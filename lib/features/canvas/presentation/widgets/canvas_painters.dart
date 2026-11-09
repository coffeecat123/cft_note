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

    final double pageWidth = controller.currentPage.width;
    final double pageHeight = controller.currentPage.height;
    final Rect pageRect = Rect.fromLTWH(0, 0, pageWidth, pageHeight);

    // 1. 底層陰影
    final shadowPaint = Paint()
      ..color = Colors.black.withAlpha(50)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16);
    // 放大後紙張邊緣多半在畫面外，且模糊半徑會跟著放大 → 高倍率時略過，避免超大離屏緩衝
    if (controller.zoomPercentage < 250) {
      canvas.drawRect(pageRect.shift(const Offset(0, 6)), shadowPaint);
    }

    // 2. 純白實心底紙
    canvas.drawRect(pageRect, Paint()..color = Colors.white);

    // 3. 繪製高解析度 PDF
    final bgImage = controller.currentPage.cachedBackgroundImage;
    if (bgImage != null) {
      // ★ 改用 FilterQuality.medium，消除文字邊緣的糊化效果，邊緣字體極為銳利
      final imagePaint = Paint()..filterQuality = FilterQuality.medium;

      canvas.drawImageRect(
        bgImage,
        Rect.fromLTWH(0, 0, bgImage.width.toDouble(), bgImage.height.toDouble()),
        pageRect,
        imagePaint,
      );
    } else {
      // 空白頁橫線
      final linePaint = Paint()
        ..color = Colors.grey.withAlpha(40)
        ..strokeWidth = 1.0;
      for (double y = 40; y < pageHeight; y += 32) {
        canvas.drawLine(Offset(20, y), Offset(pageWidth - 20, y), linePaint);
      }
    }

    // 3.5 ★ 分塊高清圖塊：只覆蓋可視區域，疊在低解析度底圖之上
    final detail = controller.currentPage.detailImage;
    final detailRect = controller.currentPage.detailRect;
    if (detail != null && detailRect != null) {
      canvas.drawImageRect(
        detail,
        Rect.fromLTWH(0, 0, detail.width.toDouble(), detail.height.toDouble()),
        detailRect,
        Paint()..filterQuality = FilterQuality.low, // 圖塊與螢幕約 1:1，不需 mipmap
      );
    }

    // 4. ★ 核心硬體裁切：筆劃超出紙張部分由 GPU 自然切除，不顯現在工作桌上
    canvas.clipRect(pageRect);

    // 5. 繪製歷史手寫筆畫
    if (controller.cachedHistoryPicture != null) {
      canvas.drawPicture(controller.cachedHistoryPicture!);
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

    final Rect pageRect = Rect.fromLTWH(0, 0, controller.currentPage.width, controller.currentPage.height);

    // ★ 裁切筆劃在紙張內
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
    canvas.restore();
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