// lib/features/canvas/presentation/controllers/canvas_controller.dart
import 'dart:math';
import 'dart:ui' as ui;
import 'dart:async';

import 'package:cft_note/features/pdf_import_export/services/pdf_service.dart';
import 'package:cft_note/features/shelf/domain/models/notebook.dart';
import 'package:flutter/material.dart';
import 'package:perfect_freehand/perfect_freehand.dart';

import '../../../../core/algorithms/ray_casting.dart';
import '../../domain/models/brush_settings.dart';
import '../../domain/models/stroke.dart';
import '../../domain/models/tools.dart';
import '../../../document/domain/note_page.dart';

// 1. 命令模式 (Command Pattern) 支援 Undo / Redo
abstract class CanvasCommand {
  void undo(List<Stroke> strokes);
  void redo(List<Stroke> strokes);
}

// 繪畫命令
class DrawStrokeCommand implements CanvasCommand {
  final Stroke stroke;
  DrawStrokeCommand(this.stroke);
  @override
  void undo(List<Stroke> strokes) => strokes.remove(stroke);
  @override
  void redo(List<Stroke> strokes) => strokes.add(stroke);
}

// 橡皮擦命令
class EraseStrokesCommand implements CanvasCommand {
  final List<MapEntry<int, Stroke>> erasedItems;
  EraseStrokesCommand(this.erasedItems);
  @override
  void undo(List<Stroke> strokes) {
    final sorted = List.of(erasedItems)..sort((a, b) => a.key.compareTo(b.key));
    for (final entry in sorted) {
      if (entry.key <= strokes.length) {
        strokes.insert(entry.key, entry.value);
      } else {
        strokes.add(entry.value);
      }
    }
  }

  @override
  void redo(List<Stroke> strokes) {
    for (final entry in erasedItems) {
      strokes.remove(entry.value);
    }
  }
}

// 套索移動命令
class MoveStrokesCommand implements CanvasCommand {
  final List<Stroke> targetStrokes;
  final Offset delta;
  MoveStrokesCommand(this.targetStrokes, this.delta);
  @override
  void undo(List<Stroke> strokes) => _applyOffset(-delta);
  @override
  void redo(List<Stroke> strokes) => _applyOffset(delta);

  void _applyOffset(Offset offset) {
    for (final stroke in targetStrokes) {
      for (int i = 0; i < stroke.points.length; i++) {
        final p = stroke.points[i];
        stroke.points[i] = PointVector(
          p.x + offset.dx,
          p.y + offset.dy,
          p.pressure,
        );
      }
    }
  }
}

// 套索批次換色命令 (支援 Undo / Redo 復原舊顏色)
class ChangeStrokesColorCommand implements CanvasCommand {
  final List<Stroke> oldStrokes;
  final List<Stroke> newStrokes;

  ChangeStrokesColorCommand(this.oldStrokes, this.newStrokes);

  @override
  void undo(List<Stroke> strokes) {
    for (int i = 0; i < newStrokes.length; i++) {
      final index = strokes.indexOf(newStrokes[i]);
      if (index != -1) {
        strokes[index] = oldStrokes[i];
      }
    }
  }

  @override
  void redo(List<Stroke> strokes) {
    for (int i = 0; i < oldStrokes.length; i++) {
      final index = strokes.indexOf(oldStrokes[i]);
      if (index != -1) {
        strokes[index] = newStrokes[i];
      }
    }
  }
}

// 2. 主畫布控制器 (CanvasController)
class CanvasController extends ChangeNotifier {
  final List<Stroke> _historyStrokes = [];
  final List<CanvasCommand> _undoStack = [];
  final List<CanvasCommand> _redoStack = [];
  final List<PointVector> _currentPoints = [];
  final List<MapEntry<int, Stroke>> _currentErasedBatch = [];
  bool _isSharpening = false;
  bool _sharpenPending = false; // 銳化進行中又有新縮放 → 結束後再檢查一次
  bool _disposed = false;
  NotePage? _shownPage; // 目前顯示中的頁面 (切頁時釋放前一頁的圖)
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

    // 2. 切換標籤
    activeNotebookIndex = index;

    if (pages.isEmpty) {
      pages.add(NotePage(id: 'page_1'));
    }

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
  double maxScale = 20.0; // 最大放大至 2000% (分塊渲染後記憶體與倍率無關)
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
    unawaited(_checkAndSharpenPdf());
  }

  @override
  void dispose() {
    _disposed = true;
    if (_shownPage != null) _releasePageImages(_shownPage!);
    _saveCurrentPageState(); // ★ 核心修復：退出畫布時，立即把筆跡存回當前頁面！
    _zoomIndicatorTimer?.cancel();
    activeRepaintNotifier.dispose();
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

    // ★ 離開的頁面釋放圖塊與底圖 (PDF 頁面之後可按需重新渲染)，避免翻頁越翻越吃記憶體
    final prev = _shownPage;
    if (prev != null && prev != targetPage) _releasePageImages(prev);
    _shownPage = targetPage;

    _historyStrokes.clear();
    _historyStrokes.addAll(targetPage.strokes);

    _undoStack.clear();
    _undoStack.addAll(targetPage.undoStack);

    _redoStack.clear();
    _redoStack.addAll(targetPage.redoStack);

    clearSelection();
    _bakeHistoryToPicture();
    notifyListeners();

    // ★ 按需加載底圖 (整頁、低解析度)
    if (targetPage.cachedBackgroundImage == null &&
        targetPage.pdfFilePath != null &&
        targetPage.pdfPageNumber != null) {
      final image = await PdfService.renderPageImage(
        targetPage.pdfFilePath!,
        targetPage.pdfPageNumber!,
        _baseScale(targetPage),
      );
      if (image != null) {
        if (_disposed || _shownPage != targetPage) {
          image.dispose(); // 等待期間已切走，這張圖沒人要了
        } else {
          targetPage.cachedBackgroundImage = image;
          notifyListeners();
        }
      }
    }

    // 若目前視野是放大的，補上可視區域的高清圖塊
    unawaited(_checkAndSharpenPdf());
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
    currentNotebook.updatedAt = DateTime.now();
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
    currentNotebook.updatedAt = DateTime.now();
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
        final sorted = List.of(_currentErasedBatch)
          ..sort((a, b) => a.key.compareTo(b.key));
        for (final entry in sorted) {
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
        _eraseAtPoint(scenePoint);
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
        // ★ 移動時持續更新預覽圓圈位置
        eraserPosition = scenePoint;
        _eraseAtPoint(scenePoint);
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
        _bakeHistoryToPicture();
        activeRepaintNotifier.notifyListeners();
      } else if (currentTool == DrawingTool.eraser) {
        // ★ 核心修復：無論有沒有擦到字，只要手指抬起，感應圈必定清空！
        eraserPosition = null;

        // 只有真的有擦到字，才打包進 Undo 歷史
        if (_currentErasedBatch.isNotEmpty) {
          _undoStack.add(EraseStrokesCommand(List.from(_currentErasedBatch)));
          _redoStack.clear();
          _currentErasedBatch.clear();
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
        _checkAndSharpenPdf();
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

    for (final stroke in _historyStrokes) {
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

  void _eraseAtPoint(Offset point) {
    // ★ 核心：使用當前縮放下的精準半徑，徹底杜絕「沒碰到就刪掉」的靈異現象
    final double radius = currentEraseRadius;
    bool hasChanged = false;

    for (int i = _historyStrokes.length - 1; i >= 0; i--) {
      final stroke = _historyStrokes[i];
      for (final p in stroke.points) {
        final distance = sqrt(pow(p.x - point.dx, 2) + pow(p.y - point.dy, 2));
        if (distance <= radius) {
          _currentErasedBatch.add(MapEntry(i, stroke));
          _historyStrokes.removeAt(i);
          hasChanged = true;
          break;
        }
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
      clearSelection();
      _bakeHistoryToPicture();
      notifyListeners();
    }
  }

  // 靜態歷史筆畫烘焙
  void _bakeHistoryToPicture() {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    for (final stroke in _historyStrokes) {
      final paint = Paint()
        ..color = stroke.color
        ..style = PaintingStyle.fill;

      // 使用每條筆劃當時的專屬筆刷參數進行重繪
      final outlinePoints = getStroke(
        stroke.points,
        options: StrokeOptions(
          size: stroke.settings.size,
          thinning: stroke.settings.thinning,
          smoothing: stroke.settings.smoothing,
          streamline: stroke.settings.streamline,
          simulatePressure: false,
        ),
      );

      final path = Path();
      if (outlinePoints.isNotEmpty) {
        path.moveTo(outlinePoints.first.dx, outlinePoints.first.dy);
        for (int i = 1; i < outlinePoints.length; i++) {
          path.lineTo(outlinePoints[i].dx, outlinePoints[i].dy);
        }
        path.close();
        canvas.drawPath(path, paint);
      }
    }
    cachedHistoryPicture = recorder.endRecording();
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

  // ==========================================
  // ★ 分塊渲染 (Tile Rendering)
  //   底圖：整頁 × min(DPR, 記憶體上限)，永遠存在
  //   圖塊：只涵蓋「可視區域 + 30% 緩衝」，解析度 = 縮放 × DPR
  //   記憶體 ≈ 一張底圖 + 一個圖塊 (≤16MP)，與縮放倍率無關
  // ==========================================
  static const double _maxTileSide = 4096.0; // 單邊上限
  static const double _maxTilePixels = 16e6; // 約 64MB RGBA
  static const double _tileMargin = 0.3; // 可視範圍外多渲染的比例

  double get _dpr => ui.PlatformDispatcher.instance.views.first.devicePixelRatio;

  /// 底圖倍率：DPR，且整頁不超過記憶體上限
  double _baseScale(NotePage page) {
    final capSide = _maxTileSide / max(page.width, page.height);
    final capPixels = sqrt(_maxTilePixels / (page.width * page.height));
    return min(_dpr, min(capSide, capPixels));
  }

  /// 螢幕可視範圍對應到頁面座標、並裁在紙張內
  Rect? _visiblePageRect(NotePage page) {
    if (viewportSize.isEmpty) return null;
    final Rect scene = MatrixUtils.inverseTransformRect(
      transformation,
      Offset.zero & viewportSize,
    );
    final Rect v = scene.intersect(Rect.fromLTWH(0, 0, page.width, page.height));
    if (v.width <= 0 || v.height <= 0) return null;
    return v;
  }

  bool _tileFits(Rect r, double scale) {
    final w = r.width * scale, h = r.height * scale;
    return w <= _maxTileSide && h <= _maxTileSide && w * h <= _maxTilePixels;
  }

  /// 決定要渲染的區域與倍率 (保證不超過記憶體預算)
  ({Rect rect, double scale}) _planTile(NotePage page, Rect visible) {
    double scale = zoomPercentage / 100 * _dpr;
    final pageRect = Rect.fromLTWH(0, 0, page.width, page.height);
    final mx = visible.width * _tileMargin, my = visible.height * _tileMargin;
    final withMargin = Rect.fromLTRB(
      visible.left - mx,
      visible.top - my,
      visible.right + mx,
      visible.bottom + my,
    ).intersect(pageRect);

    Rect rect = _tileFits(withMargin, scale) ? withMargin : visible;
    if (!_tileFits(rect, scale)) {
      // 可視區域本身就太大 (例如超大平板縮得很小) → 降倍率
      scale = min(
        scale,
        min(
          _maxTileSide / rect.width,
          min(
            _maxTileSide / rect.height,
            sqrt(_maxTilePixels / (rect.width * rect.height)),
          ),
        ),
      );
    }
    return (rect: rect, scale: scale);
  }

  bool _covers(Rect outer, Rect inner) =>
      outer.left <= inner.left + 0.01 &&
      outer.top <= inner.top + 0.01 &&
      outer.right >= inner.right - 0.01 &&
      outer.bottom >= inner.bottom - 0.01;

  /// 安全釋放 ui.Image (等下一個 frame 畫完後再釋放，避免畫到已釋放的圖)
  void _disposeImageLater(ui.Image? image) {
    if (image == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => image.dispose());
    WidgetsBinding.instance.scheduleFrame();
  }

  bool _clearDetail(NotePage page) {
    if (page.detailImage == null) return false;
    _disposeImageLater(page.detailImage);
    page.detailImage = null;
    page.detailRect = null;
    page.detailScale = 0;
    return true;
  }

  void _releasePageImages(NotePage page) {
    _clearDetail(page);
    if (page.pdfFilePath != null) {
      // 只釋放能從 PDF 重新渲染的底圖
      _disposeImageLater(page.cachedBackgroundImage);
      page.cachedBackgroundImage = null;
    }
  }

  /// 供外部 (排版完成後) 呼叫
  void refreshDetail() => unawaited(_checkAndSharpenPdf());

  /// 手勢結束 / 換頁 / 重設縮放後呼叫：視需要重繪可視區域的高清圖塊
  Future<void> _checkAndSharpenPdf() async {
    if (_disposed) return;
    if (_isSharpening) {
      _sharpenPending = true;
      return;
    }
    if (currentPageIndex >= pages.length) return;
    final page = currentPage;
    if (page.pdfFilePath == null || page.pdfPageNumber == null) return;

    final visible = _visiblePageRect(page);
    if (visible == null) return;
    final plan = _planTile(page, visible);

    // 1) 縮放不高，底圖已足夠清晰 → 釋放圖塊省記憶體
    if (plan.scale <= _baseScale(page) * 1.15) {
      if (_clearDetail(page)) notifyListeners();
      return;
    }

    // 2) 現有圖塊仍涵蓋可視範圍且解析度夠 → 不用重繪
    final dr = page.detailRect;
    if (page.detailImage != null &&
        dr != null &&
        _covers(dr, visible) &&
        plan.scale <= page.detailScale * 1.15) {
      return;
    }

    _isSharpening = true;
    try {
      final tile = await PdfService.renderRegion(
        page.pdfFilePath!,
        page.pdfPageNumber!,
        plan.scale,
        plan.rect,
      );
      if (tile == null) return;
      if (_disposed || _shownPage != page) {
        tile.image.dispose(); // 等待期間已換頁/離開
        return;
      }
      final old = page.detailImage;
      page.detailImage = tile.image;
      page.detailRect = tile.rect;
      page.detailScale = tile.scale;
      notifyListeners();
      _disposeImageLater(old);
    } catch (e, st) {
      debugPrint('tile render failed: $e\n$st');
    } finally {
      _isSharpening = false; // ★ 無論如何都要解鎖
      if (_sharpenPending && !_disposed) {
        _sharpenPending = false;
        unawaited(_checkAndSharpenPdf()); // 渲染期間視野又變了 → 再檢查一次
      }
    }
  }
}
