// lib/features/canvas/domain/commands/canvas_command.dart
// 命令模式 (Command Pattern)：Undo / Redo
// 從 CanvasController 抽出，同時消除 note_page.dart <-> canvas_controller.dart 的循環依賴。
import 'dart:ui' show Offset;
import 'package:perfect_freehand/perfect_freehand.dart';
import '../models/stroke.dart';

abstract class CanvasCommand {
  void undo(List<Stroke> strokes);
  void redo(List<Stroke> strokes);
}

// 繪畫命令
class DrawStrokeCommand implements CanvasCommand {
  final Stroke stroke;
  DrawStrokeCommand(this.stroke);
  @override
  void undo(List<Stroke> strokes) => strokes.remove(stroke);
  @override
  void redo(List<Stroke> strokes) => strokes.add(stroke);
}

// 批次新增命令 (貼上)
class AddStrokesCommand implements CanvasCommand {
  final List<Stroke> added;
  AddStrokesCommand(this.added);
  @override
  void undo(List<Stroke> strokes) {
    for (final s in added) {
      strokes.remove(s);
    }
  }

  @override
  void redo(List<Stroke> strokes) => strokes.addAll(added);
}

// 橡皮擦命令
// erasedItems 依「移除發生的順序」記錄 (key = 移除當下的索引)。
// 還原必須「反向重放」：最後移除的最先插回。
// (舊版用索引排序，一次拖曳內多次擦除時，筆劃會被插回錯誤位置)
class EraseStrokesCommand implements CanvasCommand {
  final List<MapEntry<int, Stroke>> erasedItems;
  EraseStrokesCommand(this.erasedItems);

  @override
  void undo(List<Stroke> strokes) {
    for (final entry in erasedItems.reversed) {
      if (entry.key <= strokes.length) {
        strokes.insert(entry.key, entry.value);
      } else {
        strokes.add(entry.value);
      }
    }
  }

  @override
  void redo(List<Stroke> strokes) {
    for (final entry in erasedItems) {
      strokes.remove(entry.value);
    }
  }
}

// 套索移動命令
class MoveStrokesCommand implements CanvasCommand {
  final List<Stroke> targetStrokes;
  final Offset delta;
  MoveStrokesCommand(this.targetStrokes, this.delta);
  @override
  void undo(List<Stroke> strokes) => _applyOffset(-delta);
  @override
  void redo(List<Stroke> strokes) => _applyOffset(delta);

  void _applyOffset(Offset offset) {
    for (final stroke in targetStrokes) {
      for (int i = 0; i < stroke.points.length; i++) {
        final p = stroke.points[i];
        stroke.points[i] = PointVector(
          p.x + offset.dx,
          p.y + offset.dy,
          p.pressure,
        );
      }
    }
  }
}

// 套索批次換色命令 (支援 Undo / Redo 復原舊顏色)
class ChangeStrokesColorCommand implements CanvasCommand {
  final List<Stroke> oldStrokes;
  final List<Stroke> newStrokes;

  ChangeStrokesColorCommand(this.oldStrokes, this.newStrokes);

  @override
  void undo(List<Stroke> strokes) {
    for (int i = 0; i < newStrokes.length; i++) {
      final index = strokes.indexOf(newStrokes[i]);
      if (index != -1) {
        strokes[index] = oldStrokes[i];
      }
    }
  }

  @override
  void redo(List<Stroke> strokes) {
    for (int i = 0; i < oldStrokes.length; i++) {
      final index = strokes.indexOf(oldStrokes[i]);
      if (index != -1) {
        strokes[index] = newStrokes[i];
      }
    }
  }
}
