// lib/features/canvas/presentation/widgets/canvas_painters.dart
import 'dart:math';
import 'package:cft_note/features/canvas/domain/models/tools.dart';
import 'package:flutter/material.dart';
import '../../../../core/algorithms/rot_frame.dart';
import '../../../document/domain/page_background.dart';
import '../../domain/models/stroke.dart';
import '../../domain/models/stroke_geometry.dart';
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

    // 2. 實心底紙：空白頁用自己的紙張顏色；PDF 頁面維持純白 (底圖會蓋在上面)
    final bool isBlank = page.pdfFilePath == null;
    final PageBackground background = page.background;
    canvas.drawRect(
      pageRect,
      Paint()..color = isBlank ? background.color : Colors.white,
    );

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
    } else if (isBlank) {
      // 空白頁格線：橫線 / 直線 / 方格 (PDF 頁面底圖載入中時保持純白，不閃線)
      PageBackgroundPainter.paintGrid(
        canvas,
        Size(pageWidth, pageHeight),
        background,
      );
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
          canvas.save();
          _rotateAboutCenter(canvas, img.rect, img.rotation);
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
          canvas.restore();
          continue;
        }
        canvas.save();
        _rotateAboutCenter(canvas, img.rect, img.rotation);
        canvas.drawImageRect(
          bmp,
          Rect.fromLTWH(0, 0, bmp.width.toDouble(), bmp.height.toDouble()),
          img.rect,
          photoPaint,
        );
        canvas.restore();
      }
      canvas.restore();
    }

    // 4. ★ 核心硬體裁切：筆劃超出紙張部分由 GPU 自然切除，不顯現在工作桌上
    canvas.save();
    canvas.clipRect(pageRect);

    // 5. 繪製歷史手寫筆畫
    // 縮放 / 平移中：筆劃多的頁面改畫點陣快取 (成本與筆劃數量無關)；
    // 停手後 rasterFor 回傳 null，自動切回向量，靜止時依然銳利。
    final raster = controller.rasterFor(index);
    if (raster != null) {
      canvas.drawImageRect(
        raster,
        Rect.fromLTWH(0, 0, raster.width.toDouble(), raster.height.toDouble()),
        pageRect,
        Paint()..filterQuality = FilterQuality.low,
      );
    } else {
      final picture = controller.pictureFor(index);
      if (picture != null) {
        canvas.drawPicture(picture);
      }
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
      final strokePath = StrokeGeometry.pathFor(
        controller.currentPoints,
        controller.brush,
      );

      // 螢光筆：半透明疊色 (與完成後的筆劃同一份 Paint 規則)
      final paint = Stroke.paintFor(controller.strokeColor, controller.brush);

      // 與完成後的筆劃共用同一個產生器，放開筆時外觀不會跳
      canvas.drawPath(strokePath, paint);
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

    // 已閉合的套索 (調整大小模式下改畫外框 + 握把)
    if (controller.selectedLassoPolygon.isNotEmpty &&
        !controller.selectionTransformMode) {
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

      // 深色紙張上改用白色，橡皮擦圈才看得到
      final cp = controller.currentPage;
      final bool onDarkPaper =
          cp.isBlank && cp.background.color.computeLuminance() < 0.5;

      // 1. 半透明灰色填充
      final fillPaint = Paint()
        ..color = (onDarkPaper ? Colors.white : Colors.black).withAlpha(25)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(center, radius, fillPaint);

      // 2. 深灰色細邊框線 (筆寬隨縮放自適應)
      final borderPaint = Paint()
        ..color = onDarkPaper ? Colors.white70 : Colors.black54
        ..strokeWidth = 1.0 / (controller.zoomPercentage / 100)
        ..style = PaintingStyle.stroke;
      canvas.drawCircle(center, radius, borderPaint);
    }
    canvas.restore(); // 結束紙張裁切

    // 圖片模式：選取框 + 握把
    final selected = controller.selectedImage;
    if (controller.currentTool == DrawingTool.image && selected != null) {
      _paintFrameHandles(canvas, selected.frame);
    }
    // 套索「調整大小」：和圖片編輯一樣的外框 + 握把
    if (controller.currentTool == DrawingTool.lasso &&
        controller.selectionTransformMode) {
      _paintFrameHandles(canvas, controller.selectionFrame);
    }
    canvas.restore();
  }


  /// 旋轉外框；右下角 = 縮放握把 (以中心為基準)，上方圓形 = 旋轉握把，右上角 = 刪除握把
  /// (大小以螢幕像素為準)
  void _paintFrameHandles(Canvas canvas, RotFrame frame) {
    final z = controller.zoomPercentage / 100;
    final r = CanvasController.imageHandleDrawScreen / z;
    final hair = 1.0 / z;
    final corners = frame.corners;

    canvas.drawPath(
      Path()..addPolygon(corners, true),
      Paint()
        ..color = Colors.blueAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0 / z,
    );

    // 旋轉握把：從上邊中點拉一條線上去
    final topMid = frame.toScene(Offset(frame.rect.center.dx, frame.rect.top));
    final rot = frame.rotateHandle(CanvasController.imageRotateHandleScreen / z);
    canvas.drawLine(
      topMid,
      rot,
      Paint()
        ..color = Colors.blueAccent
        ..strokeWidth = 1.5 / z
        ..style = PaintingStyle.stroke,
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
    final d = corners[1];
    handle(d, Colors.redAccent);
    canvas.save();
    canvas.translate(d.dx, d.dy);
    canvas.rotate(frame.rotation);
    canvas.drawLine(Offset(-k, -k), Offset(k, k), icon);
    canvas.drawLine(Offset(-k, k), Offset(k, -k), icon);
    canvas.restore();

    // 縮放 (右下角)：藍底白色斜向雙箭頭 (跟著外框轉)
    final s = corners[2];
    handle(s, Colors.blueAccent);
    canvas.save();
    canvas.translate(s.dx, s.dy);
    canvas.rotate(frame.rotation);
    final a = Offset(-k, -k), b = Offset(k, k), h = k * 0.9;
    canvas.drawLine(a, b, icon);
    canvas.drawLine(a, a + Offset(h, 0), icon);
    canvas.drawLine(a, a + Offset(0, h), icon);
    canvas.drawLine(b, b + Offset(-h, 0), icon);
    canvas.drawLine(b, b + Offset(0, -h), icon);
    canvas.restore();

    // 旋轉 (上方)：橘底白色圓弧箭頭
    handle(rot, Colors.orangeAccent);
    final arcR = r * 0.5;
    canvas.drawArc(
      Rect.fromCircle(center: rot, radius: arcR),
      -pi * 0.15,
      pi * 1.5,
      false,
      icon,
    );
    final tip = rot + Offset(cos(-pi * 0.15), sin(-pi * 0.15)) * arcR;
    canvas.drawLine(tip, tip + Offset(-k * 0.2, -k * 0.95), icon);
    canvas.drawLine(tip, tip + Offset(k * 0.95, k * 0.1), icon);
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

/// 以 [rect] 中心為原點旋轉畫布 (圖片旋轉用)
void _rotateAboutCenter(Canvas canvas, Rect rect, double rotation) {
  if (rotation == 0) return;
  final c = rect.center;
  canvas.translate(c.dx, c.dy);
  canvas.rotate(rotation);
  canvas.translate(-c.dx, -c.dy);
}
