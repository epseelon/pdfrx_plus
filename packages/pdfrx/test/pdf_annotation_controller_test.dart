import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/instant_json.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_ink_annotation.dart';

PdfInkAnnotation _stroke({
  int pageIndex = 0,
  List<Offset> points = const [Offset(0, 0), Offset(10, 10)],
  String? creatorName,
}) => PdfInkAnnotation(
  pageIndex: pageIndex,
  pointsInPdfSpace: points,
  lineWidth: 1.0,
  strokeColor: const Color(0xFF000000),
  opacity: 1.0,
  createdAt: DateTime.utc(2024, 1, 1),
  updatedAt: DateTime.utc(2024, 1, 1),
  creatorName: creatorName,
);

void main() {
  group('PdfAnnotationController.setAll', () {
    test('replaces existing strokes and notifies listeners', () {
      final controller = PdfAnnotationController();
      var notifications = 0;
      controller.addListener(() => notifications++);

      controller.setAll([_stroke(pageIndex: 0), _stroke(pageIndex: 1)]);

      expect(controller.strokes, hasLength(2));
      expect(controller.strokes.map((s) => s.pageIndex), [0, 1]);
      expect(notifications, 1);

      controller.setAll([_stroke(pageIndex: 2)]);
      expect(controller.strokes, hasLength(1));
      expect(controller.strokes.single.pageIndex, 2);
      expect(notifications, 2);
    });
  });

  group('PdfAnnotationController.clear', () {
    test('empties strokes and notifies once', () {
      final controller = PdfAnnotationController();
      controller.setAll([_stroke(), _stroke()]);

      var notifications = 0;
      controller.addListener(() => notifications++);

      controller.clear();

      expect(controller.strokes, isEmpty);
      expect(notifications, 1);
    });
  });

  group('PdfAnnotationController.enterMode', () {
    test('flips listenable to true; second call is no-op', () {
      final controller = PdfAnnotationController();
      var notifications = 0;
      controller.annotationModeListenable.addListener(() => notifications++);

      controller.enterMode();
      expect(controller.annotationModeListenable.value, isTrue);
      expect(notifications, 1);

      controller.enterMode();
      expect(controller.annotationModeListenable.value, isTrue);
      expect(notifications, 1);
    });
  });

  group('PdfAnnotationController.exitMode', () {
    test('flips listenable to false and awaits onAnnotationsChanged before returning', () async {
      final controller = PdfAnnotationController();
      controller.enterMode();
      var callbackCompleted = false;
      Future<void> onChanged(String json) async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        callbackCompleted = true;
      }

      await controller.exitMode(onAnnotationsChanged: onChanged);

      expect(controller.annotationModeListenable.value, isFalse);
      expect(callbackCompleted, isTrue);
    });

    test('with null callback completes without throwing', () async {
      final controller = PdfAnnotationController();
      controller.enterMode();
      await controller.exitMode(onAnnotationsChanged: null);
      expect(controller.annotationModeListenable.value, isFalse);
    });
  });

  group('PdfAnnotationController stroke lifecycle', () {
    test('startStroke + appendPoint + commitStroke commits and notifies twice', () {
      final controller = PdfAnnotationController();
      var notifications = 0;
      controller.addListener(() => notifications++);

      controller.startStroke(
        pageIndex: 0,
        firstPoint: const Offset(1, 2),
        lineWidth: 3.0,
        strokeColor: const Color(0xFF112233),
        opacity: 1.0,
      );
      controller.appendPoint(const Offset(4, 5));
      controller.commitStroke();

      expect(controller.strokes, hasLength(1));
      final stroke = controller.strokes.single;
      expect(stroke.pageIndex, 0);
      expect(stroke.pointsInPdfSpace, const [Offset(1, 2), Offset(4, 5)]);
      expect(stroke.lineWidth, 3.0);
      expect(stroke.strokeColor, const Color(0xFF112233));
      expect(notifications, 2);
    });

    test('cancelStroke discards in-flight without committing', () {
      final controller = PdfAnnotationController();
      controller.startStroke(
        pageIndex: 0,
        firstPoint: const Offset(1, 1),
        lineWidth: 2.0,
        strokeColor: const Color(0xFFFF0000),
        opacity: 1.0,
      );
      controller.appendPoint(const Offset(2, 2));

      controller.cancelStroke();

      expect(controller.strokes, isEmpty);
      expect(controller.inFlightPageIndex, isNull);
    });

    test('addStroke appends and notifies', () {
      final controller = PdfAnnotationController();
      var notifications = 0;
      controller.addListener(() => notifications++);

      controller.addStroke(_stroke(pageIndex: 1));

      expect(controller.strokes, hasLength(1));
      expect(controller.strokes.single.pageIndex, 1);
      expect(notifications, 1);
    });
  });

  group('PdfAnnotationController.exportJson', () {
    test('matches encodeInstantJson(strokes)', () {
      final controller = PdfAnnotationController();
      controller.setAll([_stroke(pageIndex: 0)]);
      expect(controller.exportJson(), encodeInstantJson(controller.strokes));
    });
  });

  group('PdfAnnotationController creator tagging', () {
    test('committed strokes inherit creatorName from the active session', () {
      final controller = PdfAnnotationController();
      controller.enterMode(creatorName: 'alice');
      controller.startStroke(
        pageIndex: 0,
        firstPoint: const Offset(1, 1),
        lineWidth: 1.0,
        strokeColor: const Color(0xFF000000),
        opacity: 1.0,
      );
      controller.appendPoint(const Offset(2, 2));
      controller.commitStroke();

      expect(controller.strokes.single.creatorName, 'alice');
    });

    test('without creatorName, committed strokes have null creatorName (legacy path)', () {
      final controller = PdfAnnotationController();
      controller.enterMode();
      controller.startStroke(
        pageIndex: 0,
        firstPoint: const Offset(1, 1),
        lineWidth: 1.0,
        strokeColor: const Color(0xFF000000),
        opacity: 1.0,
      );
      controller.appendPoint(const Offset(2, 2));
      controller.commitStroke();

      expect(controller.strokes.single.creatorName, isNull);
    });

    test('exitMode clears the active creator so the next session starts fresh', () async {
      final controller = PdfAnnotationController();
      controller.enterMode(creatorName: 'alice');
      await controller.exitMode(onAnnotationsChanged: null);
      expect(controller.currentCreator, isNull);

      controller.enterMode();
      controller.startStroke(
        pageIndex: 0,
        firstPoint: const Offset(1, 1),
        lineWidth: 1.0,
        strokeColor: const Color(0xFF000000),
        opacity: 1.0,
      );
      controller.appendPoint(const Offset(2, 2));
      controller.commitStroke();
      expect(controller.strokes.single.creatorName, isNull);
    });
  });

  group('PdfAnnotationController.setTool', () {
    test('enterMode without override preserves the active tool', () async {
      final controller = PdfAnnotationController();
      controller.enterMode();
      controller.setTool(PdfAnnotationTool.eraser);
      expect(controller.currentToolListenable.value, PdfAnnotationTool.eraser);

      // Simulate exit + re-enter without a tool override — the previously
      // selected eraser is remembered.
      await controller.exitMode(onAnnotationsChanged: null);
      controller.enterMode();
      expect(controller.currentToolListenable.value, PdfAnnotationTool.eraser);
    });

    test('enterMode with `tool:` override switches the active tool', () async {
      final controller = PdfAnnotationController();
      controller.enterMode();
      controller.setTool(PdfAnnotationTool.eraser);

      await controller.exitMode(onAnnotationsChanged: null);
      controller.enterMode(tool: PdfAnnotationTool.pen);
      expect(controller.currentToolListenable.value, PdfAnnotationTool.pen);
    });

    test('flips the listenable; idempotent re-set is a no-op', () {
      final controller = PdfAnnotationController();
      var notifications = 0;
      controller.currentToolListenable.addListener(() => notifications++);

      controller.setTool(PdfAnnotationTool.eraser);
      expect(controller.currentToolListenable.value, PdfAnnotationTool.eraser);
      expect(notifications, 1);

      controller.setTool(PdfAnnotationTool.eraser);
      expect(notifications, 1);

      controller.setTool(PdfAnnotationTool.pen);
      expect(notifications, 2);
    });
  });

  group('PdfAnnotationController stroke style state', () {
    test('defaults match the documented values', () {
      final controller = PdfAnnotationController();
      expect(controller.strokeColor, const Color(0xFFFF3B30));
      expect(controller.strokeWidth, 2.0);
      expect(controller.eraserRadius, 10.0);
    });

    test('setStrokeColor / setStrokeWidth / setEraserRadius update listenables; re-set is no-op', () {
      final controller = PdfAnnotationController();

      var colorBumps = 0;
      var widthBumps = 0;
      var radiusBumps = 0;
      controller.strokeColorListenable.addListener(() => colorBumps++);
      controller.strokeWidthListenable.addListener(() => widthBumps++);
      controller.eraserRadiusListenable.addListener(() => radiusBumps++);

      controller.setStrokeColor(const Color(0xFF00FF00));
      controller.setStrokeColor(const Color(0xFF00FF00));
      controller.setStrokeWidth(5.0);
      controller.setStrokeWidth(5.0);
      controller.setEraserRadius(20.0);
      controller.setEraserRadius(20.0);

      expect(colorBumps, 1);
      expect(widthBumps, 1);
      expect(radiusBumps, 1);
      expect(controller.strokeColor, const Color(0xFF00FF00));
      expect(controller.strokeWidth, 5.0);
      expect(controller.eraserRadius, 20.0);
    });

    test('committed strokes inherit the controller\'s current strokeColor / strokeWidth', () {
      // The layer reads strokeColor/strokeWidth from the controller and
      // forwards them to startStroke. We exercise startStroke directly
      // here using the same values.
      final controller = PdfAnnotationController();
      controller.setStrokeColor(const Color(0xFF0000FF));
      controller.setStrokeWidth(4.0);
      controller.enterMode();

      controller.startStroke(
        pageIndex: 0,
        firstPoint: const Offset(0, 0),
        lineWidth: controller.strokeWidth,
        strokeColor: controller.strokeColor,
        opacity: 1.0,
      );
      controller.appendPoint(const Offset(10, 10));
      controller.commitStroke();

      expect(controller.strokes.single.strokeColor, const Color(0xFF0000FF));
      expect(controller.strokes.single.lineWidth, 4.0);
    });

    test('enterMode applies non-null overrides and persists them after exitMode', () async {
      final controller = PdfAnnotationController();
      controller.enterMode(strokeColor: const Color(0xFF34C759), strokeWidth: 3.0, eraserRadius: 25.0);

      expect(controller.strokeColor, const Color(0xFF34C759));
      expect(controller.strokeWidth, 3.0);
      expect(controller.eraserRadius, 25.0);

      await controller.exitMode(onAnnotationsChanged: null);

      // State outlives the session.
      expect(controller.strokeColor, const Color(0xFF34C759));
      expect(controller.strokeWidth, 3.0);
      expect(controller.eraserRadius, 25.0);

      // Re-entering without overrides keeps the values in place.
      controller.enterMode();
      expect(controller.strokeColor, const Color(0xFF34C759));
      expect(controller.strokeWidth, 3.0);
      expect(controller.eraserRadius, 25.0);
    });

    test('enterMode with null overrides leaves prior style untouched', () async {
      final controller = PdfAnnotationController();
      controller.setStrokeColor(const Color(0xFFAF52DE));
      controller.setStrokeWidth(8.0);

      controller.enterMode();

      expect(controller.strokeColor, const Color(0xFFAF52DE));
      expect(controller.strokeWidth, 8.0);
    });
  });

  group('PdfAnnotationController eraser (partial-stroke)', () {
    const radius = 5.0;

    void tap(PdfAnnotationController c, int pageIndex, Offset p, {double r = radius}) {
      c.startErase(pageIndex: pageIndex, pdfPoint: p, radiusInPdfPoints: r);
      c.endErase();
    }

    test('a tap on a single-segment stroke removes the whole stroke', () {
      final controller = PdfAnnotationController();
      controller.setAll([
        _stroke(pageIndex: 0, points: const [Offset(0, 0), Offset(10, 0)]),
      ]);
      controller.enterMode();

      tap(controller, 0, const Offset(5, 0));

      expect(controller.strokes, isEmpty);
    });

    test('a tap on the middle segment of a multi-segment stroke bisects it into two sub-strokes', () {
      final controller = PdfAnnotationController();
      controller.setAll([
        _stroke(
          pageIndex: 0,
          points: const [Offset(0, 0), Offset(5, 0), Offset(10, 0), Offset(15, 0), Offset(20, 0)],
          creatorName: 'alice',
        ),
      ]);
      controller.enterMode(creatorName: 'alice');

      // Tap centered on segment [(10,0)→(15,0)] with a tight radius so
      // only that segment is touched.
      tap(controller, 0, const Offset(12.5, 0), r: 1.0);

      expect(controller.strokes, hasLength(2));
      expect(controller.strokes[0].pointsInPdfSpace, const [Offset(0, 0), Offset(5, 0), Offset(10, 0)]);
      expect(controller.strokes[1].pointsInPdfSpace, const [Offset(15, 0), Offset(20, 0)]);
      // Sub-strokes inherit ownership and stroke style from the parent.
      expect(controller.strokes.every((s) => s.creatorName == 'alice'), isTrue);
    });

    test('foreign-creator strokes survive the eraser', () {
      final controller = PdfAnnotationController();
      controller.setAll([
        _stroke(pageIndex: 0, points: const [Offset(0, 0), Offset(10, 0)], creatorName: 'alice'),
        _stroke(pageIndex: 0, points: const [Offset(0, 50), Offset(10, 50)], creatorName: 'bob'),
      ]);
      controller.enterMode(creatorName: 'alice');

      tap(controller, 0, const Offset(5, 50)); // bob's stroke
      expect(controller.strokes, hasLength(2));

      tap(controller, 0, const Offset(5, 0)); // alice's stroke
      expect(controller.strokes, hasLength(1));
      expect(controller.strokes.single.creatorName, 'bob');
    });

    test('does not match across creator/null boundary', () {
      final controller = PdfAnnotationController();
      controller.setAll([
        _stroke(pageIndex: 0, points: const [Offset(0, 0), Offset(10, 0)]),
      ]);
      controller.enterMode(creatorName: 'alice');

      tap(controller, 0, const Offset(5, 0));

      expect(controller.strokes, hasLength(1));
    });

    test('a tap far from any stroke is a no-op (no notification)', () {
      final controller = PdfAnnotationController();
      controller.setAll([
        _stroke(pageIndex: 0, points: const [Offset(0, 0), Offset(10, 0)]),
      ]);
      controller.enterMode();

      var notifications = 0;
      controller.addListener(() => notifications++);

      tap(controller, 0, const Offset(500, 500));

      expect(controller.strokes, hasLength(1));
      expect(notifications, 0);
    });

    test('respects pageIndex', () {
      final controller = PdfAnnotationController();
      controller.setAll([
        _stroke(pageIndex: 1, points: const [Offset(0, 0), Offset(10, 0)]),
      ]);
      controller.enterMode();

      tap(controller, 0, const Offset(5, 0));

      expect(controller.strokes, hasLength(1));
    });

    test('a vertical eraser drag that crosses a horizontal stroke cuts it', () {
      // Pen: horizontal (0,0) → (10,0) → (20,0). Eraser drags vertically
      // across x=10 with a tight radius — relies on segment-segment
      // intersection rather than radius proximity.
      final controller = PdfAnnotationController();
      controller.setAll([
        _stroke(pageIndex: 0, points: const [Offset(0, 0), Offset(10, 0), Offset(20, 0)]),
      ]);
      controller.enterMode();

      controller.startErase(pageIndex: 0, pdfPoint: const Offset(10, -5), radiusInPdfPoints: 0.1);
      controller.continueErase(pageIndex: 0, pdfPoint: const Offset(10, 5), radiusInPdfPoints: 0.1);
      controller.endErase();

      // Both pen segments share vertex (10,0), and both are crossed by
      // the eraser line, so both are removed.
      expect(controller.strokes, isEmpty);
    });

    test('an eraser drag tangent to a single segment only cuts that segment', () {
      // Pen has a clear "middle segment" from (10,0) to (15,0). A short
      // eraser drag inside that segment only should leave the outer
      // segments intact.
      final controller = PdfAnnotationController();
      controller.setAll([
        _stroke(pageIndex: 0, points: const [Offset(0, 0), Offset(5, 0), Offset(10, 0), Offset(15, 0), Offset(20, 0)]),
      ]);
      controller.enterMode();

      controller.startErase(pageIndex: 0, pdfPoint: const Offset(11, 0), radiusInPdfPoints: 0.1);
      controller.continueErase(pageIndex: 0, pdfPoint: const Offset(14, 0), radiusInPdfPoints: 0.1);
      controller.endErase();

      expect(controller.strokes, hasLength(2));
      expect(controller.strokes[0].pointsInPdfSpace, const [Offset(0, 0), Offset(5, 0), Offset(10, 0)]);
      expect(controller.strokes[1].pointsInPdfSpace, const [Offset(15, 0), Offset(20, 0)]);
    });

    test('a page jump mid-drag does not draw a stroke-cutting cross-page line', () {
      // Two strokes, one per page. The drag samples land first on page 1
      // (far from the page-1 stroke) then page 0 (on the page-0 stroke).
      // We must not interpret the cross-page jump as a single eraser
      // segment that cuts page-0 content from a page-1 starting point.
      final controller = PdfAnnotationController();
      controller.setAll([
        _stroke(pageIndex: 0, points: const [Offset(0, 0), Offset(10, 0)]),
        _stroke(pageIndex: 1, points: const [Offset(0, 0), Offset(10, 0)]),
      ]);
      controller.enterMode();

      controller.startErase(pageIndex: 1, pdfPoint: const Offset(50, 50), radiusInPdfPoints: 1.0);
      controller.continueErase(pageIndex: 0, pdfPoint: const Offset(5, 0), radiusInPdfPoints: 5.0);
      controller.endErase();

      expect(controller.strokes.where((s) => s.pageIndex == 1), hasLength(1));
      expect(controller.strokes.where((s) => s.pageIndex == 0), isEmpty);
    });
  });

  group('PdfAnnotationController.exitMode export filter', () {
    test('with a creatorName, the callback receives only that user\'s strokes', () async {
      final controller = PdfAnnotationController();
      controller.setAll([
        _stroke(pageIndex: 0, points: const [Offset(0, 0), Offset(10, 10)], creatorName: 'alice'),
        _stroke(pageIndex: 0, points: const [Offset(20, 20), Offset(30, 30)], creatorName: 'bob'),
        _stroke(pageIndex: 0, points: const [Offset(40, 40), Offset(50, 50)]),
      ]);

      controller.enterMode(creatorName: 'alice');
      String? captured;
      await controller.exitMode(onAnnotationsChanged: (json) async => captured = json);

      final decoded = jsonDecode(captured!) as Map<String, dynamic>;
      final entries = (decoded['annotations'] as List).cast<Map<String, dynamic>>();
      expect(entries, hasLength(1));
      expect(entries.single['creatorName'], 'alice');
    });

    test('without a creatorName, the callback receives every stroke (today\'s contract)', () async {
      final controller = PdfAnnotationController();
      controller.setAll([_stroke(pageIndex: 0, creatorName: 'alice'), _stroke(pageIndex: 0)]);

      controller.enterMode();
      String? captured;
      await controller.exitMode(onAnnotationsChanged: (json) async => captured = json);

      final decoded = jsonDecode(captured!) as Map<String, dynamic>;
      final entries = decoded['annotations'] as List;
      expect(entries, hasLength(2));
    });
  });
}
