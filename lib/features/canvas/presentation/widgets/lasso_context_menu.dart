// lib/features/canvas/presentation/widgets/lasso_context_menu.dart
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/i18n/app_strings.dart';
import '../../domain/models/tools.dart';

/// 套索工具的浮動小選單：出現在點擊位置上方，空間不夠時改放下方，並保持在畫面內。
/// 空白區域不會攔截觸控，只有選單本體會。
class LassoContextMenu extends StatelessWidget {
  final LassoMenuKind kind;
  final Offset anchor; // 畫布區域內的點擊位置
  final VoidCallback onCut;
  final VoidCallback onCopy;
  final VoidCallback onDelete;
  final VoidCallback onScreenshot;
  final VoidCallback onPaste;
  final VoidCallback onPasteImage;
  final bool canPasteStrokes; // 套索剪貼簿有筆劃
  final bool canPasteImage; // 系統剪貼簿有圖片

  const LassoContextMenu({
    super.key,
    required this.kind,
    required this.anchor,
    required this.onCut,
    required this.onCopy,
    required this.onDelete,
    required this.onScreenshot,
    required this.onPaste,
    required this.onPasteImage,
    this.canPasteStrokes = true,
    this.canPasteImage = false,
  });

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final items = switch (kind) {
      LassoMenuKind.selection => [
        _item(Icons.content_cut, s.cut, onCut),
        _item(Icons.content_copy, s.copy, onCopy),
        _item(Icons.delete_outline, s.delete, onDelete, color: Colors.redAccent),
        _item(Icons.crop_free, s.screenshot, onScreenshot),
      ],
      LassoMenuKind.region => [_item(Icons.crop_free, s.screenshot, onScreenshot)],
      LassoMenuKind.paste => [
        // 兩種都有時才加註種類，避免使用者分不清
        if (canPasteStrokes)
          _item(
            Icons.content_paste,
            canPasteImage ? s.pasteStrokes : s.paste,
            onPaste,
          ),
        if (canPasteImage)
          _item(
            Icons.image_outlined,
            canPasteStrokes ? s.pasteImage : s.paste,
            onPasteImage,
          ),
      ],
      LassoMenuKind.none => <Widget>[],
    };
    if (items.isEmpty) return const SizedBox.shrink();

    return CustomSingleChildLayout(
      delegate: _MenuLayoutDelegate(anchor),
      child: Material(
        elevation: 8,
        color: const Color(0xFF2B2D31),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: items),
        ),
      ),
    );
  }

  Widget _item(IconData icon, String label, VoidCallback onTap, {Color? color}) {
    final c = color ?? Colors.white;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: c),
            const SizedBox(height: 3),
            Text(label, style: TextStyle(fontSize: 11, color: c)),
          ],
        ),
      ),
    );
  }
}

class _MenuLayoutDelegate extends SingleChildLayoutDelegate {
  final Offset anchor;
  _MenuLayoutDelegate(this.anchor);

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const margin = 8.0, gap = 16.0;
    final maxX = math.max(margin, size.width - childSize.width - margin);
    final x = (anchor.dx - childSize.width / 2).clamp(margin, maxX).toDouble();

    double y = anchor.dy - childSize.height - gap; // 優先放在手指上方
    if (y < margin) y = anchor.dy + gap + 24; // 上方放不下 → 放下方 (避開手指)
    final maxY = math.max(margin, size.height - childSize.height - margin);
    y = y.clamp(margin, maxY).toDouble();
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_MenuLayoutDelegate old) => old.anchor != anchor;
}
