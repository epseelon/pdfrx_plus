import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_layer.dart';

import '_test_helpers/fake_pdf_page.dart';

const _pageSize = Size(200, 200);

Widget _stampPlaceholder(BuildContext context, Uint8List bytes, String contentType, Size displaySize) {
  return SizedBox.fromSize(
    size: displaySize,
    child: const ColoredBox(color: Color(0xFFCCCCCC)),
  );
}

/// Mounts two annotation layers side-by-side at fixed viewer positions
/// so cross-page hit-testing has stable coordinates.
Future<void> _pumpTwoPageLayers(WidgetTester tester, PdfAnnotationController controller) async {
  final pageA = FakePdfPage(pageNumber: 1, width: _pageSize.width, height: _pageSize.height);
  final pageB = FakePdfPage(pageNumber: 2, width: _pageSize.width, height: _pageSize.height);
  await tester.pumpWidget(
    MaterialApp(
      home: Directionality(
        textDirection: TextDirection.ltr,
        child: Scaffold(
          body: SizedBox(
            width: 400,
            height: 200,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  key: const Key('layerA'),
                  left: 0,
                  top: 0,
                  width: 200,
                  height: 200,
                  child: PdfAnnotationLayer(
                    controller: controller,
                    page: pageA,
                    pageRect: const Rect.fromLTWH(0, 0, 200, 200),
                    highlighterOpacity: 0.35,
                    stampImageBuilder: _stampPlaceholder,
                  ),
                ),
                Positioned(
                  key: const Key('layerB'),
                  left: 200,
                  top: 0,
                  width: 200,
                  height: 200,
                  child: PdfAnnotationLayer(
                    controller: controller,
                    page: pageB,
                    pageRect: const Rect.fromLTWH(200, 0, 200, 200),
                    highlighterOpacity: 0.35,
                    stampImageBuilder: _stampPlaceholder,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'dragging a stamp body across the page boundary reassigns pageIndex and selection works on the new page',
    (
      tester,
    ) async {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.stamp);
      controller.placeStamp(
        bytes: Uint8List.fromList([1]),
        contentType: 'image/svg+xml',
        pageIndex: 0,
        pdfPoint: const Offset(100, 100),
        intrinsicSize: const Size(24, 24),
        pageSize: _pageSize,
        idGenerator: () => 'a',
      );

      await _pumpTwoPageLayers(tester, controller);
      controller.selectStamp('a');
      await tester.pump();

      // Sanity: at start the stamp lives on page 0 (left layer).
      expect(controller.stamps.single.pageIndex, 0);
      expect(find.byKey(const Key('stampSelection:a')), findsOneWidget);

      // Drive a body drag entirely through the controller (the layer
      // wires the same call from real touch input). 200 viewer pixels to
      // the right lands the centroid in page 1's viewer rect.
      controller.beginStampDrag(PdfStampHandle.body);
      controller.applyStampMoveViewer(const Offset(200, 0));
      controller.endStampDrag();
      await tester.pump();

      expect(controller.stamps.single.pageIndex, 1);
      // The selection overlay key now lives in layer B.
      expect(find.byKey(const Key('stampSelection:a')), findsOneWidget);

      // Tap somewhere on layer B (the right half of the viewer). The
      // controller should keep the selection (or re-select).
      controller.clearStampSelection();
      await tester.pump();
      expect(controller.selectedStampIdListenable.value, isNull);

      // Tap the new stamp center — at viewer (300, 100), inside layer B.
      final layerBOrigin = tester.getTopLeft(find.byKey(const Key('layerB')));
      await tester.tapAt(layerBOrigin + const Offset(100, 100));
      await tester.pumpAndSettle();

      // Layer B's tap pipeline now sees the stamp in its pageStamps and
      // selects it.
      expect(controller.selectedStampIdListenable.value, 'a');
    },
  );
}
