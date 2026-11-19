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

  /// 螢光筆自己的筆刷 / 顏色 (與一般筆分開記)
  final BrushSettings highlighterBrush;
  final Color highlighterColor;
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

  /// 橡皮擦可以擦的對象 (一般筆 / 螢光筆)
  final bool eraseTargetPen;
  final bool eraseTargetHighlighter;

  /// 套索可以圈選的對象 (一般筆 / 螢光筆 / 圖片)
  final bool lassoTargetPen;
  final bool lassoTargetHighlighter;
  final bool lassoTargetImage;

  /// 防誤觸：開啟後只有筆可以畫 / 操作，單指改為平移
  final bool palmRejection;

  /// 手勢：雙指輕點 = 復原、三指輕點 = 重做 (預設開啟)
  final bool gesturesEnabled;

  /// 截圖解析度：每個頁面單位對應幾個像素。0 = 自動 (跟隨螢幕 DPR 與目前縮放)
  final double screenshotScale;

  /// 截圖解析度的可選值 (0 = 自動)
  static const List<double> screenshotScaleOptions = [0, 1, 2, 3, 4, 6];

  const CanvasPrefs({
    this.brush = BrushSettings.fountainPen,
    this.strokeColor = Colors.black,
    this.highlighterBrush = BrushSettings.highlighterPreset,
    this.highlighterColor = const Color(0xFFFFEB3B),
    this.layoutMode = PageLayoutMode.single,
    this.recentColors = const [],
    this.favoriteColors,
    this.lastBlankBackground = PageBackground.standard,
    this.newPageStyle = NewPageStyle.lastUsed,
    this.recentBackgrounds = const [],
    this.eraserRadius = 15.0,
    this.eraseTargetPen = true,
    this.eraseTargetHighlighter = true,
    this.lassoTargetPen = true,
    this.lassoTargetHighlighter = true,
    this.lassoTargetImage = true,
    this.palmRejection = false,
    this.gesturesEnabled = true,
    this.screenshotScale = 0,
  });

  /// App 啟動時 (main) 讀進來；之後 CanvasController 建立時套用，
  /// 設定一有變動控制器就會更新這份，所以重新開啟筆記也維持最新值。
  static CanvasPrefs initial = const CanvasPrefs();

  Map<String, dynamic> toJson() => {
    'brush': brush.toJson(),
    'strokeColor': strokeColor.toARGB32(),
    'highlighterBrush': highlighterBrush.toJson(),
    'highlighterColor': highlighterColor.toARGB32(),
    'layoutMode': layoutMode.name,
    'recentColors': recentColors.map((c) => c.toARGB32()).toList(),
    if (favoriteColors != null)
      'favoriteColors': favoriteColors!.map((c) => c.toARGB32()).toList(),
    'lastBlankBackground': lastBlankBackground.toJson(),
    'newPageStyle': newPageStyle.name,
    'recentBackgrounds': recentBackgrounds.map((b) => b.toJson()).toList(),
    'eraserRadius': eraserRadius,
    'eraseTargetPen': eraseTargetPen,
    'eraseTargetHighlighter': eraseTargetHighlighter,
    'lassoTargetPen': lassoTargetPen,
    'lassoTargetHighlighter': lassoTargetHighlighter,
    'lassoTargetImage': lassoTargetImage,
    'palmRejection': palmRejection,
    'gesturesEnabled': gesturesEnabled,
    'screenshotScale': screenshotScale,
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
    final hlJson = json['highlighterBrush'];
    final hlColor = json['highlighterColor'];

    return CanvasPrefs(
      brush: brushJson is Map
          ? BrushSettings.fromJson(Map<String, dynamic>.from(brushJson))
          : BrushSettings.fountainPen,
      strokeColor: color is int ? Color(color) : Colors.black,
      // 螢光筆一律保持 isHighlighter = true (舊存檔沒有這欄位也一樣)
      highlighterBrush: (hlJson is Map
              ? BrushSettings.fromJson(Map<String, dynamic>.from(hlJson))
              : BrushSettings.highlighterPreset)
          .copyWith(isHighlighter: true),
      highlighterColor: hlColor is int ? Color(hlColor) : const Color(0xFFFFEB3B),
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
      // 舊存檔沒有這些欄位 → 預設全開；全關的存檔視為全開 (避免工具失效)
      eraseTargetPen: json['eraseTargetPen'] != false ||
          json['eraseTargetHighlighter'] == false,
      eraseTargetHighlighter: json['eraseTargetHighlighter'] != false ||
          json['eraseTargetPen'] == false,
      lassoTargetPen: json['lassoTargetPen'] != false ||
          (json['lassoTargetHighlighter'] == false &&
              json['lassoTargetImage'] == false),
      lassoTargetHighlighter: json['lassoTargetHighlighter'] != false ||
          (json['lassoTargetPen'] == false && json['lassoTargetImage'] == false),
      lassoTargetImage: json['lassoTargetImage'] != false ||
          (json['lassoTargetPen'] == false &&
              json['lassoTargetHighlighter'] == false),
      palmRejection: json['palmRejection'] == true,
      gesturesEnabled: json['gesturesEnabled'] != false,
      screenshotScale: json['screenshotScale'] is num
          ? (json['screenshotScale'] as num).toDouble().clamp(0.0, 8.0).toDouble()
          : 0,
    );
  }
}
