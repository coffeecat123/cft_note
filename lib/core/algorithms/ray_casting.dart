// lib/core/algorithms/ray_casting.dart
import 'dart:ui';

class RayCasting {
  /// 判斷點 [point] 是否在多邊形 [polygon] 內部
  static bool isPointInPolygon(Offset point, List<Offset> polygon) {
    if (polygon.length < 3) return false;

    int intersectCount = 0;
    for (int i = 0; i < polygon.length; i++) {
      final p1 = polygon[i];
      final p2 = polygon[(i + 1) % polygon.length];

      // 檢查水平射線是否與多邊形邊相交
      if ((p1.dy > point.dy) != (p2.dy > point.dy)) {
        final double xIntersection =
            (point.dy - p1.dy) * (p2.dx - p1.dx) / (p2.dy - p1.dy) + p1.dx;
        if (point.dx < xIntersection) {
          intersectCount++;
        }
      }
    }
    // 奇數次相交表示在多邊形內部
    return intersectCount % 2 == 1;
  }
}