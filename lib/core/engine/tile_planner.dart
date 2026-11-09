// lib/core/engine/tile_planner.dart
// PDF 分塊渲染的「純計算」部分：決定底圖倍率、圖塊範圍與解析度。
// 不依賴 Flutter，可直接在 VM 上單元測試。
import 'dart:math' as math;

class TilePlan {
  final double left, top, right, bottom; // 頁面座標
  final double scale; // 每個頁面單位對應的像素數
  const TilePlan(this.left, this.top, this.right, this.bottom, this.scale);

  double get width => right - left;
  double get height => bottom - top;
}

class TilePlanner {
  TilePlanner._();

  static const double maxSide = 4096.0; // 單邊像素上限
  static const double maxPixels = 16e6; // 約 64MB RGBA
  static const double margin = 0.3; // 可視範圍外多渲染的比例

  /// 底圖倍率：DPR，且整頁像素不超過上限
  static double baseScale({
    required double pageW,
    required double pageH,
    required double dpr,
  }) {
    final capSide = maxSide / math.max(pageW, pageH);
    final capPixels = math.sqrt(maxPixels / (pageW * pageH));
    return math.min(dpr, math.min(capSide, capPixels));
  }

  static bool fits(double w, double h, double scale) {
    final pw = w * scale, ph = h * scale;
    return pw <= maxSide && ph <= maxSide && pw * ph <= maxPixels;
  }

  /// 依可視範圍 (頁面座標，已裁在紙張內) 與縮放，決定圖塊範圍與倍率
  static TilePlan plan({
    required double pageW,
    required double pageH,
    required double visLeft,
    required double visTop,
    required double visRight,
    required double visBottom,
    required double zoom, // 畫布縮放 (1.0 = 100%)
    required double dpr,
  }) {
    double scale = zoom * dpr;
    final vw = visRight - visLeft, vh = visBottom - visTop;
    final mx = vw * margin, my = vh * margin;

    final ml = math.max(0.0, visLeft - mx);
    final mt = math.max(0.0, visTop - my);
    final mr = math.min(pageW, visRight + mx);
    final mb = math.min(pageH, visBottom + my);

    double l = visLeft, t = visTop, r = visRight, b = visBottom;
    if (fits(mr - ml, mb - mt, scale)) {
      l = ml;
      t = mt;
      r = mr;
      b = mb;
    }
    final w = r - l, h = b - t;
    if (!fits(w, h, scale)) {
      // 可視區域本身就太大 → 降倍率
      scale = math.min(
        scale,
        math.min(
          maxSide / w,
          math.min(maxSide / h, math.sqrt(maxPixels / (w * h))),
        ),
      );
    }
    return TilePlan(l, t, r, b, scale);
  }

  /// 圖塊 (outer) 是否涵蓋可視範圍 (inner)
  static bool covers({
    required double outerL,
    required double outerT,
    required double outerR,
    required double outerB,
    required double innerL,
    required double innerT,
    required double innerR,
    required double innerB,
  }) =>
      outerL <= innerL + 0.01 &&
      outerT <= innerT + 0.01 &&
      outerR >= innerR - 0.01 &&
      outerB >= innerB - 0.01;
}
