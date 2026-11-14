// lib/core/algorithms/rot_frame.dart
//
// 「繞自己中心旋轉的矩形」：圖片 / 套索調整大小的外框共用。
// rect 是未旋轉時的矩形 (頁面座標)，rotation 是繞 rect.center 的弧度 (順時針為正，與畫面一致)。
import 'dart:math' as math;
import 'dart:ui';

class RotFrame {
  final Rect rect;
  final double rotation;
  const RotFrame(this.rect, this.rotation);

  Offset get center => rect.center;

  static Offset rotate(Offset v, double a) {
    final c = math.cos(a), s = math.sin(a);
    return Offset(v.dx * c - v.dy * s, v.dx * s + v.dy * c);
  }

  /// 未旋轉座標 → 頁面座標
  Offset toScene(Offset local) => center + rotate(local - center, rotation);

  /// 頁面座標 → 未旋轉座標
  Offset toLocal(Offset scene) => center + rotate(scene - center, -rotation);

  bool contains(Offset scene) => rect.contains(toLocal(scene));

  /// 左上、右上、右下、左下 (旋轉後的頁面座標)
  List<Offset> get corners => [
    toScene(rect.topLeft),
    toScene(rect.topRight),
    toScene(rect.bottomRight),
    toScene(rect.bottomLeft),
  ];

  Offset get deleteHandle => toScene(rect.topRight);
  Offset get scaleHandle => toScene(rect.bottomRight);

  /// 旋轉握把：上邊中點再往外 [offset] (頁面單位)
  Offset rotateHandle(double offset) =>
      toScene(Offset(rect.center.dx, rect.top - offset));

  /// 旋轉後的軸對齊外框
  Rect get bounds {
    final c = corners;
    double minX = c[0].dx, maxX = minX, minY = c[0].dy, maxY = minY;
    for (final p in c) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// 角度正規化到 (-π, π]
  static double normalize(double a) {
    while (a > math.pi) {
      a -= 2 * math.pi;
    }
    while (a <= -math.pi) {
      a += 2 * math.pi;
    }
    return a;
  }

  /// 接近 45° 的倍數 (預設 ±3°) 就吸附，方便轉回正向
  static double snap(double a, {double tolDeg = 3.0}) {
    final step = math.pi / 4;
    final nearest = (a / step).roundToDouble() * step;
    if ((a - nearest).abs() <= tolDeg * math.pi / 180) return normalize(nearest);
    return normalize(a);
  }
}
