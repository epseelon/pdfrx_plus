import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/instant_json.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_ink_annotation.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_rect_annotation.dart';

PdfRectAnnotation _rect({
  String id = 'rect-1',
  int pageIndex = 0,
  Rect rect = const Rect.fromLTWH(10, 20, 100, 40),
  double rotationDeg = 0.0,
  Color? fillColor = const Color(0xFFFFFFFF),
  String? creatorName = 'alice',
}) => PdfRectAnnotation(
  id: id,
  pageIndex: pageIndex,
  rectInPdfSpace: rect,
  rotationDeg: rotationDeg,
  fillColor: fillColor,
  createdAt: DateTime.utc(2026, 9, 19, 10),
  updatedAt: DateTime.utc(2026, 9, 19, 10),
  creatorName: creatorName,
);

PdfInkAnnotation _stroke({String? creatorName = 'alice'}) => PdfInkAnnotation(
  id: 'ink-1',
  pageIndex: 0,
  pointsInPdfSpace: const [Offset(0, 0), Offset(5, 5)],
  lineWidth: 2.0,
  strokeColor: const Color(0xFFFF3B30),
  opacity: 1.0,
  createdAt: DateTime.utc(2026, 9, 19, 10),
  updatedAt: DateTime.utc(2026, 9, 19, 10),
  creatorName: creatorName,
);

List<String> _entryTypes(String json) => [
  for (final e in (jsonDecode(json) as Map<String, dynamic>)['annotations'] as List)
    (e as Map<String, dynamic>)['type'] as String,
];

List<String> _rectIds(String json) => [
  for (final e in (jsonDecode(json) as Map<String, dynamic>)['annotations'] as List)
    if ((e as Map<String, dynamic>)['type'] == 'pspdfkit/shape/rectangle') e['id'] as String,
];

void main() {
  group('PdfAnnotationController rectangle persistence', () {
    test('setAllWithStamps replaces the rectangle set', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);

      controller.setAllWithStamps(
        strokes: [],
        stamps: [],
        attachments: {},
        rects: [
          _rect(),
          _rect(id: 'rect-2'),
        ],
      );
      expect(controller.rects.map((r) => r.id), ['rect-1', 'rect-2']);

      controller.setAllWithStamps(
        strokes: [],
        stamps: [],
        attachments: {},
        rects: [_rect(id: 'rect-3')],
      );
      expect(controller.rects.map((r) => r.id), ['rect-3']);

      // The parameter defaults to empty, so a call that predates rectangles
      // still compiles and now clears them.
      controller.setAllWithStamps(strokes: [], stamps: [], attachments: {});
      expect(controller.rects, isEmpty);
    });

    test('rects is an unmodifiable view', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(strokes: [], stamps: [], attachments: {}, rects: [_rect()]);
      expect(() => controller.rects.add(_rect(id: 'nope')), throwsUnsupportedError);
    });

    test('exportJson serialises the rectangles alongside the strokes', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(strokes: [_stroke()], stamps: [], attachments: {}, rects: [_rect()]);

      expect(_entryTypes(controller.exportJson()), ['pspdfkit/ink', 'pspdfkit/shape/rectangle']);
    });

    test('importJson round-trips rectangles back into the controller', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      final json = encodeInstantJson(const [], rects: [_rect(id: 'imported', rotationDeg: 33.0)]);

      controller.importJson(json, pageCount: 3);

      expect(controller.rects, hasLength(1));
      expect(controller.rects.single.id, 'imported');
      expect(controller.rects.single.rotationDeg, 33.0);
    });

    test('the session export filters rectangles by creator, as it does strokes', () async {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(
        strokes: [],
        stamps: [],
        attachments: {},
        rects: [
          _rect(id: 'mine', creatorName: 'alice'),
          _rect(id: 'theirs', creatorName: 'bob'),
        ],
      );

      String? exported;
      controller.enterMode(creatorName: 'alice');
      await controller.exitMode(
        onAnnotationsChanged: (json) async {
          exported = json;
        },
      );

      expect(_rectIds(exported!), ['mine']);
      // Filtering the export must not touch the in-memory set: the foreign
      // rectangle still renders.
      expect(controller.rects.map((r) => r.id), ['mine', 'theirs']);
    });

    test('a null-creator session exports every rectangle', () async {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(
        strokes: [],
        stamps: [],
        attachments: {},
        rects: [
          _rect(id: 'mine', creatorName: 'alice'),
          _rect(id: 'theirs', creatorName: 'bob'),
        ],
      );

      String? exported;
      controller.enterMode();
      await controller.exitMode(
        onAnnotationsChanged: (json) async {
          exported = json;
        },
      );

      expect(_rectIds(exported!), ['mine', 'theirs']);
    });

    test('clear() empties the rectangle list (the document-swap path)', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(strokes: [], stamps: [], attachments: {}, rects: [_rect()]);

      controller.clear();

      expect(controller.rects, isEmpty);
      // A second clear is a no-op rather than a notify storm.
      var notified = 0;
      controller.addListener(() => notified++);
      controller.clear();
      expect(notified, 0);
    });

    test('clear() notifies when only rectangles are present', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(strokes: [], stamps: [], attachments: {}, rects: [_rect()]);
      var notified = 0;
      controller.addListener(() => notified++);

      controller.clear();

      expect(notified, 1);
      expect(controller.rects, isEmpty);
    });

    test('undo/redo of a neighbouring edit preserves the rectangle set', () {
      // The snapshot must carry rects: without it an undo restores a stale
      // rectangle set. Work Item 4's rectangle mutators make the stronger
      // "undo a rectangle creation" assertion possible; until then this
      // covers a snapshot that drops the rectangles outright.
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(strokes: [], stamps: [], attachments: {}, rects: [_rect()]);

      controller.addStroke(_stroke());
      expect(controller.rects.map((r) => r.id), ['rect-1']);

      controller.undo();
      expect(controller.strokes, isEmpty);
      expect(controller.rects.map((r) => r.id), ['rect-1']);

      controller.redo();
      expect(controller.strokes, hasLength(1));
      expect(controller.rects.map((r) => r.id), ['rect-1']);
    });
  });
}
