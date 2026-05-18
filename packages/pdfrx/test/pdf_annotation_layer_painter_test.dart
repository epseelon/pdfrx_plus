import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_layer.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_ink_annotation.dart';

PdfInkAnnotation _stroke({
  required PdfInkAnnotationKind kind,
  Color color = const Color(0xFFFFFF00),
  double opacity = 1.0,
  double lineWidth = 12.0,
}) => PdfInkAnnotation(
  pageIndex: 0,
  pointsInPdfSpace: const [Offset(0, 0), Offset(50, 50)],
  lineWidth: lineWidth,
  strokeColor: color,
  opacity: opacity,
  createdAt: DateTime.utc(2024, 1, 1),
  updatedAt: DateTime.utc(2024, 1, 1),
  kind: kind,
);

/// Minimal painter that delegates to [paintInkStroke] so the `paints`
/// matcher can inspect the emitted `drawPath` call.
class _InkStrokeTestPainter extends CustomPainter {
  _InkStrokeTestPainter(this.stroke);

  final PdfInkAnnotation stroke;

  @override
  void paint(Canvas canvas, Size size) {
    paintInkStroke(canvas, stroke, scaleX: 1.0, scaleY: 1.0);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

Future<void> _pumpStroke(WidgetTester tester, PdfInkAnnotation stroke) => tester.pumpWidget(
  Center(
    child: SizedBox(width: 100, height: 100, child: CustomPaint(painter: _InkStrokeTestPainter(stroke))),
  ),
);

void main() {
  group('paintInkStroke', () {
    testWidgets('highlighter strokes paint with BlendMode.multiply and round caps/joins', (tester) async {
      await _pumpStroke(tester, _stroke(kind: PdfInkAnnotationKind.highlighter, opacity: 0.35));

      // Highlighter strokes multiply-blend so they tint rather than
      // cover the page content beneath, and use rounded caps/joins to
      // match pspdfkit's wide-tipped-marker look.
      expect(
        find.byType(CustomPaint),
        paints..something(
          (method, args) =>
              method == #drawPath &&
              (args[1] as Paint).blendMode == BlendMode.multiply &&
              (args[1] as Paint).strokeCap == StrokeCap.round &&
              (args[1] as Paint).strokeJoin == StrokeJoin.round,
        ),
      );
    });

    testWidgets('pen strokes paint with BlendMode.srcOver and round caps/joins', (tester) async {
      await _pumpStroke(tester, _stroke(kind: PdfInkAnnotationKind.pen));

      // Pen ink is opaque and covers the page content — default
      // source-over compositing, no multiply.
      expect(
        find.byType(CustomPaint),
        paints..something(
          (method, args) =>
              method == #drawPath &&
              (args[1] as Paint).blendMode == BlendMode.srcOver &&
              (args[1] as Paint).strokeCap == StrokeCap.round &&
              (args[1] as Paint).strokeJoin == StrokeJoin.round,
        ),
      );
    });
  });
}
