// lib/features/canvas/presentation/toolbars/page_background_sheet.dart
//
// 空白頁背景設定：紙張顏色 + 格線 (無 / 橫線 / 直線 / 方格)。
//  - 套用範圍：只改目前頁，或一次改此筆記本的所有空白頁
//  - 新增空白頁的樣式：沿用「上次修改的」，或跟目前頁面一樣
// 每個選項一點就即時套用 (沒有「確定」按鈕)。
import 'package:flutter/material.dart';

import '../../../../app/theme/app_theme.dart';
import '../../../../core/i18n/app_strings.dart';
import '../../../document/domain/page_background.dart';
import '../../domain/models/canvas_prefs.dart';
import '../controllers/canvas_controller.dart';
import 'color_settings_sheet.dart' show GradientSliderTrackShape;

class PageBackgroundSheet extends StatefulWidget {
  final CanvasController controller;
  const PageBackgroundSheet({super.key, required this.controller});

  static Future<void> show(BuildContext context, CanvasController controller) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PageBackgroundSheet(controller: controller),
    );
  }

  @override
  State<PageBackgroundSheet> createState() => _PageBackgroundSheetState();
}

class _PageBackgroundSheetState extends State<PageBackgroundSheet> {
  late bool _scopeAll;
  late PageBackground _bg;
  late NewPageStyle _newStyle;
  bool _showCustom = false;
  bool _changed = false; // 這次開啟選單有修改過 → 關閉時記入「最近使用」
  late double _hue, _sat, _val;

  CanvasController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    // 目前是 PDF 頁面時，只有「所有空白頁」有意義
    _scopeAll = !_c.currentPageIsBlank;
    _bg = _c.backgroundForSheet;
    _newStyle = _c.newPageStyle;
    _syncHsv(_bg.color);
  }

  void _syncHsv(Color color) {
    final hsv = HSVColor.fromColor(color);
    _hue = hsv.hue;
    _sat = hsv.saturation;
    _val = hsv.value;
  }

  bool get _enabled => _scopeAll ? _c.blankPageCount > 0 : _c.currentPageIsBlank;

  @override
  void dispose() {
    // 與「最近使用顏色」相同：把這次設好的樣式 (目前頁面的樣式) 記下來
    if (_changed) _c.recordRecentBackground(_bg);
    super.dispose();
  }

  void _setBg(PageBackground bg) {
    if (!_enabled) return;
    _changed = true;
    setState(() => _bg = bg);
    _c.applyPageBackground(bg, allBlankPages: _scopeAll);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final cs = context.cs;
    final enabled = _enabled;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.9,
      ),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: cs.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.pageBackground,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 14),

                    // ── 預覽 + 套用範圍 ──
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildPreview(cs),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _label(s.applyTo),
                              const SizedBox(height: 6),
                              SizedBox(
                                width: double.infinity,
                                child: SegmentedButton<bool>(
                                  showSelectedIcon: false,
                                  segments: [
                                    ButtonSegment(
                                      value: false,
                                      label: Text(s.scopeCurrentPage,
                                          maxLines: 2,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(fontSize: 12)),
                                    ),
                                    ButtonSegment(
                                      value: true,
                                      label: Text(s.scopeAllBlankPages,
                                          maxLines: 2,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(fontSize: 12)),
                                    ),
                                  ],
                                  selected: {_scopeAll},
                                  onSelectionChanged: (v) =>
                                      setState(() => _scopeAll = v.first),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _scopeAll ? s.scopeAllBlankPagesHint : '',
                                style: TextStyle(
                                    fontSize: 11, color: cs.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    if (!enabled) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline,
                                size: 16, color: cs.onSurfaceVariant),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _scopeAll ? s.noBlankPages : s.currentPageIsPdf,
                                style: TextStyle(
                                    fontSize: 12, color: cs.onSurfaceVariant),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    // ── 紙張顏色 + 格線 (不可用時變淡) ──
                    IgnorePointer(
                      ignoring: !enabled,
                      child: Opacity(
                        opacity: enabled ? 1 : 0.4,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 18),
                            _label(s.paperColor),
                            const SizedBox(height: 8),
                            _buildColorPicker(s, cs),
                            if (_showCustom) _buildCustomSliders(),
                            const SizedBox(height: 18),
                            _label(s.gridLines),
                            const SizedBox(height: 8),
                            _buildGridOptions(s, cs),
                            const SizedBox(height: 8),
                            _buildSpacingSlider(s, cs),
                            if (_c.recentBackgrounds.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              _label(s.recentBackgrounds),
                              const SizedBox(height: 8),
                              _buildRecent(cs),
                            ],
                          ],
                        ),
                      ),
                    ),

                    const Divider(height: 32),

                    // ── 新增空白頁的樣式 ──
                    _label(s.newPageStyle),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<NewPageStyle>(
                        showSelectedIcon: false,
                        segments: [
                          ButtonSegment(
                            value: NewPageStyle.lastUsed,
                            label: Text(s.newPageLastUsed,
                                maxLines: 1,
                                style: const TextStyle(fontSize: 12)),
                          ),
                          ButtonSegment(
                            value: NewPageStyle.currentPage,
                            label: Text(s.newPageSameAsCurrent,
                                maxLines: 1,
                                style: const TextStyle(fontSize: 12)),
                          ),
                        ],
                        selected: {_newStyle},
                        onSelectionChanged: (v) {
                          setState(() => _newStyle = v.first);
                          _c.setNewPageStyle(v.first);
                        },
                      ),
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

  Widget _label(String text) => Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: context.cs.onSurfaceVariant,
        ),
      );

  Widget _buildPreview(ColorScheme cs) {
    return Container(
      width: 84,
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(40), blurRadius: 4),
        ],
      ),
      child: AspectRatio(
        aspectRatio: 595 / 842,
        child: CustomPaint(painter: _PaperPreviewPainter(_bg)),
      ),
    );
  }

  Widget _buildColorPicker(S s, ColorScheme cs) {
    final isPreset = PageBackground.presetColors.contains(_bg.color);
    Widget chip({
      required Color color,
      required bool selected,
      required VoidCallback onTap,
      Widget? child,
      String? tooltip,
    }) {
      final dark = color.computeLuminance() < 0.5;
      return Tooltip(
        message: tooltip ?? '',
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? Colors.blueAccent : cs.outlineVariant,
                width: selected ? 3 : 1.5,
              ),
            ),
            child: selected
                ? Icon(Icons.check,
                    size: 16, color: dark ? Colors.white : Colors.black)
                : child,
          ),
        ),
      );
    }

    return Wrap(
      spacing: 12,
      runSpacing: 10,
      children: [
        for (final color in PageBackground.presetColors)
          chip(
            color: color,
            selected: _bg.color == color,
            onTap: () {
              _syncHsv(color);
              _setBg(_bg.copyWith(color: color));
            },
          ),
        chip(
          color: _showCustom || !isPreset ? _bg.color : cs.surfaceContainerHighest,
          selected: !isPreset,
          tooltip: s.customColor,
          onTap: () => setState(() => _showCustom = !_showCustom),
          child: Icon(Icons.palette_outlined, size: 18, color: cs.onSurface),
        ),
      ],
    );
  }

  Widget _buildCustomSliders() {
    Widget row(String label, Gradient g, double v, double max,
        ValueChanged<double> onChanged) {
      return Row(
        children: [
          SizedBox(
            width: 24,
            child: Text(label,
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 14,
                trackShape: GradientSliderTrackShape(gradient: g),
                thumbColor: Colors.white,
                thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 9, elevation: 3, pressedElevation: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(value: v, min: 0, max: max, onChanged: onChanged),
            ),
          ),
        ],
      );
    }

    void apply() => _setBg(_bg.copyWith(
        color: HSVColor.fromAHSV(1, _hue, _sat, _val).toColor()));

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        children: [
          row(
            'H',
            const LinearGradient(colors: [
              Colors.red, Colors.yellow, Colors.green,
              Colors.cyan, Colors.blue, Colors.purple, Colors.red,
            ]),
            _hue,
            360,
            (v) {
              setState(() => _hue = v);
              apply();
            },
          ),
          row(
            'S',
            LinearGradient(colors: [
              HSVColor.fromAHSV(1, _hue, 0, _val).toColor(),
              HSVColor.fromAHSV(1, _hue, 1, _val).toColor(),
            ]),
            _sat,
            1,
            (v) {
              setState(() => _sat = v);
              apply();
            },
          ),
          row(
            'B',
            LinearGradient(colors: [
              HSVColor.fromAHSV(1, _hue, _sat, 0).toColor(),
              HSVColor.fromAHSV(1, _hue, _sat, 1).toColor(),
            ]),
            _val,
            1,
            (v) {
              setState(() => _val = v);
              apply();
            },
          ),
        ],
      ),
    );
  }

  /// 格線間隔 (沒有格線時停用)
  Widget _buildSpacingSlider(S s, ColorScheme cs) {
    final on = _bg.grid != GridMode.none;
    return Row(
      children: [
        Text(
          '${s.gridSpacing}  ${_bg.spacing.round()}',
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
        Expanded(
          child: Slider(
            value: _bg.spacing
                .clamp(PageBackground.minSpacing, PageBackground.maxSpacing)
                .toDouble(),
            min: PageBackground.minSpacing,
            max: PageBackground.maxSpacing,
            divisions:
                ((PageBackground.maxSpacing - PageBackground.minSpacing) / 2)
                    .round(),
            onChanged:
                on ? (v) => _setBg(_bg.copyWith(spacing: v.roundToDouble())) : null,
          ),
        ),
      ],
    );
  }

  /// 最近使用的背景：點一下套用，長按移除
  Widget _buildRecent(ColorScheme cs) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final b in List.of(_c.recentBackgrounds))
          GestureDetector(
            onTap: () {
              _syncHsv(b.color);
              _setBg(b);
            },
            onLongPress: () {
              _c.removeRecentBackground(b);
              setState(() {});
            },
            child: Container(
              width: 44,
              decoration: BoxDecoration(
                border: Border.all(
                  color: b == _bg ? Colors.blueAccent : cs.outlineVariant,
                  width: b == _bg ? 3 : 1.5,
                ),
              ),
              child: AspectRatio(
                aspectRatio: 595 / 842,
                child: CustomPaint(painter: _PaperPreviewPainter(b)),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildGridOptions(S s, ColorScheme cs) {
    final labels = {
      GridMode.none: s.gridNone,
      GridMode.horizontal: s.gridHorizontal,
      GridMode.vertical: s.gridVertical,
      GridMode.both: s.gridBoth,
    };
    final line = _bg.color.computeLuminance() > 0.5
        ? Colors.black45
        : Colors.white54;

    return Row(
      children: [
        for (final mode in GridMode.values)
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _setBg(_bg.copyWith(grid: mode)),
              child: Column(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: _bg.grid == mode
                            ? Colors.blueAccent
                            : cs.outlineVariant,
                        width: _bg.grid == mode ? 3 : 1.5,
                      ),
                    ),
                    child: CustomPaint(
                      painter: _GridGlyphPainter(mode, _bg.color, line),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    labels[mode]!,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: _bg.grid == mode
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// 整頁縮圖預覽 (和畫布共用同一套繪製)
class _PaperPreviewPainter extends CustomPainter {
  final PageBackground bg;
  _PaperPreviewPainter(this.bg);

  static const _page = Size(595, 842);

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / _page.width;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.scale(scale, size.height / _page.height);
    PageBackgroundPainter.paintPaper(canvas, Offset.zero & _page, bg);
    PageBackgroundPainter.paintGrid(
      canvas,
      _page,
      bg,
      strokeWidth: 1.2 / scale,
      lineColor: bg.gridColor.withAlpha(130),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PaperPreviewPainter old) => old.bg != bg;
}

/// 格線選項的小圖示
class _GridGlyphPainter extends CustomPainter {
  final GridMode mode;
  final Color paper;
  final Color line;
  _GridGlyphPainter(this.mode, this.paper, this.line);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = paper);
    final p = Paint()
      ..color = line
      ..strokeWidth = 1;
    const n = 5;
    if (mode == GridMode.horizontal || mode == GridMode.both) {
      for (var i = 1; i < n; i++) {
        final y = size.height * i / n;
        canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
      }
    }
    if (mode == GridMode.vertical || mode == GridMode.both) {
      for (var i = 1; i < n; i++) {
        final x = size.width * i / n;
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
      }
    }
  }

  @override
  bool shouldRepaint(_GridGlyphPainter old) =>
      old.mode != mode || old.paper != paper || old.line != line;
}
