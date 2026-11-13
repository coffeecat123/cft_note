// lib/features/shelf/presentation/widgets/notebook_thumbnail.dart
//
// 筆記本的「第一頁預覽圖」：書架方格卡片與精簡清單共用。
// - 空白頁：紙張顏色 + 格線 + 筆劃
// - PDF 頁：優先用頁面已有的底圖；沒有就按需渲染一張小圖 (本元件自己持有、自己釋放)
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../document/domain/note_page.dart';
import '../../../document/domain/page_background.dart';
import '../../../pdf_import_export/services/pdf_service.dart';
import '../../domain/models/notebook.dart';

class NotebookThumbnail extends StatefulWidget {
  final Notebook notebook;

  /// 縮圖的邏輯寬度 (用來決定 PDF 渲染解析度)。
  final double logicalWidth;

  const NotebookThumbnail({
    super.key,
    required this.notebook,
    required this.logicalWidth,
  });

  /// 第一頁的寬高比 (沒有頁面時用 A4)
  static double aspectOf(Notebook nb) {
    if (nb.pages.isEmpty) return 595.0 / 842.0;
    final p = nb.pages.first;
    if (p.height <= 0) return 595.0 / 842.0;
    return p.width / p.height;
  }

  @override
  State<NotebookThumbnail> createState() => _NotebookThumbnailState();
}

class _NotebookThumbnailState extends State<NotebookThumbnail> {
  ui.Image? _rendered; // 自己渲染的 PDF 縮圖 (需自行釋放)
  String? _renderedKey;
  String? _renderedPageKey; // _rendered 屬於哪一頁 (pdf 檔#頁碼)；換頁 / 換筆記本後不可沿用
  String? _loadingKey;

  static String? _pageKeyOf(NotePage? p) =>
      (p == null || p.pdfFilePath == null || p.pdfPageNumber == null)
          ? null
          : '${p.pdfFilePath}#${p.pdfPageNumber}';

  @override
  void didUpdateWidget(covariant NotebookThumbnail old) {
    super.didUpdateWidget(old);
    // 書架重排 / 新增副本時，State 可能被位置重用給另一本筆記本：
    // 舊的縮圖不屬於新的第一頁就立刻丟掉，避免顯示成別本的圖示
    if (_renderedPageKey != _pageKeyOf(_first)) {
      _rendered?.dispose();
      _rendered = null;
      _renderedKey = null;
      _renderedPageKey = null;
      _loadingKey = null;
    }
  }

  NotePage? get _first =>
      widget.notebook.pages.isEmpty ? null : widget.notebook.pages.first;

  @override
  void dispose() {
    _rendered?.dispose();
    _rendered = null;
    super.dispose();
  }

  Future<void> _ensureRendered() async {
    final page = _first;
    if (page == null ||
        page.cachedBackgroundImage != null ||
        page.pdfFilePath == null ||
        page.pdfPageNumber == null) {
      return;
    }
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final pageKey = _pageKeyOf(page)!;
    final key = '$pageKey'
        '@${widget.logicalWidth.round()}x${dpr.toStringAsFixed(1)}';
    if (_renderedKey == key || _loadingKey == key) return;
    _loadingKey = key;

    final scale = (widget.logicalWidth * dpr / page.width).clamp(0.05, 2.0);
    final img = await PdfService.renderPageImage(
      page.pdfFilePath!,
      page.pdfPageNumber!,
      scale,
    );
    if (_loadingKey == key) _loadingKey = null;
    if (img == null) return;
    if (!mounted) {
      img.dispose();
      return;
    }
    // 等待渲染期間第一頁已換成別的 → 這張圖沒人要了
    if (_pageKeyOf(_first) != pageKey) {
      img.dispose();
      return;
    }
    final old = _rendered;
    setState(() {
      _rendered = img;
      _renderedKey = key;
      _renderedPageKey = pageKey;
    });
    old?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final page = _first;
    if (page == null) {
      return const ColoredBox(color: Colors.white);
    }
    _ensureRendered();
    // 只有「屬於這一頁」的自繪縮圖才能用；空白頁絕不使用
    final own = _renderedPageKey == _pageKeyOf(page) ? _rendered : null;
    return RepaintBoundary(
      child: CustomPaint(
        painter: _FirstPagePainter(
          page: page,
          bg: page.cachedBackgroundImage ?? own,
          strokeCount: page.strokes.length,
          stamp: widget.notebook.updatedAt,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// 第一頁縮圖：紙張 + 底圖 (或空白頁格線) + 筆劃，整體等比縮小
class _FirstPagePainter extends CustomPainter {
  final NotePage page;
  final ui.Image? bg;
  final int strokeCount;
  final DateTime stamp;

  /// 建立時的背景快照 (page 是同一個物件，單靠 page 比較偵測不到背景改變)
  final PageBackground background;

  _FirstPagePainter({
    required this.page,
    required this.bg,
    required this.strokeCount,
    required this.stamp,
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
        strokeWidth: 2.0, // 縮圖縮很小，線條加粗才看得到
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
  bool shouldRepaint(covariant _FirstPagePainter old) =>
      old.page != page ||
      old.bg != bg ||
      old.strokeCount != strokeCount ||
      old.stamp != stamp ||
      old.background != background;
}
