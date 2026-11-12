// lib/features/pdf_import_export/services/image_export_service.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:file_picker/file_picker.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:super_clipboard/super_clipboard.dart';

import '../../../core/i18n/app_strings.dart';

class ImageExportService {
  ImageExportService._();

  /// 讓使用者選位置存成 PNG；使用者取消回傳 false
  static Future<bool> savePng(Uint8List bytes, String fileName) async {
    final Uri? saveUri = await FilePicker.saveFile(
      dialogTitle: S.current.saveScreenshotTitle,
      fileName: fileName,
      bytes: bytes,
    );
    if (saveUri == null) return false;

    // 桌面平台 saveFile 只回傳路徑、不一定幫忙寫入 → 補寫一次 (與 PDF 匯出相同的保護)
    try {
      final file = File(saveUri.toFilePath());
      if (!await file.exists() || await file.length() == 0) {
        await file.writeAsBytes(bytes);
      }
    } catch (_) {}
    return true;
  }

  /// 先寫成暫存檔 (分享 / 存相簿都需要檔案路徑)
  static Future<File> _writeTemp(Uint8List bytes, String fileName) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// 開啟系統分享面板。iPad 需要 [origin] (按鈕位置) 才能定位彈出視窗。
  static Future<void> sharePng(
    Uint8List bytes,
    String fileName, {
    Rect? origin,
  }) async {
    final file = await _writeTemp(bytes, fileName);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'image/png')],
        subject: fileName,
        sharePositionOrigin: origin,
      ),
    );
  }

  /// 目前平台是否支援寫入系統剪貼簿
  static bool get canCopyImage => SystemClipboard.instance != null;

  /// 把 PNG 以「圖片」格式複製到系統剪貼簿；平台不支援回傳 false
  static Future<bool> copyPngToClipboard(Uint8List bytes) async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return false;
    final item = DataWriterItem();
    item.add(Formats.png(bytes));
    await clipboard.write([item]);
    return true;
  }

  /// 相簿只有手機有 (gal 不支援 Windows / Linux)
  static bool get canSaveToGallery => Platform.isAndroid || Platform.isIOS;

  /// 存到系統相簿 (「cft_note」相簿)；沒有權限或被拒絕回傳 false
  static Future<bool> saveToGallery(Uint8List bytes, String fileName) async {
    if (!await Gal.hasAccess()) {
      if (!await Gal.requestAccess()) return false;
    }
    final file = await _writeTemp(bytes, fileName);
    await Gal.putImage(file.path, album: 'cft_note');
    return true;
  }

  /// 把筆記本名稱轉成可用的檔名
  static String safeName(String name) =>
      name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
}
