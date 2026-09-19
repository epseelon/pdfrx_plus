import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_layer.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_rect_annotation.dart';

import '_test_helpers/fake_pdf_page.dart';

// The layer is mounted 1:1 with the page, so PDF points and layer pixels
// coincide and every coordinate below reads directly.
const _pageSize = Size(200, 200);

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
              pageRect: const Rect.fromLTWH(0, 0, 200, 200),
              highlighterOpacity: 0.35,
            ),
          ),
        ),
      ),
    ),
  );
}

PdfRectAnnotation _rect({
  required String id,
  Rect rect = const Rect.fromLTWH(40, 40, 60, 60),
  String? creatorName = 'alice',
  DateTime? createdAt,
}) => PdfRectAnnotation(
  id: id,
  pageIndex: 0,
  rectInPdfSpace: rect,
  rotationDeg: 0,
  fillColor: const Color(0xFFFFFFFF),
  createdAt: createdAt ?? DateTime.utc(2026, 9, 19, 10),
  updatedAt: createdAt ?? DateTime.utc(2026, 9, 19, 10),
  creatorName: creatorName,
);

/// A controller holding [rects], in rectangle-tool mode as `alice`.
PdfAnnotationController _armed({List<PdfRectAnnotation> rects = const []}) {
  final controller = PdfAnnotationController();
  controller.setAllWithStamps(strokes: [], stamps: [], attachments: {}, rects: rects);
  controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.rectangle);
  return controller;
}

Offset _origin(WidgetTester tester) => tester.getTopLeft(find.byKey(const Key('layerHost')));

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

void main() {
  group('rectangle tool creation', () {
    testWidgets('a press-and-drag rubber-bands a new rectangle, auto-selected with its gizmo up', (tester) async {
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      await _dragFromTo(tester, const Offset(30, 40), const Offset(130, 100));

      expect(controller.rects, hasLength(1));
      expect(controller.rects.single.rectInPdfSpace, const Rect.fromLTWH(30, 40, 100, 60));
      expect(controller.selectedRectIdListenable.value, controller.rects.single.id);
      expect(_gizmoFor(controller.rects.single.id), findsOneWidget);
    });

    testWidgets('the live preview follows the finger before the pointer comes up', (tester) async {
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      final origin = _origin(tester);
      final gesture = await tester.startGesture(origin + const Offset(30, 40));
      await tester.pump();
      await gesture.moveTo(origin + const Offset(90, 90));
      await tester.pump();

      expect(controller.inFlightRectFor(0)?.rectInPdfSpace, const Rect.fromLTWH(30, 40, 60, 50));
      // Still a draft: nothing is committed until the finger lifts.
      expect(controller.rects, isEmpty);

      await gesture.up();
      await tester.pumpAndSettle();
      expect(controller.rects, hasLength(1));
    });

    testWidgets('a pointer-cancel discards the in-flight rectangle and pushes no undo snapshot', (tester) async {
      final controller = _armed();
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      final origin = _origin(tester);
      final gesture = await tester.startGesture(origin + const Offset(30, 40));
      await tester.pump();
      await gesture.moveTo(origin + const Offset(130, 100));
      await tester.pump();
      await gesture.cancel();
      await tester.pumpAndSettle();

      expect(controller.rects, isEmpty);
      expect(controller.inFlightRectFor(0), isNull);
      expect(controller.canUndoListenable.value, isFalse);
    });

    testWidgets('movement below the drag slop is a tap and never starts a rubber band', (tester) async {
      final controller = _armed(rects: [_rect(id: 'existing')]);
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      // 2 px of travel, under the 4 px slop: a tap on the rectangle.
      await _dragFromTo(tester, const Offset(60, 60), const Offset(62, 60));

      expect(controller.rects.map((r) => r.id), ['existing']);
      expect(controller.selectedRectIdListenable.value, 'existing');
    });

    testWidgets('a sub-minimum drag falls through to the tap precedence rather than being a no-op', (tester) async {
      // Past the 4 px slop so it is a drag, but under 8 PDF points on
      // both axes so the rectangle is discarded. Without the
      // fall-through, tapping an invisible white cover with a finger
      // would frequently do nothing at all.
      final controller = _armed(rects: [_rect(id: 'existing')]);
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      await _dragFromTo(tester, const Offset(60, 60), const Offset(65, 65));

      expect(controller.rects.map((r) => r.id), ['existing'], reason: 'nothing new was created');
      expect(controller.selectedRectIdListenable.value, 'existing', reason: 'the gesture became a tap');
      expect(controller.canUndoListenable.value, isFalse);
    });
  });

  group('rectangle tool tap precedence', () {
    testWidgets('a tap on an own rectangle selects it', (tester) async {
      final controller = _armed(rects: [_rect(id: 'mine')]);
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      await tester.tapAt(_origin(tester) + const Offset(70, 70));
      await tester.pumpAndSettle();

      expect(controller.selectedRectIdListenable.value, 'mine');
    });

    testWidgets('a tap on empty space deselects', (tester) async {
      final controller = _armed(rects: [_rect(id: 'mine')]);
      addTearDown(controller.dispose);
      controller.selectRect('mine');
      await _pumpLayer(tester, controller);

      await tester.tapAt(_origin(tester) + const Offset(180, 180));
      await tester.pumpAndSettle();

      expect(controller.selectedRectIdListenable.value, isNull);
    });

    testWidgets('a foreign-creator rectangle cannot be selected by tap', (tester) async {
      final controller = _armed(
        rects: [_rect(id: 'theirs', creatorName: 'bob')],
      );
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      await tester.tapAt(_origin(tester) + const Offset(70, 70));
      await tester.pumpAndSettle();

      expect(controller.selectedRectIdListenable.value, isNull);
    });

    testWidgets('an own rectangle lying under a foreign one is still selectable', (tester) async {
      final controller = _armed(
        rects: [
          _rect(id: 'mine', createdAt: DateTime.utc(2026, 9, 19, 10)),
          _rect(id: 'theirs', creatorName: 'bob', createdAt: DateTime.utc(2026, 9, 19, 11)),
        ],
      );
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      await tester.tapAt(_origin(tester) + const Offset(70, 70));
      await tester.pumpAndSettle();

      expect(controller.selectedRectIdListenable.value, 'mine');
    });

    testWidgets('the topmost own rectangle wins overlap', (tester) async {
      final controller = _armed(
        rects: [
          _rect(id: 'older', createdAt: DateTime.utc(2026, 9, 19, 10)),
          _rect(id: 'newer', createdAt: DateTime.utc(2026, 9, 19, 11)),
        ],
      );
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      await tester.tapAt(_origin(tester) + const Offset(70, 70));
      await tester.pumpAndSettle();

      expect(controller.selectedRectIdListenable.value, 'newer');
    });

    testWidgets('the delete button wins over selecting or deselecting', (tester) async {
      final controller = _armed(rects: [_rect(id: 'mine')]);
      addTearDown(controller.dispose);
      controller.selectRect('mine');
      await _pumpLayer(tester, controller);

      // The delete button floats just outside the bbox's top-right
      // corner; the icon itself is the reliable target.
      await tester.tapAt(tester.getCenter(find.byIcon(Icons.delete_outline)));
      await tester.pumpAndSettle();

      expect(controller.rects, isEmpty);
      expect(controller.selectedRectIdListenable.value, isNull);
    });
  });

  group('rectangle tool drag precedence', () {
    testWidgets('a drag starting inside an UNSELECTED rectangle creates a new one on top', (tester) async {
      // A cover must always be drawable over an existing one, so an
      // unselected rectangle never captures a drag.
      final controller = _armed(rects: [_rect(id: 'existing')]);
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      await _dragFromTo(tester, const Offset(50, 50), const Offset(150, 150));

      expect(controller.rects, hasLength(2));
      expect(controller.rects.first.rectInPdfSpace, const Rect.fromLTWH(40, 40, 60, 60), reason: 'untouched');
      expect(controller.rects.last.rectInPdfSpace, const Rect.fromLTWH(50, 50, 100, 100));
    });

    testWidgets('a body drag on the SELECTED rectangle moves it', (tester) async {
      final controller = _armed(rects: [_rect(id: 'mine')]);
      addTearDown(controller.dispose);
      controller.selectRect('mine');
      await _pumpLayer(tester, controller);

      // Start at the centre, well clear of every handle's hit radius.
      await _dragFromTo(tester, const Offset(70, 70), const Offset(100, 90));

      expect(controller.rects, hasLength(1), reason: 'moved, not duplicated');
      expect(controller.rects.single.rectInPdfSpace, const Rect.fromLTWH(70, 60, 60, 60));
    });

    testWidgets('a drag on a resize handle of the selected rectangle resizes it', (tester) async {
      final controller = _armed(rects: [_rect(id: 'mine')]);
      addTearDown(controller.dispose);
      controller.selectRect('mine');
      await _pumpLayer(tester, controller);

      // Rectangle handle padding is 0.0, so the bottom-right handle sits
      // exactly on the border at (100, 100).
      await _dragFromTo(tester, const Offset(100, 100), const Offset(140, 100));

      expect(controller.rects, hasLength(1));
      expect(controller.rects.single.rectInPdfSpace, const Rect.fromLTWH(40, 40, 100, 60));
    });

    testWidgets('a press within the handle hit radius beats the body', (tester) async {
      final controller = _armed(rects: [_rect(id: 'mine')]);
      addTearDown(controller.dispose);
      controller.selectRect('mine');
      await _pumpLayer(tester, controller);

      // 6 px inside the bottom-right corner: inside the body, but well
      // within the 22 px handle hit radius, so the handle takes it.
      await _dragFromTo(tester, const Offset(94, 94), const Offset(134, 94));

      expect(controller.rects.single.rectInPdfSpace.width, greaterThan(60));
      expect(controller.rects.single.rectInPdfSpace.left, 40, reason: 'resized, not moved');
    });

    testWidgets('a foreign-creator rectangle cannot be dragged', (tester) async {
      final controller = _armed(
        rects: [_rect(id: 'theirs', creatorName: 'bob')],
      );
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      await _dragFromTo(tester, const Offset(50, 50), const Offset(150, 150));

      // The drag became a new rectangle of the current creator; theirs
      // is untouched.
      expect(controller.rects.first.rectInPdfSpace, const Rect.fromLTWH(40, 40, 60, 60));
      expect(controller.rects.first.creatorName, 'bob');
    });
  });

  group('rectangle tool selection overlay', () {
    testWidgets('the gizmo appears on selection and goes when the tool changes', (tester) async {
      final controller = _armed(rects: [_rect(id: 'mine')]);
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);
      expect(_gizmoFor('mine'), findsNothing);

      controller.selectRect('mine');
      await tester.pumpAndSettle();
      expect(_gizmoFor('mine'), findsOneWidget);

      controller.setTool(PdfAnnotationTool.pen);
      await tester.pumpAndSettle();
      expect(_gizmoFor('mine'), findsNothing);
    });

    testWidgets('the gizmo offers eight resize handles, a rotation control and a delete button', (tester) async {
      final controller = _armed(rects: [_rect(id: 'mine')]);
      addTearDown(controller.dispose);
      controller.selectRect('mine');
      await _pumpLayer(tester, controller);

      for (final label in const [
        'Resize top-left',
        'Resize top',
        'Resize top-right',
        'Resize right',
        'Resize bottom-right',
        'Resize bottom',
        'Resize bottom-left',
        'Resize left',
        'Rotate',
        'Delete',
      ]) {
        expect(find.bySemanticsLabel(label), findsWidgets, reason: 'missing the "$label" affordance');
      }
    });
  });
}
