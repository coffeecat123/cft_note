// lib/features/canvas/domain/models/brush_settings.dart
class BrushSettings {
  final double size; // 粗細 (1.0 ~ 50.0)
  final double thinning; // 壓感粗細變化 (0.0 ~ 1.0)
  final double smoothing; // 平滑度 (0.0 ~ 1.0)
  final double streamline; // 防手抖牽引感 (0.0 ~ 1.0)

  const BrushSettings({
    this.size = 6.0,
    this.thinning = 0.6,
    this.smoothing = 0.5,
    this.streamline = 0.5,
  });

  BrushSettings copyWith({
    double? size,
    double? thinning,
    double? smoothing,
    double? streamline,
  }) {
    return BrushSettings(
      size: size ?? this.size,
      thinning: thinning ?? this.thinning,
      smoothing: smoothing ?? this.smoothing,
      streamline: streamline ?? this.streamline,
    );
  }

  // --- 經典筆刷預設 ---
  // 1. 鋼筆 (Fountain Pen)：強壓感、高彈性
  static const fountainPen = BrushSettings(
    size: 5.0,
    thinning: 0.75,
    smoothing: 0.5,
    streamline: 0.45,
  );

  // 2. 原子筆 (Ballpoint)：均勻等粗、超低延遲
  static const ballpoint = BrushSettings(
    size: 3.5,
    thinning: 0.05, // 幾乎沒有粗細變化
    smoothing: 0.2,
    streamline: 0.1, // 零阻尼感
  );

  // 3. 簽字筆/麥克筆 (Marker)：高平滑、高防手抖
  static const marker = BrushSettings(
    size: 14.0,
    thinning: 0.3,
    smoothing: 0.8,
    streamline: 0.8, // 極強防手抖
  );
}