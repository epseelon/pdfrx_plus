import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/annotation_text_layout.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_layer.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_text_annotation.dart';

import '_test_helpers/fake_pdf_page.dart';

// The layer is mounted 1:1 with the page, so PDF points and layer pixels
// coincide and every coordinate below reads directly. `flutter test` lays
// text out in its square test font: 'rit.' at 18 pt is 72 x 18.
const _pageSize = Size(400, 400);

Future<void> _pumpLayer(WidgetTester tester, PdfAnnotationController controller) async {
  final page = FakePdfPage(pageNumber: 1, width: _pageSize.width, height: _pageSize.height);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            key: const Key('layerHost'),
            width: _pageSize.width,
            height: _pageSize.height,
            child: PdfAnnotationLayer(
              controller: controller,
              page: page,
              pageRect: Offset.zero & _pageSize,
              highlighterOpacity: 0.35,
            ),
          ),
        ),
      ),
    ),
  );
}

PdfTextAnnotation _text({
  required String id,
  String text = 'rit.',
  Rect rect = const Rect.fromLTWH(40, 40, 72, 18),
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

/// A controller holding [texts], in Text-tool mode as `alice`.
PdfAnnotationController _armed({
  List<PdfTextAnnotation> texts = const [],
  PdfAnnotationTool tool = PdfAnnotationTool.text,
}) {
  final controller = PdfAnnotationController();
  controller.setAllWithStamps(strokes: [], stamps: [], attachments: {}, texts: texts);
  controller.enterMode(creatorName: 'alice', tool: tool);
  return controller;
}

Offset _origin(WidgetTester tester) => tester.getTopLeft(find.byKey(const Key('layerHost')));

Future<void> _tapAt(WidgetTester tester, Offset at) async {
  await tester.tapAt(_origin(tester) + at);
  await tester.pumpAndSettle();
}

/// Presses at [from], drags to [to] in one step, and releases.
Future<void> _dragFromTo(WidgetTester tester, Offset from, Offset to) async {
  final origin = _origin(tester);
  final gesture = await tester.startGesture(origin + from);
  await tester.pump();
  await gesture.moveTo(origin + to);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

Finder _gizmoFor(String id) => find.byKey(Key('annotationSelection:$id'));
Finder _editorFor(String id) => find.byKey(Key('annotationTextEditor:$id'));
final Finder _anyEditor = find.byType(EditableText);

// Well clear of every annotation the tests place.
const _emptySpot = Offset(300, 300);

void main() {
  group('Text tool creation', () {
    testWidgets('a tap creates auto-sized text at the tap point and opens the inline editor', (tester) async {
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      await _tapAt(tester, const Offset(60, 80));

      final editing = controller.editingText!;
      expect(editing.autoSize, isTrue);
      expect(editing.rectInPdfSpace.topLeft, const Offset(60, 80));
      expect(_editorFor(editing.id), findsOneWidget);
      final editable = tester.widget<EditableText>(_anyEditor);
      expect(editable.focusNode.hasFocus, isTrue, reason: 'the keyboard is up and the caret visible');
      expect(editable.controller.text, isEmpty, reason: 'no placeholder text is inserted');
      // The editor sits where the text will be painted.
      expect(tester.getTopLeft(_anyEditor), _origin(tester) + const Offset(60, 80));
      expect(tester.testTextInput.isVisible, isTrue);
    });

    testWidgets('typing then tapping outside commits the text where it was typed, selected with its gizmo', (
      tester,
    ) async {
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      await _tapAt(tester, const Offset(60, 80));
      await tester.enterText(_anyEditor, 'rit.');
      await tester.pump();
      await _tapAt(tester, _emptySpot);

      expect(_anyEditor, findsNothing);
      final committed = controller.texts.single;
      expect(committed.text, 'rit.');
      expect(committed.rectInPdfSpace, const Rect.fromLTWH(60, 80, 72, 18));
      expect(controller.selectedTextIdListenable.value, committed.id);
      expect(_gizmoFor(committed.id), findsOneWidget);
      expect(controller.currentToolListenable.value, PdfAnnotationTool.text, reason: 'the tool stays armed');
    });

    testWidgets('a drag rubber-bands a text area with a live outline and opens the editor on release', (tester) async {
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      final origin = _origin(tester);
      final gesture = await tester.startGesture(origin + const Offset(50, 60));
      await tester.pump();
      await gesture.moveTo(origin + const Offset(250, 160));
      await tester.pump();

      expect(controller.inFlightTextAreaFor(0), const Rect.fromLTWH(50, 60, 200, 100));
      expect(
        tester.getRect(find.byKey(const Key('annotationTextAreaDraft'))),
        Rect.fromLTWH(origin.dx + 50, origin.dy + 60, 200, 100),
      );

      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('annotationTextAreaDraft')), findsNothing);
      final editing = controller.editingText!;
      expect(editing.autoSize, isFalse);
      expect(editing.rectInPdfSpace, const Rect.fromLTWH(50, 60, 200, 100));
      expect(_editorFor(editing.id), findsOneWidget);
    });

    testWidgets('a rubber band is clamped to the page and never translated', (tester) async {
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      final origin = _origin(tester);
      final gesture = await tester.startGesture(origin + const Offset(300, 300));
      await tester.pump();
      await gesture.moveTo(origin + const Offset(399, 399));
      await tester.pump();
      await gesture.moveTo(origin + const Offset(600, 700));
      await tester.pump();

      expect(controller.inFlightTextAreaFor(0), const Rect.fromLTWH(300, 300, 100, 100));
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a pointer-cancel during the rubber band discards the draft', (tester) async {
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      final origin = _origin(tester);
      final gesture = await tester.startGesture(origin + const Offset(50, 60));
      await tester.pump();
      await gesture.moveTo(origin + const Offset(250, 160));
      await tester.pump();
      await gesture.cancel();
      await tester.pumpAndSettle();

      expect(controller.inFlightTextAreaFor(0), isNull);
      expect(controller.editingText, isNull);
      expect(controller.texts, isEmpty);
      expect(controller.canUndoListenable.value, isFalse);
    });

    testWidgets('a sub-minimum drag falls through to a tap at the pointer-DOWN point', (tester) async {
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      // Past the 4 px slop so it is a drag, under 8 pt so it is no text area.
      await _dragFromTo(tester, const Offset(60, 80), const Offset(66, 85));

      final editing = controller.editingText!;
      expect(editing.autoSize, isTrue);
      expect(editing.rectInPdfSpace.topLeft, const Offset(60, 80), reason: 'anchored where the finger landed');
    });

    testWidgets('a press inside an UNSELECTED text annotation that turns into a drag creates a new text area', (
      tester,
    ) async {
      final controller = _armed(texts: [_text(id: 'mine')]);
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      await _dragFromTo(tester, const Offset(50, 50), const Offset(200, 150));

      expect(controller.editingText?.rectInPdfSpace, const Rect.fromLTWH(50, 50, 150, 100));
    });

    testWidgets('a drag starting on the SELECTED text annotation never rubber-bands', (tester) async {
      final controller = _armed(texts: [_text(id: 'mine')]);
      addTearDown(controller.dispose);
      controller.selectText('mine');
      await _pumpLayer(tester, controller);

      await _dragFromTo(tester, const Offset(76, 49), const Offset(200, 150));

      expect(controller.editingText, isNull);
      expect(controller.inFlightTextAreaFor(0), isNull);
      expect(controller.selectedTextIdListenable.value, 'mine');
    });
  });

  group('Text tool tap precedence', () {
    testWidgets('a first tap selects without editing, a second tap on the selected annotation enters editing', (
      tester,
    ) async {
      final controller = _armed(texts: [_text(id: 'mine')]);
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      await _tapAt(tester, const Offset(60, 50));
      expect(controller.selectedTextIdListenable.value, 'mine');
      expect(_gizmoFor('mine'), findsOneWidget);
      expect(controller.editingText, isNull);
      expect(_anyEditor, findsNothing);

      await _tapAt(tester, const Offset(60, 50));
      expect(controller.editingTextIdListenable.value, 'mine');
      expect(tester.widget<EditableText>(_anyEditor).controller.text, 'rit.');
    });

    testWidgets('a tap on empty space with a selection only deselects; the next one creates', (tester) async {
      final controller = _armed(texts: [_text(id: 'mine')]);
      addTearDown(controller.dispose);
      controller.selectText('mine');
      await _pumpLayer(tester, controller);

      await _tapAt(tester, _emptySpot);
      expect(controller.selectedTextIdListenable.value, isNull);
      expect(controller.editingText, isNull, reason: 'the tap only deselected');

      await _tapAt(tester, _emptySpot);
      expect(controller.editingText?.rectInPdfSpace.topLeft, _emptySpot);
    });

    testWidgets('the tap that commits only commits: it neither creates nor selects what it landed on', (tester) async {
      final controller = _armed(
        texts: [_text(id: 'other', rect: const Rect.fromLTWH(200, 200, 72, 18))],
      );
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      await _tapAt(tester, const Offset(60, 80));
      final newId = controller.editingText!.id;
      await tester.enterText(_anyEditor, 'rit.');
      await tester.pump();

      // Straight onto another of the user's own text annotations.
      await _tapAt(tester, const Offset(220, 209));

      expect(controller.editingText, isNull);
      expect(controller.texts.map((t) => t.id), ['other', newId], reason: 'nothing new was created by that tap');
      expect(controller.selectedTextIdListenable.value, newId, reason: 'the committed annotation, not the tapped one');
    });

    testWidgets('a press outside the box that turns into a drag still only commits', (tester) async {
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      await _tapAt(tester, const Offset(60, 80));
      await tester.enterText(_anyEditor, 'rit.');
      await tester.pump();
      await _dragFromTo(tester, const Offset(200, 200), const Offset(350, 350));

      expect(controller.texts, hasLength(1));
      expect(controller.editingText, isNull);
      expect(controller.inFlightTextAreaFor(0), isNull);
    });

    testWidgets('committing empty text discards the annotation', (tester) async {
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      await _tapAt(tester, const Offset(60, 80));
      await _tapAt(tester, _emptySpot);

      expect(controller.texts, isEmpty);
      expect(controller.selectedTextIdListenable.value, isNull);
      expect(controller.canUndoListenable.value, isFalse);
    });

    testWidgets('the delete button deletes the selected text annotation in one undo step', (tester) async {
      final controller = _armed(texts: [_text(id: 'mine')]);
      addTearDown(controller.dispose);
      controller.selectText('mine');
      await _pumpLayer(tester, controller);

      await tester.tapAt(tester.getCenter(find.byIcon(Icons.delete_outline)));
      await tester.pumpAndSettle();

      expect(controller.texts, isEmpty);
      controller.undo();
      expect(controller.texts.single.id, 'mine');
      expect(controller.canUndoListenable.value, isFalse);
    });

    testWidgets("a bandmate's text annotation cannot be selected, and an own one underneath still can", (tester) async {
      final controller = _armed(
        texts: [
          _text(id: 'mine', createdAt: DateTime.utc(2026, 9, 21, 10)),
          _text(id: 'theirs', creatorName: 'bob', createdAt: DateTime.utc(2026, 9, 21, 11)),
          _text(id: 'theirsAlone', creatorName: 'bob', rect: const Rect.fromLTWH(200, 200, 72, 18)),
        ],
      );
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      await _tapAt(tester, const Offset(60, 50));
      expect(controller.selectedTextIdListenable.value, 'mine');

      controller.clearTextSelection();
      await tester.pumpAndSettle();
      await _tapAt(tester, const Offset(220, 209));
      expect(controller.selectedTextIdListenable.value, isNull);
      // Over a bandmate's text is empty space for this creator.
      expect(controller.editingText?.rectInPdfSpace.topLeft, const Offset(220, 209));
    });

    testWidgets('with another tool active a tap on a text annotation selects nothing', (tester) async {
      for (final tool in const [PdfAnnotationTool.rectangle, PdfAnnotationTool.stamp, PdfAnnotationTool.pen]) {
        final controller = _armed(
          texts: [_text(id: 'mine')],
          tool: tool,
        );
        addTearDown(controller.dispose);
        await _pumpLayer(tester, controller);

        await _tapAt(tester, const Offset(60, 50));

        expect(controller.selectedTextIdListenable.value, isNull, reason: '$tool');
        expect(_gizmoFor('mine'), findsNothing, reason: '$tool');
        expect(_anyEditor, findsNothing, reason: '$tool');
      }
    });

    testWidgets('the selected text annotation shows the shared gizmo with its localized handle labels', (tester) async {
      final controller = _armed(texts: [_text(id: 'mine')]);
      addTearDown(controller.dispose);
      controller.selectText('mine');
      await _pumpLayer(tester, controller);

      expect(tester.getRect(_gizmoFor('mine')), (_origin(tester) + const Offset(40, 40)) & const Size(72, 18));
      for (final label in const ['Resize top-left', 'Resize right', 'Rotate', 'Delete']) {
        expect(find.bySemanticsLabel(label), findsWidgets, reason: 'missing the "$label" affordance');
      }
    });
  });

  group('Text tool inline editor', () {
    testWidgets('while editing, the handles are hidden and only an outline of the box is drawn', (tester) async {
      final controller = _armed(texts: [_text(id: 'mine')]);
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      await _tapAt(tester, const Offset(60, 50));
      expect(find.bySemanticsLabel('Rotate'), findsWidgets);
      await _tapAt(tester, const Offset(60, 50));

      expect(_gizmoFor('mine'), findsOneWidget, reason: 'the outline stays');
      for (final label in const ['Resize top-left', 'Rotate', 'Delete']) {
        expect(find.bySemanticsLabel(label), findsNothing, reason: '"$label" must be hidden while editing');
      }
      expect(find.byIcon(Icons.delete_outline), findsNothing);
    });

    testWidgets('the editor losing keyboard focus does not commit', (tester) async {
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      await _tapAt(tester, const Offset(60, 80));
      await tester.enterText(_anyEditor, 'rit.');
      await tester.pump();
      tester.widget<EditableText>(_anyEditor).focusNode.unfocus();
      await tester.pumpAndSettle();

      expect(controller.editingText?.text, 'rit.');
      expect(controller.texts, isEmpty);
      expect(_anyEditor, findsOneWidget);
    });

    testWidgets('Escape commits and leaves the annotation selected', (tester) async {
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      await _tapAt(tester, const Offset(60, 80));
      await tester.enterText(_anyEditor, 'rit.');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(controller.editingText, isNull);
      expect(controller.texts.single.text, 'rit.');
      expect(controller.selectedTextIdListenable.value, controller.texts.single.id);
    });

    testWidgets('Enter inserts a newline and never commits', (tester) async {
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      await _tapAt(tester, const Offset(60, 80));
      await tester.enterText(_anyEditor, 'rit.');
      await tester.pump();
      final editable = tester.widget<EditableText>(_anyEditor);
      expect(editable.maxLines, isNull);
      expect(editable.textInputAction, TextInputAction.newline);
      // What a platform keyboard does on Enter in a multiline field: it
      // inserts the line break itself, then reports the action.
      await tester.enterText(_anyEditor, 'rit.\n');
      await tester.testTextInput.receiveAction(TextInputAction.newline);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(controller.editingText, isNotNull, reason: 'still editing');
      expect(controller.editingText!.text, 'rit.\n');
      expect(controller.texts, isEmpty);
    });

    testWidgets('autocorrect and suggestions are off', (tester) async {
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      await _tapAt(tester, const Offset(60, 80));

      final editable = tester.widget<EditableText>(_anyEditor);
      expect(editable.autocorrect, isFalse);
      expect(editable.enableSuggestions, isFalse);
    });

    testWidgets('input beyond 2,000 characters is rejected at the editor', (tester) async {
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      await _tapAt(tester, const Offset(60, 80));
      await tester.enterText(_anyEditor, 'a' * 2000);
      await tester.pump();
      expect(controller.editingText!.text.length, 2000);
      await tester.enterText(_anyEditor, 'a' * 2001);
      await tester.pump();

      expect(controller.editingText!.text.length, 2000);
    });

    testWidgets('a stored text longer than the cap is never truncated by editing it', (tester) async {
      final long = 'a' * 2500;
      final controller = _armed(
        texts: [_text(id: 'mine', text: long, autoSize: false)],
      );
      addTearDown(controller.dispose);
      controller.selectText('mine');
      await _pumpLayer(tester, controller);

      await _tapAt(tester, const Offset(60, 50));
      expect(tester.widget<EditableText>(_anyEditor).controller.text, long);
      // Growing it is refused, shrinking it is not.
      await tester.enterText(_anyEditor, '${long}b');
      await tester.pump();
      expect(controller.editingText!.text, long);
      await tester.enterText(_anyEditor, long.substring(1));
      await tester.pump();
      expect(controller.editingText!.text.length, 2499);
      // A same-length replacement (fixing a typo) is not growth either.
      final retyped = 'b${long.substring(2)}';
      await tester.enterText(_anyEditor, retyped);
      await tester.pump();
      expect(controller.editingText!.text, retyped);
    });

    testWidgets('the editor breaks lines exactly where the layout function does', (tester) async {
      // A 90 pt text area holds EXACTLY five 18 pt glyphs per line, so the
      // editor must wrap at 90 to the point: a box one caret margin short
      // would break every full line a glyph early.
      const text = 'aaaaa bbbbbbb cc ddddd eeeeeeeeeeee f';
      final annotation = _text(id: 'mine', text: text, rect: const Rect.fromLTWH(40, 40, 90, 18), autoSize: false);
      final controller = _armed(texts: [annotation]);
      addTearDown(controller.dispose);
      controller.selectText('mine');
      await _pumpLayer(tester, controller);
      await _tapAt(tester, const Offset(60, 50));

      final layout = layoutAnnotationText(
        text: text,
        style: resolveAnnotationTextStyle(annotation, controller.annotationFonts),
        align: annotation.align,
        wrapWidth: 90,
      );
      addTearDown(layout.dispose);
      final expected = layout.lineRanges;
      expect(expected.length, greaterThan(3), reason: 'the fixture must actually wrap');

      final editable = tester.state<EditableTextState>(_anyEditor).renderEditable;
      final actual = <TextRange>[];
      var offset = 0;
      while (offset < text.length) {
        final line = editable.getLineAtOffset(TextPosition(offset: offset));
        if (line.end <= offset) break;
        actual.add(TextRange(start: line.start, end: line.end));
        offset = line.end;
      }
      expect(actual, expected);
      expect(editable.size.height, layout.size.height, reason: 'same line heights, so nothing shifts on commit');
    });

    testWidgets('the editor of a text area is as wide as the box the text wraps in', (tester) async {
      final controller = _armed(
        texts: [_text(id: 'mine', rect: const Rect.fromLTWH(40, 40, 100, 50), autoSize: false)],
      );
      addTearDown(controller.dispose);
      controller.selectText('mine');
      await _pumpLayer(tester, controller);
      await _tapAt(tester, const Offset(60, 50));

      expect(tester.getTopLeft(_anyEditor), _origin(tester) + const Offset(40, 40));
      expect(tester.getRect(_gizmoFor('mine')), (_origin(tester) + const Offset(40, 40)) & const Size(100, 50));
    });
  });
}
