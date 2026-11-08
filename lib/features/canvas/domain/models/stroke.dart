// lib/features/canvas/domain/models/stroke.dart
import 'dart:ui';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'brush_settings.dart';

class Stroke {
  final List<PointVector> points;
  final Color color;
  final BrushSettings settings;

  Stroke({
    required this.points,
    required this.color,
    required this.settings,
  });

  Map<String, dynamic> toJson() => {
    'points': points.map((p) => {'x': p.x, 'y': p.y, 'p': p.pressure}).toList(),
    'color': color.toARGB32(),
    'size': settings.size,
    'thinning': settings.thinning,
    'smoothing': settings.smoothing,
    'streamline': settings.streamline,
  };

  factory Stroke.fromJson(Map<String, dynamic> json) {
    final pointsList = (json['points'] as List)
        .map((p) => PointVector(
              (p['x'] as num).toDouble(),
              (p['y'] as num).toDouble(),
              (p['p'] as num?)?.toDouble() ?? 0.5,
            ))
        .toList();

    return Stroke(
      points: pointsList,
      color: Color(json['color'] as int),
      settings: BrushSettings(
        size: (json['size'] as num?)?.toDouble() ?? 5.0,
        thinning: (json['thinning'] as num?)?.toDouble() ?? 0.6,
        smoothing: (json['smoothing'] as num?)?.toDouble() ?? 0.5,
        streamline: (json['streamline'] as num?)?.toDouble() ?? 0.5,
      ),
    );
  }
}