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
