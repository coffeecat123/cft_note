// lib/features/shelf/presentation/widgets/notebook_card.dart
import 'package:flutter/material.dart';
import '../../domain/models/notebook.dart';

class NotebookCard extends StatelessWidget {
  final Notebook notebook;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;
  final VoidCallback onExport;

  const NotebookCard({
    super.key,
    required this.notebook,
    required this.onTap,
    required this.onRename,
    required this.onDuplicate,
    required this.onDelete,
    required this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. 書本立體封面
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: notebook.coverColor,
                borderRadius: const BorderRadius.horizontal(
                  left: Radius.circular(3),  // 左側書脊較平
                  right: Radius.circular(10), // 右側書頁圓角
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(50),
                    blurRadius: 8,
                    offset: const Offset(3, 5),
                  ),
                ],
              ),
              child: Stack(
                children: [
                  // 左側書脊壓痕 (Spine Shadow)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: 14,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.black.withAlpha(80),
                            Colors.white.withAlpha(40),
                            Colors.black.withAlpha(30),
                            Colors.transparent,
                          ],
                          stops: const [0.0, 0.3, 0.6, 1.0],
                        ),
                      ),
                    ),
                  ),

                  // 封面標籤貼 (紙質白貼標)
                  Center(
                    child: Container(
                      width: 105,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFBFBF9),
                        borderRadius: BorderRadius.circular(4),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withAlpha(40),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            notebook.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF2C3E50),
                              height: 1.2,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(width: 24, height: 1.5, color: Colors.grey[300]),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),

          // 2. 書名與更多選單按鈕
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      notebook.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.black87),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${notebook.pageCount} 頁 (第 ${notebook.lastViewedPageIndex + 1} 頁) • ${_formatDate(notebook.updatedAt)}',
                      style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
              // 更多選單 (重新命名、複製、刪除)
              PopupMenuButton<String>(
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.more_vert, size: 18, color: Colors.grey),
                onSelected: (val) {
                  if (val == 'rename') onRename();
                  if (val == 'duplicate') onDuplicate();
                  if (val == 'delete') onDelete();
                  if (val == 'export') onExport();
                },
                itemBuilder: (ctx) => [
                  const PopupMenuItem(
                    value: 'export',
                    child: Row(
                      children: [
                        Icon(Icons.picture_as_pdf_outlined, size: 18, color: Colors.blueAccent),
                        SizedBox(width: 8),
                        Text('匯出為 PDF', style: TextStyle(fontSize: 13, color: Colors.blueAccent)),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'rename',
                    child: Row(
                      children: [
                        Icon(Icons.edit_outlined, size: 18),
                        SizedBox(width: 8),
                        Text('重新命名', style: TextStyle(fontSize: 13)),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'duplicate',
                    child: Row(
                      children: [
                        Icon(Icons.copy_outlined, size: 18),
                        SizedBox(width: 8),
                        Text('製作副本', style: TextStyle(fontSize: 13)),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                        SizedBox(width: 8),
                        Text('刪除', style: TextStyle(fontSize: 13, color: Colors.redAccent)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分鐘前';
    if (diff.inHours < 24) return '${diff.inHours} 小時前';
    return '${dt.month}/${dt.day}';
  }
}