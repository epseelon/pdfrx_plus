import 'dart:ui';

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

  test('annotationHighlighterColor / annotationHighlighterWidth defaults match documented values', () {
    final controller = PdfViewerController();
    expect(controller.annotationHighlighterColor, const Color(0xFFFFFF00));
    expect(controller.annotationHighlighterWidth, 12.0);
  });

  test('setAnnotationHighlighterColor / setAnnotationHighlighterWidth fire listenables only on change', () {
    final controller = PdfViewerController();

    var colorBumps = 0;
    var widthBumps = 0;
    controller.annotationHighlighterColorListenable.addListener(() => colorBumps++);
    controller.annotationHighlighterWidthListenable.addListener(() => widthBumps++);

    controller.setAnnotationHighlighterColor(const Color(0xFFFF69B4));
    controller.setAnnotationHighlighterColor(const Color(0xFFFF69B4));
    controller.setAnnotationHighlighterWidth(24.0);
    controller.setAnnotationHighlighterWidth(24.0);

    expect(colorBumps, 1);
    expect(widthBumps, 1);
    expect(controller.annotationHighlighterColor, const Color(0xFFFF69B4));
    expect(controller.annotationHighlighterWidth, 24.0);
  });

  test('enterAnnotationMode forwards highlighter overrides through to controller listenables', () async {
    final controller = PdfViewerController();

    await controller.enterAnnotationMode(
      tool: PdfAnnotationTool.pen,
      highlighterColor: const Color(0xFF00BFFF),
      highlighterWidth: 16.0,
    );

    expect(controller.annotationToolListenable.value, PdfAnnotationTool.pen);
    expect(controller.annotationHighlighterColor, const Color(0xFF00BFFF));
    expect(controller.annotationHighlighterWidth, 16.0);
  });
}
