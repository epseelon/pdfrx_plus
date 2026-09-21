import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_layer.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_text_annotation.dart';

import '_test_helpers/fake_pdf_page.dart';

// The commit triggers that live outside the layer's own gestures: the
// Android back button, the on-screen keyboard going away, the app being
// paused, and the layer being disposed.
//
// The layer is mounted 1:1 with the page, so PDF points and layer pixels
// coincide. `flutter test` lays text out in its square test font.
const _pageSize = Size(400, 400);

const _popupItemKey = Key('popupItem');

/// The layer on a route of its own, pushed over a home page, so a back
/// press has somewhere to go. The Scaffold does not resize for the
/// keyboard, as on the host's score screen: a resizing one strips the
/// keyboard inset from its body's `MediaQuery`.
class _ScorePage extends StatelessWidget {
  const _ScorePage(this.controller);

  final PdfAnnotationController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Column(
        children: [
          // Stands in for a toolbar popup (font, size, color): a
          // `PopupMenuButton` pushes a route, which takes the focus.
          PopupMenuButton<int>(
            key: const Key('toolbarPopup'),
            itemBuilder: (_) => const [PopupMenuItem(key: _popupItemKey, value: 1, child: Text('Inter'))],
          ),
          SizedBox(
            key: const Key('layerHost'),
            width: _pageSize.width,
            height: _pageSize.height,
            child: PdfAnnotationLayer(
              controller: controller,
              page: FakePdfPage(pageNumber: 1, width: _pageSize.width, height: _pageSize.height),
              pageRect: Offset.zero & _pageSize,
              highlighterOpacity: 0.35,
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _pumpScoreRoute(WidgetTester tester, PdfAnnotationController controller) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _ScorePage(controller))),
              child: const Text('open score'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open score'));
  await tester.pumpAndSettle();
}

PdfTextAnnotation _text({required String id, String text = 'rit.'}) => PdfTextAnnotation(
  id: id,
  pageIndex: 0,
  rectInPdfSpace: const Rect.fromLTWH(40, 40, 72, 18),
  rotationDeg: 0,
  text: text,
  autoSize: true,
  createdAt: DateTime.utc(2026, 9, 21, 10),
  updatedAt: DateTime.utc(2026, 9, 21, 10),
  creatorName: 'alice',
);

/// A controller holding [texts], in Text-tool mode as `alice`.
PdfAnnotationController _armed({List<PdfTextAnnotation> texts = const []}) {
  final controller = PdfAnnotationController();
  controller.setAllWithStamps(strokes: [], stamps: [], attachments: {}, texts: texts);
  controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.text);
  return controller;
}

Offset _origin(WidgetTester tester) => tester.getTopLeft(find.byKey(const Key('layerHost')));

Future<void> _tapAt(WidgetTester tester, Offset at) async {
  await tester.tapAt(_origin(tester) + at);
  await tester.pumpAndSettle();
}

/// Opens a new edit at (60, 80) and types [text] into it.
Future<void> _typeNew(WidgetTester tester, String text) async {
  await _tapAt(tester, const Offset(60, 80));
  await tester.enterText(_anyEditor, text);
  await tester.pump();
}

/// Raises or lowers the on-screen keyboard, as the platform reports it.
Future<void> _setKeyboardInset(WidgetTester tester, double logicalPixels) async {
  tester.view.viewInsets = FakeViewPadding(bottom: logicalPixels * tester.view.devicePixelRatio);
  await tester.pumpAndSettle();
}

Finder _gizmoFor(String id) => find.byKey(Key('annotationSelection:$id'));
final Finder _anyEditor = find.byType(EditableText);
final Finder _scorePage = find.byType(_ScorePage);

void main() {
  group('Android back during an edit', () {
    testWidgets('the first back press only commits and never pops the route; the second pops as before', (
      tester,
    ) async {
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpScoreRoute(tester, controller);
      await _typeNew(tester, 'rit.');

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(_scorePage, findsOneWidget, reason: 'the first back press stays on the score');
      expect(controller.editingText, isNull);
      final committed = controller.texts.single;
      expect(committed.text, 'rit.');
      expect(controller.selectedTextIdListenable.value, committed.id, reason: 'left selected, as after Escape');
      expect(_gizmoFor(committed.id), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(_scorePage, findsNothing, reason: 'with no edit in progress, back behaves as before');
      expect(find.text('open score'), findsOneWidget);
    });

    testWidgets('back with no edit in progress pops straight away', (tester) async {
      final controller = _armed(texts: [_text(id: 'mine')]);
      addTearDown(controller.dispose);
      await _pumpScoreRoute(tester, controller);
      await _tapAt(tester, const Offset(60, 50));
      expect(controller.selectedTextIdListenable.value, 'mine');

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(_scorePage, findsNothing);
    });

    testWidgets('back during an edit of empty text discards it and stays on the score', (tester) async {
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpScoreRoute(tester, controller);
      await _tapAt(tester, const Offset(60, 80));

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(_scorePage, findsOneWidget);
      expect(controller.editingText, isNull);
      expect(controller.texts, isEmpty);
      expect(controller.canUndoListenable.value, isFalse);
    });
  });

  group('the on-screen keyboard going away', () {
    testWidgets('commits the edit and leaves the annotation selected', (tester) async {
      addTearDown(tester.view.resetViewInsets);
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpScoreRoute(tester, controller);
      await _typeNew(tester, 'rit.');
      await _setKeyboardInset(tester, 300);
      expect(controller.editingText, isNotNull, reason: 'the keyboard coming up commits nothing');

      await _setKeyboardInset(tester, 120);
      expect(controller.editingText, isNotNull, reason: 'a keyboard that only shrinks has not gone away');

      await _setKeyboardInset(tester, 0);

      expect(controller.editingText, isNull);
      final committed = controller.texts.single;
      expect(committed.text, 'rit.');
      expect(controller.selectedTextIdListenable.value, committed.id);
      expect(_gizmoFor(committed.id), findsOneWidget);
    });

    testWidgets('commits when the platform closed the input connection first, as iOS does', (tester) async {
      addTearDown(tester.view.resetViewInsets);
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpScoreRoute(tester, controller);
      await _typeNew(tester, 'rit.');
      await _setKeyboardInset(tester, 300);

      // The keyboard's own dismiss key: the platform closes the
      // connection, which unfocuses the field, and only then does the
      // keyboard slide away.
      tester.state<EditableTextState>(_anyEditor).connectionClosed();
      await tester.pump();
      expect(controller.editingText, isNotNull, reason: 'losing the focus commits nothing by itself');
      await _setKeyboardInset(tester, 0);

      expect(controller.editingText, isNull);
      expect(controller.texts.single.text, 'rit.');
    });

    testWidgets('does NOT commit when it went away because a toolbar popup took the focus', (tester) async {
      addTearDown(tester.view.resetViewInsets);
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpScoreRoute(tester, controller);
      await _typeNew(tester, 'rit.');
      await _setKeyboardInset(tester, 300);

      await tester.tap(find.byKey(const Key('toolbarPopup')));
      await tester.pumpAndSettle();
      expect(find.byKey(_popupItemKey), findsOneWidget);
      await _setKeyboardInset(tester, 0);

      expect(controller.editingText?.text, 'rit.', reason: 'the edit is still open under the popup');
      expect(controller.texts, isEmpty);

      // Closing the popup gives the editor its focus back, and the
      // keyboard with it: still no commit.
      await tester.tap(find.byKey(_popupItemKey));
      await tester.pumpAndSettle();
      expect(tester.widget<EditableText>(_anyEditor).focusNode.hasFocus, isTrue);
      await _setKeyboardInset(tester, 300);
      expect(controller.editingText?.text, 'rit.');
    });

    testWidgets('with a hardware keyboard there is no inset and so no such trigger', (tester) async {
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpScoreRoute(tester, controller);
      await _typeNew(tester, 'rit.');
      await tester.pumpAndSettle();

      expect(controller.editingText?.text, 'rit.');
    });
  });

  group('the app being paused during an edit', () {
    testWidgets('commits the typed text', (tester) async {
      addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpScoreRoute(tester, controller);
      await _typeNew(tester, 'rit.');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(
        controller.editingText,
        isNotNull,
        reason: 'a notification shade or the app switcher peeking is not a pause',
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();

      expect(controller.editingText, isNull);
      expect(controller.texts.single.text, 'rit.');
      expect(controller.canUndoListenable.value, isTrue, reason: 'one undo step, as for any commit');
    });
  });

  group('the layer being disposed during an edit', () {
    testWidgets('commits non-empty text to the in-memory model, in one undo step', (tester) async {
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpScoreRoute(tester, controller);
      await _typeNew(tester, 'rit.');

      await tester.pumpWidget(const SizedBox.shrink());

      expect(controller.editingText, isNull);
      expect(controller.texts.single.text, 'rit.');
      controller.undo();
      expect(controller.texts, isEmpty);
      expect(controller.canUndoListenable.value, isFalse);
    });

    testWidgets('discards empty text and leaves no undo step', (tester) async {
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpScoreRoute(tester, controller);
      await _typeNew(tester, '   ');

      await tester.pumpWidget(const SizedBox.shrink());

      expect(controller.editingText, isNull);
      expect(controller.texts, isEmpty);
      expect(controller.canUndoListenable.value, isFalse);
    });

    testWidgets('emptying an existing annotation then disposing deletes it in one undo step', (tester) async {
      final controller = _armed(texts: [_text(id: 'mine')]);
      addTearDown(controller.dispose);
      await _pumpScoreRoute(tester, controller);
      await _tapAt(tester, const Offset(60, 50));
      await _tapAt(tester, const Offset(60, 50));
      expect(controller.editingText?.id, 'mine');
      await tester.enterText(_anyEditor, '');
      await tester.pump();

      await tester.pumpWidget(const SizedBox.shrink());

      expect(controller.texts, isEmpty);
      controller.undo();
      expect(controller.texts.single.text, 'rit.');
    });

    testWidgets('a controller disposed together with the layer is left alone', (tester) async {
      final controller = _armed();
      await _pumpScoreRoute(tester, controller);
      await _typeNew(tester, 'rit.');

      await tester.pumpWidget(const SizedBox.shrink(), phase: EnginePhase.build);
      controller.dispose();
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });

  group('the caret is reported to the controller', () {
    testWidgets('as the editor moves it', (tester) async {
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpScoreRoute(tester, controller);
      await _typeNew(tester, 'rit.');
      expect(controller.textEditCaretInPage!.rect, const Rect.fromLTWH(60 + 72, 80, 0, 18));

      tester.widget<EditableText>(_anyEditor).controller.selection = const TextSelection.collapsed(offset: 1);
      await tester.pump();

      expect(controller.textEditCaretInPage!.rect, const Rect.fromLTWH(60 + 18, 80, 0, 18));
    });
  });
}
