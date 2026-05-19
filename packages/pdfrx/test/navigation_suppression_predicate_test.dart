import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  group('navigationSuppressedByAnnotation', () {
    test('false when annotation mode is off, regardless of tool', () {
      expect(navigationSuppressedByAnnotation(false, null), isFalse);
      expect(navigationSuppressedByAnnotation(false, PdfAnnotationTool.pen), isFalse);
      expect(navigationSuppressedByAnnotation(false, PdfAnnotationTool.hand), isFalse);
    });

    test('false when annotation mode is on but the hand tool is active', () {
      expect(navigationSuppressedByAnnotation(true, PdfAnnotationTool.hand), isFalse);
    });

    test('true when annotation mode is on and a drawing tool is active', () {
      expect(navigationSuppressedByAnnotation(true, PdfAnnotationTool.pen), isTrue);
      expect(navigationSuppressedByAnnotation(true, PdfAnnotationTool.highlighter), isTrue);
      expect(navigationSuppressedByAnnotation(true, PdfAnnotationTool.eraser), isTrue);
      expect(navigationSuppressedByAnnotation(true, PdfAnnotationTool.stamp), isTrue);
    });
  });
}
