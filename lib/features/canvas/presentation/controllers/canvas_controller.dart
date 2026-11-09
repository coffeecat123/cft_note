// lib/features/canvas/presentation/controllers/canvas_controller.dart
import 'dart:math';
import 'dart:ui' as ui;
import 'dart:async';
import 'dart:typed_data';

import 'package:cft_note/features/pdf_import_export/services/pdf_service.dart';
import 'package:cft_note/features/shelf/domain/models/notebook.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:perfect_freehand/perfect_freehand.dart';

import '../../../../core/algorithms/ray_casting.dart';
import '../../../../core/engine/repaint_signal.dart';
import '../../domain/models/brush_settings.dart';
import '../../domain/models/stroke.dart';
import '../../domain/commands/canvas_command.dart';
import '../../domain/models/page_layout_mode.dart';
import '../../domain/models/tools.dart';
import '../../../document/domain/note_page.dart';
import 'page_image_manager.dart';
import 'region_capture.dart';

// 2. 主畫布控制器 (CanvasController)
class CanvasController extends ChangeNotifier {
  final List<Stroke> _historyStrokes = [];
  final List<CanvasCommand> _undoStack = [];
  final List<CanvasCommand> _redoStack = [];
  final List<PointVector> _currentPoints = [];
  final List<MapEntry<int, Stroke>> _currentErasedBatch = [];
  Offset? _lastEraseScenePoint; // 橡皮擦上一個取樣點 (用來做線段掃掠碰撞)
  int _incrementalBakes = 0;

  /// 內容有變動時通知外部 (畫布頁用來做防抖自動存檔)
  VoidCallback? onContentChanged;

  /// 只驅動 Painter / 縮放 HUD 的訊號：雙指縮放時不必重建整個頁面
  final RepaintSignal viewSignal = RepaintSignal();

  void _markDirty() {
    currentNotebook.updatedAt = DateTime.now();
    onContentChanged?.call();
  }

  /// PDF 底圖 / 高清圖塊的生命週期交給專責物件管理
  late final PageImageManager images = PageImageManager(
    transform: () => transformation,
    viewportSize: () => viewportSize,
    zoom: () => zoomPercentage / 100,
    focus: _detailFocus,
    onChanged: notifyListeners,
  );

  List<NotePage> get pages => currentNotebook.pages;
  int currentPageIndex = 0;

  NotePage get currentPage => pages[currentPageIndex];
  int get totalPages => pages.length;

  // ==========================================
  // ★ 頁面顯示方式：單頁 / 往下連續 / 往右連續
  //   筆劃永遠存成「頁面自己的座標」；連續模式只是把每頁放在畫布的不同位置，
  //   目前編輯頁的位置 (currentPageOrigin) 會在輸入座標轉換時扣掉。
  // ==========================================
  static const double pageGap = 16.0; // 連續模式下頁與頁的間隔
  PageLayoutMode layoutMode = PageLayoutMode.single;
  bool get isContinuous => layoutMode.isContinuous;

  List<Offset>? _origins;
  List<NotePage>? _originsPages;
  int _originsLen = -1;
  PageLayoutMode? _originsMode;

  /// 每一頁左上角在畫布座標中的位置 (單頁模式全部為 0)
  List<Offset> get _pageOrigins {
    final cached = _origins;
    if (cached != null &&
        identical(_originsPages, pages) &&
        _originsLen == pages.length &&
        _originsMode == layoutMode) {
      return cached;
    }
    final list = <Offset>[];
    switch (layoutMode) {
      case PageLayoutMode.single:
        for (int i = 0; i < pages.length; i++) {
          list.add(Offset.zero);
        }
        break;
      case PageLayoutMode.vertical:
        double maxW = 0;
        for (final p in pages) {
          maxW = max(maxW, p.width);
        }
        double y = 0;
        for (final p in pages) {
          list.add(Offset((maxW - p.width) / 2, y));
          y += p.height + pageGap;
        }
        break;
      case PageLayoutMode.horizontal:
        double maxH = 0;
        for (final p in pages) {
          maxH = max(maxH, p.height);
        }
        double x = 0;
        for (final p in pages) {
          list.add(Offset(x, (maxH - p.height) / 2));
          x += p.width + pageGap;
        }
        break;
    }
    _origins = list;
    _originsPages = pages;
    _originsLen = pages.length;
    _originsMode = layoutMode;
    return list;
  }

  Offset pageOrigin(int i) {
    final o = _pageOrigins;
    return (i >= 0 && i < o.length) ? o[i] : Offset.zero;
  }

  Offset get currentPageOrigin => pageOrigin(currentPageIndex);

  Rect pageSceneRect(int i) {
    final p = pages[i];
    final o = pageOrigin(i);
    return Rect.fromLTWH(o.dx, o.dy, p.width, p.height);
  }

  /// 螢幕可視範圍對應到畫布座標
  Rect get viewSceneRect => viewportSize.isEmpty
      ? Rect.zero
      : MatrixUtils.inverseTransformRect(transformation, Offset.zero & viewportSize);

  /// 與 [sceneRect] 有重疊的頁面 (單頁模式只有目前頁)
  List<int> visiblePageIndices(Rect sceneRect) {
    if (!isContinuous) return [currentPageIndex];
    final out = <int>[];
    for (int i = 0; i < pages.length; i++) {
      if (pageSceneRect(i).overlaps(sceneRect)) out.add(i);
    }
    return out;
  }

  /// 離畫面中心最近的頁面 (中心點落在某頁內就是那一頁)；單頁模式就是目前頁
  int get focusPageIndex {
    if (!isContinuous || viewportSize.isEmpty || pages.isEmpty) {
      return currentPageIndex;
    }
    final center = viewSceneRect.center;
    int best = currentPageIndex.clamp(0, pages.length - 1);
    double bestD = double.infinity;
    for (int i = 0; i < pages.length; i++) {
      final r = pageSceneRect(i);
      // 中心點到該頁矩形的距離 (在頁內為 0)
      final dx = max(max(r.left - center.dx, center.dx - r.right), 0.0);
      final dy = max(max(r.top - center.dy, center.dy - r.bottom), 0.0);
      final d = dx * dx + dy * dy;
      if (d < bestD) {
        bestD = d;
        best = i;
        if (d == 0) break; // 中心就在這頁內
      }
    }
    return best;
  }

  PageFocus? _detailFocus() {
    if (pages.isEmpty) return null;
    final i = (isContinuous ? focusPageIndex : currentPageIndex).clamp(
      0,
      pages.length - 1,
    );
    return PageFocus(pages[i], pageOrigin(i));
  }

  /// 把第 [index] 頁放進畫面：水平、垂直都置中 (頁面比畫面大時，四邊對稱裁切)
  Matrix4 _placementFor(int index, double scale) {
    final p = pages[index];
    final o = pageOrigin(index);
    if (viewportSize.isEmpty) {
      return Matrix4.translationValues(-scale * o.dx, 30.0 - scale * o.dy, 0.0) *
          Matrix4.diagonal3Values(scale, scale, 1.0);
    }
    final tx = (viewportSize.width - p.width * scale) / 2 - scale * o.dx;
    final ty = (viewportSize.height - p.height * scale) / 2 - scale * o.dy;
    return Matrix4.translationValues(tx, ty, 0.0) *
        Matrix4.diagonal3Values(scale, scale, 1.0);
  }

  /// 連續模式：把目前編輯頁放進畫面 (保持目前縮放)
  void _placeCurrent() {
    if (viewportSize.isEmpty) return;
    transformation = _placementFor(currentPageIndex, zoomPercentage / 100);
    notifyListeners();
    refreshDetail();
  }

  /// 連續模式下可視 (含預載邊界) 的頁面才載入底圖，最多同時 8 頁，避免縮很小時爆記憶體
  void _syncVisiblePages() {
    if (!isContinuous || viewportSize.isEmpty) {
      images.setVisible(const []);
      return;
    }
    final view = viewSceneRect;
    final margin = max(view.width, view.height) * 0.3;
    final indices = visiblePageIndices(view.inflate(margin));
    final focus = focusPageIndex;
    indices.sort((a, b) => (a - focus).abs().compareTo((b - focus).abs()));
    images.setVisible(indices.take(8).map((i) => pages[i]));
  }

  /// 連續模式：目前編輯頁 := 畫面上最主要的那一頁 (插入/刪除/翻頁前呼叫)
  void syncCurrentToFocus() {
    if (!isContinuous) return;
    final i = focusPageIndex;
    if (i != currentPageIndex) {
      _saveCurrentPageState();
      _loadPageState(i);
    }
  }

  void setLayoutMode(PageLayoutMode mode) {
    if (mode == layoutMode) return;
    if (isContinuous) {
      syncCurrentToFocus(); // 離開連續模式前，把「看到的那頁」變成目前頁
    } else {
      _saveCurrentPageState();
    }
    final scale = zoomPercentage / 100;
    layoutMode = mode;
    clearSelection();
    eraserPosition = null;
    if (!isContinuous) _clearPictureCache();
    if (!viewportSize.isEmpty) {
      transformation = _placementFor(currentPageIndex, scale);
    }
    _syncVisiblePages();
    notifyListeners();
    images.refreshDetail();
  }

  Timer? _scrollSettleTimer;

  /// 滑鼠滾輪 / 觸控板捲動 (只在連續模式有效)
  void onScroll(Offset delta) {
    if (!isContinuous) return;
    double dx = delta.dx, dy = delta.dy;
    if (layoutMode == PageLayoutMode.horizontal && dx == 0) {
      dx = dy; // 橫向模式：滾輪上下 = 左右移動
      dy = 0;
    }
    transformation = Matrix4.translationValues(-dx, -dy, 0.0) * transformation;
    _syncVisiblePages();
    viewSignal.fire();
    _scrollSettleTimer?.cancel();
    _scrollSettleTimer = Timer(const Duration(milliseconds: 150), refreshDetail);
  }

  // ---- 非編輯頁的筆劃 Picture 快取 (編輯頁用 cachedHistoryPicture) ----
  final Map<NotePage, ui.Picture> _pagePictures = {};

  ui.Picture? pictureFor(int i) {
    if (i == currentPageIndex) return cachedHistoryPicture;
    final page = pages[i];
    if (page.strokes.isEmpty) return null;
    return _pagePictures[page] ??= _bakeStrokes(page.strokes);
  }

  ui.Picture _bakeStrokes(List<Stroke> strokes) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()..style = PaintingStyle.fill;
    for (final stroke in strokes) {
      paint.color = stroke.color;
      canvas.drawPath(stroke.outlinePath, paint);
    }
    return recorder.endRecording();
  }

  void _dropPicture(NotePage page) {
    _disposePictureLater(_pagePictures.remove(page));
  }

  void _clearPictureCache() {
    for (final pic in _pagePictures.values) {
      _disposePictureLater(pic);
    }
    _pagePictures.clear();
  }

  /// 快取太多時，丟掉不在 [keep] 內的頁面
  void trimPictureCache(Set<int> keep) {
    if (_pagePictures.length <= 12) return;
    final keepPages = <NotePage>{
      for (final i in keep)
        if (i >= 0 && i < pages.length) pages[i],
    };
    final drop = _pagePictures.keys.where((p) => !keepPages.contains(p)).toList();
    for (final p in drop) {
      _dropPicture(p);
    }
  }

  int get _savedPageIndex => isContinuous ? focusPageIndex : currentPageIndex;

  /// 存檔用的視野矩陣：一律換算成「該頁位於原點」的單頁座標，兩種模式通用
  List<double> _savedMatrix() {
    if (!isContinuous) return transformation.storage.toList();
    final o = pageOrigin(focusPageIndex);
    return (transformation * Matrix4.translationValues(o.dx, o.dy, 0.0))
        .storage
        .toList();
  }

  // ★ 獨立通知器：只驅動最上層的即時筆劃 (不驚動歷史層與 PDF)
  final ChangeNotifier activeRepaintNotifier = ChangeNotifier();
  // 判定座標是否在當前紙張範圍內
  bool isInsidePage(Offset scenePoint) {
    final pageRect = Rect.fromLTWH(0, 0, currentPage.width, currentPage.height);
    return pageRect.contains(scenePoint);
  }

  // 繪圖工具與自訂筆刷設定
  DrawingTool currentTool = DrawingTool.pen;
  Color strokeColor = Colors.black;
  BrushSettings brush = BrushSettings.fountainPen; // 預設使用鋼筆設定
  ui.Picture? cachedHistoryPicture;
  // 記錄調色剛開始時的筆劃備份
  List<Stroke>? _colorChangeInitialStrokes;
  // 最近使用的顏色 (最多記錄 8 個)
  final List<Color> recentColors = [];

  // 收藏/喜愛的顏色 (預設包含 GoodNotes 常用色)
  final List<Color> favoriteColors = [
    Colors.black,
    Colors.white,
    // 依序生成 0°, 20°, 40°, ..., 340° (S: 85%, B: 90% 飽和高雅的筆記色彩)
    for (double h = 0; h <= 340; h += 20)
      HSVColor.fromAHSV(1.0, h, 0.85, 0.90).toColor(),
  ];

  // 變換與手勢狀態
  Matrix4 transformation = Matrix4.identity();
  final Map<int, Offset> _pointerPositions = {};
  double _previousDistance = 0.0;
  Offset _previousMidpoint = Offset.zero;
  bool _isScalingLocked = false;

  // 套索狀態
  final List<Offset> _currentLassoDrawing = [];
  final List<Offset> _selectedLassoPolygon = [];
  final List<Stroke> _selectedStrokes = [];
  bool _isDraggingSelection = false;
  Offset _lastDragPosition = Offset.zero;
  Offset _totalDragDelta = Offset.zero;

  // 雙指捏合手勢防誤觸標記
  bool _isPotentialNewLasso = false;
  Offset _potentialLassoStart = Offset.zero;

  // 套索「點一下」判定與浮動選單
  static const double _tapSlop = 10.0; // 螢幕像素；移動超過才算拖曳
  static const Duration _longPressDelay = Duration(milliseconds: 500);
  Timer? _lassoLongPressTimer; // 空白處長按 → 顯示「貼上」
  Offset _lassoDownScreen = Offset.zero;
  bool _selectionDragStarted = false;
  LassoMenuKind lassoMenu = LassoMenuKind.none;
  Offset lassoMenuAnchor = Offset.zero; // 螢幕座標 (選單出現位置)
  Offset _pasteScenePoint = Offset.zero;

  /// 套索剪貼簿 (static：換頁、換筆記本都還在；只存在記憶體)
  static List<Stroke> _clipboard = [];
  bool get hasClipboard => _clipboard.isNotEmpty;

  List<PointVector> get currentPoints => _currentPoints;
  List<Stroke> get historyStrokes => _historyStrokes;
  List<Offset> get currentLassoDrawing => _currentLassoDrawing;
  List<Offset> get selectedLassoPolygon => _selectedLassoPolygon;
  List<Stroke> get selectedStrokes => _selectedStrokes;
  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;
  // ==========================================
  // ★ 雙指輕點 Undo 手勢精準追蹤
  // ==========================================
  bool _twoFingerTapCandidate = false;
  DateTime? _twoFingerDownTime;
  double _initialTwoFingerDistance = 0.0;
  Offset? _finger1Initial;
  Offset? _finger2Initial;
  Matrix4? _matrixBeforeGesture;

  // 浮動提示文字 (例如顯示 "已復原")
  String? hudMessage;
  IconData hudIcon = Icons.undo;
  // ==========================================
  // ★ 多標籤頁 (Tabs) 與當前筆記本狀態
  // ==========================================
  final List<Notebook> openNotebooks = [];
  int activeNotebookIndex = 0;

  Notebook get currentNotebook => openNotebooks[activeNotebookIndex];

  // 建構子：接收初始筆記本清單
  CanvasController({
    required List<Notebook> initialNotebooks,
    int initialIndex = 0,
  }) {
    if (initialNotebooks.isNotEmpty) {
      openNotebooks.addAll(initialNotebooks);
      activeNotebookIndex = initialIndex.clamp(0, openNotebooks.length - 1);
    } else {
      final fallbackBook = Notebook(
        id: 'nb_fallback',
        title: '未命名筆記',
        coverColor: const Color(0xFF2B3A4A),
        updatedAt: DateTime.now(),
      );
      openNotebooks.add(fallbackBook);
      activeNotebookIndex = 0;
    }

    if (pages.isEmpty) {
      pages.add(NotePage(id: 'page_1'));
    }

    // ★ 還原該筆記本上次儲存的縮放平移矩陣；沒有紀錄 (全新筆記) 則等取得畫面大小後置中
    if (currentNotebook.transformMatrix != null) {
      transformation = Matrix4.fromList(currentNotebook.transformMatrix!);
    } else {
      _needsInitialCenter = true;
    }

    final targetPage = currentNotebook.lastViewedPageIndex.clamp(0, pages.length - 1);
    _loadPageState(targetPage);
  }

  // ★ 解決第 2 點：切換至其他 Tab (標籤頁)
  void switchTab(int index) {
    if (index == activeNotebookIndex || index < 0 || index >= openNotebooks.length) return;

    // 1. 保存當前筆記本的筆劃、閱讀頁數、以及當前縮放與平移矩陣！
    _saveCurrentPageState();
    currentNotebook.lastViewedPageIndex = _savedPageIndex;
    currentNotebook.transformMatrix = _savedMatrix(); // ★ 保存視野 (只存檔，不更新修改時間)
    onContentChanged?.call();

    // 2. 切換標籤
    activeNotebookIndex = index;

    if (pages.isEmpty) {
      pages.add(NotePage(id: 'page_1'));
    }

    // 先校正頁碼：resetZoom 會用 currentPage，舊筆記本的頁碼套在新筆記本上可能越界
    currentPageIndex = currentNotebook.lastViewedPageIndex.clamp(0, pages.length - 1);

    // 3. ★ 還原目標筆記本的縮放與平移矩陣
    if (currentNotebook.transformMatrix != null) {
      var restored = Matrix4.fromList(currentNotebook.transformMatrix!);
      if (isContinuous) {
        // 存的是「該頁在原點」的矩陣，換回連續版面中的位置
        final o = pageOrigin(currentPageIndex);
        restored = restored * Matrix4.translationValues(-o.dx, -o.dy, 0.0);
      }
      transformation = restored;
    } else {
      resetZoom(); // 若無紀錄則置中
    }

    final targetPage = currentNotebook.lastViewedPageIndex.clamp(0, pages.length - 1);
    _loadPageState(targetPage);
  }

  // ★ 開啟新標籤頁
  void openNotebookInTab(Notebook notebook) {
    final existingIndex = openNotebooks.indexWhere(
      (nb) => nb.id == notebook.id,
    );
    if (existingIndex != -1) {
      // 若已經開著，直接切過去
      switchTab(existingIndex);
    } else {
      // 插入新標籤
      openNotebooks.add(notebook);
      switchTab(openNotebooks.length - 1);
    }
  }

  // ★ 關閉標籤頁 (點擊 x)
  void closeTab(int index, VoidCallback onAllClosed) {
    if (openNotebooks.length <= 1) {
      saveCurrentPage();
      onAllClosed(); // 只剩最後一個標籤，關閉直接退回書架
      return;
    }

    // 1. 如果關閉的是當前選中的標籤，先保存當前頁面
    if (index == activeNotebookIndex) {
      _saveCurrentPageState();
      currentNotebook.lastViewedPageIndex = _savedPageIndex;
    }

    // 2. 移除該標籤
    openNotebooks.removeAt(index);

    // 3. 校準當前選取的標籤索引，防止越界
    if (activeNotebookIndex >= openNotebooks.length) {
      activeNotebookIndex = openNotebooks.length - 1;
    }

    // ★★★ 防護：確保當前筆記本至少有 1 頁，絕不為空 (絕對不能呼叫 pages.clear()！) ★★★
    if (currentNotebook.pages.isEmpty) {
      currentNotebook.pages.add(NotePage(id: 'page_1'));
    }

    // 4. 安全載入當前筆記本的閱讀頁碼
    final targetPage = currentNotebook.lastViewedPageIndex.clamp(
      0,
      currentNotebook.pages.length - 1,
    );
    _loadPageState(targetPage);
    notifyListeners();
  }

  // 頁碼變動時即時更新紀錄
  void _saveCurrentPageState() {
    if (pages.isNotEmpty && currentPageIndex < pages.length) {
      currentPage.strokes = List.from(_historyStrokes);
      currentPage.undoStack = List.from(_undoStack);
      currentPage.redoStack = List.from(_redoStack);
      currentNotebook.lastViewedPageIndex = _savedPageIndex;
      currentNotebook.transformMatrix = _savedMatrix(); // ★ 視野不算內容變更，不動修改時間
    }
  }

  // ==========================================
  // 橡皮擦物理大小與預覽位置
  // ==========================================
  final double eraserScreenRadius = 15.0; // 在螢幕上的真實半徑 (15px)
  Offset? eraserPosition; // 當前橡皮擦位置 (用於即時圓圈預覽)

  // 轉換成畫布世界座標下的感應半徑 (隨縮放動態調整，維持螢幕大小恆定)
  double get currentEraseRadius => eraserScreenRadius / (zoomPercentage / 100);
  // ==========================================
  // 縮放倍率提示 HUD 狀態
  // ==========================================
  bool showZoomIndicator = false;
  Timer? _zoomIndicatorTimer;

  double minScale = 0.1; // 最小縮至 10%
  double maxScale = 100.0; // 最大放大至 10000% (分塊渲染後記憶體與倍率無關)
  Size viewportSize = Size.zero;

  /// 全新筆記 (沒有存過視野)：建構當下還不知道畫面大小，等第一次排版後再置中
  bool _needsInitialCenter = false;

  /// 畫布排版後回報可視範圍 (LayoutBuilder 內呼叫)
  void updateViewportSize(Size size) {
    viewportSize = size;
    if (_needsInitialCenter && !size.isEmpty && pages.isNotEmpty) {
      _needsInitialCenter = false;
      transformation = _placementFor(
        currentPageIndex.clamp(0, pages.length - 1),
        1.0,
      );
    }
  }
  // 獲取當前縮放百分比 (例如 1.0x -> 100%, 2.5x -> 250%)
  double get zoomPercentage {
    final double scaleX = sqrt(
      transformation.storage[0] * transformation.storage[0] +
          transformation.storage[1] * transformation.storage[1],
    );
    return scaleX * 100;
  }

  // 一鍵重設回 100% 原始大小
  void resetZoom() {
    hudMessage = null; // ★ 清空訊息，保證顯示 100%
    if (pages.isEmpty) return;

    // 設定為 100% (Scale = 1.0)，並把目前看的那一頁放到畫面中心
    final index = isContinuous ? focusPageIndex : currentPageIndex;
    transformation = _placementFor(index.clamp(0, pages.length - 1), 1.0);

    showZoomIndicator = true;
    _startZoomIndicatorFadeout();
    notifyListeners();
    refreshDetail();
  }

  @override
  void dispose() {
    images.dispose();
    _saveCurrentPageState(); // ★ 核心修復：退出畫布時，立即把筆跡存回當前頁面！
    _zoomIndicatorTimer?.cancel();
    _scrollSettleTimer?.cancel();
    _lassoLongPressTimer?.cancel();
    _clearPictureCache();
    activeRepaintNotifier.dispose();
    viewSignal.dispose();
    _disposePictureLater(cachedHistoryPicture);
    cachedHistoryPicture = null;
    super.dispose();
  }

  // ★ 公開保存當前頁面筆劃
  void saveCurrentPage() {
    _saveCurrentPageState();
  }

  void _startZoomIndicatorFadeout() {
    _zoomIndicatorTimer?.cancel();
    _zoomIndicatorTimer = Timer(const Duration(milliseconds: 1500), () {
      showZoomIndicator = false;
      notifyListeners();
    });
  }

  // 私有輔助：記錄最近使用顏色
  void _recordRecentColor(Color color) {
    recentColors.remove(color);
    recentColors.insert(0, color);
    if (recentColors.length > 8) {
      recentColors.removeLast();
    }
  }

  // 加入喜愛
  void addFavoriteColor(Color color) {
    if (!favoriteColors.contains(color)) {
      favoriteColors.add(color);
      notifyListeners();
    }
  }

  // 移除喜愛
  void removeFavoriteColor(Color color) {
    favoriteColors.remove(color);
    notifyListeners();
  }

  // 2. 載入目標頁面的狀態
  void _loadPageState(int targetIndex) async {
    if (pages.isEmpty) {
      pages.add(NotePage(id: 'page_1'));
    }
    currentPageIndex = targetIndex.clamp(0, pages.length - 1);
    final targetPage = pages[currentPageIndex];

    // 離開的頁面釋放圖塊與底圖，避免翻頁越翻越吃記憶體
    images.setShown(targetPage);
    _dropPicture(targetPage); // 目前頁改用即時的 cachedHistoryPicture
    _syncVisiblePages();

    _historyStrokes.clear();
    _historyStrokes.addAll(targetPage.strokes);

    _undoStack.clear();
    _undoStack.addAll(targetPage.undoStack);

    _redoStack.clear();
    _redoStack.addAll(targetPage.redoStack);

    clearSelection();
    _bakeHistoryToPicture();
    notifyListeners();

    // 按需載入底圖，完成後若視野是放大的再補上高清圖塊
    await images.loadBase(targetPage);
    images.refreshDetail();
  }

  // 下一頁
  void nextPage() {
    if (isContinuous) {
      goToPage(focusPageIndex + 1);
      return;
    }
    if (currentPageIndex < pages.length - 1) {
      _saveCurrentPageState();
      _loadPageState(currentPageIndex + 1);
    }
  }

  // 上一頁
  void previousPage() {
    if (isContinuous) {
      goToPage(focusPageIndex - 1);
      return;
    }
    if (currentPageIndex > 0) {
      _saveCurrentPageState();
      _loadPageState(currentPageIndex - 1);
    }
  }

  /// 直接跳到指定頁 (0-based)
  void goToPage(int index) {
    if (index < 0 || index >= pages.length) return;
    if (isContinuous) {
      if (index != currentPageIndex) {
        _saveCurrentPageState();
        _loadPageState(index);
      }
      _placeCurrent(); // 連續模式：捲動到該頁
      return;
    }
    if (index == currentPageIndex) return;
    _saveCurrentPageState();
    _loadPageState(index);
  }

  /// 至少要保留一頁
  bool get canDeleteCurrentPage => pages.length > 1;

  /// 刪除目前頁面 (UI 端需先讓使用者確認)。
  /// 刪除後顯示「接替它位置的那一頁」；若刪的是最後一頁則顯示前一頁。
  void deleteCurrentPage() {
    if (!canDeleteCurrentPage) return;
    final removeIndex = currentPageIndex;
    final removed = pages.removeAt(removeIndex);
    _dropPicture(removed);
    _markDirty();
    // _loadPageState 會釋放被刪頁面的底圖/圖塊 (images.setShown 會釋放前一個顯示的頁面)
    _loadPageState(removeIndex.clamp(0, pages.length - 1));
    if (isContinuous) _placeCurrent();
  }

  // 在此頁後面插入一頁空白頁
  void insertBlankPageAfterCurrent() {
    syncCurrentToFocus();
    _saveCurrentPageState();
    final newPage = NotePage(
      id: 'page_${DateTime.now().millisecondsSinceEpoch}',
    );
    // 這裡的 pages.insert 會直接插入 currentNotebook.pages！
    pages.insert(currentPageIndex + 1, newPage);
    _markDirty();
    _loadPageState(currentPageIndex + 1);
    if (isContinuous) _placeCurrent();
  }

  Future<void> insertPdfPagesAfterCurrent(List<PdfPageData> pdfPages) async {
    syncCurrentToFocus();
    _saveCurrentPageState();

    final List<NotePage> newPages = [];
    for (int i = 0; i < pdfPages.length; i++) {
      final data = pdfPages[i];

      newPages.add(NotePage(
        id: 'pdf_page_${DateTime.now().millisecondsSinceEpoch}_$i',
        cachedBackgroundImage: data.initialImage,
        width: data.width,
        height: data.height,
        pdfFilePath: data.filePath,
        pdfPageNumber: data.pageNumber,
        renderedScale: 1.0, // ★ 初始畫布倍率為 100% (1.0)
      ));
    }

    pages.insertAll(currentPageIndex + 1, newPages);
    _markDirty();
    _loadPageState(currentPageIndex + 1);
    if (isContinuous) _placeCurrent();
  }

  void setTool(DrawingTool tool) {
    currentTool = tool;
    eraserPosition = null; // ★ 切換工具時清空圓圈
    activeRepaintNotifier.notifyListeners();
    if (tool != DrawingTool.lasso) {
      clearSelection();
    }
    notifyListeners();
  }

  // 更新筆刷設定 (粗細、平滑度、防手抖、壓感)
  void updateBrush(BrushSettings newSettings) {
    brush = newSettings;
    notifyListeners();
  }

  void clearSelection() {
    _selectedStrokes.clear();
    _selectedLassoPolygon.clear();
    _currentLassoDrawing.clear();
    _isDraggingSelection = false;
    _selectionDragStarted = false;
    _isPotentialNewLasso = false;
    lassoMenu = LassoMenuKind.none;
  }

  // 1. 開始調色：手指按下滑桿瞬間呼叫 (記錄初始快照)
  void beginColorChange() {
    if (_selectedStrokes.isNotEmpty) {
      _colorChangeInitialStrokes = _selectedStrokes
          .map(
            (s) => Stroke(
              points: List.from(s.points),
              color: s.color,
              settings: s.settings,
            ),
          )
          .toList();
    }
  }

  // 2. 調色中：滑桿滑動時呼叫 (只更新視覺畫面，完全不產生 Undo)
  void updateColorPreview(Color newColor) {
    strokeColor = newColor;

    if (_selectedStrokes.isNotEmpty) {
      for (int i = 0; i < _selectedStrokes.length; i++) {
        final oldStroke = _selectedStrokes[i];
        final index = _historyStrokes.indexOf(oldStroke);
        if (index != -1) {
          final updatedStroke = Stroke(
            points: oldStroke.points,
            color: newColor,
            settings: oldStroke.settings,
          );
          _historyStrokes[index] = updatedStroke;
          _selectedStrokes[i] = updatedStroke;
        }
      }
      _bakeHistoryToPicture();
      notifyListeners();
    }
  }

  // 3. 結束調色：手指放開滑桿時呼叫 (打包成唯一一條 Undo 指令)
  void commitColorChange(Color finalColor) {
    strokeColor = finalColor;

    if (_selectedStrokes.isNotEmpty && _colorChangeInitialStrokes != null) {
      // 只有顏色真的不同時才產生 Undo 指令
      if (_colorChangeInitialStrokes!.first.color != finalColor) {
        _undoStack.add(
          ChangeStrokesColorCommand(
            _colorChangeInitialStrokes!,
            List.from(_selectedStrokes),
          ),
        );
        _redoStack.clear();
        _recordRecentColor(finalColor); // 此時才加入最近使用
      }
      _colorChangeInitialStrokes = null;
      _markDirty();
    }
    notifyListeners();
  }

  // 4. 單次點選色塊 (喜愛顏色、最近使用等直接點擊)
  void selectColorDirectly(Color color) {
    beginColorChange();
    updateColorPreview(color);
    commitColorChange(color);
  }

  // 套索選中字換色
  void changeSelectedStrokesColor(Color newColor) {
    strokeColor = newColor;

    if (_selectedStrokes.isNotEmpty) {
      final List<Stroke> oldStrokes = List.from(_selectedStrokes);
      final List<Stroke> updatedStrokes = [];

      for (int i = 0; i < _selectedStrokes.length; i++) {
        final oldStroke = _selectedStrokes[i];
        final index = _historyStrokes.indexOf(oldStroke);
        if (index != -1) {
          final updatedStroke = Stroke(
            points: oldStroke.points,
            color: newColor,
            settings: oldStroke.settings,
          );
          _historyStrokes[index] = updatedStroke;
          _selectedStrokes[i] = updatedStroke;
          updatedStrokes.add(updatedStroke);
        }
      }

      // ★ 1. 加入 Undo 歷史棧：支援將文字顏色復原！
      _undoStack.add(ChangeStrokesColorCommand(oldStrokes, updatedStrokes));
      _redoStack.clear();

      // ★ 2. 算作真正使用該顏色：加入「最近使用」歷史清單！
      _recordRecentColor(newColor);
      _markDirty();

      _bakeHistoryToPicture();
      notifyListeners();
    }
  }

  /// 螢幕座標 → 「目前編輯頁」自己的座標 (連續模式會扣掉該頁在畫布上的位置)
  Offset toScene(Offset screenPoint) {
    final Matrix4 inverse = Matrix4.inverted(transformation);
    return MatrixUtils.transformPoint(inverse, screenPoint) - currentPageOrigin;
  }

  /// 連續模式：手指落在哪一頁，就切換成編輯哪一頁 (落在頁面外則維持原本)
  void _activatePageAt(Offset screenPoint) {
    final raw = MatrixUtils.transformPoint(
      Matrix4.inverted(transformation),
      screenPoint,
    );
    if (pageSceneRect(currentPageIndex).contains(raw)) return;
    for (int i = 0; i < pages.length; i++) {
      if (pageSceneRect(i).contains(raw)) {
        _saveCurrentPageState();
        _loadPageState(i);
        return;
      }
    }
  }

  // 1. 手指落下
  void onPointerDown(int pointerId, Offset position, double pressure) {
    _pointerPositions[pointerId] = position;

    if (_pointerPositions.length >= 2) {
      _isScalingLocked = true;
      _currentPoints.clear();
      _currentLassoDrawing.clear();
      _isPotentialNewLasso = false;
      _lassoLongPressTimer?.cancel();
      lassoMenu = LassoMenuKind.none; // 縮放 / 平移時選單位置會失準，直接收起
      eraserPosition = null;
      _lastEraseScenePoint = null;

      // ★ 雙指輕點判定開始：記錄初始狀態、時間與座標
      if (_pointerPositions.length == 2) {
        _twoFingerTapCandidate = true;
        _twoFingerDownTime = DateTime.now();
        final pts = _pointerPositions.values.toList();
        _finger1Initial = pts[0];
        _finger2Initial = pts[1];
        _initialTwoFingerDistance = (pts[0] - pts[1]).distance;
        _matrixBeforeGesture = transformation.clone();
      } else {
        _twoFingerTapCandidate = false;
      }

      // 雙指誤擦復原保持不變...
      if (_currentErasedBatch.isNotEmpty) {
        // 依移除順序「反向」插回 (排序索引在多次擦除後會插錯位置)
        for (final entry in _currentErasedBatch.reversed) {
          if (entry.key <= _historyStrokes.length) {
            _historyStrokes.insert(entry.key, entry.value);
          } else {
            _historyStrokes.add(entry.value);
          }
        }
        _currentErasedBatch.clear();
        _bakeHistoryToPicture();
      }

      final points = _pointerPositions.values.toList();
      _previousDistance = (points[0] - points[1]).distance;
      _previousMidpoint = (points[0] + points[1]) / 2;
    } else if (!_isScalingLocked && _pointerPositions.length == 1) {
      if (isContinuous) _activatePageAt(position);
      final scenePoint = toScene(position);

      if (currentTool == DrawingTool.pen) {
        _currentPoints.add(PointVector(scenePoint.dx, scenePoint.dy, pressure));
        activeRepaintNotifier.notifyListeners();
        return;
      } else if (currentTool == DrawingTool.eraser) {
        // ★ 記錄位置以繪製感應圓圈
        eraserPosition = scenePoint;
        _lastEraseScenePoint = scenePoint;
        _eraseAlongSegment(scenePoint, scenePoint);
        activeRepaintNotifier.notifyListeners();
        return;
      } else if (currentTool == DrawingTool.lasso) {
        lassoMenu = LassoMenuKind.none; // 任何新的觸碰都先收起選單
        _lassoDownScreen = position;
        if (_selectedLassoPolygon.isNotEmpty &&
            RayCasting.isPointInPolygon(scenePoint, _selectedLassoPolygon)) {
          _isDraggingSelection = true;
          _selectionDragStarted = false;
          _lastDragPosition = scenePoint;
          _totalDragDelta = Offset.zero;
        } else {
          _isPotentialNewLasso = true;
          _potentialLassoStart = scenePoint;
          _startLassoLongPress();
        }
      }
    }
    notifyListeners();
  }

  // 2. 移動中
  void onPointerMove(int pointerId, Offset position, double pressure) {
    _pointerPositions[pointerId] = position;

    if (_isScalingLocked && _pointerPositions.length < 2) return;

    if (!_isScalingLocked && _pointerPositions.length == 1) {
      final scenePoint = toScene(position);

      if (currentTool == DrawingTool.pen) {
        if (_currentPoints.isEmpty) return;

        // ★ 解決第 3 點：直接記錄真實座標！絕對不強制 clamp 拉回邊緣！
        _currentPoints.add(PointVector(scenePoint.dx, scenePoint.dy, pressure));
        activeRepaintNotifier.notifyListeners();
        return;
      } else if (currentTool == DrawingTool.eraser) {
        // ★ 移動時持續更新預覽圓圈位置；以「上一點→這一點」的線段掃掠碰撞
        eraserPosition = scenePoint;
        _eraseAlongSegment(_lastEraseScenePoint ?? scenePoint, scenePoint);
        _lastEraseScenePoint = scenePoint;
        activeRepaintNotifier.notifyListeners();
        return;
      } else if (currentTool == DrawingTool.lasso) {
        if (_isDraggingSelection) {
          // 還在「點一下」的容許範圍內先不移動，避免點擊時筆劃微微位移
          if (!_selectionDragStarted &&
              (position - _lassoDownScreen).distance < _tapSlop) {
            return;
          }
          _selectionDragStarted = true;
          final delta = scenePoint - _lastDragPosition;
          _lastDragPosition = scenePoint;
          _totalDragDelta += delta;

          for (final stroke in _selectedStrokes) {
            for (int i = 0; i < stroke.points.length; i++) {
              final p = stroke.points[i];
              stroke.points[i] = PointVector(
                p.x + delta.dx,
                p.y + delta.dy,
                p.pressure,
              );
            }
          }
          for (int i = 0; i < _selectedLassoPolygon.length; i++) {
            _selectedLassoPolygon[i] = _selectedLassoPolygon[i] + delta;
          }
          _bakeHistoryToPicture();
        } else if (_isPotentialNewLasso) {
          // 手指在容許範圍內微動仍算「按住」，才能觸發長按貼上
          if ((position - _lassoDownScreen).distance < _tapSlop) return;
          _lassoLongPressTimer?.cancel();
          _isPotentialNewLasso = false;
          clearSelection();
          _currentLassoDrawing.add(_potentialLassoStart);
          _currentLassoDrawing.add(scenePoint);
        } else if (_currentLassoDrawing.isNotEmpty) {
          _currentLassoDrawing.add(scenePoint);
        }
      }
    } else if (_pointerPositions.length >= 2) {
      // HUD 尚未顯示、或正顯示文字訊息時才需要整頁重建；其餘只要重繪畫布
      final bool needsFullRebuild = !showZoomIndicator || hudMessage != null;

      // ★★★ 解決問題 2：進入雙指縮放平移，立即清空文字訊息，強制切換回「縮放 %」顯示！★★★
      hudMessage = null;

      final points = _pointerPositions.values.toList();
      final currentDistance = (points[0] - points[1]).distance;
      final currentMidpoint = (points[0] + points[1]) / 2;

      // ★★★ 核心排除演算法：
      // 1. 兩指間距變化超過 6px (代表正在做捏合/展開縮放動作)
      // 2. 任一手指移動超過 8px (代表正在平移拖動)
      // 只要符合其一，立即永遠剝奪本次手勢的 Undo 資格！
      if (_twoFingerTapCandidate) {
        final distanceDelta = (currentDistance - _initialTwoFingerDistance)
            .abs();
        final move1 = _finger1Initial != null
            ? (points[0] - _finger1Initial!).distance
            : 0.0;
        final move2 = _finger2Initial != null
            ? (points[1] - _finger2Initial!).distance
            : 0.0;

        if (distanceDelta > 6.0 || move1 > 8.0 || move2 > 8.0) {
          _twoFingerTapCandidate = false;
        }
      }
      if (_previousDistance > 0 && currentDistance > 0) {
        final double rawScaleFactor = currentDistance / _previousDistance;
        final Offset deltaTranslation = currentMidpoint - _previousMidpoint;

        // 1. 計算目前的實際 2D 縮放倍率
        final double currentScale = sqrt(
          transformation.storage[0] * transformation.storage[0] +
              transformation.storage[1] * transformation.storage[1],
        );

        // 2. ★ 核心限制運算：預測下一刻的縮放倍率，並鉗制在 [minScale, maxScale]
        double effectiveScaleFactor = rawScaleFactor;
        final double projectedScale = currentScale * rawScaleFactor;

        if (projectedScale < minScale) {
          effectiveScaleFactor = minScale / currentScale; // 貼齊下限 (30%)
        } else if (projectedScale > maxScale) {
          effectiveScaleFactor = maxScale / currentScale; // 貼齊上限 (500%)
        }

        // 3. 套用有效縮放與平移矩陣
        final Matrix4 deltaMatrix =
            Matrix4.translationValues(
              currentMidpoint.dx + deltaTranslation.dx,
              currentMidpoint.dy + deltaTranslation.dy,
              0.0,
            ) *
            Matrix4.diagonal3Values(
              effectiveScaleFactor,
              effectiveScaleFactor,
              1.0,
            ) *
            Matrix4.translationValues(
              -currentMidpoint.dx,
              -currentMidpoint.dy,
              0.0,
            );

        transformation = deltaMatrix * transformation;
        if (isContinuous) _syncVisiblePages();

        // 顯示縮放膠囊
        showZoomIndicator = true;
        _zoomIndicatorTimer?.cancel();
      }

      _previousDistance = currentDistance;
      _previousMidpoint = currentMidpoint;
      if (needsFullRebuild) {
        notifyListeners();
      } else {
        viewSignal.fire();
      }
      return;
    }
    notifyListeners();
  }

  // 3. 離地
  void onPointerUp(int pointerId) {
    // ★★★ 核心觸發：瞬間雙指輕點 (時間 < 250ms 且無位移無捏合) ★★★
    if (_twoFingerTapCandidate && _twoFingerDownTime != null) {
      final elapsed = DateTime.now()
          .difference(_twoFingerDownTime!)
          .inMilliseconds;
      _twoFingerTapCandidate = false;
      _twoFingerDownTime = null;

      // 嚴格限制在 250 毫秒內放開手指
      if (elapsed < 250) {
        // 還原輕點期間可能產生的 0.001% 微小抖動
        if (_matrixBeforeGesture != null) {
          transformation = _matrixBeforeGesture!;
        }

        // ★ 解決問題 1：只有真正能 Undo 時才執行並顯示「已復原」，否則顯示「無可復原項目」
        if (canUndo) {
          undo();
          _showHudMessage('已復原');
        } else {
          _showHudMessage('無可復原項目');
        }
      }
    }

    _pointerPositions.remove(pointerId);

    if (!_isScalingLocked) {
      if (currentTool == DrawingTool.pen && _currentPoints.isNotEmpty) {
        final stroke = Stroke(
          points: List.from(_currentPoints),
          color: strokeColor,
          settings: brush,
        );
        _historyStrokes.add(stroke);
        _undoStack.add(DrawStrokeCommand(stroke));
        _redoStack.clear();
        _currentPoints.clear();
        _recordRecentColor(strokeColor);
        _appendToPicture(stroke); // 增量烘焙：不必重畫所有舊筆劃
        _markDirty();
        activeRepaintNotifier.notifyListeners();
      } else if (currentTool == DrawingTool.eraser) {
        // ★ 核心修復：無論有沒有擦到字，只要手指抬起，感應圈必定清空！
        eraserPosition = null;
        _lastEraseScenePoint = null;

        // 只有真的有擦到字，才打包進 Undo 歷史
        if (_currentErasedBatch.isNotEmpty) {
          _undoStack.add(EraseStrokesCommand(List.from(_currentErasedBatch)));
          _redoStack.clear();
          _currentErasedBatch.clear();
          _markDirty();
        }

        // ★ 必定通知活動層重繪（抹掉感應圓圈）
        activeRepaintNotifier.notifyListeners();
      } else if (currentTool == DrawingTool.lasso) {
        if (_isDraggingSelection) {
          if (_selectionDragStarted) {
            if (_totalDragDelta != Offset.zero) {
              _undoStack.add(
                MoveStrokesCommand(List.from(_selectedStrokes), _totalDragDelta),
              );
              _redoStack.clear();
              _markDirty();
            }
          } else {
            // 在圈選範圍內「點一下」→ 顯示 剪下 / 複製 / 刪除 / 截圖
            lassoMenu = LassoMenuKind.selection;
            lassoMenuAnchor = _lassoDownScreen;
          }
          _isDraggingSelection = false;
          _selectionDragStarted = false;
        } else if (_isPotentialNewLasso) {
          // 在範圍外 / 空白處點一下：取消選取 (「貼上」改由長按觸發)
          _lassoLongPressTimer?.cancel();
          clearSelection();
        } else if (_currentLassoDrawing.length > 2) {
          _selectedLassoPolygon.clear();
          _selectedLassoPolygon.addAll(_currentLassoDrawing);
          _currentLassoDrawing.clear();
          _calculateLassoSelection();
        }
      }
    }

    if (_pointerPositions.isEmpty) {
      final wasScaling = _isScalingLocked;
      _isScalingLocked = false;
      _previousDistance = 0.0;

      // ★ 雙指縮放放開時，自動向 pdfrx 索取高清渲染
      if (wasScaling) {
        refreshDetail();
      }
      // ★ 手指全部離開後，倍率膠囊過一會兒自動消失 (文字訊息自己有計時器)
      if (showZoomIndicator && hudMessage == null) {
        _startZoomIndicatorFadeout();
      }
    }
    notifyListeners();
  }

  // 顯示短暫的浮動膠囊提示 (800ms 自動淡出)
  void _showHudMessage(String message, {IconData icon = Icons.undo}) {
    hudMessage = message;
    hudIcon = icon;
    showZoomIndicator = true;
    _zoomIndicatorTimer?.cancel();
    _zoomIndicatorTimer = Timer(const Duration(milliseconds: 800), () {
      showZoomIndicator = false;
      hudMessage = null;
      notifyListeners();
    });
    notifyListeners();
  }

  // ==========================================
  // 套索選單動作：複製 / 剪下 / 刪除 / 貼上 / 截圖
  // ==========================================
  /// 套索工具在空白處按住：剪貼簿有內容時，時間到就浮出「貼上」
  void _startLassoLongPress() {
    _lassoLongPressTimer?.cancel();
    if (!hasClipboard) return;
    _lassoLongPressTimer = Timer(_longPressDelay, () {
      if (!_isPotentialNewLasso ||
          currentTool != DrawingTool.lasso ||
          _pointerPositions.length != 1 ||
          !isInsidePage(_potentialLassoStart)) {
        return;
      }
      clearSelection();
      lassoMenu = LassoMenuKind.paste;
      lassoMenuAnchor = _lassoDownScreen;
      _pasteScenePoint = _potentialLassoStart;
      HapticFeedback.selectionClick();
      notifyListeners();
    });
  }

  void hideLassoMenu() {
    if (lassoMenu == LassoMenuKind.none) return;
    lassoMenu = LassoMenuKind.none;
    notifyListeners();
  }

  void copySelection() {
    if (_selectedStrokes.isEmpty) return;
    _clipboard = _selectedStrokes.map((s) => s.copy()).toList();
    lassoMenu = LassoMenuKind.none;
    _showHudMessage('已複製 ${_clipboard.length} 筆', icon: Icons.content_copy);
  }

  void cutSelection() {
    if (_selectedStrokes.isEmpty) return;
    _clipboard = _selectedStrokes.map((s) => s.copy()).toList();
    final n = _clipboard.length;
    _removeSelectedStrokes();
    _showHudMessage('已剪下 $n 筆', icon: Icons.content_cut);
  }

  void deleteSelection() {
    if (_selectedStrokes.isEmpty) return;
    final n = _selectedStrokes.length;
    _removeSelectedStrokes();
    _showHudMessage('已刪除 $n 筆', icon: Icons.delete_outline);
  }

  /// 刪除目前選取的筆劃 (可復原；沿用橡皮擦命令：依移除順序記錄索引)
  void _removeSelectedStrokes() {
    final removed = <MapEntry<int, Stroke>>[];
    for (final stroke in _selectedStrokes) {
      final i = _historyStrokes.indexOf(stroke);
      if (i == -1) continue;
      removed.add(MapEntry(i, stroke));
      _historyStrokes.removeAt(i);
    }
    if (removed.isNotEmpty) {
      _undoStack.add(EraseStrokesCommand(removed));
      _redoStack.clear();
      _markDirty();
    }
    clearSelection();
    _bakeHistoryToPicture();
    activeRepaintNotifier.notifyListeners();
    notifyListeners();
  }

  /// 把剪貼簿內容貼到剛才點的位置 (以內容中心對齊，並保持在紙張內)，貼完自動選取方便拖動
  void pasteFromClipboard() {
    if (_clipboard.isEmpty) return;
    Rect? b;
    for (final s in _clipboard) {
      b = b == null ? s.bounds : b.expandToInclude(s.bounds);
    }
    if (b == null) return;

    Offset shift = _pasteScenePoint - b.center;
    final moved = b.shift(shift);
    final pw = currentPage.width, ph = currentPage.height;
    double dx = 0, dy = 0;
    if (moved.right > pw) dx = pw - moved.right;
    if (moved.bottom > ph) dy = ph - moved.bottom;
    if (moved.left + dx < 0) dx = -moved.left;
    if (moved.top + dy < 0) dy = -moved.top;
    shift += Offset(dx, dy);

    final pasted = _clipboard
        .map(
          (s) => Stroke(
            points: s.points
                .map((p) => PointVector(p.x + shift.dx, p.y + shift.dy, p.pressure))
                .toList(),
            color: s.color,
            settings: s.settings,
          ),
        )
        .toList();

    _historyStrokes.addAll(pasted);
    _undoStack.add(AddStrokesCommand(pasted));
    _redoStack.clear();
    _markDirty();

    clearSelection();
    _selectedStrokes.addAll(pasted);
    final box = b.shift(shift).inflate(8);
    _selectedLassoPolygon.addAll([
      box.topLeft,
      box.topRight,
      box.bottomRight,
      box.bottomLeft,
    ]);

    _bakeHistoryToPicture();
    activeRepaintNotifier.notifyListeners();
    _showHudMessage('已貼上', icon: Icons.content_paste);
  }

  /// 截圖：套索虛線的「最小外接矩形」(裁在紙張內)，輸出 PNG。含底圖與範圍內所有筆劃。
  Future<Uint8List?> captureSelectionPng() async {
    if (_selectedLassoPolygon.isEmpty) return null;
    final pageRect = Rect.fromLTWH(0, 0, currentPage.width, currentPage.height);
    final region = _boundsOf(_selectedLassoPolygon).intersect(pageRect);
    if (region.width < 1 || region.height < 1) return null;

    final dpr = ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
    final scale = (dpr * max(1.0, zoomPercentage / 100)).clamp(2.0, 8.0).toDouble();
    return RegionCapture.renderPng(
      page: currentPage,
      strokes: List.of(_historyStrokes),
      region: region,
      scale: scale,
    );
  }

  void _calculateLassoSelection() {
    _selectedStrokes.clear();

    // 套索外框：和筆劃外框不相交的筆劃不必逐點檢查
    final polyBounds = _boundsOf(_selectedLassoPolygon);

    for (final stroke in _historyStrokes) {
      if (!stroke.bounds.inflate(1.0).overlaps(polyBounds)) continue;
      bool isHit = false;
      for (final p in stroke.points) {
        if (RayCasting.isPointInPolygon(
          Offset(p.x, p.y),
          _selectedLassoPolygon,
        )) {
          isHit = true;
          break;
        }
      }

      if (isHit) {
        _selectedStrokes.add(stroke);
      }
    }

    if (_selectedStrokes.isEmpty) {
      _selectedLassoPolygon.clear();
    }
    notifyListeners();
  }

  Rect _boundsOf(List<Offset> pts) {
    double minX = pts.first.dx, maxX = minX, minY = pts.first.dy, maxY = minY;
    for (final p in pts) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// ★ 橡皮擦：以「上一個取樣點 → 目前點」的掃掠線段 (膠囊體) 對筆劃的每一段做碰撞。
  /// 舊版只比較取樣點與圓心距離，手移動得快、或筆劃取樣稀疏時會直接穿過去擦不到。
  void _eraseAlongSegment(Offset from, Offset to) {
    final double radius = currentEraseRadius;
    bool hasChanged = false;

    for (int i = _historyStrokes.length - 1; i >= 0; i--) {
      final stroke = _historyStrokes[i];
      if (stroke.hitsCapsule(from, to, radius)) {
        _currentErasedBatch.add(MapEntry(i, stroke));
        _historyStrokes.removeAt(i);
        hasChanged = true;
      }
    }

    if (hasChanged) {
      _bakeHistoryToPicture();
      notifyListeners();
    }
  }

  void undo() {
    if (_undoStack.isNotEmpty) {
      final command = _undoStack.removeLast();
      command.undo(_historyStrokes);
      _redoStack.add(command);
      _markDirty();
      clearSelection();
      _bakeHistoryToPicture();
      notifyListeners();
    }
  }

  void redo() {
    if (_redoStack.isNotEmpty) {
      final command = _redoStack.removeLast();
      command.redo(_historyStrokes);
      _undoStack.add(command);
      _markDirty();
      clearSelection();
      _bakeHistoryToPicture();
      notifyListeners();
    }
  }

  // 靜態歷史筆畫烘焙 (全量重畫；筆劃輪廓 Path 已快取，不會重新跑 perfect_freehand)
  void _bakeHistoryToPicture() {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()..style = PaintingStyle.fill;

    for (final stroke in _historyStrokes) {
      paint.color = stroke.color;
      canvas.drawPath(stroke.outlinePath, paint);
    }

    final old = cachedHistoryPicture;
    cachedHistoryPicture = recorder.endRecording();
    _incrementalBakes = 0;
    _disposePictureLater(old); // ★ 舊 Picture 持有原生記憶體，必須釋放
  }

  /// 增量烘焙：新增一條筆劃時，只把它疊到現有 Picture 上。
  /// 疊太多層會讓播放變慢，每 40 次回到全量烘焙一次壓平。
  void _appendToPicture(Stroke stroke) {
    final base = cachedHistoryPicture;
    if (base == null || _incrementalBakes >= 40) {
      _bakeHistoryToPicture();
      return;
    }
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawPicture(base);
    canvas.drawPath(
      stroke.outlinePath,
      Paint()
        ..color = stroke.color
        ..style = PaintingStyle.fill,
    );
    cachedHistoryPicture = recorder.endRecording();
    _incrementalBakes++;
    _disposePictureLater(base);
  }

  void _disposePictureLater(ui.Picture? picture) {
    if (picture == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => picture.dispose());
    WidgetsBinding.instance.scheduleFrame();
  }

  // ★ 標籤拖曳交換順序
  void reorderTabs(int oldIndex, int newIndex) {
    // 注意：ReorderableListView.onReorderItem 給的 newIndex 已經是修正過的最終位置，
    // 不可以再 -1 (舊的 onReorder 才需要)，否則往右拖會少移一格、放手後彈回原位。

    // 1. 記錄當前正在看的筆記本 ID
    final currentActiveId = currentNotebook.id;

    // 2. 移除並重新插入到目標位置
    final movedNotebook = openNotebooks.removeAt(oldIndex);
    openNotebooks.insert(newIndex, movedNotebook);

    // 3. 重新校準當前聚焦索引，確保拖動後選中的依然是同一本筆記
    activeNotebookIndex = openNotebooks.indexWhere(
      (nb) => nb.id == currentActiveId,
    );

    notifyListeners();
  }

  /// 供外部 (排版完成後) 呼叫
  void refreshDetail() {
    _syncVisiblePages();
    images.refreshDetail();
  }
}
