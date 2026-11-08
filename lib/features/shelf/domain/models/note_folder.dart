// lib/features/shelf/domain/models/note_folder.dart
class NoteFolder {
  final String id;
  String name;
  DateTime createdAt;
  String? parentFolderId; // 支援子資料夾 (null 代表最外層)

  NoteFolder({
    required this.id,
    required this.name,
    required this.createdAt,
    this.parentFolderId,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'parentFolderId': parentFolderId,
  };

  factory NoteFolder.fromJson(Map<String, dynamic> json) => NoteFolder(
    id: json['id'] as String,
    name: json['name'] as String,
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    parentFolderId: json['parentFolderId'] as String?,
  );
}