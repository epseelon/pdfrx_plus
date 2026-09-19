import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart' show PdfPage;
import 'package:pdfrx/src/widgets/annotations/annotation_paint_sequence.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_layer.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_ink_annotation.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_stamp_annotation.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_stamp_picture.dart';

PdfInkAnnotation _stroke({
  required PdfInkAnnotationKind kind,
  Color color = const Color(0xFFFFFF00),
  double opacity = 1.0,
  double lineWidth = 12.0,
}) => PdfInkAnnotation(
  pageIndex: 0,
  pointsInPdfSpace: const [Offset(0, 0), Offset(50, 50)],
  lineWidth: lineWidth,
  strokeColor: color,
  opacity: opacity,
  createdAt: DateTime.utc(2024, 1, 1),
  updatedAt: DateTime.utc(2024, 1, 1),
  kind: kind,
);

/// Unix-epoch sentinel: what the decoders stamp onto an entry whose JSON
/// carried no `createdAt`.
final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

PdfInkAnnotation _strokeAt(DateTime createdAt, {String? id, int pageIndex = 0}) => PdfInkAnnotation(
  id: id,
  pageIndex: pageIndex,
  pointsInPdfSpace: const [Offset(0, 0), Offset(50, 50)],
  lineWidth: 2.0,
  strokeColor: const Color(0xFFFF0000),
  opacity: 1.0,
  createdAt: createdAt,
  updatedAt: createdAt,
);

PdfStampAnnotation _stampAt(DateTime createdAt, {String id = 'stamp', String sha = _sha, int pageIndex = 0}) =>
    PdfStampAnnotation(
      id: id,
      pageIndex: pageIndex,
      rectInPdfSpace: const Rect.fromLTWH(10, 10, 24, 24),
      rotationDeg: 0,
      attachmentSha256: sha,
      contentType: 'image/svg+xml',
      createdAt: createdAt,
      updatedAt: createdAt,
    );

const String _sha = 'sha-test';

/// Minimal [PdfPage] stub. The painter reads only [pageNumber], [width]
/// and [height]; anything else surfaces as an error rather than a
/// silently wrong value.
class _FakePdfPage implements PdfPage {
  _FakePdfPage({required this.pageNumber, required this.width, required this.height});

  @override
  final int pageNumber;
  @override
  final double width;
  @override
  final double height;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_FakePdfPage does not implement ${invocation.memberName}');
}

/// Fake decode seam: no real SVG parsing happens in this file.
Future<PdfDecodedStampPicture?> _fakeDecoder(Uint8List bytes, String contentType) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 1, 1), Paint());
  return PdfDecodedStampPicture(picture: recorder.endRecording(), size: const Size(10, 10));
}

/// Paints one page's whole unified sequence, the way the `PdfViewer`
/// page painter does.
class _PageTestPainter extends CustomPainter {
  _PageTestPainter(this.controller);

  final PdfAnnotationController controller;

  @override
  void paint(Canvas canvas, Size size) {
    paintPageAnnotations(
      canvas,
      pageRect: Offset.zero & size,
      page: _FakePdfPage(pageNumber: 1, width: size.width, height: size.height),
      controller: controller,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Loads [strokes] and [stamps] into a controller whose stamp decoder is
/// faked, waits for the pre-warmed decode, then paints the page.
Future<PdfAnnotationController> _pumpPage(
  WidgetTester tester, {
  required List<PdfInkAnnotation> strokes,
  required List<PdfStampAnnotation> stamps,
}) async {
  final controller = PdfAnnotationController()..stampPictureDecoder = _fakeDecoder;
  addTearDown(controller.dispose);
  controller.setAllWithStamps(
    strokes: strokes,
    stamps: stamps,
    attachments: {_sha: PdfStampAttachment(bytes: Uint8List.fromList([1]), contentType: 'image/svg+xml')},
  );
  await tester.pumpWidget(
    Center(
      child: SizedBox(width: 100, height: 100, child: CustomPaint(painter: _PageTestPainter(controller))),
    ),
  );
  if (stamps.isNotEmpty) {
    // The painter can only draw a decoded stamp, so a silently
    // undecoded fake would make every ordering assertion below vacuous.
    await tester.pumpAndSettle();
    expect(controller.stampPictureFor(_sha), isNotNull, reason: 'the fake decode must have landed');
    await tester.pump();
  }
  return controller;
}

/// [PdfInkAnnotation] has no `copyWith`; this rebuilds one with a
/// different `createdAt` so a test can flip which shape is newer.
PdfInkAnnotation _reCreated(PdfInkAnnotation stroke, DateTime createdAt) => PdfInkAnnotation(
  id: stroke.id,
  pageIndex: stroke.pageIndex,
  pointsInPdfSpace: stroke.pointsInPdfSpace,
  lineWidth: stroke.lineWidth,
  strokeColor: stroke.strokeColor,
  opacity: stroke.opacity,
  createdAt: createdAt,
  updatedAt: createdAt,
  creatorName: stroke.creatorName,
  kind: stroke.kind,
);

bool _isDrawPath(Symbol method, List<dynamic> arguments) => method == #drawPath;

bool _isDrawPicture(Symbol method, List<dynamic> arguments) => method == #drawPicture;

/// Minimal painter that delegates to [paintInkStroke] so the `paints`
/// matcher can inspect the emitted `drawPath` call.
class _InkStrokeTestPainter extends CustomPainter {
  _InkStrokeTestPainter(this.stroke);

  final PdfInkAnnotation stroke;

  @override
  void paint(Canvas canvas, Size size) {
    paintInkStroke(canvas, stroke, scaleX: 1.0, scaleY: 1.0);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

Future<void> _pumpStroke(WidgetTester tester, PdfInkAnnotation stroke) => tester.pumpWidget(
  Center(
    child: SizedBox(width: 100, height: 100, child: CustomPaint(painter: _InkStrokeTestPainter(stroke))),
  ),
);

void main() {
  group('paintInkStroke', () {
    testWidgets('highlighter strokes paint with BlendMode.multiply and round caps/joins', (tester) async {
      await _pumpStroke(tester, _stroke(kind: PdfInkAnnotationKind.highlighter, opacity: 0.35));

      // Highlighter strokes multiply-blend so they tint rather than
      // cover the page content beneath, and use rounded caps/joins to
      // match pspdfkit's wide-tipped-marker look.
      expect(
        find.byType(CustomPaint),
        paints..something(
          (method, args) =>
              method == #drawPath &&
              (args[1] as Paint).blendMode == BlendMode.multiply &&
              (args[1] as Paint).strokeCap == StrokeCap.round &&
              (args[1] as Paint).strokeJoin == StrokeJoin.round,
        ),
      );
    });

    testWidgets('pen strokes paint with BlendMode.srcOver and round caps/joins', (tester) async {
      await _pumpStroke(tester, _stroke(kind: PdfInkAnnotationKind.pen));

      // Pen ink is opaque and covers the page content — default
      // source-over compositing, no multiply.
      expect(
        find.byType(CustomPaint),
        paints..something(
          (method, args) =>
              method == #drawPath &&
              (args[1] as Paint).blendMode == BlendMode.srcOver &&
              (args[1] as Paint).strokeCap == StrokeCap.round &&
              (args[1] as Paint).strokeJoin == StrokeJoin.round,
        ),
      );
    });
  });

  group('paintPageAnnotations unified z-order', () {
    testWidgets('a stamp created after a stroke paints over it', (tester) async {
      await _pumpPage(
        tester,
        strokes: [_strokeAt(DateTime.utc(2026, 1, 1), id: 'ink')],
        stamps: [_stampAt(DateTime.utc(2026, 1, 2), id: 'stamp')],
      );

      // The `paints` matcher advances through the recorded calls in
      // order, so this asserts the stroke is drawn BEFORE the stamp:
      // i.e. the stamp covers it.
      expect(find.byType(CustomPaint), paints..something(_isDrawPath)..something(_isDrawPicture));
    });

    testWidgets('a stamp created before a stroke paints under it', (tester) async {
      await _pumpPage(
        tester,
        strokes: [_strokeAt(DateTime.utc(2026, 1, 2), id: 'ink')],
        stamps: [_stampAt(DateTime.utc(2026, 1, 1), id: 'stamp')],
      );

      expect(find.byType(CustomPaint), paints..something(_isDrawPicture)..something(_isDrawPath));
    });

    testWidgets('the in-flight stroke paints last, over an already-committed stamp', (tester) async {
      final controller = await _pumpPage(
        tester,
        strokes: const [],
        stamps: [_stampAt(DateTime.utc(2026, 1, 2), id: 'stamp')],
      );

      controller
        ..startStroke(
          pageIndex: 0,
          firstPoint: const Offset(1, 1),
          lineWidth: 2,
          strokeColor: const Color(0xFF000000),
          opacity: 1.0,
        )
        ..appendPoint(const Offset(40, 40));
      await tester.pump();

      expect(find.byType(CustomPaint), paints..something(_isDrawPicture)..something(_isDrawPath));
    });

    testWidgets('a stamp whose picture has not decoded yet draws nothing and does not blank the page', (
      tester,
    ) async {
      // A decoder that never completes stands in for the window between
      // a stamp appearing and its bytes finishing decoding.
      final controller = PdfAnnotationController()
        ..stampPictureDecoder = (bytes, contentType) => Completer<PdfDecodedStampPicture?>().future;
      addTearDown(controller.dispose);
      controller.setAllWithStamps(
        strokes: [_strokeAt(DateTime.utc(2026, 1, 1), id: 'ink')],
        stamps: [_stampAt(DateTime.utc(2026, 1, 2), id: 'stamp')],
        attachments: {_sha: PdfStampAttachment(bytes: Uint8List.fromList([1]), contentType: 'image/svg+xml')},
      );

      await tester.pumpWidget(
        Center(
          child: SizedBox(width: 100, height: 100, child: CustomPaint(painter: _PageTestPainter(controller))),
        ),
      );

      // The stroke underneath still paints; only the stamp is missing.
      expect(find.byType(CustomPaint), paints..something(_isDrawPath));
      expect(find.byType(CustomPaint), isNot(paints..something(_isDrawPicture)));
    });
  });

  group('paintPageAnnotations failure tolerance', () {
    testWidgets('a stamp whose bytes cannot be decoded draws nothing and leaves the rest of the page painted', (
      tester,
    ) async {
      final controller = PdfAnnotationController()..stampPictureDecoder = (bytes, contentType) async => null;
      addTearDown(controller.dispose);
      controller.setAllWithStamps(
        strokes: [_strokeAt(DateTime.utc(2026, 1, 1), id: 'ink')],
        stamps: [_stampAt(DateTime.utc(2026, 1, 2), id: 'stamp')],
        attachments: {_sha: PdfStampAttachment(bytes: Uint8List.fromList([1]), contentType: 'application/pdf')},
      );

      await tester.pumpWidget(
        Center(
          child: SizedBox(width: 100, height: 100, child: CustomPaint(painter: _PageTestPainter(controller))),
        ),
      );
      // Repainting over an attachment that will never decode must stay
      // quiet rather than throw out of paint().
      await tester.pumpAndSettle();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(CustomPaint), paints..something(_isDrawPath));
      expect(find.byType(CustomPaint), isNot(paints..something(_isDrawPicture)));
    });
  });

  group('buildPageAnnotationPaintSequence total order', () {
    List<String> idsOf(List<PdfAnnotationPaintEntry> entries) => entries
        .map(
          (e) => switch (e) {
            PdfInkPaintEntry() => e.stroke.id ?? 'ink@${e.indexInKind}',
            PdfStampPaintEntry() => e.stamp.id,
          },
        )
        .toList(growable: false);

    test('two legacy epoch-sentinel strokes with null ids keep one reproducible order across repeated builds', () {
      // Both keys that usually separate entries are absent here: the
      // timestamps tie on the sentinel and neither carries an id. Only
      // the kind ordinal and the index within the controller's list are
      // left, and `List.sort` is not stable, so without them the order
      // would be unspecified: a rectangle could cover a stroke on one
      // device and not on another.
      final strokes = [_strokeAt(_epoch), _strokeAt(_epoch), _strokeAt(_epoch)];

      final first = buildPageAnnotationPaintSequence(pageIndex: 0, strokes: strokes, stamps: const []);
      expect(idsOf(first), ['ink@0', 'ink@1', 'ink@2']);

      for (var i = 0; i < 5; i++) {
        final again = buildPageAnnotationPaintSequence(pageIndex: 0, strokes: strokes, stamps: const []);
        expect(idsOf(again), idsOf(first), reason: 'build $i disagreed with the first build');
      }
    });

    test('a stamp with no createdAt sorts with the legacy entries rather than above everything', () {
      // A timestamp-less stamp decodes to the same sentinel as a legacy
      // stroke (requirement 38), so it must tie with them and sit UNDER
      // anything carrying a real timestamp, not float to the top.
      final entries = buildPageAnnotationPaintSequence(
        pageIndex: 0,
        strokes: [_strokeAt(_epoch, id: 'aaa'), _strokeAt(DateTime.utc(2026, 1, 1), id: 'real')],
        stamps: [_stampAt(_epoch, id: 'bbb')],
      );

      expect(idsOf(entries), ['aaa', 'bbb', 'real']);
    });

    test('an entry with a real timestamp always paints over every sentinel entry', () {
      final entries = buildPageAnnotationPaintSequence(
        pageIndex: 0,
        strokes: [_strokeAt(DateTime.utc(2026, 1, 1), id: 'zzz-late-id'), _strokeAt(_epoch, id: 'aaa')],
        stamps: [_stampAt(_epoch, id: 'bbb')],
      );

      expect(idsOf(entries).last, 'zzz-late-id');
    });

    test('entries anchored to another page are not in the sequence', () {
      final entries = buildPageAnnotationPaintSequence(
        pageIndex: 0,
        strokes: [_strokeAt(DateTime.utc(2026, 1, 1), id: 'here'), _strokeAt(DateTime.utc(2026, 1, 1), id: 'there', pageIndex: 1)],
        stamps: [_stampAt(DateTime.utc(2026, 1, 1), id: 'stamp-there', pageIndex: 1)],
      );

      expect(idsOf(entries), ['here']);
    });

    test('a later shape covers an earlier one across creators', () {
      // Ownership scopes what a user may *edit*, never what covers what:
      // the comparator reads no `creatorName`, so a bandmate's stamp
      // still covers my earlier stroke and mine still covers theirs.
      final mineFirst = PdfInkAnnotation(
        id: 'mine',
        pageIndex: 0,
        pointsInPdfSpace: const [Offset(0, 0), Offset(50, 50)],
        lineWidth: 2.0,
        strokeColor: const Color(0xFFFF0000),
        opacity: 1.0,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        creatorName: 'alice',
      );
      final theirsLater = PdfStampAnnotation(
        id: 'theirs',
        pageIndex: 0,
        rectInPdfSpace: const Rect.fromLTWH(10, 10, 24, 24),
        rotationDeg: 0,
        attachmentSha256: _sha,
        contentType: 'image/svg+xml',
        createdAt: DateTime.utc(2026, 1, 2),
        updatedAt: DateTime.utc(2026, 1, 2),
        creatorName: 'bob',
      );

      expect(
        idsOf(buildPageAnnotationPaintSequence(pageIndex: 0, strokes: [mineFirst], stamps: [theirsLater])),
        ['mine', 'theirs'],
      );
      expect(
        idsOf(
          buildPageAnnotationPaintSequence(
            pageIndex: 0,
            strokes: [_reCreated(mineFirst, DateTime.utc(2026, 1, 3))],
            stamps: [theirsLater],
          ),
        ),
        ['theirs', 'mine'],
      );
    });

    test('the kind ordinal separates a stamp and a stroke that tie on timestamp and id', () {
      final entries = buildPageAnnotationPaintSequence(
        pageIndex: 0,
        strokes: [_strokeAt(_epoch, id: 'same')],
        stamps: [_stampAt(_epoch, id: 'same')],
      );

      // ink < rect < stamp.
      expect(entries.map((e) => e.kind).toList(), [PdfAnnotationPaintKind.ink, PdfAnnotationPaintKind.stamp]);
    });
  });
}
