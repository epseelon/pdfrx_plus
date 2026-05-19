import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_viewer/main_page.dart';
import 'package:pdfrx/pdfrx.dart';

import '_test_helpers/toolbar_widgets.dart';

void main() {
  group('annotationNavigationAvailable', () {
    test('available when annotation mode is off, for any tool', () {
      expect(annotationNavigationAvailable(false, PdfAnnotationTool.pen), isTrue);
      expect(annotationNavigationAvailable(false, PdfAnnotationTool.hand), isTrue);
    });

    test('available when annotating with the hand tool', () {
      expect(annotationNavigationAvailable(true, PdfAnnotationTool.hand), isTrue);
    });

    test('unavailable when annotating with a drawing tool', () {
      expect(annotationNavigationAvailable(true, PdfAnnotationTool.pen), isFalse);
      expect(annotationNavigationAvailable(true, PdfAnnotationTool.highlighter), isFalse);
      expect(annotationNavigationAvailable(true, PdfAnnotationTool.eraser), isFalse);
      expect(annotationNavigationAvailable(true, PdfAnnotationTool.stamp), isFalse);
    });
  });

  group('planPageStep', () {
    test('moves within the document when not at a boundary', () {
      final plan = planPageStep(currentSpreadStart: 1, step: 2, pageCount: 6, annotating: false);
      expect(plan.outcome, PageStepOutcome.goToPage);
      expect(plan.page, 3);
    });

    test('switches document at the forward boundary when annotation mode is off', () {
      final plan = planPageStep(currentSpreadStart: 5, step: 2, pageCount: 6, annotating: false);
      expect(plan.outcome, PageStepOutcome.switchDocument);
    });

    test('switches document at the backward boundary when annotation mode is off', () {
      final plan = planPageStep(currentSpreadStart: 1, step: -2, pageCount: 6, annotating: false);
      expect(plan.outcome, PageStepOutcome.switchDocument);
    });

    test('stays at the forward boundary while annotation mode is active', () {
      final plan = planPageStep(currentSpreadStart: 5, step: 2, pageCount: 6, annotating: true);
      expect(plan.outcome, PageStepOutcome.stayAtBoundary);
    });

    test('stays at the backward boundary while annotation mode is active', () {
      final plan = planPageStep(currentSpreadStart: 1, step: -2, pageCount: 6, annotating: true);
      expect(plan.outcome, PageStepOutcome.stayAtBoundary);
    });

    test('moves within the document while annotating when not at a boundary', () {
      final plan = planPageStep(currentSpreadStart: 1, step: 2, pageCount: 6, annotating: true);
      expect(plan.outcome, PageStepOutcome.goToPage);
      expect(plan.page, 3);
    });
  });

  group('AnnotationToolButtons hand tool', () {
    Widget harness(ValueNotifier<PdfAnnotationTool> tool, {ValueChanged<PdfAnnotationTool>? onSelect}) => MaterialApp(
      home: Scaffold(
        body: AnnotationToolButtons(toolListenable: tool, onSelectTool: onSelect ?? (_) {}),
      ),
    );

    testWidgets('hand button is present and is the first tool button', (tester) async {
      final tool = ValueNotifier<PdfAnnotationTool>(PdfAnnotationTool.pen);
      addTearDown(tool.dispose);
      await tester.pumpWidget(harness(tool));

      expect(find.byTooltip('Hand'), findsOneWidget);
      final firstButton = tester.widgetList<IconButton>(find.byType(IconButton)).first;
      expect(firstButton.key, const Key('annotationToolHand'));
    });

    testWidgets('a divider separates the hand button from the pen button', (tester) async {
      final tool = ValueNotifier<PdfAnnotationTool>(PdfAnnotationTool.pen);
      addTearDown(tool.dispose);
      await tester.pumpWidget(harness(tool));

      expect(find.byType(VerticalDivider), findsOneWidget);
    });

    testWidgets('tapping hand calls onSelectTool with PdfAnnotationTool.hand', (tester) async {
      final tool = ValueNotifier<PdfAnnotationTool>(PdfAnnotationTool.pen);
      addTearDown(tool.dispose);
      PdfAnnotationTool? selected;
      await tester.pumpWidget(harness(tool, onSelect: (t) => selected = t));

      await tester.tap(find.byTooltip('Hand'));
      await tester.pump();

      expect(selected, PdfAnnotationTool.hand);
    });

    testWidgets('hand button selection state follows the tool listenable', (tester) async {
      final tool = ValueNotifier<PdfAnnotationTool>(PdfAnnotationTool.pen);
      addTearDown(tool.dispose);
      await tester.pumpWidget(harness(tool));

      IconButton handButton() => tester.widget<IconButton>(find.byKey(const Key('annotationToolHand')));
      expect(handButton().isSelected, isFalse);

      tool.value = PdfAnnotationTool.hand;
      await tester.pump();
      expect(handButton().isSelected, isTrue);
    });
  });
}
