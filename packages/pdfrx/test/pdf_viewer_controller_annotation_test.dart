import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  test('PdfViewerController.annotationModeListenable is readable before the PdfViewer is mounted', () {
    final controller = PdfViewerController();

    expect(controller.annotationModeListenable.value, isFalse);
  });

  test('PdfViewerController.canUndoListenable / canRedoListenable default to false pre-mount', () {
    final controller = PdfViewerController();

    expect(controller.canUndoListenable.value, isFalse);
    expect(controller.canRedoListenable.value, isFalse);
  });

  test('PdfViewerController.undo / redo are no-ops pre-mount', () {
    final controller = PdfViewerController();

    controller.undo();
    controller.redo();

    expect(controller.canUndoListenable.value, isFalse);
    expect(controller.canRedoListenable.value, isFalse);
  });
}
