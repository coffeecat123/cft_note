// lib/features/canvas/presentation/toolbars/lasso_settings_sheet.dart
//
// 套索設定：選擇圈選對象 (一般筆 / 螢光筆 / 圖片)。
import 'package:flutter/material.dart';

import '../../../../app/theme/app_theme.dart';
import '../../../../core/i18n/app_strings.dart';
import '../controllers/canvas_controller.dart';
import 'target_chips.dart';

class LassoSettingsSheet extends StatefulWidget {
  final CanvasController controller;
  const LassoSettingsSheet({super.key, required this.controller});

  static Future<void> show(BuildContext context, CanvasController controller) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => LassoSettingsSheet(controller: controller),
    );
  }

  @override
  State<LassoSettingsSheet> createState() => _LassoSettingsSheetState();
}

class _LassoSettingsSheetState extends State<LassoSettingsSheet> {
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final cs = context.cs;
    final c = widget.controller;

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
              Text(s.lassoSettings,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 14),
              TargetChips(
                title: s.lassoTargets,
                options: [
                  TargetOption(
                    label: s.targetPen,
                    icon: Icons.edit,
                    selected: c.lassoTargetPen,
                    onChanged: (v) {
                      c.setLassoTargets(pen: v);
                      setState(() {});
                    },
                  ),
                  TargetOption(
                    label: s.highlighter,
                    icon: Icons.highlight,
                    selected: c.lassoTargetHighlighter,
                    onChanged: (v) {
                      c.setLassoTargets(highlighter: v);
                      setState(() {});
                    },
                  ),
                  TargetOption(
                    label: s.targetImage,
                    icon: Icons.image_outlined,
                    selected: c.lassoTargetImage,
                    onChanged: (v) {
                      c.setLassoTargets(image: v);
                      setState(() {});
                    },
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
