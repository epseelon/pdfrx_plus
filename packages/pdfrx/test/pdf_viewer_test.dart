import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pdfrx/pdfrx.dart';

final testPdfFile = File('example/viewer/assets/hello.pdf');
final binding = TestWidgetsFlutterBinding.ensureInitialized();

/// Pump until the viewer has laid out and is ready to interact.
///
/// [PdfViewerController.isReady] reports only that the DOCUMENT loaded.
/// `_layout` and `_viewSize` are set one rebuild later, inside the
/// `LayoutBuilder` that only runs once `_document != null`, so a test that
/// stops at `isReady` reaches `controller.layout` / `viewSize` / `setZoom`
/// a frame too early and dies on a null check.
///
/// These loops used to also spin while `controller.alternativeFitScale`
/// was null, which WAS a real layout guard back when it was a nullable
/// field left null until the layout existed. Upstream `52862d9` turned it
/// into a getter that falls back to `_defaultMinScale` and can never return
/// null, so the guard quietly became a no-op. `onViewerReady` is the
/// documented "ready to interact" signal, so spin on that instead.
Future<void> pumpUntilViewerReady(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 20 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
  }
  expect(ready(), isTrue, reason: 'PdfViewer did not become ready to interact within 20 pumps');
}

void main() {
  // For testing purpose, we should run on the command line
  // and pdfrxInitialize is a better way to initialize the library.
  setUp(() => pdfrxInitialize());
  Pdfrx.createHttpClient = () => MockClient((request) async {
    return http.Response.bytes(await testPdfFile.readAsBytes(), 200);
  });

  testWidgets('PdfViewer.uri', (tester) async {
    await binding.setSurfaceSize(Size(1080, 1920));
    addTearDown(() => binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        // FIXME: Just a workaround for "A RenderFlex overflowed..."
        home: SingleChildScrollView(child: PdfViewer.uri(Uri.parse('https://example.com/hello.pdf'))),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.byType(PdfViewer), findsOneWidget);
  });

  testWidgets('top page anchor keeps underflowing page top aligned', (tester) async {
    await binding.setSurfaceSize(Size(1000, 2000));
    addTearDown(() => binding.setSurfaceSize(null));
    final controller = PdfViewerController();
    var viewerReady = false;
    final document = await tester.runAsync(
      () async => PdfDocument.openData(
        await testPdfFile.readAsBytes(),
        sourceName: 'top-anchor-test.pdf',
        useProgressiveLoading: false,
      ),
    );
    addTearDown(() => document?.dispose());

    await tester.pumpWidget(
      MaterialApp(
        home: PdfViewer(
          PdfDocumentRefDirect(document!),
          controller: controller,
          params: PdfViewerParams(
            minScale: 0.1,
            useAlternativeFitScaleAsMinScale: false,
            onViewerReady: (_, _) => viewerReady = true,
            behaviorControlParams: const PdfViewerBehaviorControlParams(trailingPageLoadingDelay: Duration.zero),
          ),
        ),
      ),
    );

    await pumpUntilViewerReady(tester, () => viewerReady);
    expect(controller.isReady, isTrue);
    expect(controller.params.pageAnchor, PdfPageAnchor.top);

    final underflowZoom = controller.alternativeFitScale! * 0.5;
    await controller.setZoom(Offset.zero, underflowZoom, duration: Duration.zero);
    await controller.goToPage(pageNumber: 1, anchor: PdfPageAnchor.top, duration: Duration.zero);
    await tester.pump();

    final pageTopInViewport =
        (controller.layout.pageLayouts.first.top - controller.visibleRect.top) * controller.currentZoom;

    expect(pageTopInViewport, moreOrLessEquals(controller.params.margin * controller.currentZoom, epsilon: 0.1));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('landscape page is centered in portrait viewport by default', (tester) async {
    await binding.setSurfaceSize(Size(500, 1000));
    addTearDown(() => binding.setSurfaceSize(null));
    final controller = PdfViewerController();
    var viewerReady = false;
    final document = await tester.runAsync(
      () async => PdfDocument.openData(
        await testPdfFile.readAsBytes(),
        sourceName: 'landscape-default-center-test.pdf',
        useProgressiveLoading: false,
      ),
    );
    addTearDown(() => document?.dispose());

    await tester.pumpWidget(
      MaterialApp(
        home: PdfViewer(
          PdfDocumentRefDirect(document!),
          controller: controller,
          params: PdfViewerParams(
            onViewerReady: (_, _) => viewerReady = true,
            layoutPages: (pages, params, helper) {
              const pageSize = Size(1000, 500);
              final pageLayouts = [
                for (final _ in pages) Rect.fromLTWH(params.margin, params.margin, pageSize.width, pageSize.height),
              ];
              return PdfPageLayout(
                pageLayouts: pageLayouts,
                documentSize: Size(pageSize.width + params.margin * 2, pageSize.height + params.margin * 2),
              );
            },
            behaviorControlParams: const PdfViewerBehaviorControlParams(trailingPageLoadingDelay: Duration.zero),
          ),
        ),
      ),
    );

    await pumpUntilViewerReady(tester, () => viewerReady);
    expect(controller.isReady, isTrue);

    final pageRect = controller.layout.pageLayouts.first;
    final pageCenterYInViewport = (pageRect.center.dy - controller.visibleRect.top) * controller.currentZoom;

    expect(pageCenterYInViewport, moreOrLessEquals(controller.viewSize.height / 2, epsilon: 0.1));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('underflow anchor places a landscape page at the top of a portrait viewport', (tester) async {
    await binding.setSurfaceSize(Size(500, 1000));
    addTearDown(() => binding.setSurfaceSize(null));
    final controller = PdfViewerController();
    var viewerReady = false;
    final document = await tester.runAsync(
      () async => PdfDocument.openData(
        await testPdfFile.readAsBytes(),
        sourceName: 'underflow-anchor-test.pdf',
        useProgressiveLoading: false,
      ),
    );
    addTearDown(() => document?.dispose());

    await tester.pumpWidget(
      MaterialApp(
        home: PdfViewer(
          PdfDocumentRefDirect(document!),
          controller: controller,
          params: PdfViewerParams(
            underflowAnchor: PdfPageAnchor.top,
            onViewerReady: (_, _) => viewerReady = true,
            layoutPages: (pages, params, helper) {
              const pageSize = Size(1000, 500);
              final pageLayouts = [
                for (final _ in pages) Rect.fromLTWH(params.margin, params.margin, pageSize.width, pageSize.height),
              ];
              return PdfPageLayout(
                pageLayouts: pageLayouts,
                documentSize: Size(pageSize.width + params.margin * 2, pageSize.height + params.margin * 2),
              );
            },
            behaviorControlParams: const PdfViewerBehaviorControlParams(trailingPageLoadingDelay: Duration.zero),
          ),
        ),
      ),
    );

    await pumpUntilViewerReady(tester, () => viewerReady);
    expect(controller.isReady, isTrue);

    final pageTopInViewport =
        (controller.layout.pageLayouts.first.top - controller.visibleRect.top) * controller.currentZoom;

    expect(pageTopInViewport, moreOrLessEquals(controller.params.margin * controller.currentZoom, epsilon: 0.1));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('scale disabled ignores ctrl wheel zoom', (tester) async {
    await binding.setSurfaceSize(Size(1000, 2000));
    addTearDown(() => binding.setSurfaceSize(null));
    final controller = PdfViewerController();
    var viewerReady = false;
    final document = await tester.runAsync(
      () async => PdfDocument.openData(
        await testPdfFile.readAsBytes(),
        sourceName: 'scale-disabled-ctrl-wheel-test.pdf',
        useProgressiveLoading: false,
      ),
    );
    addTearDown(() => document?.dispose());

    await tester.pumpWidget(
      MaterialApp(
        home: PdfViewer(
          PdfDocumentRefDirect(document!),
          controller: controller,
          params: PdfViewerParams(
            scaleEnabled: false,
            onViewerReady: (_, _) => viewerReady = true,
            behaviorControlParams: const PdfViewerBehaviorControlParams(trailingPageLoadingDelay: Duration.zero),
          ),
        ),
      ),
    );

    await pumpUntilViewerReady(tester, () => viewerReady);
    expect(controller.isReady, isTrue);
    await tester.pump();

    final zoomBefore = controller.currentZoom;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);

    binding.handlePointerEvent(
      const PointerScrollEvent(
        position: Offset(500, 1000),
        scrollDelta: Offset(0, -120),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await tester.pump();

    expect(controller.currentZoom, zoomBefore);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
  });

  test('default page anchor remains top', () {
    expect(const PdfViewerParams().pageAnchor, PdfPageAnchor.top);
    expect(const PdfViewerParams().underflowAnchor, isNull);
  });
}
