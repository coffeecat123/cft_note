// lib/features/shelf/presentation/widgets/shelf_page.dart
import 'package:cft_note/features/pdf_import_export/services/pdf_export_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../app/settings/settings_dialog.dart';
import '../../../../app/theme/app_theme.dart';
import '../../../../core/i18n/app_strings.dart';
import '../../../canvas/presentation/widgets/canvas_page.dart';
import '../../domain/models/note_folder.dart';
import '../../domain/models/notebook.dart';
import '../../domain/models/shelf_view_options.dart';
import '../controllers/shelf_controller.dart';
import 'create_notebook_dialog.dart';
import 'folder_card.dart';
import 'notebook_card.dart';
import 'shelf_list_row.dart';

/// 拖曳時攜帶的資料：被拖的是筆記本還是資料夾
class _DragItem {
  final bool isFolder;
  final String id;
  final String name;
  const _DragItem({required this.isFolder, required this.id, required this.name});
}

class ShelfPage extends StatefulWidget {
  const ShelfPage({super.key});

  @override
  State<ShelfPage> createState() => _ShelfPageState();
}

class _ShelfPageState extends State<ShelfPage> {
  late final ShelfController _controller;

  /// 是否正在拖曳項目 (用來顯示「移到上一層」的放置區)
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _controller = ShelfController();
    _controller.addListener(() {
      if (!mounted) return;
      setState(() {});
      // 讀取失敗 / 從備份還原 / 儲存失敗 → 明確告知使用者，而不是默默吞掉
      final warning = _controller.takeLoadWarning();
      if (warning != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(warning), duration: const Duration(seconds: 10)),
          );
        });
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _openNotebook(Notebook notebook) async {
    _controller.openNotebook(notebook);
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => CanvasPage(shelfController: _controller),
      ),
    );
    _controller.notifyNotebookUpdated();
  }

  // ==========================================================
  // 對話框
  // ==========================================================
  void _showDeleteFolderDialog(NoteFolder folder) {
    final direct = _controller.folderContents(folder.id);
    final all = _controller.folderContents(folder.id, recursive: true);
    final isEmpty = all.notebooks == 0 && all.folders == 0;
    final s = S.of(context);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.deleteFolder),
        content: Text(
          isEmpty
              ? s.confirmDeleteEmptyFolder(folder.name)
              : s.deleteFolderMovesContents(
                  folder.name,
                  direct.notebooks,
                  direct.folders,
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
          if (!isEmpty)
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              onPressed: () {
                Navigator.pop(ctx);
                _confirmDeleteFolderWithContents(folder, all);
              },
              child: Text(s.deleteWithContents),
            ),
          ElevatedButton(
            onPressed: () {
              _controller.deleteFolder(folder.id);
              Navigator.pop(ctx);
            },
            child: Text(isEmpty ? s.delete : s.deleteFolder),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteFolderWithContents(
    NoteFolder folder,
    ({int notebooks, int folders}) all,
  ) {
    final s = S.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.deleteWithContentsTitle),
        content: Text(
          s.permanentlyDeleteFolder(folder.name, all.notebooks, all.folders),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              _controller.deleteFolder(folder.id, deleteContents: true);
              Navigator.pop(ctx);
            },
            child: Text(s.deletePermanently),
          ),
        ],
      ),
    );
  }

  void _showCreateFolderDialog() {
    final textController = TextEditingController();
    final s = S.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          s.newFolder,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: InputDecoration(
            hintText: s.folderName,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
          ElevatedButton(
            onPressed: () {
              _controller.createFolder(textController.text);
              Navigator.pop(ctx);
            },
            child: Text(s.create),
          ),
        ],
      ),
    );
  }

  void _showRenameDialog({
    required String title,
    required String initial,
    required String confirmLabel,
    required void Function(String) onSubmit,
  }) {
    final textController = TextEditingController(text: initial);
    final s = S.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: textController, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
          ElevatedButton(
            onPressed: () {
              onSubmit(textController.text);
              Navigator.pop(ctx);
            },
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  void _renameFolder(NoteFolder folder) => _showRenameDialog(
    title: S.of(context).renameFolder,
    initial: folder.name,
    confirmLabel: S.of(context).save,
    onSubmit: (v) => _controller.renameFolder(folder.id, v),
  );

  void _renameNotebook(Notebook nb) => _showRenameDialog(
    title: S.of(context).rename,
    initial: nb.title,
    confirmLabel: S.of(context).confirm,
    onSubmit: (v) => _controller.renameNotebook(nb.id, v),
  );

  void _showDeleteNotebookDialog(Notebook notebook) {
    final s = S.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.deleteNotebook),
        content: Text(s.confirmDeleteNotebook(notebook.title)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              _controller.deleteNotebook(notebook.id);
              Navigator.pop(ctx);
            },
            child: Text(s.delete),
          ),
        ],
      ),
    );
  }

  Future<void> _exportNotebook(Notebook notebook) async {
    final s = S.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(s.exportingPdf),
        duration: const Duration(seconds: 1),
      ),
    );
    final success = await PdfExportService.exportNotebook(notebook);
    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.pdfExported)),
      );
    }
  }

  // ==========================================================
  // 拖曳搬移
  // ==========================================================
  /// 長按後拖動。用長按而不是直接拖，才不會和捲動手勢打架。
  Widget _draggable(_DragItem item, Widget child) {
    return LongPressDraggable<_DragItem>(
      data: item,
      delay: const Duration(milliseconds: 300),
      hapticFeedbackOnStart: true,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _dragFeedback(item),
      childWhenDragging: Opacity(opacity: 0.3, child: child),
      onDragStarted: () => setState(() => _dragging = true),
      onDragEnd: (_) {
        if (mounted) setState(() => _dragging = false);
      },
      child: child,
    );
  }

  Widget _dragFeedback(_DragItem item) {
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(10),
      color: context.cs.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              item.isFolder ? Icons.folder_rounded : Icons.book_rounded,
              size: 20,
              color: item.isFolder ? Colors.blueAccent : Colors.blueGrey,
            ),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: context.cs.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _canDrop(_DragItem item, String? targetFolderId) => item.isFolder
      ? _controller.canMoveFolder(item.id, targetFolderId)
      : _controller.canMoveNotebook(item.id, targetFolderId);

  Future<void> _drop(_DragItem item, String? targetFolderId, String targetName) async {
    final ok = item.isFolder
        ? await _controller.moveFolder(item.id, targetFolderId)
        : await _controller.moveNotebook(item.id, targetFolderId);
    if (!ok || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(S.of(context).movedTo(item.name, targetName)),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  /// 把 [child] 變成資料夾的放置目標；被拖著的項目移到上面時會高亮
  Widget _folderDropTarget(NoteFolder folder, Widget child, {double radius = 12}) {
    return DragTarget<_DragItem>(
      onWillAcceptWithDetails: (d) => _canDrop(d.data, folder.id),
      onAcceptWithDetails: (d) => _drop(d.data, folder.id, folder.name),
      builder: (ctx, candidates, _) {
        final hot = candidates.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          foregroundDecoration: hot
              ? BoxDecoration(
                  color: Colors.blueAccent.withAlpha(30),
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(color: Colors.blueAccent, width: 2),
                )
              : null,
          child: child,
        );
      },
    );
  }

  /// 「上一層」的放置目標 (目前所在資料夾的父層，null = 我的筆記櫃)
  String? get _parentId => _controller.currentFolder?.parentFolderId;

  String get _parentName {
    final pid = _parentId;
    if (pid == null) return S.of(context).myShelf;
    for (final f in _controller.folders) {
      if (f.id == pid) return f.name;
    }
    return S.of(context).myShelf;
  }

  Widget _moveUpTarget(Widget Function(bool hot) builder) {
    return DragTarget<_DragItem>(
      onWillAcceptWithDetails: (d) => _canDrop(d.data, _parentId),
      onAcceptWithDetails: (d) => _drop(d.data, _parentId, _parentName),
      builder: (ctx, candidates, _) => builder(candidates.isNotEmpty),
    );
  }

  Widget _buildMoveUpBanner() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: _moveUpTarget(
        (hot) => Material(
          color: hot ? Colors.blueAccent : context.appColors.moveUpBanner,
          elevation: 3,
          child: Container(
            height: 44,
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.drive_file_move_outline,
                  size: 20,
                  color: hot ? Colors.white : Colors.blueAccent,
                ),
                const SizedBox(width: 8),
                Text(
                  S.of(context).dropHereToMove(_parentName),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: hot ? Colors.white : Colors.blueAccent,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ==========================================================
  // 排序 / 檢視切換 (AppBar)
  // ==========================================================
  PopupMenuItem<String> _checkItem(String value, String label, bool checked) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: checked
                ? const Icon(Icons.check, size: 18, color: Colors.blueAccent)
                : null,
          ),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildSortButton() {
    final c = _controller;
    final s = S.of(context);
    return PopupMenuButton<String>(
      tooltip: s.sortBy,
      icon: Icon(Icons.sort, color: context.cs.onSurface),
      onSelected: (v) {
        switch (v) {
          case 'modified':
            c.setSort(key: ShelfSortKey.modified);
          case 'name':
            c.setSort(key: ShelfSortKey.name);
          case 'asc':
            c.setSort(ascending: true);
          case 'desc':
            c.setSort(ascending: false);
        }
      },
      itemBuilder: (ctx) => [
        _checkItem('modified', s.modifiedTime, c.sortKey == ShelfSortKey.modified),
        _checkItem('name', s.name, c.sortKey == ShelfSortKey.name),
        const PopupMenuDivider(),
        _checkItem('asc', s.ascending, c.sortAscending),
        _checkItem('desc', s.descending, !c.sortAscending),
      ],
    );
  }

  Widget _buildViewToggle() {
    final isGrid = _controller.viewMode == ShelfViewMode.grid;
    final s = S.of(context);
    return IconButton(
      tooltip: isGrid ? s.switchToList : s.switchToGrid,
      icon: Icon(
        isGrid ? Icons.view_list_rounded : Icons.grid_view_rounded,
        color: context.cs.onSurface,
      ),
      onPressed: () => _controller.setViewMode(
        isGrid ? ShelfViewMode.list : ShelfViewMode.grid,
      ),
    );
  }

  // ==========================================================
  // build
  // ==========================================================
  @override
  Widget build(BuildContext context) {
    final inFolder = _controller.currentFolderId != null;
    final s = S.of(context);
    final cs = context.cs;

    return PopScope(
      // 手機返回鍵：資料夾內 → 回上一層；首頁 → 二次確認後才離開 App
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBack();
      },
      child: Scaffold(
      backgroundColor: context.appColors.shelfBackground,
      appBar: AppBar(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0.5,
        // 返回箭頭也是放置目標：把項目拖到這裡 = 移到上一層
        leading: inFolder
            ? _moveUpTarget(
                (hot) => IconButton(
                  icon: Icon(
                    Icons.arrow_back,
                    color: hot ? Colors.blueAccent : cs.onSurface,
                  ),
                  style: hot
                      ? IconButton.styleFrom(
                          backgroundColor: Colors.blueAccent.withAlpha(40),
                        )
                      : null,
                  tooltip: s.backUpOneLevel,
                  onPressed: _controller.exitFolder,
                ),
              )
            : null,
        title: Text(
          _controller.currentFolder?.name ?? s.myShelf,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 18,
            color: cs.onSurface,
          ),
        ),
        actions: [
          // 繼續編輯：只放圖示 + 數量徽章，不佔標題空間 (文字改成長按提示)
          if (_controller.openTabs.isNotEmpty)
            IconButton(
              tooltip: s.continueEditing(_controller.openTabs.length),
              style: IconButton.styleFrom(
                backgroundColor: Colors.blue.withAlpha(20),
                foregroundColor: Colors.blueAccent,
              ),
              icon: Badge(
                label: Text('${_controller.openTabs.length}'),
                backgroundColor: Colors.blueAccent,
                child: const Icon(Icons.tab, size: 20),
              ),
              onPressed: () {
                final idx = _controller.activeTabIndex
                    .clamp(0, _controller.openTabs.length - 1);
                _openNotebook(_controller.openTabs[idx]);
              },
            ),
          _buildSortButton(),
          _buildViewToggle(),
          // ★ 全域設定 (主題 / 語言)
          IconButton(
            tooltip: s.settings,
            icon: Icon(Icons.settings_outlined, color: cs.onSurface),
            onPressed: () => SettingsDialog.show(context),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Stack(
        children: [
          _controller.viewMode == ShelfViewMode.grid
              ? _buildGridView()
              : _buildListView(),
          if (_dragging && inFolder) _buildMoveUpBanner(),
        ],
      ),
    ),
    );
  }

  /// 手機返回鍵：資料夾內 → 回上一層；首頁 → 二次確認後離開 App
  Future<void> _handleBack() async {
    if (_controller.currentFolderId != null) {
      _controller.exitFolder();
      return;
    }
    final s = S.of(context);
    final exit = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.exitAppTitle),
        content: Text(s.exitAppMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.exit),
          ),
        ],
      ),
    );
    if (exit == true) {
      await SystemNavigator.pop();
    }
  }

  // ==========================================================
  // 小圖示 (格狀)
  // ==========================================================
  Widget _buildGridView() {
    final currentFolders = _controller.currentFolders;
    final currentNotebooks = _controller.currentNotebooks;

    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = (constraints.maxWidth / 160).clamp(2, 6).toInt();
        // 總卡片數 = 1(新增卡片) + 資料夾數 + 筆記本數
        final totalItems = 1 + currentFolders.length + currentNotebooks.length;

        return GridView.builder(
          // 拖曳時頂端有放置區，多留一點空間避免蓋住第一排
          padding: EdgeInsets.fromLTRB(20, _dragging && _controller.currentFolderId != null ? 64 : 20, 20, 20),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 18,
            mainAxisSpacing: 22,
            childAspectRatio: 0.65,
          ),
          itemCount: totalItems,
          itemBuilder: (context, index) {
            if (index == 0) return _buildAddNewCard();

            final itemIndex = index - 1;
            if (itemIndex < currentFolders.length) {
              return _buildFolderGridItem(currentFolders[itemIndex]);
            }
            return _buildNotebookGridItem(
              currentNotebooks[itemIndex - currentFolders.length],
            );
          },
        );
      },
    );
  }

  Widget _buildFolderGridItem(NoteFolder folder) {
    final c = _controller.folderContents(folder.id);
    final card = FolderCard(
      folder: folder,
      itemCount: c.notebooks + c.folders,
      onTap: () => _controller.enterFolder(folder.id),
      onRename: () => _renameFolder(folder),
      onDelete: () => _showDeleteFolderDialog(folder),
    );
    return _folderDropTarget(
      folder,
      _draggable(_DragItem(isFolder: true, id: folder.id, name: folder.name), card),
    );
  }

  Widget _buildNotebookGridItem(Notebook notebook) {
    final card = NotebookCard(
      notebook: notebook,
      onTap: () => _openNotebook(notebook),
      onRename: () => _renameNotebook(notebook),
      onDuplicate: () => _controller.duplicateNotebook(notebook),
      onDelete: () => _showDeleteNotebookDialog(notebook),
      onExport: () => _exportNotebook(notebook),
    );
    return _draggable(
      _DragItem(isFolder: false, id: notebook.id, name: notebook.title),
      card,
    );
  }

  // ==========================================================
  // 精簡清單 (詳細資料)
  // ==========================================================
  Widget _buildListView() {
    final folders = _controller.currentFolders;
    final notebooks = _controller.currentNotebooks;

    return LayoutBuilder(
      builder: (context, constraints) {
        final showInfo = constraints.maxWidth >= 560;
        final itemCount = 1 + folders.length + notebooks.length; // 1 = 新增列

        return Column(
          children: [
            // 拖曳時頂端有放置區，把標題列往下推
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              height: _dragging && _controller.currentFolderId != null ? 44 : 0,
            ),
            _buildListHeader(showInfo),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: itemCount,
                itemBuilder: (context, index) {
                  if (index == 0) return _buildAddNewRow();
                  final i = index - 1;
                  if (i < folders.length) {
                    return _buildFolderRow(folders[i], showInfo);
                  }
                  return _buildNotebookRow(notebooks[i - folders.length], showInfo);
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildListHeader(bool showInfo) {
    Widget cell(String label, {ShelfSortKey? key, double? width}) {
      final active = key != null && _controller.sortKey == key;
      final text = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: active ? Colors.blueAccent : context.cs.onSurfaceVariant,
              ),
            ),
          ),
          if (active)
            Icon(
              _controller.sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
              size: 14,
              color: Colors.blueAccent,
            ),
        ],
      );
      final inner = key == null
          ? Align(alignment: Alignment.centerLeft, child: text)
          : InkWell(
              onTap: () => _controller.toggleSortByColumn(key),
              child: Align(alignment: Alignment.centerLeft, child: text),
            );
      return width == null
          ? Expanded(child: inner)
          : SizedBox(width: width, child: inner);
    }

    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: context.cs.surfaceContainerHighest,
        border: Border(bottom: BorderSide(color: context.cs.outlineVariant)),
      ),
      child: Row(
        children: [
          const SizedBox(width: ShelfListRow.iconWidth),
          cell(S.of(context).name, key: ShelfSortKey.name),
          cell(S.of(context).modifiedTime, key: ShelfSortKey.modified, width: ShelfListRow.modifiedWidth),
          if (showInfo) cell(S.of(context).info, width: ShelfListRow.infoWidth),
          const SizedBox(width: ShelfListRow.menuWidth),
        ],
      ),
    );
  }

  Widget _buildFolderRow(NoteFolder folder, bool showInfo) {
    final c = _controller.folderContents(folder.id);
    final row = ShelfListRow(
      leading: Icon(Icons.folder_rounded, size: 26, color: Colors.blueAccent.withAlpha(200)),
      name: folder.name,
      modifiedText: _formatDateTime(folder.updatedAt),
      infoText: S.of(context).itemCount(c.notebooks + c.folders),
      showInfo: showInfo,
      onTap: () => _controller.enterFolder(folder.id),
      trailing: PopupMenuButton<String>(
        padding: EdgeInsets.zero,
        icon: const Icon(Icons.more_vert, size: 18, color: Colors.grey),
        onSelected: (v) {
          if (v == 'rename') _renameFolder(folder);
          if (v == 'delete') _showDeleteFolderDialog(folder);
        },
        itemBuilder: (ctx) => FolderCard.menuItems(S.of(context)),
      ),
    );
    return _folderDropTarget(
      folder,
      _draggable(_DragItem(isFolder: true, id: folder.id, name: folder.name), row),
      radius: 0,
    );
  }

  Widget _buildNotebookRow(Notebook nb, bool showInfo) {
    final row = ShelfListRow(
      leading: Container(
        width: 20,
        height: 26,
        decoration: BoxDecoration(
          color: nb.coverColor,
          borderRadius: const BorderRadius.horizontal(
            left: Radius.circular(2),
            right: Radius.circular(5),
          ),
        ),
      ),
      name: nb.title,
      modifiedText: _formatDateTime(nb.updatedAt),
      infoText: S.of(context).pageCount(nb.pageCount),
      showInfo: showInfo,
      onTap: () => _openNotebook(nb),
      trailing: PopupMenuButton<String>(
        padding: EdgeInsets.zero,
        icon: const Icon(Icons.more_vert, size: 18, color: Colors.grey),
        onSelected: (v) {
          if (v == 'rename') _renameNotebook(nb);
          if (v == 'duplicate') _controller.duplicateNotebook(nb);
          if (v == 'delete') _showDeleteNotebookDialog(nb);
          if (v == 'export') _exportNotebook(nb);
        },
        itemBuilder: (ctx) => NotebookCard.menuItems(S.of(context)),
      ),
    );
    return _draggable(_DragItem(isFolder: false, id: nb.id, name: nb.title), row);
  }

  String _formatDateTime(DateTime d) {
    String p(int n) => n.toString().padLeft(2, '0');
    return '${d.year}/${p(d.month)}/${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }

  // ==========================================================
  // 新增項目 (選單：新增筆記本 / 新增資料夾)
  // ==========================================================
  Widget _buildAddMenu({required Widget child}) {
    final s = S.of(context);
    return PopupMenuButton<String>(
      tooltip: s.addEllipsis,
      offset: const Offset(0, 50),
      onSelected: (val) {
        if (val == 'notebook') {
          showDialog(
            context: context,
            builder: (ctx) => CreateNotebookDialog(
              onCreate: (res) => _controller.createNotebook(
                title: res.title,
                coverColor: res.color,
              ),
            ),
          );
        } else if (val == 'folder') {
          _showCreateFolderDialog();
        }
      },
      itemBuilder: (ctx) => [
        PopupMenuItem(
          value: 'notebook',
          child: Row(
            children: [
              const Icon(Icons.book_outlined, color: Colors.blueAccent),
              const SizedBox(width: 8),
              Text(s.newNotebook),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'folder',
          child: Row(
            children: [
              const Icon(Icons.create_new_folder_outlined, color: Colors.amber),
              const SizedBox(width: 8),
              Text(s.newFolder),
            ],
          ),
        ),
      ],
      child: child,
    );
  }

  Widget _buildAddNewRow() {
    return _buildAddMenu(
      child: Container(
        height: ShelfListRow.rowHeight,
        decoration: BoxDecoration(
          color: context.cs.surface,
          border: Border(bottom: BorderSide(color: context.cs.outlineVariant.withAlpha(110))),
        ),
        child: Row(
          children: [
            SizedBox(
              width: ShelfListRow.iconWidth,
              child: Center(
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: Colors.blue.withAlpha(20),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.add, size: 16, color: Colors.blueAccent),
                ),
              ),
            ),
            Text(
              S.of(context).newItem,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.blueAccent,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddNewCard() {
    return _buildAddMenu(
      child: Column(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: context.cs.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: context.cs.outlineVariant, width: 1.5),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.blue.withAlpha(20),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.add, color: Colors.blueAccent, size: 26),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      S.of(context).newItem,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.blueAccent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
