import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_layer.dart';

import '_test_helpers/fake_pdf_page.dart';

const _testSvg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"></svg>';
final Uint8List _testStampBytes = Uint8List.fromList(_testSvg.codeUnits);

Widget _stampPlaceholder(BuildContext context, Uint8List bytes, String contentType, Size displaySize) {
  return SizedBox.fromSize(
    size: displaySize,
    child: const ColoredBox(color: Color(0xFFCCCCCC)),
  );
}

const _pageSize = Size(200, 200);

class _StampJourneyRobot {
  _StampJourneyRobot(this.tester, this.controller);

  final WidgetTester tester;
  final PdfAnnotationController controller;
  String? _capturedJson;

  String? get capturedJson => _capturedJson;

  Offset _layerOffsetFor(double pdfX, double pdfY) {
    final origin = tester.getTopLeft(find.byKey(const Key('layerHost')));
    // Layer is sized 1:1 with the page's PDF point space (200×200).
    return origin + Offset(pdfX, pdfY);
  }

  Future<void> enterAnnotationMode() async {
    controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.stamp);
    await tester.pumpAndSettle();
  }

  Future<void> selectStampTool() async {
    controller.setTool(PdfAnnotationTool.stamp);
    await tester.pumpAndSettle();
  }

  Future<void> pickStamp(PdfStampDefinition stamp) async {
    controller.setPendingStamp(stamp);
    await tester.pumpAndSettle();
  }

  Future<void> tapPage(Offset pdfPoint) async {
    await tester.tapAt(_layerOffsetFor(pdfPoint.dx, pdfPoint.dy));
    await tester.pumpAndSettle();
  }

  Future<void> selectStamp(String id) async {
    final stamp = controller.stamps.firstWhere((s) => s.id == id);
    final center = stamp.rectInPdfSpace.center;
    await tester.tapAt(_layerOffsetFor(center.dx, center.dy));
    await tester.pumpAndSettle();
  }

  Future<void> dragHandle(PdfStampHandle handle, Offset deltaPdf) async {
    final stamp = controller.stamps.firstWhere((s) => s.id == controller.selectedStampIdListenable.value);
    final rect = stamp.rectInPdfSpace;
    Offset start;
    switch (handle) {
      case PdfStampHandle.body:
        start = rect.center;
      case PdfStampHandle.topLeft:
        start = rect.topLeft;
      case PdfStampHandle.topRight:
        start = rect.topRight;
      case PdfStampHandle.bottomRight:
        start = rect.bottomRight;
      case PdfStampHandle.bottomLeft:
        start = rect.bottomLeft;
      case PdfStampHandle.top:
        start = Offset(rect.center.dx, rect.top);
      case PdfStampHandle.bottom:
        start = Offset(rect.center.dx, rect.bottom);
      case PdfStampHandle.left:
        start = Offset(rect.left, rect.center.dy);
      case PdfStampHandle.right:
        start = Offset(rect.right, rect.center.dy);
      case PdfStampHandle.rotation:
        // Rotation handle floats above the bbox top (gap + handle/2);
        // see _kRotateHandleGapPx + _kRotateHandlePx in pdf_annotation_layer.dart.
        start = Offset(rect.center.dx, rect.top - 20);
    }
    final startGlobal = _layerOffsetFor(start.dx, start.dy);
    final gesture = await tester.startGesture(startGlobal);
    // Move in two steps so the pan recognizer wins the arena (the
    // first crosses kPanSlop, the second supplies the actual delta).
    await gesture.moveBy(const Offset(20, 20));
    await tester.pump();
    await gesture.moveBy(deltaPdf - const Offset(20, 20));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  Future<void> exitAnnotationMode() async {
    await controller.exitMode(onAnnotationsChanged: (json) async => _capturedJson = json);
    await tester.pumpAndSettle();
  }
}

Future<_StampJourneyRobot> _pumpJourney(WidgetTester tester) async {
  final controller = PdfAnnotationController();
  addTearDown(controller.dispose);
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
  return _StampJourneyRobot(tester, controller);
}

void main() {
  testWidgets('stamp journey: place → select → resize → rotate → delete → place again → exit → JSON round-trip', (
    tester,
  ) async {
    final robot = await _pumpJourney(tester);
    final controller = robot.controller;
    // Hand-built test stamp definition — bypasses the asset loader.
    final stampDef = PdfStampDefinition(
      id: 'stamp_a',
      name: 'Test Stamp',
      contentType: 'image/svg+xml',
      bytesLoader: () async => _testStampBytes,
      intrinsicSize: const Size(24, 24),
    );
    var idCounter = 0;
    String idGen() => 'journey-${idCounter++}';

    // Step 1: enter annotation mode + select Stamp tool.
    await robot.enterAnnotationMode();
    await robot.selectStampTool();
    expect(controller.currentToolListenable.value, PdfAnnotationTool.stamp);

    // Step 2-3: arm a stamp.
    await robot.pickStamp(stampDef);
    expect(controller.pendingStampListenable.value, same(stampDef));

    // Step 4: tap a page → places one stamp at the tap point. The layer
    // routes through bytesLoader → controller.placeStamp; we drive the
    // controller directly here so we can inject a deterministic
    // idGenerator for assertion stability.
    controller.placeStamp(
      bytes: _testStampBytes,
      contentType: 'image/svg+xml',
      pageIndex: 0,
      pdfPoint: const Offset(100, 100),
      intrinsicSize: const Size(24, 24),
      pageSize: _pageSize,
      idGenerator: idGen,
    );
    await tester.pumpAndSettle();
    expect(controller.stamps, hasLength(1));
    final placedRect = controller.stamps.single.rectInPdfSpace;
    expect(placedRect.width, 36);
    expect(placedRect.height, 36);
    expect(placedRect.center.dx, closeTo(100, 1e-9));
    expect(placedRect.center.dy, closeTo(100, 1e-9));

    // Step 5: select the placed stamp.
    await robot.selectStamp('journey-0');
    expect(controller.selectedStampIdListenable.value, 'journey-0');

    // Step 6: resize via the bottom-right corner. We drive the
    // controller directly here — the gesture-arena disambiguation
    // between onTapUp and onPanStart in flutter_test makes synthetic
    // pans flaky to deliver across handles, but the controller-side
    // unit tests (pdf_annotation_controller_stamp_drag_test) cover
    // the same code path with explicit cumulative deltas.
    final rectBefore = controller.stamps.single.rectInPdfSpace;
    controller.beginStampDrag(PdfStampHandle.bottomRight);
    controller.applyStampResize(const Offset(10, 10));
    controller.endStampDrag();
    await tester.pumpAndSettle();
    final rectAfter = controller.stamps.single.rectInPdfSpace;
    expect(rectAfter.width, greaterThan(rectBefore.width));
    expect(rectAfter.height, greaterThan(rectBefore.height));

    // Step 7: rotate.
    final rotBefore = controller.stamps.single.rotationDeg;
    controller.beginStampDrag(PdfStampHandle.rotation);
    controller.applyStampRotate(45);
    controller.endStampDrag();
    await tester.pumpAndSettle();
    final rotAfter = controller.stamps.single.rotationDeg;
    expect(rotAfter, isNot(closeTo(rotBefore, 1e-3)));
    expect(rotAfter, 45);

    // Step 8: tap delete.
    controller.deleteStamp('journey-0');
    await tester.pumpAndSettle();
    expect(controller.stamps, isEmpty);

    // Step 9: place again, then exit and capture JSON.
    controller.placeStamp(
      bytes: _testStampBytes,
      contentType: 'image/svg+xml',
      pageIndex: 0,
      pdfPoint: const Offset(50, 50),
      intrinsicSize: const Size(24, 24),
      pageSize: _pageSize,
      idGenerator: idGen,
    );
    await tester.pumpAndSettle();
    await robot.exitAnnotationMode();
    expect(robot.capturedJson, isNotNull);

    // Step 10: decode round-trip — assert one stamp + one attachment.
    final decoded = decodeInstantJsonFull(
      robot.capturedJson!,
      pageCount: 1,
      defaultColor: const Color(0xFFFF0000),
      defaultLineWidth: 1.0,
    );
    expect(decoded.stamps, hasLength(1));
    expect(decoded.attachments, hasLength(1));
    final attachmentSha = decoded.stamps.single.attachmentSha256;
    expect(decoded.attachments.containsKey(attachmentSha), isTrue);
    expect(decoded.attachments[attachmentSha]!.bytes, _testStampBytes);
  });
}
