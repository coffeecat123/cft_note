// lib/features/canvas/domain/models/stroke_geometry.dart
//
// 取代 perfect_freehand 的輪廓演算法 (類似 Ibis Paint 的作法)：
//
//  1. 輸入點 → 去重 / 清掉收筆抖動 → 零延遲的 [1,2,1] 平滑 (不會「尾巴追著手指跑」)
//  2. 以「相鄰點中點為端點、原始點為控制點」的二次貝茲曲線取得平滑中心線，
//     並沿線取樣出 (x, y, 半徑)。已經畫好的部分之後不會再被改動，
//     所以不會有「邊畫邊矯正」或「放開手又跳一次」。
//  3. 輪廓 = 每個取樣點的圓 + 相鄰取樣點之間的連接塊，全部同繞向、用 nonZero 填色，
//     等於「形狀聯集」：數學上不可能出現缺口，也沒有端帽方向造成的小鉤子 / 圓球。
//
// 預覽、完成後的筆劃、筆刷預覽共用同一份取樣，外觀完全一致。
import 'dart:math' as math;
import 'dart:ui';
import 'package:perfect_freehand/perfect_freehand.dart' show PointVector;
import 'brush_settings.dart';

/// 中心線上的一個取樣點：位置 + 該處筆劃半徑
class StrokeSample {
  final double x;
  final double y;
  final double r;
  const StrokeSample(this.x, this.y, this.r);
}

/// 中心線的一段：二次貝茲曲線 (起點、控制點、終點) 或直線，附起訖半徑
class StrokeSegment {
  final double x0, y0, cx, cy, x1, y1, r0, r1;
  final bool isLine;
  const StrokeSegment.quad(
      this.x0, this.y0, this.cx, this.cy, this.x1, this.y1, this.r0, this.r1)
      : isLine = false;
  const StrokeSegment.line(
      this.x0, this.y0, this.x1, this.y1, this.r0, this.r1)
      : cx = (x0 + x1) / 2,
        cy = (y0 + y1) / 2,
        isLine = true;

  /// 在 t = 0.5 切成兩段 (de Casteljau)，用來處理半徑變化太大的段落
  (StrokeSegment, StrokeSegment) split() {
    final rm = (r0 + r1) / 2;
    if (isLine) {
      final mx = (x0 + x1) / 2, my = (y0 + y1) / 2;
      return (
        StrokeSegment.line(x0, y0, mx, my, r0, rm),
        StrokeSegment.line(mx, my, x1, y1, rm, r1),
      );
    }
    final ax = (x0 + cx) / 2, ay = (y0 + cy) / 2;
    final bx = (cx + x1) / 2, by = (cy + y1) / 2;
    final mx = (ax + bx) / 2, my = (ay + by) / 2;
    return (
      StrokeSegment.quad(x0, y0, ax, ay, mx, my, r0, rm),
      StrokeSegment.quad(mx, my, bx, by, x1, y1, rm, r1),
    );
  }
}

class StrokeGeometry {
  StrokeGeometry._();

  static double _pressureOf(PointVector p) {
    final num? v = p.pressure;
    if (v == null || !v.isFinite) return 0.5;
    return v.toDouble().clamp(0.0, 1.0).toDouble();
  }

  /// 步驟 1~3：去重 → 清收筆抖動 → [1,2,1] 平滑。回傳平滑後的點與半徑。
  static ({List<double> xs, List<double> ys, List<double> rs}) _prepare(
    List<PointVector> pts,
    BrushSettings s,
  ) {
    final double size = s.size;
    final double thinning = s.thinning;

    double radiusOf(double p) {
      // 與 perfect_freehand 相同的壓力 → 半徑對應，既有筆刷手感不變
      final r = size * (0.5 - thinning * (0.5 - p));
      return math.max(r, math.max(size * 0.06, 0.15));
    }

    // ---- 1. 複製 + 去掉非法 / 完全重複的點 -------------------------------
    final xs = <double>[];
    final ys = <double>[];
    final rs = <double>[];
    for (final p in pts) {
      final x = p.x, y = p.y;
      if (!x.isFinite || !y.isFinite) continue;
      if (xs.isNotEmpty) {
        final dx = x - xs.last, dy = y - ys.last;
        if (dx * dx + dy * dy < 1e-6) continue;
      }
      xs.add(x);
      ys.add(y);
      rs.add(radiusOf(_pressureOf(p)));
    }

    // ---- 2. 清掉收筆抖動 ---------------------------------------------------
    // 手指離開螢幕前，最後幾點常常是「很短、而且往回折」的雜訊。
    // 只剪「短 (< 半個筆寬) 且 折返」的尾端點，刻意的急轉彎 (回程很長) 不受影響。
    final double jitter = size * 0.5;
    int guard = 8;
    while (xs.length > 2 && guard-- > 0) {
      final n = xs.length;
      final v1x = xs[n - 2] - xs[n - 3], v1y = ys[n - 2] - ys[n - 3];
      final v2x = xs[n - 1] - xs[n - 2], v2y = ys[n - 1] - ys[n - 2];
      final dot = v1x * v2x + v1y * v2y;
      final len2 = v2x * v2x + v2y * v2y;
      if (dot < 0 && len2 < jitter * jitter) {
        xs.removeLast();
        ys.removeLast();
        rs.removeLast();
      } else {
        break;
      }
    }

    // ---- 3. 零延遲平滑：[1,2,1]/4 低通，只動內部點，頭尾位置不動 ---------------
    // 次數由 smoothing / streamline 決定 (0 ~ 3 次)，不會像 streamline 那樣拖著尾巴跑。
    final int passes = ((s.smoothing + s.streamline) * 1.5).round().clamp(0, 3);
    for (int pass = 0; pass < passes && xs.length >= 3; pass++) {
      final n = xs.length;
      final nx = List<double>.from(xs);
      final ny = List<double>.from(ys);
      final nr = List<double>.from(rs);
      for (int i = 1; i < n - 1; i++) {
        nx[i] = (xs[i - 1] + 2 * xs[i] + xs[i + 1]) / 4;
        ny[i] = (ys[i - 1] + 2 * ys[i] + ys[i + 1]) / 4;
        nr[i] = (rs[i - 1] + 2 * rs[i] + rs[i + 1]) / 4;
      }
      for (int i = 0; i < n; i++) {
        xs[i] = nx[i];
        ys[i] = ny[i];
        rs[i] = nr[i];
      }
    }
    // 頭尾的半徑跟鄰點一致，端點不會因為單點的壓力雜訊突然變粗 / 變細
    if (rs.length >= 2) {
      rs[0] = rs[1];
      rs[rs.length - 1] = rs[rs.length - 2];
    }

    return (xs: xs, ys: ys, rs: rs);
  }

  /// 中心線的「二次貝茲曲線」表示 (PDF 匯出用)。
  /// 與 [sample] 使用同一份平滑後的點、同樣的「中點為端點、原始點為控制點」，
  /// 所以形狀與畫面一致，但只需要少數幾個控制點，不必密集取樣。
  static List<StrokeSegment> curve(List<PointVector> pts, BrushSettings s) {
    final prep = _prepare(pts, s);
    final xs = prep.xs, ys = prep.ys, rs = prep.rs;
    final n = xs.length;
    if (n == 0) return const <StrokeSegment>[];
    if (n == 1) {
      return [StrokeSegment.line(xs[0], ys[0], xs[0], ys[0], rs[0], rs[0])];
    }
    if (n == 2) {
      return [StrokeSegment.line(xs[0], ys[0], xs[1], ys[1], rs[0], rs[1])];
    }
    final out = <StrokeSegment>[];
    double px = xs[0], py = ys[0], pr = rs[0];
    for (int i = 1; i <= n - 2; i++) {
      final ex = (xs[i] + xs[i + 1]) / 2;
      final ey = (ys[i] + ys[i + 1]) / 2;
      final er = (rs[i] + rs[i + 1]) / 2;
      out.add(StrokeSegment.quad(px, py, xs[i], ys[i], ex, ey, pr, er));
      px = ex;
      py = ey;
      pr = er;
    }
    out.add(StrokeSegment.line(px, py, xs[n - 1], ys[n - 1], pr, rs[n - 1]));
    return out;
  }

  /// 產生中心線取樣。[stepScale] 越大取樣越疏 (PDF 匯出用，檔案較小)。
  static List<StrokeSample> sample(
    List<PointVector> pts,
    BrushSettings s, {
    double stepScale = 1.0,
  }) {
    final double size = s.size;
    final prep = _prepare(pts, s);
    final xs = prep.xs, ys = prep.ys, rs = prep.rs;
    if (xs.isEmpty) return const <StrokeSample>[];
    if (xs.length == 1) return [StrokeSample(xs[0], ys[0], rs[0])];

    // ---- 4. 沿平滑曲線取樣 -------------------------------------------------
    final double step = math.max(0.3, size * 0.18) * stepScale;
    final out = <StrokeSample>[StrokeSample(xs[0], ys[0], rs[0])];

    void addLine(double x1, double y1, double r1) {
      final last = out.last;
      final dx = x1 - last.x, dy = y1 - last.y;
      final len = math.sqrt(dx * dx + dy * dy);
      final count = math.max(1, (len / step).ceil());
      for (int k = 1; k <= count; k++) {
        final t = k / count;
        out.add(StrokeSample(
          last.x + dx * t,
          last.y + dy * t,
          last.r + (r1 - last.r) * t,
        ));
      }
    }

    void addQuad(double cx, double cy, double x1, double y1, double r1) {
      final p0 = out.last;
      final len = math.sqrt((cx - p0.x) * (cx - p0.x) + (cy - p0.y) * (cy - p0.y)) +
          math.sqrt((x1 - cx) * (x1 - cx) + (y1 - cy) * (y1 - cy));
      final count = math.max(1, (len / step).ceil());
      for (int k = 1; k <= count; k++) {
        final t = k / count;
        final u = 1 - t;
        out.add(StrokeSample(
          u * u * p0.x + 2 * u * t * cx + t * t * x1,
          u * u * p0.y + 2 * u * t * cy + t * t * y1,
          p0.r + (r1 - p0.r) * t,
        ));
      }
    }

    final n = xs.length;
    if (n == 2) {
      addLine(xs[1], ys[1], rs[1]);
      return out;
    }
    for (int i = 1; i <= n - 2; i++) {
      // 控制點 = 原始點 i；終點 = 點 i 與 i+1 的中點
      addQuad(
        xs[i],
        ys[i],
        (xs[i] + xs[i + 1]) / 2,
        (ys[i] + ys[i + 1]) / 2,
        (rs[i] + rs[i + 1]) / 2,
      );
    }
    // 最後半段直接接到真正的最後一點
    addLine(xs[n - 1], ys[n - 1], rs[n - 1]);
    return out;
  }

  /// 兩個取樣點之間的連接塊 (梯形)，[positive] 指定頂點繞向。長度為 0 回傳 null。
  static List<Offset>? segmentQuad(
    StrokeSample a,
    StrokeSample b, {
    bool? positive,
  }) {
    final dx = b.x - a.x, dy = b.y - a.y;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1e-6) return null;
    final nx = -dy / len, ny = dx / len;
    final pts = <Offset>[
      Offset(a.x + nx * a.r, a.y + ny * a.r),
      Offset(b.x + nx * b.r, b.y + ny * b.r),
      Offset(b.x - nx * b.r, b.y - ny * b.r),
      Offset(a.x - nx * a.r, a.y - ny * a.r),
    ];
    if (positive != null) {
      double area2 = 0;
      for (int i = 0; i < 4; i++) {
        final p = pts[i], q = pts[(i + 1) % 4];
        area2 += p.dx * q.dy - q.dx * p.dy;
      }
      if ((area2 > 0) != positive) {
        return pts.reversed.toList();
      }
    }
    return pts;
  }

  /// 單一緞帶多邊形 (左緣往前、右緣往回)：相鄰橫截面共用邊，因此沒有楔形縫隙。
  /// 轉角處用平均法線 (miter，限制最大延伸)；轉彎很急、緞帶內側可能自我交疊的地方，
  /// 由呼叫端在該取樣點另外補一個圓蓋住。用於 PDF 匯出，檔案大小接近一個多邊形。
  static List<Offset> ribbonPolygon(List<StrokeSample> samples) {
    final pts = <StrokeSample>[];
    for (final p in samples) {
      if (pts.isEmpty) {
        pts.add(p);
      } else {
        final dx = p.x - pts.last.x, dy = p.y - pts.last.y;
        if (dx * dx + dy * dy > 1e-12) pts.add(p);
      }
    }
    final n = pts.length;
    if (n < 2) return const <Offset>[];

    final nxs = List<double>.filled(n - 1, 0);
    final nys = List<double>.filled(n - 1, 0);
    for (int i = 0; i < n - 1; i++) {
      final dx = pts[i + 1].x - pts[i].x, dy = pts[i + 1].y - pts[i].y;
      final len = math.sqrt(dx * dx + dy * dy);
      nxs[i] = -dy / len;
      nys[i] = dx / len;
    }

    final left = <Offset>[];
    final right = <Offset>[];
    for (int i = 0; i < n; i++) {
      double nx, ny, scale = 1.0;
      if (i == 0) {
        nx = nxs[0];
        ny = nys[0];
      } else if (i == n - 1) {
        nx = nxs[n - 2];
        ny = nys[n - 2];
      } else {
        final ax = nxs[i - 1] + nxs[i], ay = nys[i - 1] + nys[i];
        final l = math.sqrt(ax * ax + ay * ay);
        if (l < 1e-6) {
          nx = nxs[i];
          ny = nys[i];
        } else {
          nx = ax / l;
          ny = ay / l;
          final c = nx * nxs[i] + ny * nys[i]; // cos(半轉角)
          scale = 1.0 / math.max(c, 0.67);
        }
      }
      final r = pts[i].r * scale;
      left.add(Offset(pts[i].x + nx * r, pts[i].y + ny * r));
      right.add(Offset(pts[i].x - nx * r, pts[i].y - ny * r));
    }
    return <Offset>[...left, ...right.reversed];
  }

  // 執行時自我校正：確認 Path.addOval 的繞向與「shoelace 面積為正」的多邊形相同。
  // 兩者同向時重疊處繞數為 2 (填色)；反向時會抵銷成 0 (出現破洞)，
  // 所以不靠猜測，直接用 Path.contains 實測一次。
  static bool? _quadPositive;
  static bool get _quadsPositive => _quadPositive ??= (Path()
        ..addOval(Rect.fromCircle(center: Offset.zero, radius: 10))
        ..addPolygon(
          const [Offset(-5, -5), Offset(5, -5), Offset(5, 5), Offset(-5, 5)],
          true,
        ))
      .contains(Offset.zero);

  /// 取樣點 → 填色用的 Path (圓 + 連接塊的聯集)
  static Path buildPath(List<StrokeSample> samples) {
    final path = Path();
    if (samples.isEmpty) return path;
    final bool positive = _quadsPositive;
    for (int i = 0; i < samples.length; i++) {
      final a = samples[i];
      path.addOval(Rect.fromCircle(center: Offset(a.x, a.y), radius: a.r));
      if (i + 1 < samples.length) {
        final quad = segmentQuad(a, samples[i + 1], positive: positive);
        if (quad != null) path.addPolygon(quad, true);
      }
    }
    return path;
  }

  /// 便利函式：點 → Path
  static Path pathFor(List<PointVector> pts, BrushSettings s) =>
      buildPath(sample(pts, s));
}