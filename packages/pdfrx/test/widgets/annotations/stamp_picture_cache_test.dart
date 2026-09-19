import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_annotation_controller.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_stamp_annotation.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_stamp_picture.dart';

/// Records a real (but trivially small) [ui.Picture] so disposal can be
/// observed through `debugDisposed`. No SVG parsing happens anywhere in
/// this file: the decoder seam is faked throughout.
ui.Picture _recordPicture() {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 1, 1), Paint());
  return recorder.endRecording();
}

/// Fake decoder seam. Counts calls per content, hands back a picture the
/// test can watch, and can be made to fail or to hang.
class _FakeDecoder {
  final List<String> calls = <String>[];
  final List<PdfDecodedStampPicture> handedOut = <PdfDecodedStampPicture>[];
  bool fail = false;

  Future<PdfDecodedStampPicture?> call(Uint8List bytes, String contentType) async {
    calls.add(contentType);
    if (fail) return null;
    final picture = PdfDecodedStampPicture(picture: _recordPicture(), size: const Size(10, 20));
    handedOut.add(picture);
    return picture;
  }
}

Uint8List _bytes(int seed) => Uint8List.fromList([seed, seed + 1, seed + 2]);

PdfStampAnnotation _stamp({required String id, required String sha, int pageIndex = 0}) => PdfStampAnnotation(
  id: id,
  pageIndex: pageIndex,
  rectInPdfSpace: const Rect.fromLTWH(10, 10, 24, 24),
  rotationDeg: 0,
  attachmentSha256: sha,
  contentType: 'image/svg+xml',
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 1, 1),
);

void main() {
  group('stamp picture cache', () {
    test('schedules one decode per SHA even when several stamps share it', () async {
      final decoder = _FakeDecoder();
      final controller = PdfAnnotationController()..stampPictureDecoder = decoder.call;
      addTearDown(controller.dispose);

      const sha = 'sha-shared';
      controller.setAllWithStamps(
        strokes: const [],
        stamps: [
          _stamp(id: 'a', sha: sha),
          _stamp(id: 'b', sha: sha),
          _stamp(id: 'c', sha: sha),
        ],
        attachments: {sha: PdfStampAttachment(bytes: _bytes(1), contentType: 'image/svg+xml')},
      );
      await pumpEventQueue();

      expect(decoder.calls, hasLength(1));

      // A later painter pass that finds the SHA already decoded must not
      // schedule a second decode either.
      controller.ensureStampPictureDecoded(sha);
      await pumpEventQueue();
      expect(decoder.calls, hasLength(1));
    });

    test('pre-warms on setAllWithStamps rather than waiting for the first paint', () async {
      final decoder = _FakeDecoder();
      final controller = PdfAnnotationController()..stampPictureDecoder = decoder.call;
      addTearDown(controller.dispose);

      const sha = 'sha-prewarm';
      controller.setAllWithStamps(
        strokes: const [],
        stamps: [_stamp(id: 'a', sha: sha)],
        attachments: {sha: PdfStampAttachment(bytes: _bytes(2), contentType: 'image/svg+xml')},
      );
      await pumpEventQueue();

      // Nothing has painted yet, and the picture is already there.
      expect(controller.stampPictureFor(sha), isNotNull);
      expect(controller.stampPictureFor(sha)!.size, const Size(10, 20));
    });

    test('a completed decode triggers the repaint signal', () async {
      final decoder = _FakeDecoder();
      final controller = PdfAnnotationController()..stampPictureDecoder = decoder.call;
      addTearDown(controller.dispose);

      var repaints = 0;
      void onRepaint() => repaints++;
      controller.stampPicturesChangedListenable.addListener(onRepaint);
      addTearDown(() => controller.stampPicturesChangedListenable.removeListener(onRepaint));

      const sha = 'sha-signal';
      controller.setAllWithStamps(
        strokes: const [],
        stamps: [_stamp(id: 'a', sha: sha)],
        attachments: {sha: PdfStampAttachment(bytes: _bytes(3), contentType: 'image/svg+xml')},
      );
      expect(repaints, 0, reason: 'the decode has not completed yet');

      await pumpEventQueue();
      expect(repaints, 1);
    });

    test('eviction disposes the pictures of attachments that are no longer referenced', () async {
      final decoder = _FakeDecoder();
      final controller = PdfAnnotationController()..stampPictureDecoder = decoder.call;
      addTearDown(controller.dispose);

      const goneSha = 'sha-gone';
      const keptSha = 'sha-kept';
      controller.setAllWithStamps(
        strokes: const [],
        stamps: [
          _stamp(id: 'a', sha: goneSha),
          _stamp(id: 'b', sha: keptSha),
        ],
        attachments: {
          goneSha: PdfStampAttachment(bytes: _bytes(4), contentType: 'image/svg+xml'),
          keptSha: PdfStampAttachment(bytes: _bytes(5), contentType: 'image/svg+xml'),
        },
      );
      await pumpEventQueue();

      final gone = controller.stampPictureFor(goneSha)!;
      final kept = controller.stampPictureFor(keptSha)!;
      expect(gone.picture.debugDisposed, isFalse);

      // A remote refresh drops one of the two stamps.
      controller.setAllWithStamps(
        strokes: const [],
        stamps: [_stamp(id: 'b', sha: keptSha)],
        attachments: {keptSha: PdfStampAttachment(bytes: _bytes(5), contentType: 'image/svg+xml')},
      );
      await pumpEventQueue();

      expect(gone.picture.debugDisposed, isTrue);
      expect(controller.stampPictureFor(goneSha), isNull);
      expect(kept.picture.debugDisposed, isFalse, reason: 'a still-referenced attachment keeps its picture');
      expect(controller.stampPictureFor(keptSha), same(kept), reason: 'and is not re-decoded');
    });

    test('clear() disposes every decoded picture (document swap must not leak)', () async {
      final decoder = _FakeDecoder();
      final controller = PdfAnnotationController()..stampPictureDecoder = decoder.call;
      addTearDown(controller.dispose);

      const sha = 'sha-clear';
      controller.setAllWithStamps(
        strokes: const [],
        stamps: [_stamp(id: 'a', sha: sha)],
        attachments: {sha: PdfStampAttachment(bytes: _bytes(6), contentType: 'image/svg+xml')},
      );
      await pumpEventQueue();
      final picture = controller.stampPictureFor(sha)!;

      controller.clear();

      expect(picture.picture.debugDisposed, isTrue);
      expect(controller.stampPictureFor(sha), isNull);
    });

    test('controller disposal disposes every decoded picture', () async {
      final decoder = _FakeDecoder();
      final controller = PdfAnnotationController()..stampPictureDecoder = decoder.call;

      const sha = 'sha-dispose';
      controller.setAllWithStamps(
        strokes: const [],
        stamps: [_stamp(id: 'a', sha: sha)],
        attachments: {sha: PdfStampAttachment(bytes: _bytes(7), contentType: 'image/svg+xml')},
      );
      await pumpEventQueue();
      final picture = controller.stampPictureFor(sha)!;

      controller.dispose();

      expect(picture.picture.debugDisposed, isTrue);
    });

    test('a failing decode is swallowed, logged once, and never retried', () async {
      final decoder = _FakeDecoder()..fail = true;
      final controller = PdfAnnotationController()..stampPictureDecoder = decoder.call;
      addTearDown(controller.dispose);

      final logged = <String>[];
      final previousPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) logged.add(message);
      };
      addTearDown(() => debugPrint = previousPrint);

      const sha = 'sha-broken';
      controller.setAllWithStamps(
        strokes: const [],
        stamps: [
          _stamp(id: 'a', sha: sha),
          _stamp(id: 'b', sha: sha),
        ],
        attachments: {sha: PdfStampAttachment(bytes: _bytes(8), contentType: 'application/octet-stream')},
      );
      await pumpEventQueue();

      expect(controller.stampPictureFor(sha), isNull, reason: 'nothing to paint, but no throw');
      expect(decoder.calls, hasLength(1));
      expect(logged.where((m) => m.contains(sha)), hasLength(1));

      // A painter pass over the still-undecodable stamp must not re-log
      // or re-schedule: the failure is memoised.
      controller.ensureStampPictureDecoded(sha);
      await pumpEventQueue();
      expect(decoder.calls, hasLength(1));
      expect(logged.where((m) => m.contains(sha)), hasLength(1));
    });

    test('replacing the decoder drops what the previous decoder produced', () async {
      final first = _FakeDecoder();
      final controller = PdfAnnotationController()..stampPictureDecoder = first.call;
      addTearDown(controller.dispose);

      const sha = 'sha-swap';
      controller.setAllWithStamps(
        strokes: const [],
        stamps: [_stamp(id: 'a', sha: sha)],
        attachments: {sha: PdfStampAttachment(bytes: _bytes(9), contentType: 'image/svg+xml')},
      );
      await pumpEventQueue();
      final fromFirst = controller.stampPictureFor(sha)!;

      final second = _FakeDecoder();
      controller.stampPictureDecoder = second.call;

      expect(fromFirst.picture.debugDisposed, isTrue);
      expect(controller.stampPictureFor(sha), isNull);

      // Re-setting the same decoder is idempotent: it must not throw
      // away a cache that is still valid.
      controller.ensureStampPictureDecoded(sha);
      await pumpEventQueue();
      final fromSecond = controller.stampPictureFor(sha)!;
      controller.stampPictureDecoder = second.call;
      expect(controller.stampPictureFor(sha), same(fromSecond));
    });
  });
}
