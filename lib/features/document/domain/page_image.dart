// lib/features/document/domain/page_image.dart
//
// 放在頁面上的「圖片」(照片 / 圖庫 / 檔案匯入)。
// 位置與大小用「頁面座標」，與筆劃相同；圖片檔本身存在 App 資料夾，
// 這裡只記錄檔名 (不存絕對路徑，iOS 重新安裝 / 更新後容器路徑會變)。
import 'dart:ui' as ui;

import '../../../core/algorithms/rot_frame.dart';

class PageImage {
  final String id;

  /// 在 cft_images 資料夾內的檔名
  final String fileName;

  /// 圖片在頁面上的矩形 (頁面座標，未旋轉時)
  ui.Rect rect;

  /// 繞 [rect] 中心的旋轉 (弧度，順時針為正)
  double rotation;

  // ---- 以下只存在記憶體 ----
  ui.Image? image;
  bool loading = false;
  bool missing = false; // 檔案不見 / 解碼失敗

  PageImage({
    required this.id,
    required this.fileName,
    required this.rect,
    this.rotation = 0.0,
    this.image,
  });

  RotFrame get frame => RotFrame(rect, rotation);

  /// 旋轉後的軸對齊外框
  ui.Rect get bounds => rotation == 0 ? rect : frame.bounds;

  /// 複製 (筆記本副本用)：共用同一個圖檔，解碼後的 ui.Image 各自持有
  PageImage copy() =>
      PageImage(id: id, fileName: fileName, rect: rect, rotation: rotation);

  Map<String, dynamic> toJson() => {
    'id': id,
    'file': fileName,
    'x': rect.left,
    'y': rect.top,
    'w': rect.width,
    'h': rect.height,
    if (rotation != 0) 'r': rotation,
  };

  factory PageImage.fromJson(Map<String, dynamic> json) {
    double n(String k) => (json[k] as num).toDouble();
    return PageImage(
      id: json['id'] as String,
      fileName: json['file'] as String,
      rect: ui.Rect.fromLTWH(n('x'), n('y'), n('w'), n('h')),
      rotation: (json['r'] as num?)?.toDouble() ?? 0.0,
    );
  }
}
