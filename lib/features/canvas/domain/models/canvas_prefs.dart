// lib/features/canvas/domain/models/canvas_prefs.dart
import 'package:flutter/material.dart';

import 'brush_settings.dart';
import 'page_layout_mode.dart';

/// 畫布的使用者偏好：每次開 App 都要還原的設定
///  - 頁面顯示方式 (單頁 / 往下連續 / 往右連續)
///  - 畫筆設定 (粗細 / 壓感 / 平滑 / 防手抖)
///  - 目前顏色、最近使用顏色、收藏顏色
class CanvasPrefs {
  final BrushSettings brush;
  final Color strokeColor;
  final PageLayoutMode layoutMode;
  final List<Color> recentColors;

  /// null = 沒存過，使用控制器內建的預設收藏色
  final List<Color>? favoriteColors;

  const CanvasPrefs({
    this.brush = BrushSettings.fountainPen,
    this.strokeColor = Colors.black,
    this.layoutMode = PageLayoutMode.single,
    this.recentColors = const [],
    this.favoriteColors,
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
    );
  }
}
