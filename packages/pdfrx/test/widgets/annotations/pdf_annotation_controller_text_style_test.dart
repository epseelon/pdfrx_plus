import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/annotation_text_layout.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_text_annotation.dart';

// `flutter test` lays text out in its square test font: every glyph is
// one em wide and one em tall, so the sizes below are exact arithmetic.
// 'rit.' at the default 18 pt is 72 x 18.

const Size _pageSize = Size(600, 800);

/// A style that differs from the default in every field.
const PdfTextAnnotationStyle _loud = PdfTextAnnotationStyle(
  fontFamily: 'Inter',
  fontSize: 32,
  color: Color(0xFFFF3B30),
  bold: true,
  italic: true,
  underline: true,
  align: PdfTextAnnotationAlign.center,
);

PdfTextAnnotation _text({
  String id = 'text-1',
  String text = 'rit.',
  Rect rect = const Rect.fromLTWH(10, 20, 72, 18),
  bool autoSize = true,
  String? creatorName = 'alice',
  PdfTextAnnotationStyle style = const PdfTextAnnotationStyle(),
  Map<String, dynamic> preservedJson = const {},
}) => PdfTextAnnotation(
  id: id,
  pageIndex: 0,
  rectInPdfSpace: rect,
  rotationDeg: 0,
  text: text,
  fontFamily: style.fontFamily,
  fontSize: style.fontSize,
  color: style.color,
  bold: style.bold,
  italic: style.italic,
  underline: style.underline,
  align: style.align,
  autoSize: autoSize,
  createdAt: DateTime.utc(2026, 9, 21, 10),
  updatedAt: DateTime.utc(2026, 9, 21, 10),
  creatorName: creatorName,
  preservedJson: preservedJson,
);

/// A controller in Text-tool mode as `alice`, holding [texts], with page
/// 0 laid out so a restyle can re-derive the display box.
PdfAnnotationController _armed({List<PdfTextAnnotation> texts = const []}) {
  final controller = PdfAnnotationController();
  controller.setAllWithStamps(strokes: const [], stamps: const [], attachments: {}, texts: texts);
  controller.registerPageLayout(pageIndex: 0, viewerRect: Offset.zero & _pageSize, pageSize: _pageSize);
  controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.text);
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Text style: arming', () {
    test('the armed style starts as the default style', () {
      final controller = _armed();
      addTearDown(controller.dispose);

      expect(controller.textStyle, const PdfTextAnnotationStyle());
      expect(controller.textStyle.fontFamily, isNull, reason: 'null stands for the host default family');
      expect(controller.textStyle.fontSize, 18);
      expect(controller.textStyle.color, const Color(0xFF000000));
      expect(controller.textStyle.bold, isFalse);
      expect(controller.textStyle.italic, isFalse);
      expect(controller.textStyle.underline, isFalse);
      expect(controller.textStyle.align, PdfTextAnnotationAlign.left);
    });

    test('a change with nothing selected arms the style and touches no annotation', () {
      final controller = _armed(texts: [_text()]);
      addTearDown(controller.dispose);
      var fired = 0;
      controller.textStyleListenable.addListener(() => fired++);

      controller.setTextStyle(_loud);

      expect(controller.textStyle, _loud);
      expect(fired, 1);
      expect(controller.texts.single.style, const PdfTextAnnotationStyle(), reason: 'nothing was selected');
      expect(controller.canUndoListenable.value, isFalse, reason: 'arming is not an edit');

      controller.setTextStyle(_loud);
      expect(fired, 1, reason: 'idempotent');
    });

    test('a new text annotation takes the armed style', () {
      final controller = _armed();
      addTearDown(controller.dispose);
      controller.setTextStyle(_loud);

      controller.createTextAt(pageIndex: 0, pdfPoint: const Offset(50, 60), pageSize: _pageSize);
      expect(controller.editingText!.style, _loud, reason: 'the editor opens in the armed style');
      controller.updateTextEdit('rit.');
      controller.commitTextEdit();

      expect(controller.texts.single.style, _loud);
      expect(controller.texts.single.rectInPdfSpace.size, const Size(4 * 32, 32), reason: 'laid out at 32 pt');
    });

    test('an armed style that names no family creates text in the host default family', () {
      final controller = _armed();
      addTearDown(controller.dispose);
      controller.annotationFonts = const PdfAnnotationFonts(
        families: [PdfAnnotationFontFamily('Academico')],
        defaultFamily: 'Academico',
      );

      controller.createTextAt(pageIndex: 0, pdfPoint: const Offset(50, 60), pageSize: _pageSize);

      expect(controller.editingText!.fontFamily, 'Academico');
    });
  });

  group('Text style: what this build could not use', () {
    test('a restyle retires the preserved raw value of the field it changed, and of no other', () {
      final stored = _text(
        preservedJson: const {'fontSize': 'big', 'horizontalAlign': 'justify', 'backgroundColor': '#FFFF00'},
      );
      final controller = _armed(texts: [stored]);
      addTearDown(controller.dispose);
      controller.selectText('text-1');

      controller.setTextStyle(controller.textStyle.copyWith(fontSize: 24));

      expect(controller.texts.single.preservedJson, const {'horizontalAlign': 'justify', 'backgroundColor': '#FFFF00'});
    });

    test('undoing a restyle loads the restored style back into the armed style', () {
      final controller = _armed(texts: [_text()]);
      addTearDown(controller.dispose);
      controller.selectText('text-1');
      controller.setTextStyle(_loud);

      controller.undo();

      expect(controller.selectedTextIdListenable.value, 'text-1');
      expect(controller.textStyle, const PdfTextAnnotationStyle(), reason: 'the controls show the selection');
      controller.redo();
      expect(controller.textStyle, _loud);
    });
  });

  group('Text style: annotation-mode cycle', () {
    test('the armed style survives leaving and re-entering annotation mode', () async {
      final controller = _armed();
      addTearDown(controller.dispose);
      controller.setTextStyle(_loud);

      await controller.exitMode(onAnnotationsChanged: null);
      controller.enterMode(creatorName: 'alice');

      expect(controller.textStyle, _loud);
    });

    test('enterMode takes the armed style as an optional override', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);

      controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.text, textStyle: _loud);
      expect(controller.textStyle, _loud);

      controller.enterMode(creatorName: 'alice');
      expect(controller.textStyle, _loud, reason: 'a null override keeps the remembered style');
    });
  });

  group('Text style: selection', () {
    test('selecting a text annotation loads its style into the armed style', () {
      final controller = _armed(texts: [_text(style: _loud)]);
      addTearDown(controller.dispose);

      controller.selectText('text-1');

      expect(controller.textStyle, _loud);
      expect(controller.canUndoListenable.value, isFalse, reason: 'loading a style edits nothing');
    });

    test('a change restyles the selected annotation in one undo step', () {
      final controller = _armed(texts: [_text()]);
      addTearDown(controller.dispose);
      controller.selectText('text-1');
      var notified = 0;
      controller.addListener(() => notified++);

      controller.setTextStyle(_loud);

      final restyled = controller.texts.single;
      expect(restyled.style, _loud);
      expect(
        restyled.rectInPdfSpace,
        const Rect.fromLTWH(10, 20, 4 * 32, 32),
        reason: 'the display box is written back',
      );
      expect(restyled.updatedAt.isAfter(DateTime.utc(2026, 9, 21, 10)), isTrue);
      expect(controller.selectedTextIdListenable.value, 'text-1', reason: 'still selected');
      expect(notified, 1, reason: 'the canvas repaints');

      controller.undo();
      expect(controller.texts.single.style, const PdfTextAnnotationStyle());
      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(10, 20, 72, 18));
      expect(controller.canUndoListenable.value, isFalse, reason: 'exactly one step');
    });
  });

  group('Text style: during an edit', () {
    test('an edit of an existing annotation that only restyles it is committed, in one undo step', () {
      final controller = _armed(texts: [_text()]);
      addTearDown(controller.dispose);
      controller.beginTextEdit('text-1', pageSize: _pageSize);

      controller.setTextStyle(_loud);
      expect(controller.texts.single.style, const PdfTextAnnotationStyle(), reason: 'the model waits for the commit');
      controller.commitTextEdit();

      expect(controller.texts.single.style, _loud);
      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(10, 20, 4 * 32, 32));
      controller.undo();
      expect(controller.texts.single.style, const PdfTextAnnotationStyle());
      expect(controller.canUndoListenable.value, isFalse, reason: 'exactly one step');
    });

    test('a change restyles the text being typed, keeps the edit open and takes no undo step of its own', () {
      final controller = _armed();
      addTearDown(controller.dispose);
      controller.createTextAt(pageIndex: 0, pdfPoint: const Offset(50, 60), pageSize: _pageSize);
      controller.updateTextEdit('rit.');
      var editTicks = 0;
      controller.textEditChangedListenable.addListener(() => editTicks++);

      controller.setTextStyle(_loud);

      expect(controller.editingText, isNotNull, reason: 'the edit is still open');
      expect(controller.editingText!.style, _loud);
      expect(controller.editingText!.text, 'rit.');
      expect(editTicks, 1, reason: 'the layer re-boxes and restyles the editor');
      expect(controller.texts, isEmpty, reason: 'nothing joins the model before the commit');
      expect(controller.canUndoListenable.value, isFalse);

      controller.commitTextEdit();
      expect(controller.texts.single.style, _loud);
      controller.undo();
      expect(controller.texts, isEmpty, reason: 'the whole session, restyle included, is one undo step');
      expect(controller.canUndoListenable.value, isFalse);
    });
  });

  group('Text style: a style the family lacks', () {
    const fonts = PdfAnnotationFonts(
      families: [
        PdfAnnotationFontFamily('Academico', styles: PdfAnnotationFontStyle.values),
        PdfAnnotationFontFamily('Caveat', styles: [PdfAnnotationFontStyle.regular, PdfAnnotationFontStyle.bold]),
      ],
      defaultFamily: 'Academico',
    );

    test('the stored italic flag survives a family switch to Caveat and back', () {
      const italic = PdfTextAnnotationStyle(fontFamily: 'Academico', italic: true);
      final controller = _armed(texts: [_text(style: italic)])..annotationFonts = fonts;
      addTearDown(controller.dispose);
      controller.selectText('text-1');

      controller.setTextStyle(controller.textStyle.copyWith(fontFamily: 'Caveat'));
      final inCaveat = controller.texts.single;
      expect(inCaveat.italic, isTrue, reason: 'the flag is kept');
      expect(controller.textStyle.italic, isTrue);
      expect(resolveAnnotationTextStyle(inCaveat, fonts).fontStyle, FontStyle.normal, reason: 'never synthesized');

      controller.setTextStyle(controller.textStyle.copyWith(fontFamily: 'Academico'));
      final back = controller.texts.single;
      expect(back.italic, isTrue);
      expect(resolveAnnotationTextStyle(back, fonts).fontStyle, FontStyle.italic, reason: 'italic is back');
    });
  });
}
