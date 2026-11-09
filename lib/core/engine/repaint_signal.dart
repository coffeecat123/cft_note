// lib/core/engine/repaint_signal.dart
import 'package:flutter/foundation.dart';

/// 輕量重繪訊號：只驅動 Painter / 小範圍 ListenableBuilder，
/// 不會讓整個頁面 (工具列、標籤列) 跟著 rebuild。
class RepaintSignal extends ChangeNotifier {
  void fire() => notifyListeners();
}
