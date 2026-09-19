import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// A decoded stamp graphic, ready to be replayed onto the page canvas.
///
/// Holds a [ui.Picture], which is a native resource: whoever owns the
/// instance must call [dispose] exactly once when it is no longer
/// reachable. Ownership passes to the annotation controller's picture
/// cache as soon as a [PdfStampPictureDecoder] returns one.
class PdfDecodedStampPicture {
  /// Wraps [picture] together with the graphic's intrinsic [size].
  const PdfDecodedStampPicture({required this.picture, required this.size});

  /// The recorded drawing commands of the stamp graphic.
  final ui.Picture picture;

  /// The graphic's intrinsic size, in its own coordinate space. The
  /// painter scales this onto the stamp's bounding box on both axes
  /// independently (`BoxFit.fill`).
  final ui.Size size;

  /// Releases the underlying [ui.Picture]. Safe to call once.
  void dispose() => picture.dispose();
}

/// Turns raw stamp bytes into something paintable.
///
/// Receives the attachment's raw [bytes] and its declared MIME type, and
/// returns a disposable decoded picture plus its intrinsic size, or
/// `null` when the bytes cannot be decoded (including an unsupported
/// content type). Returning `null` and throwing are treated the same
/// way: the stamp draws nothing, the failure is logged once, and the
/// decode is never retried for that attachment.
///
/// Optional on `PdfViewerParams`: the package's own
/// [decodeStampPictureWithVectorGraphics] is used when the integrator
/// supplies none, so no wiring is required. The seam exists so tests can
/// inject a fake decoder and so a host with its own vector pipeline can
/// take over.
typedef PdfStampPictureDecoder = Future<PdfDecodedStampPicture?> Function(Uint8List bytes, String contentType);

/// MIME type of the only stamp payload this package decodes itself.
const String kSvgStampContentType = 'image/svg+xml';

/// The package's default [PdfStampPictureDecoder]: decodes SVG bytes
/// through `flutter_svg`'s `vg.loadPicture`.
///
/// Any other content type returns `null` rather than throwing, so the
/// caller's single "cannot decode" path handles both.
///
/// A `null` `BuildContext` is passed deliberately: it only affects the
/// locale and text direction handed to the SVG decoder, neither of which
/// any music-notation glyph depends on, and the decode runs from a
/// painter that has no element to read an inherited locale from.
Future<PdfDecodedStampPicture?> decodeStampPictureWithVectorGraphics(Uint8List bytes, String contentType) async {
  if (contentType != kSvgStampContentType) return null;
  final info = await vg.loadPicture(SvgBytesLoader(bytes), null);
  return PdfDecodedStampPicture(picture: info.picture, size: info.size);
}

/// Decoded-stamp store keyed by attachment SHA-256, owned by the
/// annotation controller.
///
/// The page painter is synchronous, so it can only draw entries that are
/// already decoded; an undecoded attachment is scheduled here and the
/// completion bumps [changedListenable] so the canvas repaints. Decoding
/// is normally pre-warmed when the annotation set is replaced, which
/// keeps the "draws nothing this frame" window invisible in practice.
///
/// Every [PdfDecodedStampPicture] this cache holds is owned by it and is
/// explicitly disposed on eviction, on [clear] and on [dispose]: the
/// upstream API documents picture disposal as the caller's
/// responsibility, and the viewer clears the cache on every document
/// swap.
class PdfStampPictureCache {
  /// Creates a cache backed by [decoder], defaulting to
  /// [decodeStampPictureWithVectorGraphics].
  PdfStampPictureCache({PdfStampPictureDecoder? decoder}) : _decoder = decoder ?? decodeStampPictureWithVectorGraphics;

  PdfStampPictureDecoder _decoder;
  final Map<String, PdfDecodedStampPicture> _pictures = <String, PdfDecodedStampPicture>{};
  final Set<String> _inFlight = <String>{};
  final Set<String> _failed = <String>{};
  final ValueNotifier<int> _tick = ValueNotifier<int>(0);

  /// Incremented on every decoder swap so a decode started by a previous
  /// decoder cannot land in the cache after it was replaced.
  int _generation = 0;
  bool _disposed = false;

  /// Bumps when a decode completes and the page canvas has something new
  /// to draw. Wire this to the viewer's canvas invalidation.
  Listenable get changedListenable => _tick;

  /// The decoder used for subsequent decodes.
  PdfStampPictureDecoder get decoder => _decoder;

  /// Replaces the decoder. Idempotent: re-setting the same decoder keeps
  /// the cache intact, which matters because `PdfViewerParams` is
  /// typically rebuilt on every frame.
  ///
  /// A genuinely different decoder invalidates everything the previous
  /// one produced, including its memoised failures: the cache's contents
  /// are a function of the decoder.
  set decoder(PdfStampPictureDecoder value) {
    if (_decoder == value) return;
    _decoder = value;
    _generation++;
    _inFlight.clear();
    _failed.clear();
    _disposePictures();
  }

  /// The already-decoded picture for [sha], or `null` when it has not
  /// been decoded (yet, or ever).
  PdfDecodedStampPicture? operator [](String sha) => _pictures[sha];

  /// `true` when the cache holds no decoded picture.
  bool get isEmpty => _pictures.isEmpty;

  /// Schedules a decode of [bytes] under [sha] unless it is already
  /// decoded, already in flight, or already known to be undecodable.
  void ensureDecoded({required String sha, required Uint8List bytes, required String contentType}) {
    if (_disposed) return;
    if (_pictures.containsKey(sha) || _inFlight.contains(sha) || _failed.contains(sha)) return;
    _inFlight.add(sha);
    unawaited(_decode(_generation, sha, bytes, contentType));
  }

  Future<void> _decode(int generation, String sha, Uint8List bytes, String contentType) async {
    PdfDecodedStampPicture? picture;
    Object? error;
    try {
      picture = await _decoder(bytes, contentType);
    } catch (e) {
      error = e;
    }

    // The cache may have been disposed, cleared or re-decodered while the
    // decode was in flight. Anything produced for a stale generation is
    // dropped, and disposed, because nothing else owns it.
    if (_disposed || generation != _generation) {
      picture?.dispose();
      return;
    }
    _inFlight.remove(sha);

    if (picture == null) {
      _failed.add(sha);
      // Logged exactly once per attachment: `_failed` gates every later
      // attempt, so a painter that walks the same broken stamp on every
      // frame stays silent.
      debugPrint(
        'pdfrx: cannot decode stamp attachment $sha ($contentType), so it will draw nothing.'
        '${error == null ? '' : ' Cause: $error'}',
      );
      return;
    }

    // A `clear()` between the schedule and the completion drops the
    // attachment, so only keep the picture if it is still wanted.
    _pictures[sha]?.dispose();
    _pictures[sha] = picture;
    _tick.value++;
  }

  /// Disposes and drops every picture whose key is not in [shas].
  void retainOnly(Set<String> shas) {
    _failed.removeWhere((sha) => !shas.contains(sha));
    final evicted = _pictures.keys.where((sha) => !shas.contains(sha)).toList(growable: false);
    for (final sha in evicted) {
      _pictures.remove(sha)!.dispose();
    }
  }

  /// Disposes and drops every picture. Called on document swap.
  void clear() {
    _inFlight.clear();
    _failed.clear();
    _disposePictures();
  }

  /// Disposes every picture and stops accepting new decodes.
  void dispose() {
    _disposed = true;
    _inFlight.clear();
    _failed.clear();
    _disposePictures();
    _tick.dispose();
  }

  void _disposePictures() {
    for (final picture in _pictures.values) {
      picture.dispose();
    }
    _pictures.clear();
  }
}
