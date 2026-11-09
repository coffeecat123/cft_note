// lib/core/algorithms/segment_math.dart
// 純 Dart 線段幾何 (不依賴 Flutter，可直接在 VM 上單元測試)
import 'dart:math' as math;

class SegmentMath {
  SegmentMath._();

  /// 點 (px,py) 到線段 AB 的距離平方 (A==B 時退化為點對點)
  static double pointToSegmentDistSq(
    double px,
    double py,
    double ax,
    double ay,
    double bx,
    double by,
  ) {
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    double t = 0;
    if (len2 > 0) {
      t = ((px - ax) * dx + (py - ay) * dy) / len2;
      if (t < 0) {
        t = 0;
      } else if (t > 1) {
        t = 1;
      }
    }
    final ex = px - (ax + t * dx);
    final ey = py - (ay + t * dy);
    return ex * ex + ey * ey;
  }

  static double _orient(
    double ax,
    double ay,
    double bx,
    double by,
    double cx,
    double cy,
  ) => (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);

  static bool _onSegment(
    double ax,
    double ay,
    double bx,
    double by,
    double px,
    double py,
  ) =>
      px >= math.min(ax, bx) &&
      px <= math.max(ax, bx) &&
      py >= math.min(ay, by) &&
      py <= math.max(ay, by);

  /// 線段 AB 與 CD 是否相交 (含端點接觸、共線重疊)
  static bool segmentsIntersect(
    double ax,
    double ay,
    double bx,
    double by,
    double cx,
    double cy,
    double dx,
    double dy,
  ) {
    final o1 = _orient(ax, ay, bx, by, cx, cy);
    final o2 = _orient(ax, ay, bx, by, dx, dy);
    final o3 = _orient(cx, cy, dx, dy, ax, ay);
    final o4 = _orient(cx, cy, dx, dy, bx, by);

    if (((o1 > 0 && o2 < 0) || (o1 < 0 && o2 > 0)) &&
        ((o3 > 0 && o4 < 0) || (o3 < 0 && o4 > 0))) {
      return true;
    }
    if (o1 == 0 && _onSegment(ax, ay, bx, by, cx, cy)) return true;
    if (o2 == 0 && _onSegment(ax, ay, bx, by, dx, dy)) return true;
    if (o3 == 0 && _onSegment(cx, cy, dx, dy, ax, ay)) return true;
    if (o4 == 0 && _onSegment(cx, cy, dx, dy, bx, by)) return true;
    return false;
  }

  /// 兩線段最短距離的平方 (相交為 0)
  static double segmentToSegmentDistSq(
    double ax,
    double ay,
    double bx,
    double by,
    double cx,
    double cy,
    double dx,
    double dy,
  ) {
    if (segmentsIntersect(ax, ay, bx, by, cx, cy, dx, dy)) return 0;
    return math.min(
      math.min(
        pointToSegmentDistSq(ax, ay, cx, cy, dx, dy),
        pointToSegmentDistSq(bx, by, cx, cy, dx, dy),
      ),
      math.min(
        pointToSegmentDistSq(cx, cy, ax, ay, bx, by),
        pointToSegmentDistSq(dx, dy, ax, ay, bx, by),
      ),
    );
  }
}
