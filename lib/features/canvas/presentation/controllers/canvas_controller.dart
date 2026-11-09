// lib/features/canvas/presentation/controllers/canvas_controller.dart
import 'dart:math';
import 'dart:ui' as ui;
import 'dart:async';

import 'package:cft_note/features/pdf_import_export/services/pdf_service.dart';
import 'package:cft_note/features/shelf/domain/models/notebook.dart';
import 'package:flutter/material.dart';
import 'package:perfect_freehand/perfect_freehand.dart';

import '../../../../core/algorithms/ray_casting.dart';
import '../../../../core/engine/repaint_signal.dart';
import '../../domain/models/brush_settings.dart';
import '../../domain/models/stroke.dart';
import '../../domain/commands/canvas_command.dart';
import '../../domain/models/tools.dart';
import '../../../document/domain/note_page.dart';
import 'page_image_manager.dart';

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
    onChanged: notifyListeners,
  );

  List<NotePage> get pages => currentNotebook.pages;
  int currentPageIndex = 0;

  NotePage get currentPage => pages[currentPageIndex];
  int get totalPages => pages.length;

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

    // ★ 還原該筆記本上次儲存的縮放平移矩陣
    if (currentNotebook.transformMatrix != null) {
      transformation = Matrix4.fromList(currentNotebook.transformMatrix!);
    }

    final targetPage = currentNotebook.lastViewedPageIndex.clamp(0, pages.length - 1);
    _loadPageState(targetPage);
  }

  // ★ 解決第 2 點：切換至其他 Tab (標籤頁)
  void switchTab(int index) {
    if (index == activeNotebookIndex || index < 0 || index >= openNotebooks.length) return;

    // 1. 保存當前筆記本的筆劃、閱讀頁數、以及當前縮放與平移矩陣！
    _saveCurrentPageState();
    currentNotebook.lastViewedPageIndex = currentPageIndex;
    currentNotebook.transformMatrix = transformation.storage.toList(); // ★ 保存視野
    currentNotebook.updatedAt = DateTime.now();
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
      transformation = Matrix4.fromList(currentNotebook.transformMatrix!);
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
      currentNotebook.lastViewedPageIndex = currentPageIndex;
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
      currentNotebook.lastViewedPageIndex = currentPageIndex;
      currentNotebook.transformMatrix = transformation.storage.toList(); // ★
      currentNotebook.updatedAt = DateTime.now();
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
    final double pageWidth = currentPage.width;
    final double pageHeight = currentPage.height;

    double tx = 0.0;
    double ty = 30.0; // 預設頂部留 30px 舒適邊距

    if (viewportSize.width > 0 && viewportSize.height > 0) {
      // 1. 水平居中：(螢幕寬 - 紙張寬) / 2
      tx = (viewportSize.width - pageWidth) / 2;

      // 2. 垂直居中：若紙張比螢幕矮則垂直置中；若比螢幕高則頂部留 30px 邊距便於閱讀
      if (pageHeight < viewportSize.height) {
        ty = (viewportSize.height - pageHeight) / 2;
      } else {
        ty = 30.0;
      }
    }

    // 設定為 100% (Scale = 1.0) 且平移至正中心
    transformation = Matrix4.translationValues(tx, ty, 0.0);

    showZoomIndicator = true;
    _startZoomIndicatorFadeout();
    notifyListeners();
    images.refreshDetail();
  }

  @override
  void dispose() {
    images.dispose();
    _saveCurrentPageState(); // ★ 核心修復：退出畫布時，立即把筆跡存回當前頁面！
    _zoomIndicatorTimer?.cancel();
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
    _zoomIndicatorTimer = Timer(const Duration(milliseconds: 1000), () {
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
    if (currentPageIndex < pages.length - 1) {
      _saveCurrentPageState();
      _loadPageState(currentPageIndex + 1);
    }
  }

  // 上一頁
  void previousPage() {
    if (currentPageIndex > 0) {
      _saveCurrentPageState();
      _loadPageState(currentPageIndex - 1);
    }
  }

  // 在此頁後面插入一頁空白頁
  void insertBlankPageAfterCurrent() {
    _saveCurrentPageState();
    final newPage = NotePage(
      id: 'page_${DateTime.now().millisecondsSinceEpoch}',
    );
    // 這裡的 pages.insert 會直接插入 currentNotebook.pages！
    pages.insert(currentPageIndex + 1, newPage);
    _markDirty();
    _loadPageState(currentPageIndex + 1);
  }

  Future<void> insertPdfPagesAfterCurrent(List<PdfPageData> pdfPages) async {
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
    _isPotentialNewLasso = false;
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

  Offset toScene(Offset screenPoint) {
    final Matrix4 inverse = Matrix4.inverted(transformation);
    return MatrixUtils.transformPoint(inverse, screenPoint);
  }

  // 1. 手指落下
  void onPointerDown(int pointerId, Offset position, double pressure) {
    _pointerPositions[pointerId] = position;

    if (_pointerPositions.length >= 2) {
      _isScalingLocked = true;
      _currentPoints.clear();
      _currentLassoDrawing.clear();
      _isPotentialNewLasso = false;
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
        if (_selectedLassoPolygon.isNotEmpty &&
            RayCasting.isPointInPolygon(scenePoint, _selectedLassoPolygon)) {
          _isDraggingSelection = true;
          _lastDragPosition = scenePoint;
          _totalDragDelta = Offset.zero;
        } else {
          _isPotentialNewLasso = true;
          _potentialLassoStart = scenePoint;
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
        // 套索拖曳保持不變...
        if (_isDraggingSelection) {
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
          if (_totalDragDelta != Offset.zero) {
            _undoStack.add(
              MoveStrokesCommand(List.from(_selectedStrokes), _totalDragDelta),
            );
            _redoStack.clear();
            _markDirty();
          }
          _isDraggingSelection = false;
        } else if (_isPotentialNewLasso) {
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
        images.refreshDetail();
      }
    }
    notifyListeners();
  }

  // 顯示短暫的浮動膠囊提示 (800ms 自動淡出)
  void _showHudMessage(String message) {
    hudMessage = message;
    showZoomIndicator = true;
    _zoomIndicatorTimer?.cancel();
    _zoomIndicatorTimer = Timer(const Duration(milliseconds: 800), () {
      showZoomIndicator = false;
      hudMessage = null;
      notifyListeners();
    });
    notifyListeners();
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
    if (oldIndex < newIndex) {
      newIndex -= 1; // 修正 Flutter ReorderableList 的索引偏移
    }

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
  void refreshDetail() => images.refreshDetail();
}
