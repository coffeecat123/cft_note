// lib/features/canvas/presentation/widgets/canvas_page.dart
import 'dart:async';
import 'dart:ui';

import 'package:cft_note/features/document/data/storage_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../../app/theme/app_theme.dart';
import '../../../../core/i18n/app_strings.dart';
import '../../../pdf_import_export/services/image_export_service.dart';
import '../../../pdf_import_export/services/image_pick_service.dart';
import '../../../pdf_import_export/services/pdf_export_service.dart';
import '../../../pdf_import_export/services/pdf_service.dart';
import '../../../shelf/presentation/controllers/shelf_controller.dart';
import '../../domain/models/tools.dart';
import '../controllers/canvas_controller.dart';
import '../toolbars/brush_settings_sheet.dart';
import '../toolbars/color_settings_sheet.dart';
import '../toolbars/eraser_settings_sheet.dart';
import '../toolbars/page_background_sheet.dart';
import 'canvas_painters.dart';
import 'lasso_context_menu.dart';
import 'screenshot_sheet.dart';
import 'page_list_dialog.dart';
import '../../domain/models/page_layout_mode.dart';

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
    _controller.flushPrefs();
    final shelf = widget.shelfController;
    shelf.activeTabIndex = _controller.activeNotebookIndex;
    shelf.openTabs.clear();
    if (!_controller.allTabsClosed) {
      shelf.openTabs.addAll(_controller.openNotebooks);
    }
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
    if (_controller.allTabsClosed) {
      widget.shelfController.activeTabIndex = 0;
    } else {
      widget.shelfController.openTabs.addAll(_controller.openNotebooks);
    }
    widget.shelfController.notifyNotebookUpdated(); // 立即存檔到硬碟！
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final colors = context.appColors;
    final cs = context.cs;
    return Scaffold(
      backgroundColor: colors.workspace,

      // 頂部雙層 Bar (標籤列 48px + 工具列 50px)
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(98),
        child: Container(
          color: colors.tabBar, // 與標籤列相同的背景色，向上延伸覆蓋
          child: SafeArea(
            bottom: false, // 僅頂部 SafeArea
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ==========================================
                // 1. 頂部多標籤頁列 (Tab Bar) - 已移除 + 號
                // ==========================================
                Container(
                  height: 48,
                  color: colors.tabBar,
                  child: Row(
                    children: [
                      // 返回首頁書架
                      // 與下方工具列按鈕同大：圖示 20、點擊範圍 48 (預設)
                      IconButton(
                        iconSize: 20,
                        icon: Icon(
                          Icons.home_outlined,
                          color: cs.onSurface,
                        ),
                        tooltip: s.backToShelf,
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
                          // 放得下就平均分配寬度；放不下就維持原本寬度並可橫向捲動
                          child: LayoutBuilder(builder: (context, box) {
                            const double tabSlot = 104; // 最小寬度 100 + 右邊距 4
                            final int tabCount = _controller.openNotebooks.length;
                            final bool fill = tabCount > 0 &&
                                tabCount * tabSlot <= box.maxWidth;
                            return ReorderableListView.builder(
                            scrollDirection: Axis.horizontal,
                            itemExtent: fill ? box.maxWidth / tabCount : null,
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
                                  // 拖曳時被拖的項目包含右邊 / 上方的間距 (margin)，
                                  // 所以陰影與邊框都用 Positioned 縮進 margin，
                                  // 只貼合「標籤本體」。
                                  const tabRadius = BorderRadius.vertical(
                                    top: Radius.circular(8),
                                  );
                                  final bool dark =
                                      cs.brightness == Brightness.dark;
                                  return Stack(
                                    clipBehavior: Clip.none,
                                    // passthrough：沿用列表給的限制，標籤才會維持滿高
                                    // (預設 loose 會讓標籤縮成內容高度，下半部變空)
                                    fit: StackFit.passthrough,
                                    children: [
                                      // 陰影 (在標籤後面)
                                      Positioned.fill(
                                        top: 4,
                                        right: 4,
                                        child: Material(
                                          elevation: elevation,
                                          color: Colors.transparent,
                                          shadowColor:
                                              Colors.black.withAlpha(90),
                                          borderRadius: tabRadius,
                                        ),
                                      ),
                                      // 透明 Material：拖曳中的標籤裡有 InkWell (×)，
                                      // 需要 Material 祖先才能繪製
                                      Material(
                                        type: MaterialType.transparency,
                                        child: child!,
                                      ),
                                      // 深色主題：標籤列近黑，黑色陰影看不出來，
                                      // 所以拖曳中再加「提亮 + 亮色邊框」讓它浮起來
                                      if (dark)
                                        Positioned.fill(
                                          top: 4,
                                          right: 4,
                                          child: IgnorePointer(
                                            child: DecoratedBox(
                                              decoration: BoxDecoration(
                                                color: Colors.white.withAlpha(
                                                  (animValue * 24).round(),
                                                ),
                                                border: Border.all(
                                                  color: cs.outline.withAlpha(
                                                    (animValue * 220).round(),
                                                  ),
                                                ),
                                                borderRadius: tabRadius,
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
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

                              // ★ 整個標籤都是點擊範圍 (含空白處、內距)，不是只有文字那一小塊。
                              //   × 是更內層的 InkWell，點它不會同時觸發切換。
                              return GestureDetector(
                                // ★ ReorderableList 的每個項目必須要有唯一的 Key！
                                key: ValueKey(nb.id),
                                behavior: HitTestBehavior.opaque,
                                onTap: () {
                                  _controller.switchTab(index);
                                  widget.shelfController.activeTabIndex = index;
                                },
                                child: Container(
                                  margin: const EdgeInsets.only(
                                    top: 4,
                                    right: 4,
                                  ),
                                  // 標籤最小寬度：標題很短時也不會縮成一小塊
                                  constraints: const BoxConstraints(
                                    minWidth: 100,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isActive
                                        ? colors.toolbar
                                        : colors.tabInactive,
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(8),
                                    ),
                                    border: isActive
                                        ? Border.all(
                                            color: cs.outlineVariant,
                                            width: 0.5,
                                          )
                                        : null,
                                  ),
                                  child: Row(
                                    mainAxisSize: fill
                                        ? MainAxisSize.max
                                        : MainAxisSize.min,
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      _tabTitleSlot(
                                        fill: fill,
                                        child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const SizedBox(width: 6),
                                          _tabTitleBox(
                                            fill: fill,
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
                                                    ? cs.onSurface
                                                    : cs.onSurfaceVariant,
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
                                          padding: EdgeInsets.all(6.0),
                                          child: Icon(
                                            Icons.close,
                                            size: 14,
                                            color: Colors.grey,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          );
                          }),
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
                  color: colors.toolbar,
                  child: Row(
                    children: [
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
                                _buildPageNavPill(context),
                                VerticalDivider(
                                  width: 1,
                                  indent: 12,
                                  endIndent: 12,
                                  color: cs.outlineVariant,
                                ),
                                // 智慧筆刷按鈕 (未選中切換，已選中開啟工作室)
                                IconButton(
                                  icon: Icon(
                                    Icons.edit,
                                    color:
                                        _controller.currentTool ==
                                            DrawingTool.pen
                                        ? Colors.blue
                                        : colors.toolbarIcon,
                                    size: 20,
                                  ),
                                  tooltip:
                                      _controller.currentTool == DrawingTool.pen
                                      ? s.openBrushStudio
                                      : s.brush,
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
                                        : colors.toolbarIcon,
                                    size: 20,
                                  ),
                                  // 未選中 → 切換到橡皮擦；已選中 → 調整大小 (與筆刷相同)
                                  tooltip:
                                      _controller.currentTool ==
                                          DrawingTool.eraser
                                      ? s.eraserSettings
                                      : s.eraser,
                                  onPressed: () {
                                    if (_controller.currentTool !=
                                        DrawingTool.eraser) {
                                      _controller.setTool(DrawingTool.eraser);
                                    } else {
                                      EraserSettingsSheet.show(
                                        context,
                                        _controller,
                                      );
                                    }
                                  },
                                ),

                                // 套索工具
                                IconButton(
                                  icon: Icon(
                                    Icons.gesture,
                                    color:
                                        _controller.currentTool ==
                                            DrawingTool.lasso
                                        ? Colors.blue
                                        : colors.toolbarIcon,
                                    size: 20,
                                  ),
                                  tooltip: s.lasso,
                                  onPressed: () =>
                                      _controller.setTool(DrawingTool.lasso),
                                ),

                                // 圖片模式：未選中 → 切換到圖片模式；已選中 → 選擇圖片來源
                                IconButton(
                                  icon: Icon(
                                    Icons.image_outlined,
                                    color:
                                        _controller.currentTool ==
                                            DrawingTool.image
                                        ? Colors.blue
                                        : colors.toolbarIcon,
                                    size: 20,
                                  ),
                                  tooltip:
                                      _controller.currentTool ==
                                          DrawingTool.image
                                      ? s.insertImage
                                      : s.imageMode,
                                  onPressed: _onImageButtonPressed,
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

                                const SizedBox(width: 8),
                              ],
                            ),
                          ),
                        ),
                      ),

                      // ★ 靠右固定：復原 / 重做 / 頁面列表 / 更多
                      //   (工具太多時只有左邊的工具區會捲動，這一組永遠在最右邊)
                      VerticalDivider(
                        width: 1,
                        indent: 12,
                        endIndent: 12,
                        color: cs.outlineVariant,
                      ),
                      IconButton(
                        icon: const Icon(Icons.undo, size: 20),
                        tooltip: s.undo,
                        onPressed: _controller.canUndo
                            ? _controller.undo
                            : null,
                      ),
                      IconButton(
                        icon: const Icon(Icons.redo, size: 20),
                        tooltip: s.redo,
                        onPressed: _controller.canRedo
                            ? _controller.redo
                            : null,
                      ),
                      _buildPageBackgroundButton(),
                      _buildPageListButton(),
                      _buildMoreMenu(),
                      const SizedBox(width: 4),
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
          _controller.updateViewportSize(constraints.biggest);

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
                  onPointerSignal: (e) {
                    // 滑鼠滾輪 / 觸控板：連續捲動模式下用來捲動頁面
                    if (e is PointerScrollEvent) {
                      _controller.onScroll(e.scrollDelta);
                    }
                  },
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

              // 套索：在圈選範圍內點一下 → 剪下 / 複製 / 刪除 / 截圖；空白處點一下 → 貼上
              if (_controller.lassoMenu != LassoMenuKind.none)
                Positioned.fill(
                  child: LassoContextMenu(
                    kind: _controller.lassoMenu,
                    anchor: _controller.lassoMenuAnchor,
                    onCut: _controller.cutSelection,
                    onCopy: _controller.copySelection,
                    onDelete: _controller.deleteSelection,
                    onPaste: _controller.pasteFromClipboard,
                    onPasteImage: _controller.pasteImageFromSystemClipboard,
                    canPasteStrokes: _controller.lassoMenuCanPasteStrokes,
                    canPasteImage: _controller.lassoMenuCanPasteImage,
                    onScreenshot: _screenshotSelection,
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
                                    ? _controller.hudIcon
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

  /// 把套索圈選範圍 (最小外接矩形) 輸出成 PNG，並開啟「分享 / 存相簿 / 存檔」面板
  Future<void> _screenshotSelection() async {
    final messenger = ScaffoldMessenger.of(context);
    final s = S.of(context); // await 之前先取得
    _controller.hideLassoMenu(); // 只收起選單，圈選範圍保留
    final png = await _controller.captureSelectionPng();
    if (!mounted) return;
    if (png == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(s.screenshotOutsidePage)),
      );
      return;
    }
    final t = DateTime.now();
    String p(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${t.year}${p(t.month)}${p(t.day)}_${p(t.hour)}${p(t.minute)}${p(t.second)}';
    final title = ImageExportService.safeName(
      _controller.currentNotebook.title,
    );
    // 先給使用者預覽，再選擇：分享 / 存到相簿 / 儲存檔案
    await ScreenshotSheet.show(
      context,
      png: png,
      fileName: '${title}_${s.screenshotNamePart}_$stamp.png',
    );
  }

  /// 圖片按鈕：不在圖片模式 → 先切過去；已在圖片模式 → 跳出 系統圖庫 / 系統檔案
  void _onImageButtonPressed() {
    if (_controller.currentTool != DrawingTool.image) {
      _controller.setTool(DrawingTool.image);
    } else {
      _showImageSourceSheet();
    }
  }

  Future<void> _showImageSourceSheet() async {
    final s = S.of(context);
    final source = await showModalBottomSheet<ImagePickSource>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(s.sysGallery),
              onTap: () => Navigator.pop(ctx, ImagePickSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: Text(s.sysFiles),
              onTap: () => Navigator.pop(ctx, ImagePickSource.files),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source != null && mounted) await _pickAndInsertImage(source);
  }

  /// 挑圖 → 放進目前頁面並選取 (之後可直接平移 / 縮放 / 刪除)
  Future<void> _pickAndInsertImage(ImagePickSource source) async {
    final messenger = ScaffoldMessenger.of(context);
    final s = S.of(context); // await 之前先取得
    try {
      final bytes = await ImagePickService.pick(source);
      if (bytes == null || !mounted) return; // 使用者取消
      final ok = await _controller.addImageFromBytes(bytes);
      if (!ok && mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(s.imageLoadFailed)),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(s.imagePickFailed(e))),
        );
      }
    }
  }

  /// 頁面清單按鈕：列出所有頁面，點選即跳轉
  /// 頁面背景 (紙張顏色 / 格線)：可改目前頁或所有空白頁
  /// 標籤標題外層：平均分配寬度時吃滿剩餘空間 (× 靠右)，否則維持內容寬度
  Widget _tabTitleSlot({required bool fill, required Widget child}) =>
      fill ? Expanded(child: child) : child;

  /// 標題文字：平均分配時隨標籤變寬 (過長才省略)，否則最寬 120
  Widget _tabTitleBox({required bool fill, required Widget child}) => fill
      ? Flexible(child: child)
      : ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 120),
          child: child,
        );

  Widget _buildPageBackgroundButton() {
    return IconButton(
      icon: Icon(Icons.grid_on_rounded, size: 20, color: context.appColors.toolbarIcon),
      tooltip: S.of(context).pageBackground,
      onPressed: () {
        _controller.syncCurrentToFocus(); // 連續模式：以畫面上看到的頁面為「目前頁」
        PageBackgroundSheet.show(context, _controller);
      },
    );
  }

  Widget _buildPageListButton() {
    return IconButton(
      icon: Icon(Icons.view_list_rounded, size: 20, color: context.appColors.toolbarIcon),
      tooltip: S.of(context).pageList,
      onPressed: _showPageListDialog,
    );
  }

  Future<void> _showPageListDialog() async {
    _controller.syncCurrentToFocus(); // 連續模式：以畫面上看到的頁面為準
    final selected = await PageListDialog.show(context, _controller);
    if (selected != null && mounted) {
      _controller.goToPage(selected);
    }
  }

  Widget _buildMoreMenu() {
    final s = S.of(context);
    final canDelete = _controller.canDeleteCurrentPage;
    return PopupMenuButton<String>(
      tooltip: s.more,
      padding: EdgeInsets.zero,
      icon: Icon(Icons.more_vert, size: 20, color: context.appColors.toolbarIcon),
      onSelected: (value) {
        if (value == 'export_pdf') {
          _exportPdf();
        } else if (value == 'delete_page') {
          _confirmDeleteCurrentPage();
        } else if (value == 'layout') {
          _showLayoutModeDialog();
        }
      },
      itemBuilder: (ctx) => [
        PopupMenuItem<String>(
          value: 'layout',
          child: Row(
            children: [
              const Icon(
                Icons.view_carousel_outlined,
                size: 18,
                color: Colors.blueAccent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(s.pageLayout, style: const TextStyle(fontSize: 13)),
              ),
              Text(
                _controller.layoutMode.label,
                style: TextStyle(fontSize: 11, color: context.cs.onSurfaceVariant),
              ),
              Icon(Icons.chevron_right, size: 18, color: Colors.grey[500]),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'export_pdf',
          child: Row(
            children: [
              const Icon(
                Icons.picture_as_pdf_outlined,
                size: 18,
                color: Colors.blueAccent,
              ),
              const SizedBox(width: 10),
              Text(s.exportAsPdf, style: const TextStyle(fontSize: 13)),
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
                canDelete ? s.deleteCurrentPage : s.deleteCurrentPageKeepOne,
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

  /// 列出所有頁面顯示方式供切換
  Future<void> _showLayoutModeDialog() async {
    final current = _controller.layoutMode;
    final selected = await showDialog<PageLayoutMode>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(S.of(context).pageLayout, style: const TextStyle(fontSize: 16)),
        children: [
          for (final mode in PageLayoutMode.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, mode),
              child: Row(
                children: [
                  Icon(
                    mode == current
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: mode == current ? Colors.blueAccent : Colors.grey,
                  ),
                  const SizedBox(width: 12),
                  Text(mode.label, style: const TextStyle(fontSize: 14)),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected != null && mounted) {
      _controller.setLayoutMode(selected);
    }
  }

  Future<void> _exportPdf() async {
    final messenger = ScaffoldMessenger.of(context);
    final s = S.of(context);
    _controller.saveCurrentPage();
    messenger.showSnackBar(
      SnackBar(
        content: Text(s.exportingPdf),
        duration: const Duration(seconds: 1),
      ),
    );

    final success = await PdfExportService.exportNotebook(
      _controller.currentNotebook,
    );
    if (success && mounted) {
      messenger.showSnackBar(SnackBar(content: Text(s.pdfExported)));
    }
  }

  Future<void> _confirmDeleteCurrentPage() async {
    _controller.syncCurrentToFocus(); // 連續模式：刪除畫面上看到的那一頁
    if (!_controller.canDeleteCurrentPage) return;
    final pageNumber = _controller.currentPageIndex + 1;
    final s = S.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.deleteCurrentPage),
        content: Text(s.confirmDeletePage(pageNumber)),
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

    // 對話框開啟期間頁面可能已改變 (例如自動存檔/切頁)，確認時再檢查一次
    if (confirmed == true && mounted && _controller.canDeleteCurrentPage) {
      _controller.deleteCurrentPage();
    }
  }

  Widget _buildPageNavPill(BuildContext context) {
    // 連續模式捲動時只有 viewSignal 會觸發，所以頁碼要自己監聽
    return ListenableBuilder(
      listenable: _controller.viewSignal,
      builder: (context, _) => _buildPageNavPillBody(),
    );
  }

  Widget _buildPageNavPillBody() {
    final idx = _controller.focusPageIndex; // 單頁模式 = 目前頁
    final canPrev = idx > 0;
    final canNext = idx < _controller.totalPages - 1;
    final s = S.of(context);
    final cs = context.cs;

    // 與右側工具按鈕 (undo / redo / 更多…) 同大：圖示 20、點擊範圍 40
    const double iconSize = 20;
    const btnConstraints = BoxConstraints(minWidth: 40, minHeight: 40);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          iconSize: iconSize,
          padding: EdgeInsets.zero,
          constraints: btnConstraints,
          tooltip: s.prevPage,
          icon: Icon(
            Icons.arrow_back_ios_new,
            color: canPrev ? cs.onSurface : cs.onSurface.withAlpha(80),
          ),
          onPressed: canPrev ? _controller.previousPage : null,
        ),
        Text(
          '${idx + 1} / ${_controller.totalPages}',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: cs.onSurface,
          ),
        ),
        IconButton(
          iconSize: iconSize,
          padding: EdgeInsets.zero,
          constraints: btnConstraints,
          tooltip: s.nextPage,
          icon: Icon(
            Icons.arrow_forward_ios,
            color: canNext ? cs.onSurface : cs.onSurface.withAlpha(80),
          ),
          onPressed: canNext ? _controller.nextPage : null,
        ),
        PopupMenuButton<String>(
          padding: EdgeInsets.zero,
          iconSize: iconSize,
          icon: const Icon(Icons.add, color: Colors.blueAccent),
          tooltip: s.insertAfterThisPage,
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
            PopupMenuItem(
              value: 'blank',
              child: Text(s.insertBlankAfter, style: const TextStyle(fontSize: 13)),
            ),
            PopupMenuItem(
              value: 'pdf',
              child: Text(s.insertPdfAfter, style: const TextStyle(fontSize: 13)),
            ),
          ],
        ),
      ],
    );
  }
}
