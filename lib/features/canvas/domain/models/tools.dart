// lib/features/canvas/domain/models/tools.dart
enum DrawingTool {
  pen,
  eraser,
  lasso, // 新增套索
}

/// 套索工具浮出的小選單種類
enum LassoMenuKind {
  none,

  /// 在圈選範圍內點一下：剪下 / 複製 / 刪除 / 截圖
  selection,

  /// 剪貼簿有內容時，在空白處點一下：貼上
  paste,
}
