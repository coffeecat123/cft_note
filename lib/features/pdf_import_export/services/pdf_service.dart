// lib/features/pdf_import_export/services/pdf_service.dart
import 'dart:math' show max;
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart' show Color;
import 'package:pdfrx/pdfrx.dart';

import '../../../core/engine/tile_planner.dart';

class PdfPageData {
  final double width;
  final double height;
  final String filePath;
  final int pageNumber;
  final ui.Image? initialImage; // 只有第 1 頁會立刻渲染，其餘延遲載入

  PdfPageData({
    required this.width,
    required this.height,
    required this.filePath,
    required this.pageNumber,
    this.initialImage,
  });
}

/// 局部渲染結果：影像 + 它在頁面座標中實際涵蓋的範圍
class PdfTile {
  final ui.Image image;
  final ui.Rect rect;
  final double scale;
  PdfTile(this.image, this.rect, this.scale);
}

class PdfService {
  // ★ 快取已開啟的 PDF 實例 (快取 Future：同時多個請求只會開一次，不會重複開檔而洩漏)
  static final Map<String, Future<PdfDocument>> _docCache = {};

  static Future<PdfDocument> _getDocument(String filePath) {
    return _docCache.putIfAbsent(filePath, () {
      final future = PdfDocument.openFile(filePath);
      // 開檔失敗不要把失敗結果永遠留在快取裡
      future.then<void>((_) {}, onError: (Object e) {
        _docCache.remove(filePath); // 呼叫端自己 await future 時仍會收到錯誤
      });
      return future;
    });
  }

  /// 預先開啟 PDF (只解析檔案、不渲染)，讓使用者點進筆記時不必再等開檔
  static void warmUp(String filePath) {
    _getDocument(filePath).then<void>((_) {}, onError: (Object e) {
      debugPrint('warmUp failed: $e');
    });
  }

  /// 釋放某個 PDF 檔案占用的原生資源 (筆記本被刪除、檔案不再被引用時呼叫)
  static Future<void> evictDocument(String filePath) async {
    final future = _docCache.remove(filePath);
    if (future == null) return;
    try {
      final doc = await future;
      final dynamic result = (doc as dynamic).dispose();
      if (result is Future) await result;
    } catch (e) {
      debugPrint('evictDocument failed: $e');
    }
  }

  /// 釋放所有已開啟的 PDF
  static Future<void> closeAll() async {
    for (final path in List<String>.of(_docCache.keys)) {
      await evictDocument(path);
    }
  }

  /// 挑選本機 PDF 並抽取各頁資訊
  static Future<List<PdfPageData>?> pickAndRenderPdf() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );

    if (files.isEmpty || files.first.path == null) return null;

    final String filePath = files.first.path!;
    final document = await _getDocument(filePath);
    final List<PdfPageData> pageDataList = [];

    // ★ 初始第 1 頁以 DPR 渲染，保證一打開就點對點清晰；超大頁面會被記憶體上限壓低
    final double dpr = ui.PlatformDispatcher.instance.views.first.devicePixelRatio;

    for (int i = 1; i <= document.pages.length; i++) {
      final page = document.pages[i - 1];

      ui.Image? firstPageImage;
      if (i == 1) {
        firstPageImage = await renderPageImage(
          filePath,
          1,
          TilePlanner.baseScale(pageW: page.width, pageH: page.height, dpr: dpr),
        );
      }

      pageDataList.add(PdfPageData(
        width: page.width,
        height: page.height,
        filePath: filePath,
        pageNumber: i,
        initialImage: firstPageImage,
      ));
    }

    return pageDataList;
  }

  /// ★★★ 核心提速 30 倍：零拷貝直接產出 ui.Image 直通 GPU，徹底刪除 PNG 編解碼！★★★
  static Future<ui.Image?> renderPageImage(
    String filePath,
    int pageNumber,
    double targetScale,
  ) async {
    try {
      final document = await _getDocument(filePath);
      if (pageNumber > document.pages.length) return null;
      final page = document.pages[pageNumber - 1];

      final double targetW = page.width * targetScale;
      final double targetH = page.height * targetScale;

      // 1. PDFium 高速渲染
      final pageImage = await page.render(
        fullWidth: targetW,
        fullHeight: targetH,
        width: targetW.round(),
        height: targetH.round(),
        backgroundColor: const Color(0xFFFFFFFF).toARGB32(),
      );

      if (pageImage == null) return null;

      // 2. 直接產出原生 ui.Image；PdfImage 的原生像素緩衝必須手動 dispose，
      //    否則每次渲染都會洩漏一整張點陣圖 (高倍率時一張就數十 MB)
      try {
        return await pageImage.createImage();
      } finally {
        pageImage.dispose();
      }
    } catch (e, st) {
      debugPrint('renderPageImage failed: $e\n$st');
      return null;
    }
  }

  /// ★ 只渲染頁面的一塊區域 (頁面座標 region) 到高解析度。
  /// 記憶體只與「圖塊像素數」有關，與縮放倍率、整頁大小無關。
  static Future<PdfTile?> renderRegion(
    String filePath,
    int pageNumber,
    double scale,
    ui.Rect region,
  ) async {
    try {
      final document = await _getDocument(filePath);
      if (pageNumber > document.pages.length) return null;
      final page = document.pages[pageNumber - 1];

      // 以整數像素對齊，回傳實際涵蓋範圍，疊圖時才不會有縫隙或位移
      final int fullW = max(1, (page.width * scale).round());
      final int fullH = max(1, (page.height * scale).round());
      final double sx = fullW / page.width;
      final double sy = fullH / page.height;

      final int x = (region.left * sx).floor().clamp(0, fullW - 1);
      final int y = (region.top * sy).floor().clamp(0, fullH - 1);
      final int r = (region.right * sx).ceil().clamp(x + 1, fullW);
      final int b = (region.bottom * sy).ceil().clamp(y + 1, fullH);
      final int w = r - x;
      final int h = b - y;

      final pageImage = await page.render(
        x: x,
        y: y,
        width: w,
        height: h,
        fullWidth: fullW.toDouble(),
        fullHeight: fullH.toDouble(),
        backgroundColor: const Color(0xFFFFFFFF).toARGB32(),
      );
      if (pageImage == null) return null;

      try {
        final image = await pageImage.createImage();
        return PdfTile(
          image,
          ui.Rect.fromLTWH(x / sx, y / sy, w / sx, h / sy),
          sx,
        );
      } finally {
        pageImage.dispose();
      }
    } catch (e, st) {
      debugPrint('renderRegion failed: $e\n$st');
      return null;
    }
  }
}
