// lib/features/canvas/domain/models/page_layout_mode.dart
import '../../../../core/i18n/app_strings.dart';

/// 頁面顯示方式
enum PageLayoutMode {
  /// 一次只顯示一頁 (預設)
  single,

  /// 所有頁面由上往下連續排列
  vertical,

  /// 所有頁面由左往右連續排列
  horizontal,
}

extension PageLayoutModeX on PageLayoutMode {
  bool get isContinuous => this != PageLayoutMode.single;

  /// 依目前語言取得名稱 (畫面在語言切換時會重建，所以直接讀 S.current 即可)
  String get label {
    final s = S.current;
    switch (this) {
      case PageLayoutMode.single:
        return s.layoutSingle;
      case PageLayoutMode.vertical:
        return s.layoutVertical;
      case PageLayoutMode.horizontal:
        return s.layoutHorizontal;
    }
  }
}
