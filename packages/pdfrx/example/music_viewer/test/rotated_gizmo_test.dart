import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_layer.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_overlay_labels.dart';

import '_test_helpers/fake_pdf_page.dart';

// The layer is mounted 1:1 with the page, so PDF points and layer
// pixels coincide and the arithmetic below reads directly.
const _pageSize = Size(200, 200);

Widget _stampPlaceholder(BuildContext context, Uint8List bytes, String contentType, Size displaySize) {
  return SizedBox.fromSize(
    size: displaySize,
    child: const ColoredBox(color: Color(0xFFCCCCCC)),
  );
}

Future<void> _pumpLayer(
  WidgetTester tester,
  PdfAnnotationController controller, {
  PdfAnnotationOverlayLabels labels = const PdfAnnotationOverlayLabels(),
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
              pageRect: const Rect.fromLTWH(0, 0, 200, 200),
              highlighterOpacity: 0.35,
              stampImageBuilder: _stampPlaceholder,
              labels: labels,
            ),
          ),
        ),
      ),
    ),
  );
}

/// Places a 36x36 stamp centred on (100, 100) and selects it.
void _placeAndSelect(PdfAnnotationController controller) {
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
  controller.selectStamp('a');
}

void _rotateTo(PdfAnnotationController controller, double deg) {
  controller.beginStampDrag(PdfAnnotationHandle.rotation);
  controller.applyStampRotate(deg);
  controller.endStampDrag();
}

/// Where [localPoint] is drawn once the shape is turned [rotationDeg]
/// degrees counter-clockwise about [center].
Offset _onScreen(Offset localPoint, {required Offset center, required double rotationDeg}) {
  final theta = -rotationDeg * math.pi / 180.0;
  final v = localPoint - center;
  return center +
      Offset(
        v.dx * math.cos(theta) - v.dy * math.sin(theta),
        v.dx * math.sin(theta) + v.dy * math.cos(theta),
      );
}

void main() {
  testWidgets('a rotated stamp\'s delete button is tappable where it is drawn, not where it was', (tester) async {
    final controller = PdfAnnotationController();
    addTearDown(controller.dispose);
    _placeAndSelect(controller);
    _rotateTo(controller, 90);
    await _pumpLayer(tester, controller);

    final origin = tester.getTopLeft(find.byKey(const Key('layerHost')));
    // Stamp bbox is 82..118 on both axes (no selection padding here).
    // The delete button floats at (right + 8) .. (right + 32) on x and
    // (top - 32) .. (top - 8) on y, so its unrotated centre is (138, 62).
    const unrotatedDeleteCentre = Offset(138, 62);
    final drawnDeleteCentre = _onScreen(unrotatedDeleteCentre, center: const Offset(100, 100), rotationDeg: 90);

    // A tap where the button *used* to be must miss it.
    await tester.tapAt(origin + unrotatedDeleteCentre);
    await tester.pumpAndSettle();
    expect(controller.stamps, hasLength(1), reason: 'the unrotated position is no longer the delete button');

    // Re-select: the missed tap landed on empty space and deselected.
    controller.selectStamp('a');
    await tester.pump();

    // A tap where it is now drawn must hit it.
    await tester.tapAt(origin + drawnDeleteCentre);
    await tester.pumpAndSettle();
    expect(controller.stamps, isEmpty);
  });

  testWidgets('a rotated stamp resizes from the corner handle where it is drawn', (tester) async {
    final controller = PdfAnnotationController();
    addTearDown(controller.dispose);
    _placeAndSelect(controller);
    _rotateTo(controller, 90);
    await _pumpLayer(tester, controller);

    final origin = tester.getTopLeft(find.byKey(const Key('layerHost')));
    final orig = controller.stamps.single.rectInPdfSpace;
    final drawnBottomRight = _onScreen(orig.bottomRight, center: orig.center, rotationDeg: 90);

    // Press on the drawn corner and drag along the shape's own +x axis,
    // which at 90° points up the screen.
    final gesture = await tester.startGesture(origin + drawnBottomRight);
    await tester.pump();
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final after = controller.stamps.single.rectInPdfSpace;
    expect(after.width, greaterThan(orig.width), reason: 'the corner handle was grabbed where it is drawn');
    // The opposite corner stayed put on screen.
    final anchorBefore = _onScreen(orig.topLeft, center: orig.center, rotationDeg: 90);
    final anchorAfter = _onScreen(after.topLeft, center: after.center, rotationDeg: 90);
    expect(anchorAfter.dx, closeTo(anchorBefore.dx, 1e-6));
    expect(anchorAfter.dy, closeTo(anchorBefore.dy, 1e-6));
  });

  testWidgets('the overlay renders the supplied labels rather than the English defaults', (tester) async {
    final controller = PdfAnnotationController();
    addTearDown(controller.dispose);
    _placeAndSelect(controller);
    await _pumpLayer(
      tester,
      controller,
      labels: const PdfAnnotationOverlayLabels(
        rotate: 'Pivoter',
        delete: 'Supprimer',
        resizeTopLeft: 'Redimensionner en haut à gauche',
      ),
    );

    final semantics = tester.widgetList<Semantics>(find.byType(Semantics)).map((s) => s.properties.label).toList();
    expect(semantics, contains('Pivoter'));
    expect(semantics, contains('Supprimer'));
    expect(semantics, contains('Redimensionner en haut à gauche'));
    expect(semantics, isNot(contains('Rotate')));
    expect(semantics, isNot(contains('Delete')));
    // The delete control keeps its visible tooltip, now localised.
    expect(find.byTooltip('Supprimer'), findsOneWidget);
    // Handles that were not overridden fall back to the English default.
    expect(semantics, contains('Resize bottom-right'));
  });
}
