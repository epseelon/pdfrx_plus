import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pdfrx/src/widgets/internals/pdf_viewer_key_handler.dart';

void main() {
  Future<KeyEventResult?> sendKeyEvent(WidgetTester tester, KeyEvent event) async {
    final focusNode = Focus.of(tester.element(find.byType(SizedBox)));
    return focusNode.onKeyEvent?.call(focusNode, event);
  }

  testWidgets('KeyUp is ignored when KeyDown was not handled (regression for #585)', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PdfViewerKeyHandler(
          params: const PdfViewerKeyHandlerParams(),
          onKeyRepeat: (_, _, _) => false,
          child: const SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const downEvent = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.escape,
      logicalKey: LogicalKeyboardKey.escape,
      timeStamp: Duration.zero,
    );
    const upEvent = KeyUpEvent(
      physicalKey: PhysicalKeyboardKey.escape,
      logicalKey: LogicalKeyboardKey.escape,
      timeStamp: Duration.zero,
    );

    expect(await sendKeyEvent(tester, downEvent), KeyEventResult.ignored);
    expect(await sendKeyEvent(tester, upEvent), KeyEventResult.ignored);
  });

  testWidgets('KeyUp is handled only when KeyDown was handled', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PdfViewerKeyHandler(
          params: const PdfViewerKeyHandlerParams(),
          onKeyRepeat: (_, key, _) => key == LogicalKeyboardKey.arrowDown,
          child: const SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const handledDown = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.arrowDown,
      logicalKey: LogicalKeyboardKey.arrowDown,
      timeStamp: Duration.zero,
    );
    const handledUp = KeyUpEvent(
      physicalKey: PhysicalKeyboardKey.arrowDown,
      logicalKey: LogicalKeyboardKey.arrowDown,
      timeStamp: Duration.zero,
    );
    const otherUp = KeyUpEvent(
      physicalKey: PhysicalKeyboardKey.arrowUp,
      logicalKey: LogicalKeyboardKey.arrowUp,
      timeStamp: Duration.zero,
    );

    expect(await sendKeyEvent(tester, handledDown), KeyEventResult.handled);
    expect(await sendKeyEvent(tester, handledUp), KeyEventResult.handled);
    expect(await sendKeyEvent(tester, handledUp), KeyEventResult.ignored);
    expect(await sendKeyEvent(tester, otherUp), KeyEventResult.ignored);
  });

  testWidgets('a key typed into a text input inside the viewer is never claimed by the viewer', (tester) async {
    // The viewer reads Space as "next page" and reports it handled. With a
    // text input focused beneath it (the inline text annotation editor),
    // that stops the platform from inserting the character at all: on an
    // iPad with a hardware keyboard the space bar simply did nothing.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final claimed = <LogicalKeyboardKey>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PdfViewerKeyHandler(
              params: const PdfViewerKeyHandlerParams(),
              onKeyRepeat: (_, key, _) {
                claimed.add(key);
                return true;
              },
              child: const TextField(autofocus: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus, isTrue);

      // Nothing claims Space, so the platform is free to insert it.
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.space), isFalse);
      // Home and Page Down may be consumed, but by the text input (they
      // move its caret), never by the viewer.
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      expect(claimed, isEmpty);

      // The viewer takes its keys back as soon as the text input lets go.
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.unfocus();
      Focus.of(tester.element(find.byType(TextField))).requestFocus();
      await tester.pumpAndSettle();
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.space), isTrue);
      expect(claimed, [LogicalKeyboardKey.space]);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
