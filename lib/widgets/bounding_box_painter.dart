import 'package:flutter/material.dart';

import '../services/tflite_service.dart' show LetterboxGeometry;

/// Draws detection boxes over the camera preview.
///
/// Boxes arrive normalised (0–1) in the *letterboxed model input* space. To
/// land on the preview they are mapped in two steps:
///  1. undo the letterbox (remove the grey padding, stretch to the content
///     rectangle) → 0–1 in the upright camera frame;
///  2. apply the same `BoxFit.cover` crop the preview uses, from the frame's
///     aspect ratio ([LetterboxGeometry.contentAspect]) to the widget size.
///
/// Without [geometry] the boxes are drawn straight onto the widget, which is
/// only correct when the camera frame happens to be square.
///
/// Performance notes kept from the previous version: real `shouldRepaint`,
/// static `Paint`s, cached `TextPainter`s.
class BoundingBoxPainter extends CustomPainter {
  BoundingBoxPainter({required this.detections, this.geometry});

  final List<Map<String, dynamic>> detections;
  final LetterboxGeometry? geometry;

  static final Paint _boxPaint = Paint()
    ..color = Colors.redAccent
    ..strokeWidth = 2.2
    ..style = PaintingStyle.stroke;

  static final Paint _glowPaint = Paint()
    ..color = Colors.redAccent.withValues(alpha: 0.12)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 8;

  static final Paint _bgPaint = Paint()
    ..color = Colors.black.withValues(alpha: 0.65)
    ..style = PaintingStyle.fill;

  static final Paint _labelBorderPaint = Paint()
    ..color = Colors.redAccent.withValues(alpha: 0.75)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1;

  static const Radius _boxRadius = Radius.circular(10);
  static const Radius _labelRadius = Radius.circular(8);
  static const double _labelHeight = 22.0;

  static const TextStyle _labelStyle = TextStyle(
    color: Colors.white,
    fontSize: 12,
    fontWeight: FontWeight.bold,
  );

  static final Map<String, TextPainter> _textCache = <String, TextPainter>{};

  static TextPainter _textPainterFor(String label) {
    final cached = _textCache[label];
    if (cached != null) return cached;

    final tp = TextPainter(
      text: TextSpan(text: label, style: _labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();

    if (_textCache.length > 64) _textCache.clear();
    _textCache[label] = tp;
    return tp;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (detections.isEmpty) return;

    // Step 2 constants: the upright frame drawn with BoxFit.cover.
    final g = geometry;
    double drawW = size.width, drawH = size.height, offX = 0, offY = 0;
    if (g != null && g.contentAspect > 0 && size.height > 0) {
      final widgetAspect = size.width / size.height;
      if (g.contentAspect > widgetAspect) {
        // Frame is wider than the widget: height fits, width overflows.
        drawH = size.height;
        drawW = drawH * g.contentAspect;
      } else {
        drawW = size.width;
        drawH = drawW / g.contentAspect;
      }
      offX = (size.width - drawW) / 2;
      offY = (size.height - drawH) / 2;
    }

    for (final d in detections) {
      double x1 = (d['x1'] as num?)?.toDouble() ?? 0.0;
      double y1 = (d['y1'] as num?)?.toDouble() ?? 0.0;
      double x2 = (d['x2'] as num?)?.toDouble() ?? 0.0;
      double y2 = (d['y2'] as num?)?.toDouble() ?? 0.0;

      // Step 1: letterbox → upright frame.
      if (g != null && g.contentWNorm > 0 && g.contentHNorm > 0) {
        x1 = ((x1 - g.padXNorm) / g.contentWNorm).clamp(0.0, 1.0);
        x2 = ((x2 - g.padXNorm) / g.contentWNorm).clamp(0.0, 1.0);
        y1 = ((y1 - g.padYNorm) / g.contentHNorm).clamp(0.0, 1.0);
        y2 = ((y2 - g.padYNorm) / g.contentHNorm).clamp(0.0, 1.0);
      }

      final rect = Rect.fromLTRB(
        offX + x1 * drawW,
        offY + y1 * drawH,
        offX + x2 * drawW,
        offY + y2 * drawH,
      );

      if (rect.width <= 1 || rect.height <= 1) continue;

      final rrect = RRect.fromRectAndRadius(rect, _boxRadius);
      canvas.drawRRect(rrect, _glowPaint);
      canvas.drawRRect(rrect, _boxPaint);

      final conf = (d['conf'] as num?)?.toDouble() ?? 0.0;
      final label = '${d['label']} ${(conf * 100).toStringAsFixed(0)}%';
      final tp = _textPainterFor(label);

      final labelWidth = tp.width + 14;
      final labelLeft = rect.left
          .clamp(0.0, (size.width - labelWidth).clamp(0.0, size.width));
      final labelTop = (rect.top - _labelHeight - 6)
          .clamp(0.0, (size.height - _labelHeight).clamp(0.0, size.height));

      final labelRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(labelLeft, labelTop, labelWidth, _labelHeight),
        _labelRadius,
      );

      canvas.drawRRect(labelRect, _bgPaint);
      canvas.drawRRect(labelRect, _labelBorderPaint);
      tp.paint(canvas, Offset(labelLeft + 7, labelTop + 3));
    }
  }

  @override
  bool shouldRepaint(covariant BoundingBoxPainter old) {
    if (old.geometry != geometry) return true;
    if (identical(old.detections, detections)) return false;
    if (old.detections.length != detections.length) return true;

    for (int i = 0; i < detections.length; i++) {
      final a = old.detections[i];
      final b = detections[i];
      if (a['x1'] != b['x1'] ||
          a['y1'] != b['y1'] ||
          a['x2'] != b['x2'] ||
          a['y2'] != b['y2'] ||
          a['conf'] != b['conf'] ||
          a['label'] != b['label']) {
        return true;
      }
    }
    return false;
  }
}
