import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/annotation_text_layout.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_layer.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_text_annotation.dart';

import '_test_helpers/fake_pdf_page.dart';

// The layer is mounted 1:1 with the page, so PDF points and layer pixels
// coincide. `flutter test` lays text out in its square test font: 'rit.'
// at 18 pt is 72 x 18, and at 32 pt it is 128 x 32.
const _pageSize = Size(400, 400);

const _fonts = PdfAnnotationFonts(
  families: [
    PdfAnnotationFontFamily('Inter', styles: PdfAnnotationFontStyle.values),
    PdfAnnotationFontFamily('Caveat', styles: [PdfAnnotationFontStyle.regular, PdfAnnotationFontStyle.bold]),
  ],
  defaultFamily: 'Inter',
);

const _loud = PdfTextAnnotationStyle(
  fontFamily: 'Inter',
  fontSize: 32,
  color: Color(0xFFFF3B30),
  bold: true,
  italic: true,
  underline: true,
  align: PdfTextAnnotationAlign.right,
);

/// The layer, and beside it a button standing in for a toolbar control:
/// it is outside the layer, so a tap on it is not a tap on the score.
Future<void> _pumpLayerAndToolbar(
  WidgetTester tester,
  PdfAnnotationController controller, {
  required PdfTextAnnotationStyle styleOnTap,
}) async {
  final page = FakePdfPage(pageNumber: 1, width: _pageSize.width, height: _pageSize.height);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            IconButton(
              key: const Key('restyle'),
              icon: const Icon(Icons.format_bold),
              onPressed: () => controller.setTextStyle(styleOnTap),
            ),
            SizedBox(
              key: const Key('layerHost'),
              width: _pageSize.width,
              height: _pageSize.height,
              child: PdfAnnotationLayer(
                controller: controller,
                page: page,
                pageRect: Offset.zero & _pageSize,
                highlighterOpacity: 0.35,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

PdfAnnotationController _armed() {
  final controller = PdfAnnotationController()..annotationFonts = _fonts;
  controller.setAllWithStamps(strokes: [], stamps: [], attachments: {});
  controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.text);
  return controller;
}

final Finder _anyEditor = find.byType(EditableText);

void main() {
  testWidgets('a style change made while editing keeps the edit open and restyles the editor', (tester) async {
    final controller = _armed();
    addTearDown(controller.dispose);
    await _pumpLayerAndToolbar(tester, controller, styleOnTap: _loud);

    await tester.tapAt(tester.getTopLeft(find.byKey(const Key('layerHost'))) + const Offset(60, 80));
    await tester.pumpAndSettle();
    await tester.enterText(_anyEditor, 'rit.');
    await tester.pump();
    final before = tester.widget<EditableText>(_anyEditor);
    before.controller.selection = const TextSelection.collapsed(offset: 2);
    await tester.pump();
    final stateBefore = tester.state<EditableTextState>(_anyEditor);
    expect(before.style.fontSize, 18);
    expect(tester.getSize(_anyEditor).height, 18);

    await tester.tap(find.byKey(const Key('restyle')));
    await tester.pumpAndSettle();

    expect(controller.editingText, isNotNull, reason: 'a toolbar tap is not a tap outside the box');
    expect(controller.texts, isEmpty, reason: 'nothing was committed');
    final after = tester.widget<EditableText>(_anyEditor);
    expect(tester.state<EditableTextState>(_anyEditor), same(stateBefore), reason: 'the same editor, not a new one');
    expect(after.controller.text, 'rit.');
    expect(after.controller.selection, const TextSelection.collapsed(offset: 2), reason: 'the caret stays put');
    expect(after.focusNode.hasFocus, isTrue, reason: 'the keyboard stays up');
    expect(after.style.fontFamily, 'Inter');
    expect(after.style.fontSize, 32);
    expect(after.style.color, const Color(0xFFFF3B30));
    expect(after.style.fontWeight, FontWeight.w700);
    expect(after.style.fontStyle, FontStyle.italic);
    expect(after.style.decoration, TextDecoration.underline);
    expect(after.textAlign, TextAlign.right);
    expect(tester.getSize(_anyEditor).height, 32, reason: 'the box follows the restyled text');
  });

  testWidgets('italic asked of a family that lacks it leaves the editor upright', (tester) async {
    final controller = _armed();
    addTearDown(controller.dispose);
    await _pumpLayerAndToolbar(
      tester,
      controller,
      styleOnTap: const PdfTextAnnotationStyle(fontFamily: 'Caveat', italic: true, bold: true),
    );

    await tester.tapAt(tester.getTopLeft(find.byKey(const Key('layerHost'))) + const Offset(60, 80));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('restyle')));
    await tester.pumpAndSettle();

    final editor = tester.widget<EditableText>(_anyEditor);
    expect(editor.style.fontFamily, 'Caveat');
    expect(editor.style.fontStyle, FontStyle.normal, reason: 'never synthesized');
    expect(editor.style.fontWeight, FontWeight.w700, reason: 'Caveat has a real bold');
    expect(controller.editingText!.italic, isTrue, reason: 'the flag is kept');
  });
}
