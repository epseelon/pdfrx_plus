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
}
