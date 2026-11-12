// lib/features/document/domain/page_background.dart
//
// 空白頁的背景：紙張顏色 + 格線 (無 / 橫線 / 直線 / 方格)。
// PDF 頁面永遠使用 PDF 本身的底圖，不套用這份設定。
import 'dart:ui';

/// 格線樣式
enum GridMode {
  none,
  horizontal,
  vertical,
  both,
}

class PageBackground {
  /// 格距 (頁面座標，單位與紙張 595 x 842 相同)
  static const double minSpacing = 12;
  static const double maxSpacing = 80;
  static const double defaultSpacing = 32;

  final Color color;
  final GridMode grid;
  final double spacing;

  const PageBackground({
    this.color = const Color(0xFFFFFFFF),
    this.grid = GridMode.horizontal,
    this.spacing = defaultSpacing,
  });

  /// 預設樣式 = 白紙 + 橫線。舊存檔沒有這個欄位時也用它。
  static const PageBackground standard = PageBackground();

  /// 紙張顏色預設選項 (淺色紙 → 深色紙)
  static const List<Color> presetColors = [
    Color(0xFFFFFFFF), // 白
    Color(0xFFFFF8E7), // 米白
    Color(0xFFFFF9C4), // 淡黃 (便條紙)
    Color(0xFFF1F3F4), // 淺灰
    Color(0xFFE8F1FB), // 淺藍
    Color(0xFFE6F4EA), // 淺綠
    Color(0xFF3A3A3C), // 深灰
    Color(0xFF121212), // 近黑
  ];

  /// 格線顏色：淺色紙用淡灰，深色紙用淡白，兩種都看得清楚但不搶筆跡
  Color get gridColor => color.computeLuminance() > 0.5
      ? const Color(0x289E9E9E)
      : const Color(0x30FFFFFF);

  PageBackground copyWith({Color? color, GridMode? grid, double? spacing}) =>
      PageBackground(
        color: color ?? this.color,
        grid: grid ?? this.grid,
        spacing: spacing ?? this.spacing,
      );

  Map<String, dynamic> toJson() => {
        'color': color.toARGB32(),
        'grid': grid.name,
        'spacing': spacing,
      };

  factory PageBackground.fromJson(Object? json) {
    if (json is! Map) return standard;
    final c = json['color'];
    final g = json['grid'];
    final sp = json['spacing'];
    return PageBackground(
      color: c is int ? Color(c) : standard.color,
      grid: GridMode.values.firstWhere(
        (m) => m.name == g,
        orElse: () => standard.grid,
      ),
      spacing: sp is num
          ? sp.toDouble().clamp(minSpacing, maxSpacing)
          : defaultSpacing,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PageBackground &&
      other.color == color &&
      other.grid == grid &&
      other.spacing == spacing;

  @override
  int get hashCode => Object.hash(color, grid, spacing);
}

/// 畫布、縮圖、截圖、PDF 匯出共用的背景繪製：確保各處看到的一模一樣。
/// 格線直接鋪滿整張紙 (邊到邊)，從第一個格距開始，不留邊界。
class PageBackgroundPainter {
  PageBackgroundPainter._();

  static void paintPaper(Canvas canvas, Rect pageRect, PageBackground bg) {
    canvas.drawRect(pageRect, Paint()..color = bg.color);
  }

  /// [visible]：只畫與這個範圍 (頁面座標) 重疊的線，截圖大頁面時省時間
  static void paintGrid(
    Canvas canvas,
    Size pageSize,
    PageBackground bg, {
    double strokeWidth = 1.0,
    Rect? visible,
    Color? lineColor, // 預覽用：縮很小時需要較深的線才看得到
  }) {
    if (bg.grid == GridMode.none) return;
    final paint = Paint()
      ..color = lineColor ?? bg.gridColor
      ..strokeWidth = strokeWidth;

    for (final (from, to) in gridLines(pageSize, bg)) {
      if (visible != null) {
        final horizontal = from.dy == to.dy;
        if (horizontal) {
          if (from.dy < visible.top - 1 || from.dy > visible.bottom + 1) continue;
        } else {
          if (from.dx < visible.left - 1 || from.dx > visible.right + 1) continue;
        }
      }
      canvas.drawLine(from, to, paint);
    }
  }

  /// 每條線的 (起點, 終點)。畫布與 PDF 匯出共用，位置完全相同。
  static List<(Offset, Offset)> gridLines(Size pageSize, PageBackground bg) {
    final lines = <(Offset, Offset)>[];
    if (bg.grid == GridMode.none) return lines;

    final w = pageSize.width;
    final h = pageSize.height;
    final step = bg.spacing;

    if (bg.grid == GridMode.horizontal || bg.grid == GridMode.both) {
      for (int i = 1; i * step < h; i++) {
        final y = i * step;
        lines.add((Offset(0, y), Offset(w, y)));
      }
    }
    if (bg.grid == GridMode.vertical || bg.grid == GridMode.both) {
      for (int i = 1; i * step < w; i++) {
        final x = i * step;
        lines.add((Offset(x, 0), Offset(x, h)));
      }
    }
    return lines;
  }
}
