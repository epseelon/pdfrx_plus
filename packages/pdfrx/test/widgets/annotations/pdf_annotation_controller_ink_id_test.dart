import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_ink_annotation.dart';

void main() {
  group('PdfAnnotationController.commitStroke ink ids', () {
    test('assigns a fresh 24-character hex id to the committed stroke', () {
      final controller = PdfAnnotationController();
      controller.enterMode();
      controller.startStroke(
        pageIndex: 0,
        firstPoint: const Offset(0, 0),
        lineWidth: 1.0,
        strokeColor: const Color(0xFF000000),
        opacity: 1.0,
      );
      controller.appendPoint(const Offset(5, 5));
      controller.commitStroke();

      final id = controller.strokes.single.id;
      expect(id, isNotNull);
      expect(id, matches(RegExp(r'^[0-9a-f]{24}$')));
    });

    test('uses the injected idGenerator seam when provided', () {
      final controller = PdfAnnotationController();
      controller.enterMode();
      controller.startStroke(
        pageIndex: 0,
        firstPoint: const Offset(0, 0),
        lineWidth: 1.0,
        strokeColor: const Color(0xFF000000),
        opacity: 1.0,
      );
      controller.appendPoint(const Offset(5, 5));
      controller.commitStroke(idGenerator: () => 'deadbeefdeadbeefdeadbeef');

      expect(controller.strokes.single.id, 'deadbeefdeadbeefdeadbeef');
    });
  });

  group('PdfAnnotationController eraser split ids', () {
    test('each surviving fragment gets a fresh distinct id, never the parent id', () {
      const parentId = 'parentparentparentparent';
      final controller = PdfAnnotationController();
      controller.setAll([
        PdfInkAnnotation(
          id: parentId,
          pageIndex: 0,
          pointsInPdfSpace: const [Offset(0, 0), Offset(5, 0), Offset(10, 0), Offset(15, 0), Offset(20, 0)],
          lineWidth: 1.0,
          strokeColor: const Color(0xFF000000),
          opacity: 1.0,
          createdAt: DateTime.utc(2024, 1, 1),
          updatedAt: DateTime.utc(2024, 1, 1),
        ),
      ]);
      controller.enterMode();

      // A tight tap at the stroke's midpoint bisects it into two sub-strokes.
      controller.startErase(pageIndex: 0, pdfPoint: const Offset(10, 0), radiusInPdfPoints: 1.0);
      controller.endErase();

      final pieces = controller.strokes;
      expect(pieces, hasLength(2));
      for (final piece in pieces) {
        expect(piece.id, isNotNull);
        expect(piece.id, isNot(parentId));
      }
      // Fresh ids are distinct across fragments (duplicate ids would collapse in
      // the downstream element diff and lose strokes).
      expect(pieces.map((p) => p.id).toSet(), hasLength(pieces.length));
    });
  });
}
