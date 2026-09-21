import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/annotation_paint_sequence.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_text_annotation.dart';
import 'package:pdfrx/src/widgets/annotations/selection_geometry.dart';

// `flutter test` lays text out in its square test font (Ahem-style):
// every glyph, the space included, is one em wide and one em tall. At
// 10 pt 'aaaa bbbb' is 90 x 10 on one line and 40 x 20 once it wraps, so
// every size below is exact arithmetic. The layout seam is the real one.

const Size _pageSize = Size(600, 800);
const String _twoWords = 'aaaa bbbb';

// Two 600x800 pages mounted side by side at 1:1 PDF-to-viewer scale.
const Rect _leftViewer = Rect.fromLTWH(0, 0, 600, 800);
const Rect _rightViewer = Rect.fromLTWH(600, 0, 600, 800);

PdfTextAnnotation _text({
  required Rect rect,
  String id = 'text-1',
  String text = _twoWords,
  bool autoSize = false,
  double rotationDeg = 0,
  String? creatorName = 'alice',
}) => PdfTextAnnotation(
  id: id,
  pageIndex: 0,
  rectInPdfSpace: rect,
  rotationDeg: rotationDeg,
  text: text,
  fontSize: 10,
  autoSize: autoSize,
  createdAt: DateTime.utc(2026, 9, 21, 10),
  updatedAt: DateTime.utc(2026, 9, 21, 10),
  creatorName: creatorName,
);

/// A controller in Text-tool mode as `alice`, holding [text] selected,
/// with two pages registered.
PdfAnnotationController _armed(PdfTextAnnotation text, {Size secondPageSize = _pageSize}) {
  final controller = PdfAnnotationController();
  controller.setAllWithStamps(strokes: [], stamps: [], attachments: {}, texts: [text]);
  controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.text);
  controller.registerPageLayout(pageIndex: 0, viewerRect: _leftViewer, pageSize: _pageSize);
  controller.registerPageLayout(
    pageIndex: 1,
    viewerRect: _rightViewer.topLeft & secondPageSize,
    pageSize: secondPageSize,
  );
  controller.selectText(text.id);
  return controller;
}

/// One whole drag of [handle] carrying [deltas], each cumulative.
void _drag(PdfAnnotationController controller, PdfAnnotationHandle handle, List<Offset> deltas) {
  controller.beginTextDrag(handle, pageSize: _pageSize);
  for (final delta in deltas) {
    if (handle == PdfAnnotationHandle.body) {
      controller.applyTextMoveViewer(delta);
    } else {
      controller.applyTextResize(delta);
    }
  }
  controller.endTextDrag();
}

/// Where the top-left corner of [rect] is on screen once the box is
/// turned by [rotationDeg] about its centre.
Offset _screenCornerOf(Rect rect, double rotationDeg) =>
    rotatePointToScreen(rect.topLeft, center: rect.center, rotationDeg: rotationDeg);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Text drag: move', () {
    test('a body drag translates a text area and keeps its size', () {
      final controller = _armed(_text(rect: const Rect.fromLTWH(100, 100, 80, 40)));
      addTearDown(controller.dispose);

      _drag(controller, PdfAnnotationHandle.body, const [Offset(20, 5)]);

      final moved = controller.texts.single;
      expect(moved.pageIndex, 0);
      expect(moved.rectInPdfSpace, const Rect.fromLTWH(120, 105, 80, 40));
      expect(moved.autoSize, isFalse);
    });

    test('a body drag hands the annotation to the page its centre crosses into', () {
      final controller = _armed(_text(rect: const Rect.fromLTWH(100, 100, 80, 40)));
      addTearDown(controller.dispose);

      _drag(controller, PdfAnnotationHandle.body, const [Offset(600, 0)]);

      final moved = controller.texts.single;
      expect(moved.pageIndex, 1);
      // Re-expressed in the destination page's PDF point space.
      expect(moved.rectInPdfSpace.left, closeTo(100, 1e-6));
      expect(moved.rectInPdfSpace.top, closeTo(100, 1e-6));
      expect(moved.rectInPdfSpace.size, const Size(80, 40));
    });

    test('auto-sized text re-wraps when moved toward the right edge, and returns to one line when moved back', () {
      final controller = _armed(_text(rect: const Rect.fromLTWH(100, 100, 90, 10), autoSize: true));
      addTearDown(controller.dispose);

      // Left edge at 550: 50 pt to the right page edge, room for one word.
      _drag(controller, PdfAnnotationHandle.body, const [Offset(450, 0)]);
      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(550, 100, 40, 20));
      expect(controller.texts.single.autoSize, isTrue);

      _drag(controller, PdfAnnotationHandle.body, const [Offset(-450, 0)]);
      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(100, 100, 90, 10));
      expect(controller.texts.single.autoSize, isTrue);
    });

    test('the re-wrap is live: within one drag the box follows the position under the finger', () {
      final controller = _armed(_text(rect: const Rect.fromLTWH(100, 100, 90, 10), autoSize: true));
      addTearDown(controller.dispose);

      controller.beginTextDrag(PdfAnnotationHandle.body, pageSize: _pageSize);
      controller.applyTextMoveViewer(const Offset(450, 0));
      expect(controller.texts.single.rectInPdfSpace.size, const Size(40, 20));
      controller.applyTextMoveViewer(const Offset(10, 0));
      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(110, 100, 90, 10));
      controller.endTextDrag();
    });

    test('auto-sized text moved to another page wraps at THAT page\'s right edge', () {
      final controller = _armed(
        _text(rect: const Rect.fromLTWH(100, 100, 90, 10), autoSize: true),
        secondPageSize: const Size(150, 800),
      );
      addTearDown(controller.dispose);

      // Centre 145 -> 745 in the viewer: on the narrow second page, left
      // edge at 100 of its 150 pt, so 50 pt of room.
      _drag(controller, PdfAnnotationHandle.body, const [Offset(600, 0)]);

      final moved = controller.texts.single;
      expect(moved.pageIndex, 1);
      expect(moved.rectInPdfSpace.left, closeTo(100, 1e-6));
      expect(moved.rectInPdfSpace.size, const Size(40, 20));
    });

    test('a box moved past the bottom edge is shifted up by the layout seam', () {
      final controller = _armed(_text(rect: const Rect.fromLTWH(100, 700, 80, 40)));
      addTearDown(controller.dispose);

      _drag(controller, PdfAnnotationHandle.body, const [Offset(0, 90)]);

      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(100, 760, 80, 40));
    });

    test('a body move is not clamped away from the side edges, as for stamps and rectangles', () {
      final controller = _armed(_text(rect: const Rect.fromLTWH(100, 100, 80, 40)));
      addTearDown(controller.dispose);

      // Centre 140 -> 590, still on page 0; the right edge lands at 630.
      _drag(controller, PdfAnnotationHandle.body, const [Offset(450, 0)]);

      expect(controller.texts.single.pageIndex, 0);
      expect(controller.texts.single.rectInPdfSpace.right, closeTo(630, 1e-6));
    });

    test('a drag starts from the DISPLAY box, not from a stored box another device measured', () {
      // Stored as 50 x 50 by a bandmate's metrics; here 'aaaa' is 40 x 10.
      final controller = _armed(_text(text: 'aaaa', rect: const Rect.fromLTWH(100, 100, 50, 50), autoSize: true));
      addTearDown(controller.dispose);

      _drag(controller, PdfAnnotationHandle.body, const [Offset(10, 0)]);

      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(110, 100, 40, 10));
    });
  });

  group('Text drag: rotate', () {
    test('rotation is a free angle about the centre with no snapping, and changes nothing else', () {
      final controller = _armed(_text(rect: const Rect.fromLTWH(100, 100, 90, 10), autoSize: true));
      addTearDown(controller.dispose);

      controller.beginTextDrag(PdfAnnotationHandle.rotation, pageSize: _pageSize);
      controller.applyTextRotate(37.5);
      controller.endTextDrag();

      final rotated = controller.texts.single;
      expect(rotated.rotationDeg, 37.5);
      expect(rotated.rectInPdfSpace, const Rect.fromLTWH(100, 100, 90, 10));
      expect(rotated.autoSize, isTrue);
      expect(rotated.fontSize, 10);
    });

    test('a rotate call is ignored during a resize drag, and a resize during a rotation', () {
      final controller = _armed(_text(rect: const Rect.fromLTWH(100, 100, 80, 40)));
      addTearDown(controller.dispose);

      controller.beginTextDrag(PdfAnnotationHandle.right, pageSize: _pageSize);
      controller.applyTextRotate(45);
      controller.endTextDrag();
      expect(controller.texts.single.rotationDeg, 0);

      controller.beginTextDrag(PdfAnnotationHandle.rotation, pageSize: _pageSize);
      controller.applyTextResize(const Offset(30, 30));
      controller.applyTextMoveViewer(const Offset(30, 30));
      controller.endTextDrag();
      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(100, 100, 80, 40));
    });
  });

  group('Text drag: resize a text area', () {
    test('a corner drag reshapes the box with free aspect and never changes the font size', () {
      final controller = _armed(_text(rect: const Rect.fromLTWH(100, 100, 80, 40)));
      addTearDown(controller.dispose);

      _drag(controller, PdfAnnotationHandle.bottomRight, const [Offset(20, 60)]);

      final resized = controller.texts.single;
      expect(resized.rectInPdfSpace, const Rect.fromLTWH(100, 100, 100, 100));
      expect(resized.fontSize, 10);
    });

    test('an edge drag moves only its own edge', () {
      final controller = _armed(_text(rect: const Rect.fromLTWH(100, 100, 80, 40)));
      addTearDown(controller.dispose);

      _drag(controller, PdfAnnotationHandle.left, const [Offset(-20, 30)]);

      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(80, 100, 100, 40));
    });

    test('narrowing a box until its text wraps grows it downward: never shorter than its content', () {
      final controller = _armed(_text(rect: const Rect.fromLTWH(100, 100, 100, 10)));
      addTearDown(controller.dispose);

      _drag(controller, PdfAnnotationHandle.right, const [Offset(-50, 0)]);

      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(100, 100, 50, 20));
    });

    test('the rewrap is live: each delta of the drag re-lays the text out', () {
      final controller = _armed(_text(rect: const Rect.fromLTWH(100, 100, 100, 10)));
      addTearDown(controller.dispose);

      controller.beginTextDrag(PdfAnnotationHandle.right, pageSize: _pageSize);
      controller.applyTextResize(const Offset(-50, 0));
      expect(controller.texts.single.rectInPdfSpace.size, const Size(50, 20));
      controller.applyTextResize(const Offset(-5, 0));
      // Back on one line, and back to the height the drag started from.
      expect(controller.texts.single.rectInPdfSpace.size, const Size(95, 10));
      controller.endTextDrag();
    });

    test('the bottom edge stops at the content height', () {
      // Two lines at 80 wide: the content is 20 tall.
      final controller = _armed(_text(rect: const Rect.fromLTWH(100, 100, 80, 40)));
      addTearDown(controller.dispose);

      _drag(controller, PdfAnnotationHandle.bottom, const [Offset(0, -35)]);

      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(100, 100, 80, 20));
    });

    test('the top edge stops at the content height too, and the bottom edge stays where it was', () {
      final controller = _armed(_text(rect: const Rect.fromLTWH(100, 100, 80, 40)));
      addTearDown(controller.dispose);

      _drag(controller, PdfAnnotationHandle.top, const [Offset(0, 35)]);

      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(100, 120, 80, 20));
    });

    test('each axis clamps at the minimum size rather than collapsing', () {
      final controller = _armed(_text(rect: const Rect.fromLTWH(100, 100, 80, 40)));
      addTearDown(controller.dispose);

      _drag(controller, PdfAnnotationHandle.right, const [Offset(-500, 0)]);

      final resized = controller.texts.single;
      expect(resized.rectInPdfSpace.left, 100);
      expect(resized.rectInPdfSpace.width, kMinAnnotationSizePts);
      // However narrow, nothing is clipped: the box holds its content.
      final box = controller.textDisplayBoxFor(resized, pageSize: _pageSize);
      expect(resized.rectInPdfSpace.height, greaterThanOrEqualTo(box.layout.size.height));
      expect(resized.fontSize, 10);
    });

    test('the dragged edges stop at the page edges; the anchored ones never move', () {
      final controller = _armed(_text(rect: const Rect.fromLTWH(500, 700, 80, 40)));
      addTearDown(controller.dispose);

      _drag(controller, PdfAnnotationHandle.bottomRight, const [Offset(300, 300)]);
      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTRB(500, 700, 600, 800));

      _drag(controller, PdfAnnotationHandle.topLeft, const [Offset(-900, -900)]);
      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTRB(0, 0, 600, 800));
    });

    test('the opposite edge of a rotated text area stays fixed on screen', () {
      // A quarter turn counter-clockwise: the box's own +x axis points UP
      // the screen, so pulling the right handle up by 20 widens it by 20.
      final controller = _armed(_text(rect: const Rect.fromLTWH(200, 300, 100, 40), rotationDeg: 90));
      addTearDown(controller.dispose);
      final before = controller.texts.single.rectInPdfSpace;

      _drag(controller, PdfAnnotationHandle.right, const [Offset(0, -20)]);

      final after = controller.texts.single.rectInPdfSpace;
      expect(after.size, const Size(120, 40));
      expect(_screenCornerOf(after, 90).dx, closeTo(_screenCornerOf(before, 90).dx, 1e-9));
      expect(_screenCornerOf(after, 90).dy, closeTo(_screenCornerOf(before, 90).dy, 1e-9));
    });

    test('when the content of a rotated box grows, its top-left corner stays fixed on screen', () {
      final controller = _armed(_text(rect: const Rect.fromLTWH(200, 300, 100, 10), rotationDeg: 90));
      addTearDown(controller.dispose);
      final before = controller.texts.single.rectInPdfSpace;

      // Pulling the right handle DOWN the screen narrows the box by 50:
      // the text wraps and the content doubles in height.
      _drag(controller, PdfAnnotationHandle.right, const [Offset(0, 50)]);

      final after = controller.texts.single.rectInPdfSpace;
      expect(after.size, const Size(50, 20));
      expect(_screenCornerOf(after, 90).dx, closeTo(_screenCornerOf(before, 90).dx, 1e-9));
      expect(_screenCornerOf(after, 90).dy, closeTo(_screenCornerOf(before, 90).dy, 1e-9));
    });
  });

  group('Text drag: auto-sized text becomes a text area', () {
    test('dragging a resize handle converts it at the dragged size, and rewraps', () {
      final controller = _armed(_text(rect: const Rect.fromLTWH(100, 100, 90, 10), autoSize: true));
      addTearDown(controller.dispose);

      _drag(controller, PdfAnnotationHandle.right, const [Offset(-40, 0)]);

      final converted = controller.texts.single;
      expect(converted.autoSize, isFalse);
      expect(converted.rectInPdfSpace, const Rect.fromLTWH(100, 100, 50, 20));
      expect(converted.fontSize, 10);
    });

    test('the conversion and the resize are ONE undo step, and the undo restores auto-sized text', () {
      final controller = _armed(_text(rect: const Rect.fromLTWH(100, 100, 90, 10), autoSize: true));
      addTearDown(controller.dispose);

      _drag(controller, PdfAnnotationHandle.bottomRight, const [Offset(10, 10), Offset(20, 20), Offset(30, 30)]);
      expect(controller.texts.single.autoSize, isFalse);
      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(100, 100, 120, 40));

      controller.undo();
      expect(controller.texts.single.autoSize, isTrue);
      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(100, 100, 90, 10));
      expect(controller.canUndoListenable.value, isFalse);

      controller.redo();
      expect(controller.texts.single.autoSize, isFalse);
    });

    test('the conversion is one-way: no later move, rotation or edit makes it auto-sized again', () {
      final controller = _armed(_text(rect: const Rect.fromLTWH(100, 100, 90, 10), autoSize: true));
      addTearDown(controller.dispose);
      _drag(controller, PdfAnnotationHandle.right, const [Offset(30, 0)]);
      expect(controller.texts.single.autoSize, isFalse);

      _drag(controller, PdfAnnotationHandle.body, const [Offset(15, 15)]);
      controller.beginTextDrag(PdfAnnotationHandle.rotation, pageSize: _pageSize);
      controller.applyTextRotate(10);
      controller.endTextDrag();
      controller.beginTextEdit('text-1', pageSize: _pageSize);
      controller.updateTextEdit('cc');
      controller.commitTextEdit();

      final text = controller.texts.single;
      expect(text.autoSize, isFalse);
      // Still 120 wide: a text area does not hug its content.
      expect(text.rectInPdfSpace.width, closeTo(120, 1e-9));
    });

    test('a body drag or a rotation does NOT convert', () {
      final controller = _armed(_text(rect: const Rect.fromLTWH(100, 100, 90, 10), autoSize: true));
      addTearDown(controller.dispose);

      _drag(controller, PdfAnnotationHandle.body, const [Offset(15, 15)]);
      controller.beginTextDrag(PdfAnnotationHandle.rotation, pageSize: _pageSize);
      controller.applyTextRotate(10);
      controller.endTextDrag();

      expect(controller.texts.single.autoSize, isTrue);
    });
  });

  group('Text drag: undo and lifecycle', () {
    test('each drag pushes exactly one undo snapshot, however many deltas it carries', () {
      final controller = _armed(_text(rect: const Rect.fromLTWH(100, 100, 80, 40)));
      addTearDown(controller.dispose);

      _drag(controller, PdfAnnotationHandle.body, const [Offset(5, 5), Offset(10, 10), Offset(15, 15)]);
      controller.beginTextDrag(PdfAnnotationHandle.rotation, pageSize: _pageSize);
      controller.applyTextRotate(10);
      controller.applyTextRotate(20);
      controller.endTextDrag();

      controller.undo();
      expect(controller.texts.single.rotationDeg, 0);
      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(115, 115, 80, 40));
      controller.undo();
      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(100, 100, 80, 40));
      expect(controller.canUndoListenable.value, isFalse);
    });

    test('a drag bumps the shape-drag tick and the paint sequence carries the live geometry', () {
      final controller = _armed(_text(rect: const Rect.fromLTWH(100, 100, 80, 40)));
      addTearDown(controller.dispose);
      var ticks = 0;
      controller.stampDragChangedListenable.addListener(() => ticks++);
      controller.paintSequenceForPage(0);

      controller.beginTextDrag(PdfAnnotationHandle.body, pageSize: _pageSize);
      controller.applyTextMoveViewer(const Offset(20, 0));

      expect(ticks, 1);
      final entry = controller.paintSequenceForPage(0).single as PdfTextPaintEntry;
      expect(entry.text.rectInPdfSpace.left, 120);
      controller.endTextDrag();
    });

    test('a drag cut short by a pointer-cancel ends cleanly', () {
      final controller = _armed(_text(rect: const Rect.fromLTWH(100, 100, 90, 10), autoSize: true));
      addTearDown(controller.dispose);

      // Begun, never moved: nothing converted, nothing relocated.
      controller.beginTextDrag(PdfAnnotationHandle.right, pageSize: _pageSize);
      controller.endTextDrag();
      controller.endTextDrag();
      expect(controller.texts.single.autoSize, isTrue);
      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(100, 100, 90, 10));

      // An apply after the end is a no-op, and the next drag starts fresh.
      controller.applyTextResize(const Offset(50, 50));
      expect(controller.texts.single.autoSize, isTrue);
      _drag(controller, PdfAnnotationHandle.body, const [Offset(5, 0)]);
      expect(controller.texts.single.rectInPdfSpace.left, 105);
    });

    test('exitMode drops a half-finished drag', () async {
      final controller = _armed(_text(rect: const Rect.fromLTWH(100, 100, 80, 40)));
      addTearDown(controller.dispose);
      controller.beginTextDrag(PdfAnnotationHandle.body, pageSize: _pageSize);

      await controller.exitMode(onAnnotationsChanged: null);

      // A drag that outlived the session must not keep mutating.
      controller.applyTextMoveViewer(const Offset(300, 300));
      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(100, 100, 80, 40));
    });

    test('no drag starts while an edit is in progress', () {
      final controller = _armed(_text(rect: const Rect.fromLTWH(100, 100, 80, 40)));
      addTearDown(controller.dispose);
      controller.beginTextEdit('text-1', pageSize: _pageSize);

      _drag(controller, PdfAnnotationHandle.body, const [Offset(50, 50)]);
      controller.commitTextEdit();

      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(100, 100, 80, 40));
      expect(controller.canUndoListenable.value, isFalse);
    });
  });

  group('Text drag: ownership', () {
    test('a bandmate\'s text annotation cannot be moved, resized or rotated', () {
      final controller = _armed(
        _text(id: 'theirs', rect: const Rect.fromLTWH(100, 100, 90, 10), autoSize: true, creatorName: 'bob'),
      );
      addTearDown(controller.dispose);
      expect(controller.selectedTextIdListenable.value, isNull);

      // Every mutator is gated on a selection, so nothing can move it.
      controller.beginTextDrag(PdfAnnotationHandle.body, pageSize: _pageSize);
      controller.applyTextMoveViewer(const Offset(50, 50));
      controller.endTextDrag();
      controller.beginTextDrag(PdfAnnotationHandle.right, pageSize: _pageSize);
      controller.applyTextResize(const Offset(50, 50));
      controller.endTextDrag();
      controller.beginTextDrag(PdfAnnotationHandle.rotation, pageSize: _pageSize);
      controller.applyTextRotate(45);
      controller.endTextDrag();

      final theirs = controller.texts.single;
      expect(theirs.rectInPdfSpace, const Rect.fromLTWH(100, 100, 90, 10));
      expect(theirs.rotationDeg, 0);
      expect(theirs.autoSize, isTrue);
      expect(controller.canUndoListenable.value, isFalse);
    });
  });
}
