// lib/features/shelf/domain/models/notebook.dart
import 'package:flutter/material.dart';
import '../../../document/domain/note_page.dart';

class Notebook {
  final String id;
  String title;
  Color coverColor;
  DateTime updatedAt;
  List<NotePage> pages;
  int lastViewedPageIndex;
  String? folderId;
  List<double>? transformMatrix;

  Notebook({
    required this.id,
    required this.title,
    required this.coverColor,
    required this.updatedAt,
    List<NotePage>? pages,
    this.lastViewedPageIndex = 0,
    this.folderId,
    this.transformMatrix,
  }) : pages = pages ?? [NotePage(id: 'page_1')];

  // ★ 補回此 getter：取得總頁數
  int get pageCount => pages.length;

  Notebook copyWith({
    String? title,
    Color? coverColor,
    List<NotePage>? pages,
    int? lastViewedPageIndex,
    String? folderId,
    List<double>? transformMatrix,
  }) {
    return Notebook(
      id: 'nb_${DateTime.now().millisecondsSinceEpoch}',
      title: title ?? this.title,
      coverColor: coverColor ?? this.coverColor,
      updatedAt: DateTime.now(),
      lastViewedPageIndex: lastViewedPageIndex ?? this.lastViewedPageIndex,
      folderId: folderId ?? this.folderId,
      transformMatrix: transformMatrix ?? this.transformMatrix,
      pages: pages ?? this.pages,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'coverColor': coverColor.toARGB32(),
    'updatedAt': updatedAt.toIso8601String(),
    'lastViewedPageIndex': lastViewedPageIndex,
    'folderId': folderId,
    'transformMatrix': transformMatrix, // ★ 存檔矩陣
    'pages': pages.map((p) => p.toJson()).toList(),
  };

  factory Notebook.fromJson(Map<String, dynamic> json) {
    return Notebook(
      id: json['id'] as String,
      title: json['title'] as String,
      coverColor: Color(json['coverColor'] as int),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
      lastViewedPageIndex: (json['lastViewedPageIndex'] as int?) ?? 0,
      folderId: json['folderId'] as String?,
      transformMatrix: (json['transformMatrix'] as List?)?.map((e) => (e as num).toDouble()).toList(), // ★ 讀取矩陣
      pages: (json['pages'] as List? ?? []).map((p) => NotePage.fromJson(p as Map<String, dynamic>)).toList(),
    );
  }

  static const List<Color> presetCoverColors = [
    Color(0xFF2B3A4A),
    Color(0xFF5E7153),
    Color(0xFF8B4F58),
    Color(0xFFC97C5D),
    Color(0xFF3A3D40),
    Color(0xFF6B5B95),
  ];
}