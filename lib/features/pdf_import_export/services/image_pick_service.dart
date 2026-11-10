// lib/features/pdf_import_export/services/image_pick_service.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

enum ImagePickSource {
  /// 系統圖庫 (相簿)
  gallery,

  /// 系統檔案 (檔案管理員)
  files,
}

class ImagePickService {
  ImagePickService._();

  /// 挑一張圖片並回傳位元組；使用者取消回傳 null
  static Future<Uint8List?> pick(ImagePickSource source) async {
    switch (source) {
      case ImagePickSource.gallery:
        final x = await ImagePicker().pickImage(source: ImageSource.gallery);
        return x?.readAsBytes();
      case ImagePickSource.files:
        final files = await FilePicker.pickFiles(type: FileType.image);
        if (files.isEmpty || files.first.path == null) return null;
        return File(files.first.path!).readAsBytes();
    }
  }
}
