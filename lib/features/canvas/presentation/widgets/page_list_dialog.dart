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
import '../../../document/data/page_image_store.dart';
import '../../../document/domain/page_background.dart';
import '../../../document/domain/page_image.dart';
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
  bool _onlyBookmarks = false; // 只顯示書籤頁

  // 頁面上的圖片縮圖：對話框自己從檔案載入縮小版 (不動主畫布持有的 ui.Image)
  final Map<String, ui.Image> _imgs = {}; // key = 圖檔名
  final Set<String> _imgLoading = {};
  final Set<String> _imgFailed = {};

  // 多選刪除
  bool _selecting = false;
  final Set<int> _selected = {};

  @override
  void dispose() {
    _scroll.dispose();
    for (final img in _rendered.values) {
      img.dispose();
    }
    _rendered.clear();
    for (final img in _imgs.values) {
      img.dispose();
    }
    _imgs.clear();
    super.dispose();
  }

  /// 頁面上有圖片但尚未解碼 → 載入縮小版供縮圖使用
  void _ensureImages(NotePage page, double logicalWidth) {
    for (final pi in page.images) {
      if (pi.image != null ||
          _imgs.containsKey(pi.fileName) ||
          _imgFailed.contains(pi.fileName) ||
          !_imgLoading.add(pi.fileName)) {
        continue;
      }
      _loadImageThumb(pi, logicalWidth);
    }
  }

  Future<void> _loadImageThumb(PageImage pi, double logicalWidth) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? desc;
    ui.Codec? codec;
    ui.Image? result;
    try {
      final file = await PageImageStore.fileFor(pi);
      if (!await file.exists()) {
        _imgFailed.add(pi.fileName);
        return;
      }
      buffer = await ui.ImmutableBuffer.fromUint8List(await file.readAsBytes());
      desc = await ui.ImageDescriptor.encoded(buffer);
      final dpr = mounted ? MediaQuery.of(context).devicePixelRatio : 2.0;
      // 圖片可能佔滿整頁，解碼寬度以縮圖寬度為準 (留一點餘裕)
      final tw = (logicalWidth * dpr * 1.5).round().clamp(64, 1024);
      codec = await desc.instantiateCodec(
        targetWidth: desc.width > tw ? tw : null,
      );
      result = (await codec.getNextFrame()).image;
    } catch (_) {
      _imgFailed.add(pi.fileName);
    } finally {
      codec?.dispose();
      desc?.dispose();
      buffer?.dispose();
      _imgLoading.remove(pi.fileName);
    }
    if (result == null) return;
    if (!mounted) {
      result.dispose();
      return;
    }
    setState(() => _imgs[pi.fileName] = result!);
  }

  ui.Image? _imageFor(PageImage pi) => pi.image ?? _imgs[pi.fileName];

  /// 該頁圖片的載入狀態簽章 (變了縮圖才重畫)
  int _imageSig(NotePage page) {
    int loaded = 0;
    for (final pi in page.images) {
      if (_imageFor(pi) != null) loaded++;
    }
    return page.images.length * 1000 + loaded;
  }

  Future<void> _confirmDeleteSelected() async {
    final s = S.of(context);
    final n = _selected.length;
    if (n == 0 || n >= widget.controller.pages.length) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.deleteSelectedPages),
        content: Text(s.confirmDeletePages(n)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.cancel),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.delete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final pages = widget.controller.pages;
    final removed = [
      for (final i in _selected)
        if (i >= 0 && i < pages.length) pages[i],
    ];
    widget.controller.deletePages(Set.of(_selected));
    for (final p in removed) {
      _rendered.remove(p)?.dispose();
    }
    setState(() {
      _selected.clear();
      _selecting = false;
      _jumped = false;
    });
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
    final s = S.of(context);
    // 顯示的頁面 (原始頁碼)；篩選書籤時只留有書籤的
    final shown = <int>[
      for (int i = 0; i < pages.length; i++)
        if (!_onlyBookmarks || pages[i].bookmarked) i,
    ];
    final bookmarkCount = pages.where((p) => p.bookmarked).length;

    // 尺寸依螢幕比例
    final dialogW = (screen.width * 0.8);
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
                      _selecting
                          ? s.selectedPagesCount(_selected.length)
                          : _onlyBookmarks
                          ? s.bookmarkedPagesTitle(bookmarkCount, pages.length)
                          : s.allPagesTitle(pages.length),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (_selecting) ...[
                    TextButton(
                      onPressed: () => setState(() {
                        if (_selected.length == shown.length) {
                          _selected.clear();
                        } else {
                          _selected
                            ..clear()
                            ..addAll(shown);
                        }
                      }),
                      child: Text(
                        _selected.length == shown.length && shown.isNotEmpty
                            ? s.deselectAll
                            : s.selectAll,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 22),
                      color: Colors.redAccent,
                      tooltip: _selected.length >= pages.length
                          ? s.keepAtLeastOnePage
                          : s.deleteSelectedPages,
                      onPressed:
                          _selected.isEmpty || _selected.length >= pages.length
                          ? null
                          : _confirmDeleteSelected,
                    ),
                  ] else ...[
                    IconButton(
                      icon: Icon(
                        _onlyBookmarks ? Icons.bookmark : Icons.bookmark_border,
                        size: 22,
                        color: _onlyBookmarks ? Colors.amber : null,
                      ),
                      tooltip: _onlyBookmarks
                          ? s.showAllPages
                          : s.showBookmarksOnly,
                      onPressed: () => setState(() {
                        _onlyBookmarks = !_onlyBookmarks;
                        _jumped = false; // 換了清單，重新捲到目前頁
                        if (_scroll.hasClients) _scroll.jumpTo(0);
                      }),
                    ),
                    IconButton(
                      icon: const Icon(Icons.checklist_rounded, size: 22),
                      tooltip: s.selectPages,
                      onPressed: () => setState(() {
                        _selecting = true;
                        _selected.clear();
                      }),
                    ),
                  ],
                  IconButton(
                    icon: Icon(
                      _selecting ? Icons.done : Icons.close,
                      size: 20,
                    ),
                    onPressed: () {
                      if (_selecting) {
                        setState(() {
                          _selecting = false;
                          _selected.clear();
                        });
                      } else {
                        Navigator.pop(context);
                      }
                    },
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

                  if (shown.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: EdgeInsets.all(pad * 2),
                        child: Text(
                          s.noBookmarks,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: context.cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                    );
                  }

                  // 第一次排版後，捲到目前頁面所在列
                  if (!_jumped) {
                    _jumped = true;
                    final pos = shown.indexOf(current);
                    final row = (pos < 0 ? 0 : pos) ~/ cols;
                    final target = (row * (cellH + gap) - cellH * 0.5);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!_scroll.hasClients) return;
                      _scroll.jumpTo(
                        target.clamp(0.0, _scroll.position.maxScrollExtent),
                      );
                    });
                  }

                  // 捲軸加粗加長，手指才好抓；格子右側留出捲軸的位置
                  return ScrollbarTheme(
                    data: ScrollbarThemeData(
                      thickness: const WidgetStatePropertyAll(10),
                      radius: const Radius.circular(5),
                      minThumbLength: 50,
                      thumbColor: WidgetStatePropertyAll(
                        context.cs.primary.withAlpha(150),
                      ),
                      trackColor: WidgetStatePropertyAll(
                        context.cs.onSurface.withAlpha(18),
                      ),
                      trackBorderColor: const WidgetStatePropertyAll(
                        Colors.transparent,
                      ),
                    ),
                    child: Scrollbar(
                    controller: _scroll,
                    thumbVisibility: true,
                    trackVisibility: true,
                    interactive: true,
                    child: GridView.builder(
                      controller: _scroll,
                      padding: EdgeInsets.fromLTRB(pad, pad, pad + 20, pad),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        crossAxisSpacing: gap,
                        mainAxisSpacing: gap,
                        mainAxisExtent: cellH,
                      ),
                      itemCount: shown.length,
                      itemBuilder: (ctx, k) {
                        final i = shown[k];
                        final page = pages[i];
                        final isCurrent = i == current;
                        _ensureThumb(page, cellW);
                        _ensureImages(page, cellW);
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
      onTap: () {
        if (_selecting) {
          setState(() {
            if (!_selected.add(index)) _selected.remove(index);
          });
        } else {
          Navigator.pop(context, index);
        }
      },
      child: Column(
        children: [
          Stack(
            children: [
          Container(
            width: cellW,
            height: thumbBoxH,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: context.cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _selecting && _selected.contains(index)
                    ? Colors.redAccent
                    : isCurrent
                    ? Colors.blueAccent
                    : context.cs.outlineVariant,
                width: (isCurrent || (_selecting && _selected.contains(index)))
                    ? 2.5
                    : 1,
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
                      imageOf: _imageFor,
                      imageSig: _imageSig(page),
                    ),
                  ),
                ),
              ),
            ),
          ),
              if (_selecting)
                Positioned(
                  top: 4,
                  left: 4,
                  child: Icon(
                    _selected.contains(index)
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 24,
                    color: _selected.contains(index)
                        ? Colors.blueAccent
                        : context.cs.onSurface.withAlpha(140),
                  ),
                ),
              // 書籤：點一下加入 / 移除 (已加入的一直顯示，沒加入的淡淡的)
              Positioned(
                top: 0,
                right: 2,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    widget.controller.toggleBookmark(index);
                    setState(() {});
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      page.bookmarked ? Icons.bookmark : Icons.bookmark_border,
                      size: 32,
                      color: page.bookmarked
                          ? Colors.amber
                          : context.cs.onSurface.withAlpha(110),
                    ),
                  ),
                ),
              ),
            ],
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

  /// 取得頁面上某張圖片已解碼的縮圖 (沒有就回傳 null，畫灰底)
  final ui.Image? Function(PageImage) imageOf;
  final int imageSig;

  /// 建立時的背景快照 (page 是同一個物件，單靠 page 比較偵測不到背景改變)
  final PageBackground background;

  _PageThumbPainter({
    required this.page,
    required this.bg,
    required this.strokeCount,
    required this.imageOf,
    required this.imageSig,
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

    // 使用者放上去的圖片 (在底圖之上、筆劃之下，與畫布相同的疊放順序)
    final photoPaint = Paint()..filterQuality = FilterQuality.medium;
    for (final pi in page.images) {
      final bmp = imageOf(pi);
      canvas.save();
      if (pi.rotation != 0) {
        final c = pi.rect.center;
        canvas.translate(c.dx, c.dy);
        canvas.rotate(pi.rotation);
        canvas.translate(-c.dx, -c.dy);
      }
      if (bmp == null) {
        canvas.drawRect(
          pi.rect,
          Paint()..color = Colors.grey.withAlpha(pi.missing ? 90 : 50),
        );
      } else {
        canvas.drawImageRect(
          bmp,
          Rect.fromLTWH(0, 0, bmp.width.toDouble(), bmp.height.toDouble()),
          pi.rect,
          photoPaint,
        );
      }
      canvas.restore();
    }

    for (final stroke in page.strokes) {
      canvas.drawPath(stroke.outlinePath, stroke.fillPaint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PageThumbPainter old) =>
      old.page != page ||
      old.bg != bg ||
      old.strokeCount != strokeCount ||
      old.imageSig != imageSig ||
      old.background != background;
}
