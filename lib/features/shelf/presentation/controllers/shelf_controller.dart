// lib/features/shelf/presentation/controllers/shelf_controller.dart
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import '../../../document/data/storage_service.dart';
import '../../../pdf_import_export/services/pdf_service.dart';
import '../../domain/models/note_folder.dart';
import '../../domain/models/notebook.dart';
import '../../domain/models/shelf_view_options.dart';

class ShelfController extends ChangeNotifier {
  List<Notebook> notebooks = [];
  List<NoteFolder> folders = [];
  bool isLoading = true;

  final List<Notebook> openTabs = [];
  int activeTabIndex = 0;

  // 當前所在資料夾 ID (null 代表根目錄「我的筆記櫃」)
  String? currentFolderId;

  /// 讀取存檔失敗時為 true：此時不寫入磁碟，避免用「空資料」覆蓋掉還讀不出來的存檔
  bool _readOnly = false;
  String? _pendingWarning;

  /// 取出一次性的警告訊息 (讀取失敗 / 從備份還原 / 儲存失敗…)，供 UI 顯示
  String? takeLoadWarning() {
    final w = _pendingWarning;
    _pendingWarning = null;
    return w;
  }

  void _collectStorageWarnings() {
    final w = StorageService.takeWarnings();
    if (w.isNotEmpty) {
      _pendingWarning = [if (_pendingWarning != null) _pendingWarning!, ...w].join('\n');
    }
  }

  // ------------------------------------------
  // 顯示方式與排序 (僅存在記憶體，重開 App 會回到預設)
  // ------------------------------------------
  ShelfViewMode viewMode = ShelfViewMode.grid;
  ShelfSortKey sortKey = ShelfSortKey.modified;
  bool sortAscending = false; // 預設：最近修改的在前

  void setViewMode(ShelfViewMode mode) {
    if (viewMode == mode) return;
    viewMode = mode;
    notifyListeners();
  }

  void setSort({ShelfSortKey? key, bool? ascending}) {
    final newKey = key ?? sortKey;
    final newAsc = ascending ?? sortAscending;
    if (newKey == sortKey && newAsc == sortAscending) return;
    sortKey = newKey;
    sortAscending = newAsc;
    notifyListeners();
  }

  /// 點擊清單欄位標題：同一欄 → 反轉方向；換欄 → 名稱預設升序、時間預設降序
  void toggleSortByColumn(ShelfSortKey key) {
    if (sortKey == key) {
      sortAscending = !sortAscending;
    } else {
      sortKey = key;
      sortAscending = key == ShelfSortKey.name;
    }
    notifyListeners();
  }

  int _compare(String nameA, DateTime timeA, String idA, String nameB,
      DateTime timeB, String idB) {
    int c = sortKey == ShelfSortKey.name
        ? nameA.toLowerCase().compareTo(nameB.toLowerCase())
        : timeA.compareTo(timeB);
    if (c == 0) c = nameA.toLowerCase().compareTo(nameB.toLowerCase());
    if (c == 0) c = idA.compareTo(idB);
    return sortAscending ? c : -c;
  }

  // 取得當前目錄下的資料夾與筆記本 (已依目前排序設定排序；資料夾永遠在筆記本前面)
  List<NoteFolder> get currentFolders {
    final list = folders.where((f) => f.parentFolderId == currentFolderId).toList();
    list.sort((a, b) => _compare(a.name, a.updatedAt, a.id, b.name, b.updatedAt, b.id));
    return list;
  }

  List<Notebook> get currentNotebooks {
    final list = notebooks.where((n) => n.folderId == currentFolderId).toList();
    list.sort((a, b) => _compare(a.title, a.updatedAt, a.id, b.title, b.updatedAt, b.id));
    return list;
  }

  /// 找不到時回傳 null (原本 firstWhere 會直接丟 StateError)
  NoteFolder? get currentFolder =>
      currentFolderId == null ? null : _folderById(currentFolderId!);

  NoteFolder? _folderById(String id) {
    for (final f in folders) {
      if (f.id == id) return f;
    }
    return null;
  }

  ShelfController() {
    _initAndLoad();
  }

  Future<void> _initAndLoad() async {
    List<Notebook>? loaded;
    List<NoteFolder>? loadedFolders;
    try {
      loaded = await StorageService.loadNotebooks();
      loadedFolders = await StorageService.loadFolders();
    } catch (e, st) {
      debugPrint('讀取存檔失敗：$e\n$st');
      _readOnly = true;
      _pendingWarning = '讀取存檔時發生錯誤，為保護現有資料，本次使用期間不會寫入存檔。\n$e';
    }

    if (loadedFolders != null) {
      folders = loadedFolders;
    }
    if (loaded != null && loaded.isNotEmpty) {
      notebooks = loaded;
    } else {
      notebooks = [
        Notebook(
          id: 'default_1',
          title: '日常速記',
          coverColor: const Color(0xFF2B3A4A),
          updatedAt: DateTime.now(),
        ),
      ];
      await _persist();
    }

    try {
      final session = await StorageService.loadSession();
      if (session != null) {
        final List<dynamic> openIds = (session['openTabIds'] as List?) ?? [];
        openTabs.clear();
        for (final id in openIds) {
          final match = notebooks.where((n) => n.id == id).firstOrNull;
          if (match != null) openTabs.add(match);
        }
        final savedIndex = session['activeTabIndex'] as int? ?? 0;
        activeTabIndex =
            openTabs.isNotEmpty ? savedIndex.clamp(0, openTabs.length - 1) : 0;
      }
    } catch (e) {
      debugPrint('讀取 session 失敗 (忽略)：$e');
    }

    // 預先開啟上次正在看的 PDF，使用者點進筆記時目前頁可以更快出現
    if (openTabs.isNotEmpty) {
      final nb = openTabs[activeTabIndex.clamp(0, openTabs.length - 1)];
      if (nb.pages.isNotEmpty) {
        final page =
            nb.pages[nb.lastViewedPageIndex.clamp(0, nb.pages.length - 1)];
        final path = page.pdfFilePath;
        if (path != null) PdfService.warmUp(path);
      }
    }

    _collectStorageWarnings();
    isLoading = false;
    notifyListeners();
  }

  Future<void> _persist() async {
    if (_readOnly) return;
    await StorageService.saveNotebooks(notebooks);
    await StorageService.saveFolders(folders);
    await StorageService.saveSession(
      openTabIds: openTabs.map((n) => n.id).toList(),
      activeTabIndex: activeTabIndex,
    );
    _collectStorageWarnings();
  }

  /// 只存檔、不通知 UI (畫布自動存檔用，避免書架無謂重建)
  Future<void> saveToDisk() => _persist();

  // ------------------------------------------
  // 資料夾操作
  // ------------------------------------------
  Future<void> createFolder(String name) async {
    final newFolder = NoteFolder(
      id: 'folder_${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim().isEmpty ? '未命名資料夾' : name.trim(),
      createdAt: DateTime.now(),
      parentFolderId: currentFolderId,
    );
    folders.insert(0, newFolder);
    _touchFolder(currentFolderId); // 父資料夾內容有異動
    await _persist();
    notifyListeners();
  }

  void _touchFolder(String? id) {
    if (id == null) return;
    final f = _folderById(id);
    if (f != null) f.updatedAt = DateTime.now();
  }

  Future<void> renameFolder(String id, String newName) async {
    final idx = folders.indexWhere((f) => f.id == id);
    if (idx != -1 && newName.trim().isNotEmpty) {
      folders[idx].name = newName.trim();
      folders[idx].updatedAt = DateTime.now();
      await _persist();
      notifyListeners();
    }
  }

  /// 某資料夾底下所有子孫資料夾的 ID (含防循環)
  Set<String> _descendantFolderIds(String id) {
    final result = <String>{};
    final queue = <String>[id];
    while (queue.isNotEmpty) {
      final cur = queue.removeLast();
      for (final f in folders) {
        if (f.parentFolderId == cur && result.add(f.id)) {
          queue.add(f.id);
        }
      }
    }
    result.remove(id);
    return result;
  }

  /// 資料夾內容統計 (供刪除對話框顯示)。
  /// [recursive] 為 false 只算直接子層，true 則包含所有子孫。
  ({int notebooks, int folders}) folderContents(String id, {bool recursive = false}) {
    if (!recursive) {
      return (
        notebooks: notebooks.where((n) => n.folderId == id).length,
        folders: folders.where((f) => f.parentFolderId == id).length,
      );
    }
    final subs = _descendantFolderIds(id);
    return (
      notebooks: notebooks.where((n) => n.folderId == id || subs.contains(n.folderId)).length,
      folders: subs.length,
    );
  }

  /// 刪除資料夾。
  /// 預設 ([deleteContents] = false)：裡面的筆記本與子資料夾「移到上一層」，不會遺失。
  /// 明確指定 [deleteContents] = true 才會連同所有子孫內容一併刪除。
  Future<void> deleteFolder(String id, {bool deleteContents = false}) async {
    final target = _folderById(id);
    if (target == null) return;
    final parentId = target.parentFolderId;

    final removedFolderIds = <String>{id};
    final removedNotebooks = <Notebook>[];

    if (deleteContents) {
      removedFolderIds.addAll(_descendantFolderIds(id));
      removedNotebooks.addAll(
        notebooks.where((n) => removedFolderIds.contains(n.folderId)),
      );
      notebooks.removeWhere((n) => removedFolderIds.contains(n.folderId));
      openTabs.removeWhere((n) => removedNotebooks.any((r) => r.id == n.id));
    } else {
      for (final n in notebooks) {
        if (n.folderId == id) n.folderId = parentId;
      }
      for (final f in folders) {
        if (f.parentFolderId == id) f.parentFolderId = parentId;
      }
    }

    folders.removeWhere((f) => removedFolderIds.contains(f.id));

    // 使用者正站在被刪的資料夾裡 → 退回安全位置 (原本會因 currentFolder 找不到而崩潰)
    if (currentFolderId != null && removedFolderIds.contains(currentFolderId)) {
      currentFolderId = parentId;
    }
    _clampActiveTab();

    await _persist();
    await _evictUnusedPdfs(removedNotebooks);
    notifyListeners();
  }

  // ------------------------------------------
  // 拖曳搬移
  // ------------------------------------------
  /// 筆記本能否搬到 [targetFolderId] (null = 最外層)
  bool canMoveNotebook(String id, String? targetFolderId) {
    final nb = notebooks.where((n) => n.id == id).firstOrNull;
    if (nb == null || nb.folderId == targetFolderId) return false;
    if (targetFolderId != null && _folderById(targetFolderId) == null) return false;
    return true;
  }

  /// 資料夾能否搬到 [targetParentId] (null = 最外層)。
  /// 不能搬進自己或自己的子孫 (會形成循環)，也不用搬到原本所在位置。
  bool canMoveFolder(String id, String? targetParentId) {
    final f = _folderById(id);
    if (f == null || f.parentFolderId == targetParentId) return false;
    if (targetParentId == null) return true;
    if (targetParentId == id) return false;
    if (_folderById(targetParentId) == null) return false;
    return !_descendantFolderIds(id).contains(targetParentId);
  }

  /// 搬移筆記本。不改變筆記本自己的修改時間，只更新相關資料夾的時間。
  Future<bool> moveNotebook(String id, String? targetFolderId) async {
    if (!canMoveNotebook(id, targetFolderId)) return false;
    final nb = notebooks.firstWhere((n) => n.id == id);
    _touchFolder(nb.folderId);
    nb.folderId = targetFolderId;
    _touchFolder(targetFolderId);
    await _persist();
    notifyListeners();
    return true;
  }

  Future<bool> moveFolder(String id, String? targetParentId) async {
    if (!canMoveFolder(id, targetParentId)) return false;
    final f = _folderById(id)!;
    _touchFolder(f.parentFolderId);
    f.parentFolderId = targetParentId;
    _touchFolder(targetParentId);
    await _persist();
    notifyListeners();
    return true;
  }

  void enterFolder(String folderId) {
    currentFolderId = folderId;
    notifyListeners();
  }

  void exitFolder() {
    if (currentFolderId == null) return;
    currentFolderId = currentFolder?.parentFolderId;
    notifyListeners();
  }

  // ------------------------------------------
  // 筆記本操作
  // ------------------------------------------
  void openNotebook(Notebook notebook) {
    final existingIndex = openTabs.indexWhere((nb) => nb.id == notebook.id);
    if (existingIndex != -1) {
      activeTabIndex = existingIndex;
    } else {
      openTabs.add(notebook);
      activeTabIndex = openTabs.length - 1;
    }
    _persist();
    notifyListeners();
  }

  Future<void> createNotebook({required String title, required Color coverColor}) async {
    final newBook = Notebook(
      id: Notebook.generateId(),
      title: title.trim().isEmpty ? '未命名筆記' : title.trim(),
      coverColor: coverColor,
      updatedAt: DateTime.now(),
      folderId: currentFolderId,
    );
    notebooks.insert(0, newBook);
    _touchFolder(currentFolderId);
    await _persist();
    notifyListeners();
  }

  Future<void> renameNotebook(String id, String newTitle) async {
    final index = notebooks.indexWhere((nb) => nb.id == id);
    if (index != -1 && newTitle.trim().isNotEmpty) {
      notebooks[index].title = newTitle.trim();
      notebooks[index].updatedAt = DateTime.now();
      await _persist();
      notifyListeners();
    }
  }

  /// 複製筆記本：新 id + 頁面/筆劃深層複製，副本與原本完全獨立
  Future<void> duplicateNotebook(Notebook target) async {
    final cloned = target.duplicate(title: '${target.title} (副本)');
    notebooks.insert(0, cloned);
    await _persist();
    notifyListeners();
  }

  Future<void> deleteNotebook(String id) async {
    final removed = notebooks.where((nb) => nb.id == id).toList();
    notebooks.removeWhere((nb) => nb.id == id);
    openTabs.removeWhere((nb) => nb.id == id);
    _clampActiveTab();
    await _persist();
    await _evictUnusedPdfs(removed);
    notifyListeners();
  }

  Future<void> notifyNotebookUpdated() async {
    await _persist();
    notifyListeners();
  }

  // ------------------------------------------
  // 內部輔助
  // ------------------------------------------
  void _clampActiveTab() {
    if (openTabs.isEmpty) {
      activeTabIndex = 0;
    } else if (activeTabIndex >= openTabs.length) {
      activeTabIndex = openTabs.length - 1;
    }
  }

  /// 已不再被任何筆記本引用的 PDF → 關閉已開啟的 PdfDocument，釋放原生記憶體
  Future<void> _evictUnusedPdfs(List<Notebook> removed) async {
    if (removed.isEmpty) return;
    final stillUsed = <String>{
      for (final nb in notebooks)
        for (final p in nb.pages)
          if (p.pdfFilePath != null) p.pdfFilePath!,
    };
    final candidates = <String>{
      for (final nb in removed)
        for (final p in nb.pages)
          if (p.pdfFilePath != null) p.pdfFilePath!,
    };
    for (final path in candidates.difference(stillUsed)) {
      await PdfService.evictDocument(path);
    }
  }
}
