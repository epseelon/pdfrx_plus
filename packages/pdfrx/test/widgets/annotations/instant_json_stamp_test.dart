import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/instant_json.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_ink_annotation.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_stamp_annotation.dart';

PdfInkAnnotation _stroke({int pageIndex = 0, List<Offset> points = const [Offset(0, 0), Offset(10, 10)]}) =>
    PdfInkAnnotation(
      pageIndex: pageIndex,
      pointsInPdfSpace: points,
      lineWidth: 1.0,
      strokeColor: const Color(0xFF000000),
      opacity: 1.0,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );

PdfStampAnnotation _stamp({
  required String hash,
  String id = 'stamp-1',
  int pageIndex = 0,
  Rect rect = const Rect.fromLTWH(10, 10, 24, 24),
  double rotationDeg = 0,
  String contentType = 'image/svg+xml',
  String? creatorName,
}) => PdfStampAnnotation(
  id: id,
  pageIndex: pageIndex,
  rectInPdfSpace: rect,
  rotationDeg: rotationDeg,
  attachmentSha256: hash,
  contentType: contentType,
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 1, 2),
  creatorName: creatorName,
);

void main() {
  group('encodeInstantJson stamps + attachments', () {
    test('attachments field is omitted from JSON when no stamps are present (legacy ink-only output)', () {
      final json = encodeInstantJson([_stroke()]);
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      expect(decoded.containsKey('attachments'), isFalse);
    });

    test('encodes stamps with v:1, bbox, contentType, imageAttachmentId, snapped + free rotation', () {
      final bytes = Uint8List.fromList(utf8.encode('<svg/>'));
      final hash = sha256.convert(bytes).toString();
      final attachments = {hash: PdfStampAttachment(bytes: bytes, contentType: 'image/svg+xml')};

      final json = encodeInstantJson(
        const [],
        stamps: [_stamp(hash: hash, rotationDeg: 47.5)],
        attachments: attachments,
      );
      final decoded = jsonDecode(json) as Map<String, dynamic>;

      final entries = (decoded['annotations'] as List).cast<Map<String, dynamic>>();
      expect(entries, hasLength(1));
      final entry = entries.single;
      expect(entry['type'], 'pspdfkit/image');
      expect(entry['v'], 1);
      expect(entry['contentType'], 'image/svg+xml');
      expect(entry['imageAttachmentId'], hash);
      expect(entry['bbox'], [10, 10, 24, 24]);
      expect(entry['rotation'], 90); // 47.5° snaps to nearest cardinal = 90°
      expect((entry['pdfrx:rotation'] as num).toDouble(), closeTo(47.5, 1e-9));

      final atts = decoded['attachments'] as Map<String, dynamic>;
      expect(atts.keys.toList(), [hash]);
      final att = atts[hash] as Map<String, dynamic>;
      expect(att['contentType'], 'image/svg+xml');
      expect(att['binary'], base64Encode(bytes));
    });

    test('round-trip: encode + decode preserves rect, rotation (free angle), contentType, hash', () {
      final bytes = Uint8List.fromList(utf8.encode('<svg id=t/>'));
      final hash = sha256.convert(bytes).toString();
      final original = _stamp(
        id: 'abc',
        pageIndex: 0,
        rect: const Rect.fromLTWH(12, 13, 25, 19),
        rotationDeg: 137.42,
        hash: hash,
        creatorName: 'alice',
      );
      final attachments = {hash: PdfStampAttachment(bytes: bytes, contentType: 'image/svg+xml')};
      final json = encodeInstantJson(const [], stamps: [original], attachments: attachments);

      final decoded = decodeInstantJsonFull(
        json,
        pageCount: 1,
        defaultColor: const Color(0xFFFF0000),
        defaultLineWidth: 1.0,
      );

      expect(decoded.strokes, isEmpty);
      expect(decoded.stamps, hasLength(1));
      final stamp = decoded.stamps.single;
      expect(stamp.id, original.id);
      expect(stamp.rectInPdfSpace, original.rectInPdfSpace);
      expect(stamp.rotationDeg, closeTo(137.42, 1e-9));
      expect(stamp.attachmentSha256, hash);
      expect(stamp.contentType, 'image/svg+xml');
      expect(stamp.creatorName, 'alice');
      expect(decoded.attachments[hash]?.bytes, bytes);
    });

    test('round-trip with one ink stroke + one stamp keeps both kinds', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final hash = sha256.convert(bytes).toString();
      final attachments = {hash: PdfStampAttachment(bytes: bytes, contentType: 'image/png')};

      final json = encodeInstantJson(
        [_stroke()],
        stamps: [_stamp(hash: hash, contentType: 'image/png')],
        attachments: attachments,
      );

      final decoded = decodeInstantJsonFull(
        json,
        pageCount: 1,
        defaultColor: const Color(0xFFFF0000),
        defaultLineWidth: 1.0,
      );
      expect(decoded.strokes, hasLength(1));
      expect(decoded.stamps, hasLength(1));
      expect(decoded.attachments.containsKey(hash), isTrue);
    });

    test('SHA-256 dedupe: encoding two stamps with the same bytes produces one attachment entry', () {
      final bytes = Uint8List.fromList(utf8.encode('shared'));
      final hash = sha256.convert(bytes).toString();
      final attachments = {hash: PdfStampAttachment(bytes: bytes, contentType: 'image/svg+xml')};
      final json = encodeInstantJson(
        const [],
        stamps: [
          _stamp(id: 'a', hash: hash),
          _stamp(id: 'b', hash: hash),
        ],
        attachments: attachments,
      );
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      final atts = decoded['attachments'] as Map<String, dynamic>;
      expect(atts, hasLength(1));
    });

    test('attachments not referenced by any stamp are dropped at encode time', () {
      final bytes = Uint8List.fromList([9, 9]);
      final hash = sha256.convert(bytes).toString();
      // Stamps list is empty but attachments map contains a stale entry.
      final json = encodeInstantJson(
        const [],
        stamps: const [],
        attachments: {hash: PdfStampAttachment(bytes: bytes, contentType: 'image/svg+xml')},
      );
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      expect(decoded.containsKey('attachments'), isFalse);
    });
  });

  group('decodeInstantJsonFull stamp tolerance', () {
    test('skips stamp whose imageAttachmentId is not present in attachments map', () {
      final json = jsonEncode({
        'format': 'https://pspdfkit.com/instant-json/v1',
        'annotations': [
          {
            'v': 1,
            'type': 'pspdfkit/image',
            'id': 'orphan',
            'pageIndex': 0,
            'bbox': [0, 0, 10, 10],
            'imageAttachmentId': 'missing',
            'contentType': 'image/svg+xml',
            'rotation': 0,
            'pdfrx:rotation': 0,
          },
        ],
        'attachments': {},
      });
      final decoded = decodeInstantJsonFull(
        json,
        pageCount: 1,
        defaultColor: const Color(0xFFFF0000),
        defaultLineWidth: 1.0,
      );
      expect(decoded.stamps, isEmpty);
      expect(decoded.attachments, isEmpty);
    });

    test('drops attachment entries whose binary is malformed base64', () {
      final json = jsonEncode({
        'format': 'https://pspdfkit.com/instant-json/v1',
        'annotations': [
          {
            'v': 1,
            'type': 'pspdfkit/image',
            'id': 'a',
            'pageIndex': 0,
            'bbox': [0, 0, 10, 10],
            'imageAttachmentId': 'bad-hash',
            'contentType': 'image/svg+xml',
          },
        ],
        'attachments': {
          'bad-hash': {'binary': 'not-base-64-!!!!', 'contentType': 'image/svg+xml'},
        },
      });
      final decoded = decodeInstantJsonFull(
        json,
        pageCount: 1,
        defaultColor: const Color(0xFFFF0000),
        defaultLineWidth: 1.0,
      );
      expect(decoded.stamps, isEmpty);
    });

    test('legacy ink-only JSON with no `attachments` field decodes as before (zero stamps)', () {
      final json = encodeInstantJson([_stroke()]);
      final decoded = decodeInstantJsonFull(
        json,
        pageCount: 1,
        defaultColor: const Color(0xFFFF0000),
        defaultLineWidth: 1.0,
      );
      expect(decoded.strokes, hasLength(1));
      expect(decoded.stamps, isEmpty);
      expect(decoded.attachments, isEmpty);
    });

    test('decoder prefers pdfrx:rotation over rotation when both are present', () {
      final bytes = Uint8List.fromList([1]);
      final hash = sha256.convert(bytes).toString();
      final json = jsonEncode({
        'format': 'https://pspdfkit.com/instant-json/v1',
        'annotations': [
          {
            'v': 1,
            'type': 'pspdfkit/image',
            'id': 'a',
            'pageIndex': 0,
            'bbox': [0, 0, 10, 10],
            'imageAttachmentId': hash,
            'contentType': 'image/svg+xml',
            'rotation': 90,
            'pdfrx:rotation': 47.5,
          },
        ],
        'attachments': {
          hash: {'binary': base64Encode(bytes), 'contentType': 'image/svg+xml'},
        },
      });
      final decoded = decodeInstantJsonFull(
        json,
        pageCount: 1,
        defaultColor: const Color(0xFFFF0000),
        defaultLineWidth: 1.0,
      );
      expect(decoded.stamps.single.rotationDeg, closeTo(47.5, 1e-9));
    });
  });
}
