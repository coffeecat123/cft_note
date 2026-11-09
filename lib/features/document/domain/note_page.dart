// lib/features/document/domain/note_page.dart
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:cft_note/features/canvas/domain/models/stroke.dart';
import 'package:cft_note/features/canvas/domain/commands/canvas_command.dart';

class NotePage {
  final String id;
  List<Stroke> strokes;
  List<CanvasCommand> undoStack;
  List<CanvasCommand> redoStack;

  Uint8List? pdfImageBytes;
  ui.Image? cachedBackgroundImage;

  String? pdfFilePath;
  int? pdfPageNumber;
  double renderedScale;

  // ★ 分塊渲染：只覆蓋可視區域的高解析度圖塊 (座標為頁面座標)
  ui.Image? detailImage;
  ui.Rect? detailRect;
  double detailScale = 0; // 圖塊每個頁面單位對應的像素數

  double width;
  double height;

  NotePage({
    required this.id,
    List<Stroke>? strokes,
    List<CanvasCommand>? undoStack,
    List<CanvasCommand>? redoStack,
    this.pdfImageBytes,
    this.cachedBackgroundImage,
    this.pdfFilePath,
    this.pdfPageNumber,
    this.renderedScale = 4.0,
    this.width = 595.0,
    this.height = 842.0,
  })  : strokes = strokes ?? [],
        undoStack = undoStack ?? [],
        redoStack = redoStack ?? [];

  /// 深層複製：筆劃完全獨立。
  /// 不複製 undo/redo (命令物件指向原筆劃)，也不複製 ui.Image
  /// (影像需各自持有、各自 dispose，之後由 PDF 重新渲染)。
  NotePage copy() => NotePage(
    id: id,
    strokes: strokes.map((s) => s.copy()).toList(),
    pdfFilePath: pdfFilePath,
    pdfPageNumber: pdfPageNumber,
    renderedScale: renderedScale,
    width: width,
    height: height,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'width': width,
    'height': height,
    'pdfFilePath': pdfFilePath,
    'pdfPageNumber': pdfPageNumber,
    'strokes': strokes.map((s) => s.toJson()).toList(),
  };

  factory NotePage.fromJson(Map<String, dynamic> json) {
    return NotePage(
      id: json['id'] as String,
      width: (json['width'] as num?)?.toDouble() ?? 595.0,
      height: (json['height'] as num?)?.toDouble() ?? 842.0,
      pdfFilePath: json['pdfFilePath'] as String?,
      pdfPageNumber: json['pdfPageNumber'] as int?,
      strokes: (json['strokes'] as List? ?? [])
          .map((s) => Stroke.fromJson(s as Map<String, dynamic>))
          .toList(),
    );
  }
}