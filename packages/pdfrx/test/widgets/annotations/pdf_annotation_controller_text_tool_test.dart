import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/annotation_text_layout.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_ink_annotation.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_rect_annotation.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_stamp_annotation.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_text_annotation.dart';

// `flutter test` lays text out in its square test font: every glyph is
// one em wide and one em tall, so the sizes below are exact arithmetic.
// 'rit.' at the default 18 pt is 72 x 18.

const Size _pageSize = Size(600, 800);

PdfTextAnnotation _text({
  String id = 'text-1',
  String text = 'rit.',
  Rect rect = const Rect.fromLTWH(10, 20, 72, 18),
  bool autoSize = true,
  String? creatorName = 'alice',
  DateTime? createdAt,
}) => PdfTextAnnotation(
  id: id,
  pageIndex: 0,
  rectInPdfSpace: rect,
  rotationDeg: 0,
  text: text,
  autoSize: autoSize,
  createdAt: createdAt ?? DateTime.utc(2026, 9, 21, 10),
  updatedAt: createdAt ?? DateTime.utc(2026, 9, 21, 10),
  creatorName: creatorName,
);

PdfRectAnnotation _rect({String id = 'rect-1'}) => PdfRectAnnotation(
  id: id,
  pageIndex: 0,
  rectInPdfSpace: const Rect.fromLTWH(300, 300, 50, 50),
  rotationDeg: 0,
  fillColor: const Color(0xFFFFFFFF),
  createdAt: DateTime.utc(2026, 9, 21, 9),
  updatedAt: DateTime.utc(2026, 9, 21, 9),
  creatorName: 'alice',
);

PdfStampAnnotation _stamp({String id = 'stamp-1'}) => PdfStampAnnotation(
  id: id,
  pageIndex: 0,
  rectInPdfSpace: const Rect.fromLTWH(200, 200, 24, 24),
  rotationDeg: 0,
  attachmentSha256: 'sha',
  contentType: 'image/svg+xml',
  createdAt: DateTime.utc(2026, 9, 21, 9),
  updatedAt: DateTime.utc(2026, 9, 21, 9),
  creatorName: 'alice',
);

PdfInkAnnotation _stroke() => PdfInkAnnotation(
  id: 'ink-1',
  pageIndex: 0,
  pointsInPdfSpace: const [Offset(40, 65), Offset(140, 65)],
  lineWidth: 2.0,
  strokeColor: const Color(0xFFFF3B30),
  opacity: 1.0,
  createdAt: DateTime.utc(2026, 9, 21, 9),
  updatedAt: DateTime.utc(2026, 9, 21, 9),
  creatorName: 'alice',
);

/// A controller in Text-tool mode as `alice`, holding [texts].
PdfAnnotationController _armed({
  List<PdfTextAnnotation> texts = const [],
  List<PdfRectAnnotation> rects = const [],
  List<PdfStampAnnotation> stamps = const [],
  List<PdfInkAnnotation> strokes = const [],
}) {
  final controller = PdfAnnotationController();
  controller.setAllWithStamps(strokes: strokes, stamps: stamps, attachments: {}, rects: rects, texts: texts);
  controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.text);
  return controller;
}

/// Taps at [at], types [text] and commits: one whole edit session.
String? _write(PdfAnnotationController controller, String text, {Offset at = const Offset(50, 60), String id = 'new'}) {
  final created = controller.createTextAt(
    pageIndex: 0,
    pdfPoint: at,
    pageSize: _pageSize,
    clock: () => DateTime.utc(2026, 9, 21, 11),
    idGenerator: () => id,
  );
  controller.updateTextEdit(text);
  controller.commitTextEdit();
  return created;
}

/// The `text` of every text annotation entry of [json], in order.
List<String> _exportedTexts(String json) => [
  for (final e in (jsonDecode(json) as Map<String, dynamic>)['annotations'] as List)
    if ((e as Map<String, dynamic>)['type'] == 'pspdfkit/text') e['text'] as String,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Text tool: create and commit', () {
    test('a tap creates auto-sized text in the default style and opens an edit', () {
      final controller = _armed();
      addTearDown(controller.dispose);

      final id = controller.createTextAt(
        pageIndex: 0,
        pdfPoint: const Offset(50, 60),
        pageSize: _pageSize,
        idGenerator: () => 'new',
      );

      expect(id, 'new');
      expect(controller.editingTextIdListenable.value, 'new');
      final editing = controller.editingText!;
      expect(editing.text, isEmpty, reason: 'no placeholder text is inserted');
      expect(editing.rectInPdfSpace.topLeft, const Offset(50, 60), reason: 'the tap point is the top-left corner');
      expect(editing.autoSize, isTrue);
      expect(editing.fontSize, 18);
      expect(editing.color, const Color(0xFF000000));
      expect(editing.align, PdfTextAnnotationAlign.left);
      expect((editing.bold, editing.italic, editing.underline), (false, false, false));
      expect(editing.creatorName, 'alice');
      // Not in the model, and no history, until the first commit.
      expect(controller.texts, isEmpty);
      expect(controller.canUndoListenable.value, isFalse);
    });

    test('committing typed text adds the annotation, boxed to its laid-out size, and selects it', () {
      final controller = _armed();
      addTearDown(controller.dispose);

      _write(controller, 'rit.');

      expect(controller.editingTextIdListenable.value, isNull);
      expect(controller.texts, hasLength(1));
      final committed = controller.texts.single;
      expect(committed.text, 'rit.');
      expect(committed.rectInPdfSpace, const Rect.fromLTWH(50, 60, 72, 18));
      expect(controller.selectedTextIdListenable.value, 'new');
      expect(controller.currentToolListenable.value, PdfAnnotationTool.text, reason: 'the tool stays armed');
    });

    test('a new annotation takes the default family of the declared fonts', () {
      final controller = _armed();
      addTearDown(controller.dispose);
      controller.annotationFonts = const PdfAnnotationFonts(
        families: [PdfAnnotationFontFamily('Academico')],
        defaultFamily: 'Academico',
      );

      _write(controller, 'rit.');

      expect(controller.texts.single.fontFamily, 'Academico');
    });

    test('committing empty or whitespace-only text discards a new annotation with no undo snapshot', () {
      final controller = _armed();
      addTearDown(controller.dispose);

      final id = _write(controller, ' \n  ');

      expect(id, isNotNull, reason: 'the annotation did exist while it was edited');
      expect(controller.texts, isEmpty);
      expect(controller.editingTextIdListenable.value, isNull);
      expect(controller.selectedTextIdListenable.value, isNull);
      expect(controller.canUndoListenable.value, isFalse);
    });

    test('a rubber band commits a text area at the dragged box and opens an edit, with no undo snapshot yet', () {
      final controller = _armed();
      addTearDown(controller.dispose);

      controller.startTextDraft(pageIndex: 0, anchorPdfPoint: const Offset(100, 100), pageSize: _pageSize);
      controller.updateTextDraft(const Offset(300, 180));
      expect(controller.inFlightTextAreaFor(0), const Rect.fromLTWH(100, 100, 200, 80));
      final id = controller.commitTextDraft(idGenerator: () => 'area');

      expect(id, 'area');
      expect(controller.inFlightTextAreaFor(0), isNull);
      expect(controller.editingTextIdListenable.value, 'area');
      expect(controller.editingText!.autoSize, isFalse);
      expect(controller.editingText!.rectInPdfSpace, const Rect.fromLTWH(100, 100, 200, 80));
      expect(controller.texts, isEmpty);
      expect(controller.canUndoListenable.value, isFalse);

      controller.updateTextEdit('watch');
      controller.commitTextEdit();
      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(100, 100, 200, 80));
      expect(controller.texts.single.autoSize, isFalse);
    });

    test('a rubber band is clamped to the page componentwise and never translated', () {
      final controller = _armed();
      addTearDown(controller.dispose);

      controller.startTextDraft(pageIndex: 0, anchorPdfPoint: const Offset(500, 700), pageSize: _pageSize);
      controller.updateTextDraft(const Offset(900, 1000));

      expect(controller.inFlightTextAreaFor(0), const Rect.fromLTWH(500, 700, 100, 100));
    });

    test('a sub-minimum rubber band is not a text area, and a cancelled one leaves nothing', () {
      final controller = _armed();
      addTearDown(controller.dispose);

      controller.startTextDraft(pageIndex: 0, anchorPdfPoint: const Offset(100, 100), pageSize: _pageSize);
      controller.updateTextDraft(const Offset(300, 105));
      expect(controller.inFlightTextAreaFor(0), isNotNull);
      expect(controller.commitTextDraft(), isNull);
      expect(controller.editingTextIdListenable.value, isNull);

      controller.startTextDraft(pageIndex: 0, anchorPdfPoint: const Offset(100, 100), pageSize: _pageSize);
      controller.updateTextDraft(const Offset(300, 300));
      controller.cancelTextDraft();
      expect(controller.inFlightTextAreaFor(0), isNull);
      expect(controller.editingTextIdListenable.value, isNull);
      expect(controller.texts, isEmpty);
      expect(controller.canUndoListenable.value, isFalse);
    });

    test('a text area whose text outgrows the dragged height is stored at the content height', () {
      final controller = _armed();
      addTearDown(controller.dispose);

      controller.startTextDraft(pageIndex: 0, anchorPdfPoint: const Offset(100, 100), pageSize: _pageSize);
      controller.updateTextDraft(const Offset(190, 120));
      controller.commitTextDraft();
      // 90 pt wide holds five 18 pt glyphs a line: ten glyphs are two lines.
      controller.updateTextEdit('aaaaabbbbb');
      controller.commitTextEdit();

      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(100, 100, 90, 36));
    });
  });

  group('Text tool: editing an existing annotation', () {
    test('an edit replaces the text and re-boxes auto-sized text', () {
      final controller = _armed(texts: [_text()]);
      addTearDown(controller.dispose);

      controller.selectText('text-1');
      controller.beginTextEdit('text-1', pageSize: _pageSize);
      expect(controller.editingText!.text, 'rit.');
      controller.updateTextEdit('ritard.');
      controller.commitTextEdit();

      expect(controller.texts.single.text, 'ritard.');
      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(10, 20, 126, 18));
      expect(controller.selectedTextIdListenable.value, 'text-1');
    });

    test('emptying an existing annotation deletes it in exactly one undo snapshot', () {
      final controller = _armed(texts: [_text()]);
      addTearDown(controller.dispose);

      controller.beginTextEdit('text-1', pageSize: _pageSize);
      controller.updateTextEdit('');
      controller.commitTextEdit();

      expect(controller.texts, isEmpty);
      expect(controller.selectedTextIdListenable.value, isNull);
      controller.undo();
      expect(controller.texts.single.text, 'rit.');
      expect(controller.canUndoListenable.value, isFalse, reason: 'exactly one snapshot was pushed');
    });

    test('an edit session is one undo step however many keystrokes it took', () {
      final controller = _armed(texts: [_text()]);
      addTearDown(controller.dispose);

      controller.beginTextEdit('text-1', pageSize: _pageSize);
      for (final typed in const ['rit', 'rita', 'ritar', 'ritard.']) {
        controller.updateTextEdit(typed);
      }
      controller.commitTextEdit();

      controller.undo();
      expect(controller.texts.single.text, 'rit.');
      expect(controller.canUndoListenable.value, isFalse);
      controller.redo();
      expect(controller.texts.single.text, 'ritard.');
    });

    test('creating a new annotation is one undo step, taken at commit', () {
      final controller = _armed();
      addTearDown(controller.dispose);

      _write(controller, 'rit.');
      expect(controller.canUndoListenable.value, isTrue);

      controller.undo();
      expect(controller.texts, isEmpty);
      expect(controller.canUndoListenable.value, isFalse);
      expect(
        controller.selectedTextIdListenable.value,
        isNull,
        reason: 'the selection pointed at a vanished annotation',
      );
    });

    test('an edit that changes nothing pushes no undo snapshot', () {
      final controller = _armed(texts: [_text()]);
      addTearDown(controller.dispose);

      controller.beginTextEdit('text-1', pageSize: _pageSize);
      controller.commitTextEdit();

      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(10, 20, 72, 18));
      expect(controller.canUndoListenable.value, isFalse);
    });

    test('undo and redo are disabled while an edit is in progress', () {
      final controller = _armed();
      addTearDown(controller.dispose);
      _write(controller, 'one', id: 'one');
      _write(controller, 'two', at: const Offset(50, 200), id: 'two');
      controller.undo();
      expect((controller.canUndoListenable.value, controller.canRedoListenable.value), (true, true));

      controller.beginTextEdit('one', pageSize: _pageSize);

      expect((controller.canUndoListenable.value, controller.canRedoListenable.value), (false, false));
      controller.undo();
      controller.redo();
      expect(controller.texts.map((t) => t.id), ['one'], reason: 'undo and redo are no-ops during an edit');

      controller.commitTextEdit();
      expect((controller.canUndoListenable.value, controller.canRedoListenable.value), (true, true));
    });

    test('the delete button path removes the annotation in one undo step', () {
      final controller = _armed(texts: [_text()]);
      addTearDown(controller.dispose);
      controller.selectText('text-1');

      controller.deleteText('text-1');

      expect(controller.texts, isEmpty);
      expect(controller.selectedTextIdListenable.value, isNull);
      controller.undo();
      expect(controller.texts.single.id, 'text-1');
      expect(controller.canUndoListenable.value, isFalse);
    });
  });

  group('Text tool: ownership, selection and the eraser', () {
    test("a bandmate's text annotation cannot be selected, edited or deleted", () {
      final controller = _armed(
        texts: [
          _text(id: 'mine'),
          _text(id: 'theirs', creatorName: 'bob'),
        ],
      );
      addTearDown(controller.dispose);

      controller.selectText('theirs');
      expect(controller.selectedTextIdListenable.value, isNull);
      controller.beginTextEdit('theirs', pageSize: _pageSize);
      expect(controller.editingTextIdListenable.value, isNull);
      controller.deleteText('theirs');
      expect(controller.texts.map((t) => t.id), ['mine', 'theirs']);

      // The guard is about ownership, not a selection that never works.
      controller.selectText('mine');
      expect(controller.selectedTextIdListenable.value, 'mine');
    });

    test('hit-test candidates come in reverse unified z-order, skipping foreign text and continuing underneath', () {
      final controller = _armed(
        texts: [
          _text(id: 'older', createdAt: DateTime.utc(2026, 9, 21, 10)),
          _text(id: 'theirs', creatorName: 'bob', createdAt: DateTime.utc(2026, 9, 21, 11)),
          _text(id: 'newer', createdAt: DateTime.utc(2026, 9, 21, 12)),
        ],
      );
      addTearDown(controller.dispose);

      expect(controller.selectableTextsForHitTest(0).map((t) => t.id), ['newer', 'older']);
      expect(controller.selectableTextsForHitTest(1), isEmpty);
    });

    test('selection is mutually exclusive across stamps, rectangles and text annotations', () {
      final controller = _armed(texts: [_text()], rects: [_rect()], stamps: [_stamp()]);
      addTearDown(controller.dispose);

      controller.selectRect('rect-1');
      controller.selectText('text-1');
      expect(controller.selectedTextIdListenable.value, 'text-1');
      expect(controller.selectedRectIdListenable.value, isNull);

      controller.selectStamp('stamp-1');
      expect(controller.selectedTextIdListenable.value, isNull);

      controller.selectText('text-1');
      expect(controller.selectedStampIdListenable.value, isNull);

      controller.selectRect('rect-1');
      expect(controller.selectedTextIdListenable.value, isNull);
    });

    test('setAllWithStamps clears the text selection', () {
      final controller = _armed(texts: [_text()]);
      addTearDown(controller.dispose);
      controller.selectText('text-1');
      expect(controller.selectedTextIdListenable.value, 'text-1');

      controller.setAllWithStamps(strokes: [], stamps: [], attachments: {}, texts: [_text()]);

      expect(controller.selectedTextIdListenable.value, isNull);
    });

    test('the eraser leaves text annotations alone', () {
      final controller = _armed(strokes: [_stroke()]);
      addTearDown(controller.dispose);
      _write(controller, 'rit.');
      controller.setTool(PdfAnnotationTool.eraser);

      // Straight through the stroke AND the text annotation (50,60)-(122,78).
      controller.startErase(pageIndex: 0, pdfPoint: const Offset(45, 65), radiusInPdfPoints: 10);
      controller.continueErase(pageIndex: 0, pdfPoint: const Offset(135, 65), radiusInPdfPoints: 10);
      controller.endErase();

      expect(controller.strokes, isEmpty, reason: 'the eraser did pass over this spot');
      expect(controller.texts.single.text, 'rit.');
    });
  });

  group('Text tool: what commits an edit, and what a commit does not do', () {
    test('switching tool commits the edit in progress and leaves nothing selected', () {
      final controller = _armed();
      addTearDown(controller.dispose);
      controller.createTextAt(pageIndex: 0, pdfPoint: const Offset(50, 60), pageSize: _pageSize);
      controller.updateTextEdit('rit.');

      controller.setTool(PdfAnnotationTool.pen);

      expect(controller.editingTextIdListenable.value, isNull);
      expect(controller.texts.single.text, 'rit.');
      expect(controller.selectedTextIdListenable.value, isNull);
    });

    test('a commit updates the in-memory model only: nothing is saved until annotation mode is left', () async {
      final controller = _armed();
      addTearDown(controller.dispose);
      final saved = <String>[];

      _write(controller, 'rit.');

      expect(controller.texts, hasLength(1));
      expect(controller.annotationModeListenable.value, isTrue);
      await controller.exitMode(onAnnotationsChanged: (json) async => saved.add(json));
      expect(saved, hasLength(1));
      expect(_exportedTexts(saved.single), ['rit.']);
    });

    test('leaving annotation mode commits the edit in progress BEFORE the export', () async {
      final controller = _armed();
      addTearDown(controller.dispose);
      final saved = <String>[];
      controller.createTextAt(pageIndex: 0, pdfPoint: const Offset(50, 60), pageSize: _pageSize);
      controller.updateTextEdit('2nd time only');

      await controller.exitMode(onAnnotationsChanged: (json) async => saved.add(json));

      expect(_exportedTexts(saved.single), ['2nd time only']);
      expect(controller.editingTextIdListenable.value, isNull);
      expect(controller.selectedTextIdListenable.value, isNull);
    });

    test('leaving annotation mode discards an empty edit in progress before the export', () async {
      final controller = _armed(texts: [_text()]);
      addTearDown(controller.dispose);
      final saved = <String>[];
      controller.beginTextEdit('text-1', pageSize: _pageSize);
      controller.updateTextEdit('   ');

      await controller.exitMode(onAnnotationsChanged: (json) async => saved.add(json));

      expect(_exportedTexts(saved.single), isEmpty);
      expect(controller.texts, isEmpty);
    });

    test('an export taken mid-edit carries the last committed text', () {
      final controller = _armed(texts: [_text()]);
      addTearDown(controller.dispose);
      controller.beginTextEdit('text-1', pageSize: _pageSize);
      controller.updateTextEdit('ritard.');

      expect(_exportedTexts(controller.exportJson()), ['rit.']);

      controller.commitTextEdit();
      expect(_exportedTexts(controller.exportJson()), ['ritard.']);
    });
  });
}
