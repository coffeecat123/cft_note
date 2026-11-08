// lib/features/shelf/presentation/widgets/shelf_page.dart
import 'package:cft_note/features/pdf_import_export/services/pdf_export_service.dart';
import 'package:flutter/material.dart';

import '../../../canvas/presentation/widgets/canvas_page.dart';
import '../../domain/models/notebook.dart';
import '../controllers/shelf_controller.dart';
import 'create_notebook_dialog.dart';
import 'folder_card.dart';
import 'notebook_card.dart';

class ShelfPage extends StatefulWidget {
  const ShelfPage({super.key});

  @override
  State<ShelfPage> createState() => _ShelfPageState();
}

class _ShelfPageState extends State<ShelfPage> {
  late final ShelfController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ShelfController();
    _controller.addListener(() => setState(() {}));
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

  // 新增資料夾對話框
  void _showCreateFolderDialog() {
    final textController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          '新增資料夾',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '資料夾名稱',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              _controller.createFolder(textController.text);
              Navigator.pop(ctx);
            },
            child: const Text('建立'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentFolders = _controller.currentFolders;
    final currentNotebooks = _controller.currentNotebooks;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        // ★ 麵包屑導覽：如果在資料夾內，顯示返回箭頭與當前資料夾名稱
        leading: _controller.currentFolderId != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.black87),
                tooltip: '返回上一層',
                onPressed: _controller.exitFolder,
              )
            : null,
        title: Text(
          _controller.currentFolder != null
              ? _controller.currentFolder!.name
              : '我的筆記櫃',
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 18,
            color: Colors.black87,
          ),
        ),
        actions: [
          if (_controller.openTabs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  backgroundColor: Colors.blue.withAlpha(20),
                  foregroundColor: Colors.blueAccent,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                icon: const Icon(Icons.tab, size: 16),
                label: Text(
                  '繼續編輯 (${_controller.openTabs.length})',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onPressed: () {
                  final target =
                      _controller.openTabs[_controller.activeTabIndex];
                  _openNotebook(target);
                },
              ),
            ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final crossAxisCount = (constraints.maxWidth / 160)
              .clamp(2, 6)
              .toInt();

          // 總卡片數 = 1(新增卡片) + 資料夾數 + 筆記本數
          final totalItems =
              1 + currentFolders.length + currentNotebooks.length;

          return GridView.builder(
            padding: const EdgeInsets.all(20),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              crossAxisSpacing: 18,
              mainAxisSpacing: 22,
              childAspectRatio: 0.65,
            ),
            itemCount: totalItems,
            itemBuilder: (context, index) {
              // 1. 第一個永遠是新增卡片
              if (index == 0) {
                return _buildAddNewCard();
              }

              final itemIndex = index - 1;

              // 2. 優先排列資料夾 (Folders First)
              if (itemIndex < currentFolders.length) {
                final folder = currentFolders[itemIndex];
                // 計算資料夾內的項目數
                final count = _controller.notebooks
                    .where((n) => n.folderId == folder.id)
                    .length;

                return FolderCard(
                  folder: folder,
                  itemCount: count,
                  onTap: () => _controller.enterFolder(folder.id), // 點擊進入資料夾
                  onRename: () {
                    final textController = TextEditingController(
                      text: folder.name,
                    );
                    showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('重新命名資料夾'),
                        content: TextField(
                          controller: textController,
                          autofocus: true,
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('取消'),
                          ),
                          ElevatedButton(
                            onPressed: () {
                              _controller.renameFolder(
                                folder.id,
                                textController.text,
                              );
                              Navigator.pop(ctx);
                            },
                            child: const Text('儲存'),
                          ),
                        ],
                      ),
                    );
                  },
                  onDelete: () {
                    showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('刪除資料夾'),
                        content: Text('確定要刪除「${folder.name}」嗎？裡面的所有筆記本將會一併被徹底刪除，無法復原。'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('取消'),
                          ),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.redAccent,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () {
                              _controller.deleteFolder(folder.id);
                              Navigator.pop(ctx);
                            },
                            child: const Text('刪除'),
                          ),
                        ],
                      ),
                    );
                  },
                );
              }

              // 3. 排列筆記本 (Notebooks)
              final nbIndex = itemIndex - currentFolders.length;
              final notebook = currentNotebooks[nbIndex];

              return NotebookCard(
                notebook: notebook,
                onTap: () => _openNotebook(notebook),
                onRename: () {
                  final textController = TextEditingController(
                    text: notebook.title,
                  );
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('重新命名'),
                      content: TextField(
                        controller: textController,
                        autofocus: true,
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('取消'),
                        ),
                        ElevatedButton(
                          onPressed: () {
                            _controller.renameNotebook(
                              notebook.id,
                              textController.text,
                            );
                            Navigator.pop(ctx);
                          },
                          child: const Text('確認'),
                        ),
                      ],
                    ),
                  );
                },
                onDuplicate: () => _controller.duplicateNotebook(notebook),
                onDelete: () {
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('刪除筆記本'),
                      content: Text('確定要刪除「${notebook.title}」嗎？'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('取消'),
                        ),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.redAccent,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () {
                            _controller.deleteNotebook(notebook.id);
                            Navigator.pop(ctx);
                          },
                          child: const Text('刪除'),
                        ),
                      ],
                    ),
                  );
                },
                onExport: () async {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('正在合成向量 PDF...'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                  final success = await PdfExportService.exportNotebook(
                    notebook,
                  );
                  if (success && context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('PDF 匯出成功！')));
                  }
                },
              );
            },
          );
        },
      ),
    );
  }

  // ★ 新增卡片：點擊彈出選單（新增筆記本 或 新增資料夾）
  Widget _buildAddNewCard() {
    return PopupMenuButton<String>(
      tooltip: '新增...',
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
        const PopupMenuItem(
          value: 'notebook',
          child: Row(
            children: [
              Icon(Icons.book_outlined, color: Colors.blueAccent),
              SizedBox(width: 8),
              Text('新增筆記本'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'folder',
          child: Row(
            children: [
              Icon(Icons.create_new_folder_outlined, color: Colors.amber),
              SizedBox(width: 8),
              Text('新增資料夾'),
            ],
          ),
        ),
      ],
      child: Column(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey[300]!, width: 1.5),
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
                      child: const Icon(
                        Icons.add,
                        color: Colors.blueAccent,
                        size: 26,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '新增項目',
                      style: TextStyle(
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
