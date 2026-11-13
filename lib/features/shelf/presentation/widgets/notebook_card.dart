// lib/features/shelf/presentation/widgets/notebook_card.dart
import 'package:flutter/material.dart';
import '../../../../app/theme/app_theme.dart';
import '../../../../core/i18n/app_strings.dart';
import '../../domain/models/notebook.dart';
import 'notebook_thumbnail.dart';

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
    final s = S.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. 書本立體封面：顯示第一頁預覽圖 (封面顏色保留在左側書脊)
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: NotebookThumbnail.aspectOf(notebook),
                child: LayoutBuilder(
                  builder: (context, box) {
                    const radius = BorderRadius.horizontal(
                      left: Radius.circular(3), // 左側書脊較平
                      right: Radius.circular(10), // 右側書頁圓角
                    );
                    return Container(
                      decoration: BoxDecoration(
                        color: notebook.coverColor,
                        borderRadius: radius,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withAlpha(50),
                            blurRadius: 8,
                            offset: const Offset(3, 5),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: radius,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            // 第一頁預覽 (左邊留一條封面色書脊)
                            Positioned(
                              left: 6,
                              top: 0,
                              right: 0,
                              bottom: 0,
                              child: NotebookThumbnail(
                                key: ValueKey('thumb_${notebook.id}'),
                                notebook: notebook,
                                logicalWidth: box.maxWidth,
                              ),
                            ),
                            // 左側書脊壓痕 (Spine Shadow)
                            Positioned(
                              left: 0,
                              top: 0,
                              bottom: 0,
                              width: 14,
                              child: DecoratedBox(
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
                          ],
                        ),
                      ),
                    );
                  },
                ),
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
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.cs.onSurface),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      s.notebookSubtitle(
                        notebook.pageCount,
                        notebook.lastViewedPageIndex + 1,
                        _formatDate(s, notebook.updatedAt),
                      ),
                      style: TextStyle(fontSize: 10, color: context.cs.onSurfaceVariant),
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
                itemBuilder: (ctx) => menuItems(s),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 選單項目 (清單模式的列也共用)
  static List<PopupMenuEntry<String>> menuItems(S s) => [
          PopupMenuItem(
            value: 'export',
            child: Row(
              children: [
                const Icon(Icons.picture_as_pdf_outlined, size: 18, color: Colors.blueAccent),
                const SizedBox(width: 8),
                Text(s.exportAsPdf, style: const TextStyle(fontSize: 13, color: Colors.blueAccent)),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'rename',
            child: Row(
              children: [
                const Icon(Icons.edit_outlined, size: 18),
                const SizedBox(width: 8),
                Text(s.rename, style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'duplicate',
            child: Row(
              children: [
                const Icon(Icons.copy_outlined, size: 18),
                const SizedBox(width: 8),
                Text(s.duplicate, style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'delete',
            child: Row(
              children: [
                const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                const SizedBox(width: 8),
                Text(s.delete, style: const TextStyle(fontSize: 13, color: Colors.redAccent)),
              ],
            ),
          ),
  ];

  String _formatDate(S s, DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 60) return s.minutesAgo(diff.inMinutes);
    if (diff.inHours < 24) return s.hoursAgo(diff.inHours);
    return '${dt.month}/${dt.day}';
  }
}