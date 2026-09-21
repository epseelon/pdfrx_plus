import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/instant_json.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_rect_annotation.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_text_annotation.dart';

PdfTextAnnotation _text({
  String id = 'text-1',
  int pageIndex = 0,
  Rect rectInPdfSpace = const Rect.fromLTWH(10, 20, 120.5, 40.25),
  double rotationDeg = 12.5,
  String text = 'rit.',
  String? fontFamily = 'Academico',
  double fontSize = 18,
  Color color = const Color(0xFF000000),
  bool bold = true,
  bool italic = true,
  bool underline = false,
  PdfTextAnnotationAlign align = PdfTextAnnotationAlign.left,
  bool autoSize = true,
  String? creatorName = 'alice',
}) => PdfTextAnnotation(
  id: id,
  pageIndex: pageIndex,
  rectInPdfSpace: rectInPdfSpace,
  rotationDeg: rotationDeg,
  text: text,
  fontFamily: fontFamily,
  fontSize: fontSize,
  color: color,
  bold: bold,
  italic: italic,
  underline: underline,
  align: align,
  autoSize: autoSize,
  createdAt: DateTime.utc(2026, 9, 21, 10),
  updatedAt: DateTime.utc(2026, 9, 21, 10),
  creatorName: creatorName,
);

Map<String, dynamic> _firstEntry(String json) =>
    ((jsonDecode(json) as Map<String, dynamic>)['annotations'] as List).first as Map<String, dynamic>;

DecodedInstantJson _decode(String json, {int pageCount = 3}) =>
    decodeInstantJsonFull(json, pageCount: pageCount, defaultColor: const Color(0xFF000000), defaultLineWidth: 2.0);

String _wrap(List<Map<String, dynamic>> entries) => jsonEncode({'format': instantJsonFormat, 'annotations': entries});

/// The entry the encoder writes for [_text], as a stored document holds it.
Map<String, dynamic> _textEntry() => _firstEntry(encodeInstantJson(const [], texts: [_text()]));

String _reencode(DecodedInstantJson d) => encodeInstantJson(
  d.strokes,
  stamps: d.stamps,
  rects: d.rects,
  texts: d.texts,
  unknowns: d.unknowns,
  attachments: d.attachments,
);

void main() {
  group('text annotations (pspdfkit/text)', () {
    test('encodes the full pspdfkit/text entry shape', () {
      final entry = _firstEntry(encodeInstantJson(const [], texts: [_text()]));
      expect(entry, {
        'v': 1,
        'type': 'pspdfkit/text',
        'id': 'text-1',
        'pageIndex': 0,
        'bbox': [10.0, 20.0, 120.5, 40.25],
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
        'createdAt': '2026-09-21T10:00:00.000Z',
        'updatedAt': '2026-09-21T10:00:00.000Z',
        'creatorName': 'alice',
      });
      // The key order is the format's, as written in the Spec.
      expect(entry.keys.toList(), [
        'v',
        'type',
        'id',
        'pageIndex',
        'bbox',
        'opacity',
        'text',
        'font',
        'fontSize',
        'fontStyle',
        'fontColor',
        'horizontalAlign',
        'verticalAlign',
        'rotation',
        'pdfrx:rotation',
        'pdfrx:underline',
        'pdfrx:autoSize',
        'createdAt',
        'updatedAt',
        'creatorName',
      ]);
    });

    test('fontStyle holds any of bold and italic, and is an empty array when neither is set', () {
      List<dynamic> style({required bool bold, required bool italic}) =>
          _firstEntry(
                encodeInstantJson(
                  const [],
                  texts: [_text(bold: bold, italic: italic)],
                ),
              )['fontStyle']
              as List<dynamic>;
      expect(style(bold: false, italic: false), isEmpty);
      expect(style(bold: true, italic: false), ['bold']);
      expect(style(bold: false, italic: true), ['italic']);
      expect(style(bold: true, italic: true), ['bold', 'italic']);
    });

    test('writes none of the format fields this tool does not use', () {
      final entry = _firstEntry(encodeInstantJson(const [], texts: [_text()]));
      for (final key in ['backgroundColor', 'borderStyle', 'callout', 'isFitting', 'imageAttachmentId']) {
        expect(entry.containsKey(key), isFalse, reason: key);
      }
      expect(entry['verticalAlign'], 'top');
      expect(entry['opacity'], 1.0);
    });

    test('rotation carries the snapped cardinal, pdfrx:rotation the free angle', () {
      Map<String, dynamic> at(double deg) => _firstEntry(encodeInstantJson(const [], texts: [_text(rotationDeg: deg)]));
      expect(at(12.5)['rotation'], 0);
      expect(at(12.5)['pdfrx:rotation'], 12.5);
      expect(at(88.7)['rotation'], 90);
      expect(at(88.7)['pdfrx:rotation'], 88.7);
      expect(at(200)['rotation'], 180);
      expect(at(-90)['rotation'], 270);
      expect(at(-90)['pdfrx:rotation'], 270.0);
      expect(at(350)['rotation'], 0);
    });

    test('pdfrx:autoSize is true for auto-sized text and false for a text area', () {
      Map<String, dynamic> entry({required bool autoSize}) => _firstEntry(
        encodeInstantJson(
          const [],
          texts: [_text(autoSize: autoSize, underline: !autoSize)],
        ),
      );
      expect(entry(autoSize: true)['pdfrx:autoSize'], isTrue);
      expect(entry(autoSize: true)['pdfrx:underline'], isFalse);
      expect(entry(autoSize: false)['pdfrx:autoSize'], isFalse);
      expect(entry(autoSize: false)['pdfrx:underline'], isTrue);
    });

    test('bbox is rounded to 2 decimals, as ink coordinates are', () {
      final entry = _firstEntry(
        encodeInstantJson(
          const [],
          texts: [_text(rectInPdfSpace: const Rect.fromLTWH(10.123456, 20.987654, 33.335, 7.001))],
        ),
      );
      expect(entry['bbox'], [10.12, 20.99, 33.34, 7.0]);
    });

    test('a whole fontSize is written as an integer, a fractional one as is', () {
      String raw(double size) => encodeInstantJson(const [], texts: [_text(fontSize: size)]);
      expect(raw(18), contains('"fontSize":18,'));
      expect(raw(13.5), contains('"fontSize":13.5,'));
    });

    test('omits font and creatorName when null', () {
      final entry = _firstEntry(encodeInstantJson(const [], texts: [_text(fontFamily: null, creatorName: null)]));
      expect(entry.containsKey('font'), isFalse);
      expect(entry.containsKey('creatorName'), isFalse);
    });

    test('text entries are emitted after rectangles and before unknown entries', () {
      final json = encodeInstantJson(
        const [],
        rects: [
          PdfRectAnnotation(
            id: 'rect-1',
            pageIndex: 0,
            rectInPdfSpace: const Rect.fromLTWH(0, 0, 10, 10),
            rotationDeg: 0,
            createdAt: DateTime.utc(2026, 9, 21, 10),
            updatedAt: DateTime.utc(2026, 9, 21, 10),
          ),
        ],
        texts: [_text()],
        unknowns: [
          {'v': 1, 'type': 'pspdfkit/shape/ellipse', 'id': 'future-1', 'pageIndex': 0},
        ],
      );
      final entries = ((jsonDecode(json) as Map<String, dynamic>)['annotations'] as List).cast<Map<String, dynamic>>();
      expect(entries.map((e) => e['id']), ['rect-1', 'text-1', 'future-1']);
    });
    test('decodes a text entry into DecodedInstantJson.texts', () {
      final decoded = _decode(_wrap([_textEntry()]));
      expect(decoded.unknowns, isEmpty);
      final t = decoded.texts.single;
      expect(t.id, 'text-1');
      expect(t.pageIndex, 0);
      expect(t.rectInPdfSpace, const Rect.fromLTWH(10, 20, 120.5, 40.25));
      expect(t.rotationDeg, 12.5);
      expect(t.text, 'rit.');
      expect(t.fontFamily, 'Academico');
      expect(t.fontSize, 18.0);
      expect(t.color, const Color(0xFF000000));
      expect(t.bold, isTrue);
      expect(t.italic, isTrue);
      expect(t.underline, isFalse);
      expect(t.align, PdfTextAnnotationAlign.left);
      expect(t.autoSize, isTrue);
      expect(t.createdAt, DateTime.utc(2026, 9, 21, 10));
      expect(t.updatedAt, DateTime.utc(2026, 9, 21, 10));
      expect(t.creatorName, 'alice');
      expect(t.preservedJson, isEmpty);
    });
    test('text is accepted as a plain string and as {format: plain, value}', () {
      final decoded = _decode(
        _wrap([
          {..._textEntry(), 'id': 'as-string', 'text': 'breathe'},
          {
            ..._textEntry(),
            'id': 'as-object',
            'text': {'format': 'plain', 'value': 'watch'},
          },
        ]),
      );
      expect({for (final t in decoded.texts) t.id: t.text}, {'as-string': 'breathe', 'as-object': 'watch'});
      expect(decoded.unknowns, isEmpty);
    });

    test('an entry whose text.format is not plain is carried as an unknown entry, not decoded', () {
      final xhtml = {
        ..._textEntry(),
        'text': {'format': 'xhtml', 'value': '<p>rit.</p>'},
      };
      final decoded = _decode(_wrap([xhtml]));
      expect(decoded.texts, isEmpty);
      expect(decoded.unknowns, [xhtml]);
      // Carried means it comes back out exactly as it arrived.
      expect(_firstEntry(_reencode(decoded)), xhtml);
    });

    test('a text entry with no usable text or no id is carried as an unknown entry, never dropped', () {
      final noText = {..._textEntry(), 'id': 'no-text'}..remove('text');
      final badText = {..._textEntry(), 'id': 'bad-text', 'text': 42};
      final badValue = {
        ..._textEntry(),
        'id': 'bad-value',
        'text': {'format': 'plain', 'value': 42},
      };
      final noId = {..._textEntry()}..remove('id');
      final decoded = _decode(_wrap([noText, badText, badValue, noId]));
      expect(decoded.texts, isEmpty);
      expect(decoded.unknowns, [noText, badText, badValue, noId]);
    });
    test('an unknown font is kept as the stored family name', () {
      final entry = {..._textEntry(), 'font': 'Some Future Family'};
      final decoded = _decode(_wrap([entry]));
      expect(decoded.texts.single.fontFamily, 'Some Future Family');
      expect(_firstEntry(_reencode(decoded)), entry);
    });

    test('a positive finite fontSize is kept even when it is not on the tool list', () {
      final decoded = _decode(
        _wrap([
          {..._textEntry(), 'fontSize': 13.5},
        ]),
      );
      expect(decoded.texts.single.fontSize, 13.5);
      expect(_firstEntry(_reencode(decoded))['fontSize'], 13.5);
    });

    test('an unusable fontSize decodes as 18 and the stored value is preserved on re-save', () {
      for (final stored in <Object>['big', 0, -4, true]) {
        final entry = {..._textEntry(), 'fontSize': stored};
        final decoded = _decode(_wrap([entry]));
        expect(decoded.texts.single.fontSize, 18.0, reason: '$stored');
        expect(_firstEntry(_reencode(decoded))['fontSize'], stored, reason: '$stored');
      }
      final missing = {..._textEntry()}..remove('fontSize');
      expect(_decode(_wrap([missing])).texts.single.fontSize, 18.0);
    });

    test('a non-finite number is never preserved: it could not be written back', () {
      // `1e400` is valid JSON text and parses to infinity, which jsonEncode
      // refuses. Preserving it would make every later export throw.
      final raw = _wrap([_textEntry()]).replaceFirst('"fontSize":18,', '"fontSize":1e400,"pdfrx:future":[1e400],');
      final decoded = _decode(raw);
      expect(decoded.texts.single.fontSize, 18.0);
      final entry = _firstEntry(_reencode(decoded));
      expect(entry['fontSize'], 18);
      expect(entry.containsKey('pdfrx:future'), isFalse);
    });

    test('a non-finite bbox is malformed', () {
      final raw = _wrap([_textEntry()]).replaceFirst('"bbox":[10.0,', '"bbox":[1e400,');
      expect(raw, contains('1e400'));
      final decoded = _decode(raw);
      expect(decoded.texts, isEmpty);
    });

    test('an unknown horizontalAlign decodes as left and the stored value is preserved on re-save', () {
      final entry = {..._textEntry(), 'horizontalAlign': 'justify'};
      final decoded = _decode(_wrap([entry]));
      expect(decoded.texts.single.align, PdfTextAnnotationAlign.left);
      expect(_firstEntry(_reencode(decoded)), entry);
    });

    test('center and right alignments decode and round-trip', () {
      for (final align in [PdfTextAnnotationAlign.center, PdfTextAnnotationAlign.right]) {
        final x = encodeInstantJson(const [], texts: [_text(align: align)]);
        expect(_decode(x).texts.single.align, align);
        expect(_reencode(_decode(x)), x);
      }
    });

    test('missing pdfrx:autoSize means text area, missing pdfrx:underline means not underlined', () {
      final entry = {..._textEntry()}
        ..remove('pdfrx:autoSize')
        ..remove('pdfrx:underline');
      final t = _decode(_wrap([entry])).texts.single;
      expect(t.autoSize, isFalse);
      expect(t.underline, isFalse);
    });

    test('rotationDeg reads pdfrx:rotation, then rotation, then 0.0', () {
      final json = _wrap([
        {..._textEntry(), 'id': 'both', 'rotation': 90, 'pdfrx:rotation': 88.7},
        {..._textEntry(), 'id': 'cardinal-only', 'rotation': 270}..remove('pdfrx:rotation'),
        {..._textEntry(), 'id': 'neither'}
          ..remove('pdfrx:rotation')
          ..remove('rotation'),
      ]);
      final byId = {for (final t in _decode(json).texts) t.id: t.rotationDeg};
      expect(byId, {'both': 88.7, 'cardinal-only': 270.0, 'neither': 0.0});
    });

    test('an entry with a malformed bbox is skipped without dropping its siblings', () {
      final json = _wrap([
        {..._textEntry(), 'id': 'good-1'},
        {
          ..._textEntry(),
          'id': 'bad-bbox',
          'bbox': [1, 2, 'x', 4],
        },
        {
          ..._textEntry(),
          'id': 'bad-bbox-short',
          'bbox': [1, 2, 3],
        },
        {..._textEntry(), 'id': 'bad-bbox-type', 'bbox': 'nope'},
        {..._textEntry(), 'id': 'good-2'},
      ]);
      final decoded = _decode(json);
      expect(decoded.texts.map((t) => t.id), ['good-1', 'good-2']);
      expect(decoded.unknowns, isEmpty);
    });

    test('the stored bbox is kept verbatim, and re-emitted unchanged when nothing was edited', () {
      final entry = {
        ..._textEntry(),
        'bbox': [10.123456, 20.987654, 33.335, 7.001],
      };
      final decoded = _decode(_wrap([entry]));
      expect(decoded.texts.single.rectInPdfSpace, const Rect.fromLTWH(10.123456, 20.987654, 33.335, 7.001));
      expect(_firstEntry(_reencode(decoded))['bbox'], [10.123456, 20.987654, 33.335, 7.001]);
    });

    test('a stored text longer than 2,000 characters decodes in full and is never truncated', () {
      final long = List.filled(500, 'molto espressivo\n').join();
      expect(long.length, greaterThan(2000));
      final x = encodeInstantJson(const [], texts: [_text(text: long)]);
      expect(_decode(x).texts.single.text, long);
      expect(_reencode(_decode(x)), x);
    });

    test('keys this build does not model are preserved verbatim across decode and encode', () {
      final entry = {
        ..._textEntry(),
        'v': 2,
        'backgroundColor': '#FFFF00',
        'borderStyle': 'solid',
        'isFitting': true,
        'callout': {
          'start': [1.5, 2],
          'cap': 'openArrow',
        },
        'verticalAlign': 'center',
        'opacity': 0.5,
        'fontStyle': ['bold', 'strikethrough'],
        'fontColor': '#12345678',
        'name': '01J8TEXT',
      };
      final decoded = _decode(_wrap([entry]));
      final t = decoded.texts.single;
      expect(t.bold, isTrue);
      expect(t.italic, isFalse);
      expect(t.color, const Color(0xFF000000));
      expect(_firstEntry(_reencode(decoded)), entry);
    });

    test('the {format, value} form of text is put back as it was stored', () {
      final entry = {
        ..._textEntry(),
        'text': {'format': 'plain', 'value': 'watch'},
      };
      expect(_firstEntry(_reencode(_decode(_wrap([entry])))), entry);
    });

    test('encode(decode(x)) == x for every entry the encoder can produce', () {
      final x = encodeInstantJson(
        const [],
        rects: [
          PdfRectAnnotation(
            id: 'rect-1',
            pageIndex: 0,
            rectInPdfSpace: const Rect.fromLTWH(0, 0, 10, 10),
            rotationDeg: 0,
            createdAt: DateTime.utc(2026, 9, 21, 10),
            updatedAt: DateTime.utc(2026, 9, 21, 10),
          ),
        ],
        texts: [
          _text(id: 't1'),
          _text(id: 't2', text: '2nd time only\nD.S. « à la coda »', bold: false, italic: false, underline: true),
          _text(id: 't3', autoSize: false, align: PdfTextAnnotationAlign.center, rotationDeg: 271.25, pageIndex: 2),
          _text(id: 't4', fontFamily: 'Caveat', fontSize: 64, color: const Color(0xFFFF3B30), italic: false),
          _text(id: 't5', fontFamily: null, creatorName: null, fontSize: 13.5, rotationDeg: 0, text: ''),
          _text(id: 't6', rectInPdfSpace: const Rect.fromLTWH(10.123456, 20.987654, 33.335, 7.001)),
        ],
      );
      final decoded = _decode(x);
      expect(decoded.texts, hasLength(6));
      expect(decoded.unknowns, isEmpty);
      final once = _reencode(decoded);
      expect(once, x);
      expect(_reencode(_decode(once)), once);
    });

    test('a text entry never keeps an attachment alive', () {
      const sha = 'aabbcc';
      final json = jsonEncode({
        'annotations': [
          {..._textEntry(), 'imageAttachmentId': sha},
        ],
        'attachments': {
          sha: {
            'binary': base64Encode(const [1, 2, 3]),
            'contentType': 'image/png',
          },
        },
      });
      final decoded = _decode(json);
      expect(decoded.texts, hasLength(1));
      expect(decoded.attachments, isEmpty);
      final out = jsonDecode(_reencode(decoded)) as Map<String, dynamic>;
      expect(out.containsKey('attachments'), isFalse);
      // The key itself is unmodelled data and still round-trips.
      expect((out['annotations'] as List).single['imageAttachmentId'], sha);
    });

    test('missing timestamps fall back to the Unix epoch sentinel (not now())', () {
      final entry = {..._textEntry()}
        ..remove('createdAt')
        ..remove('updatedAt');
      final t = _decode(_wrap([entry])).texts.single;
      final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      expect(t.createdAt, epoch);
      expect(t.updatedAt, epoch);
    });

    test('the legacy ink-only decodeInstantJson ignores text annotations', () {
      final strokes = decodeInstantJson(
        encodeInstantJson(const [], texts: [_text()]),
        pageCount: 3,
        defaultColor: const Color(0xFF000000),
        defaultLineWidth: 2.0,
      );
      expect(strokes, isEmpty);
    });
    test('copyWith replaces only the supplied fields', () {
      final original = _text();
      final moved = original.copyWith(rectInPdfSpace: const Rect.fromLTWH(1, 2, 3, 4));
      expect(moved.rectInPdfSpace, const Rect.fromLTWH(1, 2, 3, 4));
      expect(moved.id, original.id);
      expect(moved.pageIndex, original.pageIndex);
      expect(moved.rotationDeg, original.rotationDeg);
      expect(moved.text, original.text);
      expect(moved.fontFamily, original.fontFamily);
      expect(moved.fontSize, original.fontSize);
      expect(moved.color, original.color);
      expect(moved.bold, original.bold);
      expect(moved.italic, original.italic);
      expect(moved.underline, original.underline);
      expect(moved.align, original.align);
      expect(moved.autoSize, original.autoSize);
      expect(moved.createdAt, original.createdAt);
      expect(moved.updatedAt, original.updatedAt);
      expect(moved.creatorName, original.creatorName);
    });

    test('editing a field retires the raw value preserved for it, and only that one', () {
      // Every modelled key is stored in a form this build preserves raw, so
      // each would win over the model on encode if it were left in place.
      final stored = {
        ..._textEntry(),
        'bbox': [10.123456, 20.987654, 33.335, 7.001],
        'text': {'format': 'plain', 'value': 'watch'},
        'font': 42,
        'fontSize': 'big',
        'fontStyle': ['bold', 'strikethrough'],
        'fontColor': '#12345678',
        'horizontalAlign': 'justify',
        'rotation': 45,
        'pdfrx:rotation': 'askew',
        'pdfrx:underline': 'yes',
        'pdfrx:autoSize': 'yes',
        'createdAt': '2026-09-21T10:00:00Z',
        'updatedAt': '2026-09-21T10:00:00Z',
        'creatorName': 7,
        'backgroundColor': '#FFFF00',
      };
      final decoded = _decode(_wrap([stored])).texts.single;
      Map<String, dynamic> encode(PdfTextAnnotation t) => _firstEntry(encodeInstantJson(const [], texts: [t]));
      expect(encode(decoded), stored, reason: 'untouched, it goes back as stored');

      final edits = <String, (PdfTextAnnotation, Map<String, Object?>)>{
        'rect': (
          decoded.copyWith(rectInPdfSpace: const Rect.fromLTWH(1, 2, 3, 4)),
          {
            'bbox': [1.0, 2.0, 3.0, 4.0],
          },
        ),
        'rotation': (decoded.copyWith(rotationDeg: 100), {'rotation': 90, 'pdfrx:rotation': 100.0}),
        'text': (decoded.copyWith(text: 'breathe'), {'text': 'breathe'}),
        'fontFamily': (decoded.copyWith(fontFamily: 'Inter'), {'font': 'Inter'}),
        'fontSize': (decoded.copyWith(fontSize: 24), {'fontSize': 24}),
        'color': (decoded.copyWith(color: const Color(0xFFFF3B30)), {'fontColor': '#FF3B30'}),
        'bold': (decoded.copyWith(bold: false), {'fontStyle': <String>[]}),
        'italic': (
          decoded.copyWith(italic: true),
          {
            'fontStyle': ['bold', 'italic'],
          },
        ),
        'underline': (decoded.copyWith(underline: true), {'pdfrx:underline': true}),
        'align': (decoded.copyWith(align: PdfTextAnnotationAlign.right), {'horizontalAlign': 'right'}),
        'autoSize': (decoded.copyWith(autoSize: true), {'pdfrx:autoSize': true}),
        'pageIndex': (decoded.copyWith(pageIndex: 2), {'pageIndex': 2}),
        'updatedAt': (
          decoded.copyWith(updatedAt: DateTime.utc(2026, 9, 22)),
          {'updatedAt': '2026-09-22T00:00:00.000Z'},
        ),
        'createdAt': (
          decoded.copyWith(createdAt: DateTime.utc(2026, 9, 20)),
          {'createdAt': '2026-09-20T00:00:00.000Z'},
        ),
        'creatorName': (decoded.copyWith(creatorName: 'alice'), {'creatorName': 'alice'}),
      };
      for (final MapEntry(key: field, value: (edited, expected)) in edits.entries) {
        expect(encode(edited), {...stored, ...expected}, reason: field);
      }
    });
  });
}
