import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  group('decodeInstantJson', () {
    test('returns an empty list for empty or whitespace input', () {
      expect(
        decodeInstantJson('', pageCount: 1, defaultColor: const Color(0xFFFF0000), defaultLineWidth: 1.0),
        isEmpty,
      );
      expect(
        decodeInstantJson('   \n  ', pageCount: 1, defaultColor: const Color(0xFFFF0000), defaultLineWidth: 1.0),
        isEmpty,
      );
    });

    test('throws FormatException on malformed JSON', () {
      expect(
        () =>
            decodeInstantJson('{not json', pageCount: 1, defaultColor: const Color(0xFFFF0000), defaultLineWidth: 1.0),
        throwsFormatException,
      );
    });

    test('skips entries with unknown type, missing v, or out-of-range pageIndex', () {
      const json = '''
        {
          "annotations": [
            {"v": 1, "type": "pspdfkit/highlight", "pageIndex": 0, "lines": {"points": [[[0,0],[1,1]]]}, "lineWidth": 1, "strokeColor": "#000000"},
            {"v": 0, "type": "pspdfkit/ink", "pageIndex": 0, "lines": {"points": [[[0,0],[1,1]]]}, "lineWidth": 1, "strokeColor": "#000000"},
            {"v": "bad", "type": "pspdfkit/ink", "pageIndex": 0, "lines": {"points": [[[0,0],[1,1]]]}, "lineWidth": 1, "strokeColor": "#000000"},
            {"v": 1, "type": "pspdfkit/ink", "pageIndex": 99, "lines": {"points": [[[0,0],[1,1]]]}, "lineWidth": 1, "strokeColor": "#000000"},
            {"v": 1, "type": "pspdfkit/ink", "pageIndex": -1, "lines": {"points": [[[0,0],[1,1]]]}, "lineWidth": 1, "strokeColor": "#000000"},
            {"v": 1, "type": "pspdfkit/ink", "pageIndex": 0, "lines": {"points": [[[7,7],[8,8]]]}, "lineWidth": 1, "strokeColor": "#000000"}
          ]
        }
      ''';

      final result = decodeInstantJson(
        json,
        pageCount: 3,
        defaultColor: const Color(0xFFFF0000),
        defaultLineWidth: 2.0,
      );

      expect(result, hasLength(1));
      expect(result.single.pointsInPdfSpace, [const Offset(7, 7), const Offset(8, 8)]);
    });

    test('expands a multi-segment ink entry into one stroke per segment', () {
      // pspdfkit packs multiple polylines under one annotation entry with
      // shared metadata. Decoder must produce one PdfInkAnnotation per
      // segment.
      const json = '''
        {
          "annotations": [
            {
              "v": 2,
              "type": "pspdfkit/ink",
              "pageIndex": 0,
              "lineWidth": 3,
              "strokeColor": "#FF3B30",
              "creatorName": "alice",
              "lines": {
                "points": [
                  [[1,1],[2,2]],
                  [[10,10],[11,11],[12,12]],
                  [[20,20],[21,21]]
                ]
              }
            }
          ]
        }
      ''';
      final result = decodeInstantJson(
        json,
        pageCount: 1,
        defaultColor: const Color(0xFFFF0000),
        defaultLineWidth: 2.0,
      );
      expect(result, hasLength(3));
      // Shared metadata propagates to every decoded stroke.
      for (final stroke in result) {
        expect(stroke.creatorName, 'alice');
        expect(stroke.lineWidth, 3);
        expect(stroke.pageIndex, 0);
      }
      expect(result[0].pointsInPdfSpace, [const Offset(1, 1), const Offset(2, 2)]);
      expect(result[1].pointsInPdfSpace, [const Offset(10, 10), const Offset(11, 11), const Offset(12, 12)]);
      expect(result[2].pointsInPdfSpace, [const Offset(20, 20), const Offset(21, 21)]);
    });

    test('preserves single-point segments (pspdfkit "dot" tap)', () {
      // pspdfkit treats a tap with no drag as a 1-point segment and
      // renders it as a small filled circle. pdfrx preserves the
      // segment verbatim — the painter renders a zero-length stroke
      // with round caps as a circle of diameter `lineWidth`, matching
      // pspdfkit's marker-tap visual without reshaping the data.
      const json = '''
        {
          "annotations": [
            {"v": 1, "type": "pspdfkit/ink", "pageIndex": 0, "lines": {"points": [[[5,5]]]}, "lineWidth": 1, "strokeColor": "#000000"}
          ]
        }
      ''';
      final result = decodeInstantJson(
        json,
        pageCount: 1,
        defaultColor: const Color(0xFFFF0000),
        defaultLineWidth: 2.0,
      );
      expect(result, hasLength(1));
      expect(result.single.pointsInPdfSpace, [const Offset(5, 5)]);
    });

    test('accepts any positive integer v (forward-compat with pspdfkit v:2)', () {
      // pspdfkit's native Instant JSON wire format uses v: 2; the ink schema
      // didn't break compat with v: 1 for the fields pdfrx reads, so the
      // decoder treats `v` as a soft forward-compat marker.
      const json = '''
        {
          "annotations": [
            {"v": 2, "type": "pspdfkit/ink", "pageIndex": 0, "lines": {"points": [[[1,2],[3,4]]]}, "lineWidth": 1, "strokeColor": "#000000"},
            {"v": 7, "type": "pspdfkit/ink", "pageIndex": 0, "lines": {"points": [[[5,6],[7,8]]]}, "lineWidth": 1, "strokeColor": "#000000"}
          ]
        }
      ''';
      final result = decodeInstantJson(
        json,
        pageCount: 1,
        defaultColor: const Color(0xFFFF0000),
        defaultLineWidth: 2.0,
      );
      expect(result, hasLength(2));
      expect(result.first.pointsInPdfSpace, [const Offset(1, 2), const Offset(3, 4)]);
      expect(result.last.pointsInPdfSpace, [const Offset(5, 6), const Offset(7, 8)]);
    });

    test('tolerates a bare-array form (no document wrapper)', () {
      const json = '''
        [
          {
            "v": 1,
            "type": "pspdfkit/ink",
            "pageIndex": 0,
            "bbox": [0, 0, 10, 10],
            "opacity": 1,
            "createdAt": "2024-01-01T00:00:00.000Z",
            "updatedAt": "2024-01-01T00:00:00.000Z",
            "lines": {
              "intensities": [[1, 1]],
              "points": [[[0, 0], [10, 10]]]
            },
            "lineWidth": 2,
            "isDrawnNaturally": false,
            "strokeColor": "#000000"
          }
        ]
      ''';

      final result = decodeInstantJson(
        json,
        pageCount: 1,
        defaultColor: const Color(0xFFFF0000),
        defaultLineWidth: 2.0,
      );

      expect(result, hasLength(1));
      expect(result.single.pointsInPdfSpace, [const Offset(0, 0), const Offset(10, 10)]);
    });

    test('decodes a wrapped document with one ink stroke into one PdfInkAnnotation', () {
      const json = '''
        {
          "format": "https://pspdfkit.com/instant-json/v1",
          "annotations": [
            {
              "v": 1,
              "type": "pspdfkit/ink",
              "pageIndex": 0,
              "bbox": [10, 20, 30, 40],
              "opacity": 1,
              "createdAt": "2024-01-01T00:00:00.000Z",
              "updatedAt": "2024-01-01T00:00:00.000Z",
              "lines": {
                "intensities": [[1, 1, 1]],
                "points": [[[10, 20], [25, 30], [40, 60]]]
              },
              "lineWidth": 3.5,
              "isDrawnNaturally": false,
              "strokeColor": "#FF3B30"
            }
          ]
        }
      ''';

      final result = decodeInstantJson(
        json,
        pageCount: 3,
        defaultColor: const Color(0xFFFF0000),
        defaultLineWidth: 2.0,
      );

      expect(result, hasLength(1));
      final annotation = result.single;
      expect(annotation.pageIndex, 0);
      expect(annotation.pointsInPdfSpace, [const Offset(10, 20), const Offset(25, 30), const Offset(40, 60)]);
      expect(annotation.lineWidth, 3.5);
      expect(annotation.strokeColor, const Color(0xFFFF3B30));
      expect(annotation.opacity, 1.0);
    });
  });

  group('encodeInstantJson', () {
    test('produces a wrapper with the format URL and one ink entry per stroke', () {
      final annotation = PdfInkAnnotation(
        pageIndex: 1,
        pointsInPdfSpace: const [Offset(5, 10), Offset(15, 25), Offset(30, 40)],
        lineWidth: 2.5,
        strokeColor: const Color(0xFFFF3B30),
        opacity: 1.0,
        createdAt: DateTime.utc(2024, 1, 1, 12, 0, 0),
        updatedAt: DateTime.utc(2024, 1, 1, 12, 0, 5),
      );

      final json = encodeInstantJson([annotation]);
      final decoded = jsonDecode(json) as Map<String, dynamic>;

      expect(decoded['format'], 'https://pspdfkit.com/instant-json/v1');
      expect(decoded.containsKey('pdfId'), isFalse);
      expect(decoded['annotations'], isA<List>());

      final entry = (decoded['annotations'] as List).single as Map<String, dynamic>;
      expect(entry['v'], 1);
      expect(entry['type'], 'pspdfkit/ink');
      expect(entry['pageIndex'], 1);
      expect(entry['lineWidth'], 2.5);
      expect(entry['strokeColor'], '#FF3B30');
      expect(entry['opacity'], 1.0);
      expect(entry['isDrawnNaturally'], false);
      expect(entry['createdAt'], '2024-01-01T12:00:00.000Z');
      expect(entry['updatedAt'], '2024-01-01T12:00:05.000Z');
      expect(entry['bbox'], [5.0, 10.0, 25.0, 30.0]); // [left, top, width, height]

      final lines = entry['lines'] as Map<String, dynamic>;
      expect(lines['points'], [
        [
          [5.0, 10.0],
          [15.0, 25.0],
          [30.0, 40.0],
        ],
      ]);
      expect(lines['intensities'], [
        [1.0, 1.0, 1.0],
      ]);
    });

    test('encodes creatorName when present and omits the key when null', () {
      final tagged = PdfInkAnnotation(
        pageIndex: 0,
        pointsInPdfSpace: const [Offset(0, 0), Offset(1, 1)],
        lineWidth: 1.0,
        strokeColor: const Color(0xFF000000),
        opacity: 1.0,
        createdAt: DateTime.utc(2024, 1, 1),
        updatedAt: DateTime.utc(2024, 1, 1),
        creatorName: 'alice',
      );
      final untagged = PdfInkAnnotation(
        pageIndex: 0,
        pointsInPdfSpace: const [Offset(0, 0), Offset(2, 2)],
        lineWidth: 1.0,
        strokeColor: const Color(0xFF000000),
        opacity: 1.0,
        createdAt: DateTime.utc(2024, 1, 1),
        updatedAt: DateTime.utc(2024, 1, 1),
      );

      final decoded = jsonDecode(encodeInstantJson([tagged, untagged])) as Map<String, dynamic>;
      final entries = (decoded['annotations'] as List).cast<Map<String, dynamic>>();
      expect(entries[0]['creatorName'], 'alice');
      expect(entries[1].containsKey('creatorName'), isFalse);
    });

    test('decodes creatorName when present, leaves it null when missing or non-string', () {
      const json = '''
        {
          "annotations": [
            {"v": 1, "type": "pspdfkit/ink", "pageIndex": 0, "lines": {"points": [[[0,0],[1,1]]]}, "lineWidth": 1, "strokeColor": "#000000", "creatorName": "bob"},
            {"v": 1, "type": "pspdfkit/ink", "pageIndex": 0, "lines": {"points": [[[2,2],[3,3]]]}, "lineWidth": 1, "strokeColor": "#000000"},
            {"v": 1, "type": "pspdfkit/ink", "pageIndex": 0, "lines": {"points": [[[4,4],[5,5]]]}, "lineWidth": 1, "strokeColor": "#000000", "creatorName": 42}
          ]
        }
      ''';

      final result = decodeInstantJson(
        json,
        pageCount: 1,
        defaultColor: const Color(0xFFFF0000),
        defaultLineWidth: 1.0,
      );

      expect(result, hasLength(3));
      expect(result[0].creatorName, 'bob');
      expect(result[1].creatorName, isNull);
      expect(result[2].creatorName, isNull);
    });

    test('omits pdfrx:kind for pen entries; emits "highlighter" for highlighter entries', () {
      final pen = PdfInkAnnotation(
        pageIndex: 0,
        pointsInPdfSpace: const [Offset(0, 0), Offset(1, 1)],
        lineWidth: 1.0,
        strokeColor: const Color(0xFF000000),
        opacity: 1.0,
        createdAt: DateTime.utc(2024, 1, 1),
        updatedAt: DateTime.utc(2024, 1, 1),
      );
      final highlighter = PdfInkAnnotation(
        pageIndex: 0,
        pointsInPdfSpace: const [Offset(2, 2), Offset(3, 3)],
        lineWidth: 12.0,
        strokeColor: const Color(0xFFFFFF00),
        opacity: 0.35,
        createdAt: DateTime.utc(2024, 1, 1),
        updatedAt: DateTime.utc(2024, 1, 1),
        kind: PdfInkAnnotationKind.highlighter,
      );

      final decoded = jsonDecode(encodeInstantJson([pen, highlighter])) as Map<String, dynamic>;
      final entries = (decoded['annotations'] as List).cast<Map<String, dynamic>>();
      expect(entries[0].containsKey('pdfrx:kind'), isFalse);
      expect(entries[1]['pdfrx:kind'], 'highlighter');
    });

    test('decoder round-trips kind from explicit pdfrx:kind field', () {
      const json = '''
        {
          "annotations": [
            {"v": 1, "type": "pspdfkit/ink", "pageIndex": 0, "lines": {"points": [[[0,0],[1,1]]]}, "lineWidth": 12, "strokeColor": "#FFFF00", "opacity": 0.35, "pdfrx:kind": "highlighter"},
            {"v": 1, "type": "pspdfkit/ink", "pageIndex": 0, "lines": {"points": [[[2,2],[3,3]]]}, "lineWidth": 1, "strokeColor": "#000000", "opacity": 1.0, "pdfrx:kind": "pen"}
          ]
        }
      ''';

      final result = decodeInstantJson(
        json,
        pageCount: 1,
        defaultColor: const Color(0xFFFF0000),
        defaultLineWidth: 1.0,
      );

      expect(result, hasLength(2));
      expect(result[0].kind, PdfInkAnnotationKind.highlighter);
      expect(result[1].kind, PdfInkAnnotationKind.pen);
    });

    test('decoder infers highlighter from opacity < 1.0 when pdfrx:kind is missing', () {
      const json = '''
        {
          "annotations": [
            {"v": 1, "type": "pspdfkit/ink", "pageIndex": 0, "lines": {"points": [[[0,0],[1,1]]]}, "lineWidth": 12, "strokeColor": "#FFFF00", "opacity": 0.35},
            {"v": 1, "type": "pspdfkit/ink", "pageIndex": 0, "lines": {"points": [[[2,2],[3,3]]]}, "lineWidth": 1, "strokeColor": "#000000", "opacity": 1.0}
          ]
        }
      ''';

      final result = decodeInstantJson(
        json,
        pageCount: 1,
        defaultColor: const Color(0xFFFF0000),
        defaultLineWidth: 1.0,
      );

      expect(result, hasLength(2));
      expect(result[0].kind, PdfInkAnnotationKind.highlighter);
      expect(result[1].kind, PdfInkAnnotationKind.pen);
    });

    test('decoder tolerates malformed pdfrx:kind values and falls back to opacity inference', () {
      const json = '''
        {
          "annotations": [
            {"v": 1, "type": "pspdfkit/ink", "pageIndex": 0, "lines": {"points": [[[0,0],[1,1]]]}, "lineWidth": 12, "strokeColor": "#FFFF00", "opacity": 0.35, "pdfrx:kind": 42},
            {"v": 1, "type": "pspdfkit/ink", "pageIndex": 0, "lines": {"points": [[[2,2],[3,3]]]}, "lineWidth": 1, "strokeColor": "#000000", "opacity": 1.0, "pdfrx:kind": "marker"}
          ]
        }
      ''';

      final result = decodeInstantJson(
        json,
        pageCount: 1,
        defaultColor: const Color(0xFFFF0000),
        defaultLineWidth: 1.0,
      );

      // Both entries are decoded (never dropped) and fall back to opacity-based inference.
      expect(result, hasLength(2));
      expect(result[0].kind, PdfInkAnnotationKind.highlighter);
      expect(result[1].kind, PdfInkAnnotationKind.pen);
    });

    test('legacy fixture (no pdfrx:kind, opacity == 1.0) still decodes as pen', () {
      const json = '''
        {
          "annotations": [
            {
              "v": 1,
              "type": "pspdfkit/ink",
              "pageIndex": 0,
              "lines": {"points": [[[0,0],[10,10]]]},
              "lineWidth": 2,
              "strokeColor": "#000000",
              "opacity": 1.0
            }
          ]
        }
      ''';

      final result = decodeInstantJson(
        json,
        pageCount: 1,
        defaultColor: const Color(0xFFFF0000),
        defaultLineWidth: 1.0,
      );

      expect(result.single.kind, PdfInkAnnotationKind.pen);
    });

    test('round-trip preserves kind on every entry across a mixed list', () {
      final original = [
        PdfInkAnnotation(
          pageIndex: 0,
          pointsInPdfSpace: const [Offset(0, 0), Offset(1, 1)],
          lineWidth: 1.0,
          strokeColor: const Color(0xFF000000),
          opacity: 1.0,
          createdAt: DateTime.utc(2024, 1, 1),
          updatedAt: DateTime.utc(2024, 1, 1),
        ),
        PdfInkAnnotation(
          pageIndex: 0,
          pointsInPdfSpace: const [Offset(2, 2), Offset(3, 3)],
          lineWidth: 12.0,
          strokeColor: const Color(0xFFFFFF00),
          opacity: 0.35,
          createdAt: DateTime.utc(2024, 1, 1),
          updatedAt: DateTime.utc(2024, 1, 1),
          kind: PdfInkAnnotationKind.highlighter,
        ),
        PdfInkAnnotation(
          pageIndex: 0,
          pointsInPdfSpace: const [Offset(4, 4), Offset(5, 5)],
          lineWidth: 16.0,
          strokeColor: const Color(0xFFFF69B4),
          opacity: 0.35,
          createdAt: DateTime.utc(2024, 1, 1),
          updatedAt: DateTime.utc(2024, 1, 1),
          kind: PdfInkAnnotationKind.highlighter,
        ),
      ];

      final decoded = decodeInstantJson(
        encodeInstantJson(original),
        pageCount: 1,
        defaultColor: const Color(0xFFFF0000),
        defaultLineWidth: 1.0,
      );

      expect(decoded, hasLength(3));
      for (var i = 0; i < original.length; i++) {
        expect(decoded[i].kind, original[i].kind);
      }
    });

    test('encode -> decode round-trip preserves stroke data', () {
      final original = [
        PdfInkAnnotation(
          pageIndex: 0,
          pointsInPdfSpace: const [Offset(1.5, 2.5), Offset(10.25, 20.5), Offset(33.0, 44.0)],
          lineWidth: 1.75,
          strokeColor: const Color(0xFF112233),
          opacity: 1.0,
          createdAt: DateTime.utc(2024, 6, 15, 10, 30, 0),
          updatedAt: DateTime.utc(2024, 6, 15, 10, 30, 0),
          creatorName: 'alice',
        ),
        PdfInkAnnotation(
          pageIndex: 2,
          pointsInPdfSpace: const [Offset(0, 0), Offset(50, 50)],
          lineWidth: 4.0,
          strokeColor: const Color(0xFFABCDEF),
          opacity: 1.0,
          createdAt: DateTime.utc(2024, 6, 15, 10, 31, 0),
          updatedAt: DateTime.utc(2024, 6, 15, 10, 31, 30),
        ),
      ];

      final json = encodeInstantJson(original);
      final decoded = decodeInstantJson(
        json,
        pageCount: 5,
        defaultColor: const Color(0xFFFF0000),
        defaultLineWidth: 2.0,
      );

      expect(decoded, hasLength(2));
      for (var i = 0; i < original.length; i++) {
        expect(decoded[i].pageIndex, original[i].pageIndex);
        expect(decoded[i].lineWidth, closeTo(original[i].lineWidth, 1e-9));
        expect(decoded[i].strokeColor, original[i].strokeColor);
        expect(decoded[i].opacity, closeTo(original[i].opacity, 1e-9));
        expect(decoded[i].creatorName, original[i].creatorName);
        for (var j = 0; j < original[i].pointsInPdfSpace.length; j++) {
          expect(decoded[i].pointsInPdfSpace[j].dx, closeTo(original[i].pointsInPdfSpace[j].dx, 1e-6));
          expect(decoded[i].pointsInPdfSpace[j].dy, closeTo(original[i].pointsInPdfSpace[j].dy, 1e-6));
        }
      }
    });
  });
}
