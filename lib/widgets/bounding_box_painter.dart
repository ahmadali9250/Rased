import 'package:flutter/material.dart';

class BoundingBoxPainter extends CustomPainter {
  final List<Map<String, dynamic>> detections;

  BoundingBoxPainter({required this.detections});

  @override
  void paint(Canvas canvas, Size size) {
    final boxPaint = Paint()
      ..color = Colors.redAccent
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    final bgPaint = Paint()
      ..color = Colors.redAccent.withOpacity(0.8)
      ..style = PaintingStyle.fill;

    for (var d in detections) {
      final rect = Rect.fromLTRB(
        (d['x1'] as double) * size.width,
        (d['y1'] as double) * size.height,
        (d['x2'] as double) * size.width,
        (d['y2'] as double) * size.height,
      );
      canvas.drawRect(rect, boxPaint);

      final label = '${d['label']} ${((d['conf'] as double) * 100).toStringAsFixed(0)}%';
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      canvas.drawRect(
        Rect.fromLTWH(rect.left, rect.top - 20, tp.width + 8, 20),
        bgPaint,
      );
      tp.paint(canvas, Offset(rect.left + 4, rect.top - 18));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}