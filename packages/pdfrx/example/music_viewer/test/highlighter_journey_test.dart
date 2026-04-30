import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_layer.dart';

import '_test_helpers/fake_pdf_page.dart';
import '_test_helpers/toolbar_widgets.dart';

/// Journey test: tap Highlighter via the toolbar's stable tooltip
/// selector, drag a programmatic pan on the [PdfAnnotationLayer] in
/// isolation, exit mode, capture the `onAnnotationsChanged` JSON,
/// decode it via [decodeInstantJson], and assert the resulting
/// [PdfInkAnnotation] has `kind == PdfInkAnnotationKind.highlighter`,
/// the configured opacity, and the selected highlighter width.
///
/// We deliberately mount only the toolbar + the annotation layer (with
/// a fake [PdfPage]) instead of the full `MainPage` — building a real
/// `PdfDocumentRef` for a journey test is impractical. This follows
/// the precedent set by `AnnotationUndoRedoButtons` in
/// `main_page_annotation_toolbar_test.dart`.
void main() {
  testWidgets('Highlighter happy path: tap → draw → exit → JSON decodes as highlighter', (tester) async {
    const highlighterOpacity = 0.35;
    const pageSize = Size(200, 200);

    final controller = PdfAnnotationController();
    addTearDown(controller.dispose);

    final page = FakePdfPage(pageNumber: 1, width: pageSize.width, height: pageSize.height);

    String? capturedJson;
    Future<void> onAnnotationsChanged(String json) async => capturedJson = json;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnnotationToolButtons(
                toolListenable: controller.currentToolListenable,
                onSelectTool: controller.setTool,
              ),
              SizedBox(
                key: const Key('layerHost'),
                width: pageSize.width,
                height: pageSize.height,
                child: PdfAnnotationLayer(
                  controller: controller,
                  page: page,
                  pageRect: Rect.fromLTWH(0, 0, pageSize.width, pageSize.height),
                  highlighterOpacity: highlighterOpacity,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // Enter annotation mode (in real app, this is FAB → controller.enterAnnotationMode).
    controller.enterMode(creatorName: 'alice');
    await tester.pump();

    // Tap Highlighter via the stable tooltip selector.
    await tester.tap(find.byTooltip('Highlighter'));
    await tester.pump();
    expect(controller.currentToolListenable.value, PdfAnnotationTool.highlighter);

    // Adjust the highlighter width to a non-default to prove the layer
    // reads it at pan-start.
    controller.setHighlighterWidth(16.0);
    await tester.pump();

    // Drive a programmatic pan on the layer's GestureDetector.
    final layerCenter = tester.getCenter(find.byKey(const Key('layerHost')));
    await tester.dragFrom(layerCenter, const Offset(60, 0));
    await tester.pumpAndSettle();

    // Exit mode and capture the export.
    await controller.exitMode(onAnnotationsChanged: onAnnotationsChanged);

    expect(capturedJson, isNotNull);

    final decoded = decodeInstantJson(
      capturedJson!,
      pageCount: 1,
      defaultColor: const Color(0xFFFF0000),
      defaultLineWidth: 1.0,
    );

    expect(decoded, hasLength(1));
    final stroke = decoded.single;
    expect(stroke.kind, PdfInkAnnotationKind.highlighter);
    expect(stroke.opacity, closeTo(highlighterOpacity, 1e-9));
    expect(stroke.lineWidth, controller.highlighterWidth);
  });
}
