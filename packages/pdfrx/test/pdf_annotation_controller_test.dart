import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/instant_json.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_ink_annotation.dart';

PdfInkAnnotation _stroke({int pageIndex = 0}) => PdfInkAnnotation(
  pageIndex: pageIndex,
  pointsInPdfSpace: const [Offset(0, 0), Offset(10, 10)],
  lineWidth: 1.0,
  strokeColor: const Color(0xFF000000),
  opacity: 1.0,
  createdAt: DateTime.utc(2024, 1, 1),
  updatedAt: DateTime.utc(2024, 1, 1),
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
}
