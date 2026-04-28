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
}
