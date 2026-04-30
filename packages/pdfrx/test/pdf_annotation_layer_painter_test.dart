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

void main() {
  group('InkPainter stroke caps', () {
    testWidgets('renders highlighter strokes with StrokeCap.round and StrokeJoin.round', (tester) async {
      final repaint = ValueNotifier<int>(0);
      final painter = InkPainter(
        strokes: [_stroke(kind: PdfInkAnnotationKind.highlighter, opacity: 0.35)],
        inFlightProvider: () => const <PdfInkAnnotation>[],
        eraserCursorProvider: () => null,
        eraserRadiusProvider: () => 10.0,
        repaint: repaint,
        pageWidth: 100.0,
        pageHeight: 100.0,
      );

      await tester.pumpWidget(
        Center(
          child: SizedBox(width: 100, height: 100, child: CustomPaint(painter: painter)),
        ),
      );

      // Highlighter strokes use rounded caps and joins to match pspdfkit's
      // wide-tipped-marker look. The earlier butt/miter "ruler-edge"
      // rendering produced visible square offshoots at lift-off points and
      // sharp corners on tight curves.
      expect(
        find.byType(CustomPaint),
        paints..something(
          (method, args) =>
              method == #drawPath &&
              (args[1] as Paint).strokeCap == StrokeCap.round &&
              (args[1] as Paint).strokeJoin == StrokeJoin.round,
        ),
      );

      repaint.dispose();
    });

    testWidgets('renders pen strokes with StrokeCap.round and StrokeJoin.round', (tester) async {
      final repaint = ValueNotifier<int>(0);
      final painter = InkPainter(
        strokes: [_stroke(kind: PdfInkAnnotationKind.pen)],
        inFlightProvider: () => const <PdfInkAnnotation>[],
        eraserCursorProvider: () => null,
        eraserRadiusProvider: () => 10.0,
        repaint: repaint,
        pageWidth: 100.0,
        pageHeight: 100.0,
      );

      await tester.pumpWidget(
        Center(
          child: SizedBox(width: 100, height: 100, child: CustomPaint(painter: painter)),
        ),
      );

      expect(
        find.byType(CustomPaint),
        paints..something(
          (method, args) =>
              method == #drawPath &&
              (args[1] as Paint).strokeCap == StrokeCap.round &&
              (args[1] as Paint).strokeJoin == StrokeJoin.round,
        ),
      );

      repaint.dispose();
    });
  });
}
