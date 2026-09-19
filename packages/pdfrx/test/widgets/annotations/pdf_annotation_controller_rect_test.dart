import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/instant_json.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_ink_annotation.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_rect_annotation.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_stamp_annotation.dart';
import 'package:pdfrx/src/widgets/annotations/selection_geometry.dart';

PdfRectAnnotation _rect({
  String id = 'rect-1',
  int pageIndex = 0,
  Rect rect = const Rect.fromLTWH(10, 20, 100, 40),
  double rotationDeg = 0.0,
  Color? fillColor = const Color(0xFFFFFFFF),
  String? creatorName = 'alice',
  DateTime? createdAt,
}) => PdfRectAnnotation(
  id: id,
  pageIndex: pageIndex,
  rectInPdfSpace: rect,
  rotationDeg: rotationDeg,
  fillColor: fillColor,
  createdAt: createdAt ?? DateTime.utc(2026, 9, 19, 10),
  updatedAt: createdAt ?? DateTime.utc(2026, 9, 19, 10),
  creatorName: creatorName,
);

PdfStampAnnotation _stamp({String id = 'stamp-1', String? creatorName = 'alice'}) => PdfStampAnnotation(
  id: id,
  pageIndex: 0,
  rectInPdfSpace: const Rect.fromLTWH(200, 200, 24, 24),
  rotationDeg: 0,
  attachmentSha256: 'sha',
  contentType: 'image/svg+xml',
  createdAt: DateTime.utc(2026, 9, 19, 10),
  updatedAt: DateTime.utc(2026, 9, 19, 10),
  creatorName: creatorName,
);

const Size _pageSize = Size(600, 800);

/// A controller in rectangle-tool mode under [creator], the state every
/// creation and manipulation test starts from.
PdfAnnotationController _armed({String? creator = 'alice'}) {
  final controller = PdfAnnotationController();
  controller.enterMode(creatorName: creator, tool: PdfAnnotationTool.rectangle);
  return controller;
}

/// Runs a whole rubber band: press at [from], drag to [to], release.
String? _rubberBand(
  PdfAnnotationController controller, {
  required Offset from,
  required Offset to,
  String id = 'new-rect',
}) {
  controller.startRectDraft(pageIndex: 0, anchorPdfPoint: from, pageSize: _pageSize);
  controller.updateRectDraft(to);
  return controller.commitRectDraft(clock: () => DateTime.utc(2026, 9, 19, 11), idGenerator: () => id);
}

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

  group('PdfAnnotationController rectangle creation', () {
    test('a rubber band commits a rectangle spanning the two corners and auto-selects it', () {
      final controller = _armed();
      addTearDown(controller.dispose);

      final id = _rubberBand(controller, from: const Offset(40, 50), to: const Offset(140, 110));

      expect(id, 'new-rect');
      expect(controller.rects, hasLength(1));
      expect(controller.rects.single.rectInPdfSpace, const Rect.fromLTWH(40, 50, 100, 60));
      expect(controller.rects.single.creatorName, 'alice');
      expect(controller.rects.single.fillColor, const Color(0xFFFFFFFF));
      // Auto-selected, so the gizmo is immediately available.
      expect(controller.selectedRectIdListenable.value, 'new-rect');
    });

    test('dragging up and left of the anchor still yields a positive rectangle', () {
      final controller = _armed();
      addTearDown(controller.dispose);

      _rubberBand(controller, from: const Offset(140, 110), to: const Offset(40, 50));

      expect(controller.rects.single.rectInPdfSpace, const Rect.fromLTWH(40, 50, 100, 60));
    });

    test('the free corner is clamped componentwise into the page; the anchor never moves', () {
      final controller = _armed();
      addTearDown(controller.dispose);

      // Drag far past the page's bottom-right corner.
      _rubberBand(controller, from: const Offset(500, 700), to: const Offset(5000, 5000));

      // Clamped, NOT shifted: the anchored corner stays under the finger.
      expect(controller.rects.single.rectInPdfSpace, const Rect.fromLTWH(500, 700, 100, 100));
    });

    test('the in-flight draft is visible on its page only, and disappears on commit', () {
      final controller = _armed();
      addTearDown(controller.dispose);

      controller.startRectDraft(pageIndex: 0, anchorPdfPoint: const Offset(10, 10), pageSize: _pageSize);
      controller.updateRectDraft(const Offset(60, 70));

      expect(controller.inFlightRectFor(0)?.rectInPdfSpace, const Rect.fromLTWH(10, 10, 50, 60));
      expect(controller.inFlightRectFor(1), isNull);

      controller.commitRectDraft(idGenerator: () => 'x');
      expect(controller.inFlightRectFor(0), isNull);
    });

    test('a pointer-cancel discards the draft and pushes no undo snapshot', () {
      final controller = _armed();
      addTearDown(controller.dispose);

      controller.startRectDraft(pageIndex: 0, anchorPdfPoint: const Offset(10, 10), pageSize: _pageSize);
      controller.updateRectDraft(const Offset(160, 170));
      controller.cancelRectDraft();

      expect(controller.rects, isEmpty);
      expect(controller.inFlightRectFor(0), isNull);
      expect(controller.canUndoListenable.value, isFalse);
    });

    test('a creation pushes exactly one undo snapshot, and undo restores the pre-creation set', () {
      final controller = _armed();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(strokes: [], stamps: [], attachments: {}, rects: [_rect(id: 'pre')]);
      controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.rectangle);

      _rubberBand(controller, from: const Offset(40, 50), to: const Offset(140, 110));
      expect(controller.rects.map((r) => r.id), ['pre', 'new-rect']);

      controller.undo();

      expect(controller.rects.map((r) => r.id), ['pre']);
      // Exactly one: a second undo has nothing left to pop.
      expect(controller.canUndoListenable.value, isFalse);
    });

    test('a sub-minimum drag is discarded rather than clamped, and pushes no undo snapshot', () {
      final controller = _armed();
      addTearDown(controller.dispose);

      // 100 pts wide but only 4 pts tall: under kMinAnnotationSizePts on
      // one axis is enough to discard.
      final id = _rubberBand(controller, from: const Offset(40, 50), to: const Offset(140, 54));

      expect(id, isNull);
      expect(controller.rects, isEmpty);
      expect(controller.canUndoListenable.value, isFalse);
    });

    test('a discarded sub-minimum drag leaves the tap precedence free to run instead of being a no-op', () {
      // The slop that splits tap from drag is 4 screen pixels while the
      // discard threshold is 8 PDF points, so an ordinary fingertip tap
      // on an invisible rectangle often arrives here. If the discard
      // consumed the gesture, selecting a placed cover with a finger
      // would frequently do nothing.
      final controller = _armed();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(strokes: [], stamps: [], attachments: {}, rects: [_rect(id: 'under')]);
      controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.rectangle);

      expect(_rubberBand(controller, from: const Offset(20, 30), to: const Offset(23, 33)), isNull);

      // Nothing was created, nothing was selected, no history was
      // burned: the layer can now run the tap precedence at pointer-up.
      expect(controller.rects.map((r) => r.id), ['under']);
      expect(controller.selectedRectIdListenable.value, isNull);
      expect(controller.canUndoListenable.value, isFalse);
      controller.selectRect('under');
      expect(controller.selectedRectIdListenable.value, 'under');
    });

    test('a rubber band does not rebuild the cached paint sequence on every sample', () {
      // The preview is painted outside the committed sequence, like an
      // in-flight stroke, so a draft must not cost an O(n log n) re-sort
      // per pointer sample. Identity is the memo: a rebuild returns a
      // new list.
      final controller = _armed();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(strokes: [], stamps: [], attachments: {}, rects: [_rect(id: 'pre')]);
      controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.rectangle);
      final cached = controller.paintSequenceForPage(0);

      controller.startRectDraft(pageIndex: 0, anchorPdfPoint: const Offset(40, 50), pageSize: _pageSize);
      for (var x = 60; x < 140; x += 10) {
        controller.updateRectDraft(Offset(x.toDouble(), 110));
      }
      expect(identical(controller.paintSequenceForPage(0), cached), isTrue);

      // Committing is a real content change, so the memo does go then.
      controller.commitRectDraft(idGenerator: () => 'new-rect');
      expect(identical(controller.paintSequenceForPage(0), cached), isFalse);
      expect(controller.paintSequenceForPage(0), hasLength(2));
    });

    test('a resize clamps at the minimum size rather than discarding the rectangle', () {
      // The mirror image of the creation rule: discard-not-clamp applies
      // to the creation gesture only.
      final controller = _armed();
      addTearDown(controller.dispose);
      _rubberBand(controller, from: const Offset(40, 50), to: const Offset(140, 110));

      controller.beginRectDrag(PdfAnnotationHandle.bottomRight);
      controller.applyRectResize(const Offset(-500, -500));
      controller.endRectDrag();

      expect(controller.rects, hasLength(1));
      expect(controller.rects.single.rectInPdfSpace.width, kMinAnnotationSizePts);
      expect(controller.rects.single.rectInPdfSpace.height, kMinAnnotationSizePts);
    });
  });

  group('PdfAnnotationController rectangle manipulation', () {
    test('a body drag translates the rectangle', () {
      final controller = _armed();
      addTearDown(controller.dispose);
      _rubberBand(controller, from: const Offset(40, 50), to: const Offset(140, 110));

      controller.beginRectDrag(PdfAnnotationHandle.body);
      controller.applyRectMove(const Offset(10, -20));
      controller.endRectDrag();

      expect(controller.rects.single.rectInPdfSpace, const Rect.fromLTWH(50, 30, 100, 60));
    });

    test('a corner resize does NOT lock the aspect ratio', () {
      final controller = _armed();
      addTearDown(controller.dispose);
      _rubberBand(controller, from: const Offset(40, 50), to: const Offset(140, 110));

      controller.beginRectDrag(PdfAnnotationHandle.bottomRight);
      controller.applyRectResize(const Offset(100, 0));
      controller.endRectDrag();

      // Width grew, height did not: a locked aspect would have grown both.
      expect(controller.rects.single.rectInPdfSpace, const Rect.fromLTWH(40, 50, 200, 60));
    });

    test('an edge resize moves only its own edge', () {
      final controller = _armed();
      addTearDown(controller.dispose);
      _rubberBand(controller, from: const Offset(40, 50), to: const Offset(140, 110));

      controller.beginRectDrag(PdfAnnotationHandle.left);
      controller.applyRectResize(const Offset(-10, 999));
      controller.endRectDrag();

      expect(controller.rects.single.rectInPdfSpace, const Rect.fromLTWH(30, 50, 110, 60));
    });

    test('rotation is a free angle about the centre with no snapping', () {
      final controller = _armed();
      addTearDown(controller.dispose);
      _rubberBand(controller, from: const Offset(40, 50), to: const Offset(140, 110));

      controller.beginRectDrag(PdfAnnotationHandle.rotation);
      controller.applyRectRotate(37.5);
      controller.endRectDrag();

      expect(controller.rects.single.rotationDeg, 37.5);
      // Rotation turns the shape about its centre; the bbox is unchanged.
      expect(controller.rects.single.rectInPdfSpace, const Rect.fromLTWH(40, 50, 100, 60));
    });

    test('each drag pushes exactly one undo snapshot, however many deltas it carries', () {
      final controller = _armed();
      addTearDown(controller.dispose);
      _rubberBand(controller, from: const Offset(40, 50), to: const Offset(140, 110));
      final afterCreate = controller.rects.single.rectInPdfSpace;

      controller.beginRectDrag(PdfAnnotationHandle.body);
      controller.applyRectMove(const Offset(5, 5));
      controller.applyRectMove(const Offset(10, 10));
      controller.applyRectMove(const Offset(15, 15));
      controller.endRectDrag();

      controller.undo();
      expect(controller.rects.single.rectInPdfSpace, afterCreate);
    });

    test('the gizmo delete button removes the rectangle and clears the selection', () {
      final controller = _armed();
      addTearDown(controller.dispose);
      _rubberBand(controller, from: const Offset(40, 50), to: const Offset(140, 110));

      controller.deleteRect('new-rect');

      expect(controller.rects, isEmpty);
      expect(controller.selectedRectIdListenable.value, isNull);
      controller.undo();
      expect(controller.rects.map((r) => r.id), ['new-rect']);
    });

    test('the eraser leaves rectangles alone', () {
      final controller = _armed();
      addTearDown(controller.dispose);
      _rubberBand(controller, from: const Offset(40, 50), to: const Offset(140, 110));

      controller
        ..startErase(pageIndex: 0, pdfPoint: const Offset(90, 80), radiusInPdfPoints: 40)
        ..continueErase(pageIndex: 0, pdfPoint: const Offset(95, 85), radiusInPdfPoints: 40)
        ..endErase();

      expect(controller.rects, hasLength(1));
    });
  });

  group('PdfAnnotationController rectangle cross-page body drag', () {
    // Two 600x800 pages mounted side by side at 1:1 PDF-to-viewer
    // scale, so the arithmetic below reads directly.
    const leftViewer = Rect.fromLTWH(0, 0, 600, 800);
    const rightViewer = Rect.fromLTWH(600, 0, 600, 800);

    PdfAnnotationController twoPages() {
      final controller = _armed();
      controller.registerPageLayout(pageIndex: 0, viewerRect: leftViewer, pageSize: _pageSize);
      controller.registerPageLayout(pageIndex: 1, viewerRect: rightViewer, pageSize: _pageSize);
      return controller;
    }

    test('reassigns pageIndex when the bbox centre crosses into another page', () {
      final controller = twoPages();
      addTearDown(controller.dispose);
      // Centre at (90, 80).
      _rubberBand(controller, from: const Offset(40, 50), to: const Offset(140, 110));

      controller.beginRectDrag(PdfAnnotationHandle.body);
      controller.applyRectMoveViewer(const Offset(600, 0));
      controller.endRectDrag();

      final rect = controller.rects.single;
      expect(rect.pageIndex, 1);
      // Re-expressed in the destination page's PDF point space, so the
      // rectangle keeps its visible position and size.
      expect(rect.rectInPdfSpace.center.dx, closeTo(90, 1e-6));
      expect(rect.rectInPdfSpace.center.dy, closeTo(80, 1e-6));
      expect(rect.rectInPdfSpace.width, closeTo(100, 1e-6));
    });

    test('keeps pageIndex when the bbox centre stays on the original page', () {
      final controller = twoPages();
      addTearDown(controller.dispose);
      _rubberBand(controller, from: const Offset(40, 50), to: const Offset(140, 110));

      controller.beginRectDrag(PdfAnnotationHandle.body);
      controller.applyRectMoveViewer(const Offset(20, 5));
      controller.endRectDrag();

      expect(controller.rects.single.pageIndex, 0);
      expect(controller.rects.single.rectInPdfSpace, const Rect.fromLTWH(60, 55, 100, 60));
    });

    test('a body move is not clamped away from the page edge mid-drag', () {
      // `_clampRectInsidePage` is deliberately not on this path either:
      // the cross-page handoff needs the rectangle to travel through
      // the gutter rather than being snapped back.
      final controller = twoPages();
      addTearDown(controller.dispose);
      _rubberBand(controller, from: const Offset(40, 50), to: const Offset(140, 110));

      // Centre 90 -> 570, still on page 0, but the right edge lands at
      // 620: past the page's 600pt boundary.
      controller.beginRectDrag(PdfAnnotationHandle.body);
      controller.applyRectMoveViewer(const Offset(480, 0));
      controller.endRectDrag();

      expect(controller.rects.single.pageIndex, 0);
      expect(controller.rects.single.rectInPdfSpace.left, closeTo(520, 1e-6));
      expect(controller.rects.single.rectInPdfSpace.right, closeTo(620, 1e-6));
    });
  });

  group('PdfAnnotationController rectangle ownership', () {
    test('a foreign rectangle cannot be selected, moved, resized, rotated or deleted', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(
        strokes: [],
        stamps: [],
        attachments: {},
        rects: [_rect(id: 'theirs', creatorName: 'bob')],
      );
      controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.rectangle);

      controller.selectRect('theirs');
      expect(controller.selectedRectIdListenable.value, isNull);

      // Every mutator is gated on a selection, so nothing can move it.
      controller.beginRectDrag(PdfAnnotationHandle.body);
      controller.applyRectMove(const Offset(50, 50));
      controller.applyRectResize(const Offset(50, 50));
      controller.applyRectRotate(45);
      controller.endRectDrag();
      controller.deleteRect('theirs');

      expect(controller.rects, hasLength(1));
      expect(controller.rects.single.rectInPdfSpace, const Rect.fromLTWH(10, 20, 100, 40));
      expect(controller.rects.single.rotationDeg, 0.0);
      expect(controller.canUndoListenable.value, isFalse);
    });

    test('hit-test order is reverse unified z-order, skipping foreign rectangles and continuing underneath', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(
        strokes: [],
        stamps: [],
        attachments: {},
        rects: [
          // Distinct creation times: the unified z-order is keyed on
          // `createdAt`, not on list position.
          _rect(id: 'mine-old', creatorName: 'alice', createdAt: DateTime.utc(2026, 9, 19, 10)),
          _rect(id: 'theirs', creatorName: 'bob', createdAt: DateTime.utc(2026, 9, 19, 11)),
          _rect(id: 'mine-new', creatorName: 'alice', createdAt: DateTime.utc(2026, 9, 19, 12)),
        ],
      );
      controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.rectangle);

      // Topmost own rectangle first; the foreign one is skipped rather
      // than ending the walk, so `mine-old` underneath stays reachable.
      expect(controller.selectableRectsForHitTest(0).map((r) => r.id), ['mine-new', 'mine-old']);
    });

    test('rectangles anchored to another page are not hit-test candidates', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(
        strokes: [],
        stamps: [],
        attachments: {},
        rects: [_rect(id: 'here'), _rect(id: 'there', pageIndex: 1)],
      );
      controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.rectangle);

      expect(controller.selectableRectsForHitTest(0).map((r) => r.id), ['here']);
    });
  });

  group('PdfAnnotationController rectangle selection lifecycle', () {
    test('selection is mutually exclusive across kinds', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.setAllWithStamps(
        strokes: [],
        stamps: [],
        attachments: {},
        rects: [_rect()],
      );
      controller.setAllWithStamps(
        strokes: [],
        stamps: [_stamp()],
        attachments: {},
        rects: [_rect()],
      );
      controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.rectangle);

      controller.selectRect('rect-1');
      expect(controller.selectedStampIdListenable.value, isNull);

      controller.selectStamp('stamp-1');
      expect(controller.selectedRectIdListenable.value, isNull);
      expect(controller.selectedStampIdListenable.value, 'stamp-1');

      controller.selectRect('rect-1');
      expect(controller.selectedStampIdListenable.value, isNull);
      expect(controller.selectedRectIdListenable.value, 'rect-1');
    });

    test('changing tool clears both selections', () {
      final controller = _armed();
      addTearDown(controller.dispose);
      _rubberBand(controller, from: const Offset(40, 50), to: const Offset(140, 110));
      expect(controller.selectedRectIdListenable.value, 'new-rect');

      controller.setTool(PdfAnnotationTool.pen);

      expect(controller.selectedRectIdListenable.value, isNull);
      expect(controller.selectedStampIdListenable.value, isNull);
    });

    test('setAllWithStamps clears the rectangle selection, as it does the stamp selection', () {
      // A remote Firestore or P2P refresh must never leave a selection
      // pointing at a replaced shape.
      final controller = _armed();
      addTearDown(controller.dispose);
      _rubberBand(controller, from: const Offset(40, 50), to: const Offset(140, 110));
      expect(controller.selectedRectIdListenable.value, 'new-rect');

      controller.setAllWithStamps(strokes: [], stamps: [], attachments: {}, rects: [_rect()]);

      expect(controller.selectedRectIdListenable.value, isNull);
    });

    test('clear() drops the rectangle selection', () {
      final controller = _armed();
      addTearDown(controller.dispose);
      _rubberBand(controller, from: const Offset(40, 50), to: const Offset(140, 110));

      controller.clear();

      expect(controller.selectedRectIdListenable.value, isNull);
    });

    test('exitMode tears down the rectangle selection and any half-finished drag', () async {
      final controller = _armed();
      addTearDown(controller.dispose);
      _rubberBand(controller, from: const Offset(40, 50), to: const Offset(140, 110));
      controller.beginRectDrag(PdfAnnotationHandle.body);

      await controller.exitMode(onAnnotationsChanged: null);

      expect(controller.selectedRectIdListenable.value, isNull);
      // A drag that outlived the session must not keep mutating.
      controller.applyRectMove(const Offset(500, 500));
      expect(controller.rects.single.rectInPdfSpace, const Rect.fromLTWH(40, 50, 100, 60));
    });

    test('an undo that removes the selected rectangle clears the selection', () {
      final controller = _armed();
      addTearDown(controller.dispose);
      _rubberBand(controller, from: const Offset(40, 50), to: const Offset(140, 110));

      controller.undo();

      expect(controller.rects, isEmpty);
      expect(controller.selectedRectIdListenable.value, isNull);
    });
  });
}
