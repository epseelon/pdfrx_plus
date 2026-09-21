import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

/// Smoke test that the public package surface re-exports the annotation
/// types integrators need to consume the highlighter feature without
/// reaching into `package:pdfrx/src/...`.
void main() {
  test('pdfrx exports PdfInkAnnotationKind, PdfAnnotationTool, PdfInkAnnotation', () {
    // Reading these symbols compiles only because they live in
    // `package:pdfrx/pdfrx.dart`. If a future refactor accidentally
    // hides them, this test will fail to compile.
    expect(PdfInkAnnotationKind.values, hasLength(2));
    expect(PdfAnnotationTool.values, contains(PdfAnnotationTool.highlighter));
    expect(PdfInkAnnotation, isNotNull);
  });

  test('pdfrx exports PdfTextAnnotation and its alignment', () {
    expect(PdfTextAnnotation, isNotNull);
    expect(PdfTextAnnotationAlign.values, hasLength(3));
    expect(kDefaultTextAnnotationFontSize, 18.0);
  });

  test('pdfrx exports the text layout seam and the font declaration', () {
    expect(layoutAnnotationText, isNotNull);
    expect(PdfAnnotationFontStyle.values, hasLength(4));
    expect(
      const PdfViewerParams(
        annotationFonts: PdfAnnotationFonts(families: [PdfAnnotationFontFamily('Serif')], defaultFamily: 'Serif'),
      ).annotationFonts.resolve('Unknown')?.name,
      'Serif',
    );
    expect(const PdfViewerParams().annotationFonts, const PdfAnnotationFonts.none());
  });
}
