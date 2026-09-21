import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/annotation_text_layout.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_text_annotation.dart';

const Size _page = Size(200, 300);

final DateTime _t = DateTime.utc(2026, 1, 1);

PdfTextAnnotation _text({
  String id = 'text',
  String text = 'aaaa bbbb',
  Rect rect = const Rect.fromLTWH(20, 30, 40, 10),
  bool autoSize = true,
  double fontSize = 10,
  bool bold = false,
}) => PdfTextAnnotation(
  id: id,
  pageIndex: 0,
  rectInPdfSpace: rect,
  rotationDeg: 0,
  text: text,
  fontSize: fontSize,
  bold: bold,
  autoSize: autoSize,
  createdAt: _t,
  updatedAt: _t,
);

/// Counts the calls that reach the layout seam, and lays out for real.
class _CountingLayouter {
  int calls = 0;

  PdfAnnotationTextLayout call({
    required String text,
    required TextStyle style,
    required PdfTextAnnotationAlign align,
    required double? wrapWidth,
  }) {
    calls++;
    return layoutAnnotationText(text: text, style: style, align: align, wrapWidth: wrapWidth);
  }
}

/// A device whose fonts measure every text as 123.45 x 67.89, which no
/// stored box in this file agrees with.
PdfAnnotationTextLayout _disagreeingLayouter({
  required String text,
  required TextStyle style,
  required PdfTextAnnotationAlign align,
  required double? wrapWidth,
}) {
  final real = layoutAnnotationText(text: text, style: style, align: align, wrapWidth: wrapWidth);
  return PdfAnnotationTextLayout(size: const Size(123.45, 67.89), painter: real.painter);
}

PdfAnnotationController _controller(List<PdfTextAnnotation> texts, {PdfAnnotationTextLayouter? layouter}) {
  final controller = PdfAnnotationController();
  addTearDown(controller.dispose);
  if (layouter != null) controller.textLayouter = layouter;
  controller.setAllWithStamps(strokes: const [], stamps: const [], attachments: const {}, texts: texts);
  return controller;
}

void main() {
  group('text display box memoization', () {
    test('layout does not run on every frame', () {
      final layouter = _CountingLayouter();
      final controller = _controller([_text()], layouter: layouter.call);

      final first = controller.textDisplayBoxFor(controller.texts.single, pageSize: _page);
      for (var frame = 0; frame < 10; frame++) {
        expect(identical(controller.textDisplayBoxFor(controller.texts.single, pageSize: _page), first), isTrue);
      }

      expect(layouter.calls, 1);
      expect(first.displayRect, const Rect.fromLTWH(20, 30, 90, 10));
    });

    test('a change of text, of style or of wrap width lays out again', () {
      final layouter = _CountingLayouter();
      final controller = _controller([_text()], layouter: layouter.call);
      controller.textDisplayBoxFor(controller.texts.single, pageSize: _page);
      expect(layouter.calls, 1);

      // Text.
      controller.setAllWithStamps(
        strokes: const [],
        stamps: const [],
        attachments: const {},
        texts: [_text(text: 'aaaa')],
      );
      expect(controller.textDisplayBoxFor(controller.texts.single, pageSize: _page).displayRect.width, 40);
      expect(layouter.calls, 2);

      // Style.
      controller.setAllWithStamps(
        strokes: const [],
        stamps: const [],
        attachments: const {},
        texts: [_text(text: 'aaaa', fontSize: 20)],
      );
      expect(controller.textDisplayBoxFor(controller.texts.single, pageSize: _page).displayRect.width, 80);
      expect(layouter.calls, 3);

      // Wrap width: the same annotation on a narrower page.
      controller.textDisplayBoxFor(controller.texts.single, pageSize: const Size(60, 300));
      expect(layouter.calls, 4);
    });

    test('a move that keeps the wrap width re-derives the box without laying out again', () {
      final layouter = _CountingLayouter();
      final area = _text(autoSize: false, rect: const Rect.fromLTWH(20, 30, 50, 10));
      final controller = _controller([area], layouter: layouter.call);
      expect(
        controller.textDisplayBoxFor(controller.texts.single, pageSize: _page).displayRect,
        const Rect.fromLTWH(20, 30, 50, 20),
      );

      controller.setAllWithStamps(
        strokes: const [],
        stamps: const [],
        attachments: const {},
        texts: [area.copyWith(rectInPdfSpace: const Rect.fromLTWH(60, 70, 50, 10))],
      );
      expect(
        controller.textDisplayBoxFor(controller.texts.single, pageSize: _page).displayRect,
        const Rect.fromLTWH(60, 70, 50, 20),
      );
      expect(layouter.calls, 1);
    });

    test('a change of the font set lays out again and notifies', () {
      final layouter = _CountingLayouter();
      final controller = _controller([_text()], layouter: layouter.call);
      controller.textDisplayBoxFor(controller.texts.single, pageSize: _page);
      var notified = 0;
      controller.addListener(() => notified++);

      const fonts = PdfAnnotationFonts(families: [PdfAnnotationFontFamily('Serif')], defaultFamily: 'Serif');
      controller.annotationFonts = fonts;
      expect(notified, 1);
      controller.textDisplayBoxFor(controller.texts.single, pageSize: _page);
      expect(layouter.calls, 2);

      // A rebuilt, equal font set is not a change.
      controller.annotationFonts = PdfAnnotationFonts(families: [...fonts.families], defaultFamily: 'Serif');
      expect(notified, 1);
      controller.textDisplayBoxFor(controller.texts.single, pageSize: _page);
      expect(layouter.calls, 2);
    });

    test('annotations that left the document do not keep their layout', () {
      final layouter = _CountingLayouter();
      final controller = _controller([_text(id: 'a'), _text(id: 'b')], layouter: layouter.call);
      for (final t in controller.texts) {
        controller.textDisplayBoxFor(t, pageSize: _page);
      }
      expect(controller.memoizedTextLayoutCount, 2);

      controller.setAllWithStamps(
        strokes: const [],
        stamps: const [],
        attachments: const {},
        texts: [_text(id: 'a')],
      );
      expect(controller.memoizedTextLayoutCount, 1);
    });
  });

  group('stored box versus display box', () {
    const document = {
      'format': 'https://pspdfkit.com/instant-json/v1',
      'annotations': [
        {
          'v': 1,
          'type': 'pspdfkit/text',
          'id': '0123456789abcdef01234567',
          'pageIndex': 0,
          'bbox': [20, 30, 41.37, 12.08],
          'opacity': 1.0,
          'text': 'rit.',
          'font': 'Academico',
          'fontSize': 18,
          'fontStyle': ['bold', 'italic'],
          'fontColor': '#000000',
          'horizontalAlign': 'left',
          'verticalAlign': 'top',
          'rotation': 0,
          'pdfrx:rotation': 12.5,
          'pdfrx:underline': false,
          'pdfrx:autoSize': true,
          'createdAt': '2026-01-01T00:00:00.000Z',
          'updatedAt': '2026-01-01T00:00:00.000Z',
          'creatorName': 'alice',
        },
      ],
    };

    List<dynamic> entriesOf(String json) => (jsonDecode(json) as Map<String, dynamic>)['annotations'] as List<dynamic>;

    test('rendering never writes the display box back, whatever this device measures', () {
      final controller = PdfAnnotationController()..textLayouter = _disagreeingLayouter;
      addTearDown(controller.dispose);
      controller.importJson(jsonEncode(document), pageCount: 1);

      // Render: the display box is this device's, not the stored one.
      final box = controller.textDisplayBoxFor(controller.texts.single, pageSize: _page);
      // The entry is rotated, so the box is rebuilt around a re-derived
      // centre: compare within float noise.
      expect(box.displayRect.width, closeTo(123.45, 1e-9));
      expect(box.displayRect.height, closeTo(67.89, 1e-9));

      expect(controller.texts.single.rectInPdfSpace, const Rect.fromLTWH(20, 30, 41.37, 12.08));
      expect(entriesOf(controller.exportJson()), document['annotations']);
    });
  });
}
