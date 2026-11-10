// lib/features/document/domain/page_image.dart
//
// 放在頁面上的「圖片」(照片 / 圖庫 / 檔案匯入)。
// 位置與大小用「頁面座標」，與筆劃相同；圖片檔本身存在 App 資料夾，
// 這裡只記錄檔名 (不存絕對路徑，iOS 重新安裝 / 更新後容器路徑會變)。
import 'dart:ui' as ui;

class PageImage {
  final String id;

  /// 在 cft_images 資料夾內的檔名
  final String fileName;

  /// 圖片在頁面上的矩形 (頁面座標)
  ui.Rect rect;

  // ---- 以下只存在記憶體 ----
  ui.Image? image;
  bool loading = false;
  bool missing = false; // 檔案不見 / 解碼失敗

  PageImage({
    required this.id,
    required this.fileName,
    required this.rect,
    this.image,
  });

  /// 複製 (筆記本副本用)：共用同一個圖檔，解碼後的 ui.Image 各自持有
  PageImage copy() => PageImage(id: id, fileName: fileName, rect: rect);

  Map<String, dynamic> toJson() => {
    'id': id,
    'file': fileName,
    'x': rect.left,
    'y': rect.top,
    'w': rect.width,
    'h': rect.height,
  };

  factory PageImage.fromJson(Map<String, dynamic> json) {
    double n(String k) => (json[k] as num).toDouble();
    return PageImage(
      id: json['id'] as String,
      fileName: json['file'] as String,
      rect: ui.Rect.fromLTWH(n('x'), n('y'), n('w'), n('h')),
    );
  }
}
