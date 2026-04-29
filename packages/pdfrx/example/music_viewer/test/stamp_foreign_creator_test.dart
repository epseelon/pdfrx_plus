import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';

const _pageSize = Size(200, 200);

void _place(PdfAnnotationController controller, String id) {
  controller.placeStamp(
    bytes: Uint8List.fromList([1]),
    contentType: 'image/svg+xml',
    pageIndex: 0,
    pdfPoint: const Offset(50, 50),
    intrinsicSize: const Size(24, 24),
    pageSize: _pageSize,
    idGenerator: () => id,
  );
}

void main() {
  test(
    'foreign-creator stamp: deleteStamp is a no-op, own-stamp deletion succeeds',
    () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);

      // alice places her stamp, bob places his.
      controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.stamp);
      _place(controller, 'alice-1');
      controller.enterMode(creatorName: 'bob', tool: PdfAnnotationTool.stamp);
      _place(controller, 'bob-1');

      // Now back to alice's session.
      controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.stamp);

      // bob's stamp cannot be deleted by alice.
      controller.deleteStamp('bob-1');
      expect(controller.stamps.map((s) => s.id), unorderedEquals(['alice-1', 'bob-1']));

      // alice's own stamp deletes successfully.
      controller.deleteStamp('alice-1');
      expect(controller.stamps.map((s) => s.id), ['bob-1']);
    },
  );

  test('foreign-creator stamp cannot be selected by current creator', () {
    final controller = PdfAnnotationController();
    addTearDown(controller.dispose);

    controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.stamp);
    _place(controller, 'alice-1');
    controller.enterMode(creatorName: 'bob', tool: PdfAnnotationTool.stamp);
    _place(controller, 'bob-1');

    controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.stamp);

    // Try to select bob's stamp — selection state stays at null.
    controller.selectStamp('bob-1');
    expect(controller.selectedStampIdListenable.value, isNull);

    // Selecting alice's own stamp succeeds.
    controller.selectStamp('alice-1');
    expect(controller.selectedStampIdListenable.value, 'alice-1');
  });
}
