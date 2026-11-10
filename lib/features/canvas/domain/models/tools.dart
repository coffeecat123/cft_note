// lib/features/canvas/domain/models/tools.dart
enum DrawingTool {
  pen,
  eraser,
  lasso, // 新增套索
  image, // 圖片模式：點圖片可平移 / 縮放 / 刪除
}

/// 套索工具浮出的小選單種類
enum LassoMenuKind {
  none,

  /// 在圈選範圍內點一下：剪下 / 複製 / 刪除 / 截圖
  selection,

  /// 剪貼簿有內容時，在空白處點一下：貼上
  paste,

  /// 圈選範圍內沒有任何筆劃 / 圖片 (圈圈留著當截圖框)：點一下只有「截圖」
  region,
}
