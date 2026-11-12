// lib/features/pdf_import_export/services/pdf_export_service.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Color, Offset, Rect, Size; // 使用原生 Offset / Rect / Size / Color
import 'package:file_picker/file_picker.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import '../../../core/i18n/app_strings.dart';
import '../../document/data/page_image_store.dart';
import '../../document/domain/page_background.dart';
import '../../shelf/domain/models/notebook.dart';

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
            File(page.pdfFilePath!).existsSync()) {
          if (!openedOriginalPdfs.containsKey(page.pdfFilePath!)) {
            final bytes = await File(page.pdfFilePath!).readAsBytes();
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
        // 2. 向量筆跡疊加：使用 drawPolygon 直接注入多邊形向量曲線
        // ============================================================
        for (final stroke in page.strokes) {
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

          if (outlinePoints.length >= 3) {
            // ★ 修正 2：符合 Flutter 3.27+ 色彩標準，消除 red/green/blue 棄用警告
            final color = stroke.color;
            final r = (color.r * 255.0).round().clamp(0, 255);
            final g = (color.g * 255.0).round().clamp(0, 255);
            final b = (color.b * 255.0).round().clamp(0, 255);
            final a = (color.a * 255.0).round().clamp(0, 255);
            final pdfColor = PdfColor(r, g, b, a);

            // ★ 修正 1：直接呼叫 drawPolygon 畫入向量多邊形 (徹底告別 PdfPath 與 moveTo 錯誤)
            graphics.drawPolygon(
              outlinePoints,
              brush: PdfSolidBrush(pdfColor),
            );
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