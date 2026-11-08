// lib/features/document/data/storage_service.dart
import 'dart:convert';
import 'dart:io';

import 'package:cft_note/features/shelf/domain/models/note_folder.dart';
import 'package:path_provider/path_provider.dart';

import '../../shelf/domain/models/notebook.dart';

class StorageService {
  static const String _foldersFileName = 'cft_folders.json';
  static const String _fileName = 'cft_notebooks.json';
  static const String _sessionFileName = 'cft_session.json'; // ★ 記錄開啟的 Tab

  // 儲存資料夾
  static Future<void> saveFolders(List<NoteFolder> folders) async {
    try {
      final file = await _getLocalFile(_foldersFileName);
      final jsonData = jsonEncode(folders.map((f) => f.toJson()).toList());
      await file.writeAsString(jsonData);
    } catch (_) {}
  }

  // 讀取資料夾
  static Future<List<NoteFolder>?> loadFolders() async {
    try {
      final file = await _getLocalFile(_foldersFileName);
      if (!await file.exists()) return null;
      final contents = await file.readAsString();
      if (contents.trim().isEmpty) return null;
      final List<dynamic> jsonList = jsonDecode(contents);
      return jsonList
          .map((j) => NoteFolder.fromJson(j as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return null;
    }
  }

  static Future<File> _getLocalFile(String name) async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/$name');
  }

  // 儲存所有筆記本
  static Future<void> saveNotebooks(List<Notebook> notebooks) async {
    try {
      final file = await _getLocalFile(_fileName);
      final jsonData = jsonEncode(notebooks.map((n) => n.toJson()).toList());
      await file.writeAsString(jsonData);
    } catch (_) {}
  }

  // 載入筆記本
  static Future<List<Notebook>?> loadNotebooks() async {
    try {
      final file = await _getLocalFile(_fileName);
      if (!await file.exists()) return null;
      final contents = await file.readAsString();
      if (contents.trim().isEmpty) return null;
      final List<dynamic> jsonList = jsonDecode(contents);
      return jsonList
          .map((j) => Notebook.fromJson(j as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return null;
    }
  }

  // ★★★ 1. 儲存當前已開啟的標籤階段 ★★★
  static Future<void> saveSession({
    required List<String> openTabIds,
    required int activeTabIndex,
  }) async {
    try {
      final file = await _getLocalFile(_sessionFileName);
      final data = jsonEncode({
        'openTabIds': openTabIds,
        'activeTabIndex': activeTabIndex,
      });
      await file.writeAsString(data);
    } catch (_) {}
  }

  // ★★★ 2. 讀取上次開啟的標籤階段 ★★★
  static Future<Map<String, dynamic>?> loadSession() async {
    try {
      final file = await _getLocalFile(_sessionFileName);
      if (!await file.exists()) return null;
      final contents = await file.readAsString();
      if (contents.trim().isEmpty) return null;
      return jsonDecode(contents) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}
