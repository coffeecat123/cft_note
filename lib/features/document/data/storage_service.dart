// lib/features/document/data/storage_service.dart
//
// 安全儲存：
//  1. 原子寫入：先寫 .tmp 並 flush，再 rename 覆蓋，中途當機不會留下寫一半的檔案
//  2. 滾動備份：每次覆蓋前把上一個完好版本複製成 .bak
//  3. 損毀隔離：主檔解析失敗時不覆蓋，改名為 .corrupt-<時間>，並從 .bak 還原
//  4. 寫入序列化 + 合併：同一檔案的寫入排隊執行，排隊中的舊內容會被較新的取代
//  5. 單本損壞不影響其他：壞掉的筆記本另存 .skipped-<時間> 供人工救援
//  6. 不再靜默吞錯：失敗會記錄並累積警告供 UI 顯示
import 'dart:convert';
import 'dart:io';

import 'package:cft_note/features/shelf/domain/models/note_folder.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import '../../shelf/domain/models/notebook.dart';

class StorageService {
  static const String _foldersFileName = 'cft_folders.json';
  static const String _fileName = 'cft_notebooks.json';
  static const String _sessionFileName = 'cft_session.json'; // 記錄開啟的 Tab

  // ------------------------------------------------------------
  // 警告收集 (供 UI 顯示)
  // ------------------------------------------------------------
  static final List<String> _warnings = [];

  /// 取出並清空目前累積的警告
  static List<String> takeWarnings() {
    final w = List<String>.from(_warnings);
    _warnings.clear();
    return w;
  }

  static void _warn(String message) {
    debugPrint('[Storage] $message');
    _warnings.add(message);
  }

  static Future<File> _getLocalFile(String name) async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/$name');
  }

  // ------------------------------------------------------------
  // 寫入 (序列化 + 合併 + 原子)
  // ------------------------------------------------------------
  static final Map<String, int> _version = {};
  static final Map<String, Future<void>> _tail = {};

  static Future<void> _write(String name, String content) {
    final v = (_version[name] ?? 0) + 1;
    _version[name] = v;
    final prev = _tail[name] ?? Future<void>.value();
    final next = prev
        .then<void>((_) async {
          // 排隊期間若已有更新的內容，這份就不用寫了
          if (_version[name] != v) return;
          await _atomicWrite(name, content);
        })
        .catchError((Object e, StackTrace st) {
          _warn('儲存「$name」失敗：$e');
        });
    _tail[name] = next;
    return next;
  }

  static Future<void> _atomicWrite(String name, String content) async {
    final file = await _getLocalFile(name);
    final tmp = File('${file.path}.tmp');
    final bak = File('${file.path}.bak');

    await tmp.writeAsString(content, flush: true);

    // 上一個完好版本留作備份
    if (await file.exists() && await file.length() > 0) {
      try {
        await file.copy(bak.path);
      } catch (e) {
        debugPrint('[Storage] 備份失敗：$e');
      }
    }

    try {
      await tmp.rename(file.path);
    } on FileSystemException {
      // 部分平台不允許 rename 覆蓋既有檔案
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
    }
  }

  // ------------------------------------------------------------
  // 讀取 (含損毀偵測與備份還原)
  // ------------------------------------------------------------
  static Object? _tryDecode(String text, bool Function(Object?) isValid) {
    try {
      final decoded = jsonDecode(text);
      return isValid(decoded) ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static String _stamp() => DateTime.now().millisecondsSinceEpoch.toString();

  /// 回傳解碼後的內容；檔案不存在回傳 null。
  /// I/O 錯誤 (權限、磁碟) 會直接丟出例外 → 呼叫端必須視為「讀取失敗」而非「沒有資料」。
  static Future<Object?> _readJson(
    String name,
    bool Function(Object?) isValid,
  ) async {
    final file = await _getLocalFile(name);
    final bak = File('${file.path}.bak');

    if (await file.exists()) {
      final contents = await file.readAsString();
      if (contents.trim().isNotEmpty) {
        final decoded = _tryDecode(contents, isValid);
        if (decoded != null) return decoded;

        // 主檔損毀 → 保留證據，絕不覆蓋
        final aside = '${file.path}.corrupt-${_stamp()}';
        try {
          await file.rename(aside);
          _warn('「$name」內容損毀，已另存為 ${aside.split(Platform.pathSeparator).last}');
        } catch (e) {
          _warn('「$name」內容損毀且無法另存：$e');
        }
      }
      // 空檔案 (例如舊版寫入中斷) 直接走備份流程
    } else if (!await bak.exists()) {
      return null; // 全新安裝
    }

    if (await bak.exists()) {
      final decoded = _tryDecode(await bak.readAsString(), isValid);
      if (decoded != null) {
        try {
          await bak.copy(file.path);
        } catch (_) {}
        _warn('偵測到資料檔異常，已從備份還原 (可能遺失最近一次的修改)。');
        return decoded;
      }
    }
    _warn('資料檔損毀且沒有可用的備份，已保留原檔供救援。');
    return null;
  }

  // ------------------------------------------------------------
  // 資料夾
  // ------------------------------------------------------------
  static Future<void> saveFolders(List<NoteFolder> folders) async {
    final String json;
    try {
      json = jsonEncode(folders.map((f) => f.toJson()).toList());
    } catch (e) {
      _warn('資料夾資料無法編碼，已略過儲存：$e');
      return;
    }
    await _write(_foldersFileName, json);
  }

  static Future<List<NoteFolder>?> loadFolders() async {
    final decoded = await _readJson(_foldersFileName, (d) => d is List);
    if (decoded == null) return null;
    final result = <NoteFolder>[];
    for (final j in decoded as List) {
      try {
        result.add(NoteFolder.fromJson(j as Map<String, dynamic>));
      } catch (e) {
        debugPrint('[Storage] 略過損壞的資料夾項目：$e');
      }
    }
    return result;
  }

  // ------------------------------------------------------------
  // 筆記本
  // ------------------------------------------------------------
  static Future<void> saveNotebooks(List<Notebook> notebooks) async {
    // 編碼在「呼叫當下」同步完成 → 取得一致的快照，之後的修改不會混進來
    final String json;
    try {
      json = jsonEncode(notebooks.map((n) => n.toJson()).toList());
    } catch (e) {
      // 編碼失敗時絕對不能動磁碟上的舊檔
      _warn('筆記資料無法編碼，已保留先前的存檔：$e');
      return;
    }
    await _write(_fileName, json);
  }

  static Future<List<Notebook>?> loadNotebooks() async {
    final decoded = await _readJson(_fileName, (d) => d is List);
    if (decoded == null) return null;

    final result = <Notebook>[];
    final skipped = <Object?>[];
    for (final j in decoded as List) {
      try {
        result.add(Notebook.fromJson(j as Map<String, dynamic>));
      } catch (e) {
        debugPrint('[Storage] 略過損壞的筆記本：$e');
        skipped.add(j);
      }
    }

    if (skipped.isNotEmpty) {
      // 把解析不了的原始資料另存，避免下次儲存時被永久丟掉
      try {
        final file = await _getLocalFile(_fileName);
        final out = File('${file.path}.skipped-${_stamp()}');
        await out.writeAsString(jsonEncode(skipped), flush: true);
        _warn('有 ${skipped.length} 本筆記無法讀取，原始資料已另存為 '
            '${out.path.split(Platform.pathSeparator).last}');
      } catch (e) {
        _warn('有 ${skipped.length} 本筆記無法讀取，且無法另存原始資料：$e');
      }
    }
    return result;
  }

  // ------------------------------------------------------------
  // 標籤階段 (Session)
  // ------------------------------------------------------------
  static Future<void> saveSession({
    required List<String> openTabIds,
    required int activeTabIndex,
  }) async {
    await _write(
      _sessionFileName,
      jsonEncode({'openTabIds': openTabIds, 'activeTabIndex': activeTabIndex}),
    );
  }

  static Future<Map<String, dynamic>?> loadSession() async {
    final decoded = await _readJson(_sessionFileName, (d) => d is Map);
    if (decoded == null) return null;
    return Map<String, dynamic>.from(decoded as Map);
  }
}
