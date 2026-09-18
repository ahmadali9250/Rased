import 'package:flutter/material.dart';

/// يرسم مربعات الكشف فوق معاينة الكاميرا.
///
/// تحسينات الأداء:
///  1. `shouldRepaint` صار يقارن فعلياً — الكود القديم كان `=> true` دائماً،
///     يعني إعادة رسم كاملة مع كل rebuild حتى لو ما تغيّر ولا مربع.
///  2. كائنات `Paint` مبنية مرة وحدة كـ static بدل إنشائها كل رسمة.
///  3. `TextPainter` مخزّن بـ cache حسب نص الليبل — بناء + layout للنص كان
///     أغلى جزء بالـ painter، وكان بيتكرر كل فريم لنفس النص تقريباً.
class BoundingBoxPainter extends CustomPainter {
  BoundingBoxPainter({required this.detections});

  final List<Map<String, dynamic>> detections;

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

  /// cache صغير للنصوص المرسومة — نفس الليبل بيتكرر بين الفريمات.
  static final Map<String, TextPainter> _textCache = <String, TextPainter>{};

  static TextPainter _textPainterFor(String label) {
    final cached = _textCache[label];
    if (cached != null) return cached;

    final tp = TextPainter(
      text: TextSpan(text: label, style: _labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();

    // حد أقصى بسيط حتى لا ينمو الـ cache بلا نهاية (النسب بتتغير باستمرار)
    if (_textCache.length > 64) _textCache.clear();
    _textCache[label] = tp;
    return tp;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (detections.isEmpty) return;

    for (final d in detections) {
      final x1 = (d['x1'] as num?)?.toDouble() ?? 0.0;
      final y1 = (d['y1'] as num?)?.toDouble() ?? 0.0;
      final x2 = (d['x2'] as num?)?.toDouble() ?? 0.0;
      final y2 = (d['y2'] as num?)?.toDouble() ?? 0.0;

      final rect = Rect.fromLTRB(
        x1 * size.width,
        y1 * size.height,
        x2 * size.width,
        y2 * size.height,
      );

      // تجاهل المربعات المنحلّة (عرض أو ارتفاع صفر)
      if (rect.width <= 1 || rect.height <= 1) continue;

      final rrect = RRect.fromRectAndRadius(rect, _boxRadius);
      canvas.drawRRect(rrect, _glowPaint);
      canvas.drawRRect(rrect, _boxPaint);

      final conf = (d['conf'] as num?)?.toDouble() ?? 0.0;
      final label = '${d['label']} ${(conf * 100).toStringAsFixed(0)}%';
      final tp = _textPainterFor(label);

      final labelWidth = tp.width + 14;
      final labelLeft = rect.left.clamp(0.0, (size.width - labelWidth).clamp(0.0, size.width));
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

  /// مقارنة فعلية بدل `=> true`.
  @override
  bool shouldRepaint(covariant BoundingBoxPainter old) {
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