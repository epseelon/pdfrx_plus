import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_ink_annotation.dart';

void main() {
  group('PdfInkAnnotation.kind', () {
    test('defaults to PdfInkAnnotationKind.pen when omitted', () {
      final stroke = PdfInkAnnotation(
        pageIndex: 0,
        pointsInPdfSpace: const [Offset(0, 0), Offset(10, 10)],
        lineWidth: 1.0,
        strokeColor: const Color(0xFF000000),
        opacity: 1.0,
        createdAt: DateTime.utc(2024, 1, 1),
        updatedAt: DateTime.utc(2024, 1, 1),
      );

      expect(stroke.kind, PdfInkAnnotationKind.pen);
    });

    test('round-trips an explicitly set highlighter kind', () {
      final stroke = PdfInkAnnotation(
        pageIndex: 0,
        pointsInPdfSpace: const [Offset(0, 0), Offset(10, 10)],
        lineWidth: 12.0,
        strokeColor: const Color(0xFFFFFF00),
        opacity: 0.35,
        createdAt: DateTime.utc(2024, 1, 1),
        updatedAt: DateTime.utc(2024, 1, 1),
        kind: PdfInkAnnotationKind.highlighter,
      );

      expect(stroke.kind, PdfInkAnnotationKind.highlighter);
    });
  });
}
