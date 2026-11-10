// lib/features/canvas/presentation/widgets/canvas_painters.dart
import 'dart:math';
import 'package:cft_note/features/canvas/domain/models/tools.dart';
import 'package:flutter/material.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import '../controllers/canvas_controller.dart';

class HistoryLayerPainter extends CustomPainter {
  final CanvasController controller;
  // 監聽控制器本身 + 縮放/平移訊號 (雙指縮放時整頁不重建，只重繪畫布)
  HistoryLayerPainter(this.controller)
    : super(repaint: Listenable.merge([controller, controller.viewSignal]));

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.transform(controller.transformation.storage);

    // 單頁模式只畫目前頁；連續模式畫所有與畫面重疊的頁面
    final Rect view = MatrixUtils.inverseTransformRect(
      controller.transformation,
      Offset.zero & size,
    );
    final indices = controller.visiblePageIndices(view);
    final continuous = controller.isContinuous;

    for (final i in indices) {
      final origin = controller.pageOrigin(i);
      canvas.save();
      canvas.translate(origin.dx, origin.dy);
      _paintPage(canvas, i, continuous);
      canvas.restore();
    }

    canvas.restore();

    if (continuous) controller.trimPictureCache(indices.toSet());
  }

  void _paintPage(Canvas canvas, int index, bool continuous) {
    final page = controller.pages[index];
    final double pageWidth = page.width;
    final double pageHeight = page.height;
    final Rect pageRect = Rect.fromLTWH(0, 0, pageWidth, pageHeight);

    // 1. 底層陰影 (連續模式頁面很多，且有間隔襯底，不畫模糊陰影以保持順暢)
    // 放大後紙張邊緣多半在畫面外，且模糊半徑會跟著放大 → 高倍率時略過，避免超大離屏緩衝
    if (!continuous && controller.zoomPercentage < 250) {
      final shadowPaint = Paint()
        ..color = Colors.black.withAlpha(50)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16);
      canvas.drawRect(pageRect.shift(const Offset(0, 6)), shadowPaint);
    }

    // 2. 純白實心底紙
    canvas.drawRect(pageRect, Paint()..color = Colors.white);

    // 3. 繪製高解析度 PDF
    final bgImage = page.cachedBackgroundImage;
    if (bgImage != null) {
      // ★ 改用 FilterQuality.medium，消除文字邊緣的糊化效果，邊緣字體極為銳利
      final imagePaint = Paint()..filterQuality = FilterQuality.medium;

      canvas.drawImageRect(
        bgImage,
        Rect.fromLTWH(0, 0, bgImage.width.toDouble(), bgImage.height.toDouble()),
        pageRect,
        imagePaint,
      );
    } else if (page.pdfFilePath == null) {
      // 空白頁橫線 (PDF 頁面底圖載入中時保持純白，不閃橫線)
      final linePaint = Paint()
        ..color = Colors.grey.withAlpha(40)
        ..strokeWidth = 1.0;
      for (double y = 40; y < pageHeight; y += 32) {
        canvas.drawLine(Offset(20, y), Offset(pageWidth - 20, y), linePaint);
      }
    }

    // 3.5 ★ 分塊高清圖塊：只覆蓋可視區域，疊在低解析度底圖之上
    final detail = page.detailImage;
    final detailRect = page.detailRect;
    if (detail != null && detailRect != null) {
      canvas.drawImageRect(
        detail,
        Rect.fromLTWH(0, 0, detail.width.toDouble(), detail.height.toDouble()),
        detailRect,
        Paint()..filterQuality = FilterQuality.low, // 圖塊與螢幕約 1:1，不需 mipmap
      );
    }

    // 3.8 使用者放上去的圖片 (在底圖之上、筆劃之下；超出紙張的部分裁掉)
    if (page.images.isNotEmpty) {
      canvas.save();
      canvas.clipRect(pageRect);
      final photoPaint = Paint()..filterQuality = FilterQuality.medium;
      for (final img in page.images) {
        final bmp = img.image;
        if (bmp == null) {
          controller.requestImage(img); // 尚未解碼 → 背景載入 (載入中 / 檔案遺失先畫灰底)
          canvas.drawRect(
            img.rect,
            Paint()..color = Colors.grey.withAlpha(img.missing ? 90 : 40),
          );
          if (img.missing) {
            final x = Paint()
              ..color = Colors.grey
              ..strokeWidth = 2
              ..style = PaintingStyle.stroke;
            canvas.drawLine(img.rect.topLeft, img.rect.bottomRight, x);
            canvas.drawLine(img.rect.topRight, img.rect.bottomLeft, x);
          }
          continue;
        }
        canvas.drawImageRect(
          bmp,
          Rect.fromLTWH(0, 0, bmp.width.toDouble(), bmp.height.toDouble()),
          img.rect,
          photoPaint,
        );
      }
      canvas.restore();
    }

    // 4. ★ 核心硬體裁切：筆劃超出紙張部分由 GPU 自然切除，不顯現在工作桌上
    canvas.save();
    canvas.clipRect(pageRect);

    // 5. 繪製歷史手寫筆畫
    final picture = controller.pictureFor(index);
    if (picture != null) {
      canvas.drawPicture(picture);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class ActiveLayerPainter extends CustomPainter {
  final CanvasController controller;
  // ★ 關鍵：只監聽 activeRepaintNotifier，下筆時完全不驚動底下的 PDF！
  // 同時監聽 viewSignal：縮放時套索框、橡皮擦圈才會跟著畫布移動
  ActiveLayerPainter(this.controller)
    : super(
        repaint: Listenable.merge([
          controller.activeRepaintNotifier,
          controller.viewSignal,
        ]),
      );

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.transform(controller.transformation.storage);
    // 連續模式：筆劃、套索、橡皮擦都是「目前編輯頁」的座標，移到該頁的位置再畫
    final Offset pageOrigin = controller.currentPageOrigin;
    canvas.translate(pageOrigin.dx, pageOrigin.dy);

    final Rect pageRect = Rect.fromLTWH(0, 0, controller.currentPage.width, controller.currentPage.height);

    // ★ 裁切筆劃在紙張內 (圖片選取框不裁切：握把可能在紙張邊緣外)
    canvas.save();
    canvas.clipRect(pageRect);

    // 正在書寫的筆劃
    if (controller.currentPoints.isNotEmpty) {
      final outlinePoints = getStroke(
        controller.currentPoints,
        options: StrokeOptions(
          size: controller.brush.size,
          thinning: controller.brush.thinning,
          smoothing: controller.brush.smoothing,
          streamline: controller.brush.streamline,
          simulatePressure: false,
        ),
      );

      final paint = Paint()
        ..color = controller.strokeColor
        ..style = PaintingStyle.fill;

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

    // 正在畫的套索
    if (controller.currentLassoDrawing.isNotEmpty) {
      final paint = Paint()
        ..color = Colors.blueAccent.withAlpha(150)
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke;

      final path = Path()..moveTo(controller.currentLassoDrawing.first.dx, controller.currentLassoDrawing.first.dy);
      for (int i = 1; i < controller.currentLassoDrawing.length; i++) {
        path.lineTo(controller.currentLassoDrawing[i].dx, controller.currentLassoDrawing[i].dy);
      }
      canvas.drawPath(path, paint);
    }

    // 已閉合的套索
    if (controller.selectedLassoPolygon.isNotEmpty) {
      final dashedPaint = Paint()
        ..color = Colors.blueAccent
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;

      final path = Path()
        ..moveTo(controller.selectedLassoPolygon.first.dx, controller.selectedLassoPolygon.first.dy);
      for (int i = 1; i < controller.selectedLassoPolygon.length; i++) {
        path.lineTo(controller.selectedLassoPolygon[i].dx, controller.selectedLassoPolygon[i].dy);
      }
      path.close();
      _drawDashedPath(canvas, path, dashedPaint, dashWidth: 6.0, dashSpace: 4.0);
    }
 if (controller.currentTool == DrawingTool.eraser && controller.eraserPosition != null) {
      final center = controller.eraserPosition!;
      final radius = controller.currentEraseRadius;

      // 1. 半透明灰色填充
      final fillPaint = Paint()
        ..color = Colors.black.withAlpha(25)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(center, radius, fillPaint);

      // 2. 深灰色細邊框線 (筆寬隨縮放自適應)
      final borderPaint = Paint()
        ..color = Colors.black54
        ..strokeWidth = 1.0 / (controller.zoomPercentage / 100)
        ..style = PaintingStyle.stroke;
      canvas.drawCircle(center, radius, borderPaint);
    }
    canvas.restore(); // 結束紙張裁切

    // 圖片模式：選取框 + 握把
    final selected = controller.selectedImage;
    if (controller.currentTool == DrawingTool.image && selected != null) {
      _paintImageSelection(canvas, selected.rect);
    }
    canvas.restore();
  }

  /// 長方形外框；右下角 = 縮放握把，右上角 = 刪除握把 (大小以螢幕像素為準)
  void _paintImageSelection(Canvas canvas, Rect rect) {
    final z = controller.zoomPercentage / 100;
    final r = CanvasController.imageHandleDrawScreen / z;
    final hair = 1.0 / z;

    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.blueAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0 / z,
    );

    void handle(Offset c, Color color) {
      canvas.drawCircle(c, r + 1.5 * hair, Paint()..color = Colors.white);
      canvas.drawCircle(c, r, Paint()..color = color);
    }

    final icon = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.0 * hair
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final k = r * 0.42;

    // 刪除 (右上角)：紅底白叉
    final d = rect.topRight;
    handle(d, Colors.redAccent);
    canvas.drawLine(d + Offset(-k, -k), d + Offset(k, k), icon);
    canvas.drawLine(d + Offset(-k, k), d + Offset(k, -k), icon);

    // 縮放 (右下角)：藍底白色斜向雙箭頭
    final s = rect.bottomRight;
    handle(s, Colors.blueAccent);
    final a = s + Offset(-k, -k), b = s + Offset(k, k), h = k * 0.9;
    canvas.drawLine(a, b, icon);
    canvas.drawLine(a, a + Offset(h, 0), icon);
    canvas.drawLine(a, a + Offset(0, h), icon);
    canvas.drawLine(b, b + Offset(-h, 0), icon);
    canvas.drawLine(b, b + Offset(0, -h), icon);
  }

  void _drawDashedPath(Canvas canvas, Path path, Paint paint,
      {required double dashWidth, required double dashSpace}) {
    for (final metric in path.computeMetrics()) {
      double distance = 0.0;
      while (distance < metric.length) {
        final double length = min(dashWidth, metric.length - distance);
        final Path extract = metric.extractPath(distance, distance + length);
        canvas.drawPath(extract, paint);
        distance += dashWidth + dashSpace;
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}