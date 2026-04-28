import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_viewer/main_page.dart';
import 'package:pdfrx/pdfrx.dart';

Widget _toolButtonsHarness({
  required ValueNotifier<PdfAnnotationTool> toolListenable,
  required ValueChanged<PdfAnnotationTool> onSelectTool,
}) => MaterialApp(
  home: Scaffold(
    body: AnnotationToolButtons(toolListenable: toolListenable, onSelectTool: onSelectTool),
  ),
);

void main() {
  group('AnnotationToolButtons', () {
    testWidgets('renders Pen, Highlighter, and Eraser buttons with stable tooltip selectors', (tester) async {
      final tool = ValueNotifier<PdfAnnotationTool>(PdfAnnotationTool.pen);
      addTearDown(tool.dispose);

      await tester.pumpWidget(_toolButtonsHarness(toolListenable: tool, onSelectTool: (_) {}));

      expect(find.byTooltip('Pen'), findsOneWidget);
      expect(find.byTooltip('Highlighter'), findsOneWidget);
      expect(find.byTooltip('Eraser'), findsOneWidget);
    });

    testWidgets('tapping Highlighter calls onSelectTool with PdfAnnotationTool.highlighter', (tester) async {
      final tool = ValueNotifier<PdfAnnotationTool>(PdfAnnotationTool.pen);
      addTearDown(tool.dispose);
      PdfAnnotationTool? selected;

      await tester.pumpWidget(_toolButtonsHarness(toolListenable: tool, onSelectTool: (t) => selected = t));

      await tester.tap(find.byTooltip('Highlighter'));
      await tester.pump();

      expect(selected, PdfAnnotationTool.highlighter);
    });

    testWidgets('selection state follows toolListenable', (tester) async {
      final tool = ValueNotifier<PdfAnnotationTool>(PdfAnnotationTool.pen);
      addTearDown(tool.dispose);

      await tester.pumpWidget(_toolButtonsHarness(toolListenable: tool, onSelectTool: (_) {}));

      IconButton btnByTooltip(String tt) => tester.widget<IconButton>(
        find.ancestor(of: find.byTooltip(tt), matching: find.byType(IconButton)),
      );
      expect(btnByTooltip('Pen').isSelected, isTrue);
      expect(btnByTooltip('Highlighter').isSelected, isFalse);

      tool.value = PdfAnnotationTool.highlighter;
      await tester.pump();

      expect(btnByTooltip('Pen').isSelected, isFalse);
      expect(btnByTooltip('Highlighter').isSelected, isTrue);

      tool.value = PdfAnnotationTool.eraser;
      await tester.pump();

      expect(btnByTooltip('Highlighter').isSelected, isFalse);
      expect(btnByTooltip('Eraser').isSelected, isTrue);
    });
  });

  group('AnnotationStylePopups', () {
    Widget popupHarness(PdfViewerController controller, PdfAnnotationTool tool) => MaterialApp(
      home: Scaffold(
        body: AnnotationStylePopups(controller: controller, tool: tool),
      ),
    );

    testWidgets('highlighter tool exposes Highlighter color + Highlighter thickness tooltips', (tester) async {
      final controller = PdfViewerController();
      await tester.pumpWidget(popupHarness(controller, PdfAnnotationTool.highlighter));

      expect(find.byTooltip('Highlighter color'), findsOneWidget);
      expect(find.byTooltip('Highlighter thickness'), findsOneWidget);
      expect(find.byTooltip('Color'), findsNothing);
      expect(find.byTooltip('Pen thickness'), findsNothing);
      expect(find.byTooltip('Eraser size'), findsNothing);
    });

    testWidgets('selecting a highlighter swatch updates annotationHighlighterColorListenable', (tester) async {
      final controller = PdfViewerController();
      await tester.pumpWidget(popupHarness(controller, PdfAnnotationTool.highlighter));

      await tester.tap(find.byTooltip('Highlighter color'));
      await tester.pumpAndSettle();
      // Pick the pink swatch from the popup menu. The popup menu item
      // wraps the text in a layout that the tap-to-text offset can
      // miss; tapping the CheckedPopupMenuItem directly avoids the
      // hit-test warning.
      await tester.tap(find.widgetWithText(CheckedPopupMenuItem<Color>, 'Pink'));
      await tester.pumpAndSettle();

      expect(controller.annotationHighlighterColor, const Color(0xFFFF69B4));
    });

    testWidgets('eraser tool shows only the Eraser size popup', (tester) async {
      final controller = PdfViewerController();
      await tester.pumpWidget(popupHarness(controller, PdfAnnotationTool.eraser));

      expect(find.byTooltip('Eraser size'), findsOneWidget);
      expect(find.byTooltip('Color'), findsNothing);
      expect(find.byTooltip('Highlighter color'), findsNothing);
      expect(find.byTooltip('Pen thickness'), findsNothing);
      expect(find.byTooltip('Highlighter thickness'), findsNothing);
    });

    testWidgets('pen tool shows the Color + Pen thickness popups', (tester) async {
      final controller = PdfViewerController();
      await tester.pumpWidget(popupHarness(controller, PdfAnnotationTool.pen));

      expect(find.byTooltip('Color'), findsOneWidget);
      expect(find.byTooltip('Pen thickness'), findsOneWidget);
      expect(find.byTooltip('Highlighter color'), findsNothing);
      expect(find.byTooltip('Eraser size'), findsNothing);
    });
  });
}
