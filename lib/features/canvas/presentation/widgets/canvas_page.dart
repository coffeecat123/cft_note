// lib/features/canvas/presentation/widgets/canvas_page.dart
import 'dart:ui';

import 'package:cft_note/features/document/data/storage_service.dart';
import 'package:flutter/material.dart';

import '../../../pdf_import_export/services/pdf_export_service.dart';
import '../../../pdf_import_export/services/pdf_service.dart';
import '../../../shelf/presentation/controllers/shelf_controller.dart';
import '../../domain/models/tools.dart';
import '../controllers/canvas_controller.dart';
import '../toolbars/brush_settings_sheet.dart';
import '../toolbars/color_settings_sheet.dart';
import 'canvas_painters.dart';

class CanvasPage extends StatefulWidget {
  final ShelfController shelfController;

  const CanvasPage({super.key, required this.shelfController});

  @override
  State<CanvasPage> createState() => _CanvasPageState();
}

class _CanvasPageState extends State<CanvasPage> {
  late final CanvasController _controller;

  @override
  void initState() {
    super.initState();
    // ★ 接收書架中常駐的 openTabs 與 activeTabIndex
    _controller = CanvasController(
      initialNotebooks: widget.shelfController.openTabs,
      initialIndex: widget.shelfController.activeTabIndex,
    );
    _controller.addListener(() => setState(() {}));
    // 第一個 frame 排版完成、知道可視範圍後，若還原的視野是放大狀態就補上高清圖塊
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.refreshDetail();
    });
  }

  @override
  void dispose() {
    _controller.saveCurrentPage();
    // ★ 同步標籤清單與聚焦索引回書架
    widget.shelfController.activeTabIndex = _controller.activeNotebookIndex;
    widget.shelfController.openTabs.clear();
    widget.shelfController.openTabs.addAll(_controller.openNotebooks);
    widget.shelfController.notifyNotebookUpdated(); // 立即存檔到硬碟！
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),

      // 頂部雙層 Bar (標籤列 38px + 工具列 50px)
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(88),
        child: Container(
          color: const Color(0xFFE9ECEF), // 與標籤列相同的背景色，向上延伸覆蓋
          child: SafeArea(
            bottom: false, // 僅頂部 SafeArea
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ==========================================
                // 1. 頂部多標籤頁列 (Tab Bar) - 已移除 + 號
                // ==========================================
                Container(
                  height: 38,
                  color: const Color(0xFFE9ECEF),
                  child: Row(
                    children: [
                      // 返回首頁書架
                      IconButton(
                        icon: const Icon(
                          Icons.home_outlined,
                          size: 20,
                          color: Colors.black87,
                        ),
                        tooltip: '返回我的筆記櫃',
                        onPressed: () {
                          _controller.saveCurrentPage();
                          widget.shelfController.activeTabIndex =
                              _controller.activeNotebookIndex;
                          Navigator.of(context).pop();
                        },
                      ),
                      const VerticalDivider(width: 1, indent: 8, endIndent: 8),

                      // 橫向捲動的標籤清單
                      Expanded(
                        child: ScrollConfiguration(
                          behavior: const MaterialScrollBehavior().copyWith(
                            dragDevices: {
                              PointerDeviceKind.mouse,
                              PointerDeviceKind.touch,
                              PointerDeviceKind.stylus,
                              PointerDeviceKind.trackpad,
                            },
                          ),
                          child: ReorderableListView.builder(
                            scrollDirection: Axis.horizontal,
                            // 拖曳結束時觸發排序並存檔
                            onReorderItem: (oldIndex, newIndex) {
                              _controller.reorderTabs(oldIndex, newIndex);
                              widget.shelfController.activeTabIndex =
                                  _controller.activeNotebookIndex;
                              StorageService.saveSession(
                                openTabIds: _controller.openNotebooks
                                    .map((n) => n.id)
                                    .toList(),
                                activeTabIndex: _controller.activeNotebookIndex,
                              );
                            },
                            // ★ 拖曳時的懸浮立體效果 (像 Chrome 一樣浮起來)
                            proxyDecorator: (child, index, animation) {
                              return AnimatedBuilder(
                                animation: animation,
                                builder: (context, child) {
                                  final double animValue = Curves.easeInOut
                                      .transform(animation.value);
                                  final double elevation = lerpDouble(
                                    0,
                                    8,
                                    animValue,
                                  )!;
                                  return Material(
                                    elevation: elevation,
                                    color: Colors.transparent,
                                    shadowColor: Colors.black.withAlpha(90),
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(8),
                                    ),
                                    child: child,
                                  );
                                },
                                child: child,
                              );
                            },
                            itemCount: _controller.openNotebooks.length,
                            itemBuilder: (context, index) {
                              final nb = _controller.openNotebooks[index];
                              final isActive =
                                  index == _controller.activeNotebookIndex;

                              return Container(
                                // ★ ReorderableList 的每個項目必須要有唯一的 Key！
                                key: ValueKey(nb.id),
                                margin: const EdgeInsets.only(top: 4, right: 4),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: isActive
                                      ? Colors.white
                                      : const Color(0xFFDFE3E6),
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(8),
                                  ),
                                  border: isActive
                                      ? Border.all(
                                          color: Colors.black12,
                                          width: 0.5,
                                        )
                                      : null,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // 點擊切換標籤 (單擊切換，長按/拖動為排序)
                                    GestureDetector(
                                      onTap: () {
                                        _controller.switchTab(index);
                                        widget.shelfController.activeTabIndex =
                                            index;
                                      },
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const SizedBox(width: 12),
                                          ConstrainedBox(
                                            constraints: const BoxConstraints(
                                              minWidth: 20,
                                              maxWidth: 120,
                                            ),
                                            child: Text(
                                              nb.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: isActive
                                                    ? FontWeight.bold
                                                    : FontWeight.normal,
                                                color: isActive
                                                    ? Colors.black87
                                                    : Colors.black54,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 12),

                                    // 關閉標籤 (×)
                                    InkWell(
                                      borderRadius: BorderRadius.circular(10),
                                      onTap: () =>
                                          _controller.closeTab(index, () {
                                            Navigator.of(context).pop();
                                          }),
                                      child: const Padding(
                                        padding: EdgeInsets.all(2.0),
                                        child: Icon(
                                          Icons.close,
                                          size: 14,
                                          color: Colors.grey,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // ==========================================
                // 2. 工具列 (Tool Bar)
                // ==========================================
                Container(
                  height: 50,
                  color: Colors.white,
                  child: Row(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 12, right: 8),
                        child: _buildPageNavPill(context),
                      ),
                      const VerticalDivider(
                        width: 1,
                        indent: 12,
                        endIndent: 12,
                        color: Colors.black12,
                      ),

                      Expanded(
                        child: ScrollConfiguration(
                          behavior: const MaterialScrollBehavior().copyWith(
                            dragDevices: {
                              PointerDeviceKind.mouse,
                              PointerDeviceKind.touch,
                              PointerDeviceKind.stylus,
                              PointerDeviceKind.trackpad,
                            },
                          ),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.undo, size: 20),
                                  tooltip: '復原',
                                  onPressed: _controller.canUndo
                                      ? _controller.undo
                                      : null,
                                ),
                                IconButton(
                                  icon: const Icon(Icons.redo, size: 20),
                                  tooltip: '重做',
                                  onPressed: _controller.canRedo
                                      ? _controller.redo
                                      : null,
                                ),
                                const VerticalDivider(
                                  width: 16,
                                  indent: 14,
                                  endIndent: 14,
                                ),

                                // 智慧筆刷按鈕 (未選中切換，已選中開啟工作室)
                                IconButton(
                                  icon: Icon(
                                    Icons.edit,
                                    color:
                                        _controller.currentTool ==
                                            DrawingTool.pen
                                        ? Colors.blue
                                        : Colors.grey[700],
                                    size: 20,
                                  ),
                                  tooltip:
                                      _controller.currentTool == DrawingTool.pen
                                      ? '開啟筆刷工作室'
                                      : '筆刷',
                                  onPressed: () {
                                    if (_controller.currentTool !=
                                        DrawingTool.pen) {
                                      _controller.setTool(DrawingTool.pen);
                                    } else {
                                      showModalBottomSheet(
                                        context: context,
                                        isScrollControlled: true,
                                        backgroundColor: Colors.transparent,
                                        builder: (ctx) => BrushSettingsSheet(
                                          controller: _controller,
                                        ),
                                      );
                                    }
                                  },
                                ),

                                // 橡皮擦
                                IconButton(
                                  icon: Icon(
                                    Icons.cleaning_services_rounded,
                                    color:
                                        _controller.currentTool ==
                                            DrawingTool.eraser
                                        ? Colors.blue
                                        : Colors.grey[700],
                                    size: 20,
                                  ),
                                  tooltip: '筆畫橡皮擦',
                                  onPressed: () =>
                                      _controller.setTool(DrawingTool.eraser),
                                ),

                                // 套索工具
                                IconButton(
                                  icon: Icon(
                                    Icons.gesture,
                                    color:
                                        _controller.currentTool ==
                                            DrawingTool.lasso
                                        ? Colors.blue
                                        : Colors.grey[700],
                                    size: 20,
                                  ),
                                  tooltip: '套索工具',
                                  onPressed: () =>
                                      _controller.setTool(DrawingTool.lasso),
                                ),

                                // ★ 新增：匯出 PDF 按鈕
                                IconButton(
                                  icon: const Icon(
                                    Icons.picture_as_pdf_outlined,
                                    size: 20,
                                    color: Colors.blueAccent,
                                  ),
                                  tooltip: '匯出為 PDF 文件',
                                  onPressed: () async {
                                    _controller.saveCurrentPage();
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('正在合成向量 PDF...'),
                                        duration: Duration(seconds: 1),
                                      ),
                                    );

                                    final success =
                                        await PdfExportService.exportNotebook(
                                          _controller.currentNotebook,
                                        );
                                    if (success && context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                            const SnackBar(
                                              content: Text('PDF 匯出成功！'),
                                            ),
                                          );
                                    }
                                  },
                                ),

                                const VerticalDivider(
                                  width: 16,
                                  indent: 14,
                                  endIndent: 14,
                                ),

                                // 色彩按鈕
                                GestureDetector(
                                  onTap: () {
                                    showModalBottomSheet(
                                      context: context,
                                      isScrollControlled: true,
                                      backgroundColor: Colors.transparent,
                                      builder: (ctx) => ColorSettingsSheet(
                                        controller: _controller,
                                      ),
                                    );
                                  },
                                  child: Container(
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                    ),
                                    width: 26,
                                    height: 26,
                                    decoration: BoxDecoration(
                                      color: _controller.strokeColor,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white,
                                        width: 2,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withAlpha(40),
                                          blurRadius: 4,
                                          offset: const Offset(0, 1),
                                        ),
                                      ],
                                    ),
                                    child: const Icon(
                                      Icons.colorize,
                                      size: 13,
                                      color: Colors.white70,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),

      // 畫布主體
      body: LayoutBuilder(
        builder: (context, constraints) {
          _controller.viewportSize = constraints.biggest;

          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (e) => _controller.onPointerDown(
                    e.pointer,
                    e.localPosition,
                    e.pressure == 0 ? 0.5 : e.pressure,
                  ),
                  onPointerMove: (e) => _controller.onPointerMove(
                    e.pointer,
                    e.localPosition,
                    e.pressure == 0 ? 0.5 : e.pressure,
                  ),
                  onPointerUp: (e) => _controller.onPointerUp(e.pointer),
                  onPointerCancel: (e) => _controller.onPointerUp(e.pointer),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      RepaintBoundary(
                        child: CustomPaint(
                          painter: HistoryLayerPainter(_controller),
                          size: Size.infinite,
                        ),
                      ),
                      RepaintBoundary(
                        child: CustomPaint(
                          painter: ActiveLayerPainter(_controller),
                          size: Size.infinite,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              if (_controller.showZoomIndicator)
                Positioned(
                  top: 20,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: GestureDetector(
                      onTap: _controller.hudMessage == null
                          ? _controller.resetZoom
                          : null,
                      child: AnimatedOpacity(
                        opacity: _controller.showZoomIndicator ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 200),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withAlpha(200),
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withAlpha(60),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _controller.hudMessage != null
                                    ? Icons.undo
                                    : Icons.zoom_in,
                                color: Colors.white70,
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _controller.hudMessage ??
                                    '${_controller.zoomPercentage.toInt()}%',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPageNavPill(BuildContext context) {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _controller.currentPageIndex > 0
                ? _controller.previousPage
                : null,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.arrow_back_ios_new,
                size: 13,
                color: _controller.currentPageIndex > 0
                    ? Colors.black87
                    : Colors.grey[400],
              ),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            '${_controller.currentPageIndex + 1} / ${_controller.totalPages}',
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 12,
              color: Colors.black87,
            ),
          ),
          const SizedBox(width: 4),
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _controller.currentPageIndex < _controller.totalPages - 1
                ? _controller.nextPage
                : null,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.arrow_forward_ios,
                size: 13,
                color: _controller.currentPageIndex < _controller.totalPages - 1
                    ? Colors.black87
                    : Colors.grey[400],
              ),
            ),
          ),
          Container(
            width: 1,
            height: 16,
            color: Colors.grey[300],
            margin: const EdgeInsets.symmetric(horizontal: 4),
          ),
          PopupMenuButton<String>(
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.add, size: 18, color: Colors.blueAccent),
            tooltip: '在此頁後插入...',
            onSelected: (value) async {
              if (value == 'blank') {
                _controller.insertBlankPageAfterCurrent();
              } else if (value == 'pdf') {
                final pages = await PdfService.pickAndRenderPdf();
                if (pages != null && pages.isNotEmpty) {
                  await _controller.insertPdfPagesAfterCurrent(pages);
                }
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'blank',
                child: Text('在此頁後插入空白頁', style: TextStyle(fontSize: 13)),
              ),
              const PopupMenuItem(
                value: 'pdf',
                child: Text('在此頁後插入 PDF...', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
