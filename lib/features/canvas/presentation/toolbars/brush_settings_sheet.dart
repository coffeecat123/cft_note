// lib/features/canvas/presentation/toolbars/brush_settings_sheet.dart
import 'package:flutter/material.dart';
import 'package:perfect_freehand/perfect_freehand.dart';

import '../../../../app/theme/app_theme.dart';
import '../../../../core/i18n/app_strings.dart';
import '../../domain/models/brush_settings.dart';
import '../controllers/canvas_controller.dart';

class BrushSettingsSheet extends StatefulWidget {
  final CanvasController controller;
  const BrushSettingsSheet({super.key, required this.controller});

  @override
  State<BrushSettingsSheet> createState() => _BrushSettingsSheetState();
}

class _BrushSettingsSheetState extends State<BrushSettingsSheet> {
  late BrushSettings _current;

  @override
  void initState() {
    super.initState();
    _current = widget.controller.brush;
  }

  void _update(BrushSettings settings) {
    setState(() => _current = settings);
    widget.controller.updateBrush(settings);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final page = widget.controller.currentPage;
    // 預覽畫在「目前這頁的紙張顏色」上，深色紙 / 深色主題下黑色筆跡也看得到
    final previewPaper = page.isBlank ? page.background.color : Colors.white;
    return Container(
      // ★ 設定最大高度上限為螢幕的 90%，防止撐破
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.9,
      ),
      decoration: BoxDecoration(
        color: context.cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 1. 置頂固定區：把手 (不隨內容滾動)
            const SizedBox(height: 12),
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: context.cs.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 8),

            // 2. ★ 可滾動內容區 (Scrollable Body)
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.brushStudio,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // 即時筆觸預覽小黑板
                    Container(
                      height: 70,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: previewPaper,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: context.cs.outlineVariant),
                      ),
                      child: CustomPaint(
                        painter: _BrushPreviewPainter(
                          settings: _current,
                          color: widget.controller.strokeColor,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // 快速風格預設
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _presetChip(s.presetFountain, BrushSettings.fountainPen),
                          const SizedBox(width: 8),
                          _presetChip(s.presetBallpoint, BrushSettings.ballpoint),
                          const SizedBox(width: 8),
                          _presetChip(s.presetMarker, BrushSettings.marker),
                        ],
                      ),
                    ),
                    const Divider(height: 24),

                    // 四大調節滑桿
                    _buildSlider(
                      title: s.brushSize,
                      value: _current.size,
                      min: 0.1,
                      max: 40.0,
                      divisions: ((40-0.1)/0.1).toInt(),
                      displayValue: '${_current.size.toStringAsFixed(1)} px',
                      onChanged: (v) => _update(_current.copyWith(size: v)),
                    ),
                    _buildSlider(
                      title: s.brushThinning,
                      value: _current.thinning,
                      min: 0.0,
                      max: 1.0,
                      displayValue: '${(_current.thinning * 100).toInt()}%',
                      onChanged: (v) => _update(_current.copyWith(thinning: v)),
                    ),
                    _buildSlider(
                      title: s.brushStreamline,
                      value: _current.streamline,
                      min: 0.0,
                      max: 1.0,
                      displayValue: '${(_current.streamline * 100).toInt()}%',
                      onChanged: (v) =>
                          _update(_current.copyWith(streamline: v)),
                    ),
                    _buildSlider(
                      title: s.brushSmoothing,
                      value: _current.smoothing,
                      min: 0.0,
                      max: 1.0,
                      displayValue: '${(_current.smoothing * 100).toInt()}%',
                      onChanged: (v) =>
                          _update(_current.copyWith(smoothing: v)),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _presetChip(String label, BrushSettings preset) {
    final isSelected =
        _current.thinning == preset.thinning &&
        _current.streamline == preset.streamline &&
        _current.smoothing == preset.smoothing;
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: isSelected,
      onSelected: (_) => _update(preset),
    );
  }

  Widget _buildSlider({
    required String title,
    required double value,
    required double min,
    required double max,
    int? divisions,
    required String displayValue,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Text(
              title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                value: value,
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 50,
            child: Text(
              displayValue,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}

// 預覽小黑板 Painter (模擬一條優雅的 S 筆畫與變動壓感)
class _BrushPreviewPainter extends CustomPainter {
  final BrushSettings settings;
  final Color color;
  _BrushPreviewPainter({required this.settings, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    // 構造一條 S 形狀的模擬點集合 (自帶由輕到重再到輕的壓感變化)
    final points = <PointVector>[];
    const steps = 30;
    for (int i = 0; i <= steps; i++) {
      final t = i / steps;
      final x = 20.0 + t * (size.width - 40.0);
      final y =
          size.height / 2 + 18.0 * (t < 0.5 ? (t * 2 - 0.5) : -(t * 2 - 1.5));
      // 模擬壓感曲線 (中間重、兩頭輕)
      final pressure = 0.2 + 0.8 * (1.0 - (t - 0.5).abs() * 2);
      points.add(PointVector(x, y, pressure));
    }

    final outlinePoints = getStroke(
      points,
      options: StrokeOptions(
        size: settings.size,
        thinning: settings.thinning,
        smoothing: settings.smoothing,
        streamline: settings.streamline,
        simulatePressure: false,
      ),
    );

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path();
    if (outlinePoints.isNotEmpty) {
      path.moveTo(outlinePoints.first.dx, outlinePoints.first.dy);
      for (int i = 1; i < outlinePoints.length; i++) {
        path.lineTo(outlinePoints[i].dx, outlinePoints[i].dy);
      }
      path.close();
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BrushPreviewPainter old) =>
      old.settings != settings || old.color != color;
}
