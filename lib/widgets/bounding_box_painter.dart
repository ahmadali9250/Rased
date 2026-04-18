import 'package:flutter/material.dart';

class BoundingBoxPainter extends CustomPainter {
  final List<Map<String, dynamic>> detections;

  BoundingBoxPainter({required this.detections});

  @override
  void paint(Canvas canvas, Size size) {
    final boxPaint = Paint()
      ..color = Colors.redAccent
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke;

    final glowPaint = Paint()
      ..color = Colors.redAccent.withValues(alpha: 0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8;

    final bgPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.65)
      ..style = PaintingStyle.fill;

    for (var d in detections) {
      final rect = Rect.fromLTRB(
        (d['x1'] as double) * size.width,
        (d['y1'] as double) * size.height,
        (d['x2'] as double) * size.width,
        (d['y2'] as double) * size.height,
      );
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(10));
      canvas.drawRRect(rrect, glowPaint);
      canvas.drawRRect(rrect, boxPaint);

      final label = '${d['label']} ${((d['conf'] as double) * 100).toStringAsFixed(0)}%';
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final labelWidth = tp.width + 14;
      final labelHeight = 22.0;
      final labelLeft = rect.left.clamp(0.0, size.width - labelWidth);
      final labelTop = (rect.top - labelHeight - 6).clamp(0.0, size.height - labelHeight);
      final labelRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(labelLeft, labelTop, labelWidth, labelHeight),
        const Radius.circular(8),
      );

      canvas.drawRRect(labelRect, bgPaint);
      canvas.drawRRect(
        labelRect,
        Paint()
          ..color = Colors.redAccent.withValues(alpha: 0.75)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      tp.paint(canvas, Offset(labelLeft + 7, labelTop + 3));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}