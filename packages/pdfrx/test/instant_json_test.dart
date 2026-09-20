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
      // Payload shrink: `lines.intensities` is no longer emitted, and an id-less
      // stroke omits the `id` key entirely.
      expect(lines.containsKey('intensities'), isFalse);
      expect(entry.containsKey('id'), isFalse);
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

  group('ink id + payload shrink (element split)', () {
    PdfInkAnnotation ink({
      String? id,
      int pageIndex = 0,
      List<Offset> points = const [Offset(0, 0), Offset(1, 1)],
      PdfInkAnnotationKind kind = PdfInkAnnotationKind.pen,
      double opacity = 1.0,
    }) => PdfInkAnnotation(
      id: id,
      pageIndex: pageIndex,
      pointsInPdfSpace: points,
      lineWidth: 2.0,
      strokeColor: const Color(0xFFFF3B30),
      opacity: opacity,
      createdAt: DateTime.utc(2024, 1, 1, 12),
      updatedAt: DateTime.utc(2024, 1, 1, 12),
      kind: kind,
    );

    Map<String, dynamic> encodeSingle(PdfInkAnnotation a) {
      final decoded = jsonDecode(encodeInstantJson([a])) as Map<String, dynamic>;
      return (decoded['annotations'] as List).single as Map<String, dynamic>;
    }

    List<PdfInkAnnotation> decode(String json) =>
        decodeInstantJson(json, pageCount: 1, defaultColor: const Color(0xFFFF0000), defaultLineWidth: 2.0);

    test('encode emits the id when present and omits the key when null', () {
      expect(encodeSingle(ink(id: 'stroke-abc'))['id'], 'stroke-abc');
      expect(encodeSingle(ink()).containsKey('id'), isFalse);
    });

    test('encode rounds ink coordinates to 2 decimals and drops lines.intensities', () {
      final entry = encodeSingle(ink(points: const [Offset(1.239, 2.561), Offset(3.014, 4.986)]));
      final lines = entry['lines'] as Map<String, dynamic>;
      expect(lines.containsKey('intensities'), isFalse);
      expect(lines['points'], [
        [
          [1.24, 2.56],
          [3.01, 4.99],
        ],
      ]);
      // bbox is derived from the rounded points and is itself 2-decimal.
      expect(entry['bbox'], [1.24, 2.56, 1.77, 2.43]);
    });

    test('decode reads the id from a single-segment entry', () {
      const json =
          '{"annotations":[{"v":1,"type":"pspdfkit/ink","id":"stroke-xyz","pageIndex":0,'
          '"lines":{"points":[[[0,0],[1,1]]]},"lineWidth":2,"strokeColor":"#FF3B30"}]}';
      expect(decode(json).single.id, 'stroke-xyz');
    });

    test('decode assigns distinct per-segment ids to a multi-segment entry', () {
      const json =
          '{"annotations":[{"v":2,"type":"pspdfkit/ink","id":"multi","pageIndex":0,'
          '"lines":{"points":[[[0,0],[1,1]],[[2,2],[3,3]],[[4,4],[5,5]]]},"lineWidth":2,"strokeColor":"#FF3B30"}]}';
      expect(decode(json).map((s) => s.id).toList(), ['multi#0', 'multi#1', 'multi#2']);
    });

    test('decode leaves the id null when the entry has none', () {
      const json =
          '{"annotations":[{"v":1,"type":"pspdfkit/ink","pageIndex":0,'
          '"lines":{"points":[[[0,0],[1,1]]]},"lineWidth":2,"strokeColor":"#FF3B30"}]}';
      expect(decode(json).single.id, isNull);
    });

    test('decode falls back to the Unix epoch sentinel for missing timestamps (not now())', () {
      const json =
          '{"annotations":[{"v":1,"type":"pspdfkit/ink","pageIndex":0,'
          '"lines":{"points":[[[0,0],[1,1]]]},"lineWidth":2,"strokeColor":"#FF3B30"}]}';
      final stroke = decode(json).single;
      final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      expect(stroke.createdAt, epoch);
      expect(stroke.updatedAt, epoch);
    });

    test('decode tolerates a fork-authored payload with no lines.intensities', () {
      final json = encodeInstantJson([
        ink(points: const [Offset(2, 3), Offset(4, 5)]),
      ]);
      expect(json.contains('intensities'), isFalse);
      expect(decode(json).single.pointsInPdfSpace, const [Offset(2, 3), Offset(4, 5)]);
    });

    test('encode(decode(x)) == x for a fork-authored payload (id + kind + rounding)', () {
      final x = encodeInstantJson([
        ink(id: 'a1', points: const [Offset(1.239, 2.561), Offset(3.014, 4.986)]),
        ink(
          id: 'b2',
          points: const [Offset(10.5, 20.25), Offset(30.75, 40.125)],
          kind: PdfInkAnnotationKind.highlighter,
          opacity: 0.35,
        ),
      ]);
      expect(encodeInstantJson(decode(x)), x);
    });

    test('rounding is idempotent across two encode/decode cycles', () {
      final x = encodeInstantJson([
        ink(points: const [Offset(1.239, 2.561), Offset(3.014, 4.986)]),
      ]);
      final once = encodeInstantJson(decode(x));
      final twice = encodeInstantJson(decode(once));
      expect(once, x);
      expect(twice, once);
    });
  });

  group('rectangle annotations (pspdfkit/shape/rectangle)', () {
    PdfRectAnnotation rect({
      String id = 'rect-1',
      int pageIndex = 0,
      Rect rectInPdfSpace = const Rect.fromLTWH(10, 20, 120.5, 40.25),
      double rotationDeg = 0.0,
      Color? fillColor = const Color(0xFFFFFFFF),
      String? creatorName = 'alice',
      DateTime? createdAt,
      DateTime? updatedAt,
    }) => PdfRectAnnotation(
      id: id,
      pageIndex: pageIndex,
      rectInPdfSpace: rectInPdfSpace,
      rotationDeg: rotationDeg,
      fillColor: fillColor,
      createdAt: createdAt ?? DateTime.utc(2026, 9, 19, 10),
      updatedAt: updatedAt ?? DateTime.utc(2026, 9, 19, 10),
      creatorName: creatorName,
    );

    DecodedInstantJson decodeFull(String json, {int pageCount = 3}) =>
        decodeInstantJsonFull(json, pageCount: pageCount, defaultColor: const Color(0xFF000000), defaultLineWidth: 2.0);

    PdfInkAnnotation ink({String? id, List<Offset> points = const [Offset(0, 0), Offset(1, 1)]}) => PdfInkAnnotation(
      id: id,
      pageIndex: 0,
      pointsInPdfSpace: points,
      lineWidth: 2.0,
      strokeColor: const Color(0xFFFF3B30),
      opacity: 1.0,
      createdAt: DateTime.utc(2024, 1, 1, 12),
      updatedAt: DateTime.utc(2024, 1, 1, 12),
    );

    Map<String, dynamic> firstEntry(String json) =>
        ((jsonDecode(json) as Map<String, dynamic>)['annotations'] as List).first as Map<String, dynamic>;

    String wrap(List<Map<String, dynamic>> entries) =>
        jsonEncode({'format': instantJsonFormat, 'annotations': entries});

    Map<String, dynamic> rectEntry({
      Object? id = 'rect-1',
      Object? v = 1,
      Object? pageIndex = 0,
      Object? bbox = const [10.0, 20.0, 120.5, 40.25],
      Object? fillColor = '#FFFFFF',
      Object? strokeColor = '#FFFFFF',
    }) => {
      'v': ?v,
      'type': 'pspdfkit/shape/rectangle',
      'id': ?id,
      'pageIndex': ?pageIndex,
      'bbox': ?bbox,
      'opacity': 1.0,
      'strokeWidth': 0,
      'strokeColor': ?strokeColor,
      'fillColor': ?fillColor,
      'pdfrx:rotation': 0.0,
      'createdAt': '2026-09-19T10:00:00.000Z',
      'updatedAt': '2026-09-19T10:00:00.000Z',
      'creatorName': 'alice',
    };

    test('encodes the full pspdfkit/shape/rectangle entry shape', () {
      final entry = firstEntry(encodeInstantJson(const [], rects: [rect()]));
      expect(entry, {
        'v': 1,
        'type': 'pspdfkit/shape/rectangle',
        'id': 'rect-1',
        'pageIndex': 0,
        'bbox': [10.0, 20.0, 120.5, 40.25],
        'opacity': 1.0,
        'strokeWidth': 0,
        'strokeColor': '#FFFFFF',
        'fillColor': '#FFFFFF',
        'pdfrx:rotation': 0.0,
        'createdAt': '2026-09-19T10:00:00.000Z',
        'updatedAt': '2026-09-19T10:00:00.000Z',
        'creatorName': 'alice',
      });
    });

    test('emits strokeColor equal to fillColor with strokeWidth 0 (borderless)', () {
      final entry = firstEntry(encodeInstantJson(const [], rects: [rect(fillColor: const Color(0xFFFAF6EC))]));
      expect(entry['fillColor'], '#FAF6EC');
      expect(entry['strokeColor'], entry['fillColor']);
      expect(entry['strokeWidth'], 0);
    });

    test('emits NO cardinal rotation key, only the namespaced pdfrx:rotation', () {
      final json = encodeInstantJson(const [], rects: [rect(rotationDeg: 88.7)]);
      final entry = firstEntry(json);
      expect(entry.containsKey('rotation'), isFalse);
      expect(entry['pdfrx:rotation'], 88.7);
    });

    test('omits creatorName when null', () {
      final entry = firstEntry(encodeInstantJson(const [], rects: [rect(creatorName: null)]));
      expect(entry.containsKey('creatorName'), isFalse);
    });

    test('decodes a rectangle entry into DecodedInstantJson.rects', () {
      final decoded = decodeFull(wrap([rectEntry()]));
      expect(decoded.rects, hasLength(1));
      final r = decoded.rects.single;
      expect(r.id, 'rect-1');
      expect(r.pageIndex, 0);
      expect(r.rectInPdfSpace, const Rect.fromLTWH(10, 20, 120.5, 40.25));
      expect(r.fillColor, const Color(0xFFFFFFFF));
      expect(r.rotationDeg, 0.0);
      expect(r.creatorName, 'alice');
      expect(decoded.strokes, isEmpty);
      expect(decoded.stamps, isEmpty);
    });

    test('encode -> decode round-trips every rectangle field', () {
      final original = rect(
        id: 'rect-xyz',
        pageIndex: 2,
        rectInPdfSpace: const Rect.fromLTWH(1.5, 2.25, 33.75, 44.5),
        rotationDeg: 37.5,
        fillColor: const Color(0xFF007AFF),
        creatorName: 'bob',
        createdAt: DateTime.utc(2026, 3, 4, 5, 6, 7, 8),
        updatedAt: DateTime.utc(2026, 3, 4, 9, 10, 11, 12),
      );
      final r = decodeFull(encodeInstantJson(const [], rects: [original])).rects.single;
      expect(r.id, original.id);
      expect(r.pageIndex, original.pageIndex);
      expect(r.rectInPdfSpace, original.rectInPdfSpace);
      expect(r.rotationDeg, original.rotationDeg);
      expect(r.fillColor, original.fillColor);
      expect(r.creatorName, original.creatorName);
      expect(r.createdAt, original.createdAt);
      expect(r.updatedAt, original.updatedAt);
    });

    test('encode(decode(x)) == x for a payload mixing ink, stamps and rectangles', () {
      final x = encodeInstantJson(
        [
          ink(id: 'ink-1', points: const [Offset(1, 2), Offset(3, 4)]),
        ],
        rects: [
          rect(id: 'r1'),
          rect(id: 'r2', rotationDeg: 12.5, fillColor: const Color(0xFFFF3B30)),
        ],
      );
      final decoded = decodeFull(x);
      expect(decoded.rects, hasLength(2));
      expect(encodeInstantJson(decoded.strokes, stamps: decoded.stamps, rects: decoded.rects), x);
    });

    test('a malformed rectangle is skipped without dropping its siblings', () {
      final json = wrap([
        rectEntry(id: 'good-1'),
        rectEntry(id: 'bad-bbox', bbox: const [1, 2, 'x', 4]),
        rectEntry(id: 'bad-bbox-short', bbox: const [1, 2, 3]),
        rectEntry(id: 'bad-bbox-type', bbox: 'nope'),
        rectEntry(id: null),
        rectEntry(id: ''),
        rectEntry(id: 'bad-page', pageIndex: 99),
        rectEntry(id: 'bad-page-negative', pageIndex: -1),
        rectEntry(id: 'bad-version', v: 0),
        rectEntry(id: 'good-2'),
      ]);
      final decoded = decodeFull(json);
      expect(decoded.rects.map((r) => r.id), ['good-1', 'good-2']);
    });

    test('a missing or unparseable fillColor decodes to NO fill, and the entry is kept', () {
      final json = wrap([
        rectEntry(id: 'no-fill', fillColor: null),
        rectEntry(id: 'bad-fill', fillColor: 'not-a-color'),
        rectEntry(id: 'non-string-fill', fillColor: 42),
      ]);
      final decoded = decodeFull(json);
      expect(decoded.rects.map((r) => r.id), ['no-fill', 'bad-fill', 'non-string-fill']);
      for (final r in decoded.rects) {
        // Never a white fallback: white is the tool's creation default only.
        expect(r.fillColor, isNull);
      }
    });

    test('a no-fill rectangle survives a re-encode (still schema-valid, still no fill)', () {
      final once = encodeInstantJson(const [], rects: decodeFull(wrap([rectEntry(fillColor: null)])).rects);
      final entry = firstEntry(once);
      expect(entry.containsKey('fillColor'), isFalse);
      expect(entry['strokeWidth'], 0);
      expect(entry['strokeColor'], isA<String>());
      expect(decodeFull(once).rects.single.fillColor, isNull);
      expect(encodeInstantJson(const [], rects: decodeFull(once).rects), once);
    });

    test('rotationDeg reads pdfrx:rotation, then rotation, then 0.0', () {
      final json = wrap([
        rectEntry(id: 'both'),
        {...rectEntry(id: 'cardinal-only'), 'pdfrx:rotation': null, 'rotation': 90},
        {...rectEntry(id: 'neither'), 'pdfrx:rotation': null},
      ]);
      final byId = {for (final r in decodeFull(json).rects) r.id: r};
      expect(byId['both']!.rotationDeg, 0.0);
      expect(byId['cardinal-only']!.rotationDeg, 90.0);
      expect(byId['neither']!.rotationDeg, 0.0);
    });

    test('missing timestamps fall back to the Unix epoch sentinel (not now())', () {
      final entry = rectEntry()
        ..remove('createdAt')
        ..remove('updatedAt');
      final r = decodeFull(wrap([entry])).rects.single;
      final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      expect(r.createdAt, epoch);
      expect(r.updatedAt, epoch);
    });

    test('accepts any positive integer v (forward-compat with pspdfkit v:2)', () {
      expect(decodeFull(wrap([rectEntry(v: 2)])).rects, hasLength(1));
    });

    test('the legacy ink-only decodeInstantJson ignores rectangles', () {
      final json = encodeInstantJson([ink(id: 'k')], rects: [rect()]);
      final strokes = decodeInstantJson(
        json,
        pageCount: 3,
        defaultColor: const Color(0xFF000000),
        defaultLineWidth: 2.0,
      );
      expect(strokes, hasLength(1));
      expect(strokes.single.id, 'k');
    });

    test('copyWith replaces only the supplied fields', () {
      final original = rect();
      final moved = original.copyWith(rectInPdfSpace: const Rect.fromLTWH(1, 2, 3, 4));
      expect(moved.rectInPdfSpace, const Rect.fromLTWH(1, 2, 3, 4));
      expect(moved.id, original.id);
      expect(moved.pageIndex, original.pageIndex);
      expect(moved.rotationDeg, original.rotationDeg);
      expect(moved.fillColor, original.fillColor);
      expect(moved.createdAt, original.createdAt);
      expect(moved.updatedAt, original.updatedAt);
      expect(moved.creatorName, original.creatorName);
    });
  });

  group('unrecognised entries survive a round trip', () {
    const color = Color(0xFFFF0000);

    // A plausible "type after next": a kind no build in this tree knows,
    // carrying fields the decoder has no model for.
    const futureEntry = {
      'v': 1,
      'type': 'pspdfkit/shape/ellipse',
      'id': 'future-1',
      'pageIndex': 0,
      'bbox': [10.0, 20.0, 30.0, 40.0],
      'fillColor': '#00FF00',
      'pdfrx:someFutureKnob': {'nested': true, 'count': 7},
      'createdAt': '2026-01-02T03:04:05.000Z',
      'updatedAt': '2026-01-02T03:04:05.000Z',
      'creatorName': 'alice',
    };

    DecodedInstantJson decode(String json, {int pageCount = 1}) =>
        decodeInstantJsonFull(json, pageCount: pageCount, defaultColor: color, defaultLineWidth: 1.0);

    test('decode carries an unknown type verbatim instead of dropping it', () {
      final json = jsonEncode({
        'annotations': [
          futureEntry,
          {
            'v': 1,
            'type': 'pspdfkit/ink',
            'id': 'ink-1',
            'pageIndex': 0,
            'lines': {
              'points': [
                [
                  [0, 0],
                  [1, 1],
                ],
              ],
            },
            'lineWidth': 1,
            'strokeColor': '#000000',
          },
        ],
      });

      final decoded = decode(json);

      expect(decoded.strokes, hasLength(1));
      expect(decoded.unknowns, hasLength(1));
      expect(decoded.unknowns.single, futureEntry);
    });

    test('encode re-emits an unknown entry unchanged', () {
      final json = encodeInstantJson(const [], unknowns: [Map<String, dynamic>.from(futureEntry)]);

      final entries = (jsonDecode(json) as Map<String, dynamic>)['annotations'] as List<dynamic>;
      expect(entries, hasLength(1));
      expect(entries.single, futureEntry);
    });

    test('decode -> encode -> decode preserves the unknown entry exactly', () {
      final original = jsonEncode({
        'annotations': [futureEntry],
      });

      final once = decode(original);
      final reencoded = encodeInstantJson(
        once.strokes,
        stamps: once.stamps,
        rects: once.rects,
        unknowns: once.unknowns,
        attachments: once.attachments,
      );
      final twice = decode(reencoded);

      expect(twice.unknowns.single, futureEntry);
    });

    test("an unknown entry's attachment is kept, not pruned as orphaned", () {
      const sha = 'aabbcc';
      final binary = base64Encode(const [1, 2, 3]);
      final json = jsonEncode({
        'annotations': [
          {...futureEntry, 'imageAttachmentId': sha},
        ],
        'attachments': {
          sha: {'binary': binary, 'contentType': 'image/png'},
        },
      });

      final decoded = decode(json);

      // The binary must survive the decode even though no STAMP refers to
      // it: the entry that does is one this build cannot model.
      expect(decoded.attachments.containsKey(sha), isTrue);

      final reencoded = encodeInstantJson(
        decoded.strokes,
        unknowns: decoded.unknowns,
        attachments: decoded.attachments,
      );
      final out = jsonDecode(reencoded) as Map<String, dynamic>;
      final attachments = out['attachments'] as Map<String, dynamic>;
      expect(attachments[sha], {'binary': binary, 'contentType': 'image/png'});
    });

    test('an unknown entry on an out-of-range page is still carried', () {
      // Bounds checks belong to the decoders that build a model. A kind
      // with no model gets no geometry opinion imposed on it, or a page
      // count that shrank once would silently delete it.
      final json = jsonEncode({
        'annotations': [
          {...futureEntry, 'pageIndex': 99},
        ],
      });

      expect(decode(json).unknowns, hasLength(1));
    });
  });
}
