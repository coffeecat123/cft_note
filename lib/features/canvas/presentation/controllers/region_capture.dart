// lib/features/canvas/presentation/controllers/region_capture.dart
//
// 把「頁面上的一塊矩形區域」輸出成 PNG：底圖 (PDF / 空白橫線) + 全部筆劃。
// 不含套索虛線。PDF 底圖直接向 pdfium 要該區域的高解析度，不受畫面縮放影響。
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../../../core/engine/tile_planner.dart';
import '../../../document/data/page_image_store.dart';
import '../../../document/domain/note_page.dart';
import '../../../pdf_import_export/services/pdf_service.dart';
import '../../../document/domain/page_background.dart';
import '../../domain/models/stroke.dart';

class RegionCapture {
  RegionCapture._();

  /// [region] 為頁面座標；[scale] 為每個頁面單位對應的像素數 (太大會自動調降)
  static Future<Uint8List?> renderPng({
    required NotePage page,
    required List<Stroke> strokes,
    required ui.Rect region,
    required double scale,
  }) async {
    if (region.width < 1 || region.height < 1) return null;

    // 單邊 / 總像素有上限，超過就降倍率
    double s = scale;
    for (int i = 0;
        i < 30 && !TilePlanner.fits(region.width, region.height, s);
        i++) {
      s *= 0.85;
    }
    final int pw = math.max(1, (region.width * s).round());
    final int ph = math.max(1, (region.height * s).round());

    PdfTile? tile;
    ui.Picture? picture;
    ui.Image? image;
    try {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.scale(pw / region.width, ph / region.height);
      canvas.translate(-region.left, -region.top);
      canvas.clipRect(region);

      final pageRect = ui.Rect.fromLTWH(0, 0, page.width, page.height);
      // 整個輸出範圍先鋪不透明白底，PNG 不會有任何透明像素 (圖片 / PDF 有透明處也一樣)
      canvas.drawRect(region, ui.Paint()..color = const ui.Color(0xFFFFFFFF));
      // 空白頁：再鋪上這一頁自己的紙張顏色
      if (page.isBlank) {
        PageBackgroundPainter.paintPaper(canvas, pageRect, page.background);
      }

      // 底圖
      final imagePaint = ui.Paint()..filterQuality = ui.FilterQuality.medium;
      if (page.pdfFilePath != null && page.pdfPageNumber != null) {
        tile = await PdfService.renderRegion(
          page.pdfFilePath!,
          page.pdfPageNumber!,
          s,
          region,
        );
        if (tile != null) {
          canvas.drawImageRect(
            tile.image,
            ui.Rect.fromLTWH(
              0,
              0,
              tile.image.width.toDouble(),
              tile.image.height.toDouble(),
            ),
            tile.rect,
            imagePaint,
          );
        } else if (page.cachedBackgroundImage != null) {
          // 高清渲染失敗 → 退而用畫面上現成的底圖
          final bg = page.cachedBackgroundImage!;
          canvas.drawImageRect(
            bg,
            ui.Rect.fromLTWH(0, 0, bg.width.toDouble(), bg.height.toDouble()),
            pageRect,
            imagePaint,
          );
        }
      } else {
        // 空白頁格線 (與畫布顯示一致)
        PageBackgroundPainter.paintGrid(
          canvas,
          ui.Size(page.width, page.height),
          page.background,
          visible: region,
        );
      }

      // 使用者放上去的圖片 (在筆劃之下、裁在紙張內)
      if (page.images.isNotEmpty) {
        canvas.save();
        canvas.clipRect(pageRect);
        for (final img in page.images) {
          if (!img.rect.overlaps(region)) continue;
          await PageImageStore.ensureLoaded(img);
          final bmp = img.image;
          if (bmp == null) continue;
          canvas.drawImageRect(
            bmp,
            ui.Rect.fromLTWH(0, 0, bmp.width.toDouble(), bmp.height.toDouble()),
            img.rect,
            imagePaint,
          );
        }
        canvas.restore();
      }

      // 全部筆劃 (圈選範圍內看得到的都算)
      final strokePaint = ui.Paint()..style = ui.PaintingStyle.fill;
      for (final stroke in strokes) {
        if (!stroke.bounds.inflate(stroke.settings.size).overlaps(region)) continue;
        strokePaint.color = stroke.color;
        canvas.drawPath(stroke.outlinePath, strokePaint);
      }

      picture = recorder.endRecording();
      image = await picture.toImage(pw, ph);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } finally {
      tile?.image.dispose();
      picture?.dispose();
      image?.dispose();
    }
  }
}
