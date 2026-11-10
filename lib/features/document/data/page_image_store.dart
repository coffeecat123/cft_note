// lib/features/document/data/page_image_store.dart
//
// 圖片檔的匯入 / 讀取：
//  匯入：解碼 → 長邊縮到 [maxSide] 以內 → 轉成 PNG 存進 App 資料夾。
//        這樣 EXIF 旋轉已經套用、格式固定 (PDF 匯出才吃得下)、記憶體也有上限。
//  讀取：按需解碼成 ui.Image，頁面離開畫面時由 PageImageManager 釋放。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import '../domain/page_image.dart';

class ImportedImage {
  final String fileName;
  final ui.Image image;
  const ImportedImage(this.fileName, this.image);
}

class PageImageStore {
  PageImageStore._();

  static const int maxSide = 2560;
  static const String _dirName = 'cft_images';
  static Future<Directory>? _dirFuture;
  static int _seq = 0;

  static Future<Directory> _dir() => _dirFuture ??= () async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}$_dirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }();

  static String newId() => 'img_${DateTime.now().microsecondsSinceEpoch}_${_seq++}';

  static Future<File> fileFor(PageImage img) async {
    final dir = await _dir();
    return File('${dir.path}${Platform.pathSeparator}${img.fileName}');
  }

  /// 匯入使用者挑的圖片位元組；格式不支援 / 解碼失敗回傳 null
  static Future<ImportedImage?> importBytes(Uint8List bytes) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? desc;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      desc = await ui.ImageDescriptor.encoded(buffer);
      final w = desc.width, h = desc.height;
      int? tw, th;
      if (math.max(w, h) > maxSide) {
        if (w >= h) {
          tw = maxSide;
        } else {
          th = maxSide;
        }
      }
      codec = await desc.instantiateCodec(targetWidth: tw, targetHeight: th);
      final frame = await codec.getNextFrame();
      final image = frame.image;

      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        image.dispose();
        return null;
      }
      final dir = await _dir();
      final fileName = '${newId()}.png';
      await File('${dir.path}${Platform.pathSeparator}$fileName').writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      return ImportedImage(fileName, image);
    } catch (e, st) {
      debugPrint('importBytes failed: $e\n$st');
      return null;
    } finally {
      codec?.dispose();
      desc?.dispose();
      buffer?.dispose();
    }
  }

  /// 按需載入 [img] 的 ui.Image (已載入 / 載入中會直接返回)
  static Future<void> ensureLoaded(PageImage img) async {
    if (img.image != null || img.loading) return;
    img.loading = true;
    try {
      final file = await fileFor(img);
      if (!await file.exists()) {
        img.missing = true;
        return;
      }
      final codec = await ui.instantiateImageCodec(await file.readAsBytes());
      try {
        final frame = await codec.getNextFrame();
        img.image = frame.image;
      } finally {
        codec.dispose();
      }
    } catch (e) {
      debugPrint('load image failed: $e');
      img.missing = true;
    } finally {
      img.loading = false;
    }
  }
}
