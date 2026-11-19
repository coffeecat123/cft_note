// lib/features/canvas/presentation/controllers/canvas_controller.dart
import 'dart:math';
import 'dart:ui' as ui;
import 'dart:async';
import 'dart:typed_data';

import 'package:cft_note/features/pdf_import_export/services/pdf_service.dart';
import 'package:cft_note/features/shelf/domain/models/notebook.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:perfect_freehand/perfect_freehand.dart';

import '../../../../core/algorithms/ray_casting.dart';
import '../../../../core/algorithms/rot_frame.dart';
import '../../../../core/algorithms/shape_recognizer.dart';
import '../../../../core/i18n/app_strings.dart';
import '../../../../core/engine/repaint_signal.dart';
import '../../../../core/engine/tile_planner.dart';
import '../../domain/models/brush_settings.dart';
import '../../domain/models/canvas_prefs.dart';
import '../../domain/models/stroke.dart';
import '../../domain/commands/canvas_command.dart';
import '../../domain/models/page_layout_mode.dart';
import '../../domain/models/tools.dart';
import '../../../document/data/page_image_store.dart';
import '../../../document/data/storage_service.dart';
import '../../../pdf_import_export/services/clipboard_image_service.dart';
import '../../../document/domain/note_page.dart';
import '../../../document/domain/page_background.dart';
import '../../../document/domain/page_image.dart';
import 'page_image_manager.dart';
import 'region_capture.dart';

/// 圖片模式下，一次手指按下後正在做的操作
enum _ImageOp { none, move, resize, rotate, delete }

// 2. 主畫布控制器 (CanvasController)
/// 縮放 / 平移時用來取代向量筆劃的點陣快取。
/// [image] 為 null 代表這一頁筆劃不多，直接畫向量就夠快。
class StrokeRaster {
  final ui.Picture source; // 烘焙來源：用 identity 判斷筆劃是否變動過
  final ui.Image? image;
  final ui.Rect rect; // 點陣涵蓋的頁面範圍 (頁面座標)
  final double scale; // 烘焙時每個頁面單位的像素數
  final DateTime bakedAt;
  StrokeRaster(this.source, this.image, [this.rect = ui.Rect.zero, this.scale = 0])
    : bakedAt = DateTime.now();
}

/// [CanvasController.rasterFor] 的回傳：點陣圖與它對應的頁面範圍
class RasterView {
  final ui.Image image;
  final ui.Rect rect;
  const RasterView(this.image, this.rect);
}

class CanvasController extends ChangeNotifier {
  bool _disposed = false;
  final List<Stroke> _historyStrokes = [];
  final List<CanvasCommand> _undoStack = [];
  final List<CanvasCommand> _redoStack = [];
  final List<PointVector> _currentPoints = [];
  double _smoothedPressure = 0.5; // 目前筆劃平滑後的壓力
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
    _schedulePrefsSave();
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
    _scrollInteracting = true;
    _showZoomIndicatorWhilePanning();
    viewSignal.fire();
    _scrollSettleTimer?.cancel();
    _scrollSettleTimer = Timer(const Duration(milliseconds: 150), () {
      _scrollInteracting = false;
      if (showZoomIndicator && hudMessage == null) _startZoomIndicatorFadeout();
      refreshDetail();
      viewSignal.fire(); // 停手後切回向量筆劃
      _scheduleRasterRelease();
    });
  }

  // ---- 非編輯頁的筆劃 Picture 快取 (編輯頁用 cachedHistoryPicture) ----
  final Map<NotePage, ui.Picture> _pagePictures = {};

  // ---- 縮放 / 平移中的筆劃點陣快取 ----
  // 向量 Picture 每一幀都要讓 GPU 重新填色全部筆劃；筆劃一多，縮放就會掉幀。
  // 互動中 (雙指縮放 / 平移 / 滾輪) 改畫「整頁筆劃的點陣圖」，成本與筆劃數量無關；
  // 停手後立刻切回向量，所以靜止時依然銳利。
  static const int _rasterMinPoints = 3000; // 少於這麼多點的頁面直接畫向量
  static const int _rasterMaxPages = 8;
  final Map<NotePage, StrokeRaster> _rasters = {};
  Timer? _rasterReleaseTimer;
  bool _viewMoving = false; // 雙指真的在縮放 / 平移
  bool _scrollInteracting = false; // 滾輪捲動中 (停手 150ms 後結束)

  bool get isViewInteracting => _viewMoving || _scrollInteracting;

  /// 互動中回傳「目前可視範圍」的筆劃點陣圖 (解析度 = 螢幕實際像素，不受整頁大小限制)；
  /// [visible] 為可視範圍 (該頁座標，已裁在紙張內)。回傳 null 請直接畫向量。
  RasterView? rasterFor(int i, ui.Rect visible) {
    if (!isViewInteracting) return null;
    if (i < 0 || i >= pages.length) return null;
    if (visible.width <= 0 || visible.height <= 0) return null;
    final pic = pictureFor(i);
    if (pic == null) return null;
    final page = pages[i];

    var r = _rasters.remove(page); // 取出再放回 = 最近使用排最後
    var rebake = r == null || !identical(r.source, pic);
    if (!rebake && r.image != null) {
      final plan = _rasterPlan(page, visible);
      final covered = TilePlanner.covers(
        outerL: r.rect.left, outerT: r.rect.top,
        outerR: r.rect.right, outerB: r.rect.bottom,
        innerL: visible.left, innerT: visible.top,
        innerR: visible.right, innerB: visible.bottom,
      );
      // 範圍不夠 / 放大後解析度不足 → 重烘；連續縮放時 90ms 內只重烘一次
      final needs = !covered || r.scale < plan.scale * 0.8;
      final recent = DateTime.now().difference(r.bakedAt).inMilliseconds < 90;
      rebake = needs && !recent;
    }
    if (rebake) {
      r?.image?.dispose();
      r = _bakeRaster(page, i, pic, visible);
    }
    _rasters[page] = r!;
    _rasterReleaseTimer?.cancel();
    while (_rasters.length > _rasterMaxPages) {
      _rasters.remove(_rasters.keys.first)?.image?.dispose();
    }
    final img = r.image;
    return img == null ? null : RasterView(img, r.rect);
  }

  TilePlan _rasterPlan(NotePage page, ui.Rect vis) {
    final dpr = ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
    return TilePlanner.plan(
      pageW: page.width,
      pageH: page.height,
      visLeft: vis.left,
      visTop: vis.top,
      visRight: vis.right,
      visBottom: vis.bottom,
      zoom: zoomPercentage / 100,
      dpr: dpr,
    );
  }

  StrokeRaster _bakeRaster(NotePage page, int i, ui.Picture pic, ui.Rect vis) {
    final strokes = i == currentPageIndex ? _historyStrokes : page.strokes;
    int cost = 0;
    for (final st in strokes) {
      cost += st.points.length;
      if (cost >= _rasterMinPoints) break;
    }
    if (cost < _rasterMinPoints) return StrokeRaster(pic, null);
    if (page.width <= 0 || page.height <= 0) return StrokeRaster(pic, null);

    final plan = _rasterPlan(page, vis);
    final pw = max(1, (plan.width * plan.scale).ceil());
    final ph = max(1, (plan.height * plan.scale).ceil());

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(pw / plan.width, ph / plan.height);
    canvas.translate(-plan.left, -plan.top);
    canvas.drawPicture(pic);
    final baked = recorder.endRecording();
    final image = baked.toImageSync(pw, ph);
    _disposePictureLater(baked);
    return StrokeRaster(
      pic,
      image,
      ui.Rect.fromLTRB(plan.left, plan.top, plan.right, plan.bottom),
      plan.scale,
    );
  }

  void _scheduleRasterRelease() {
    _rasterReleaseTimer?.cancel();
    _rasterReleaseTimer = Timer(const Duration(seconds: 3), _disposeRasters);
  }

  void _disposeRasters() {
    _rasterReleaseTimer?.cancel();
    for (final r in _rasters.values) {
      r.image?.dispose();
    }
    _rasters.clear();
  }

  ui.Picture? pictureFor(int i) {
    if (i == currentPageIndex) return cachedHistoryPicture;
    final page = pages[i];
    if (page.strokes.isEmpty) return null;
    return _pagePictures[page] ??= _bakeStrokes(page.strokes);
  }

  ui.Picture _bakeStrokes(List<Stroke> strokes) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    for (final stroke in strokes) {
      canvas.drawPath(stroke.outlinePath, stroke.fillPaint);
    }
    return recorder.endRecording();
  }

  void _dropPicture(NotePage page) {
    _disposePictureLater(_pagePictures.remove(page));
    _rasters.remove(page)?.image?.dispose();
  }

  void _clearPictureCache() {
    for (final pic in _pagePictures.values) {
      _disposePictureLater(pic);
    }
    _pagePictures.clear();
    _disposeRasters();
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
  // 一般筆與螢光筆各自記一份顏色 / 筆刷；strokeColor / brush 永遠指向「目前工具」那一份，
  // 其他地方 (調色盤、筆刷設定、預覽) 不用知道現在是哪一支筆。
  Color _penColor = Colors.black;
  Color _highlighterColor = const Color(0xFFFFEB3B);
  BrushSettings _penBrush = BrushSettings.fountainPen; // 預設使用鋼筆設定
  BrushSettings _highlighterBrush = BrushSettings.highlighterPreset;

  bool get isHighlighterTool => currentTool == DrawingTool.highlighter;

  /// 會留下筆跡的工具 (筆 / 螢光筆)
  bool get _isInkTool =>
      currentTool == DrawingTool.pen || currentTool == DrawingTool.highlighter;

  Color get strokeColor => isHighlighterTool ? _highlighterColor : _penColor;
  set strokeColor(Color c) {
    if (isHighlighterTool) {
      _highlighterColor = c;
    } else {
      _penColor = c;
    }
  }

  BrushSettings get brush => isHighlighterTool ? _highlighterBrush : _penBrush;
  set brush(BrushSettings b) {
    if (isHighlighterTool) {
      // 螢光筆一律等寬、保持螢光筆標記
      _highlighterBrush = b.copyWith(thinning: 0.0, isHighlighter: true);
    } else {
      _penBrush = b.copyWith(isHighlighter: false);
    }
  }
  ui.Picture? cachedHistoryPicture;
  // 記錄調色剛開始時的筆劃備份
  List<Stroke>? _colorChangeInitialStrokes;
  List<Color>? _colorChangeInitialColors;
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
  Matrix4 _transformation = Matrix4.identity();
  Matrix4 get transformation => _transformation;
  set transformation(Matrix4 value) {
    // 慣性滑動中，只要別處 (換頁、縮放、還原...) 改了矩陣就中止滑動
    if (_flinging && !_flingStepping) _stopFling();
    _transformation = value;
  }
  final Map<int, Offset> _pointerPositions = {};
  double _previousDistance = 0.0;
  Offset _previousMidpoint = Offset.zero;
  bool _isScalingLocked = false;
  bool _gestureCancelled = false; // 切換工具而被取消的動作：到所有手指離開前都不處理

  // 套索狀態
  final List<Offset> _currentLassoDrawing = [];
  final List<Offset> _selectedLassoPolygon = [];
  final List<Stroke> _selectedStrokes = [];
  final List<PageImage> _selectedImages = []; // 套索一起圈到的圖片
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
  Timer? _pasteHoldTimer; // 套索以外的工具：空白處長按 → 顯示「貼上」
  Offset _lassoDownScreen = Offset.zero;
  bool _selectionDragStarted = false;
  // 防誤觸下手指在套索圈外：單指平移畫布 (沒移動就放開 = 點一下取消選取；按住 = 長按貼上)
  bool _isLassoPanning = false;
  bool _lassoPanMoved = false;
  // 同一組選取連續換色 → 合併成一筆 Undo (換完才算一筆，不會塞滿歷史)
  ChangeStrokesColorCommand? _colorSession;
  LassoMenuKind lassoMenu = LassoMenuKind.none;
  Offset lassoMenuAnchor = Offset.zero; // 螢幕座標 (選單出現位置)
  bool lassoMenuCanPasteStrokes = false; // 貼上選單：套索剪貼簿有筆劃
  bool lassoMenuCanPasteImage = false; // 貼上選單：系統剪貼簿有圖片
  Offset _pasteScenePoint = Offset.zero;

  /// 套索剪貼簿 (static：換頁、換筆記本都還在；只存在記憶體)
  static List<Stroke> _clipboard = [];
  static List<PageImage> _clipboardImages = [];
  bool get hasClipboard => _clipboard.isNotEmpty || _clipboardImages.isNotEmpty;

  List<PointVector> get currentPoints => _currentPoints;
  List<Stroke> get historyStrokes => _historyStrokes;
  List<Offset> get currentLassoDrawing => _currentLassoDrawing;
  List<Offset> get selectedLassoPolygon => _selectedLassoPolygon;
  List<Stroke> get selectedStrokes => _selectedStrokes;
  List<PageImage> get selectedImages => _selectedImages;
  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;
  // ==========================================
  // ★ 雙指輕點 Undo 手勢精準追蹤
  // ==========================================
  bool _twoFingerTapCandidate = false;
  DateTime? _twoFingerDownTime;
  DateTime? _firstFingerDownTime; // 第一根手指落下的時間 (判斷兩指是不是「同時」按下)
  static const int _twoFingerTapMaxGapMs = 120; // 兩指落下的時間差超過這個值就不算雙指輕點

  // 三指輕點 = 重做：三指幾乎同時按下、很快一起抬起、期間幾乎沒有移動
  bool _threeFingerTapCandidate = false;
  bool _threeFingerSession = false; // 這一輪出現過三根手指：到全部離開前都不縮放 / 平移
  DateTime? _threeFingerDownTime;
  List<Offset> _threeFingerInitial = const [];
  static const int _threeFingerTapMaxGapMs = 100; // 第一指到第三指落下的時間差上限
  static const double _threeFingerTapSlop = 12.0; // 任一指移動超過這個距離就不算輕點
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
        title: S.current.untitledNotebook,
        coverColor: const Color(0xFF2B3A4A),
        updatedAt: DateTime.now(),
      );
      openNotebooks.add(fallbackBook);
      activeNotebookIndex = 0;
    }

    if (pages.isEmpty) {
      pages.add(NotePage(id: 'page_1'));
    }

    // ★ 還原上次的畫筆 / 顏色 / 頁面顯示方式 (要在還原視野矩陣之前，連續模式的頁面位置才正確)
    final prefs = CanvasPrefs.initial;
    _penBrush = prefs.brush.copyWith(isHighlighter: false);
    _penColor = prefs.strokeColor;
    _highlighterBrush = prefs.highlighterBrush;
    _highlighterColor = prefs.highlighterColor;
    layoutMode = prefs.layoutMode;
    lastBlankBackground = prefs.lastBlankBackground;
    newPageStyle = prefs.newPageStyle;
    recentBackgrounds.addAll(prefs.recentBackgrounds.take(8));
    eraserScreenRadius = prefs.eraserRadius;
    eraseTargetPen = prefs.eraseTargetPen;
    eraseTargetHighlighter = prefs.eraseTargetHighlighter;
    lassoTargetPen = prefs.lassoTargetPen;
    lassoTargetHighlighter = prefs.lassoTargetHighlighter;
    lassoTargetImage = prefs.lassoTargetImage;
    palmRejection = prefs.palmRejection;
    gesturesEnabled = prefs.gesturesEnabled;
    screenshotScale = prefs.screenshotScale;
    if (prefs.favoriteColors != null) {
      favoriteColors
        ..clear()
        ..addAll(prefs.favoriteColors!);
    }
    recentColors.addAll(prefs.recentColors.take(8));

    final targetPage = currentNotebook.lastViewedPageIndex.clamp(0, pages.length - 1);

    // ★ 還原該筆記本上次儲存的縮放平移矩陣；沒有紀錄 (全新筆記) 則等取得畫面大小後置中
    if (currentNotebook.transformMatrix != null) {
      var restored = Matrix4.fromList(currentNotebook.transformMatrix!);
      if (isContinuous) {
        // 存的是「該頁在原點」的矩陣，換回連續版面中的位置
        final o = pageOrigin(targetPage);
        restored = restored * Matrix4.translationValues(-o.dx, -o.dy, 0.0);
      }
      transformation = restored;
    } else {
      _needsInitialCenter = true;
    }

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
  /// 最後一個標籤已被關閉 (離開畫布頁時，書架不應再保留任何開啟中的標籤)
  bool allTabsClosed = false;

  void closeTab(int index, VoidCallback onAllClosed) {
    if (openNotebooks.length <= 1) {
      saveCurrentPage();
      allTabsClosed = true; // 書架就不再顯示「繼續編輯」
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
  static const double minEraserRadius = 5;
  static const double maxEraserRadius = 60;
  double eraserScreenRadius = 15.0; // 在螢幕上的真實半徑 (預設 15px，可調整並記住)

  void setEraserRadius(double radius) {
    final r = radius.clamp(minEraserRadius, maxEraserRadius).toDouble();
    if (r == eraserScreenRadius) return;
    eraserScreenRadius = r;
    _schedulePrefsSave();
    notifyListeners();
  }
  Offset? eraserPosition; // 當前橡皮擦位置 (用於即時圓圈預覽)

  // 橡皮擦 / 套索可作用的對象 (至少保留一項；設定會記住)
  bool eraseTargetPen = true;
  bool eraseTargetHighlighter = true;
  bool lassoTargetPen = true;
  bool lassoTargetHighlighter = true;
  bool lassoTargetImage = true;

  void setEraseTargets({bool? pen, bool? highlighter}) {
    final p = pen ?? eraseTargetPen;
    final h = highlighter ?? eraseTargetHighlighter;
    if (!p && !h) return; // 至少留一項
    if (p == eraseTargetPen && h == eraseTargetHighlighter) return;
    eraseTargetPen = p;
    eraseTargetHighlighter = h;
    _schedulePrefsSave();
    notifyListeners();
  }

  void setLassoTargets({bool? pen, bool? highlighter, bool? image}) {
    final p = pen ?? lassoTargetPen;
    final h = highlighter ?? lassoTargetHighlighter;
    final i = image ?? lassoTargetImage;
    if (!p && !h && !i) return; // 至少留一項
    if (p == lassoTargetPen && h == lassoTargetHighlighter && i == lassoTargetImage) {
      return;
    }
    lassoTargetPen = p;
    lassoTargetHighlighter = h;
    lassoTargetImage = i;
    clearSelection(); // 對象改了，目前的選取就不適用了
    _schedulePrefsSave();
    notifyListeners();
  }

  bool _erasable(Stroke s) =>
      s.settings.isHighlighter ? eraseTargetHighlighter : eraseTargetPen;

  bool _lassoSelectable(Stroke s) =>
      s.settings.isHighlighter ? lassoTargetHighlighter : lassoTargetPen;

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

  /// 點縮放膠囊：把「目前這頁」依寬度或高度貼齊畫面，再點一次換成另一種 (寬 ↔ 高)。
  ///  - 目前已經是貼齊寬度 → 改貼齊高度；已經是貼齊高度 → 改貼齊寬度。
  ///  - 都不是時：橫向連續模式先貼齊高度，其他模式先貼齊寬度。
  ///  - 貼齊的那一軸剛好填滿畫面；另一軸比畫面大就對齊頂端 / 左端，比畫面小就置中。
  void fitPage() {
    hudMessage = null;
    if (pages.isEmpty || viewportSize.isEmpty) {
      resetZoom();
      return;
    }
    final index = (isContinuous ? focusPageIndex : currentPageIndex).clamp(
      0,
      pages.length - 1,
    );
    final p = pages[index];
    final o = pageOrigin(index);
    if (p.width <= 0 || p.height <= 0) {
      resetZoom();
      return;
    }
    final fw = (viewportSize.width / p.width).clamp(minScale, maxScale).toDouble();
    final fh = (viewportSize.height / p.height).clamp(minScale, maxScale).toDouble();
    final cur = zoomPercentage / 100;
    bool near(double a, double b) => (a - b).abs() <= b * 0.005;

    final bool toHeight;
    if (near(cur, fw) && !near(cur, fh)) {
      toHeight = true;
    } else if (near(cur, fh) && !near(cur, fw)) {
      toHeight = false;
    } else {
      toHeight = layoutMode == PageLayoutMode.horizontal;
    }

    final s = toHeight ? fh : fw;
    final sw = p.width * s, sh = p.height * s;
    final tx = sw > viewportSize.width && toHeight
        ? -s * o.dx // 貼齊高度、頁面比畫面寬：左端對齊
        : (viewportSize.width - sw) / 2 - s * o.dx;
    final ty = sh > viewportSize.height && !toHeight
        ? -s * o.dy // 貼齊寬度、頁面比畫面高：頂端對齊
        : (viewportSize.height - sh) / 2 - s * o.dy;
    transformation =
        Matrix4.translationValues(tx, ty, 0.0) *
        Matrix4.diagonal3Values(s, s, 1.0);

    if (isContinuous) _syncVisiblePages();
    showZoomIndicator = true;
    _startZoomIndicatorFadeout();
    notifyListeners();
    refreshDetail();
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
    _disposed = true;
    _flinging = false;
    _shapeHoldTimer?.cancel();
    flushPrefs();
    images.dispose();
    _saveCurrentPageState(); // ★ 核心修復：退出畫布時，立即把筆跡存回當前頁面！
    _zoomIndicatorTimer?.cancel();
    _scrollSettleTimer?.cancel();
    _disposeRasters();
    _lassoLongPressTimer?.cancel();
    _pasteHoldTimer?.cancel();
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

  // ---- 書籤 ----
  /// 工具列書籤按鈕對應的頁面 (連續模式 = 畫面上看到的那一頁)
  int get bookmarkTargetIndex => isContinuous && pages.isNotEmpty
      ? focusPageIndex.clamp(0, pages.length - 1)
      : currentPageIndex;

  bool get currentPageBookmarked =>
      pages.isNotEmpty && pages[bookmarkTargetIndex].bookmarked;

  void toggleBookmark(int index, {bool showHud = false}) {
    if (index < 0 || index >= pages.length) return;
    final page = pages[index];
    page.bookmarked = !page.bookmarked;
    _markDirty();
    if (showHud) {
      _showHudMessage(
        page.bookmarked ? S.current.bookmarkAdded : S.current.bookmarkRemoved,
        icon: page.bookmarked ? Icons.bookmark : Icons.bookmark_border,
      );
    } else {
      notifyListeners();
    }
  }

  void toggleCurrentBookmark() => toggleBookmark(bookmarkTargetIndex, showHud: true);

  void _startZoomIndicatorFadeout() {
    _zoomIndicatorTimer?.cancel();
    _zoomIndicatorTimer = Timer(const Duration(milliseconds: 700), () {
      showZoomIndicator = false;
      notifyListeners();
    });
  }

  // ==========================================
  // 偏好設定 (畫筆 / 顏色 / 頁面顯示方式) 存檔：防抖，停止調整 0.6 秒後才寫入
  // ==========================================
  Timer? _prefsSaveTimer;

  void _schedulePrefsSave() {
    _prefsSaveTimer?.cancel();
    _prefsSaveTimer = Timer(const Duration(milliseconds: 600), flushPrefs);
  }

  /// 立刻寫入偏好設定 (App 進背景 / 離開畫布時呼叫)
  void flushPrefs() {
    if (_prefsSaveTimer == null) return; // 沒有待寫入的變更
    _prefsSaveTimer!.cancel();
    _prefsSaveTimer = null;
    final prefs = CanvasPrefs(
      brush: _penBrush,
      strokeColor: _penColor,
      highlighterBrush: _highlighterBrush,
      highlighterColor: _highlighterColor,
      layoutMode: layoutMode,
      recentColors: List.of(recentColors),
      favoriteColors: List.of(favoriteColors),
      lastBlankBackground: lastBlankBackground,
      newPageStyle: newPageStyle,
      recentBackgrounds: List.of(recentBackgrounds),
      eraserRadius: eraserScreenRadius,
      eraseTargetPen: eraseTargetPen,
      eraseTargetHighlighter: eraseTargetHighlighter,
      lassoTargetPen: lassoTargetPen,
      lassoTargetHighlighter: lassoTargetHighlighter,
      lassoTargetImage: lassoTargetImage,
      palmRejection: palmRejection,
      gesturesEnabled: gesturesEnabled,
      screenshotScale: screenshotScale,
    );
    CanvasPrefs.initial = prefs; // 下次開筆記 / 切換標籤時直接用最新值
    unawaited(StorageService.saveCanvasPrefs(prefs.toJson()));
  }

  // 私有輔助：記錄最近使用顏色
  void _recordRecentColor(Color color) {
    recentColors.remove(color);
    recentColors.insert(0, color);
    if (recentColors.length > 8) {
      recentColors.removeLast();
    }
    _schedulePrefsSave();
  }

  // 加入喜愛
  void addFavoriteColor(Color color) {
    if (!favoriteColors.contains(color)) {
      favoriteColors.add(color);
      _schedulePrefsSave();
      notifyListeners();
    }
  }

  // 移除喜愛
  void removeFavoriteColor(Color color) {
    favoriteColors.remove(color);
    _schedulePrefsSave();
    notifyListeners();
  }

  // 2. 載入目標頁面的狀態
  void _loadPageState(int targetIndex) async {
    if (pages.isEmpty) {
      pages.add(NotePage(id: 'page_1'));
    }
    currentPageIndex = targetIndex.clamp(0, pages.length - 1);
    final targetPage = pages[currentPageIndex];
    // 換到空白頁就把它的背景記進「最近使用」(PDF 頁面不用)
    if (targetPage.isBlank) recordRecentBackground(targetPage.background);

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

  /// 一次刪除多頁 (UI 端需先讓使用者確認)。至少要保留一頁，
  /// 全部選取時不執行。目前頁沒被刪就繼續停在同一頁，被刪則改顯示接替它位置的頁面。
  void deletePages(Set<int> indices) {
    final remove = indices.where((i) => i >= 0 && i < pages.length).toList()
      ..sort();
    if (remove.isEmpty || remove.length >= pages.length) return;
    final oldCurrent = currentPageIndex;
    final currentRemoved = remove.contains(oldCurrent);
    if (!currentRemoved) _saveCurrentPageState();
    final keep = currentRemoved ? null : pages[oldCurrent];
    for (final i in remove.reversed) {
      _dropPicture(pages.removeAt(i));
    }
    _markDirty();
    final int target;
    if (keep != null) {
      target = pages.indexOf(keep);
    } else {
      final before = remove.where((i) => i < oldCurrent).length;
      target = (oldCurrent - before).clamp(0, pages.length - 1);
    }
    _loadPageState(target);
    if (isContinuous) _placeCurrent();
  }

  // ==========================================
  // ★ 空白頁背景 (紙張顏色 + 格線)
  //   - 可只改目前頁，或一次改此筆記本的所有空白頁 (PDF 頁面不受影響)
  //   - 每次修改都記成「上次修改的樣式」(存進偏好設定)，
  //     新增空白頁 / 新增筆記本時可直接沿用，也可選擇改成跟目前頁面一樣
  // ==========================================
  PageBackground lastBlankBackground = PageBackground.standard;
  NewPageStyle newPageStyle = NewPageStyle.lastUsed;

  /// 最近使用的頁面背景 (最新在前，最多 8 個)
  final List<PageBackground> recentBackgrounds = [];

  /// 記錄一個背景樣式到「最近使用」。不通知畫面 (背景選單關閉時呼叫)。
  void recordRecentBackground(PageBackground bg) {
    if (recentBackgrounds.isNotEmpty && recentBackgrounds.first == bg) return;
    recentBackgrounds.remove(bg);
    recentBackgrounds.insert(0, bg);
    if (recentBackgrounds.length > 8) recentBackgrounds.removeLast();
    _schedulePrefsSave();
  }

  void removeRecentBackground(PageBackground bg) {
    if (recentBackgrounds.remove(bg)) _schedulePrefsSave();
  }

  /// 目前頁面是空白頁 (PDF 頁面不能設定背景)
  bool get currentPageIsBlank => currentPage.isBlank;

  /// 這本筆記本有幾頁空白頁
  int get blankPageCount => pages.where((p) => p.isBlank).length;

  /// 背景選單開啟時的初始值：目前是空白頁就用它，否則用上次的樣式
  PageBackground get backgroundForSheet =>
      currentPage.isBlank ? currentPage.background : lastBlankBackground;

  /// 套用背景。[allBlankPages] = true → 此筆記本所有空白頁；false → 只有目前頁。
  void applyPageBackground(PageBackground bg, {required bool allBlankPages}) {
    bool changed = false;
    if (allBlankPages) {
      for (final p in pages) {
        if (p.isBlank && p.background != bg) {
          p.background = bg;
          changed = true;
        }
      }
    } else if (currentPage.isBlank && currentPage.background != bg) {
      currentPage.background = bg;
      changed = true;
    }
    if (lastBlankBackground != bg) {
      lastBlankBackground = bg;
      _schedulePrefsSave();
    }
    if (changed) {
      _markDirty(); // 觸發自動存檔
      notifyListeners(); // 重繪畫布
    }
  }

  void setNewPageStyle(NewPageStyle style) {
    if (style == newPageStyle) return;
    newPageStyle = style;
    _schedulePrefsSave();
    notifyListeners();
  }

  /// 新增空白頁時要用的背景
  PageBackground _backgroundForNewPage() {
    if (newPageStyle == NewPageStyle.currentPage && currentPage.isBlank) {
      return currentPage.background;
    }
    return lastBlankBackground;
  }

  // 在此頁後面插入一頁空白頁
  void insertBlankPageAfterCurrent() {
    syncCurrentToFocus();
    _saveCurrentPageState();
    final newPage = NotePage(
      id: 'page_${DateTime.now().millisecondsSinceEpoch}',
      background: _backgroundForNewPage(),
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

  /// 手指 / 筆還按在畫布上、卻切換了工具：整個動作取消 (寫到一半的筆劃不留、
  /// 擦掉的筆劃還原、套索拖曳移回原位、圖片操作還原)，而且這次按下之後的
  /// 移動 / 抬起都不再生效，直到所有手指離開。
  void _cancelActiveGesture() {
    if (_pointerPositions.isEmpty) return;
    _gestureCancelled = true;

    // 畫筆：丟掉寫到一半的筆劃
    _currentPoints.clear();

    // 橡皮擦：把這一次已擦掉的筆劃放回去
    if (_currentErasedBatch.isNotEmpty) {
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
    eraserPosition = null;
    _lastEraseScenePoint = null;

    // 套索：取消圈選 / 長按；拖曳到一半就移回原位
    _lassoLongPressTimer?.cancel();
    _pasteHoldTimer?.cancel();
    _currentLassoDrawing.clear();
    _isPotentialNewLasso = false;
    _isLassoPanning = false;
    _lassoPanMoved = false;
    if (_isDraggingSelection && _selectionDragStarted && _totalDragDelta != Offset.zero) {
      final back = -_totalDragDelta;
      for (final stroke in _selectedStrokes) {
        for (int i = 0; i < stroke.points.length; i++) {
          final p = stroke.points[i];
          stroke.points[i] = PointVector(p.x + back.dx, p.y + back.dy, p.pressure);
        }
      }
      for (final img in _selectedImages) {
        img.rect = img.rect.shift(back);
      }
      for (int i = 0; i < _selectedLassoPolygon.length; i++) {
        _selectedLassoPolygon[i] = _selectedLassoPolygon[i] + back;
      }
      if (_selectedStrokes.isNotEmpty) _bakeHistoryToPicture();
    }
    _isDraggingSelection = false;
    _selectionDragStarted = false;
    _totalDragDelta = Offset.zero;

    // 圖片模式：搬移 / 縮放做到一半就還原成按下前的位置
    final img = _selectedImage;
    final start = _imageStartRect;
    if (img != null && start != null && _imageOpIsEdit) {
      img.rect = start;
      img.rotation = _imageStartRot;
    }
    _xfRevert();
    _resetShapeState();
    _imageOp = _ImageOp.none;
    _imageStartRect = null;
    _imageDragStarted = false;
    _imageCandidate = null;
    _imageDeselectPending = false;
  }

  void setTool(DrawingTool tool) {
    final bool changed = tool != currentTool;
    if (changed) _cancelActiveGesture();
    currentTool = tool;
    eraserPosition = null; // ★ 切換工具時清空圓圈
    activeRepaintNotifier.notifyListeners();
    // 換工具一定清掉選取與浮出的選單 (圖片模式 → 套索時，圖片選單 / 選取也不能留著)
    if (changed || tool != DrawingTool.lasso) {
      clearSelection();
    }
    notifyListeners();
  }

  // 更新筆刷設定 (粗細、平滑度、防手抖、壓感)
  void updateBrush(BrushSettings newSettings) {
    brush = newSettings;
    _schedulePrefsSave();
    notifyListeners();
  }

  void clearSelection() {
    _revertPendingColorChange();
    _selectedStrokes.clear();
    _selectedImages.clear();
    _selectedLassoPolygon.clear();
    _currentLassoDrawing.clear();
    _isDraggingSelection = false;
    _selectionDragStarted = false;
    _isPotentialNewLasso = false;
    _colorSession = null;
    lassoMenu = LassoMenuKind.none;
    _selectedImage = null; // 圖片模式的選取也一併清掉
    _imageOp = _ImageOp.none;
    _imageStartRect = null;
    _imageCandidate = null;
    _imageDeselectPending = false;
    _endSelectionTransformState();
  }

  // 1. 開始調色：手指按下滑桿瞬間呼叫 (記錄初始顏色)
  //   ★ 換色一律「就地修改」Stroke.color，絕不替換歷史裡的 Stroke 物件。
  //   其他 Undo 指令都靠物件身分找筆劃；替換物件只要有一條路徑沒配對好指令，
  //   就會留下無法 Undo 的殘留筆劃。
  void beginColorChange() {
    if (_selectedStrokes.isNotEmpty) {
      _colorChangeInitialStrokes = List<Stroke>.of(_selectedStrokes);
      _colorChangeInitialColors = _selectedStrokes.map((s) => s.color).toList();
    }
  }

  // 2. 調色中：滑桿滑動時呼叫 (只更新視覺畫面，完全不產生 Undo)
  void updateColorPreview(Color newColor) {
    strokeColor = newColor;

    if (_selectedStrokes.isNotEmpty) {
      for (final s in _selectedStrokes) {
        s.color = newColor;
      }
      _bakeHistoryToPicture();
      notifyListeners();
    }
  }

  // 3. 結束調色：手指放開滑桿時呼叫 (打包成唯一一條 Undo 指令)
  void commitColorChange(Color finalColor) {
    strokeColor = finalColor;
    _schedulePrefsSave();

    final initStrokes = _colorChangeInitialStrokes;
    final initColors = _colorChangeInitialColors;
    if (_selectedStrokes.isNotEmpty && initStrokes != null && initColors != null) {
      // 同一組選取連續換色：只在「第一次」開一筆 Undo，之後都更新那一筆
      // (原色 = 第一次換色前的顏色；最後換回原色就整筆撤掉)
      final session = _colorSession;
      final inSession = session != null &&
          _undoStack.isNotEmpty &&
          identical(_undoStack.last, session);
      final targets = inSession ? session.targets : initStrokes;
      final originals = inSession ? session.oldColors : initColors;
      final changed = originals.any((c) => c != finalColor);

      if (inSession) _undoStack.removeLast();
      if (changed) {
        final cmd = ChangeStrokesColorCommand(
          targets,
          originals,
          List<Color>.filled(targets.length, finalColor),
        );
        _undoStack.add(cmd);
        _colorSession = cmd;
        _redoStack.clear();
        _recordRecentColor(finalColor);
      } else {
        // 換回原色：筆劃顏色已是原色，不需任何指令
        _colorSession = null;
      }
      _markDirty();
    }
    _colorChangeInitialStrokes = null;
    _colorChangeInitialColors = null;
    notifyListeners();
  }

  /// 調色做到一半被中斷 (選取被清掉、切工具…)：還原成調色前的顏色，不留下沒有 Undo 的變動
  void _revertPendingColorChange() {
    final strokes = _colorChangeInitialStrokes;
    final colors = _colorChangeInitialColors;
    _colorChangeInitialStrokes = null;
    _colorChangeInitialColors = null;
    if (strokes == null || colors == null) return;
    for (int i = 0; i < strokes.length && i < colors.length; i++) {
      strokes[i].color = colors[i];
    }
    _bakeHistoryToPicture();
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
    _schedulePrefsSave();

    if (_selectedStrokes.isNotEmpty) {
      final targets = List<Stroke>.of(_selectedStrokes);
      final oldColors = targets.map((s) => s.color).toList();
      if (oldColors.any((c) => c != newColor)) {
        for (final s in targets) {
          s.color = newColor;
        }
        _undoStack.add(ChangeStrokesColorCommand(
          targets,
          oldColors,
          List<Color>.filled(targets.length, newColor),
        ));
        _redoStack.clear();
        _markDirty();
      }
      _recordRecentColor(newColor);
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

  // ==========================================
  // ★ 圖片模式
  //   點圖片 → 選取 (外框 + 握把)；框內拖曳 = 平移；
  //   右下角 = 以圖片中心為基準等比縮放；上方圓形握把 = 繞中心旋轉；右上角 = 刪除。
  //   所有座標都是「目前編輯頁」的頁面座標；握把大小以螢幕像素為準 (隨縮放換算)。
  // ==========================================
  static const double imageHandleHitScreen = 24.0; // 握把可點擊半徑 (螢幕 px)
  static const double imageHandleDrawScreen = 12.0; // 握把繪製半徑 (螢幕 px)
  static const double imageRotateHandleScreen = 36.0; // 旋轉握把離上邊的距離 (螢幕 px)
  static const double _imageMinSide = 10.0; // 圖片短邊最小值 (頁面單位)

  PageImage? _selectedImage;
  _ImageOp _imageOp = _ImageOp.none;
  Rect? _imageStartRect;
  double _imageStartRot = 0.0;
  Offset _imageDownScene = Offset.zero;
  Offset _imageLastScene = Offset.zero;
  Offset _imageDownScreen = Offset.zero; // 按下的螢幕座標 (選單出現位置)
  bool _imageDragStarted = false;
  // 按在「尚未選取」的圖片上：等手指放開 / 拖動才真正選取 (雙指縮放時不會換掉選取)
  PageImage? _imageCandidate;
  // 按在空白處：等手指放開才取消選取 (雙指縮放時不會被取消)
  bool _imageDeselectPending = false;

  bool get isImageMode => currentTool == DrawingTool.image;

  bool get _imageOpIsEdit =>
      _imageOp == _ImageOp.move ||
      _imageOp == _ImageOp.resize ||
      _imageOp == _ImageOp.rotate;

  /// 目前選取的圖片 (已不在頁面上則視為沒有)
  PageImage? get selectedImage {
    final s = _selectedImage;
    return (s != null && currentPage.images.contains(s)) ? s : null;
  }

  double get _imageHitRadius => imageHandleHitScreen / (zoomPercentage / 100);

  /// 旋轉握把離外框上邊的距離 (頁面單位)；繪製與點擊共用
  double get rotateHandleOffsetScene =>
      imageRotateHandleScreen / (zoomPercentage / 100);

  /// 外框 (圖片或套索選取框) 上，這一點按到了什麼：握把優先，其次框內 = 平移
  _ImageOp _frameOpAt(RotFrame f, Offset p) {
    final hr = _imageHitRadius;
    if ((p - f.deleteHandle).distance <= hr) return _ImageOp.delete;
    if ((p - f.scaleHandle).distance <= hr) return _ImageOp.resize;
    if ((p - f.rotateHandle(rotateHandleOffsetScene)).distance <= hr) {
      return _ImageOp.rotate;
    }
    if (f.contains(p)) return _ImageOp.move;
    return _ImageOp.none;
  }

  /// 螢幕上的這一點是否落在「已選取圖片 / 套索調整框」的框或握把上
  bool _pointerHitsSelectedImage(Offset screenPoint) {
    if (currentTool == DrawingTool.lasso && selectionTransformMode) {
      return _frameOpAt(selectionFrame, toScene(screenPoint)) != _ImageOp.none;
    }
    if (!isImageMode) return false;
    final sel = selectedImage;
    if (sel == null) return false;
    return _frameOpAt(sel.frame, toScene(screenPoint)) != _ImageOp.none;
  }

  /// 這些外框 (頁面座標) 只要有任何一個超出頁面範圍，就浮出提醒。
  void _warnIfOutOfPage(Iterable<Rect> boxes) {
    if (_disposed || pages.isEmpty) return;
    final pw = currentPage.width, ph = currentPage.height;
    const eps = 0.5;
    for (final b in boxes) {
      if (b.left < -eps || b.top < -eps || b.right > pw + eps || b.bottom > ph + eps) {
        _showHudMessage(
          S.current.outOfPageWarning,
          icon: Icons.warning_amber_rounded,
        );
        return;
      }
    }
  }

  /// 目前套索選取內容的外框們 (筆劃 + 圖片)
  List<Rect> get _selectionBoxes => [
    for (final st in _selectedStrokes)
      st.bounds.inflate(st.settings.size * 0.5),
    for (final im in _selectedImages) im.bounds,
  ];

  void _imageDown(Offset p) {
    _imageOp = _ImageOp.none;
    _imageDragStarted = false;
    _imageCandidate = null;
    _imageDeselectPending = false;
    _imageDownScene = p;
    _imageLastScene = p;

    PageImage? target;
    _ImageOp op = _ImageOp.none;

    // 已選取的圖片優先 (它的握把可能超出圖片範圍)：立刻開始操作
    final sel = selectedImage;
    if (sel != null) {
      op = _frameOpAt(sel.frame, p);
      if (op != _ImageOp.none) target = sel;
    }
    if (target != null) {
      _imageOp = op;
      _imageStartRect = target.rect;
      _imageStartRot = target.rotation;
      viewSignal.fire();
      return;
    }

    // 否則找最上面那張被點到的圖片 → 先當候選；放開 / 拖動才真正選取
    final list = currentPage.images;
    for (int i = list.length - 1; i >= 0; i--) {
      if (list[i].frame.contains(p)) {
        _imageCandidate = list[i];
        _imageOp = _ImageOp.move;
        _imageStartRect = list[i].rect;
        _imageStartRot = list[i].rotation;
        return;
      }
    }
    // 空白處：放開才取消選取 (可能是雙指縮放的第一根手指)
    _imageDeselectPending = selectedImage != null;
  }

  void _imageMove(Offset p) {
    _imageLastScene = p;
    final double movedPx = (p - _imageDownScene).distance * (zoomPercentage / 100);

    if (_imageDeselectPending) {
      if (movedPx >= _tapSlop) _imageDeselectPending = false; // 拖動 = 不是點一下
      return;
    }
    final candidate = _imageCandidate;
    if (candidate != null) {
      if (movedPx < _tapSlop) return;
      _selectedImage = candidate; // 拖動開始才選取並移動
      _imageCandidate = null;
      _imageDragStarted = true;
    }

    final img = _selectedImage;
    final start = _imageStartRect;
    if (img == null || start == null) return;

    switch (_imageOp) {
      case _ImageOp.move:
        // 點一下選取時手指會微動，超過容許範圍才算拖曳
        if (!_imageDragStarted) {
          if (movedPx < _tapSlop) return;
          _imageDragStarted = true;
        }
        img.rect = start.shift(p - _imageDownScene); // 不再限制在頁面內，放開後超出會提醒
        break;
      case _ImageOp.resize:
        // 以圖片中心為基準等比縮放：新大小 = 手指離中心的距離 / 按下時離中心的距離
        final c = start.center;
        final d0 = (_imageDownScene - c).distance;
        if (d0 < 1e-6) return;
        final aspect = start.width / start.height;
        final minW = aspect >= 1 ? _imageMinSide * aspect : _imageMinSide;
        final maxW = max(currentPage.width, currentPage.height) * 4;
        final w = (start.width * (p - c).distance / d0)
            .clamp(minW, max(minW, maxW))
            .toDouble();
        img.rect = Rect.fromCenter(center: c, width: w, height: w / aspect);
        break;
      case _ImageOp.rotate:
        final c = start.center;
        final a0 = atan2(_imageDownScene.dy - c.dy, _imageDownScene.dx - c.dx);
        final a1 = atan2(p.dy - c.dy, p.dx - c.dx);
        img.rotation = RotFrame.snap(_imageStartRot + (a1 - a0)); // 接近 45° 倍數會吸附
        break;
      case _ImageOp.delete:
      case _ImageOp.none:
        return;
    }
    viewSignal.fire();
  }

  void _imageUp() {
    final candidate = _imageCandidate;
    final deselect = _imageDeselectPending;
    _imageCandidate = null;
    _imageDeselectPending = false;
    if (candidate != null) {
      _imageOp = _ImageOp.none;
      _imageStartRect = null;
      _selectedImage = candidate; // 點一下 = 只選取；再點一次才浮出選單
      viewSignal.fire();
      return;
    }
    if (deselect) {
      _selectedImage = null; // 點空白處 = 取消選取
      viewSignal.fire();
      return;
    }

    final img = _selectedImage;
    final start = _imageStartRect;
    final op = _imageOp;
    final bool wasTap = !_imageDragStarted;
    _imageOp = _ImageOp.none;
    _imageStartRect = null;
    _imageDragStarted = false;
    if (img == null || start == null || op == _ImageOp.none) return;

    // 在已選取的圖片框內點一下 (沒有拖動) → 浮出 剪下 / 複製 / 刪除
    if (op == _ImageOp.move && wasTap) {
      lassoMenu = LassoMenuKind.image;
      lassoMenuAnchor = _imageDownScreen;
      notifyListeners();
      return;
    }

    if (op == _ImageOp.delete) {
      // 手指放開時還在刪除握把上才算「按下刪除」
      if ((_imageLastScene - img.frame.deleteHandle).distance <= _imageHitRadius) {
        _deleteImage(img);
      }
      return;
    }
    _pushImageTransform(img, start, _imageStartRot);
    _warnIfOutOfPage([img.bounds]);
  }

  void _pushImageTransform(PageImage img, Rect startRect, double startRot) {
    if (img.rect == startRect && img.rotation == startRot) return;
    _undoStack.add(
      TransformImageCommand(
        img,
        startRect,
        img.rect,
        fromRotation: startRot,
        toRotation: img.rotation,
      ),
    );
    _redoStack.clear();
    _markDirty();
  }

  /// 第二根手指落下 (雙指縮放 / 平移畫面)：不打斷圖片編輯。
  /// 已經做出的平移 / 縮放 / 旋轉就地確定 (可復原)，選取狀態原封不動，縮放完還能繼續編輯。
  void _suspendImageOp() {
    final img = _selectedImage;
    final start = _imageStartRect;
    if (_imageCandidate == null && img != null && start != null && _imageOpIsEdit) {
      _pushImageTransform(img, start, _imageStartRot);
    }
    _imageOp = _ImageOp.none;
    _imageStartRect = null;
    _imageDragStarted = false;
    _imageCandidate = null;
    _imageDeselectPending = false;
    _xfSuspend(); // 套索調整大小做到一半也一併確定
  }

  void _deleteImage(PageImage img, {bool hud = true}) {
    final list = currentPage.images;
    final i = list.indexOf(img);
    if (i == -1) return;
    list.removeAt(i);
    _undoStack.add(RemoveImageCommand(list, img, i));
    _redoStack.clear();
    _selectedImage = null;
    _markDirty();
    if (hud) _showHudMessage(S.current.imageDeleted, icon: Icons.delete_outline);
  }

  /// 圖片模式選單：複製 / 剪下 / 刪除目前選取的圖片 (剪貼簿與套索共用，可到套索模式貼上)
  void _copyImageToClipboard(PageImage img) {
    _clipboard = [];
    _clipboardImages = [img.copy()];
  }

  bool get _imageMenuTarget => currentTool == DrawingTool.image && selectedImage != null;

  // ==========================================
  // ★ 套索「調整大小」 (貼上之後也自動進入)
  //   選單按下「調整大小」→ 選取範圍出現與圖片編輯相同的外框 + 握把：
  //   框內拖曳 = 平移；右下角 = 以中心等比縮放；上方握把 = 繞中心旋轉；右上角 = 刪除。
  //   筆劃的點與粗細、圖片的位置 / 大小 / 角度都一起變換，整個動作一次 Undo。
  // ==========================================
  bool selectionTransformMode = false;
  Rect _xfBox = Rect.zero; // 外框 (未旋轉座標)，旋轉繞其中心
  double _xfRot = 0.0;
  _ImageOp _xfOp = _ImageOp.none;
  bool _xfMoved = false;
  Offset _xfDownScene = Offset.zero;
  Offset _xfDownScreen = Offset.zero;
  Offset _xfLastScene = Offset.zero;
  Rect _xfStartBox = Rect.zero;
  double _xfStartRot = 0.0;
  List<StrokeXformState> _xfStrokesStart = const [];
  List<ImageXformState> _xfImagesStart = const [];
  List<Offset> _xfPolyStart = const [];

  RotFrame get selectionFrame => RotFrame(_xfBox, _xfRot);

  /// 選單「調整大小」
  void beginSelectionTransform() {
    if (!_hasSelectedContent) return;
    lassoMenu = LassoMenuKind.none;

    if (_selectedStrokes.isEmpty && _selectedImages.length == 1) {
      // 只有一張圖：直接用圖片自己的 (含旋轉的) 外框，和圖片編輯完全一樣
      final im = _selectedImages.first;
      _xfBox = im.rect;
      _xfRot = im.rotation;
    } else {
      Rect? b;
      for (final st in _selectedStrokes) {
        final r = st.bounds.inflate(st.settings.size * 0.5);
        b = b == null ? r : b.expandToInclude(r);
      }
      for (final im in _selectedImages) {
        b = b == null ? im.bounds : b.expandToInclude(im.bounds);
      }
      if (b == null) return;
      b = b.inflate(4);
      _xfBox = Rect.fromCenter(
        center: b.center,
        width: max(b.width, 20.0),
        height: max(b.height, 20.0),
      );
      _xfRot = 0.0;
    }
    selectionTransformMode = true;
    _xfOp = _ImageOp.none;
    viewSignal.fire();
    notifyListeners();
  }

  void _endSelectionTransformState() {
    selectionTransformMode = false;
    _xfOp = _ImageOp.none;
    _xfMoved = false;
  }

  void _xfSnapshot() {
    _xfStartBox = _xfBox;
    _xfStartRot = _xfRot;
    _xfStrokesStart = [
      for (final st in _selectedStrokes)
        StrokeXformState(st, List.of(st.points), st.settings.size),
    ];
    _xfImagesStart = [
      for (final im in _selectedImages) ImageXformState(im, im.rect, im.rotation),
    ];
    _xfPolyStart = List.of(_selectedLassoPolygon);
  }

  /// 按下：落在外框 / 握把上就開始操作，回傳 true
  bool _xfDown(Offset scenePoint, Offset screenPoint) {
    final op = _frameOpAt(selectionFrame, scenePoint);
    if (op == _ImageOp.none) return false;
    _xfOp = op;
    _xfMoved = false;
    _xfDownScene = scenePoint;
    _xfLastScene = scenePoint;
    _xfDownScreen = screenPoint;
    _xfSnapshot();
    viewSignal.fire();
    return true;
  }

  void _xfMove(Offset scenePoint, Offset screenPoint) {
    _xfLastScene = scenePoint;
    if (_xfOp == _ImageOp.delete || _xfOp == _ImageOp.none) return;
    if (!_xfMoved) {
      if ((screenPoint - _xfDownScreen).distance < _tapSlop) return;
      _xfMoved = true;
    }
    final c0 = _xfStartBox.center;
    Offset t = Offset.zero;
    double s = 1.0, dr = 0.0;
    switch (_xfOp) {
      case _ImageOp.move:
        t = scenePoint - _xfDownScene;
        break;
      case _ImageOp.resize:
        final d0 = (_xfDownScene - c0).distance;
        if (d0 < 1e-6) return;
        final minSide = min(_xfStartBox.width, _xfStartBox.height);
        final maxSide = max(_xfStartBox.width, _xfStartBox.height);
        final sMin = min(1.0, _imageMinSide / minSide);
        final sMax = max(
          1.0,
          max(currentPage.width, currentPage.height) * 4 / maxSide,
        );
        s = ((scenePoint - c0).distance / d0).clamp(sMin, sMax).toDouble();
        break;
      case _ImageOp.rotate:
        final a0 = atan2(_xfDownScene.dy - c0.dy, _xfDownScene.dx - c0.dx);
        final a1 = atan2(scenePoint.dy - c0.dy, scenePoint.dx - c0.dx);
        dr = RotFrame.snap(_xfStartRot + (a1 - a0)) - _xfStartRot;
        break;
      case _ImageOp.delete:
      case _ImageOp.none:
        return;
    }
    _xfApply(c0, t, s, dr);
  }

  /// 以起始快照為基準：繞 [c0] 旋轉 [dr]、縮放 [s]，再平移 [t]
  void _xfApply(Offset c0, Offset t, double s, double dr) {
    final cNew = c0 + t;
    Offset map(Offset q) => cNew + RotFrame.rotate((q - c0) * s, dr);

    for (final st in _xfStrokesStart) {
      final dst = st.stroke.points;
      for (int i = 0; i < dst.length; i++) {
        final p = st.points[i];
        final m = map(Offset(p.x, p.y));
        dst[i] = PointVector(m.dx, m.dy, p.pressure);
      }
      final ns = (st.size * s).clamp(1.0, 50.0).toDouble();
      if (st.stroke.settings.size != ns) {
        st.stroke.settings = st.stroke.settings.copyWith(size: ns);
        st.stroke.invalidate();
      }
    }
    for (final st in _xfImagesStart) {
      st.image.rect = Rect.fromCenter(
        center: map(st.rect.center),
        width: st.rect.width * s,
        height: st.rect.height * s,
      );
      st.image.rotation = RotFrame.normalize(st.rotation + dr);
    }
    for (int i = 0; i < _xfPolyStart.length && i < _selectedLassoPolygon.length; i++) {
      _selectedLassoPolygon[i] = map(_xfPolyStart[i]);
    }
    _xfBox = Rect.fromCenter(
      center: cNew,
      width: _xfStartBox.width * s,
      height: _xfStartBox.height * s,
    );
    _xfRot = RotFrame.normalize(_xfStartRot + dr);

    if (_selectedStrokes.isNotEmpty) {
      _bakeHistoryToPicture();
      activeRepaintNotifier.notifyListeners();
      notifyListeners();
    } else {
      viewSignal.fire();
    }
  }

  /// 放開 / 第二根手指落下：把這次操作定案 (記一筆 Undo)。
  /// 沒有移動 (點一下框內) → 浮出 剪下 / 複製 / 刪除 / 截圖 選單。
  void _xfCommit() {
    final op = _xfOp;
    if (op == _ImageOp.none) return;
    _xfOp = _ImageOp.none;

    if (op == _ImageOp.delete) {
      if ((_xfLastScene - selectionFrame.deleteHandle).distance <= _imageHitRadius) {
        deleteSelection();
      }
      return;
    }
    if (!_xfMoved) {
      if (op == _ImageOp.move) {
        lassoMenu = LassoMenuKind.selection;
        lassoMenuAnchor = _lassoDownScreen;
      }
      return;
    }
    _xfMoved = false;
    final cmd = TransformSelectionCommand(
      strokesBefore: _xfStrokesStart,
      strokesAfter: [
        for (final st in _selectedStrokes)
          StrokeXformState(st, List.of(st.points), st.settings.size),
      ],
      imagesBefore: _xfImagesStart,
      imagesAfter: [
        for (final im in _selectedImages) ImageXformState(im, im.rect, im.rotation),
      ],
    );
    _undoStack.add(cmd);
    _redoStack.clear();
    _colorSession = null; // 變換之後再換色是新的一筆
    _markDirty();
    _warnIfOutOfPage(_selectionBoxes);
  }

  /// 第二根手指落下：做出來的變換照樣定案，但不要浮出選單
  void _xfSuspend() {
    if (_xfOp == _ImageOp.none) return;
    if (_xfMoved && _xfOp != _ImageOp.delete) {
      _xfCommit();
    } else {
      _xfOp = _ImageOp.none;
      _xfMoved = false;
    }
  }

  /// 手勢被取消 (切換工具...)：做到一半的變換還原成按下前
  void _xfRevert() {
    if (_xfOp == _ImageOp.none) return;
    if (_xfMoved && _xfOp != _ImageOp.delete) {
      _xfApply(_xfStartBox.center, Offset.zero, 1.0, 0.0);
      _xfBox = _xfStartBox;
      _xfRot = _xfStartRot;
    }
    _xfOp = _ImageOp.none;
    _xfMoved = false;
  }

  /// 繪製時發現圖片還沒解碼 → 背景載入，完成後只重繪畫布
  void requestImage(PageImage img) {
    if (img.image != null || img.loading || img.missing) return;
    unawaited(
      PageImageStore.ensureLoaded(img).then((_) {
        if (!_disposed) viewSignal.fire();
      }),
    );
  }

  /// 加入使用者挑選的圖片：放在目前畫面可見範圍的中央、選取它，進入可編輯狀態。
  /// 圖片無法解碼時回傳 false。
  /// [at] (目前頁的頁面座標) 有給就以該點為中心 (貼上用)，也不再切換頁面。
  Future<bool> addImageFromBytes(Uint8List bytes, {Offset? at}) async {
    if (at == null) syncCurrentToFocus(); // 連續模式：加到畫面上看到的那一頁
    final page = currentPage;

    final imported = await PageImageStore.importBytes(bytes);
    if (imported == null) return false;
    if (_disposed || !pages.contains(page)) {
      imported.image.dispose(); // 等待期間頁面已被刪掉 / 控制器已銷毀
      return false;
    }

    final isCurrent = identical(page, currentPage);
    final pageRect = Rect.fromLTWH(0, 0, page.width, page.height);
    final iw = imported.image.width.toDouble();
    final ih = imported.image.height.toDouble();
    // 最大佔紙張 60%，不放大小圖
    final s = min(1.0, min(page.width * 0.6 / iw, page.height * 0.6 / ih));
    final w = iw * s, h = ih * s;

    Offset center = at ?? pageRect.center;
    if (at == null && isCurrent && !viewportSize.isEmpty) {
      final vis = viewSceneRect.shift(-currentPageOrigin).intersect(pageRect);
      if (vis.width > 0 && vis.height > 0) center = vis.center;
    }
    var rect = Rect.fromCenter(center: center, width: w, height: h);
    double dx = 0, dy = 0;
    if (rect.left < 0) {
      dx = -rect.left;
    } else if (rect.right > page.width) {
      dx = page.width - rect.right;
    }
    if (rect.top < 0) {
      dy = -rect.top;
    } else if (rect.bottom > page.height) {
      dy = page.height - rect.bottom;
    }
    rect = rect.shift(Offset(dx, dy));

    final img = PageImage(
      id: PageImageStore.newId(),
      fileName: imported.fileName,
      rect: rect,
      image: imported.image,
    );
    page.images.add(img);
    (isCurrent ? _undoStack : page.undoStack).add(AddImageCommand(page.images, img));
    (isCurrent ? _redoStack : page.redoStack).clear();
    _markDirty();

    if (isCurrent) {
      setTool(DrawingTool.image); // 會清掉舊選取，所以選取要放後面
      _selectedImage = img;
    }
    notifyListeners();
    return true;
  }

  // ==========================================
  // ★ 防誤觸 (Palm rejection)
  //   開啟後：手指 (touch) 不能畫 / 擦 / 套索 / 操作圖片，
  //   單指 = 平移畫面、雙指 = 縮放平移 (含雙指輕點復原) 照常；
  //   筆 (stylus) 與滑鼠照常使用。筆一落下，已按著的手指 (手掌) 立刻忽略。
  // ==========================================
  bool palmRejection = false;
  final Set<int> _touchIds = {}; // 防誤觸模式下，正在畫面上的手指
  final Set<int> _penIds = {}; // 防誤觸模式下，正在畫面上的筆 / 滑鼠
  final Set<int> _ignoredPointers = {}; // 被判定為手掌、整段都忽略的手指
  bool _isTouchPanning = false;
  Offset _touchPanLast = Offset.zero;

  // 圖片工具：手指按在「不是圖片」的地方 → 單指平移畫布
  bool _isImagePanning = false;
  double _imagePanTotal = 0.0; // 累計平移的螢幕距離 (超過點擊容許範圍就不算「點一下取消選取」)

  /// 平移 / 慣性滑動 / 滾輪捲動時也顯示目前縮放比例的膠囊 (各種工具模式都一樣)。
  /// 倍率沒變，所以只有「剛要出現」(或正顯示文字訊息) 時才需要整頁重建一次；
  /// 計時器先取消，等手指離開 / 滑動結束後再淡出。
  void _showZoomIndicatorWhilePanning() {
    final bool needsRebuild = !showZoomIndicator || hudMessage != null;
    hudMessage = null; // 平移時顯示倍率，不顯示殘留的文字訊息
    showZoomIndicator = true;
    _zoomIndicatorTimer?.cancel();
    if (needsRebuild && !_disposed) notifyListeners();
  }

  void _panViewBy(Offset delta) {
    transformation =
        Matrix4.translationValues(delta.dx, delta.dy, 0.0) * transformation;
    _viewMoving = true;
    if (isContinuous) _syncVisiblePages();
    _showZoomIndicatorWhilePanning();
    viewSignal.fire();
  }

  // ==========================================
  // 按住自動完美形狀：畫到一半停住不放 (約 0.6 秒) → 直線 / 圓 / 橢圓 / 矩形 / 多邊形
  // 變好之後手指繼續拖曳可以調整：起點固定，控制點跟著手指
  // (直線 / 曲線 = 終點；折線 = 只調最後一段；圓 / 橢圓 = 以中心縮放旋轉、手指留在圓周上；
  //  矩形 / 三角形 = 起點穿過中心的對面那一點)，放開即完成。
  // 直線 / 曲線 / 折線的起點會吸附到最近的其他筆跡。
  // ==========================================
  static const Duration _shapeHoldDelay = Duration(milliseconds: 600);
  static const double _shapeHoldSlopScreen = 6.0; // 手指抖動容許範圍 (螢幕 px)
  Timer? _shapeHoldTimer;
  Offset _shapeHoldAnchor = Offset.zero;
  bool _shapeSnapped = false;
  ShapeKind? _shapeKind;
  List<Pt> _shapeOutline0 = const []; // 剛辨識好的輪廓 (調整時都以它為基準)
  List<Pt>? _shapeVertices; // 折線的頂點 (只有折線需要)
  Pt? _shapeEndSnapTarget; // 拖曳中終點目前吸附到的筆跡點
  Pt _shapePivot = const Pt(0, 0); // 起點 (固定不動)
  Pt _shapeH0 = const Pt(0, 0); // 控制點原本的位置
  Pt _shapeP0 = const Pt(0, 0); // 變形當下手指的位置 (頁面座標)
  Offset _shapeP0Screen = Offset.zero; // 同上 (螢幕座標)

  double get _shapeStep => max(2.0, brush.size * 0.4);

  void _shapeHoldStart(Offset screenPos) {
    _resetShapeState();
    if (!brush.shapeSnap) return;
    _shapeHoldAnchor = screenPos;
    _shapeHoldTimer = Timer(_shapeHoldDelay, _trySnapShape);
  }

  /// 手指真的移動了 (超過抖動範圍) → 重新計時
  void _shapeHoldMoved(Offset screenPos) {
    if (_shapeSnapped || _shapeHoldTimer == null) return;
    if ((screenPos - _shapeHoldAnchor).distance > _shapeHoldSlopScreen) {
      _shapeHoldAnchor = screenPos;
      _shapeHoldTimer!.cancel();
      _shapeHoldTimer = Timer(_shapeHoldDelay, _trySnapShape);
    }
  }

  void _resetShapeState() {
    _shapeHoldTimer?.cancel();
    _shapeHoldTimer = null;
    _shapeSnapped = false;
    _shapeKind = null;
    _shapeOutline0 = const [];
    _shapeVertices = null;
    _shapeEndSnapTarget = null;
  }

  void _trySnapShape() {
    _shapeHoldTimer = null;
    if (_disposed || _shapeSnapped) return;
    if (!_isInkTool || _currentPoints.length < 3) return;
    if (_isScalingLocked || _gestureCancelled || _pointerPositions.length != 1) {
      return;
    }
    final z = zoomPercentage / 100;
    final raw = [for (final p in _currentPoints) Pt(p.x, p.y)];
    final result = ShapeRecognizer.recognize(
      raw,
      minLength: 24 / z, // 至少 24 螢幕像素長才辨識
      step: _shapeStep,
    );
    if (result == null) return; // 辨識不出來就維持原本的筆跡

    // 直線 / 曲線 / 折線：起點吸附到最近的其他筆跡 (約 16 螢幕像素內)
    var res = result;
    if (!res.closed && brush.strokeSnap) {
      final q = _nearestOtherStrokePoint(raw.first, 16 / z);
      if (q != null) res = ShapeRecognizer.moveStart(res, q, _shapeStep);
    }

    _currentPoints
      ..clear()
      ..addAll([for (final q in res.outline) PointVector(q.x, q.y, 0.5)]);
    _shapeSnapped = true;
    _shapeKind = res.kind;
    _shapeOutline0 = res.outline;
    _shapeVertices = res.vertices;
    _shapeP0 = raw.last;
    _shapeP0Screen = _pointerPositions.values.first;

    final outline = res.outline;
    if (!res.closed) {
      // 開放形狀：起點固定 (可能已吸附)，控制點 = 終點
      _shapePivot = outline.first;
      _shapeH0 = outline.last;
    } else if (res.kind == ShapeKind.ellipse && res.center != null) {
      // 圓 / 橢圓：以中心縮放 + 旋轉，控制點 = 手指所在的那個圓周點 (調整後手指仍在圓周上)
      _shapePivot = res.center!;
      var best = outline.first;
      for (final q in outline) {
        if (q.dist(_shapeP0) < best.dist(_shapeP0)) best = q;
      }
      _shapeH0 = best;
    } else if (res.kind == ShapeKind.rectangle &&
        res.vertices != null &&
        res.vertices!.length == 4) {
      // 矩形：控制點 = 離手指最近的角，固定點 = 它的對角；寬高可以分開縮放
      final vs = res.vertices!;
      var bi = 0;
      for (int i = 1; i < 4; i++) {
        if (vs[i].dist(_shapeP0) < vs[bi].dist(_shapeP0)) bi = i;
      }
      _shapeH0 = vs[bi];
      _shapePivot = vs[(bi + 2) % 4];
    } else if (res.kind == ShapeKind.polygon &&
        res.vertices != null &&
        res.vertices!.length == 3) {
      // 三角形：控制點 = 離手指最近的頂點，對邊固定；頂點可以自由移動
      final vs = res.vertices!;
      var bi = 0;
      for (int i = 1; i < 3; i++) {
        if (vs[i].dist(_shapeP0) < vs[bi].dist(_shapeP0)) bi = i;
      }
      _shapeH0 = vs[bi];
      _shapePivot = Pt(
        (vs[(bi + 1) % 3].x + vs[(bi + 2) % 3].x) / 2,
        (vs[(bi + 1) % 3].y + vs[(bi + 2) % 3].y) / 2,
      ); // 對邊中點 (三角形調整時不會用到)
    } else {
      // 四邊形 / 五、六邊形：以中心 (頂點平均) 縮放 + 旋轉，
      // 控制點 = 手指所在的輪廓點 (調整後手指仍然在輪廓上，和圓 / 橢圓一致)
      final cp = (res.vertices != null && res.vertices!.length >= 3)
          ? res.vertices!
          : outline.sublist(0, outline.length - 1);
      double cx = 0, cy = 0;
      for (final q in cp) {
        cx += q.x;
        cy += q.y;
      }
      _shapePivot = Pt(cx / cp.length, cy / cp.length);
      // 輪廓點很稀疏，改成「線段上離手指最近的投影點」，手指一開始就貼在邊上
      Pt best = outline.first;
      double bestD = double.infinity;
      for (int k = 0; k + 1 < outline.length; k++) {
        final a = outline[k], b = outline[k + 1];
        final abx = b.x - a.x, aby = b.y - a.y;
        final l2 = abx * abx + aby * aby;
        final t = l2 < 1e-12
            ? 0.0
            : (((_shapeP0.x - a.x) * abx + (_shapeP0.y - a.y) * aby) / l2)
                .clamp(0.0, 1.0)
                .toDouble();
        final q = Pt(a.x + abx * t, a.y + aby * t);
        final d = q.dist(_shapeP0);
        if (d < bestD) {
          bestD = d;
          best = q;
        }
      }
      _shapeH0 = best;
      if ((_shapeH0 - _shapePivot).length < 1e-6) {
        _shapeH0 = outline[outline.length ~/ 2];
      }
    }
    activeRepaintNotifier.notifyListeners();
  }

  /// 其他 (已完成的) 筆跡上離 [p] 最近的點 (線段上的投影點)；超過 [maxDist] 回傳 null
  Pt? _nearestOtherStrokePoint(Pt p, double maxDist) {
    Pt? best;
    double bestD = maxDist;
    for (final st in _historyStrokes) {
      final pts = st.points;
      if (pts.isEmpty) continue;
      final bb = st.bounds.inflate(maxDist + st.settings.size);
      if (p.x < bb.left || p.x > bb.right || p.y < bb.top || p.y > bb.bottom) {
        continue;
      }
      for (int i = 0; i < pts.length; i++) {
        final a = pts[i];
        double qx = a.x, qy = a.y;
        if (i + 1 < pts.length) {
          final b = pts[i + 1];
          final abx = b.x - a.x, aby = b.y - a.y;
          final l2 = abx * abx + aby * aby;
          if (l2 > 1e-12) {
            final t = (((p.x - a.x) * abx + (p.y - a.y) * aby) / l2)
                .clamp(0.0, 1.0)
                .toDouble();
            qx = a.x + abx * t;
            qy = a.y + aby * t;
          }
        }
        final d = sqrt((p.x - qx) * (p.x - qx) + (p.y - qy) * (p.y - qy));
        if (d < bestD) {
          bestD = d;
          best = Pt(qx, qy);
        }
      }
    }
    return best;
  }

  /// 變形之後手指繼續移動：以起點為中心，讓控制點跟著手指縮放 / 旋轉
  void _shapeAdjust(Offset scenePoint, Offset screenPoint) {
    final kind = _shapeKind;
    if (kind == null) return;
    // 手指離開變形當下的位置不到 4 螢幕像素：不動，避免筆尖抖動破壞剛整理好的形狀
    if ((screenPoint - _shapeP0Screen).distance < 4.0) return;
    var h = _shapeH0 + (Pt(scenePoint.dx, scenePoint.dy) - _shapeP0);
    // 直線 / 曲線 / 折線：拖曳中的終點靠近其他筆跡就吸附上去
    bool snappedToStroke = false;
    if (brush.strokeSnap &&
        (kind == ShapeKind.line ||
            kind == ShapeKind.curve ||
            kind == ShapeKind.polyline)) {
      final q = _nearestOtherStrokePoint(h, 16 / (zoomPercentage / 100));
      if (q != null) {
        snappedToStroke = true;
        if (_shapeEndSnapTarget == null || _shapeEndSnapTarget!.dist(q) > 0.5) {
        }
        h = q;
      }
      _shapeEndSnapTarget = q;
    }
    final pts = ShapeRecognizer.adjust(
      kind: kind,
      outline0: _shapeOutline0,
      pivot: _shapePivot,
      h0: _shapeH0,
      h: h,
      step: _shapeStep,
      vertices: _shapeVertices,
      angleSnap: !snappedToStroke,
    );
    _currentPoints
      ..clear()
      ..addAll([for (final q in pts) PointVector(q.x, q.y, 0.5)]);
    activeRepaintNotifier.notifyListeners();
  }

  // ==========================================
  // 平移：軸向鎖定 + 放手後的慣性滑動
  // ==========================================
  static const double _axisLockEnterDeg = 15.0; // 與水平 / 鉛直夾角小於此值 → 鎖單軸
  static const double _axisLockExitDeg = 28.0; // 夾角超過此值 → 解除鎖定 (遲滯，避免抖動)
  static const double _flingTau = 0.38; // 速度衰減時間常數 (秒)；越大滑越遠
  static const double _flingMinStart = 150.0; // 放手速度低於此值 (px/s) 不滑
  static const double _flingMinSpeed = 25.0; // 滑動中速度低於此值就停
  static const double _flingMaxSpeed = 7000.0;

  final Stopwatch _panClock = Stopwatch()..start();
  final List<_PanSample> _panSamples = [];
  Offset _panDir = Offset.zero; // 衰減累計的原始移動方向
  int _panAxis = 0; // 0 = 自由, 1 = 只動 x, 2 = 只動 y
  bool _pinchZoomed = false; // 雙指手勢中真的有縮放 (縮放過就不慣性滑動)
  Offset? _pendingPinchFling; // 雙指其中一指離開時就算好的平移速度
  int _pendingPinchFlingAt = 0;

  // 雙指意圖判斷：把兩指的移動拆成「一起動 (平移)」和「沿兩指連線相向 / 相背 (縮放)」，
  // 各自做衰減累計，只看最近一小段時間，所以不會被一開始的動作綁住。
  Offset? _intentPrev0, _intentPrev1;
  Offset _intentAcc0 = Offset.zero, _intentAcc1 = Offset.zero;
  static const double _intentDecay = 0.9; // 每個 move 事件衰減，約看最近 10 個事件
  static const double _zoomOverPanRatio = 0.6; // 縮放分量要大於平移分量的這個倍數才算想縮放

  void _resetPinchIntent() {
    _intentPrev0 = null;
    _intentPrev1 = null;
    _intentAcc0 = Offset.zero;
    _intentAcc1 = Offset.zero;
  }

  /// 更新並回傳「最近是不是縮放分量夠大」。平移時兩指間距容易小幅漂移，
  /// 這個判斷用來避免把平移誤認成縮放。
  bool _updatePinchIntent(Offset p0, Offset p1) {
    final a = _intentPrev0, b = _intentPrev1;
    if (a != null && b != null) {
      _intentAcc0 = _intentAcc0 * _intentDecay + (p0 - a);
      _intentAcc1 = _intentAcc1 * _intentDecay + (p1 - b);
    }
    _intentPrev0 = p0;
    _intentPrev1 = p1;
    final axis = p1 - p0;
    final len = axis.distance;
    if (len < 1e-6) return false;
    final u = axis / len;
    final pan = ((_intentAcc0 + _intentAcc1) / 2).distance;
    final zoomVec = (_intentAcc1 - _intentAcc0) / 2;
    final zoom = (zoomVec.dx * u.dx + zoomVec.dy * u.dy).abs();
    return zoom > pan * _zoomOverPanRatio;
  }

  bool _flinging = false;
  bool _flingStepping = false;
  Offset _flingVelocity = Offset.zero;
  Duration? _flingLastStamp;

  void _resetPanTracking() {
    _panSamples.clear();
    _panDir = Offset.zero;
    _panAxis = 0;
  }

  /// 接近水平 / 鉛直的拖動只保留主軸分量；回傳實際要套用的位移
  Offset _applyAxisLock(Offset raw) {
    if (raw == Offset.zero) return raw;
    _panDir = _panDir * 0.85 + raw;
    if (_panDir.distance < 4.0) return raw; // 方向還不明確
    final ax = _panDir.dx.abs(), ay = _panDir.dy.abs();
    final deg = atan2(min(ax, ay), max(ax, ay)) * 180 / pi; // 離最近軸的夾角
    final dominant = ax >= ay ? 1 : 2;
    if (_panAxis == 0) {
      if (deg <= _axisLockEnterDeg) _panAxis = dominant;
    } else if (deg > _axisLockExitDeg || _panAxis != dominant) {
      _panAxis = deg <= _axisLockEnterDeg ? dominant : 0;
    }
    switch (_panAxis) {
      case 1:
        return Offset(raw.dx, 0);
      case 2:
        return Offset(0, raw.dy);
      default:
        return raw;
    }
  }

  void _recordPanSample(Offset applied) {
    final now = _panClock.elapsedMilliseconds;
    _panSamples.add(_PanSample(now, applied));
    while (_panSamples.isNotEmpty && now - _panSamples.first.t > 150) {
      _panSamples.removeAt(0);
    }
  }

  /// 以最近 ~100ms 的移動算放手速度 (px/s)；停頓過 / 太慢 → null
  Offset? _panReleaseVelocity() {
    final now = _panClock.elapsedMilliseconds;
    final recent = _panSamples.where((s) => now - s.t <= 100).toList();
    if (recent.length < 2) return null;
    if (now - recent.last.t > 60) return null; // 手指停住後才放開
    final span = recent.last.t - recent.first.t;
    if (span < 8) return null;
    var sum = Offset.zero;
    for (int i = 1; i < recent.length; i++) {
      sum += recent[i].delta;
    }
    var v = sum * (1000.0 / span);
    final speed = v.distance;
    if (speed < _flingMinStart) return null;
    if (speed > _flingMaxSpeed) v = v * (_flingMaxSpeed / speed);
    return v;
  }

  void _startFling(Offset velocity) {
    _flinging = true;
    _flingVelocity = velocity;
    _flingLastStamp = null;
    _viewMoving = true; // 滑動期間維持「互動中」(筆劃用點陣快取)
    SchedulerBinding.instance.scheduleFrameCallback(_onFlingFrame);
  }

  void _onFlingFrame(Duration stamp) {
    if (!_flinging || _disposed) return;
    final last = _flingLastStamp;
    _flingLastStamp = stamp;
    if (last != null) {
      final dt = ((stamp - last).inMicroseconds / 1e6).clamp(0.0, 0.05);
      final decay = exp(-dt / _flingTau);
      final delta = _flingVelocity * (_flingTau * (1 - decay));
      _flingVelocity = _flingVelocity * decay;
      _flingStepping = true;
      _panViewBy(delta);
      _flingStepping = false;
      if (_flingVelocity.distance < _flingMinSpeed) {
        _stopFling(refresh: true);
        return;
      }
    }
    SchedulerBinding.instance.scheduleFrameCallback(_onFlingFrame);
  }

  /// 停止慣性滑動。refresh = true：補上高清渲染並讓筆劃切回向量
  void _stopFling({bool refresh = false}) {
    if (!_flinging) return;
    _flinging = false;
    _flingVelocity = Offset.zero;
    _flingLastStamp = null;
    _viewMoving = false;
    _scheduleRasterRelease();
    if (showZoomIndicator && hudMessage == null) _startZoomIndicatorFadeout();
    if (refresh && !_disposed) {
      refreshDetail();
      viewSignal.fire();
      notifyListeners();
    }
  }

  void setPalmRejection(bool value) {
    if (palmRejection == value) return;
    palmRejection = value;
    _touchIds.clear();
    _penIds.clear();
    _ignoredPointers.clear();
    _isTouchPanning = false;
    _cancelActiveGesture();
    _schedulePrefsSave();
    _showHudMessage(
      value ? S.current.palmRejectionOn : S.current.palmRejectionOff,
      icon: Icons.pan_tool_alt_outlined,
    );
  }

  void togglePalmRejection() => setPalmRejection(!palmRejection);

  /// 手勢 (雙指輕點 = 復原、三指輕點 = 重做) 開關；縮放 / 平移不受影響
  bool gesturesEnabled = true;

  void setGesturesEnabled(bool value) {
    if (gesturesEnabled == value) return;
    gesturesEnabled = value;
    _twoFingerTapCandidate = false;
    _threeFingerTapCandidate = false;
    _schedulePrefsSave();
    _showHudMessage(
      value ? S.current.gesturesOn : S.current.gesturesOff,
      icon: Icons.touch_app_outlined,
    );
    notifyListeners();
  }

  /// 截圖解析度 (每個頁面單位的像素數)；0 = 自動
  double screenshotScale = 0;

  void setScreenshotScale(double value) {
    if (screenshotScale == value) return;
    screenshotScale = value;
    _schedulePrefsSave();
    notifyListeners();
  }

  /// 防誤觸：筆落下時，已經按在畫面上的手指一律當成手掌丟掉
  void _dropTouchesForPen() {
    if (_touchIds.isEmpty) return;
    for (final id in _touchIds) {
      _pointerPositions.remove(id);
      _ignoredPointers.add(id);
    }
    _touchIds.clear();
    _isTouchPanning = false;
    // 套索：手掌 (手指) 造成的平移 / 長按作廢；拖曳到一半的就收尾
    _isLassoPanning = false;
    _lassoPanMoved = false;
    _lassoLongPressTimer?.cancel();
    _isPotentialNewLasso = false;
    if (_isDraggingSelection) {
      if (_selectionDragStarted) _pushSelectionMoveCommand();
      _isDraggingSelection = false;
      _selectionDragStarted = false;
    }
    _twoFingerTapCandidate = false;
    _threeFingerTapCandidate = false;
    _previousDistance = 0.0;
    if (_isScalingLocked) {
      _isScalingLocked = false;
      _viewMoving = false;
      refreshDetail();
      _scheduleRasterRelease();
    }
  }

  // ==========================================
  // ★ 清除當前頁面：所有筆跡與圖片 (背景 / PDF 保留)，一次 Undo 可還原
  // ==========================================
  /// 回傳 false = 本來就沒有內容
  bool clearCurrentPageContent() {
    final cmds = <CanvasCommand>[];

    if (_historyStrokes.isNotEmpty) {
      // 由後往前移除並記錄索引，還原時 (反向重放) 就會依原順序放回
      final removed = <MapEntry<int, Stroke>>[
        for (int i = _historyStrokes.length - 1; i >= 0; i--)
          MapEntry(i, _historyStrokes[i]),
      ];
      _historyStrokes.clear();
      cmds.add(EraseStrokesCommand(removed));
    }

    final list = currentPage.images;
    for (int i = list.length - 1; i >= 0; i--) {
      cmds.add(RemoveImageCommand(list, list[i], i));
    }
    list.clear();

    if (cmds.isEmpty) {
      _showHudMessage(S.current.pageAlreadyEmpty, icon: Icons.info_outline);
      return false;
    }

    // 進行到一半的筆劃 / 選取一併丟掉
    _currentPoints.clear();
    clearSelection();

    _undoStack.add(cmds.length == 1 ? cmds.first : CompositeCommand(cmds));
    _redoStack.clear();
    _markDirty();
    _bakeHistoryToPicture();
    activeRepaintNotifier.notifyListeners();
    _showHudMessage(S.current.pageCleared, icon: Icons.cleaning_services_outlined);
    return true;
  }

  // 1. 手指落下
  void onPointerDown(
    int pointerId,
    Offset position,
    double pressure, {
    PointerDeviceKind kind = PointerDeviceKind.stylus,
  }) {
    if (_flinging) {
      _stopFling();
      refreshDetail();
      viewSignal.fire();
    }
    _resetPanTracking();
    if (_pointerPositions.isEmpty) _firstFingerDownTime = DateTime.now();
    // 圖片工具：手指也能移動 / 縮放圖片，不套用防誤觸
    if (palmRejection && currentTool != DrawingTool.image) {
      if (kind == PointerDeviceKind.touch) {
        // 筆正在畫面上 → 這根手指是手掌，整段忽略
        if (_penIds.isNotEmpty) {
          _ignoredPointers.add(pointerId);
          return;
        }
        _touchIds.add(pointerId);
        if (_touchIds.length == 1) {
          _pointerPositions[pointerId] = position;
          _gestureCancelled = false;
          if (currentTool != DrawingTool.lasso) {
            // 單指：只平移，不畫也不選取
            _isTouchPanning = true;
            _touchPanLast = position;
            lassoMenu = LassoMenuKind.none;
            _startPasteHold(position); // 手指按著不動 → 貼上選單
            return;
          }
          // 套索：手指不能畫圈，但圈內可拖曳 / 點一下開選單，
          // 圈外平移畫布、點一下取消選取、長按貼上 → 走下面的套索流程
        } else {
          // 第二根手指：停止單指平移，交給下面的雙指縮放流程
          _isTouchPanning = false;
        }
      } else {
        _dropTouchesForPen();
        _penIds.add(pointerId);
      }
    }

    _pointerPositions[pointerId] = position;
    if (_pointerPositions.length == 1) _gestureCancelled = false;

    if (_pointerPositions.length >= 2) {
      _isScalingLocked = true;
      _currentPoints.clear();
      _currentLassoDrawing.clear();
      _isPotentialNewLasso = false;
      _lassoLongPressTimer?.cancel();
      _pasteHoldTimer?.cancel();
      _isLassoPanning = false;
      _lassoPanMoved = false;
      if (_isDraggingSelection) {
        // 拖曳到一半被第二根手指打斷：已經移動的部分照樣記一筆
        if (_selectionDragStarted) _pushSelectionMoveCommand();
        _isDraggingSelection = false;
        _selectionDragStarted = false;
      }
      lassoMenu = LassoMenuKind.none; // 縮放 / 平移時選單位置會失準，直接收起
      _isImagePanning = false;
      _suspendImageOp();
      eraserPosition = null;
      _lastEraseScenePoint = null;

      // ★ 雙指輕點判定開始：記錄初始狀態、時間與座標
      if (_pointerPositions.length == 2) {
        // 雙指輕點 = 兩指幾乎同時按下、又很快一起抬起；
        // 第一指先按住、隔一段時間才按第二指，只是要平移 / 縮放，不算輕點
        final nowDown = DateTime.now();
        final firstDown = _firstFingerDownTime;
        _twoFingerTapCandidate =
            gesturesEnabled &&
            firstDown != null &&
            nowDown.difference(firstDown).inMilliseconds <=
                _twoFingerTapMaxGapMs;
        _twoFingerDownTime = nowDown;
        final pts = _pointerPositions.values.toList();
        _finger1Initial = pts[0];
        _finger2Initial = pts[1];
        _initialTwoFingerDistance = (pts[0] - pts[1]).distance;
        _matrixBeforeGesture = transformation.clone();
        _pinchZoomed = false;
        _pendingPinchFling = null;
        _resetPinchIntent();
        _threeFingerTapCandidate = false;
      } else {
        _twoFingerTapCandidate = false;
        _pinchZoomed = true; // 三指以上不做慣性
        _threeFingerSession = true; // 三指以上：不縮放、不平移
        if (_pointerPositions.length == 3) {
          final nowDown = DateTime.now();
          final firstDown = _firstFingerDownTime;
          _threeFingerTapCandidate =
              gesturesEnabled &&
              firstDown != null &&
              nowDown.difference(firstDown).inMilliseconds <=
                  _threeFingerTapMaxGapMs;
          _threeFingerDownTime = nowDown;
          _threeFingerInitial = _pointerPositions.values.toList();
          // 第三指落下前，雙指階段可能已經讓畫面縮放 / 平移了一點：
          // 立刻還原到手勢開始前，三指期間畫面就不會動
          if (_threeFingerTapCandidate && _matrixBeforeGesture != null) {
            transformation = _matrixBeforeGesture!;
            viewSignal.fire();
          }
        } else {
          _threeFingerTapCandidate = false; // 四指以上不處理
        }
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
      // 圖片模式：點在已選取圖片的框 / 握把上 (可能超出紙張) 時不要切換頁面
      if (isContinuous && !_pointerHitsSelectedImage(position)) {
        _activatePageAt(position);
      }
      final scenePoint = toScene(position);
      _pasteHoldTimer?.cancel();
      lassoMenu = LassoMenuKind.none; // 任何新的觸碰都先收起選單

      if (_isInkTool) {
        _smoothedPressure = pressure;
        _currentPoints.add(PointVector(scenePoint.dx, scenePoint.dy, pressure));
        _shapeHoldStart(position);
        _startPasteHold(position);
        activeRepaintNotifier.notifyListeners();
        return;
      } else if (currentTool == DrawingTool.eraser) {
        // ★ 記錄位置以繪製感應圓圈
        eraserPosition = scenePoint;
        _lastEraseScenePoint = scenePoint;
        _eraseAlongSegment(scenePoint, scenePoint);
        if (_currentErasedBatch.isEmpty) _startPasteHold(position); // 沒擦到東西才算空白處
        activeRepaintNotifier.notifyListeners();
        return;
      } else if (currentTool == DrawingTool.lasso) {
        lassoMenu = LassoMenuKind.none; // 任何新的觸碰都先收起選單
        _lassoDownScreen = position;
        if (selectionTransformMode && _xfDown(scenePoint, position)) {
          // 調整大小模式：按到外框 / 握把，已開始操作
        } else if (!selectionTransformMode &&
            _selectedLassoPolygon.isNotEmpty &&
            RayCasting.isPointInPolygon(scenePoint, _selectedLassoPolygon)) {
          _isDraggingSelection = true;
          _selectionDragStarted = false;
          _lastDragPosition = scenePoint;
          _totalDragDelta = Offset.zero;
        } else {
          _isPotentialNewLasso = true;
          _potentialLassoStart = scenePoint;
          _startLassoLongPress();
          // 防誤觸下的手指：圈外 = 平移畫布 (套索的圈圈只能用 Pencil 畫)
          if (palmRejection && kind == PointerDeviceKind.touch) {
            _isLassoPanning = true;
            _lassoPanMoved = false;
            _touchPanLast = position;
          }
        }
      } else if (currentTool == DrawingTool.image) {
        lassoMenu = LassoMenuKind.none; // 任何新的觸碰都先收起選單
        _imageDownScreen = position;
        _imageDown(scenePoint);
        // 手指按在空白處 (沒碰到圖片 / 握把) → 單指平移畫布
        _isImagePanning = kind == PointerDeviceKind.touch &&
            _imageOp == _ImageOp.none &&
            _imageCandidate == null;
        if (_isImagePanning) {
          _touchPanLast = position;
          _imagePanTotal = 0.0;
        }
        // 按在空白處 (沒碰到圖片 / 握把) → 長按浮出貼上選單
        if (_imageOp == _ImageOp.none && _imageCandidate == null) {
          _startPasteHold(position);
        }
      }
    }
    notifyListeners();
  }

  // 2. 移動中
  void onPointerMove(int pointerId, Offset position, double pressure) {
    if (_ignoredPointers.contains(pointerId)) return;

    // 防誤觸：單指平移
    if (_isTouchPanning &&
        _touchIds.contains(pointerId) &&
        _pointerPositions.length == 1) {
      _pointerPositions[pointerId] = position;
      final raw = position - _touchPanLast;
      _touchPanLast = position;
      if (raw == Offset.zero) return;
      final delta = _applyAxisLock(raw);
      _recordPanSample(delta);
      if (delta != Offset.zero) _panViewBy(delta);
      return;
    }

    _pointerPositions[pointerId] = position;

    if (_isScalingLocked && _pointerPositions.length < 2) return;
    if (_gestureCancelled && _pointerPositions.length < 2) return;

    if (!_isScalingLocked && _pointerPositions.length == 1) {
      final scenePoint = toScene(position);

      if (_isInkTool) {
        if (_currentPoints.isEmpty) return;

        // 已經變成完美形狀：手指拖曳 = 調整形狀 (起點固定)
        if (_shapeSnapped) {
          _shapeAdjust(scenePoint, position);
          return;
        }
        _shapeHoldMoved(position);

        // ★ 解決第 3 點：直接記錄真實座標！絕對不強制 clamp 拉回邊緣！
        // 過濾抖動：和上一點相距不到 0.5 螢幕像素就略過 (放大後慢慢移動時，
        // 感測器雜訊會讓輪廓出現尖刺)。門檻用螢幕像素換算，所以任何縮放都一致。
        final last = _currentPoints.last;
        final minStep = 0.5 / (zoomPercentage / 100);
        final dx = scenePoint.dx - last.x;
        final dy = scenePoint.dy - last.y;
        if (dx * dx + dy * dy < minStep * minStep) return;
        // 壓力做輕度平滑，粗細才不會忽粗忽細
        _smoothedPressure += (pressure - _smoothedPressure) * 0.5;
        _currentPoints.add(
          PointVector(scenePoint.dx, scenePoint.dy, _smoothedPressure),
        );
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
        if (_xfOp != _ImageOp.none) {
          _xfMove(scenePoint, position);
          return;
        }
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
          for (final img in _selectedImages) {
            img.rect = img.rect.shift(delta);
          }
          for (int i = 0; i < _selectedLassoPolygon.length; i++) {
            _selectedLassoPolygon[i] = _selectedLassoPolygon[i] + delta;
          }
          if (_selectedStrokes.isNotEmpty) _bakeHistoryToPicture();
        } else if (_isLassoPanning) {
          // 手指在容許範圍內微動仍算「按住」(長按貼上 / 點一下取消選取)
          if (!_lassoPanMoved) {
            if ((position - _lassoDownScreen).distance < _tapSlop) return;
            _lassoPanMoved = true;
            _lassoLongPressTimer?.cancel();
            _isPotentialNewLasso = false; // 拖動了 → 不是「點一下取消選取」
          }
          final raw = position - _touchPanLast;
          _touchPanLast = position;
          if (raw != Offset.zero) {
            final delta = _applyAxisLock(raw);
            _recordPanSample(delta);
            if (delta != Offset.zero) _panViewBy(delta);
          }
          return;
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
      } else if (currentTool == DrawingTool.image) {
        if (_isImagePanning) {
          final raw = position - _touchPanLast;
          _touchPanLast = position;
          _imagePanTotal += raw.distance;
          // 拖動 = 不是「點空白處取消選取」
          if (_imagePanTotal >= _tapSlop) _imageDeselectPending = false;
          if (raw != Offset.zero) {
            final delta = _applyAxisLock(raw);
            _recordPanSample(delta);
            if (delta != Offset.zero) _panViewBy(delta);
          }
          return;
        }
        _imageMove(scenePoint); // 只重繪畫布，不重建整頁
        return;
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
      if (_threeFingerTapCandidate) {
        if (points.length != _threeFingerInitial.length) {
          _threeFingerTapCandidate = false;
        } else {
          for (int i = 0; i < points.length; i++) {
            if ((points[i] - _threeFingerInitial[i]).distance >
                _threeFingerTapSlop) {
              _threeFingerTapCandidate = false;
              break;
            }
          }
        }
      }
      // 三指不縮放也不平移；另外兩指剛落下的前 _threeFingerTapMaxGapMs 毫秒
      // 還可能有第三指跟上，先不動畫面 (只更新基準，避免第三指落下時畫面已被拉動)
      final firstDown = _firstFingerDownTime;
      final bool inThreeFingerWindow =
          _pointerPositions.length == 2 &&
          firstDown != null &&
          DateTime.now().difference(firstDown).inMilliseconds <
              _threeFingerTapMaxGapMs;
      if (_threeFingerSession || inThreeFingerWindow) {
        _previousDistance = currentDistance;
        _previousMidpoint = currentMidpoint;
        return;
      }
      if (_previousDistance > 0 && currentDistance > 0) {
        final double rawScaleFactor = currentDistance / _previousDistance;
        final Offset rawTranslation = currentMidpoint - _previousMidpoint;

        // 雙指「平移優先」：兩指間距要明顯變化 (至少 16px 且超過起始間距的 12%)
        // 才算要縮放，這之後才加入縮放 (不鎖軸、放手也不慣性滑動)；
        // 在那之前只平移，間距的小幅變化一律忽略。
        // 同時要「最近的動作以相向 / 相背為主」(不是兩指一起滑)，平移時間距的漂移不算
        final bool zoomIntent = _updatePinchIntent(points[0], points[1]);
        if (!_pinchZoomed &&
            zoomIntent &&
            (currentDistance - _initialTwoFingerDistance).abs() >
                max(16.0, _initialTwoFingerDistance * 0.12)) {
          _pinchZoomed = true;
          _panSamples.clear();
        }
        // 純平移：接近水平 / 鉛直就只動單軸，並記錄速度供放手後慣性滑動
        Offset deltaTranslation = rawTranslation;
        if (!_pinchZoomed) {
          deltaTranslation = _applyAxisLock(rawTranslation);
          _recordPanSample(deltaTranslation);
        }

        // 1. 計算目前的實際 2D 縮放倍率
        final double currentScale = sqrt(
          transformation.storage[0] * transformation.storage[0] +
              transformation.storage[1] * transformation.storage[1],
        );

        // 2. ★ 核心限制運算：預測下一刻的縮放倍率，並鉗制在 [minScale, maxScale]
        // 還沒確定要縮放前倍率固定為 1 (純平移)
        double effectiveScaleFactor = _pinchZoomed ? rawScaleFactor : 1.0;
        final double projectedScale = currentScale * effectiveScaleFactor;

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
        _viewMoving = true;
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
  void onPointerUp(int pointerId, {bool canceled = false}) {
    if (_ignoredPointers.remove(pointerId)) return;
    _touchIds.remove(pointerId);
    _penIds.remove(pointerId);

    // ★ 系統取消 (防誤觸 / 手勢被搶走)：不是使用者真的抬手，
    //   絕不能當成雙指 / 三指輕點
    if (canceled) {
      _twoFingerTapCandidate = false;
      _threeFingerTapCandidate = false;
      _twoFingerDownTime = null;
      _threeFingerDownTime = null;
    }

    final bool wasTouchPan = _isTouchPanning;
    final bool wasImagePan = _isImagePanning && _imagePanTotal >= _tapSlop;
    final bool wasLassoPan = _isLassoPanning && _lassoPanMoved;
    // 放手瞬間的平移速度 (單指平移；雙指則在第一指離開時就先算好)
    Offset? flingV;
    if (wasTouchPan || wasImagePan || wasLassoPan) {
      flingV = _panReleaseVelocity();
    } else if (_isScalingLocked && !_pinchZoomed) {
      if (_pointerPositions.length == 2) {
        _pendingPinchFling = _panReleaseVelocity();
        _pendingPinchFlingAt = _panClock.elapsedMilliseconds;
      }
    }
    _isTouchPanning = false;
    _isImagePanning = false;
    _isLassoPanning = false;
    _lassoPanMoved = false;

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
          _showHudMessage(S.current.undone);
        } else {
          _showHudMessage(S.current.nothingToUndo);
        }
      }
    }

    // 三指輕點 → 重做
    if (_threeFingerTapCandidate && _threeFingerDownTime != null) {
      final elapsed = DateTime.now()
          .difference(_threeFingerDownTime!)
          .inMilliseconds;
      _threeFingerTapCandidate = false;
      _threeFingerDownTime = null;
      if (elapsed < 300) {
        // 還原輕點期間可能產生的微小平移 / 縮放抖動
        if (_matrixBeforeGesture != null) {
          transformation = _matrixBeforeGesture!;
        }
        if (canRedo) {
          redo();
          _showHudMessage(S.current.redone, icon: Icons.redo);
        } else {
          _showHudMessage(S.current.nothingToRedo, icon: Icons.redo);
        }
      }
    }

    _pointerPositions.remove(pointerId);

    if (!_isScalingLocked && !_gestureCancelled && !wasTouchPan) {
      if (currentTool == DrawingTool.image) {
        _imageUp();
      } else if (_isInkTool && _currentPoints.isNotEmpty) {
        _resetShapeState();
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
        if (_xfOp != _ImageOp.none) {
          _xfCommit();
        } else if (_isDraggingSelection) {
          if (_selectionDragStarted) {
            _pushSelectionMoveCommand();
          } else {
            // 在圈選範圍內「點一下」→ 顯示 剪下 / 複製 / 刪除 / 截圖；
            // 圈到的範圍內什麼都沒有時 (只當截圖框) 就只有「截圖」
            lassoMenu = _hasSelectedContent
                ? LassoMenuKind.selection
                : LassoMenuKind.region;
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
      final wasScaling =
          _isScalingLocked || wasTouchPan || wasImagePan || wasLassoPan;
      if (_isScalingLocked &&
          !_pinchZoomed &&
          _panClock.elapsedMilliseconds - _pendingPinchFlingAt < 250) {
        flingV ??= _pendingPinchFling; // 第二指也很快離開才算一次滑動
      }
      _pendingPinchFling = null;
      _isScalingLocked = false;
      _threeFingerSession = false;
      _gestureCancelled = false;
      _previousDistance = 0.0;

      if (wasScaling && flingV != null) {
        // 放手後順勢滑出去；滑完才補高清渲染 / 切回向量
        _startFling(flingV);
      } else {
        _viewMoving = false; // 下面的 notifyListeners 會讓筆劃切回向量
        // ★ 雙指縮放放開時，自動向 pdfrx 索取高清渲染
        if (wasScaling) {
          refreshDetail();
          _scheduleRasterRelease();
        }
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
  /// 把這次拖曳選取內容的位移記成一筆 Undo
  void _pushSelectionMoveCommand() {
    if (_totalDragDelta == Offset.zero || !_hasSelectedContent) return;
    final cmds = <CanvasCommand>[
      if (_selectedStrokes.isNotEmpty)
        MoveStrokesCommand(List.from(_selectedStrokes), _totalDragDelta),
      if (_selectedImages.isNotEmpty)
        MoveImagesCommand(List.from(_selectedImages), _totalDragDelta),
    ];
    _undoStack.add(cmds.length == 1 ? cmds.first : CompositeCommand(cmds));
    _redoStack.clear();
    _colorSession = null; // 位移之後再換色是新的一筆
    _totalDragDelta = Offset.zero;
    _markDirty();
    _warnIfOutOfPage(_selectionBoxes);
  }

  /// 套索工具在空白處按住：剪貼簿有內容時，時間到就浮出「貼上」
  /// 套索以外的工具 (筆 / 螢光筆 / 橡皮擦 / 圖片)：在空白處按住不動 → 浮出「貼上」。
  /// 剪貼簿有筆劃 / 圖片才會出現；手指移動、離開、第二根手指落下都會取消。
  void _startPasteHold(Offset screen) {
    _pasteHoldTimer?.cancel();
    bool stillHolding() =>
        !_disposed &&
        currentTool != DrawingTool.lasso &&
        !_isScalingLocked &&
        _pointerPositions.length == 1 &&
        (_pointerPositions.values.first - screen).distance < _tapSlop &&
        (currentTool != DrawingTool.eraser || _currentErasedBatch.isEmpty);

    _pasteHoldTimer = Timer(_longPressDelay, () async {
      if (!stillHolding()) return;
      if (isContinuous) _activatePageAt(screen); // 連續模式：貼到手指按著的那一頁
      final point = toScene(screen);
      if (!isInsidePage(point)) return;
      final hasImage = await ClipboardImageService.hasImage();
      if (!stillHolding()) return; // 讀剪貼簿期間手指已離開 / 移動
      if (!hasClipboard && !hasImage) return;
      // 按著的這一點不是要畫的：放棄那個小點 / 形狀辨識
      _currentPoints.clear();
      _resetShapeState();
      clearSelection();
      lassoMenu = LassoMenuKind.paste;
      lassoMenuAnchor = screen;
      lassoMenuCanPasteStrokes = hasClipboard;
      lassoMenuCanPasteImage = hasImage;
      _pasteScenePoint = point;
      // 和套索一樣：選單出來後這根手指的動作到此為止，繼續按著 / 移動都不再平移或畫線
      _gestureCancelled = true;
      _isTouchPanning = false;
      _isImagePanning = false;
      activeRepaintNotifier.notifyListeners();
      notifyListeners();
    });
  }

  void _startLassoLongPress() {
    _lassoLongPressTimer?.cancel();
    bool stillHolding() =>
        !_disposed &&
        _isPotentialNewLasso &&
        currentTool == DrawingTool.lasso &&
        _pointerPositions.length == 1 &&
        isInsidePage(_potentialLassoStart);

    _lassoLongPressTimer = Timer(_longPressDelay, () async {
      if (!stillHolding()) return;
      // 套索剪貼簿有筆劃，或系統剪貼簿有圖片 → 才浮出「貼上」
      final point = _potentialLassoStart;
      final screen = _lassoDownScreen;
      final hasImage = await ClipboardImageService.hasImage();
      if (!stillHolding()) return; // 讀剪貼簿期間手指已離開 / 移動
      if (!hasClipboard && !hasImage) return;
      clearSelection();
      lassoMenu = LassoMenuKind.paste;
      lassoMenuAnchor = screen;
      lassoMenuCanPasteStrokes = hasClipboard;
      lassoMenuCanPasteImage = hasImage;
      _pasteScenePoint = point;
      // 長按已經處理完：放開時不要再被當成「點一下取消選取」而把選單關掉
      _isPotentialNewLasso = false;
      _isLassoPanning = false;
      notifyListeners();
    });
  }

  /// 把系統剪貼簿的圖片貼到長按的位置，並進入圖片編輯 (選取、可平移 / 縮放 / 刪除)
  Future<void> pasteImageFromSystemClipboard() async {
    final at = _pasteScenePoint;
    lassoMenu = LassoMenuKind.none;
    notifyListeners();

    final bytes = await ClipboardImageService.readImage();
    if (_disposed) return;
    if (bytes == null) {
      _showHudMessage(S.current.clipboardNoImage,
          icon: Icons.image_not_supported_outlined);
      return;
    }
    final ok = await addImageFromBytes(bytes, at: at);
    if (!_disposed && !ok) {
      _showHudMessage(S.current.imageLoadFailed,
          icon: Icons.image_not_supported_outlined);
    }
  }

  void hideLassoMenu() {
    if (lassoMenu == LassoMenuKind.none) return;
    lassoMenu = LassoMenuKind.none;
    notifyListeners();
  }

  bool get _hasSelectedContent =>
      _selectedStrokes.isNotEmpty || _selectedImages.isNotEmpty;

  String _countLabel() {
    final s = S.current;
    final parts = <String>[
      if (_selectedStrokes.isNotEmpty) s.strokesCount(_selectedStrokes.length),
      if (_selectedImages.isNotEmpty) s.imagesCount(_selectedImages.length),
    ];
    return parts.join(s.listSeparator);
  }

  void _copySelectionToClipboard() {
    _clipboard = _selectedStrokes.map((s) => s.copy()).toList();
    _clipboardImages = _selectedImages.map((i) => i.copy()).toList();
  }

  void copySelection() {
    if (_imageMenuTarget) {
      // 圖片模式：複製到 App 內部剪貼簿 (系統剪貼簿只有截圖面板的「複製」才會寫入)
      _copyImageToClipboard(selectedImage!);
      lassoMenu = LassoMenuKind.none;
      _showHudMessage(S.current.copiedX(S.current.imagesCount(1)), icon: Icons.content_copy);
      notifyListeners();
      return;
    }
    if (!_hasSelectedContent) return;
    _copySelectionToClipboard();
    lassoMenu = LassoMenuKind.none;
    _showHudMessage(S.current.copiedX(_countLabel()), icon: Icons.content_copy);
  }

  void cutSelection() {
    if (_imageMenuTarget) {
      final img = selectedImage!;
      _copyImageToClipboard(img);
      lassoMenu = LassoMenuKind.none;
      _deleteImage(img, hud: false);
      _showHudMessage(S.current.cutX(S.current.imagesCount(1)), icon: Icons.content_cut);
      notifyListeners();
      return;
    }
    if (!_hasSelectedContent) return;
    _copySelectionToClipboard();
    final label = _countLabel();
    _removeSelected();
    _showHudMessage(S.current.cutX(label), icon: Icons.content_cut);
  }

  void deleteSelection() {
    if (_imageMenuTarget) {
      lassoMenu = LassoMenuKind.none;
      _deleteImage(selectedImage!);
      notifyListeners();
      return;
    }
    if (!_hasSelectedContent) return;
    final label = _countLabel();
    _removeSelected();
    _showHudMessage(S.current.deletedX(label), icon: Icons.delete_outline);
  }

  /// 刪除目前選取的筆劃與圖片 (一次 Undo；筆劃沿用橡皮擦命令：依移除順序記錄索引)
  void _removeSelected() {
    final cmds = <CanvasCommand>[];

    final removed = <MapEntry<int, Stroke>>[];
    for (final stroke in _selectedStrokes) {
      final i = _historyStrokes.indexOf(stroke);
      if (i == -1) continue;
      removed.add(MapEntry(i, stroke));
      _historyStrokes.removeAt(i);
    }
    if (removed.isNotEmpty) cmds.add(EraseStrokesCommand(removed));

    final list = currentPage.images;
    for (final img in _selectedImages) {
      final i = list.indexOf(img);
      if (i == -1) continue;
      list.removeAt(i);
      cmds.add(RemoveImageCommand(list, img, i)); // Composite 會反向還原，索引才對得上
    }

    if (cmds.isNotEmpty) {
      _undoStack.add(cmds.length == 1 ? cmds.first : CompositeCommand(cmds));
      _redoStack.clear();
      _markDirty();
    }
    clearSelection();
    _bakeHistoryToPicture();
    activeRepaintNotifier.notifyListeners();
    notifyListeners();
  }

  /// 把剪貼簿內容 (筆劃 + 圖片) 貼到剛才點的位置 (以內容中心對齊，並保持在紙張內)，貼完自動選取方便拖動
  void pasteFromClipboard() {
    if (!hasClipboard) return;
    // 剪貼簿只有一張圖 (從圖片模式複製的) → 貼完回到圖片模式；其餘貼完進套索的調整大小
    final bool singleImage = _clipboard.isEmpty && _clipboardImages.length == 1;
    final target = singleImage ? DrawingTool.image : DrawingTool.lasso;
    if (currentTool != target) setTool(target);
    Rect? b;
    for (final s in _clipboard) {
      b = b == null ? s.bounds : b.expandToInclude(s.bounds);
    }
    for (final i in _clipboardImages) {
      b = b == null ? i.bounds : b.expandToInclude(i.bounds);
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
    final pastedImages = _clipboardImages
        .map(
          (i) => PageImage(
            id: PageImageStore.newId(),
            fileName: i.fileName, // 共用同一個圖檔
            rect: i.rect.shift(shift),
            rotation: i.rotation,
          ),
        )
        .toList();

    final cmds = <CanvasCommand>[];
    if (pasted.isNotEmpty) {
      _historyStrokes.addAll(pasted);
      cmds.add(AddStrokesCommand(pasted));
    }
    for (final img in pastedImages) {
      currentPage.images.add(img);
      cmds.add(AddImageCommand(currentPage.images, img));
    }
    _undoStack.add(cmds.length == 1 ? cmds.first : CompositeCommand(cmds));
    _redoStack.clear();
    _markDirty();

    clearSelection();
    if (singleImage) {
      _selectedImage = pastedImages.first; // 圖片模式：選取剛貼上的圖片，可直接平移 / 縮放 / 旋轉
      _bakeHistoryToPicture();
      activeRepaintNotifier.notifyListeners();
      viewSignal.fire();
      notifyListeners();
      _showHudMessage(S.current.pasted, icon: Icons.content_paste);
      return;
    }
    _selectedStrokes.addAll(pasted);
    _selectedImages.addAll(pastedImages);
    final box = b.shift(shift).inflate(8);
    _selectedLassoPolygon.addAll([
      box.topLeft,
      box.topRight,
      box.bottomRight,
      box.bottomLeft,
    ]);

    _bakeHistoryToPicture();
    activeRepaintNotifier.notifyListeners();
    beginSelectionTransform(); // 貼上後直接可以縮放 / 旋轉 / 移動
    _showHudMessage(S.current.pasted, icon: Icons.content_paste);
  }

  /// 截圖：套索虛線的「最小外接矩形」(裁在紙張內)，輸出 PNG。含底圖與範圍內所有筆劃。
  Future<Uint8List?> captureSelectionPng() async {
    if (_selectedLassoPolygon.isEmpty) return null;
    final pageRect = Rect.fromLTWH(0, 0, currentPage.width, currentPage.height);
    final region = _boundsOf(_selectedLassoPolygon).intersect(pageRect);
    if (region.width < 1 || region.height < 1) return null;

    final dpr = ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
    // 使用者指定解析度 → 直接用 (太大時 RegionCapture 會自動降倍率)；0 = 自動
    final scale = screenshotScale > 0
        ? screenshotScale
        : (dpr * max(1.0, zoomPercentage / 100)).clamp(2.0, 8.0).toDouble();
    return RegionCapture.renderPng(
      page: currentPage,
      strokes: List.of(_historyStrokes),
      region: region,
      scale: scale,
    );
  }

  void _calculateLassoSelection() {
    _colorSession = null; // 新的選取 → 換色重新算一筆
    _selectedStrokes.clear();
    _selectedImages.clear();

    // 套索外框：和筆劃外框不相交的筆劃不必逐點檢查
    final polyBounds = _boundsOf(_selectedLassoPolygon);

    for (final stroke in _historyStrokes) {
      if (!_lassoSelectable(stroke)) continue;
      if (!stroke.bounds.inflate(1.0).overlaps(polyBounds)) continue;
      bool isHit = false;
      final sp = stroke.points;
      for (int i = 0; i < sp.length && !isHit; i++) {
        final p = sp[i];
        if (RayCasting.isPointInPolygon(
          Offset(p.x, p.y),
          _selectedLassoPolygon,
        )) {
          isHit = true;
          break;
        }
        // 點很稀疏時 (例如直線只有兩個端點)，沿線段補查，圈到中間也算選到
        if (i + 1 < sp.length) {
          final q = sp[i + 1];
          final len = sqrt((q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y));
          final n = min(200, (len / 6).ceil());
          for (int k = 1; k < n; k++) {
            final t = k / n;
            if (RayCasting.isPointInPolygon(
              Offset(p.x + (q.x - p.x) * t, p.y + (q.y - p.y) * t),
              _selectedLassoPolygon,
            )) {
              isHit = true;
              break;
            }
          }
        }
      }

      if (isHit) {
        _selectedStrokes.add(stroke);
      }
    }

    // 圖片：套索與圖片矩形有任何重疊 (哪怕只套到一角) 就算圈到
    if (lassoTargetImage && _selectedLassoPolygon.length >= 3) {
      final lassoPath = Path()..addPolygon(_selectedLassoPolygon, true);
      for (final img in currentPage.images) {
        if (!img.bounds.overlaps(polyBounds)) continue; // 外框不相交就不必精算
        final overlap = Path.combine(
          PathOperation.intersect,
          lassoPath,
          Path()..addPolygon(img.frame.corners, true),
        );
        if (!overlap.getBounds().isEmpty) _selectedImages.add(img);
      }
    }

    // 什麼都沒圈到也保留套索圈圈 (之後點圈內可以截圖)，點圈外才取消
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
      if (!_erasable(stroke)) continue;
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

    for (final stroke in _historyStrokes) {
      canvas.drawPath(stroke.outlinePath, stroke.fillPaint);
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
    canvas.drawPath(stroke.outlinePath, stroke.fillPaint);
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

/// 平移速度取樣：時間 (ms) 與當次實際套用的位移
class _PanSample {
  final int t;
  final Offset delta;
  const _PanSample(this.t, this.delta);
}
