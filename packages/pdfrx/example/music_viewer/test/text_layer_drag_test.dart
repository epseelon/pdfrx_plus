import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_layer.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_text_annotation.dart';
import 'package:pdfrx/src/widgets/annotations/selection_geometry.dart';

import '_test_helpers/fake_pdf_page.dart';

// The layer is mounted 1:1 with the page, so PDF points and layer pixels
// coincide and every coordinate below reads directly. `flutter test` lays
// text out in its square test font: at 18 pt 'rit.' is 72 x 18, and
// 'aaaa bbbb' is 162 x 18 on one line, 72 x 36 once it wraps.
const _pageSize = Size(400, 400);

// What the host app passes for stamps. The selected text gizmo reuses it,
// so its handles clear the glyphs and a short word keeps a body zone.
const _padding = 24.0;

// Distance from the gizmo's top edge to the rotation handle's centre.
const _rotationHandleOffset = 20.0;

Future<void> _pumpLayer(
  WidgetTester tester,
  PdfAnnotationController controller, {
  double padding = _padding,
  double? textPadding,
}) async {
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
              selectedStampPadding: padding,
              selectedTextPadding: textPadding,
            ),
          ),
        ),
      ),
    ),
  );
}

PdfTextAnnotation _text({
  String text = 'rit.',
  Rect rect = const Rect.fromLTWH(100, 200, 72, 18),
  bool autoSize = true,
  double rotationDeg = 0,
}) => PdfTextAnnotation(
  id: 'mine',
  pageIndex: 0,
  rectInPdfSpace: rect,
  rotationDeg: rotationDeg,
  text: text,
  autoSize: autoSize,
  createdAt: DateTime.utc(2026, 9, 21, 10),
  updatedAt: DateTime.utc(2026, 9, 21, 10),
  creatorName: 'alice',
);

/// A controller holding [text], selected, in Text-tool mode as `alice`.
PdfAnnotationController _armed(PdfTextAnnotation text) {
  final controller = PdfAnnotationController();
  controller.setAllWithStamps(strokes: [], stamps: [], attachments: {}, texts: [text]);
  controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.text);
  controller.selectText(text.id);
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

/// Where [handle] of the gizmo around [box] is drawn, in layer pixels.
Offset _drawnHandle(Rect box, PdfAnnotationHandle handle, {double rotationDeg = 0}) => handleAnchorOnScreen(
  rect: box.inflate(_padding),
  rotationDeg: rotationDeg,
  handle: handle,
  rotationHandleOffset: _rotationHandleOffset,
);

final Finder _gizmo = find.byKey(const Key('annotationSelection:mine'));

void main() {
  group('Text manipulation on the mounted layer', () {
    testWidgets('a body drag on a short selected word moves it, and the gizmo follows', (tester) async {
      final controller = _armed(_text());
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);
      const box = Rect.fromLTWH(100, 200, 72, 18);

      // The middle of the word. Without the padding this press would be
      // 9 px from the top handle and grab it.
      await _dragFromTo(tester, box.center, box.center + const Offset(120, -60));

      final moved = controller.texts.single;
      expect(moved.rectInPdfSpace, const Rect.fromLTWH(220, 140, 72, 18));
      expect(moved.autoSize, isTrue);
      expect(controller.selectedTextIdListenable.value, 'mine');
      expect(controller.editingText, isNull);
      expect(
        tester.getRect(_gizmo).shift(-_origin(tester)),
        const Rect.fromLTWH(220, 140, 72, 18).inflate(_padding),
      );

      controller.undo();
      expect(controller.texts.single.rectInPdfSpace, box);
      expect(controller.canUndoListenable.value, isFalse);
    });

    testWidgets('a text annotation can be padded less than a stamp: its gizmo takes selectedTextPadding', (
      tester,
    ) async {
      final controller = _armed(_text());
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller, textPadding: 12);

      expect(
        tester.getRect(_gizmo).shift(-_origin(tester)),
        const Rect.fromLTWH(100, 200, 72, 18).inflate(12),
        reason: 'not the 24 px the stamps keep',
      );
    });

    testWidgets('at 12 px a short word still has a body zone to be moved by, beside its centre', (tester) async {
      final controller = _armed(_text());
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller, textPadding: 12);
      const box = Rect.fromLTWH(100, 200, 72, 18);

      // 24 px from the left handle, 32 px from the top-left and top ones:
      // outside every handle's 22 px hit radius. The very centre of an
      // 18 px tall word is NOT: it is 21 px from the top handle.
      final press = box.centerLeft + const Offset(12, 0);
      await _dragFromTo(tester, press, press + const Offset(120, -60));

      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(220, 140, 72, 18));
      expect(controller.texts.single.autoSize, isTrue, reason: 'a move, not a resize');
    });

    testWidgets('a handle drag on selected auto-sized text converts it to a text area and rewraps it', (tester) async {
      const box = Rect.fromLTWH(100, 200, 162, 18);
      final controller = _armed(_text(text: 'aaaa bbbb', rect: box));
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      // Pull the right handle 82 px to the left: 80 wide, room for one
      // word per line.
      final handle = _drawnHandle(box, PdfAnnotationHandle.right);
      await _dragFromTo(tester, handle, handle - const Offset(82, 0));

      final converted = controller.texts.single;
      expect(converted.autoSize, isFalse);
      expect(converted.rectInPdfSpace, const Rect.fromLTWH(100, 200, 80, 36));
      expect(converted.fontSize, 18);
      expect(controller.inFlightTextAreaFor(0), isNull, reason: 'a handle drag never rubber-bands');

      // One step back: auto-sized again, on one line.
      controller.undo();
      expect(controller.texts.single.autoSize, isTrue);
      expect(controller.texts.single.rectInPdfSpace, box);
    });

    testWidgets('the rewrap is live: the box under the finger reshapes before the pointer is released', (tester) async {
      const box = Rect.fromLTWH(100, 200, 162, 18);
      final controller = _armed(_text(text: 'aaaa bbbb', rect: box, autoSize: false));
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      final handle = _drawnHandle(box, PdfAnnotationHandle.right);
      final gesture = await tester.startGesture(_origin(tester) + handle);
      await tester.pump();
      await gesture.moveBy(const Offset(-82, 0));
      await tester.pump();

      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(100, 200, 80, 36));
      expect(
        tester.getRect(_gizmo).shift(-_origin(tester)),
        const Rect.fromLTWH(100, 200, 80, 36).inflate(_padding),
      );

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('the rotation handle turns the annotation freely, and the gizmo turns with it', (tester) async {
      const box = Rect.fromLTWH(100, 200, 72, 18);
      final controller = _armed(_text());
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      // From straight above the centre to straight right of it: a quarter
      // turn clockwise on screen, which is -90 counter-clockwise.
      final handle = _drawnHandle(box, PdfAnnotationHandle.rotation);
      final radius = box.center.dy - handle.dy;
      await _dragFromTo(tester, handle, box.center + Offset(radius, 0));

      final rotated = controller.texts.single;
      expect(rotated.rotationDeg, closeTo(-90, 1e-6));
      expect(rotated.rectInPdfSpace, box);
      expect(rotated.autoSize, isTrue);
      final transform = tester.widget<Transform>(find.descendant(of: _gizmo, matching: find.byType(Transform)).first);
      // Rotated a quarter turn clockwise: the x axis now points down.
      expect(transform.transform.entry(1, 0), closeTo(1, 1e-6));
    });

    testWidgets('the handles of a rotated annotation are grabbable where they are drawn', (tester) async {
      const box = Rect.fromLTWH(150, 150, 100, 40);
      final controller = _armed(_text(text: 'aaaa', rect: box, autoSize: false, rotationDeg: 90));
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      // At 90 degrees the box's own +x axis points up the screen, so the
      // right handle is drawn above the centre.
      final handle = _drawnHandle(box, PdfAnnotationHandle.right, rotationDeg: 90);
      expect(handle.dy, lessThan(box.center.dy - 60));
      await _dragFromTo(tester, handle, handle - const Offset(0, 30));

      final after = controller.texts.single.rectInPdfSpace;
      expect(after.size, const Size(130, 40), reason: 'the right handle was grabbed where it is drawn');
      // The left edge stayed put on screen.
      Offset leftMiddle(Rect r) => rotatePointToScreen(r.centerLeft, center: r.center, rotationDeg: 90);
      expect(leftMiddle(after).dx, closeTo(leftMiddle(box).dx, 1e-6));
      expect(leftMiddle(after).dy, closeTo(leftMiddle(box).dy, 1e-6));
    });

    testWidgets('a drag interrupted by a pointer-cancel ends cleanly', (tester) async {
      const box = Rect.fromLTWH(100, 200, 72, 18);
      final controller = _armed(_text());
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      final gesture = await tester.startGesture(_origin(tester) + box.center);
      await tester.pump();
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(controller.texts.single.rectInPdfSpace, box.shift(const Offset(40, 0)));

      // The next drag is a fresh one, from where the annotation now is.
      final center = box.center + const Offset(40, 0);
      await _dragFromTo(tester, center, center + const Offset(0, 50));
      expect(controller.texts.single.rectInPdfSpace, box.shift(const Offset(40, 50)));

      controller.undo();
      expect(controller.texts.single.rectInPdfSpace, box.shift(const Offset(40, 0)));
      controller.undo();
      expect(controller.texts.single.rectInPdfSpace, box);
    });

    testWidgets('a tap inside the padded gizmo of the selected annotation enters editing', (tester) async {
      final controller = _armed(_text());
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      // In the padding ring, between the handles.
      await tester.tapAt(_origin(tester) + const Offset(120, 190));
      await tester.pumpAndSettle();

      expect(controller.editingText?.id, 'mine');
    });

    testWidgets('while editing, the outline hugs the box: the padding is for the handles only', (tester) async {
      const box = Rect.fromLTWH(100, 200, 72, 18);
      final controller = _armed(_text());
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      controller.beginTextEdit('mine', pageSize: _pageSize);
      await tester.pumpAndSettle();

      expect(tester.getRect(_gizmo).shift(-_origin(tester)), box);
    });

    testWidgets('the padding does not widen an UNSELECTED annotation: a tap beside it still creates text', (
      tester,
    ) async {
      final controller = _armed(_text());
      addTearDown(controller.dispose);
      controller.clearTextSelection();
      await _pumpLayer(tester, controller);

      await tester.tapAt(_origin(tester) + const Offset(120, 190));
      await tester.pumpAndSettle();

      expect(controller.selectedTextIdListenable.value, isNull);
      expect(controller.editingText, isNotNull);
      expect(controller.editingText!.id, isNot('mine'));
    });
  });
}
