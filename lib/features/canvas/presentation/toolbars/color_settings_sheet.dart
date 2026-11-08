// lib/features/canvas/presentation/toolbars/color_settings_sheet.dart
import 'package:flutter/material.dart';
import '../controllers/canvas_controller.dart';

// ==========================================
// ★ 解決第 2 點：純向量全寬漸層滑軌 (消除邊距脫節問題)
// ==========================================
class GradientSliderTrackShape extends SliderTrackShape {
  final Gradient gradient;
  const GradientSliderTrackShape({required this.gradient});

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final double trackHeight = sliderTheme.trackHeight ?? 14.0;
    final double trackLeft = offset.dx;
    final double trackTop = offset.dy + (parentBox.size.height - trackHeight) / 2;
    final double trackWidth = parentBox.size.width;
    return Rect.fromLTWH(trackLeft, trackTop, trackWidth, trackHeight);
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
  }) {
    final Rect trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
    );

    final Paint paint = Paint()
      ..shader = gradient.createShader(trackRect)
      ..style = PaintingStyle.fill;

    final RRect rrect = RRect.fromRectAndRadius(
      trackRect,
      Radius.circular(trackRect.height / 2),
    );
    context.canvas.drawRRect(rrect, paint);
  }
}

// ==========================================
// 主調色盤視窗
// ==========================================
class ColorSettingsSheet extends StatefulWidget {
  final CanvasController controller;
  const ColorSettingsSheet({super.key, required this.controller});

  @override
  State<ColorSettingsSheet> createState() => _ColorSettingsSheetState();
}

class _ColorSettingsSheetState extends State<ColorSettingsSheet> {
  late double _hue; // H: 色相 0° ~ 360°
  late double _saturation; // S: 彩度 0.0 ~ 1.0
  late double _brightness; // B: 明度 0.0 ~ 1.0

  @override
  void initState() {
    super.initState();
    final hsv = HSVColor.fromColor(widget.controller.strokeColor);
    _hue = hsv.hue;
    _saturation = hsv.saturation;
    _brightness = hsv.value;
  }

  Color get _currentColor =>
      HSVColor.fromAHSV(1.0, _hue, _saturation, _brightness).toColor();

  String get _hexCode {
    final c = _currentColor;
    return '#${(c.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  void _applyColor(Color color) {
    widget.controller.selectColorDirectly(color); // 單次點擊一次提交
    final hsv = HSVColor.fromColor(color);
    setState(() {
      _hue = hsv.hue;
      _saturation = hsv.saturation;
      _brightness = hsv.value;
    });
  }

  // ★ 解決第 4 點：刪除前二次確認對話框
  void _confirmDeleteColor(BuildContext context, Color color) {
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('刪除收藏顏色', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.grey[400]!),
              ),
            ),
            const SizedBox(width: 12),
            const Text('確定要從喜愛清單中移除此顏色？'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('取消', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              elevation: 0,
            ),
            onPressed: () {
              widget.controller.removeFavoriteColor(color);
              Navigator.pop(dialogCtx);
              setState(() {});
            },
            child: const Text('確定刪除'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sGradient = LinearGradient(colors: [
      HSVColor.fromAHSV(1.0, _hue, 0.0, _brightness).toColor(),
      HSVColor.fromAHSV(1.0, _hue, 1.0, _brightness).toColor(),
    ]);

    final bGradient = LinearGradient(colors: [
      HSVColor.fromAHSV(1.0, _hue, _saturation, 0.0).toColor(),
      HSVColor.fromAHSV(1.0, _hue, _saturation, 1.0).toColor(),
    ]);

    const hGradient = LinearGradient(colors: [
      Colors.red,
      Colors.yellow,
      Colors.green,
      Colors.cyan,
      Colors.blue,
      Colors.purple,
      Colors.red,
    ]);

    return Container(
      // ★ 設定最大高度上限為螢幕的 90%
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.9,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
                decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 8),

            // 2. ★ 可滾動內容區 (Scrollable Body)
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 頂部列：標題 + 當前大顏色圓圈
                    Row(
                      children: [
                        const Text('色彩工作台', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        const Spacer(),
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: _currentColor,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                            boxShadow: [
                              BoxShadow(color: Colors.black.withAlpha(40), blurRadius: 6, offset: const Offset(0, 2)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // 固定定位的標籤
                    Row(
                      children: [
                        _buildFixedBadge('H', '${_hue.toInt()}°', 48),
                        const SizedBox(width: 8),
                        _buildFixedBadge('S', '${(_saturation * 100).toInt()}%', 48),
                        const SizedBox(width: 8),
                        _buildFixedBadge('B', '${(_brightness * 100).toInt()}%', 48),
                        const SizedBox(width: 8),
                        _buildFixedBadge('HEX', _hexCode, 82),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // 1. H 滑桿
                    _buildSliderRow(
                      label: 'H (色相)',
                      gradient: hGradient,
                      value: _hue,
                      min: 0,
                      max: 360,
                      onChangeStart: () => widget.controller.beginColorChange(),
                      onChanged: (v) {
                        setState(() => _hue = v);
                        widget.controller.updateColorPreview(_currentColor);
                      },
                      onChangeEnd: () => widget.controller.commitColorChange(_currentColor),
                    ),
                    const SizedBox(height: 14),

                    // 2. S 滑桿
                    _buildSliderRow(
                      label: 'S (彩度)',
                      gradient: sGradient,
                      value: _saturation,
                      min: 0.0,
                      max: 1.0,
                      onChangeStart: () => widget.controller.beginColorChange(),
                      onChanged: (v) {
                        setState(() => _saturation = v);
                        widget.controller.updateColorPreview(_currentColor);
                      },
                      onChangeEnd: () => widget.controller.commitColorChange(_currentColor),
                    ),
                    const SizedBox(height: 14),

                    // 3. B 滑桿
                    _buildSliderRow(
                      label: 'B (明度)',
                      gradient: bGradient,
                      value: _brightness,
                      min: 0.0,
                      max: 1.0,
                      onChangeStart: () => widget.controller.beginColorChange(),
                      onChanged: (v) {
                        setState(() => _brightness = v);
                        widget.controller.updateColorPreview(_currentColor);
                      },
                      onChangeEnd: () => widget.controller.commitColorChange(_currentColor),
                    ),

                    const Divider(height: 24),

                    // 喜愛的顏色
                    Row(
                      children: [
                        const Text('喜愛的顏色 (長按刪除)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                        const Spacer(),
                        TextButton.icon(
                          icon: const Icon(Icons.bookmark_add_outlined, size: 16),
                          label: const Text('收藏當前色', style: TextStyle(fontSize: 12)),
                          onPressed: () {
                            widget.controller.addFavoriteColor(_currentColor);
                            setState(() {});
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // 喜愛顏色清單 (流式排列)
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: widget.controller.favoriteColors.map((color) {
                        final isSelected = widget.controller.strokeColor == color;
                        return GestureDetector(
                          onTap: () => _applyColor(color),
                          onLongPress: () => _confirmDeleteColor(context, color),
                          child: _colorChip(color, isSelected),
                        );
                      }).toList(),
                    ),

                    const Divider(height: 24),

                    // 最近使用的顏色
                    const Text('最近使用 (畫過自動收錄)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: widget.controller.recentColors.map((color) {
                        final isSelected = widget.controller.strokeColor == color;
                        return GestureDetector(
                          onTap: () => _applyColor(color),
                          child: _colorChip(color, isSelected),
                        );
                      }).toList(),
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

  // ★ 解決第 1 點：固定寬度的膠囊標籤 (徹底解決字長變動跳位問題)
  Widget _buildFixedBadge(String label, String value, double width) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 1),
          Text(value, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.black87)),
        ],
      ),
    );
  }

  // ★ 解決第 2 點：乾淨對齊的 Slider 列 (零邊距脫節)
  Widget _buildSliderRow({
    required String label,
    required Gradient gradient,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
    required VoidCallback onChangeStart,
    required VoidCallback onChangeEnd,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 55,
          child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 14,
              trackShape: GradientSliderTrackShape(gradient: gradient),
              thumbColor: Colors.white,
              thumbShape: const RoundSliderThumbShape(
                enabledThumbRadius: 9,
                elevation: 3,
                pressedElevation: 5,
              ),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: value,
              min: min,
              max: max,
              // ★ 按下時記錄初始快照
              onChangeStart: (_) => onChangeStart(),
              // ★ 滑動時只更新預覽，不產 Undo
              onChanged: onChanged,
              // ★ 放開時打包唯一一次 Undo
              onChangeEnd: (_) => onChangeEnd(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _colorChip(Color color, bool isSelected) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: isSelected ? Colors.blueAccent : Colors.grey[300]!,
          width: isSelected ? 3 : 1.5,
        ),
        boxShadow: isSelected
            ? [BoxShadow(color: Colors.blueAccent.withAlpha(120), blurRadius: 5)]
            : null,
      ),
      child: isSelected
          ? Icon(
              Icons.check,
              size: 15,
              color: color.computeLuminance() > 0.5 ? Colors.black : Colors.white,
            )
          : null,
    );
  }
}