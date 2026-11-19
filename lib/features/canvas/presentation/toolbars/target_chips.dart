// lib/features/canvas/presentation/toolbars/target_chips.dart
//
// 橡皮擦 / 套索設定面板共用：可多選的「對象」晶片。至少要保留一項 (最後一項不能取消)。
import 'package:flutter/material.dart';

import '../../../../core/i18n/app_strings.dart';

class TargetOption {
  final String label;
  final IconData icon;
  final bool selected;
  final ValueChanged<bool> onChanged;
  const TargetOption({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onChanged,
  });
}

class TargetChips extends StatelessWidget {
  final String title;
  final List<TargetOption> options;
  const TargetChips({super.key, required this.title, required this.options});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final selectedCount = options.where((o) => o.selected).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final o in options)
              Tooltip(
                // 只剩這一項時不能取消：給個提示
                message: (o.selected && selectedCount == 1) ? s.keepOneTarget : '',
                child: FilterChip(
                  avatar: Icon(o.icon, size: 16),
                  label: Text(o.label),
                  selected: o.selected,
                  onSelected: (o.selected && selectedCount == 1)
                      ? null
                      : o.onChanged,
                ),
              ),
          ],
        ),
      ],
    );
  }
}
