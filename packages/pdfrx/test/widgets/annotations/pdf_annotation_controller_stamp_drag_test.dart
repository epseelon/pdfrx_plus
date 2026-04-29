import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';

const _pageSize = Size(200, 200);

PdfAnnotationController _makeController({String? creator = 'alice'}) {
  final controller = PdfAnnotationController();
  controller.enterMode(creatorName: creator, tool: PdfAnnotationTool.stamp);
  return controller;
}

void _placeAt(
  PdfAnnotationController controller, {
  required String id,
  Offset point = const Offset(100, 100),
  Size intrinsic = const Size(24, 24),
}) {
  controller.placeStamp(
    bytes: Uint8List.fromList([1]),
    contentType: 'image/svg+xml',
    pageIndex: 0,
    pdfPoint: point,
    intrinsicSize: intrinsic,
    pageSize: _pageSize,
    idGenerator: () => id,
  );
}

void main() {
  group('PdfAnnotationController.beginStampDrag / endStampDrag', () {
    test('no-op when nothing is selected', () {
      final controller = _makeController();
      addTearDown(controller.dispose);
      _placeAt(controller, id: 'a');
      // No selection.
      controller.beginStampDrag(PdfStampHandle.body);
      // Move call without an active drag is a no-op too.
      controller.applyStampMove(const Offset(50, 0));
      final stamp = controller.stamps.single;
      expect(stamp.rectInPdfSpace.center.dx, closeTo(100, 1e-9));
    });

    test('foreign-creator selection cannot be dragged', () {
      final controller = _makeController(creator: 'alice');
      addTearDown(controller.dispose);
      _placeAt(controller, id: 'alice-1');
      controller.enterMode(creatorName: 'bob');
      controller.beginStampDrag(
        PdfStampHandle.body,
      ); // selectedId is null after creator switch? actually selection is independent, but selectStamp checks ownership.
      controller.selectStamp('alice-1');
      // bob doesn't own alice-1, so selection is rejected.
      expect(controller.selectedStampIdListenable.value, isNull);
    });
  });

  group('applyStampMove', () {
    test('translates rect by cumulative delta and pushes one undo snapshot per drag', () {
      final controller = _makeController();
      addTearDown(controller.dispose);
      _placeAt(controller, id: 'a');
      controller.selectStamp('a');

      controller.beginStampDrag(PdfStampHandle.body);
      controller.applyStampMove(const Offset(10, 0));
      controller.applyStampMove(const Offset(20, 5));
      controller.endStampDrag();

      final stamp = controller.stamps.single;
      // Original center was 100,100 → topLeft was 82,82. New rect.shift(20,5) → 102,87.
      expect(stamp.rectInPdfSpace.left, closeTo(82 + 20, 1e-9));
      expect(stamp.rectInPdfSpace.top, closeTo(82 + 5, 1e-9));

      // Undo restores the pre-drag rect (one snapshot per drag).
      controller.undo();
      expect(controller.stamps.single.rectInPdfSpace.left, closeTo(82, 1e-9));
    });
  });

  group('applyStampResize', () {
    test('topLeft handle shrinks the bbox from the top-left corner', () {
      final controller = _makeController();
      addTearDown(controller.dispose);
      _placeAt(controller, id: 'a');
      controller.selectStamp('a');

      final original = controller.stamps.single.rectInPdfSpace;

      controller.beginStampDrag(PdfStampHandle.topLeft);
      controller.applyStampResize(const Offset(4, 4));
      controller.endStampDrag();

      final after = controller.stamps.single.rectInPdfSpace;
      expect(after.left, closeTo(original.left + 4, 1e-9));
      expect(after.top, closeTo(original.top + 4, 1e-9));
      expect(after.right, closeTo(original.right, 1e-9));
      expect(after.bottom, closeTo(original.bottom, 1e-9));
    });

    test('corner handle preserves the start-of-drag aspect ratio (non-square)', () {
      final controller = _makeController();
      addTearDown(controller.dispose);
      // Place a stamp with a 2:1 intrinsic — placeStamp scales the
      // longest side to 36 pt, giving a 36×18 rect.
      controller.placeStamp(
        bytes: Uint8List.fromList([1]),
        contentType: 'image/svg+xml',
        pageIndex: 0,
        pdfPoint: const Offset(100, 100),
        intrinsicSize: const Size(48, 24),
        pageSize: _pageSize,
        idGenerator: () => 'a',
      );
      controller.selectStamp('a');
      final orig = controller.stamps.single.rectInPdfSpace;
      expect(orig.width / orig.height, closeTo(2.0, 1e-9));

      // Drag bottomRight by (10, 10). Width-axis pull is 10/36; height
      // pull is 10/18 — so height dominates, scale ≈ 28/18.
      controller.beginStampDrag(PdfStampHandle.bottomRight);
      controller.applyStampResize(const Offset(10, 10));
      controller.endStampDrag();

      final after = controller.stamps.single.rectInPdfSpace;
      // Aspect preserved.
      expect(after.width / after.height, closeTo(orig.width / orig.height, 1e-9));
      // Top-left anchored.
      expect(after.left, closeTo(orig.left, 1e-9));
      expect(after.top, closeTo(orig.top, 1e-9));
      // Dominant-axis (height) pull determines the scale.
      expect(after.height, closeTo(orig.height + 10, 1e-9));
      expect(after.width, closeTo(orig.width * (orig.height + 10) / orig.height, 1e-9));
    });

    test('edge handle stretches a single axis (aspect ratio changes)', () {
      final controller = _makeController();
      addTearDown(controller.dispose);
      _placeAt(controller, id: 'a');
      controller.selectStamp('a');

      final orig = controller.stamps.single.rectInPdfSpace;

      controller.beginStampDrag(PdfStampHandle.right);
      controller.applyStampResize(const Offset(20, 99)); // dy ignored on edge
      controller.endStampDrag();

      final after = controller.stamps.single.rectInPdfSpace;
      expect(after.left, closeTo(orig.left, 1e-9));
      expect(after.top, closeTo(orig.top, 1e-9));
      expect(after.bottom, closeTo(orig.bottom, 1e-9));
      expect(after.right, closeTo(orig.right + 20, 1e-9));
      // Aspect changed (it's no longer 1:1 like the original square).
      expect(after.width / after.height, isNot(closeTo(orig.width / orig.height, 1e-9)));
    });

    test('clamps bbox to a minimum size of 8 PDF points', () {
      final controller = _makeController();
      addTearDown(controller.dispose);
      _placeAt(controller, id: 'a');
      controller.selectStamp('a');

      final original = controller.stamps.single.rectInPdfSpace;

      // Drag the bottom-right corner inward by more than the original
      // dimensions — the bbox must clamp to >= 8 pt on each axis.
      controller.beginStampDrag(PdfStampHandle.bottomRight);
      controller.applyStampResize(const Offset(-100, -100));
      controller.endStampDrag();

      final after = controller.stamps.single.rectInPdfSpace;
      expect(after.width, kMinStampSizePts);
      expect(after.height, kMinStampSizePts);
      // Top-left edge stays where it was; bottom-right snaps to min.
      expect(after.left, closeTo(original.left, 1e-9));
      expect(after.top, closeTo(original.top, 1e-9));
    });
  });

  group('applyStampRotate', () {
    test('rotates the selected stamp by the absolute angle and pushes one undo snapshot', () {
      final controller = _makeController();
      addTearDown(controller.dispose);
      _placeAt(controller, id: 'a');
      controller.selectStamp('a');

      controller.beginStampDrag(PdfStampHandle.rotation);
      controller.applyStampRotate(45);
      controller.applyStampRotate(90);
      controller.endStampDrag();

      expect(controller.stamps.single.rotationDeg, 90);

      controller.undo();
      expect(controller.stamps.single.rotationDeg, 0);
    });
  });

  group('applyStampMoveViewer (cross-page body drag)', () {
    // Two pages of equal PDF size, mounted side-by-side in viewer
    // pixel space. PDF→viewer scale is 1:1 here for arithmetic
    // simplicity. Pages are 200pt wide; viewer rects are 200px wide
    // and abut at x = 200.
    const leftViewer = Rect.fromLTWH(0, 0, 200, 200);
    const rightViewer = Rect.fromLTWH(200, 0, 200, 200);

    void registerTwoPages(PdfAnnotationController c) {
      c.registerPageLayout(pageIndex: 0, viewerRect: leftViewer, pageSize: _pageSize);
      c.registerPageLayout(pageIndex: 1, viewerRect: rightViewer, pageSize: _pageSize);
    }

    test('reassigns pageIndex when bbox center crosses into another page', () {
      final controller = _makeController();
      addTearDown(controller.dispose);
      registerTwoPages(controller);
      _placeAt(controller, id: 'a', point: const Offset(100, 100));
      controller.selectStamp('a');

      // Drag right by 200 viewer pixels — centroid lands at viewer
      // (300, 100), which is inside the right page's viewer rect.
      controller.beginStampDrag(PdfStampHandle.body);
      controller.applyStampMoveViewer(const Offset(200, 0));
      controller.endStampDrag();

      final stamp = controller.stamps.single;
      expect(stamp.pageIndex, 1);
      // Rect is now expressed in the new page's PDF point space, so
      // its center should be at (100, 100) in page-1's local space.
      expect(stamp.rectInPdfSpace.center.dx, closeTo(100, 1e-6));
      expect(stamp.rectInPdfSpace.center.dy, closeTo(100, 1e-6));
    });

    test('keeps pageIndex when bbox center stays within the original page', () {
      final controller = _makeController();
      addTearDown(controller.dispose);
      registerTwoPages(controller);
      _placeAt(controller, id: 'a', point: const Offset(100, 100));
      controller.selectStamp('a');

      controller.beginStampDrag(PdfStampHandle.body);
      controller.applyStampMoveViewer(const Offset(20, 5));
      controller.endStampDrag();

      final stamp = controller.stamps.single;
      expect(stamp.pageIndex, 0);
      expect(stamp.rectInPdfSpace.center.dx, closeTo(120, 1e-6));
      expect(stamp.rectInPdfSpace.center.dy, closeTo(105, 1e-6));
    });

    test('falls back to original page when new center is in a gutter', () {
      final controller = _makeController();
      addTearDown(controller.dispose);
      // Two pages with a 40-pixel gutter between them.
      controller.registerPageLayout(pageIndex: 0, viewerRect: leftViewer, pageSize: _pageSize);
      controller.registerPageLayout(
        pageIndex: 1,
        viewerRect: const Rect.fromLTWH(240, 0, 200, 200),
        pageSize: _pageSize,
      );
      _placeAt(controller, id: 'a', point: const Offset(100, 100));
      controller.selectStamp('a');

      // Drag so the centroid lands at viewer (220, 100) — squarely in
      // the gutter, not in either page's viewer rect.
      controller.beginStampDrag(PdfStampHandle.body);
      controller.applyStampMoveViewer(const Offset(120, 0));
      controller.endStampDrag();

      final stamp = controller.stamps.single;
      // pageIndex stays put because no registered page contains the
      // new center.
      expect(stamp.pageIndex, 0);
    });

    test('one undo snapshot covers the whole cross-page drag', () {
      final controller = _makeController();
      addTearDown(controller.dispose);
      registerTwoPages(controller);
      _placeAt(controller, id: 'a', point: const Offset(100, 100));
      controller.selectStamp('a');

      controller.beginStampDrag(PdfStampHandle.body);
      // Multiple intermediate moves — the second crosses the boundary.
      controller.applyStampMoveViewer(const Offset(50, 0));
      controller.applyStampMoveViewer(const Offset(200, 0));
      controller.endStampDrag();

      expect(controller.stamps.single.pageIndex, 1);

      controller.undo();
      final restored = controller.stamps.single;
      expect(restored.pageIndex, 0);
      expect(restored.rectInPdfSpace.center.dx, closeTo(100, 1e-6));
    });

    test('no-op when active handle is not body', () {
      final controller = _makeController();
      addTearDown(controller.dispose);
      registerTwoPages(controller);
      _placeAt(controller, id: 'a', point: const Offset(100, 100));
      controller.selectStamp('a');

      controller.beginStampDrag(PdfStampHandle.topLeft);
      controller.applyStampMoveViewer(const Offset(200, 0));
      controller.endStampDrag();

      // Stamp didn't move; pageIndex didn't change.
      final stamp = controller.stamps.single;
      expect(stamp.pageIndex, 0);
      expect(stamp.rectInPdfSpace.center.dx, closeTo(100, 1e-6));
    });

    test('no-op when original page layout is not registered', () {
      final controller = _makeController();
      addTearDown(controller.dispose);
      // Don't register page 0.
      controller.registerPageLayout(pageIndex: 1, viewerRect: rightViewer, pageSize: _pageSize);
      _placeAt(controller, id: 'a', point: const Offset(100, 100));
      controller.selectStamp('a');

      controller.beginStampDrag(PdfStampHandle.body);
      controller.applyStampMoveViewer(const Offset(200, 0));
      controller.endStampDrag();

      // Move was rejected because page 0's layout is unknown.
      final stamp = controller.stamps.single;
      expect(stamp.pageIndex, 0);
      expect(stamp.rectInPdfSpace.center.dx, closeTo(100, 1e-6));
    });
  });

  group('selection state', () {
    test('selectStamp accepts own stamp; rejects foreign-creator stamps', () {
      final controller = _makeController(creator: 'alice');
      addTearDown(controller.dispose);
      _placeAt(controller, id: 'alice-1');

      controller.selectStamp('alice-1');
      expect(controller.selectedStampIdListenable.value, 'alice-1');

      controller.enterMode(creatorName: 'bob');
      controller.selectStamp('alice-1');
      // bob can't select alice's stamp; selection unchanged from the
      // controller's pre-call value (still alice-1 because selectStamp
      // is a no-op when the target is foreign).
      expect(controller.selectedStampIdListenable.value, 'alice-1');
    });
  });
}
