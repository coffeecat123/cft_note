// lib/features/pdf_import_export/services/clipboard_image_service.dart
//
// 讀取「系統剪貼簿」裡的圖片 (與 ImageExportService.copyPngToClipboard 相反方向)。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:super_clipboard/super_clipboard.dart';

class ClipboardImageService {
  ClipboardImageService._();

  static final List<SimpleFileFormat> _formats = [
    Formats.png,
    Formats.jpeg,
    Formats.webp,
    Formats.gif,
    Formats.bmp,
    Formats.tiff,
  ];

  /// 系統剪貼簿目前是否有圖片；平台不支援 / 讀取失敗回傳 false
  static Future<bool> hasImage() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return false;
    try {
      final reader = await clipboard.read();
      return _formats.any(reader.canProvide);
    } catch (e) {
      debugPrint('clipboard hasImage failed: $e');
      return false;
    }
  }

  /// 讀出剪貼簿圖片的位元組 (依 PNG → JPEG → … 順序取第一個有的格式)
  static Future<Uint8List?> readImage() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return null;
    try {
      final reader = await clipboard.read();
      for (final format in _formats) {
        if (!reader.canProvide(format)) continue;
        final done = Completer<Uint8List?>();
        final progress = reader.getFile(
          format,
          (file) async {
            try {
              final bytes = await file.readAll();
              if (!done.isCompleted) done.complete(bytes);
            } catch (_) {
              if (!done.isCompleted) done.complete(null);
            }
          },
          onError: (_) {
            if (!done.isCompleted) done.complete(null);
          },
        );
        if (progress == null) continue;
        final bytes = await done.future.timeout(
          const Duration(seconds: 15),
          onTimeout: () => null,
        );
        if (bytes != null && bytes.isNotEmpty) return bytes;
      }
    } catch (e) {
      debugPrint('clipboard readImage failed: $e');
    }
    return null;
  }
}
