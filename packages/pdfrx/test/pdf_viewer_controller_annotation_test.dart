import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  test('PdfViewerController.annotationModeListenable is readable before the PdfViewer is mounted', () {
    final controller = PdfViewerController();

    expect(controller.annotationModeListenable.value, isFalse);
  });
}
