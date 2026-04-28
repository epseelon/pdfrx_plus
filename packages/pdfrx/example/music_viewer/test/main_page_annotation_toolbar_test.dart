import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_viewer/main_page.dart';

class _StubHistory {
  final canUndo = ValueNotifier<bool>(false);
  final canRedo = ValueNotifier<bool>(false);
  int undoCalls = 0;
  int redoCalls = 0;

  void dispose() {
    canUndo.dispose();
    canRedo.dispose();
  }
}

Widget _harness(_StubHistory history) => MaterialApp(
  home: Scaffold(
    body: AnnotationUndoRedoButtons(
      canUndoListenable: history.canUndo,
      canRedoListenable: history.canRedo,
      onUndo: () => history.undoCalls++,
      onRedo: () => history.redoCalls++,
    ),
  ),
);

Finder _undoButton() => find.widgetWithIcon(IconButton, Icons.undo);
Finder _redoButton() => find.widgetWithIcon(IconButton, Icons.redo);

void main() {
  testWidgets('Undo and Redo are disabled when their listenables are false', (tester) async {
    final history = _StubHistory();
    addTearDown(history.dispose);

    await tester.pumpWidget(_harness(history));

    expect(find.byTooltip('Undo'), findsOneWidget);
    expect(find.byTooltip('Redo'), findsOneWidget);
    expect(tester.widget<IconButton>(_undoButton()).onPressed, isNull);
    expect(tester.widget<IconButton>(_redoButton()).onPressed, isNull);
  });

  testWidgets('Undo enables when canUndoListenable flips to true and the tap fires onUndo', (tester) async {
    final history = _StubHistory();
    addTearDown(history.dispose);
    await tester.pumpWidget(_harness(history));

    history.canUndo.value = true;
    await tester.pump();

    expect(tester.widget<IconButton>(_undoButton()).onPressed, isNotNull);
    await tester.tap(_undoButton());
    expect(history.undoCalls, 1);
  });

  testWidgets('Redo enables when canRedoListenable flips to true and the tap fires onRedo', (tester) async {
    final history = _StubHistory();
    addTearDown(history.dispose);
    await tester.pumpWidget(_harness(history));

    history.canRedo.value = true;
    await tester.pump();

    expect(tester.widget<IconButton>(_redoButton()).onPressed, isNotNull);
    await tester.tap(_redoButton());
    expect(history.redoCalls, 1);
  });
}
