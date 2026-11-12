// lib/features/canvas/domain/models/canvas_prefs.dart
import 'package:flutter/material.dart';

import '../../../document/domain/page_background.dart';
import 'brush_settings.dart';
import 'page_layout_mode.dart';

/// 新增空白頁時，背景要用哪一種
enum NewPageStyle {
  /// 沿用「上次在頁面背景選單修改好的樣式」
  lastUsed,

  /// 跟目前所在頁面 (空白頁) 一樣
  currentPage,
}

/// 畫布的使用者偏好：每次開 App 都要還原的設定
///  - 頁面顯示方式 (單頁 / 往下連續 / 往右連續)
///  - 畫筆設定 (粗細 / 壓感 / 平滑 / 防手抖)
///  - 目前顏色、最近使用顏色、收藏顏色
///  - 空白頁背景：上次修改的樣式、新增空白頁時的取用方式
class CanvasPrefs {
  final BrushSettings brush;
  final Color strokeColor;
  final PageLayoutMode layoutMode;
  final List<Color> recentColors;

  /// null = 沒存過，使用控制器內建的預設收藏色
  final List<Color>? favoriteColors;

  /// 上次在「頁面背景」選單修改好的樣式 (新增空白頁 / 新增筆記本時使用)
  final PageBackground lastBlankBackground;

  /// 新增空白頁時的樣式來源
  final NewPageStyle newPageStyle;

  /// 最近使用的頁面背景 (最新的在前，與「最近使用顏色」相同的概念)
  final List<PageBackground> recentBackgrounds;

  /// 橡皮擦半徑 (螢幕像素)
  final double eraserRadius;

  const CanvasPrefs({
    this.brush = BrushSettings.fountainPen,
    this.strokeColor = Colors.black,
    this.layoutMode = PageLayoutMode.single,
    this.recentColors = const [],
    this.favoriteColors,
    this.lastBlankBackground = PageBackground.standard,
    this.newPageStyle = NewPageStyle.lastUsed,
    this.recentBackgrounds = const [],
    this.eraserRadius = 15.0,
  });

  /// App 啟動時 (main) 讀進來；之後 CanvasController 建立時套用，
  /// 設定一有變動控制器就會更新這份，所以重新開啟筆記也維持最新值。
  static CanvasPrefs initial = const CanvasPrefs();

  Map<String, dynamic> toJson() => {
    'brush': brush.toJson(),
    'strokeColor': strokeColor.toARGB32(),
    'layoutMode': layoutMode.name,
    'recentColors': recentColors.map((c) => c.toARGB32()).toList(),
    if (favoriteColors != null)
      'favoriteColors': favoriteColors!.map((c) => c.toARGB32()).toList(),
    'lastBlankBackground': lastBlankBackground.toJson(),
    'newPageStyle': newPageStyle.name,
    'recentBackgrounds': recentBackgrounds.map((b) => b.toJson()).toList(),
    'eraserRadius': eraserRadius,
  };

  factory CanvasPrefs.fromJson(Map<String, dynamic> json) {
    List<Color>? colors(Object? v) {
      if (v is! List) return null;
      return [
        for (final e in v)
          if (e is int) Color(e),
      ];
    }

    final brushJson = json['brush'];
    final color = json['strokeColor'];
    final modeName = json['layoutMode'];

    return CanvasPrefs(
      brush: brushJson is Map
          ? BrushSettings.fromJson(Map<String, dynamic>.from(brushJson))
          : BrushSettings.fountainPen,
      strokeColor: color is int ? Color(color) : Colors.black,
      layoutMode: PageLayoutMode.values.firstWhere(
        (m) => m.name == modeName,
        orElse: () => PageLayoutMode.single,
      ),
      recentColors: colors(json['recentColors']) ?? const [],
      favoriteColors: colors(json['favoriteColors']),
      lastBlankBackground:
          PageBackground.fromJson(json['lastBlankBackground']),
      newPageStyle: NewPageStyle.values.firstWhere(
        (s) => s.name == json['newPageStyle'],
        orElse: () => NewPageStyle.lastUsed,
      ),
      recentBackgrounds: json['recentBackgrounds'] is List
          ? (json['recentBackgrounds'] as List)
              .map(PageBackground.fromJson)
              .toList()
          : const [],
      eraserRadius: json['eraserRadius'] is num
          ? (json['eraserRadius'] as num).toDouble().clamp(5.0, 60.0).toDouble()
          : 15.0,
    );
  }
}
