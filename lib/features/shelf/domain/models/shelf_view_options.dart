// lib/features/shelf/domain/models/shelf_view_options.dart

/// 書架顯示方式
enum ShelfViewMode {
  /// 小圖示 (卡片格狀)
  grid,

  /// 精簡清單 (類似檔案總管的「詳細資料」)
  list,
}

/// 排序依據
enum ShelfSortKey { modified, name }
