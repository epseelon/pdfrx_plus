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
import 'package:pdfrx/src/widgets/annotations/pdf_rect_annotation.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_stamp_annotation.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_stamp_picture.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_text_annotation.dart';

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

PdfRectAnnotation _rectAt(
  DateTime createdAt, {
  String id = 'rect',
  int pageIndex = 0,
  Color? fillColor = const Color(0xFFFFFFFF),
  double rotationDeg = 0,
  String? creatorName,
}) => PdfRectAnnotation(
  id: id,
  pageIndex: pageIndex,
  rectInPdfSpace: const Rect.fromLTWH(5, 5, 40, 30),
  rotationDeg: rotationDeg,
  fillColor: fillColor,
  createdAt: createdAt,
  updatedAt: createdAt,
  creatorName: creatorName,
);

PdfTextAnnotation _textAt(DateTime createdAt, {String id = 'text', int pageIndex = 0}) => PdfTextAnnotation(
  id: id,
  pageIndex: pageIndex,
  rectInPdfSpace: const Rect.fromLTWH(5, 5, 40, 30),
  rotationDeg: 0,
  text: 'rit.',
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
  _PageTestPainter(this.controller, {this.pageSize});

  final PdfAnnotationController controller;

  /// The page's size in PDF points. Defaults to the painted size, which
  /// is a zoom of 1.
  final Size? pageSize;

  @override
  void paint(Canvas canvas, Size size) {
    paintPageAnnotations(
      canvas,
      pageRect: Offset.zero & size,
      page: _FakePdfPage(pageNumber: 1, width: (pageSize ?? size).width, height: (pageSize ?? size).height),
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
  List<PdfRectAnnotation> rects = const [],
  List<PdfTextAnnotation> texts = const [],
  PdfAnnotationTool? tool,
  String? creatorName,
}) async {
  final controller = PdfAnnotationController()..stampPictureDecoder = _fakeDecoder;
  addTearDown(controller.dispose);
  controller.setAllWithStamps(
    strokes: strokes,
    stamps: stamps,
    rects: rects,
    texts: texts,
    attachments: {_sha: PdfStampAttachment(bytes: Uint8List.fromList([1]), contentType: 'image/svg+xml')},
  );
  if (tool != null) controller.enterMode(creatorName: creatorName, tool: tool);
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

bool _isDrawRect(Symbol method, List<dynamic> arguments) => method == #drawRect;

bool _isDrawParagraph(Symbol method, List<dynamic> arguments) => method == #drawParagraph;

/// The hint outline is the only stroked path a rectangle emits, so a
/// stroked `drawPath` on a page that carries no ink is the hint.
bool _isStrokedPath(Symbol method, List<dynamic> arguments) =>
    method == #drawPath && (arguments[1] as Paint).style == PaintingStyle.stroke;

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

  group('paintPageAnnotations rectangles in the unified z-order', () {
    testWidgets('a rectangle created after a stroke paints over it', (tester) async {
      await _pumpPage(
        tester,
        strokes: [_strokeAt(DateTime.utc(2026, 1, 1), id: 'ink')],
        stamps: const [],
        rects: [_rectAt(DateTime.utc(2026, 1, 2), id: 'rect')],
      );

      // `paints` advances through the recorded calls in order, so this
      // asserts the stroke is drawn BEFORE the rectangle: it is covered.
      expect(find.byType(CustomPaint), paints..something(_isDrawPath)..something(_isDrawRect));
    });

    testWidgets('a rectangle created before a stroke paints under it', (tester) async {
      await _pumpPage(
        tester,
        strokes: [_strokeAt(DateTime.utc(2026, 1, 2), id: 'ink')],
        stamps: const [],
        rects: [_rectAt(DateTime.utc(2026, 1, 1), id: 'rect')],
      );

      expect(find.byType(CustomPaint), paints..something(_isDrawRect)..something(_isDrawPath));
    });

    testWidgets('a rectangle created after a stamp paints over it', (tester) async {
      await _pumpPage(
        tester,
        strokes: const [],
        stamps: [_stampAt(DateTime.utc(2026, 1, 1), id: 'stamp')],
        rects: [_rectAt(DateTime.utc(2026, 1, 2), id: 'rect')],
      );

      expect(find.byType(CustomPaint), paints..something(_isDrawPicture)..something(_isDrawRect));
    });

    testWidgets('a stamp created after a rectangle paints over it', (tester) async {
      await _pumpPage(
        tester,
        strokes: const [],
        stamps: [_stampAt(DateTime.utc(2026, 1, 2), id: 'stamp')],
        rects: [_rectAt(DateTime.utc(2026, 1, 1), id: 'rect')],
      );

      expect(find.byType(CustomPaint), paints..something(_isDrawRect)..something(_isDrawPicture));
    });

    testWidgets('a rectangle with no fillColor paints nothing', (tester) async {
      // A hand-authored `pspdfkit/shape/rectangle` with no fill decodes
      // and round-trips, but must never be rendered as an opaque block.
      await _pumpPage(
        tester,
        strokes: const [],
        stamps: const [],
        rects: [_rectAt(DateTime.utc(2026, 1, 1), id: 'rect', fillColor: null)],
      );

      expect(find.byType(CustomPaint), isNot(paints..something(_isDrawRect)));
    });
  });

  group('paintPageAnnotations text in the unified z-order', () {
    testWidgets('a text annotation created after a rectangle paints over it', (tester) async {
      await _pumpPage(
        tester,
        strokes: const [],
        stamps: const [],
        rects: [_rectAt(DateTime.utc(2026, 1, 1))],
        texts: [_textAt(DateTime.utc(2026, 1, 2))],
      );

      expect(
        find.byType(CustomPaint),
        paints
          ..something(_isDrawRect)
          ..something(_isDrawParagraph),
      );
    });

    testWidgets('a text annotation created before a rectangle paints under it', (tester) async {
      await _pumpPage(
        tester,
        strokes: const [],
        stamps: const [],
        rects: [_rectAt(DateTime.utc(2026, 1, 2))],
        texts: [_textAt(DateTime.utc(2026, 1, 1))],
      );

      expect(
        find.byType(CustomPaint),
        paints
          ..something(_isDrawParagraph)
          ..something(_isDrawRect),
      );
    });

    testWidgets('a text annotation is painted against strokes and stamps in creation order too', (tester) async {
      await _pumpPage(
        tester,
        strokes: [_strokeAt(DateTime.utc(2026, 1, 1), id: 'ink')],
        stamps: [_stampAt(DateTime.utc(2026, 1, 3))],
        texts: [_textAt(DateTime.utc(2026, 1, 2))],
      );

      expect(
        find.byType(CustomPaint),
        paints
          ..something(_isDrawPath)
          ..something(_isDrawParagraph)
          ..something(_isDrawPicture),
      );
    });

    testWidgets('a text annotation anchored to another page is not painted', (tester) async {
      await _pumpPage(
        tester,
        strokes: const [],
        stamps: const [],
        texts: [_textAt(DateTime.utc(2026, 1, 1), pageIndex: 1)],
      );

      expect(find.byType(CustomPaint), isNot(paints..something(_isDrawParagraph)));
    });

    testWidgets('text is laid out in PDF points and the canvas is scaled to the zoom', (tester) async {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(
        strokes: const [],
        stamps: const [],
        attachments: const {},
        texts: [_textAt(DateTime.utc(2026, 1, 1))],
      );

      // A 50 x 50 pt page shown at 100 x 100: a zoom of 2.
      await tester.pumpWidget(
        Center(
          child: SizedBox(
            width: 100,
            height: 100,
            child: CustomPaint(painter: _PageTestPainter(controller, pageSize: const Size(50, 50))),
          ),
        ),
      );

      // The paragraph lands at the stored top-left IN POINTS, under a
      // canvas scaled by the zoom, so the layout itself never sees it.
      expect(
        find.byType(CustomPaint),
        paints
          ..scale(x: 2.0, y: 2.0)
          ..paragraph(offset: const Offset(5, 5)),
      );
      expect(controller.memoizedTextLayoutCount, 1);
    });
  });

  group('paintPageAnnotations rectangle hint outline', () {
    testWidgets('is drawn on an own rectangle while the rectangle tool is active', (tester) async {
      await _pumpPage(
        tester,
        strokes: const [],
        stamps: const [],
        rects: [_rectAt(DateTime.utc(2026, 1, 1), creatorName: 'alice')],
        tool: PdfAnnotationTool.rectangle,
        creatorName: 'alice',
      );

      // Painted inside the rectangle's own step of the sequence: the
      // fill first, the hint immediately on top of it.
      expect(find.byType(CustomPaint), paints..something(_isDrawRect)..something(_isStrokedPath));
    });

    testWidgets('is absent when annotation mode is off, but the rectangle still renders', (tester) async {
      // Rendering is never gated: a rectangle drawn on a build where the
      // tool is enabled must still cover the score on one where it is
      // not, so turning the flag off never orphans data.
      await _pumpPage(
        tester,
        strokes: const [],
        stamps: const [],
        rects: [_rectAt(DateTime.utc(2026, 1, 1), creatorName: 'alice')],
      );

      expect(find.byType(CustomPaint), paints..something(_isDrawRect));
      expect(find.byType(CustomPaint), isNot(paints..something(_isStrokedPath)));
    });

    testWidgets('is absent under any other tool', (tester) async {
      await _pumpPage(
        tester,
        strokes: const [],
        stamps: const [],
        rects: [_rectAt(DateTime.utc(2026, 1, 1), creatorName: 'alice')],
        tool: PdfAnnotationTool.pen,
        creatorName: 'alice',
      );

      expect(find.byType(CustomPaint), isNot(paints..something(_isStrokedPath)));
    });

    testWidgets('is absent on a foreign-creator rectangle', (tester) async {
      await _pumpPage(
        tester,
        strokes: const [],
        stamps: const [],
        rects: [_rectAt(DateTime.utc(2026, 1, 1), creatorName: 'bob')],
        tool: PdfAnnotationTool.rectangle,
        creatorName: 'alice',
      );

      expect(find.byType(CustomPaint), paints..something(_isDrawRect));
      expect(find.byType(CustomPaint), isNot(paints..something(_isStrokedPath)));
    });
  });

  group('buildPageAnnotationPaintSequence total order', () {
    List<String> idsOf(List<PdfAnnotationPaintEntry> entries) => entries
        .map(
          (e) => switch (e) {
            PdfInkPaintEntry() => e.stroke.id ?? 'ink@${e.indexInKind}',
            PdfStampPaintEntry() => e.stamp.id,
            PdfRectPaintEntry() => e.rect.id,
            PdfTextPaintEntry() => e.text.id,
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

    test('rectangles join the sequence in creation order alongside the other kinds', () {
      final entries = buildPageAnnotationPaintSequence(
        pageIndex: 0,
        strokes: [_strokeAt(DateTime.utc(2026, 1, 1), id: 'ink')],
        stamps: [_stampAt(DateTime.utc(2026, 1, 3), id: 'stamp')],
        rects: [_rectAt(DateTime.utc(2026, 1, 2), id: 'rect')],
      );

      expect(idsOf(entries), ['ink', 'rect', 'stamp']);
    });

    test('a rectangle anchored to another page is not in the sequence', () {
      final entries = buildPageAnnotationPaintSequence(
        pageIndex: 0,
        strokes: const [],
        stamps: const [],
        rects: [
          _rectAt(DateTime.utc(2026, 1, 1), id: 'here'),
          _rectAt(DateTime.utc(2026, 1, 1), id: 'there', pageIndex: 1),
        ],
      );

      expect(idsOf(entries), ['here']);
    });

    test('the kind ordinal separates a stamp, a rectangle and a stroke that tie on timestamp and id', () {
      final entries = buildPageAnnotationPaintSequence(
        pageIndex: 0,
        strokes: [_strokeAt(_epoch, id: 'same')],
        stamps: [_stampAt(_epoch, id: 'same')],
        rects: [_rectAt(_epoch, id: 'same')],
      );

      // ink < rect < stamp.
      expect(entries.map((e) => e.kind).toList(), [
        PdfAnnotationPaintKind.ink,
        PdfAnnotationPaintKind.rect,
        PdfAnnotationPaintKind.stamp,
      ]);
    });

    test('text is the last paint kind, so every ordinal that existed before it is unchanged', () {
      expect(PdfAnnotationPaintKind.values, [
        PdfAnnotationPaintKind.ink,
        PdfAnnotationPaintKind.rect,
        PdfAnnotationPaintKind.stamp,
        PdfAnnotationPaintKind.text,
      ]);
    });

    test('a text annotation created after a stroke, a rectangle or a stamp paints over it', () {
      final early = DateTime.utc(2026, 1, 1);
      final late = DateTime.utc(2026, 1, 2);

      expect(
        idsOf(
          buildPageAnnotationPaintSequence(
            pageIndex: 0,
            strokes: [_strokeAt(early, id: 'ink')],
            stamps: const [],
            texts: [_textAt(late)],
          ),
        ),
        ['ink', 'text'],
      );
      expect(
        idsOf(
          buildPageAnnotationPaintSequence(
            pageIndex: 0,
            strokes: const [],
            stamps: const [],
            rects: [_rectAt(early)],
            texts: [_textAt(late)],
          ),
        ),
        ['rect', 'text'],
      );
      expect(
        idsOf(
          buildPageAnnotationPaintSequence(
            pageIndex: 0,
            strokes: const [],
            stamps: [_stampAt(early)],
            texts: [_textAt(late)],
          ),
        ),
        ['stamp', 'text'],
      );
    });

    test('a text annotation created before a stroke, a rectangle or a stamp paints under it', () {
      final early = DateTime.utc(2026, 1, 1);
      final late = DateTime.utc(2026, 1, 2);

      expect(
        idsOf(
          buildPageAnnotationPaintSequence(
            pageIndex: 0,
            strokes: [_strokeAt(late, id: 'ink')],
            stamps: const [],
            texts: [_textAt(early)],
          ),
        ),
        ['text', 'ink'],
      );
      expect(
        idsOf(
          buildPageAnnotationPaintSequence(
            pageIndex: 0,
            strokes: const [],
            stamps: const [],
            rects: [_rectAt(late)],
            texts: [_textAt(early)],
          ),
        ),
        ['text', 'rect'],
      );
      expect(
        idsOf(
          buildPageAnnotationPaintSequence(
            pageIndex: 0,
            strokes: const [],
            stamps: [_stampAt(late)],
            texts: [_textAt(early)],
          ),
        ),
        ['text', 'stamp'],
      );
    });

    test('a text annotation anchored to another page is not in the sequence', () {
      final entries = buildPageAnnotationPaintSequence(
        pageIndex: 0,
        strokes: const [],
        stamps: const [],
        texts: [
          _textAt(DateTime.utc(2026, 1, 1), id: 'here'),
          _textAt(DateTime.utc(2026, 1, 1), id: 'there', pageIndex: 1),
        ],
      );

      expect(idsOf(entries), ['here']);
    });

    test('the kind ordinal puts text above a stamp that ties with it on timestamp and id', () {
      final entries = buildPageAnnotationPaintSequence(
        pageIndex: 0,
        strokes: [_strokeAt(_epoch, id: 'same')],
        stamps: [_stampAt(_epoch, id: 'same')],
        rects: [_rectAt(_epoch, id: 'same')],
        texts: [_textAt(_epoch, id: 'same')],
      );

      expect(entries.map((e) => e.kind).toList(), [
        PdfAnnotationPaintKind.ink,
        PdfAnnotationPaintKind.rect,
        PdfAnnotationPaintKind.stamp,
        PdfAnnotationPaintKind.text,
      ]);
    });
  });
}
