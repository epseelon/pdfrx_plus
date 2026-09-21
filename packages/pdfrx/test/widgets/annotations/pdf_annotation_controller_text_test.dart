import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_ink_annotation.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_text_annotation.dart';

/// A stored text annotation entry, exactly as the encoder writes it.
Map<String, dynamic> _textEntry({String id = 'text-1', String? creatorName = 'alice', String text = 'rit.'}) => {
  'v': 1,
  'type': 'pspdfkit/text',
  'id': id,
  'pageIndex': 0,
  'bbox': [10.0, 20.0, 120.5, 40.25],
  'opacity': 1.0,
  'text': text,
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
  'createdAt': '2026-09-21T10:00:00.000Z',
  'updatedAt': '2026-09-21T10:00:00.000Z',
  'creatorName': ?creatorName,
};

PdfTextAnnotation _text({String id = 'text-1', String? creatorName = 'alice'}) => PdfTextAnnotation(
  id: id,
  pageIndex: 0,
  rectInPdfSpace: const Rect.fromLTWH(10, 20, 120.5, 40.25),
  rotationDeg: 0,
  text: 'rit.',
  createdAt: DateTime.utc(2026, 9, 21, 10),
  updatedAt: DateTime.utc(2026, 9, 21, 10),
  creatorName: creatorName,
);

PdfInkAnnotation _ink({String id = 'ink-1', String? creatorName = 'alice'}) => PdfInkAnnotation(
  id: id,
  pageIndex: 0,
  pointsInPdfSpace: const [Offset(0, 0), Offset(1, 1)],
  lineWidth: 2.0,
  strokeColor: const Color(0xFFFF0000),
  opacity: 1.0,
  createdAt: DateTime.utc(2026, 9, 19, 10),
  updatedAt: DateTime.utc(2026, 9, 19, 10),
  creatorName: creatorName,
);

/// The text annotation entries of [json], in order.
List<Map<String, dynamic>> _textEntries(String json) {
  final entries = (jsonDecode(json) as Map<String, dynamic>)['annotations'] as List<dynamic>;
  return [
    for (final e in entries.cast<Map<String, dynamic>>())
      if (e['type'] == 'pspdfkit/text') e,
  ];
}

List<String> _textIds(String json) => [for (final e in _textEntries(json)) e['id'] as String];

Future<String> _sessionExport(PdfAnnotationController controller, {String? creatorName}) async {
  String? exported;
  controller.enterMode(creatorName: creatorName);
  await controller.exitMode(
    onAnnotationsChanged: (json) async {
      exported = json;
    },
  );
  return exported!;
}

void main() {
  group('text annotation storage', () {
    test('importing a document that holds text and exporting it with no edit yields identical text entries', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);

      final stored = [
        _textEntry(id: 'auto-sized'),
        {..._textEntry(id: 'text-area'), 'pdfrx:autoSize': false, 'text': '2nd time only\nD.S.'},
        // Written by another producer: an unrounded box, a family and a size
        // this build does not offer, keys and values it does not model.
        {
          ..._textEntry(id: 'foreign'),
          'bbox': [10.123456, 20.987654, 33.335, 7.001],
          'font': 'Some Future Family',
          'fontSize': 'big',
          'horizontalAlign': 'justify',
          'backgroundColor': '#FFFF00',
          'text': {'format': 'plain', 'value': 'watch'},
        },
      ];
      controller.importJson(jsonEncode({'annotations': stored}), pageCount: 1);

      expect(controller.texts.map((t) => t.id), ['auto-sized', 'text-area', 'foreign']);
      expect(_textEntries(controller.exportJson()), stored);
    });
    test("the session export carries the creator's text annotations and excludes a bandmate's", () async {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(
        strokes: [],
        stamps: [],
        attachments: {},
        texts: [
          _text(id: 'mine', creatorName: 'alice'),
          _text(id: 'theirs', creatorName: 'bob'),
          _text(id: 'nobody', creatorName: null),
        ],
      );

      // Claiming 'theirs' would re-attribute a bandmate's text into this
      // creator's persisted set on every save; dropping 'mine' would delete
      // it for the whole band.
      expect(_textIds(await _sessionExport(controller, creatorName: 'alice')), ['mine']);
      // Leaving annotation mode exports; it does not consume.
      expect(controller.texts.map((t) => t.id), ['mine', 'theirs', 'nobody']);
    });

    test('a null-creator session exports every text annotation', () async {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(
        strokes: [],
        stamps: [],
        attachments: {},
        texts: [
          _text(id: 'mine', creatorName: 'alice'),
          _text(id: 'theirs', creatorName: 'bob'),
        ],
      );

      expect(_textIds(await _sessionExport(controller)), ['mine', 'theirs']);
    });

    test('clear() drops text annotations (the document-swap path)', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(strokes: [], stamps: [], attachments: {}, texts: [_text()]);

      var notified = 0;
      controller.addListener(() => notified++);
      controller.clear();

      // Left behind, they would export into whichever part opened next.
      expect(controller.texts, isEmpty);
      expect(_textIds(controller.exportJson()), isEmpty);
      // Not a no-op when text is the only content.
      expect(notified, 1);
    });

    test('a wholesale replacement that names no text replaces it with nothing', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(strokes: [], stamps: [], attachments: {}, texts: [_text()]);

      controller.setAllWithStamps(strokes: [], stamps: [], attachments: {});

      expect(controller.texts, isEmpty);
    });

    test('editing and undoing around a text annotation never loses it', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(strokes: [], stamps: [], attachments: {}, texts: [_text()]);

      controller.enterMode(creatorName: 'alice');
      controller.addStroke(_ink());
      expect(_textIds(controller.exportJson()), ['text-1']);

      controller.undo();
      expect(controller.strokes, isEmpty);
      expect(_textIds(controller.exportJson()), ['text-1']);

      controller.redo();
      expect(controller.strokes, hasLength(1));
      expect(_textIds(controller.exportJson()), ['text-1']);
    });
  });
}
