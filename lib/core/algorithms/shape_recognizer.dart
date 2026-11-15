// lib/core/algorithms/shape_recognizer.dart
//
// 「按住變完美形狀」：把手繪的一筆辨識成 直線 / 圓 / 橢圓 / 矩形 / 多邊形(3~6 邊)。
// 只依賴 dart:math (不依賴 dart:ui)，座標用頁面座標，所有門檻都是相對於形狀大小的比例，
// 所以任何縮放下行為一致。辨識不出來就回傳 null，筆劃維持原樣。
import 'dart:math' as math;

class Pt {
  final double x, y;
  const Pt(this.x, this.y);
  Pt operator +(Pt o) => Pt(x + o.x, y + o.y);
  Pt operator -(Pt o) => Pt(x - o.x, y - o.y);
  Pt operator *(double k) => Pt(x * k, y * k);
  double get length => math.sqrt(x * x + y * y);
  double dist(Pt o) => (this - o).length;
  @override
  String toString() => '(${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)})';
}

enum ShapeKind { line, curve, polyline, ellipse, rectangle, polygon }

class ShapeResult {
  final ShapeKind kind;

  /// 加密過的輪廓點 (封閉形狀的最後一點 = 第一點)
  final List<Pt> outline;

  /// 折線的頂點 (含起點與終點)；其他形狀為 null
  final List<Pt>? vertices;

  /// 橢圓 / 圓的中心；其他形狀為 null
  final Pt? center;
  const ShapeResult(this.kind, this.outline, {this.vertices, this.center});

  /// 直線 / 曲線 / 折線是開放的 (起點與終點不同)，其餘是封閉形狀
  bool get closed =>
      kind != ShapeKind.line &&
      kind != ShapeKind.curve &&
      kind != ShapeKind.polyline;
}

class ShapeRecognizer {
  ShapeRecognizer._();

  // ---- 門檻 (全部是比例) ----
  static const double _closedGap = 0.22; // 首尾距離 / 路徑長 小於此值 = 封閉
  static const double _lineDev = 0.07; // 離弦線最大偏差 / 弦長
  static const double _ellipseTol = 0.10; // 橢圓：平均徑向誤差
  static const double _rectTol = 0.05; // 矩形：平均離邊距離 / √面積
  static const double _polyTol = 0.025; // 多邊形：平均離邊距離 / 外框對角線
  static const double _curveMean = 0.022; // 曲線：平均擬合誤差 / 路徑長
  static const double _curveMax = 0.065; // 曲線：最大擬合誤差 / 路徑長

  /// [raw] 手繪的點 (頁面座標)；[minLength] 路徑太短就不辨識；[step] 輸出點的間距
  static ShapeResult? recognize(
    List<Pt> raw, {
    required double minLength,
    required double step,
  }) {
    if (raw.length < 3) return null;
    final len = _pathLength(raw);
    if (len < minLength) return null;
    final pts = _resample(raw, 96);
    final chord = pts.first.dist(pts.last);

    // ---------------- 開放：只認直線 ----------------
    if (chord >= len * _closedGap) {
      if (chord < 1e-6) return null;
      double maxDev = 0;
      final d = (pts.last - pts.first) * (1 / chord);
      for (final p in pts) {
        final v = p - pts.first;
        maxDev = math.max(maxDev, (v.x * d.y - v.y * d.x).abs());
      }
      if (maxDev / chord <= _lineDev && len / chord < 1.2) {
        return ShapeResult(
          ShapeKind.line,
          lineThrough(pts.first, pts.last, step),
        );
      }
      // 不是直線 → 平滑曲線 (圓弧、S 形...) 或折線 (有明顯轉角)；像塗鴉就不處理
      final curve = _fitCurve(pts, len, step);
      final poly = _fitPolyline(pts, len);
      if (curve != null &&
          (poly == null ||
              poly.maxTurnDeg < 70 ||
              poly.mean > curve.mean * 0.6)) {
        return ShapeResult(ShapeKind.curve, curve.pts);
      }
      if (poly != null) {
        return ShapeResult(
          ShapeKind.polyline,
          _sparse(poly.verts, step, closed: false),
          vertices: poly.verts,
        );
      }
      return null;
    }

    // ---------------- 封閉：橢圓 / 矩形 / 多邊形 ----------------
    final bb = _bounds(pts);
    final diag = math.sqrt(bb.w * bb.w + bb.h * bb.h);
    if (diag < 1e-6) return null;

    final ell = _fitEllipse(pts);
    final rect = _fitRect(pts);
    final poly = _fitPolygon(pts, diag);

    // 依「誤差 / 門檻」排名，最小且 <= 1 者勝出
    double best = double.infinity;
    ShapeResult? out;
    void consider(double ratio, ShapeResult? Function() build) {
      if (ratio <= 1.0 && ratio < best) {
        final r = build();
        if (r != null) {
          best = ratio;
          out = r;
        }
      }
    }

    if (ell != null) {
      consider(ell.err / _ellipseTol, () {
        return ShapeResult(
          ShapeKind.ellipse,
          _ellipseOutline(ell, step),
          center: ell.c,
        );
      });
    }
    if (rect != null) {
      consider(rect.err / _rectTol, () {
        return ShapeResult(
          ShapeKind.rectangle,
          _sparse(rect.corners, step, closed: true),
          vertices: rect.corners,
        );
      });
    }
    if (poly != null) {
      consider(poly.err / _polyTol, () {
        // 四個角接近 90° 的四邊形 (含旋轉過的正方形 / 矩形) → 整理成真正的矩形
        final rc = poly.verts.length == 4 ? _quadAsRect(poly.verts) : null;
        if (rc != null) {
          return ShapeResult(
            ShapeKind.rectangle,
            _sparse(rc, step, closed: true),
            vertices: rc,
          );
        }
        return ShapeResult(
          ShapeKind.polygon,
          _sparse(poly.verts, step, closed: true),
          vertices: poly.verts,
        );
      });
    }
    return out;
  }

  /// 起點到終點的直線；接近水平 / 垂直 / 45° (±3°) 就吸附，輸出加密過的點
  static List<Pt> lineThrough(Pt a, Pt b, double step, {bool angleSnap = true}) {
    var v = b - a;
    final len = v.length;
    if (len < 1e-9) return [a, b];
    final ang = math.atan2(v.y, v.x);
    const q = math.pi / 4;
    final nearest = (ang / q).roundToDouble() * q;
    if (angleSnap && (ang - nearest).abs() <= 3 * math.pi / 180) {
      v = Pt(math.cos(nearest), math.sin(nearest)) * len;
    }
    final e = a + v;
    return [a, e]; // 直線只存兩個端點 (繪製 / 橡皮擦 / 吸附都是以線段計算)
  }

  /// 形狀整理好之後，手指繼續拖曳的調整：「起點固定、手指拖著控制點」。
  ///  - 直線：終點跟著手指 (接近水平 / 垂直 / 45° 會吸附)。
  ///  - 曲線：整條曲線以起點為中心縮放 + 旋轉，讓終點跟著手指。
  ///  - 折線：只有最後一段的終點跟著手指，前面的線段不動。
  ///  - 圓 / 橢圓：以「中心」為基準縮放 + 旋轉，pivot = 中心、h0 = 手指所在的圓周點，
  ///    調整後手指仍然在圓周上。
  ///  - 矩形：對角固定，寬 / 高分開縮放。
  ///  - 三角形：拖最近的頂點，對邊固定。
  ///  - 其他多邊形 (四邊形 / 5 ~ 6 邊)：以中心縮放 + 旋轉，手指一直貼在輪廓上。
  /// [outline0] 剛辨識好的輪廓；[h0] 控制點原本的位置；[h] 控制點現在的位置。
  static List<Pt> adjust({
    required ShapeKind kind,
    required List<Pt> outline0,
    required Pt pivot,
    required Pt h0,
    required Pt h,
    required double step,
    List<Pt>? vertices,
    bool angleSnap = true, // 直線 / 折線最後一段是否吸附水平 / 垂直 / 45° (端點已吸附到其他筆跡時關閉)
  }) {
    if (kind == ShapeKind.line) {
      return lineThrough(pivot, h, step, angleSnap: angleSnap);
    }
    if (kind == ShapeKind.polyline) {
      // 折線：只調整最後那一段 (前面的頂點固定)，最後一段也會吸附水平 / 垂直 / 45°
      final vs = vertices;
      if (vs == null || vs.length < 2) return outline0;
      final head = vs.sublist(0, vs.length - 1);
      final end = lineThrough(head.last, h, step, angleSnap: angleSnap).last;
      return _sparse([...head, end], step, closed: false);
    }
    if (kind == ShapeKind.rectangle) {
      // 矩形：對角固定 (pivot)，手指拖著另一個對角 (h)，在矩形自己的軸向上分別縮放寬 / 高，
      // 不旋轉；接近正方形時吸附成正方形。
      final vs = vertices;
      if (vs != null && vs.length == 4) {
        final ex0 = vs[1] - vs[0], ey0 = vs[3] - vs[0];
        final lx = ex0.length, ly = ey0.length;
        if (lx > 1e-9 && ly > 1e-9) {
          final ex = ex0 * (1 / lx), ey = ey0 * (1 / ly);
          final d = h - pivot, d0 = h0 - pivot;
          // 原本對角向量在 ex / ey 上的正負號：手指跨過 pivot 時矩形會翻過去
          var w = d.x * ex.x + d.y * ex.y;
          var hh = d.x * ey.x + d.y * ey.y;
          final w0 = d0.x * ex.x + d0.y * ex.y;
          final h0v = d0.x * ey.x + d0.y * ey.y;
          // 太小就保持最小尺寸，避免縮成一條線
          const minSide = 4.0;
          if (w.abs() < minSide) w = w < 0 ? -minSide : minSide;
          if (hh.abs() < minSide) hh = hh < 0 ? -minSide : minSide;
          // 還沒怎麼動就維持原形狀
          if ((w - w0).abs() < 0.02 * w0.abs() && (hh - h0v).abs() < 0.02 * h0v.abs()) {
            return outline0;
          }
          // 接近正方形 (±6%) → 吸附成正方形，邊長取較大者
          final aw = w.abs(), ah = hh.abs();
          if ((aw - ah).abs() <= 0.06 * math.max(aw, ah)) {
            final m = math.max(aw, ah);
            w = w < 0 ? -m : m;
            hh = hh < 0 ? -m : m;
          }
          final a = pivot;
          final b = pivot + ex * w;
          final c = pivot + ex * w + ey * hh;
          final e = pivot + ey * hh;
          return _sparse([a, b, c, e], step, closed: true);
        }
      }
    }
    if (kind == ShapeKind.polygon && vertices != null && vertices.length == 3) {
      // 三角形：手指拖著最近的那個頂點 (h0 就是它原本的位置)，對邊的兩個頂點固定不動
      int bi = 0;
      for (int i = 1; i < 3; i++) {
        if (vertices[i].dist(h0) < vertices[bi].dist(h0)) bi = i;
      }
      final nv = [for (int i = 0; i < 3; i++) i == bi ? h : vertices[i]];
      return _sparse(nv, step, closed: true);
    }
    final v0 = h0 - pivot, v = h - pivot;
    final l0 = v0.length, l = v.length;
    if (l0 < 1e-9 || l < 1e-9) return outline0;
    var scale = (l / l0).clamp(0.05, 40.0).toDouble();
    var rot = math.atan2(v.y, v.x) - math.atan2(v0.y, v0.x);
    // 矩形 / 多邊形：微小的抖動不要破壞剛整理好的形狀；橢圓 / 圓要讓手指一直貼在圓周上，不做死區
    final closed = kind != ShapeKind.curve && kind != ShapeKind.ellipse;
    if (closed) {
      // 微小的抖動不要破壞剛整理好的形狀 (例如水平的矩形)
      if (rot.abs() < 3.5 * math.pi / 180) rot = 0;
      if ((scale - 1).abs() < 0.02) scale = 1;
    }
    final c = math.cos(rot), s = math.sin(rot);
    return [
      for (final p in outline0)
        () {
          final d = (p - pivot) * scale;
          return Pt(pivot.x + d.x * c - d.y * s, pivot.y + d.x * s + d.y * c);
        }(),
    ];
  }

  /// 把開放形狀 (直線 / 曲線 / 折線) 的起點移到 [q] (吸附到其他筆跡)，終點不動。
  ///  - 直線：起點換成 q。
  ///  - 曲線：整條曲線以終點為中心縮放 + 旋轉，讓起點落在 q。
  ///  - 折線：只移動第一個頂點。
  static ShapeResult moveStart(ShapeResult r, Pt q, double step) {
    switch (r.kind) {
      case ShapeKind.line:
        return ShapeResult(
          ShapeKind.line,
          [q, r.outline.last],
        );
      case ShapeKind.polyline:
        final vs = r.vertices;
        if (vs == null || vs.length < 2) return r;
        final nv = [q, ...vs.sublist(1)];
        return ShapeResult(
          ShapeKind.polyline,
          _sparse(nv, step, closed: false),
          vertices: nv,
        );
      case ShapeKind.curve:
        final e = r.outline.last;
        final v0 = r.outline.first - e, v = q - e;
        if (v0.length < 1e-9 || v.length < 1e-9) return r;
        final scale = v.length / v0.length;
        final rot = math.atan2(v.y, v.x) - math.atan2(v0.y, v0.x);
        final c = math.cos(rot), s = math.sin(rot);
        return ShapeResult(ShapeKind.curve, [
          for (final p in r.outline)
            () {
              final d = (p - e) * scale;
              return Pt(e.x + d.x * c - d.y * s, e.y + d.x * s + d.y * c);
            }(),
        ]);
      default:
        return r;
    }
  }

  // =============================================================
  // 擬合
  // =============================================================

  /// 以三次貝茲曲線 (起訖點固定) 擬合開放的一筆；擬合得夠準才回傳取樣後的曲線
  static ({List<Pt> pts, double mean})? _fitCurve(
    List<Pt> pts,
    double len,
    double step,
  ) {
    final n = pts.length;
    final p0 = pts.first, p3 = pts.last;
    // 初始參數：弦長參數化
    final ts = List<double>.filled(n, 0);
    double acc = 0;
    for (int i = 1; i < n; i++) {
      acc += pts[i].dist(pts[i - 1]);
      ts[i] = acc;
    }
    if (acc < 1e-9) return null;
    for (int i = 0; i < n; i++) {
      ts[i] /= acc;
    }

    Pt p1 = p0, p2 = p3;
    for (int iter = 0; iter < 6; iter++) {
      double a11 = 0, a12 = 0, a22 = 0;
      double bx1 = 0, by1 = 0, bx2 = 0, by2 = 0;
      for (int i = 0; i < n; i++) {
        final t = ts[i], u = 1 - t;
        final b0 = u * u * u, b1 = 3 * t * u * u, b2 = 3 * t * t * u, b3 = t * t * t;
        final rx = pts[i].x - p0.x * b0 - p3.x * b3;
        final ry = pts[i].y - p0.y * b0 - p3.y * b3;
        a11 += b1 * b1;
        a12 += b1 * b2;
        a22 += b2 * b2;
        bx1 += b1 * rx;
        by1 += b1 * ry;
        bx2 += b2 * rx;
        by2 += b2 * ry;
      }
      final det = a11 * a22 - a12 * a12;
      if (det.abs() < 1e-12) return null;
      p1 = Pt((bx1 * a22 - bx2 * a12) / det, (by1 * a22 - by2 * a12) / det);
      p2 = Pt((a11 * bx2 - a12 * bx1) / det, (a11 * by2 - a12 * by1) / det);

      // 牛頓法重新找每個點最近的曲線參數
      for (int i = 0; i < n; i++) {
        var t = ts[i];
        for (int k = 0; k < 2; k++) {
          final q = _bez(p0, p1, p2, p3, t);
          final d1 = _bezD1(p0, p1, p2, p3, t);
          final d2 = _bezD2(p0, p1, p2, p3, t);
          final dx = q.x - pts[i].x, dy = q.y - pts[i].y;
          final num = dx * d1.x + dy * d1.y;
          final den = d1.x * d1.x + d1.y * d1.y + dx * d2.x + dy * d2.y;
          if (den.abs() < 1e-12) break;
          t = (t - num / den).clamp(0.0, 1.0).toDouble();
        }
        ts[i] = t;
      }
    }

    double sum = 0, mx = 0;
    for (int i = 0; i < n; i++) {
      final e = _bez(p0, p1, p2, p3, ts[i]).dist(pts[i]);
      sum += e;
      mx = math.max(mx, e);
    }
    if (sum / n / len > _curveMean || mx / len > _curveMax) return null;

    // 控制點不能離譜 (避免自交的怪曲線)
    final chord = p0.dist(p3);
    if (p1.dist(p0) > chord * 2.5 || p2.dist(p3) > chord * 2.5) return null;

    // 取樣成等距的點 (起訖點精確保留)
    final fine = <Pt>[for (int i = 0; i <= 200; i++) _bez(p0, p1, p2, p3, i / 200)];
    final arc = _pathLength(fine);
    final count = math.max(12, (arc / (step * 4)).ceil());
    final out = <Pt>[];
    double target = 0, run = 0;
    final seg = arc / count;
    out.add(fine.first);
    for (int i = 1; i < fine.length && out.length < count; i++) {
      final d = fine[i].dist(fine[i - 1]);
      run += d;
      while (run >= target + seg && out.length < count) {
        target += seg;
        out.add(fine[i]);
      }
    }
    out.add(p3);
    return (pts: out, mean: sum / n / len);
  }

  /// 開放的一筆 → 折線頂點 (RDP 簡化)；頂點太多 (像塗鴉) 就放棄
  static ({List<Pt> verts, double maxTurnDeg, double mean})? _fitPolyline(
    List<Pt> pts,
    double len,
  ) {
    final v = _rdp(pts, len * 0.035);
    // 太靠近的頂點合併 (起訖點保留)
    final merged = <Pt>[v.first];
    for (int i = 1; i < v.length - 1; i++) {
      if (v[i].dist(merged.last) > len * 0.05 && v[i].dist(v.last) > len * 0.05) {
        merged.add(v[i]);
      }
    }
    merged.add(v.last);
    if (merged.length < 3 || merged.length > 13) return null;
    double maxTurn = 0;
    for (int i = 1; i < merged.length - 1; i++) {
      final a = merged[i] - merged[i - 1], b = merged[i + 1] - merged[i];
      final la = a.length, lb = b.length;
      if (la < 1e-9 || lb < 1e-9) continue;
      final cos = ((a.x * b.x + a.y * b.y) / (la * lb)).clamp(-1.0, 1.0).toDouble();
      maxTurn = math.max(maxTurn, math.acos(cos) * 180 / math.pi);
    }
    // 平均擬合誤差 / 路徑長 (和曲線比較誰比較貼近手繪的筆跡)
    double sum = 0;
    for (final p in pts) {
      double d = double.infinity;
      for (int i = 0; i < merged.length - 1; i++) {
        d = math.min(d, _distToSeg(p, merged[i], merged[i + 1]));
      }
      sum += d;
    }
    return (verts: merged, maxTurnDeg: maxTurn, mean: sum / pts.length / len);
  }

  static Pt _bez(Pt a, Pt b, Pt c, Pt d, double t) {
    final u = 1 - t;
    final w0 = u * u * u, w1 = 3 * t * u * u, w2 = 3 * t * t * u, w3 = t * t * t;
    return Pt(
      a.x * w0 + b.x * w1 + c.x * w2 + d.x * w3,
      a.y * w0 + b.y * w1 + c.y * w2 + d.y * w3,
    );
  }

  static Pt _bezD1(Pt a, Pt b, Pt c, Pt d, double t) {
    final u = 1 - t;
    final w0 = 3 * u * u, w1 = 6 * u * t, w2 = 3 * t * t;
    return Pt(
      (b.x - a.x) * w0 + (c.x - b.x) * w1 + (d.x - c.x) * w2,
      (b.y - a.y) * w0 + (c.y - b.y) * w1 + (d.y - c.y) * w2,
    );
  }

  static Pt _bezD2(Pt a, Pt b, Pt c, Pt d, double t) {
    final u = 1 - t;
    return Pt(
      6 * u * (c.x - 2 * b.x + a.x) + 6 * t * (d.x - 2 * c.x + b.x),
      6 * u * (c.y - 2 * b.y + a.y) + 6 * t * (d.y - 2 * c.y + b.y),
    );
  }

  static _EllipseFit? _fitEllipse(List<Pt> pts) {
    final n = pts.length;
    double cx = 0, cy = 0;
    for (final p in pts) {
      cx += p.x;
      cy += p.y;
    }
    cx /= n;
    cy /= n;
    double sxx = 0, syy = 0, sxy = 0;
    for (final p in pts) {
      final dx = p.x - cx, dy = p.y - cy;
      sxx += dx * dx;
      syy += dy * dy;
      sxy += dx * dy;
    }
    final theta = 0.5 * math.atan2(2 * sxy, sxx - syy);
    final c = math.cos(theta), s = math.sin(theta);
    double minU = double.infinity, maxU = -double.infinity;
    double minV = double.infinity, maxV = -double.infinity;
    final us = <double>[], vs = <double>[];
    for (final p in pts) {
      final dx = p.x - cx, dy = p.y - cy;
      final u = dx * c + dy * s, v = -dx * s + dy * c;
      us.add(u);
      vs.add(v);
      minU = math.min(minU, u);
      maxU = math.max(maxU, u);
      minV = math.min(minV, v);
      maxV = math.max(maxV, v);
    }
    final a = (maxU - minU) / 2, b = (maxV - minV) / 2;
    if (a < 1e-6 || b < 1e-6) return null;
    final cu = (maxU + minU) / 2, cv = (maxV + minV) / 2;
    double err = 0;
    for (int i = 0; i < n; i++) {
      final r = math.sqrt(math.pow((us[i] - cu) / a, 2) + math.pow((vs[i] - cv) / b, 2));
      err += (r - 1).abs();
    }
    err /= n;
    // 中心換回頁面座標
    final center = Pt(cx + cu * c - cv * s, cy + cu * s + cv * c);
    var aa = a, bb = b, th = theta;
    if ((a - b).abs() / math.max(a, b) < 0.12) {
      // 近似正圓
      aa = bb = (a + b) / 2;
      th = 0;
    }
    return _EllipseFit(center, aa, bb, th, err);
  }

  static _RectFit? _fitRect(List<Pt> pts) {
    final n = pts.length;
    double cx = 0, cy = 0;
    for (final p in pts) {
      cx += p.x;
      cy += p.y;
    }
    cx /= n;
    cy /= n;
    double sxx = 0, syy = 0, sxy = 0;
    for (final p in pts) {
      final dx = p.x - cx, dy = p.y - cy;
      sxx += dx * dx;
      syy += dy * dy;
      sxy += dx * dy;
    }
    final pca = 0.5 * math.atan2(2 * sxy, sxx - syy);

    _RectFit? best;
    // 候選角度：不轉 (水平 / 垂直矩形最常見) 與主軸角度
    for (final theta in <double>[0.0, pca]) {
      final c = math.cos(theta), s = math.sin(theta);
      double minU = double.infinity, maxU = -double.infinity;
      double minV = double.infinity, maxV = -double.infinity;
      for (final p in pts) {
        final u = p.x * c + p.y * s, v = -p.x * s + p.y * c;
        minU = math.min(minU, u);
        maxU = math.max(maxU, u);
        minV = math.min(minV, v);
        maxV = math.max(maxV, v);
      }
      final w = maxU - minU, h = maxV - minV;
      if (w < 1e-6 || h < 1e-6) continue;
      double err = 0;
      for (final p in pts) {
        final u = p.x * c + p.y * s, v = -p.x * s + p.y * c;
        final d = math.min(
          math.min((u - minU).abs(), (u - maxU).abs()),
          math.min((v - minV).abs(), (v - maxV).abs()),
        );
        err += d;
      }
      err = err / n / math.sqrt(w * h);
      // 主軸角度接近水平 / 垂直 (±7°) 就當作沒轉
      Pt toXY(double u, double v) => Pt(u * c - v * s, u * s + v * c);
      final corners = [
        toXY(minU, minV),
        toXY(maxU, minV),
        toXY(maxU, maxV),
        toXY(minU, maxV),
      ];
      if (best == null || err < best.err) best = _RectFit(corners, err);
    }
    if (best == null) return null;
    // 吸附成水平矩形：主軸角度接近 0 / 90° (±7°) 時改用軸對齊外框
    final e01 = best.corners[1] - best.corners[0];
    final ang = math.atan2(e01.y, e01.x);
    final off = (ang / (math.pi / 2)) - (ang / (math.pi / 2)).roundToDouble();
    if (off.abs() * 90 < 7 && ang.abs() > 1e-9) {
      final bb = _bounds(pts);
      final corners = [
        Pt(bb.minX, bb.minY),
        Pt(bb.maxX, bb.minY),
        Pt(bb.maxX, bb.maxY),
        Pt(bb.minX, bb.maxY),
      ];
      final w = bb.w, h = bb.h;
      double err = 0;
      for (final p in pts) {
        err += math.min(
          math.min((p.x - bb.minX).abs(), (p.x - bb.maxX).abs()),
          math.min((p.y - bb.minY).abs(), (p.y - bb.maxY).abs()),
        );
      }
      err = err / pts.length / math.sqrt(w * h);
      if (err <= best.err * 1.3) best = _RectFit(corners, err);
    }
    return best;
  }

  static _PolyFit? _fitPolygon(List<Pt> pts, double diag) {
    // 封閉曲線的 RDP：以離起點最遠的點為界，分成兩半各自簡化
    final ring = [...pts, pts.first];
    int far = 0;
    double fd = -1;
    for (int i = 0; i < pts.length; i++) {
      final d = pts[i].dist(pts.first);
      if (d > fd) {
        fd = d;
        far = i;
      }
    }
    final eps = diag * 0.045;
    final a = _rdp(ring.sublist(0, far + 1), eps);
    final b = _rdp(ring.sublist(far), eps);
    final verts = <Pt>[...a.sublist(0, a.length - 1), ...b.sublist(0, b.length - 1)];
    final merged = _mergeClose(verts, diag * 0.06);
    if (merged.length < 3 || merged.length > 4) return null; // 只要三角形 / 四邊形

    double err = 0;
    for (final p in pts) {
      double d = double.infinity;
      for (int i = 0; i < merged.length; i++) {
        d = math.min(d, _distToSeg(p, merged[i], merged[(i + 1) % merged.length]));
      }
      err += d;
    }
    err = err / pts.length / diag;
    return _PolyFit(merged, err);
  }

  /// 四邊形是否夠像矩形 (四角 ≈ 90°、對邊長度相近)；是的話回傳整理好的四個角
  static List<Pt>? _quadAsRect(List<Pt> q) {
    final e = [for (int i = 0; i < 4; i++) q[(i + 1) % 4] - q[i]];
    final l = [for (final v in e) v.length];
    if (l.any((x) => x < 1e-6)) return null;
    for (int i = 0; i < 4; i++) {
      final a = e[i], b = e[(i + 1) % 4];
      final cos = (a.x * b.x + a.y * b.y) / (l[i] * l[(i + 1) % 4]);
      if (cos.abs() > 0.22) return null; // 角度偏離 90° 超過約 13°
    }
    double ratio(double a, double b) => a > b ? a / b : b / a;
    if (ratio(l[0], l[2]) > 1.3 || ratio(l[1], l[3]) > 1.3) return null;

    final center = Pt(
      (q[0].x + q[1].x + q[2].x + q[3].x) / 4,
      (q[0].y + q[1].y + q[2].y + q[3].y) / 4,
    );
    // 長邊方向 = 兩條對邊方向的平均 (第二條反向後再平均)
    var u = Pt(e[0].x / l[0] - e[2].x / l[2], e[0].y / l[0] - e[2].y / l[2]);
    final ul = u.length;
    if (ul < 1e-9) return null;
    u = u * (1 / ul);
    // 接近水平 / 垂直 (±7°) 就吸附到軸向
    var ang = math.atan2(u.y, u.x);
    final qd = math.pi / 2;
    final nearest = (ang / qd).roundToDouble() * qd;
    if ((ang - nearest).abs() <= 7 * math.pi / 180) ang = nearest;
    u = Pt(math.cos(ang), math.sin(ang));
    final v = Pt(-u.y, u.x);
    final hw = (l[0] + l[2]) / 4, hh = (l[1] + l[3]) / 4;
    return [
      center - u * hw - v * hh,
      center + u * hw - v * hh,
      center + u * hw + v * hh,
      center - u * hw + v * hh,
    ];
  }

  static List<Pt> _rdp(List<Pt> pts, double eps) {
    if (pts.length < 3) return pts;
    double maxD = 0;
    int idx = 0;
    for (int i = 1; i < pts.length - 1; i++) {
      final d = _distToSeg(pts[i], pts.first, pts.last);
      if (d > maxD) {
        maxD = d;
        idx = i;
      }
    }
    if (maxD <= eps) return [pts.first, pts.last];
    final l = _rdp(pts.sublist(0, idx + 1), eps);
    final r = _rdp(pts.sublist(idx), eps);
    return [...l.sublist(0, l.length - 1), ...r];
  }

  static List<Pt> _mergeClose(List<Pt> v, double minDist) {
    final out = <Pt>[];
    for (final p in v) {
      if (out.isEmpty || p.dist(out.last) > minDist) out.add(p);
    }
    while (out.length > 1 && out.first.dist(out.last) <= minDist) {
      out.removeLast();
    }
    return out;
  }

  // =============================================================
  // 輸出輪廓
  // =============================================================
  static List<Pt> _ellipseOutline(_EllipseFit e, double step) {
    // 點數只依「取樣誤差 <= tol」決定，不再照間距密集補點
    // (二次 B 樣條取樣的最大誤差 ≈ R·Δt²/8，R = 長軸半徑)
    final tol = math.max(0.1, step * 0.1);
    final r = math.max(math.max(e.a, e.b), 1e-6);
    final n = (2 * math.pi / math.sqrt(8 * tol / r)).ceil().clamp(16, 120);
    final c = math.cos(e.theta), s = math.sin(e.theta);
    final out = <Pt>[];
    for (int i = 0; i <= n; i++) {
      final t = 2 * math.pi * i / n;
      final u = e.a * math.cos(t), v = e.b * math.sin(t);
      out.add(Pt(e.c.x + u * c - v * s, e.c.y + u * s + v * c));
    }
    return out;
  }

  /// 只留頂點的精簡輪廓。每個轉角前後各補一個很近的點 (約半個 step)，
  /// 畫筆沿「中點為端點、原始點為控制點」的曲線取樣時，轉角才不會被磨圓；
  /// 直線邊上不會有多餘的點。
  static List<Pt> _sparse(List<Pt> v, double step, {required bool closed}) {
    final n = v.length;
    if (n < 2) return List<Pt>.of(v);
    final e = math.max(0.5, step * 0.5);
    Pt toward(Pt a, Pt b, double d) {
      final l = a.dist(b);
      return l < 1e-9 ? a : a + (b - a) * (d / l);
    }

    double eps(Pt prev, Pt cur, Pt next) =>
        math.min(e, math.min(prev.dist(cur), cur.dist(next)) / 4);

    final out = <Pt>[v[0]];
    if (closed) {
      for (int i = 0; i < n; i++) {
        final prev = v[(i + n - 1) % n], cur = v[i], next = v[(i + 1) % n];
        final d = eps(prev, cur, next);
        if (i > 0) {
          out.add(toward(cur, prev, d));
          out.add(cur);
        }
        out.add(toward(cur, next, d));
      }
      final d0 = eps(v[n - 1], v[0], v[1]);
      out.add(toward(v[0], v[n - 1], d0));
      out.add(v[0]);
    } else {
      for (int i = 1; i < n - 1; i++) {
        final d = eps(v[i - 1], v[i], v[i + 1]);
        out.add(toward(v[i], v[i - 1], d));
        out.add(v[i]);
        out.add(toward(v[i], v[i + 1], d));
      }
      out.add(v[n - 1]);
    }
    return out;
  }


  // =============================================================
  // 工具
  // =============================================================
  static double _pathLength(List<Pt> p) {
    double l = 0;
    for (int i = 1; i < p.length; i++) {
      l += p[i].dist(p[i - 1]);
    }
    return l;
  }

  static List<Pt> _resample(List<Pt> p, int n) {
    final total = _pathLength(p);
    final step = total / (n - 1);
    final out = <Pt>[p.first];
    double acc = 0;
    Pt prev = p.first;
    for (int i = 1; i < p.length; i++) {
      var cur = p[i];
      double d = prev.dist(cur);
      while (d > 0 && acc + d >= step) {
        final t = (step - acc) / d;
        final q = prev + (cur - prev) * t;
        out.add(q);
        prev = q;
        d = prev.dist(cur);
        acc = 0;
      }
      acc += d;
      prev = cur;
    }
    while (out.length < n) {
      out.add(p.last);
    }
    return out.length > n ? out.sublist(0, n) : out;
  }

  static _Box _bounds(List<Pt> p) {
    double minX = p.first.x, maxX = minX, minY = p.first.y, maxY = minY;
    for (final q in p) {
      minX = math.min(minX, q.x);
      maxX = math.max(maxX, q.x);
      minY = math.min(minY, q.y);
      maxY = math.max(maxY, q.y);
    }
    return _Box(minX, minY, maxX, maxY);
  }

  static double _distToSeg(Pt p, Pt a, Pt b) {
    final ab = b - a;
    final l2 = ab.x * ab.x + ab.y * ab.y;
    if (l2 < 1e-12) return p.dist(a);
    final t = (((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / l2).clamp(0.0, 1.0);
    return p.dist(a + ab * t);
  }
}

class _Box {
  final double minX, minY, maxX, maxY;
  const _Box(this.minX, this.minY, this.maxX, this.maxY);
  double get w => maxX - minX;
  double get h => maxY - minY;
}

class _EllipseFit {
  final Pt c;
  final double a, b, theta, err;
  const _EllipseFit(this.c, this.a, this.b, this.theta, this.err);
}

class _RectFit {
  final List<Pt> corners;
  final double err;
  const _RectFit(this.corners, this.err);
}

class _PolyFit {
  final List<Pt> verts;
  final double err;
  const _PolyFit(this.verts, this.err);
}
