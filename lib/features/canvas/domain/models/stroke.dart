// lib/features/canvas/domain/models/stroke.dart
import 'dart:ui';
import 'package:perfect_freehand/perfect_freehand.dart';
import '../../../../core/algorithms/segment_math.dart';
import 'brush_settings.dart';
import 'stroke_geometry.dart';

/// perfect_freehand 給的輪廓是一圈「多邊形頂點」，直接 lineTo 連起來會是很多條直線拼成的
/// (放大後看得到稜角、轉彎處有尖刺)。改成官方建議的畫法：
/// 以每個頂點當控制點、相鄰頂點的中點當終點，連成二次貝茲曲線，邊緣就是圓滑的。
/// 預覽中的筆劃與完成後的筆劃共用這一個函式，所以放開筆時外觀不會跳。
Path smoothOutlinePath(List<Offset> pts) {
  final path = Path();
  final n = pts.length;
  if (n == 0) return path;
  if (n < 3) {
    path.moveTo(pts.first.dx, pts.first.dy);
    for (int i = 1; i < n; i++) {
      path.lineTo(pts[i].dx, pts[i].dy);
    }
    path.close();
    return path;
  }
  path.moveTo(pts[0].dx, pts[0].dy);
  for (int i = 0; i < n; i++) {
    final p = pts[i];
    final q = pts[(i + 1) % n];
    path.quadraticBezierTo(
      p.dx,
      p.dy,
      (p.dx + q.dx) / 2,
      (p.dy + q.dy) / 2,
    );
  }
  path.close();
  return path;
}

class Stroke {
  final List<PointVector> points;
  final Color color;
  final BrushSettings settings;

  Stroke({
    required this.points,
    required this.color,
    required this.settings,
  });

  // ------------------------------------------------------------
  // 快取：外框 (bounds) 與筆劃輪廓 Path
  // 筆劃被移動時，points 內的 PointVector 會被「整個換新物件」，
  // 因此用 長度 + 首尾元素的 identity 就能偵測到失效，不需手動 invalidate。
  // ------------------------------------------------------------
  Rect? _bounds;
  Path? _outline;
  int _cacheLen = -1;
  PointVector? _cacheFirst;
  PointVector? _cacheLast;

  bool get _cacheValid =>
      _cacheLen == points.length &&
      (points.isEmpty ||
          (identical(_cacheFirst, points.first) &&
              identical(_cacheLast, points.last)));

  void _refreshCache() {
    if (_cacheValid) return;
    _bounds = null;
    _outline = null;
    _cacheLen = points.length;
    _cacheFirst = points.isEmpty ? null : points.first;
    _cacheLast = points.isEmpty ? null : points.last;
  }

  /// 手動讓快取失效 (一般不需要呼叫)
  void invalidate() {
    _cacheLen = -1;
  }

  /// 所有點的外框 (不含筆刷粗細)
  Rect get bounds {
    _refreshCache();
    return _bounds ??= _computeBounds();
  }

  /// 筆劃輪廓 Path (perfect_freehand 運算很貴，只算一次)
  Path get outlinePath {
    _refreshCache();
    return _outline ??= _buildOutline();
  }

  Rect _computeBounds() {
    if (points.isEmpty) return Rect.zero;
    double minX = points.first.x, maxX = minX;
    double minY = points.first.y, maxY = minY;
    for (final p in points) {
      if (p.x < minX) minX = p.x;
      if (p.x > maxX) maxX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.y > maxY) maxY = p.y;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  Path _buildOutline() {
    if (points.isEmpty) return Path();
    // 與預覽共用 StrokeGeometry：圓 + 連接塊的聯集，無缺口、放開筆時外觀不會跳
    return StrokeGeometry.pathFor(points, settings);
  }

  // ------------------------------------------------------------
  // 橡皮擦碰撞：線段(膠囊體)對線段，不再只比對取樣點
  // ------------------------------------------------------------
  /// 實際筆寬約為 size 乘上壓感變化，取半寬的保守估計
  static const double _halfWidthFactor = 0.3;

  /// 橡皮擦從 [a] 掃到 [b]、半徑 [radius] (皆為頁面座標) 是否碰到此筆劃。
  bool hitsCapsule(Offset a, Offset b, double radius) {
    if (points.isEmpty) return false;
    final reach = radius + settings.size * _halfWidthFactor;

    // 外框快速排除
    final sweep = Rect.fromPoints(a, b).inflate(reach);
    if (!sweep.overlaps(bounds.inflate(1.0))) return false;

    final r2 = reach * reach;
    if (points.length == 1) {
      final p = points.first;
      return SegmentMath.pointToSegmentDistSq(p.x, p.y, a.dx, a.dy, b.dx, b.dy) <=
          r2;
    }
    for (int i = 0; i < points.length - 1; i++) {
      final p = points[i], q = points[i + 1];
      if (SegmentMath.segmentToSegmentDistSq(
            p.x,
            p.y,
            q.x,
            q.y,
            a.dx,
            a.dy,
            b.dx,
            b.dy,
          ) <=
          r2) {
        return true;
      }
    }
    return false;
  }

  // ------------------------------------------------------------
  // 深層複製：points 為新 list、PointVector 為新物件，與原筆劃完全獨立
  // ------------------------------------------------------------
  Stroke copy() => Stroke(
    points: points.map((p) => PointVector(p.x, p.y, p.pressure)).toList(),
    color: color,
    settings: settings,
  );

  // ------------------------------------------------------------
  // JSON
  // ------------------------------------------------------------
  static double _finite(double? v, [double fallback = 0.0]) =>
      (v != null && v.isFinite) ? v : fallback;

  Map<String, dynamic> toJson() => {
    // NaN / Infinity 會讓 JSON 編碼失敗或寫出壞檔 → 過濾
    'points': points
        .where((p) => p.x.isFinite && p.y.isFinite)
        .map((p) => {'x': p.x, 'y': p.y, 'p': _finite(p.pressure, 0.5)})
        .toList(),
    'color': color.toARGB32(),
    'size': settings.size,
    'thinning': settings.thinning,
    'smoothing': settings.smoothing,
    'streamline': settings.streamline,
  };

  factory Stroke.fromJson(Map<String, dynamic> json) {
    final pointsList = (json['points'] as List)
        .map((p) => PointVector(
              (p['x'] as num).toDouble(),
              (p['y'] as num).toDouble(),
              (p['p'] as num?)?.toDouble() ?? 0.5,
            ))
        .toList();

    return Stroke(
      points: pointsList,
      color: Color(json['color'] as int),
      settings: BrushSettings(
        size: (json['size'] as num?)?.toDouble() ?? 5.0,
        thinning: (json['thinning'] as num?)?.toDouble() ?? 0.6,
        smoothing: (json['smoothing'] as num?)?.toDouble() ?? 0.5,
        streamline: (json['streamline'] as num?)?.toDouble() ?? 0.5,
      ),
    );
  }
}
