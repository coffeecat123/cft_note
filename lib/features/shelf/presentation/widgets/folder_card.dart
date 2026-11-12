// lib/features/shelf/presentation/widgets/folder_card.dart
import 'package:flutter/material.dart';
import '../../../../app/theme/app_theme.dart';
import '../../../../core/i18n/app_strings.dart';
import '../../domain/models/note_folder.dart';

class FolderCard extends StatelessWidget {
  final NoteFolder folder;
  final int itemCount;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const FolderCard({
    super.key,
    required this.folder,
    required this.itemCount,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final colors = context.appColors;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 擬真文件夾外觀
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: colors.folderCard, // 經典清爽淺藍色夾 (深色主題為深藍)
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colors.folderCardBorder, width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(20),
                    blurRadius: 6,
                    offset: const Offset(2, 4),
                  ),
                ],
              ),
              child: Center(
                child: Icon(
                  Icons.folder_rounded,
                  size: 54,
                  color: Colors.blueAccent.withAlpha(200),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),

          // 資料夾名稱與項目數量
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      folder.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.cs.onSurface),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      s.itemCount(itemCount),
                      style: TextStyle(fontSize: 10, color: context.cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.more_vert, size: 18, color: Colors.grey),
                onSelected: (val) {
                  if (val == 'rename') onRename();
                  if (val == 'delete') onDelete();
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
            value: 'delete',
            child: Row(
              children: [
                const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                const SizedBox(width: 8),
                Text(s.deleteFolder, style: const TextStyle(fontSize: 13, color: Colors.redAccent)),
              ],
            ),
          ),
  ];
}