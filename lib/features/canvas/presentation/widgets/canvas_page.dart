// lib/features/canvas/presentation/widgets/canvas_page.dart
import 'dart:async';
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

class _CanvasPageState extends State<CanvasPage> with WidgetsBindingObserver {
  late final CanvasController _controller;

  // ★ 防抖自動存檔：停筆 2 秒後存；連續書寫最久 20 秒也會強制存一次；
  //   App 進背景立即存。避免閃退/被系統殺掉時遺失整段筆跡。
  Timer? _autosaveTimer;
  DateTime? _firstDirtyAt;
  static const Duration _autosaveDelay = Duration(seconds: 2);
  static const Duration _autosaveMaxWait = Duration(seconds: 20);

  void _scheduleAutosave() {
    final now = DateTime.now();
    _firstDirtyAt ??= now;
    _autosaveTimer?.cancel();
    final waited = now.difference(_firstDirtyAt!);
    final delay = waited >= _autosaveMaxWait ? Duration.zero : _autosaveDelay;
    _autosaveTimer = Timer(delay, _flushAutosave);
  }

  void _flushAutosave() {
    _autosaveTimer?.cancel();
    _autosaveTimer = null;
    _firstDirtyAt = null;
    _controller.saveCurrentPage();
    final shelf = widget.shelfController;
    shelf.activeTabIndex = _controller.activeNotebookIndex;
    shelf.openTabs
      ..clear()
      ..addAll(_controller.openNotebooks);
    unawaited(shelf.saveToDisk()); // 只存檔、不通知書架重建
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _flushAutosave();
    }
  }

  @override
  void initState() {
    super.initState();
    // ★ 接收書架中常駐的 openTabs 與 activeTabIndex
    _controller = CanvasController(
      initialNotebooks: widget.shelfController.openTabs,
      initialIndex: widget.shelfController.activeTabIndex,
    );
    _controller.addListener(() => setState(() {}));
    _controller.onContentChanged = _scheduleAutosave;
    WidgetsBinding.instance.addObserver(this);
    // 第一個 frame 排版完成、知道可視範圍後，若還原的視野是放大狀態就補上高清圖塊
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.refreshDetail();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autosaveTimer?.cancel();
    _controller.onContentChanged = null;
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
                                          const SizedBox(width: 6),
                                          ConstrainedBox(
                                            constraints: const BoxConstraints(
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
                                    const SizedBox(width: 6),

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
                                
                                const VerticalDivider(
                                  width: 16,
                                  indent: 14,
                                  endIndent: 14,
                                ),

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
                                
                                // ★ 更多選單：匯出 PDF / 刪除當前頁面
                                _buildMoreMenu(),
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
                              // 縮放百分比只重建這個小 Text，不重建整頁
                              ListenableBuilder(
                                listenable: _controller.viewSignal,
                                builder: (context, _) => Text(
                                  _controller.hudMessage ??
                                      '${_controller.zoomPercentage.toInt()}%',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.5,
                                  ),
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

  Widget _buildMoreMenu() {
    final canDelete = _controller.canDeleteCurrentPage;
    return PopupMenuButton<String>(
      tooltip: '更多',
      padding: EdgeInsets.zero,
      icon: Icon(Icons.more_vert, size: 20, color: Colors.grey[700]),
      onSelected: (value) {
        if (value == 'export_pdf') {
          _exportPdf();
        } else if (value == 'delete_page') {
          _confirmDeleteCurrentPage();
        }
      },
      itemBuilder: (ctx) => [
        const PopupMenuItem<String>(
          value: 'export_pdf',
          child: Row(
            children: [
              Icon(
                Icons.picture_as_pdf_outlined,
                size: 18,
                color: Colors.blueAccent,
              ),
              SizedBox(width: 10),
              Text('匯出為 PDF', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'delete_page',
          enabled: canDelete,
          child: Row(
            children: [
              Icon(
                Icons.delete_outline,
                size: 18,
                color: canDelete ? Colors.redAccent : Colors.grey,
              ),
              const SizedBox(width: 10),
              Text(
                canDelete ? '刪除當前頁面' : '刪除當前頁面 (至少保留一頁)',
                style: TextStyle(
                  fontSize: 13,
                  color: canDelete ? Colors.redAccent : Colors.grey,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _exportPdf() async {
    final messenger = ScaffoldMessenger.of(context);
    _controller.saveCurrentPage();
    messenger.showSnackBar(
      const SnackBar(
        content: Text('正在合成向量 PDF...'),
        duration: Duration(seconds: 1),
      ),
    );

    final success = await PdfExportService.exportNotebook(
      _controller.currentNotebook,
    );
    if (success && mounted) {
      messenger.showSnackBar(const SnackBar(content: Text('PDF 匯出成功！')));
    }
  }

  Future<void> _confirmDeleteCurrentPage() async {
    if (!_controller.canDeleteCurrentPage) return;
    final pageNumber = _controller.currentPageIndex + 1;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('刪除當前頁面'),
        content: Text('確定要刪除第 $pageNumber 頁嗎？頁面上的筆跡會一併刪除，無法復原。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('刪除'),
          ),
        ],
      ),
    );

    // 對話框開啟期間頁面可能已改變 (例如自動存檔/切頁)，確認時再檢查一次
    if (confirmed == true && mounted && _controller.canDeleteCurrentPage) {
      _controller.deleteCurrentPage();
    }
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
