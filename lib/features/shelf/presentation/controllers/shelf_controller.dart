// lib/features/shelf/presentation/controllers/shelf_controller.dart
import 'package:flutter/material.dart';
import '../../../document/data/storage_service.dart';
import '../../domain/models/note_folder.dart';
import '../../domain/models/notebook.dart';

class ShelfController extends ChangeNotifier {
  List<Notebook> notebooks = [];
  List<NoteFolder> folders = [];
  bool isLoading = true;

  final List<Notebook> openTabs = [];
  int activeTabIndex = 0;

  // ★ 當前所在資料夾 ID (null 代表根目錄「我的筆記櫃」)
  String? currentFolderId;

  // 取得當前目錄下的資料夾與筆記本
  List<NoteFolder> get currentFolders =>
      folders.where((f) => f.parentFolderId == currentFolderId).toList();

  List<Notebook> get currentNotebooks =>
      notebooks.where((n) => n.folderId == currentFolderId).toList();

  NoteFolder? get currentFolder =>
      currentFolderId != null ? folders.firstWhere((f) => f.id == currentFolderId) : null;

  ShelfController() {
    _initAndLoad();
  }

  Future<void> _initAndLoad() async {
    final loaded = await StorageService.loadNotebooks();
    final loadedFolders = await StorageService.loadFolders();

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

    final session = await StorageService.loadSession();
    if (session != null) {
      final List<dynamic> openIds = session['openTabIds'] ?? [];
      openTabs.clear();
      for (final id in openIds) {
        final match = notebooks.where((n) => n.id == id).firstOrNull;
        if (match != null) openTabs.add(match);
      }
      final savedIndex = session['activeTabIndex'] as int? ?? 0;
      activeTabIndex = openTabs.isNotEmpty ? savedIndex.clamp(0, openTabs.length - 1) : 0;
    }

    isLoading = false;
    notifyListeners();
  }

  Future<void> _persist() async {
    await StorageService.saveNotebooks(notebooks);
    await StorageService.saveFolders(folders); // ★ 存檔資料夾
    await StorageService.saveSession(
      openTabIds: openTabs.map((n) => n.id).toList(),
      activeTabIndex: activeTabIndex,
    );
  }

  // ------------------------------------------
  // 資料夾操作
  // ------------------------------------------
  // 新增資料夾
  Future<void> createFolder(String name) async {
    final newFolder = NoteFolder(
      id: 'folder_${DateTime.now().millisecondsSinceEpoch}',
      name: name.trim().isEmpty ? '未命名資料夾' : name.trim(),
      createdAt: DateTime.now(),
      parentFolderId: currentFolderId, // 建在當前資料夾內
    );
    folders.insert(0, newFolder);
    await _persist();
    notifyListeners();
  }

  // 重新命名資料夾
  Future<void> renameFolder(String id, String newName) async {
    final idx = folders.indexWhere((f) => f.id == id);
    if (idx != -1 && newName.trim().isNotEmpty) {
      folders[idx].name = newName.trim();
      await _persist();
      notifyListeners();
    }
  }

  // 刪除資料夾 (將裡面的筆記移至外層，避免遺失)
  Future<void> deleteFolder(String id) async {
    // 1. 找出該資料夾底下的所有筆記本 ID
    final notebookIdsInFolder =
        notebooks.where((n) => n.folderId == id).map((n) => n.id).toSet();

    // 2. 徹底刪除屬於該資料夾的所有筆記本
    notebooks.removeWhere((n) => n.folderId == id);

    // 3. 如果這些筆記本剛好開啟在標籤列，一併關閉
    openTabs.removeWhere((n) => notebookIdsInFolder.contains(n.id));
    if (activeTabIndex >= openTabs.length && openTabs.isNotEmpty) {
      activeTabIndex = openTabs.length - 1;
    }

    // 4. 刪除資料夾本體
    folders.removeWhere((f) => f.id == id);

    await _persist();
    notifyListeners();
  }

  // 進入資料夾
  void enterFolder(String folderId) {
    currentFolderId = folderId;
    notifyListeners();
  }

  // 返回上一層
  void exitFolder() {
    if (currentFolderId == null) return;
    final parent = currentFolder?.parentFolderId;
    currentFolderId = parent;
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
      id: 'nb_${DateTime.now().millisecondsSinceEpoch}',
      title: title.trim().isEmpty ? '未命名筆記' : title.trim(),
      coverColor: coverColor,
      updatedAt: DateTime.now(),
      folderId: currentFolderId, // ★ 自動建在當前所在的資料夾內！
    );
    notebooks.insert(0, newBook);
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

  Future<void> duplicateNotebook(Notebook target) async {
    final cloned = target.copyWith(title: '${target.title} (副本)');
    notebooks.insert(0, cloned);
    await _persist();
    notifyListeners();
  }

  Future<void> deleteNotebook(String id) async {
    notebooks.removeWhere((nb) => nb.id == id);
    openTabs.removeWhere((nb) => nb.id == id);
    if (activeTabIndex >= openTabs.length && openTabs.isNotEmpty) {
      activeTabIndex = openTabs.length - 1;
    }
    await _persist();
    notifyListeners();
  }

  Future<void> notifyNotebookUpdated() async {
    await _persist();
    notifyListeners();
  }
}