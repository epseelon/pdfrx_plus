import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_layer.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_stamp_definition.dart';

import '_test_helpers/fake_pdf_page.dart';

const _pageSize = Size(200, 200);

Widget _stampPlaceholder(BuildContext context, Uint8List bytes, String contentType, Size displaySize) {
  return SizedBox.fromSize(
    size: displaySize,
    child: const ColoredBox(color: Color(0xFFCCCCCC)),
  );
}

Future<void> _pumpLayer(
  WidgetTester tester,
  PdfAnnotationController controller,
) async {
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
              stampImageBuilder: _stampPlaceholder,
            ),
          ),
        ),
      ),
    ),
  );
}

void _placeAt(
  PdfAnnotationController controller, {
  required String id,
  Offset pdfPoint = const Offset(100, 100),
  String creator = 'alice',
}) {
  // Re-enter mode under the requested creator so the stamp inherits it.
  controller.enterMode(creatorName: creator, tool: PdfAnnotationTool.stamp);
  controller.placeStamp(
    bytes: Uint8List.fromList([1]),
    contentType: 'image/svg+xml',
    pageIndex: 0,
    pdfPoint: pdfPoint,
    intrinsicSize: const Size(24, 24),
    pageSize: _pageSize,
    idGenerator: () => id,
  );
}

void main() {
  testWidgets('tap on selectable stamp body sets selectedStampIdListenable', (tester) async {
    final controller = PdfAnnotationController();
    addTearDown(controller.dispose);
    _placeAt(controller, id: 'a');
    await _pumpLayer(tester, controller);

    final layerCenter = tester.getCenter(find.byKey(const Key('layerHost')));
    await tester.tapAt(layerCenter);
    await tester.pumpAndSettle();

    expect(controller.selectedStampIdListenable.value, 'a');
  });

  testWidgets('tap on empty area while selected clears the selection', (tester) async {
    final controller = PdfAnnotationController();
    addTearDown(controller.dispose);
    _placeAt(controller, id: 'a');
    await _pumpLayer(tester, controller);

    // Pre-select.
    controller.selectStamp('a');
    await tester.pump();

    // Tap on the top-left of the layer host (well outside the stamp's
    // bbox at ~82..118 in pdf points — the host is 200×200).
    final layerHost = find.byKey(const Key('layerHost'));
    final tl = tester.getTopLeft(layerHost);
    await tester.tapAt(tl + const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(controller.selectedStampIdListenable.value, isNull);
  });

  testWidgets('tap on a foreign-creator stamp does not select it', (tester) async {
    final controller = PdfAnnotationController();
    addTearDown(controller.dispose);
    _placeAt(controller, id: 'bob-1', creator: 'bob');

    // Switch to alice's session — bob's stamp is foreign.
    controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.stamp);
    await _pumpLayer(tester, controller);

    final layerCenter = tester.getCenter(find.byKey(const Key('layerHost')));
    await tester.tapAt(layerCenter);
    await tester.pumpAndSettle();

    expect(controller.selectedStampIdListenable.value, isNull);
  });

  testWidgets(
    'tap on empty area while a stamp is selected deselects rather than placing the armed pending stamp',
    (tester) async {
      // The picker's "armed" state should NOT cause the next empty tap
      // to drop a new stamp when the user is explicitly trying to
      // dismiss the current selection. Two separate taps are needed:
      // one to deselect, the next to place.
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      _placeAt(controller, id: 'a');

      // Arm a definition before pumping so the layer's tap handler
      // sees a non-null pending value.
      controller.setPendingStamp(
        PdfStampDefinition(
          id: 'sharp',
          name: 'sharp',
          contentType: 'image/svg+xml',
          bytesLoader: () async => Uint8List.fromList([9, 9, 9]),
          intrinsicSize: const Size(24, 24),
        ),
      );
      controller.selectStamp('a');

      await _pumpLayer(tester, controller);
      expect(controller.selectedStampIdListenable.value, 'a');

      // First tap on empty area: deselects, does NOT place.
      final tl = tester.getTopLeft(find.byKey(const Key('layerHost')));
      await tester.tapAt(tl + const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(controller.selectedStampIdListenable.value, isNull);
      expect(controller.stamps, hasLength(1));

      // Second tap on empty area (no selection now, pending still
      // armed): drops a new stamp.
      await tester.tapAt(tl + const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(controller.stamps, hasLength(2));
    },
  );

  testWidgets(
    'tap on the floating delete button (outside bbox) removes the selected stamp',
    (tester) async {
      // Regression: the delete button used to be an interactive
      // InkWell at top:1, right:1. Moving it OUTSIDE the bbox broke
      // tap delivery because Flutter's hit-test is bounded by the
      // parent Positioned. The tap now flows through the Listener and
      // _handleStampTap routes it to deleteStamp.
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      _placeAt(controller, id: 'a');
      controller.selectStamp('a');

      await _pumpLayer(tester, controller);
      expect(controller.stamps, hasLength(1));

      // Stamp center is at PDF (100, 100) with 36×36 bbox → top edge
      // at y≈82, right edge at x≈118. The delete button floats at
      // (right + 8) … (right + 8 + 24) on x and (top - 8 - 24) …
      // (top - 8) on y. Aim near the center of that rect: ≈(138, 62).
      final layerOrigin = tester.getTopLeft(find.byKey(const Key('layerHost')));
      await tester.tapAt(layerOrigin + const Offset(138, 62));
      await tester.pumpAndSettle();

      expect(controller.stamps, isEmpty);
    },
  );

  testWidgets('tap-selecting and tap-deselecting both update the rendered selection overlay', (tester) async {
    // Regression: the layer's AnimatedBuilder used to listen only to
    // the controller + drag tick, so selectStamp/clearStampSelection
    // mutated the value silently and the overlay only appeared after a
    // separate state change kicked off a rebuild.
    final controller = PdfAnnotationController();
    addTearDown(controller.dispose);
    _placeAt(controller, id: 'a');
    await _pumpLayer(tester, controller);

    final selectionFinder = find.byKey(const Key('stampSelection:a'));
    expect(selectionFinder, findsNothing);

    final layerCenter = tester.getCenter(find.byKey(const Key('layerHost')));
    await tester.tapAt(layerCenter);
    await tester.pumpAndSettle();

    expect(selectionFinder, findsOneWidget);

    // Tap outside to deselect.
    final tl = tester.getTopLeft(find.byKey(const Key('layerHost')));
    await tester.tapAt(tl + const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(controller.selectedStampIdListenable.value, isNull);
    expect(selectionFinder, findsNothing);
  });
}
