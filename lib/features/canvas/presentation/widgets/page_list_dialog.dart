// lib/features/canvas/presentation/widgets/page_list_dialog.dart
//
// 頁面列表：縮圖格狀排列 (類似檔案總管的「中圖示」)，附捲軸，點選即跳頁。
// 尺寸全部依螢幕比例計算；PDF 頁面的縮圖按需渲染、關閉對話框時釋放。
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cft_note/features/document/domain/note_page.dart';
import 'package:flutter/material.dart';

import '../../../../app/theme/app_theme.dart';
import '../../../../core/i18n/app_strings.dart';
import '../../../document/domain/page_background.dart';
import '../../../pdf_import_export/services/pdf_service.dart';
import '../controllers/canvas_controller.dart';

class PageListDialog extends StatefulWidget {
  final CanvasController controller;
  const PageListDialog({super.key, required this.controller});

  /// 回傳使用者選的頁碼 (0-based)；取消則為 null
  static Future<int?> show(BuildContext context, CanvasController controller) {
    // 先把目前頁的筆劃同步回 page，縮圖才會是最新內容
    controller.saveCurrentPage();
    return showDialog<int>(
      context: context,
      builder: (_) => PageListDialog(controller: controller),
    );
  }

  @override
  State<PageListDialog> createState() => _PageListDialogState();
}

class _PageListDialogState extends State<PageListDialog> {
  final ScrollController _scroll = ScrollController();
  final Map<NotePage, ui.Image> _rendered = {}; // 本對話框自己渲染的縮圖 (需自行釋放)
  final Set<NotePage> _loading = {};
  bool _jumped = false;

  @override
  void dispose() {
    _scroll.dispose();
    for (final img in _rendered.values) {
      img.dispose();
    }
    _rendered.clear();
    super.dispose();
  }

  /// 該頁沒有現成底圖、但是 PDF 頁 → 渲染一張小圖
  Future<void> _ensureThumb(NotePage page, double logicalWidth) async {
    if (page.cachedBackgroundImage != null ||
        page.pdfFilePath == null ||
        page.pdfPageNumber == null ||
        _rendered.containsKey(page) ||
        !_loading.add(page)) {
      return;
    }
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final scale = (logicalWidth * dpr / page.width).clamp(0.05, 2.0);
    final img = await PdfService.renderPageImage(
      page.pdfFilePath!,
      page.pdfPageNumber!,
      scale,
    );
    _loading.remove(page);
    if (img == null) return;
    if (!mounted) {
      img.dispose();
      return;
    }
    setState(() => _rendered[page] = img);
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final pages = widget.controller.pages;
    final current = widget.controller.currentPageIndex;

    // 尺寸依螢幕比例
    final dialogW = (screen.width * 0.6).clamp(280.0, 640.0);
    final dialogH = screen.height * 0.75;
    final pad = (dialogW * 0.03).clamp(8.0, 16.0);
    final gap = (dialogW * 0.025).clamp(8.0, 14.0);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: dialogW,
        height: dialogH,
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(pad + 4, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      S.of(context).allPagesTitle(pages.length),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  final innerW = box.maxWidth - pad * 2;
                  // 每格約佔對話框寬度的 1/4，至少 2 欄
                  final cols = math.max(2, (innerW / (dialogW * 0.24)).floor());
                  final cellW = (innerW - gap * (cols - 1)) / cols;
                  final thumbBoxH = cellW * 1.3; // 縮圖區 (約 A4 比例再留邊)
                  const labelH = 24.0;
                  final cellH = thumbBoxH + labelH;

                  // 第一次排版後，捲到目前頁面所在列
                  if (!_jumped) {
                    _jumped = true;
                    final row = current ~/ cols;
                    final target = (row * (cellH + gap) - cellH * 0.5);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!_scroll.hasClients) return;
                      _scroll.jumpTo(
                        target.clamp(0.0, _scroll.position.maxScrollExtent),
                      );
                    });
                  }

                  return Scrollbar(
                    controller: _scroll,
                    thumbVisibility: true,
                    interactive: true,
                    child: GridView.builder(
                      controller: _scroll,
                      padding: EdgeInsets.all(pad),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        crossAxisSpacing: gap,
                        mainAxisSpacing: gap,
                        mainAxisExtent: cellH,
                      ),
                      itemCount: pages.length,
                      itemBuilder: (ctx, i) {
                        final page = pages[i];
                        final isCurrent = i == current;
                        _ensureThumb(page, cellW);
                        final bg =
                            page.cachedBackgroundImage ?? _rendered[page];
                        return _buildCell(
                          index: i,
                          page: page,
                          bg: bg,
                          isCurrent: isCurrent,
                          cellW: cellW,
                          thumbBoxH: thumbBoxH,
                          labelH: labelH,
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCell({
    required int index,
    required NotePage page,
    required ui.Image? bg,
    required bool isCurrent,
    required double cellW,
    required double thumbBoxH,
    required double labelH,
  }) {
    final aspect = page.width / page.height;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => Navigator.pop(context, index),
      child: Column(
        children: [
          Container(
            width: cellW,
            height: thumbBoxH,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: context.cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isCurrent ? Colors.blueAccent : context.cs.outlineVariant,
                width: isCurrent ? 2.5 : 1,
              ),
            ),
            padding: const EdgeInsets.all(5),
            child: AspectRatio(
              aspectRatio: aspect,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(40),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _PageThumbPainter(
                      page: page,
                      bg: bg,
                      strokeCount: page.strokes.length,
                    ),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            height: labelH,
            child: Center(
              child: Text(
                '${index + 1}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isCurrent ? FontWeight.w700 : FontWeight.normal,
                  color: isCurrent ? Colors.blueAccent : context.cs.onSurface,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 單頁縮圖：紙張 + 底圖 (或空白頁格線) + 筆劃，整體等比縮小
class _PageThumbPainter extends CustomPainter {
  final NotePage page;
  final ui.Image? bg;
  final int strokeCount;

  /// 建立時的背景快照 (page 是同一個物件，單靠 page 比較偵測不到背景改變)
  final PageBackground background;

  _PageThumbPainter({
    required this.page,
    required this.bg,
    required this.strokeCount,
  }) : background = page.background;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final pageRect = Rect.fromLTWH(0, 0, page.width, page.height);

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.scale(size.width / page.width, size.height / page.height);

    final bool isBlank = page.isBlank;
    canvas.drawRect(
      pageRect,
      Paint()..color = isBlank ? background.color : Colors.white,
    );

    final image = bg;
    if (image != null) {
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        pageRect,
        Paint()..filterQuality = FilterQuality.medium,
      );
    } else if (isBlank) {
      PageBackgroundPainter.paintGrid(
        canvas,
        Size(page.width, page.height),
        background,
        strokeWidth: 2.0, // 縮圖縮小很多，線條加粗才看得到
      );
    }

    canvas.clipRect(pageRect);
    final paint = Paint()..style = PaintingStyle.fill;
    for (final stroke in page.strokes) {
      paint.color = stroke.color;
      canvas.drawPath(stroke.outlinePath, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PageThumbPainter old) =>
      old.page != page ||
      old.bg != bg ||
      old.strokeCount != strokeCount ||
      old.background != background;
}
