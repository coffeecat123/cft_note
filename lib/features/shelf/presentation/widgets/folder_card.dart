// lib/features/shelf/presentation/widgets/folder_card.dart
import 'package:flutter/material.dart';
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
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 擬真文件夾外觀
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFE8F0FE), // 經典清爽淺藍色夾
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFD2E3FC), width: 1.5),
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
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.black87),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$itemCount 個項目',
                      style: TextStyle(fontSize: 10, color: Colors.grey[600]),
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
                itemBuilder: (ctx) => menuItems(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 選單項目 (清單模式的列也共用)
  static List<PopupMenuEntry<String>> menuItems() => [
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
            value: 'delete',
            child: Row(
              children: [
                Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                SizedBox(width: 8),
                Text('刪除資料夾', style: TextStyle(fontSize: 13, color: Colors.redAccent)),
              ],
            ),
          ),
  ];
}