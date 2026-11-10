// lib/features/canvas/presentation/controllers/page_image_manager.dart
//
// 負責 PDF 頁面「圖片」的完整生命週期：
//   底圖 (整頁、低解析度)  +  圖塊 (只涵蓋可視區域的高解析度)
// 從 CanvasController 抽出。與控制器唯一的耦合是建構時注入的幾個 callback，
// 因此可以獨立閱讀、測試與修改，不會碰到筆劃/手勢/Undo 邏輯。
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../../core/engine/tile_planner.dart';
import '../../../document/domain/note_page.dart';
import '../../../pdf_import_export/services/pdf_service.dart';

/// 高清圖塊要服務的頁面，以及該頁左上角在畫布 (scene) 座標中的位置
class PageFocus {
  final NotePage page;
  final Offset origin;
  const PageFocus(this.page, this.origin);
}

class PageImageManager {
  PageImageManager({
    required Matrix4 Function() transform,
    required Size Function() viewportSize,
    required double Function() zoom, // 1.0 = 100%
    required PageFocus? Function() focus,
    required VoidCallback onChanged,
  }) : _transform = transform,
       _viewportSize = viewportSize,
       _zoom = zoom,
       _focus = focus,
       _onChanged = onChanged;

  final Matrix4 Function() _transform;
  final Size Function() _viewportSize;
  final double Function() _zoom;
  final PageFocus? Function() _focus;
  final VoidCallback _onChanged;

  NotePage? _shown; // 目前顯示中的頁面
  Set<NotePage> _visible = {}; // 連續捲動模式下，可視範圍內需要底圖的頁面
  NotePage? _detailOwner; // 目前持有高清圖塊的頁面
  final Set<NotePage> _loadingBase = {}; // 正在載入底圖的頁面 (去重)
  bool _busy = false; // 圖塊渲染中
  bool _pending = false; // 渲染中又有新縮放 → 結束後再檢查一次
  bool _disposed = false;

  double get _dpr => ui.PlatformDispatcher.instance.views.first.devicePixelRatio;

  /// 底圖倍率：DPR，且整頁不超過記憶體上限
  double baseScale(NotePage page) =>
      TilePlanner.baseScale(pageW: page.width, pageH: page.height, dpr: _dpr);

  // ------------------------------------------------------------
  // 對外介面
  // ------------------------------------------------------------

  /// 切換到 [page]：同步釋放前一頁的圖 (PDF 頁面之後可按需重新渲染)
  void setShown(NotePage page) {
    final prev = _shown;
    if (prev != null && prev != page && !_visible.contains(prev)) {
      _release(prev);
    }
    _shown = page;
  }

  /// 連續捲動模式：宣告目前可視 (含預載邊界) 的頁面。
  /// 新進入的頁面按需載入底圖；離開的頁面釋放圖片。
  /// 單頁模式請傳入空集合。
  void setVisible(Iterable<NotePage> pages) {
    final next = pages.toSet();
    if (next.length == _visible.length && next.containsAll(_visible)) return;
    final old = _visible;
    _visible = next;
    for (final p in old) {
      if (!next.contains(p) && p != _shown) _release(p);
    }
    for (final p in next) {
      // 目前頁永遠優先：其他可視頁等它載完才開始，避免搶走 PDF 解析與渲染資源
      unawaited(p == _shown ? loadBase(p) : _loadAfterShown(p));
    }
  }

  Future<void> _loadAfterShown(NotePage page) async {
    final shown = _shown;
    if (shown != null && shown != page) {
      // 目前頁還沒載好 → 先讓它載 (已在載入中就等它；否則由這裡直接代為載入)
      if (shown.cachedBackgroundImage == null && shown.pdfFilePath != null) {
        await loadBase(shown);
      }
    }
    if (_disposed || !_wanted(page)) return;
    await loadBase(page);
  }

  /// 這次 App 執行期間已經載入過的 PDF 檔 (第一次開啟才需要先出預覽圖)
  final Set<String> _seenPdfs = {};

  bool _wanted(NotePage page) => page == _shown || _visible.contains(page);

  /// 按需載入底圖。_loadingBase 去重：A→B→A 快速切換不會同時渲染兩次。
  Future<void> loadBase(NotePage page) async {
    if (page.cachedBackgroundImage != null ||
        page.pdfFilePath == null ||
        page.pdfPageNumber == null ||
        !_loadingBase.add(page)) {
      return;
    }
    try {
      final path = page.pdfFilePath!;
      final full = baseScale(page);
      ui.Image? previewImage; // 第一次載入時的低解析度預覽，正式圖完成後取代它

      // ★ 開啟 App 後第一次載入這份 PDF：先用低解析度快速把「目前頁」顯示出來，
      //   再接著渲染正式解析度的底圖取代它 (大頁面 / 高 DPR 時差很多)
      if (page == _shown && _seenPdfs.add(path) && full > 1.5) {
        final preview = await PdfService.renderPageImage(
          path,
          page.pdfPageNumber!,
          1.0,
        );
        if (preview != null) {
          if (_disposed || !_wanted(page) || page.cachedBackgroundImage != null) {
            preview.dispose();
          } else {
            page.cachedBackgroundImage = preview;
            previewImage = preview;
            _onChanged();
          }
        }
      } else {
        _seenPdfs.add(path);
      }

      final image = await PdfService.renderPageImage(
        path,
        page.pdfPageNumber!,
        full,
      );
      if (image == null) return;
      final current = page.cachedBackgroundImage;
      // 目前沒圖，或目前的圖就是我們自己的預覽 → 才能放上正式圖
      final canReplace = current == null || identical(current, previewImage);
      if (_disposed || !_wanted(page) || !canReplace) {
        image.dispose(); // 等待期間已切走 / 已被別處載入，這張沒人要了
      } else {
        page.cachedBackgroundImage = image;
        if (current != null) _disposeImageLater(current); // 換掉預覽圖
        _onChanged();
      }
    } finally {
      _loadingBase.remove(page);
    }
  }

  /// 手勢結束 / 換頁 / 重設縮放後呼叫：視需要重繪可視區域的高清圖塊
  void refreshDetail() => unawaited(_updateDetail());

  /// 控制器銷毀時呼叫
  void dispose() {
    _disposed = true;
    final page = _shown;
    if (page != null) _release(page);
    for (final p in _visible) {
      _release(p);
    }
    _visible = {};
    _shown = null;
  }

  // ------------------------------------------------------------
  // 內部
  // ------------------------------------------------------------

  /// 螢幕可視範圍對應到頁面座標、並裁在紙張內
  Rect? _visiblePageRect(NotePage page, Offset origin) {
    final viewport = _viewportSize();
    if (viewport.isEmpty) return null;
    final Rect scene = MatrixUtils.inverseTransformRect(
      _transform(),
      Offset.zero & viewport,
    ).shift(-origin); // 換算成該頁自己的座標
    final Rect v = scene.intersect(Rect.fromLTWH(0, 0, page.width, page.height));
    if (v.width <= 0 || v.height <= 0) return null;
    return v;
  }

  /// 安全釋放 ui.Image (等下一個 frame 畫完後再釋放，避免畫到已釋放的圖)
  static void _disposeImageLater(ui.Image? image) {
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

  void _release(NotePage page) {
    _clearDetail(page);
    // 使用者放上去的圖片：解碼後的 ui.Image 可以隨時從檔案重新載入
    for (final img in page.images) {
      _disposeImageLater(img.image);
      img.image = null;
    }
    if (page.pdfFilePath != null) {
      // 只釋放能從 PDF 重新渲染的底圖
      _disposeImageLater(page.cachedBackgroundImage);
      page.cachedBackgroundImage = null;
    }
  }

  Future<void> _updateDetail() async {
    if (_disposed) return;
    if (_busy) {
      _pending = true;
      return;
    }
    final focus = _focus();
    if (focus == null) return;
    final page = focus.page;

    // 焦點換到別頁 → 舊頁的高清圖塊不再需要
    final prevOwner = _detailOwner;
    if (prevOwner != null && prevOwner != page && _clearDetail(prevOwner)) {
      _onChanged();
    }
    _detailOwner = page;

    if (page.pdfFilePath == null || page.pdfPageNumber == null) {
      return;
    }

    final visible = _visiblePageRect(page, focus.origin);
    if (visible == null) return;
    final plan = TilePlanner.plan(
      pageW: page.width,
      pageH: page.height,
      visLeft: visible.left,
      visTop: visible.top,
      visRight: visible.right,
      visBottom: visible.bottom,
      zoom: _zoom(),
      dpr: _dpr,
    );

    // 1) 縮放不高，底圖已足夠清晰 → 釋放圖塊省記憶體
    if (plan.scale <= baseScale(page) * 1.15) {
      if (_clearDetail(page)) _onChanged();
      return;
    }

    // 2) 現有圖塊仍涵蓋可視範圍且解析度夠 → 不用重繪
    final dr = page.detailRect;
    if (page.detailImage != null &&
        dr != null &&
        TilePlanner.covers(
          outerL: dr.left,
          outerT: dr.top,
          outerR: dr.right,
          outerB: dr.bottom,
          innerL: visible.left,
          innerT: visible.top,
          innerR: visible.right,
          innerB: visible.bottom,
        ) &&
        plan.scale <= page.detailScale * 1.15) {
      return;
    }

    _busy = true;
    try {
      final tile = await PdfService.renderRegion(
        page.pdfFilePath!,
        page.pdfPageNumber!,
        plan.scale,
        Rect.fromLTRB(plan.left, plan.top, plan.right, plan.bottom),
      );
      if (tile == null) return;
      if (_disposed || _focus()?.page != page) {
        tile.image.dispose(); // 等待期間已換頁/離開
        return;
      }
      final old = page.detailImage;
      page.detailImage = tile.image;
      page.detailRect = tile.rect;
      page.detailScale = tile.scale;
      _onChanged();
      _disposeImageLater(old);
    } catch (e, st) {
      debugPrint('tile render failed: $e\n$st');
    } finally {
      _busy = false; // ★ 無論如何都要解鎖
      if (_pending && !_disposed) {
        _pending = false;
        unawaited(_updateDetail()); // 渲染期間視野又變了 → 再檢查一次
      }
    }
  }
}
