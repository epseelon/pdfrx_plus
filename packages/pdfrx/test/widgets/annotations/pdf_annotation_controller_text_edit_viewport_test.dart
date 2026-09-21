import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_text_annotation.dart';
import 'package:pdfrx/src/widgets/annotations/text_edit_caret_pan.dart';

// `flutter test` lays text out in its square test font: every glyph is
// one em wide and one em tall, so the sizes below are exact arithmetic.
// 'rit.' at the default 18 pt is 72 x 18.

const Size _pageSize = Size(600, 800);

PdfTextAnnotation _text({
  String text = 'rit.',
  Rect rect = const Rect.fromLTWH(10, 20, 72, 18),
  double rotationDeg = 0,
}) => PdfTextAnnotation(
  id: 'text-1',
  pageIndex: 0,
  rectInPdfSpace: rect,
  rotationDeg: rotationDeg,
  text: text,
  autoSize: true,
  createdAt: DateTime.utc(2026, 9, 21, 10),
  updatedAt: DateTime.utc(2026, 9, 21, 10),
  creatorName: 'alice',
);

/// A controller in Text-tool mode as `alice`, holding [texts].
PdfAnnotationController _armed({List<PdfTextAnnotation> texts = const []}) {
  final controller = PdfAnnotationController();
  addTearDown(controller.dispose);
  controller.setAllWithStamps(strokes: const [], stamps: const [], attachments: const {}, texts: texts);
  controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.text);
  return controller;
}

void main() {
  group('Text tool: an edit in progress is listenable', () {
    test('true from the moment an edit opens until it commits', () {
      final controller = _armed();
      final seen = <bool>[];
      controller.textEditInProgressListenable.addListener(
        () => seen.add(controller.textEditInProgressListenable.value),
      );
      expect(controller.textEditInProgressListenable.value, isFalse);

      controller.createTextAt(pageIndex: 0, pdfPoint: const Offset(10, 20), pageSize: _pageSize);
      expect(controller.textEditInProgressListenable.value, isTrue);

      controller.updateTextEdit('rit.');
      controller.commitTextEdit();
      expect(controller.textEditInProgressListenable.value, isFalse);
      expect(seen, [true, false], reason: 'typing does not fire it');
    });

    test('false again when the edit is committed by a tool switch or by leaving annotation mode', () async {
      final controller = _armed(texts: [_text()]);
      controller.beginTextEdit('text-1', pageSize: _pageSize);
      expect(controller.textEditInProgressListenable.value, isTrue);
      controller.setTool(PdfAnnotationTool.pen);
      expect(controller.textEditInProgressListenable.value, isFalse);

      controller.setTool(PdfAnnotationTool.text);
      controller.beginTextEdit('text-1', pageSize: _pageSize);
      expect(controller.textEditInProgressListenable.value, isTrue);
      await controller.exitMode(onAnnotationsChanged: (_) async {});
      expect(controller.textEditInProgressListenable.value, isFalse);
    });

    test('false again when the edit is abandoned because its annotation vanished', () {
      final controller = _armed(texts: [_text()]);
      controller.beginTextEdit('text-1', pageSize: _pageSize);
      controller.clear();
      expect(controller.textEditInProgressListenable.value, isFalse);
    });
  });

  group('Text tool: where the caret is on the page', () {
    test('null while no edit is in progress', () {
      final controller = _armed(texts: [_text()]);
      expect(controller.textEditCaretInPage, isNull);
    });

    test('a new annotation has its caret at the tap point, one line tall', () {
      final controller = _armed();
      controller.createTextAt(pageIndex: 0, pdfPoint: const Offset(10, 20), pageSize: _pageSize);

      final caret = controller.textEditCaretInPage!;
      expect(caret.pageIndex, 0);
      expect(caret.rect.topLeft, const Offset(10, 20));
      expect(caret.rect.height, 18);
    });

    test('the caret follows the offset the editor reports, across lines', () {
      final controller = _armed(
        texts: [_text(text: 'rit.\npoco', rect: const Rect.fromLTWH(10, 20, 72, 36))],
      );
      controller.beginTextEdit('text-1', pageSize: _pageSize);

      controller.updateTextEditCaret(2);
      expect(controller.textEditCaretInPage!.rect, const Rect.fromLTWH(10 + 36, 20, 0, 18));

      // Offset 5 is the first position of the second line.
      controller.updateTextEditCaret(7);
      expect(controller.textEditCaretInPage!.rect, const Rect.fromLTWH(10 + 36, 20 + 18, 0, 18));
    });

    test('an offset past the end of the text is clamped to it', () {
      final controller = _armed(texts: [_text()]);
      controller.beginTextEdit('text-1', pageSize: _pageSize);
      controller.updateTextEditCaret(99);
      expect(controller.textEditCaretInPage!.rect, const Rect.fromLTWH(10 + 72, 20, 0, 18));
    });

    test('a caret change and a text change both notify, and only a real change does', () {
      final controller = _armed(texts: [_text()]);
      controller.beginTextEdit('text-1', pageSize: _pageSize);
      var notified = 0;
      controller.textEditCaretChangedListenable.addListener(() => notified++);

      controller.updateTextEditCaret(2);
      controller.updateTextEditCaret(2);
      expect(notified, 1);
      controller.updateTextEdit('rit. poco');
      expect(notified, 2);
    });

    test('the caret of a rotated annotation is reported as the box that bounds it on the page', () {
      // 90 degrees counter-clockwise about the box centre (46, 29): the
      // text runs up the page, so a caret at the end of the text sits at
      // the top of the rotated box and lies flat.
      final controller = _armed(texts: [_text(rotationDeg: 90)]);
      controller.beginTextEdit('text-1', pageSize: _pageSize);
      controller.updateTextEditCaret(4);

      final rect = controller.textEditCaretInPage!.rect;
      expect(rect.left, closeTo(46 - 9, 1e-9));
      expect(rect.right, closeTo(46 + 9, 1e-9));
      expect(rect.top, closeTo(29 - 36, 1e-9));
      expect(rect.height, closeTo(0, 1e-9));
    });
  });

  group('textEditCaretPanShift', () {
    test('zero when the keyboard never covers the caret: the view does not move at all', () {
      expect(textEditCaretPanShift(caret: const Rect.fromLTWH(100, 200, 0, 18), visibleBottom: 600), 0);
      // No keyboard at all.
      expect(textEditCaretPanShift(caret: const Rect.fromLTWH(100, 900, 0, 18), visibleBottom: 1000), 0);
    });

    test('lifts the view just enough to clear the keyboard, with a margin', () {
      // Caret bottom at 718, keyboard top at 600, margin 24: up by 142.
      expect(textEditCaretPanShift(caret: const Rect.fromLTWH(100, 700, 0, 18), visibleBottom: 600, margin: 24), -142);
    });

    test('a caret inside the margin above the keyboard is lifted by the difference only', () {
      expect(textEditCaretPanShift(caret: const Rect.fromLTWH(100, 570, 0, 18), visibleBottom: 600, margin: 24), -12);
    });

    test('never pushes the view down past where it started', () {
      // A caret above the top of the view would ask for a positive shift.
      expect(textEditCaretPanShift(caret: const Rect.fromLTWH(100, -50, 0, 18), visibleBottom: 600), 0);
    });

    test('a caret taller than the room above the keyboard keeps its bottom in view', () {
      expect(textEditCaretPanShift(caret: const Rect.fromLTWH(100, 0, 0, 400), visibleBottom: 100, margin: 24), -324);
    });
  });
}
