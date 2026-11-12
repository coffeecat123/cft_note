// lib/features/canvas/presentation/toolbars/eraser_settings_sheet.dart
//
// 橡皮擦大小：滑桿即時調整，上方圓圈預覽 = 畫布上實際看到的大小 (螢幕像素)。
import 'package:flutter/material.dart';

import '../../../../app/theme/app_theme.dart';
import '../../../../core/i18n/app_strings.dart';
import '../controllers/canvas_controller.dart';

class EraserSettingsSheet extends StatefulWidget {
  final CanvasController controller;
  const EraserSettingsSheet({super.key, required this.controller});

  static Future<void> show(BuildContext context, CanvasController controller) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => EraserSettingsSheet(controller: controller),
    );
  }

  @override
  State<EraserSettingsSheet> createState() => _EraserSettingsSheetState();
}

class _EraserSettingsSheetState extends State<EraserSettingsSheet> {
  late double _radius;

  @override
  void initState() {
    super.initState();
    _radius = widget.controller.eraserScreenRadius;
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final cs = context.cs;
    final page = widget.controller.currentPage;
    // 預覽畫在目前這頁的紙張顏色上 (深色紙用白色圈)
    final paper = page.isBlank ? page.background.color : Colors.white;
    final onDark = paper.computeLuminance() < 0.5;

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(s.eraserSettings,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 14),
              Container(
                height: 140,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: paper,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: cs.outlineVariant),
                ),
                alignment: Alignment.center,
                child: Container(
                  width: _radius * 2,
                  height: _radius * 2,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (onDark ? Colors.white : Colors.black).withAlpha(25),
                    border: Border.all(
                      color: onDark ? Colors.white70 : Colors.black54,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    '${s.eraserSize}  ${_radius.round()}',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  Expanded(
                    child: Slider(
                      value: _radius,
                      min: CanvasController.minEraserRadius,
                      max: CanvasController.maxEraserRadius,
                      divisions: (CanvasController.maxEraserRadius -
                              CanvasController.minEraserRadius)
                          .round(),
                      onChanged: (v) {
                        setState(() => _radius = v);
                        widget.controller.setEraserRadius(v);
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
