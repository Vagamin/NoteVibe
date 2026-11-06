import 'package:flutter/material.dart';

/// One optical grid, stroke and bounds for every formatting command.
class FormatGlyph extends StatelessWidget {
  final String kind;
  const FormatGlyph(this.kind, {super.key});
  @override
  Widget build(BuildContext context) => SizedBox.square(dimension: 24,
    child: CustomPaint(painter: _GlyphPainter(kind, IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurfaceVariant)));
}

class _GlyphPainter extends CustomPainter {
  final String kind;
  final Color color;
  _GlyphPainter(this.kind, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final pen = Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 1.8..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round;
    void line(double x, double y, double a, double b) => canvas.drawLine(Offset(x,y), Offset(a,b), pen);
    switch (kind) {
      case 'bold':
        canvas.drawPath(Path()..moveTo(7,19)..lineTo(7,5)..lineTo(12,5)..cubicTo(18,5,18,12,12,12)..lineTo(7,12)..moveTo(12,12)..cubicTo(19,12,19,19,12,19)..lineTo(7,19), pen);
      case 'italic':
        line(10,5,18,5); line(6,19,14,19); line(14,5,10,19);
      case 'underline':
        canvas.drawPath(Path()..moveTo(7,5)..lineTo(7,12)..cubicTo(7,18,17,18,17,12)..lineTo(17,5), pen);
        line(5,21,19,21);
      case 'check':
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(4,5,16,14), const Radius.circular(3)), pen);
        canvas.drawPath(Path()..moveTo(8,12)..lineTo(11,15)..lineTo(16,9), pen);
      case 'list':
        for (final y in [6.0,12.0,18.0]) { line(10,y,20,y); canvas.drawCircle(Offset(5,y),1,pen); }
      case 'color':
        canvas.drawPath(Path()..moveTo(6,17)..lineTo(12,4)..lineTo(18,17)..moveTo(8,13)..lineTo(16,13), pen);
        line(4,21,20,21);
      case 'highlight':
        canvas.drawPath(Path()..moveTo(8,16)..lineTo(5,13)..lineTo(14,4)..lineTo(20,10)..lineTo(11,19)..close()..moveTo(7,11)..lineTo(13,17), pen);
        line(4,21,20,21);
      case 'undo':
      case 'redo':
        if (kind == 'redo') { canvas.translate(24,0); canvas.scale(-1,1); }
        canvas.drawPath(Path()..moveTo(9,5)..lineTo(4,10)..lineTo(9,15)..moveTo(4,10)..lineTo(14,10)..cubicTo(22,10,22,20,14,20), pen);
    }
  }
  @override
  bool shouldRepaint(covariant _GlyphPainter old) => old.kind != kind || old.color != color;
}
