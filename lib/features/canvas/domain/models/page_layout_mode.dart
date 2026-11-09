// lib/features/canvas/domain/models/page_layout_mode.dart

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

  String get label {
    switch (this) {
      case PageLayoutMode.single:
        return '單頁顯示';
      case PageLayoutMode.vertical:
        return '往下連續捲動';
      case PageLayoutMode.horizontal:
        return '往右連續捲動';
    }
  }
}
