// lib/features/shelf/domain/models/note_folder.dart
class NoteFolder {
  final String id;
  String name;
  DateTime createdAt;
  DateTime updatedAt; // 最後修改時間 (改名 / 內容異動)，供排序使用
  String? parentFolderId; // 支援子資料夾 (null 代表最外層)

  NoteFolder({
    required this.id,
    required this.name,
    required this.createdAt,
    DateTime? updatedAt,
    this.parentFolderId,
  }) : updatedAt = updatedAt ?? createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'parentFolderId': parentFolderId,
  };

  factory NoteFolder.fromJson(Map<String, dynamic> json) {
    final created =
        DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now();
    return NoteFolder(
      id: json['id'] as String,
      name: json['name'] as String,
      createdAt: created,
      // 舊存檔沒有 updatedAt → 以建立時間代替
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? created,
      parentFolderId: json['parentFolderId'] as String?,
    );
  }
}