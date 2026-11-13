// lib/features/pdf_import_export/services/pdf_export_service.dart
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color, Offset, Rect, Size; // 使用原生 Offset / Rect / Size / Color
import 'package:file_picker/file_picker.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import '../../../core/i18n/app_strings.dart';
import '../../canvas/domain/models/stroke_geometry.dart';
import '../../document/data/page_image_store.dart';
import '../../document/domain/page_background.dart';
import '../../shelf/domain/models/notebook.dart';
import 'pdf_service.dart';

class PdfExportService {
  static PdfColor _pdfColor(Color c) => PdfColor(
        (c.r * 255.0).round().clamp(0, 255),
        (c.g * 255.0).round().clamp(0, 255),
        (c.b * 255.0).round().clamp(0, 255),
      );

  /// 空白頁背景：紙張底色 + 格線。
  /// 格線事先與紙色混合成不透明色，避免依賴 PDF 的透明度支援。
  static void _drawBlankBackground(
    PdfGraphics graphics,
    double width,
    double height,
    PageBackground bg,
  ) {
    graphics.drawRectangle(
      brush: PdfSolidBrush(_pdfColor(bg.color)),
      bounds: Rect.fromLTWH(0, 0, width, height),
    );
    final lines = PageBackgroundPainter.gridLines(Size(width, height), bg);
    if (lines.isEmpty) return;
    final pen = PdfPen(
      _pdfColor(Color.alphaBlend(bg.gridColor, bg.color)),
      width: 1,
    );
    for (final (from, to) in lines) {
      graphics.drawLine(pen, from, to);
    }
  }

  /// 將整本 Notebook 合成並匯出為「真向量、原字體無損」的 PDF
  static Future<bool> exportNotebook(Notebook notebook) async {
    final PdfDocument outputDoc = PdfDocument();
    final Map<String, PdfDocument> openedOriginalPdfs = {};

    try {
      for (int i = 0; i < notebook.pages.length; i++) {
        final page = notebook.pages[i];

        // 建立新 Section，1:1 精確設定頁面尺寸並設定 0 邊距 (保證座標無偏移)
        final PdfSection section = outputDoc.sections!.add();
        section.pageSettings.size = Size(page.width, page.height);
        section.pageSettings.margins.all = 0;

        final PdfPage targetExportPage = section.pages.add();
        final PdfGraphics graphics = targetExportPage.graphics;

        // ============================================================
        // 0. 空白頁：先畫紙張顏色與格線 (向量)，與畫布上看到的一致
        // ============================================================
        if (page.isBlank) {
          _drawBlankBackground(graphics, page.width, page.height, page.background);
        }

        // ============================================================
        // 1. 若為原始 PDF 頁面，注入原版向量範本 (100% 保留文字向量與可反白特性)
        // ============================================================
        if (page.pdfFilePath != null &&
            page.pdfPageNumber != null &&
            await PdfService.exists(page.pdfFilePath!)) {
          if (!openedOriginalPdfs.containsKey(page.pdfFilePath!)) {
            final bytes = await File(await PdfService.resolvePath(page.pdfFilePath!))
                .readAsBytes();
            openedOriginalPdfs[page.pdfFilePath!] = PdfDocument(inputBytes: bytes);
          }
          final originalDoc = openedOriginalPdfs[page.pdfFilePath!]!;
          final originalPage = originalDoc.pages[page.pdfPageNumber! - 1];

          final PdfTemplate template = originalPage.createTemplate();
          graphics.drawPdfTemplate(template, const Offset(0, 0));
        }

        // ============================================================
        // 1.5 使用者放上去的圖片 (在筆跡之下；超出紙張的部分 PDF 頁面本身就會裁掉)
        // ============================================================
        for (final img in page.images) {
          final file = await PageImageStore.fileFor(img);
          if (!await file.exists()) continue;
          graphics.drawImage(PdfBitmap(await file.readAsBytes()), img.rect);
        }

        // ============================================================
        // 2. 向量筆跡疊加：二次貝茲曲線 + 圓頭圓角粗線 (向量，無縫)
        // ============================================================
        for (final stroke in page.strokes) {
          // 中心線 = 二次貝茲曲線 (與畫面同一份平滑結果)，控制點很少，檔案小。
          final segs = StrokeGeometry.curve(stroke.points, stroke.settings);
          if (segs.isEmpty) continue;

          final color = stroke.color;
          final pdfColor = PdfColor(
            (color.r * 255.0).round().clamp(0, 255),
            (color.g * 255.0).round().clamp(0, 255),
            (color.b * 255.0).round().clamp(0, 255),
            (color.a * 255.0).round().clamp(0, 255),
          );

          // 圓頭圓角的粗線：折返處是圓的、線段重疊所以沒有縫。
          // 筆寬量化到 0.05，同寬度的筆共用，避免產生大量 PdfPen。
          final pens = <int, PdfPen>{};
          PdfPen penFor(double width) {
            final key = math.max(1, (width * 20).round());
            return pens.putIfAbsent(
              key,
              () => PdfPen(pdfColor, width: key / 20.0)
                ..lineCap = PdfLineCap.round
                ..lineJoin = PdfLineJoin.round,
            );
          }

          void drawSeg(StrokeSegment g, int depth) {
            // 半徑起訖差太多 (壓力變化大)：對半切，讓每段的粗細近似固定
            if (depth < 6 &&
                (g.r1 - g.r0).abs() >
                    math.max(0.05, math.max(g.r0, g.r1) * 0.06)) {
              final (a, b) = g.split();
              drawSeg(a, depth + 1);
              drawSeg(b, depth + 1);
              return;
            }
            final p0 = Offset(g.x0, g.y0);
            final p1 = Offset(g.x1, g.y1);
            final pen = penFor(g.r0 + g.r1); // = 2 × 平均半徑
            if (g.isLine) {
              final dx = g.x1 - g.x0, dy = g.y1 - g.y0;
              if (dx * dx + dy * dy < 1e-12) {
                // 單點 (點一下)：畫圓
                final r = (g.r0 + g.r1) / 2;
                graphics.drawEllipse(
                  Rect.fromCircle(center: p0, radius: r),
                  brush: PdfSolidBrush(pdfColor),
                );
              } else {
                graphics.drawLine(pen, p0, p1);
              }
            } else {
              // 二次 → 三次貝茲 (PDF 只有三次)：控制點往 c 靠 2/3
              final c = Offset(g.cx, g.cy);
              graphics.drawBezier(
                p0,
                p0 + (c - p0) * (2 / 3),
                p1 + (c - p1) * (2 / 3),
                p1,
                pen: pen,
              );
            }
          }

          for (final g in segs) {
            drawSeg(g, 0);
          }
        }
      }

      // 3. 儲存 PDF 資料流
      final List<int> pdfBytes = await outputDoc.save();

      // ★ 修正 3 & 4：移除 saveFile 棄用的 type 與 allowedExtensions 參數
      final Uri? saveUri = await FilePicker.saveFile(
        dialogTitle: S.current.exportDialogTitle,
        fileName: '${notebook.title}.pdf',
        bytes: Uint8List.fromList(pdfBytes),
      );

      if (saveUri == null) return false;

      // 針對 Windows 進行安全防護寫入
      try {
        final filePath = saveUri.toFilePath();
        final file = File(filePath);
        if (!await file.exists() || await file.length() == 0) {
          await file.writeAsBytes(pdfBytes);
        }
      } catch (_) {}

      return true;
    } finally {
      outputDoc.dispose();
      for (final doc in openedOriginalPdfs.values) {
        doc.dispose();
      }
    }
  }
}