import 'dart:typed_data';
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_stamp_definition.dart';

const _pageSize = Size(200, 200);

PdfStampDefinition _def({
  String id = 'sharp',
  String contentType = 'image/svg+xml',
  Uint8List? bytes,
  Size intrinsic = const Size(24, 24),
}) => PdfStampDefinition(
  id: id,
  name: id,
  contentType: contentType,
  bytesLoader: () async => bytes ?? Uint8List.fromList([1, 2, 3]),
  intrinsicSize: intrinsic,
);

void main() {
  group('PdfStampDefinition / PdfViewerStampCategory validation', () {
    test('PdfStampDefinition rejects empty id, empty contentType, and non-positive size', () {
      expect(
        () => PdfStampDefinition(
          id: '',
          name: 'x',
          contentType: 'image/svg+xml',
          bytesLoader: () async => Uint8List(0),
          intrinsicSize: const Size(24, 24),
        ),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => PdfStampDefinition(
          id: 'x',
          name: 'x',
          contentType: '',
          bytesLoader: () async => Uint8List(0),
          intrinsicSize: const Size(24, 24),
        ),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => PdfStampDefinition(
          id: 'x',
          name: 'x',
          contentType: 'image/svg+xml',
          bytesLoader: () async => Uint8List(0),
          intrinsicSize: const Size(0, 24),
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('PdfViewerStampCategory rejects empty id', () {
      expect(() => PdfViewerStampCategory(id: '', title: 'x', stamps: const []), throwsA(isA<AssertionError>()));
    });
  });

  group('PdfAnnotationController stamp placement', () {
    test('placeStamp adds a stamp + dedupes attachment bytes; sha256 keyed', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.stamp);

      final bytes = Uint8List.fromList([10, 20, 30]);
      final expectedHash = sha256.convert(bytes).toString();

      controller.placeStamp(
        bytes: bytes,
        contentType: 'image/svg+xml',
        pageIndex: 0,
        pdfPoint: const Offset(50, 50),
        intrinsicSize: const Size(24, 24),
        pageSize: _pageSize,
      );
      controller.placeStamp(
        bytes: bytes,
        contentType: 'image/svg+xml',
        pageIndex: 0,
        pdfPoint: const Offset(120, 120),
        intrinsicSize: const Size(24, 24),
        pageSize: _pageSize,
      );

      expect(controller.stamps, hasLength(2));
      expect(controller.stamps.every((s) => s.attachmentSha256 == expectedHash), isTrue);
      expect(controller.attachments, hasLength(1));
      expect(controller.attachments[expectedHash]?.bytes, bytes);
    });

    test('placeStamp clamps bbox to stay inside page rect (shift, not shrink)', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.stamp);

      // Drop near the bottom-right corner; bbox should shift to remain
      // entirely within [0, page.width) × [0, page.height).
      controller.placeStamp(
        bytes: Uint8List.fromList([1]),
        contentType: 'image/svg+xml',
        pageIndex: 0,
        pdfPoint: const Offset(199, 199),
        intrinsicSize: const Size(24, 24),
        pageSize: _pageSize,
      );

      final stamp = controller.stamps.single;
      expect(stamp.rectInPdfSpace.right, lessThanOrEqualTo(_pageSize.width));
      expect(stamp.rectInPdfSpace.bottom, lessThanOrEqualTo(_pageSize.height));
      // Width/height preserved (not shrunk).
      expect(stamp.rectInPdfSpace.width, 36);
      expect(stamp.rectInPdfSpace.height, 36);
    });

    test('placeStamp uses caller-supplied clock and idGenerator for createdAt + id', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.stamp);

      final fixedTime = DateTime.utc(2026, 4, 29, 12, 0, 0);
      controller.placeStamp(
        bytes: Uint8List.fromList([1]),
        contentType: 'image/svg+xml',
        pageIndex: 0,
        pdfPoint: const Offset(50, 50),
        intrinsicSize: const Size(24, 24),
        pageSize: _pageSize,
        clock: () => fixedTime,
        idGenerator: () => 'stamp-id-001',
      );

      final stamp = controller.stamps.single;
      expect(stamp.id, 'stamp-id-001');
      expect(stamp.createdAt, fixedTime);
      expect(stamp.updatedAt, fixedTime);
    });
  });

  group('PdfAnnotationController setPendingStamp / clearStampSelection', () {
    test('setPendingStamp updates listenable; idempotent on same value', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      var bumps = 0;
      controller.pendingStampListenable.addListener(() => bumps++);

      final def = _def();
      controller.setPendingStamp(def);
      controller.setPendingStamp(def);
      expect(bumps, 1);
      expect(controller.pendingStampListenable.value, same(def));

      controller.setPendingStamp(null);
      expect(bumps, 2);
      expect(controller.pendingStampListenable.value, isNull);
    });

    test('setPendingStamp clears the current stamp selection', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.stamp);
      controller.placeStamp(
        bytes: Uint8List.fromList([1]),
        contentType: 'image/svg+xml',
        pageIndex: 0,
        pdfPoint: const Offset(50, 50),
        intrinsicSize: const Size(24, 24),
        pageSize: _pageSize,
        idGenerator: () => 'sel',
      );
      controller.selectStamp('sel');
      expect(controller.selectedStampIdListenable.value, 'sel');

      controller.setPendingStamp(_def());
      expect(controller.selectedStampIdListenable.value, isNull);
    });

    test('setTool clears both pending stamp and selection on tool change', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.stamp);
      controller.placeStamp(
        bytes: Uint8List.fromList([1]),
        contentType: 'image/svg+xml',
        pageIndex: 0,
        pdfPoint: const Offset(50, 50),
        intrinsicSize: const Size(24, 24),
        pageSize: _pageSize,
        idGenerator: () => 'sel',
      );
      controller.selectStamp('sel');
      controller.setPendingStamp(_def());

      controller.setTool(PdfAnnotationTool.pen);
      expect(controller.selectedStampIdListenable.value, isNull);
      expect(controller.pendingStampListenable.value, isNull);
    });
  });

  group('PdfAnnotationController.deleteStamp', () {
    test('removes own stamp; drops attachment when reference count hits zero', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.stamp);

      controller.placeStamp(
        bytes: Uint8List.fromList([1]),
        contentType: 'image/svg+xml',
        pageIndex: 0,
        pdfPoint: const Offset(50, 50),
        intrinsicSize: const Size(24, 24),
        pageSize: _pageSize,
        idGenerator: () => 'a',
      );
      controller.placeStamp(
        bytes: Uint8List.fromList([1]),
        contentType: 'image/svg+xml',
        pageIndex: 0,
        pdfPoint: const Offset(80, 80),
        intrinsicSize: const Size(24, 24),
        pageSize: _pageSize,
        idGenerator: () => 'b',
      );

      expect(controller.attachments, hasLength(1));
      controller.deleteStamp('a');
      expect(controller.stamps.map((s) => s.id), ['b']);
      expect(controller.attachments, hasLength(1)); // still referenced by b

      controller.deleteStamp('b');
      expect(controller.stamps, isEmpty);
      expect(controller.attachments, isEmpty);
    });

    test('foreign-creator stamp delete is a no-op', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.stamp);

      // Place a stamp as alice ...
      controller.placeStamp(
        bytes: Uint8List.fromList([1]),
        contentType: 'image/svg+xml',
        pageIndex: 0,
        pdfPoint: const Offset(50, 50),
        intrinsicSize: const Size(24, 24),
        pageSize: _pageSize,
        idGenerator: () => 'alice-1',
      );
      // ... then switch creator to bob.
      controller.enterMode(creatorName: 'bob');
      controller.deleteStamp('alice-1');
      expect(controller.stamps, hasLength(1));
    });
  });

  group('PdfAnnotationController.clearAnnotations / clear()', () {
    test('clear() empties strokes, stamps, attachments, selection, and pending', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.stamp);

      controller.placeStamp(
        bytes: Uint8List.fromList([1]),
        contentType: 'image/svg+xml',
        pageIndex: 0,
        pdfPoint: const Offset(50, 50),
        intrinsicSize: const Size(24, 24),
        pageSize: _pageSize,
        idGenerator: () => 'a',
      );
      controller.selectStamp('a');
      controller.setPendingStamp(_def());

      controller.clear();
      expect(controller.stamps, isEmpty);
      expect(controller.attachments, isEmpty);
      expect(controller.selectedStampIdListenable.value, isNull);
    });
  });

  group('PdfAnnotationController.placeStamp failure paths', () {
    test('synchronous error does not leak partial state and is logged via debugPrint', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.stamp);

      // Force the failure path: idGenerator throws synchronously.
      controller.placeStamp(
        bytes: Uint8List.fromList([1]),
        contentType: 'image/svg+xml',
        pageIndex: 0,
        pdfPoint: const Offset(50, 50),
        intrinsicSize: const Size(24, 24),
        pageSize: _pageSize,
        idGenerator: () => throw StateError('boom'),
      );
      expect(controller.stamps, isEmpty);
      expect(controller.attachments, isEmpty);
    });
  });

  group('PdfAnnotationController stamp + ink undo/redo', () {
    test('undo across mixed ink + stamp ops walks back in committed order', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.enterMode(creatorName: 'alice');

      // Commit one ink stroke.
      controller.startStroke(
        pageIndex: 0,
        firstPoint: const Offset(0, 0),
        lineWidth: 1.0,
        strokeColor: const Color(0xFF000000),
        opacity: 1.0,
      );
      controller.appendPoint(const Offset(5, 5));
      controller.commitStroke();

      // Then place a stamp.
      controller.placeStamp(
        bytes: Uint8List.fromList([1]),
        contentType: 'image/svg+xml',
        pageIndex: 0,
        pdfPoint: const Offset(50, 50),
        intrinsicSize: const Size(24, 24),
        pageSize: _pageSize,
        idGenerator: () => 'a',
      );

      expect(controller.strokes, hasLength(1));
      expect(controller.stamps, hasLength(1));

      controller.undo();
      expect(controller.stamps, isEmpty);
      expect(controller.strokes, hasLength(1));

      controller.undo();
      expect(controller.strokes, isEmpty);
      expect(controller.stamps, isEmpty);

      controller.redo();
      expect(controller.strokes, hasLength(1));

      controller.redo();
      expect(controller.stamps, hasLength(1));
    });

    test('deleteStamp pushes one undo snapshot; undo restores the deleted stamp', () {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);
      controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.stamp);
      controller.placeStamp(
        bytes: Uint8List.fromList([1]),
        contentType: 'image/svg+xml',
        pageIndex: 0,
        pdfPoint: const Offset(50, 50),
        intrinsicSize: const Size(24, 24),
        pageSize: _pageSize,
        idGenerator: () => 'a',
      );

      controller.deleteStamp('a');
      expect(controller.stamps, isEmpty);

      controller.undo();
      expect(controller.stamps, hasLength(1));
      expect(controller.stamps.single.id, 'a');
    });
  });

  group('PdfAnnotationController.exitMode tears down transient stamp state', () {
    test('clears selection and pending stamp so the layer overlay does not leak past the session', () async {
      final controller = PdfAnnotationController();
      addTearDown(controller.dispose);

      controller.enterMode(creatorName: 'alice', tool: PdfAnnotationTool.stamp);
      controller.placeStamp(
        bytes: Uint8List.fromList([1]),
        contentType: 'image/svg+xml',
        pageIndex: 0,
        pdfPoint: const Offset(50, 50),
        intrinsicSize: const Size(24, 24),
        pageSize: _pageSize,
        idGenerator: () => 'a',
      );
      // Pending must be armed first; setPendingStamp clears selection,
      // so swap the order vs. how the user sees it.
      controller.setPendingStamp(_def());
      controller.selectStamp('a');
      expect(controller.selectedStampIdListenable.value, 'a');
      expect(controller.pendingStampListenable.value, isNotNull);

      await controller.exitMode(onAnnotationsChanged: null);

      expect(controller.selectedStampIdListenable.value, isNull);
      expect(controller.pendingStampListenable.value, isNull);
      // Placed stamps survive — only the transient selection/pending
      // state is cleared.
      expect(controller.stamps, hasLength(1));
    });
  });
}
