import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_ink_annotation.dart';

/// An entry of a kind no build in this tree knows: the "type after next"
/// the carriage exists to protect.
Map<String, dynamic> _unknown({String id = 'future-1', String? creatorName = 'alice', String? attachmentId}) => {
  'v': 1,
  'type': 'pspdfkit/shape/ellipse',
  'id': id,
  'pageIndex': 0,
  'bbox': [10.0, 20.0, 30.0, 40.0],
  'fillColor': '#00FF00',
  'pdfrx:someFutureKnob': {'nested': true, 'count': 7},
  'createdAt': '2026-01-02T03:04:05.000Z',
  'updatedAt': '2026-01-02T03:04:05.000Z',
  'creatorName': ?creatorName,
  'imageAttachmentId': ?attachmentId,
};

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

/// Ids of the entries in [json] whose type this build does not model.
List<String> _unknownIds(String json) {
  final entries = (jsonDecode(json) as Map<String, dynamic>)['annotations'] as List<dynamic>;
  return [
    for (final e in entries.cast<Map<String, dynamic>>())
      if (e['type'] == 'pspdfkit/shape/ellipse') e['id'] as String,
  ];
}

void main() {
  group('carried (unrecognised) annotation entries', () {
    test('importJson keeps an unknown entry and exportJson puts it back', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);

      final source = jsonEncode({
        'annotations': [_unknown()],
      });
      controller.importJson(source, pageCount: 1);

      // Nothing to paint and nothing to select, but it must come back out.
      expect(_unknownIds(controller.exportJson()), ['future-1']);
    });

    test('the session export filters carried entries by creator, as it does strokes', () async {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(
        strokes: [],
        stamps: [],
        attachments: {},
        unknowns: [
          _unknown(id: 'mine', creatorName: 'alice'),
          _unknown(id: 'theirs', creatorName: 'bob'),
        ],
      );

      String? exported;
      controller.enterMode(creatorName: 'alice');
      await controller.exitMode(
        onAnnotationsChanged: (json) async {
          exported = json;
        },
      );

      // Claiming 'theirs' here would re-attribute another creator's entry
      // into this creator's persisted set on every save.
      expect(_unknownIds(exported!), ['mine']);
    });

    test('a null-creator session exports every carried entry', () async {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(
        strokes: [],
        stamps: [],
        attachments: {},
        unknowns: [
          _unknown(id: 'mine', creatorName: 'alice'),
          _unknown(id: 'theirs', creatorName: 'bob'),
        ],
      );

      String? exported;
      controller.enterMode();
      await controller.exitMode(
        onAnnotationsChanged: (json) async {
          exported = json;
        },
      );

      expect(_unknownIds(exported!), ['mine', 'theirs']);
    });

    test('an entry naming no creator is not claimed by a creator session', () async {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(
        strokes: [],
        stamps: [],
        attachments: {},
        unknowns: [_unknown(id: 'orphan', creatorName: null)],
      );

      String? exported;
      controller.enterMode(creatorName: 'alice');
      await controller.exitMode(
        onAnnotationsChanged: (json) async {
          exported = json;
        },
      );

      expect(_unknownIds(exported!), isEmpty);
    });

    test("a carried entry's attachment survives the export", () async {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      const sha = 'aabbcc';
      final source = jsonEncode({
        'annotations': [_unknown(attachmentId: sha)],
        'attachments': {
          sha: {
            'binary': base64Encode(const [1, 2, 3]),
            'contentType': 'image/png',
          },
        },
      });
      controller.importJson(source, pageCount: 1);

      final out = jsonDecode(controller.exportJson()) as Map<String, dynamic>;
      expect((out['attachments'] as Map<String, dynamic>).containsKey(sha), isTrue);
    });

    test('clear() drops carried entries (the document-swap path)', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(strokes: [], stamps: [], attachments: {}, unknowns: [_unknown()]);

      controller.clear();

      // Left behind, they would export into whichever part opened next.
      expect(_unknownIds(controller.exportJson()), isEmpty);
    });

    test('clear() is not a no-op when carried entries are the only content', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(strokes: [], stamps: [], attachments: {}, unknowns: [_unknown()]);

      var notified = 0;
      controller.addListener(() => notified++);
      controller.clear();

      expect(notified, 1);
    });

    test('editing and undoing around a carried entry never loses it', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(strokes: [], stamps: [], attachments: {}, unknowns: [_unknown()]);

      controller.enterMode(creatorName: 'alice');
      controller.addStroke(_ink());
      expect(_unknownIds(controller.exportJson()), ['future-1']);

      // Undo restores a snapshot that never carried the entry; it must
      // not take the entry down with it.
      controller.undo();

      expect(controller.strokes, isEmpty);
      expect(_unknownIds(controller.exportJson()), ['future-1']);
    });
  });
}
