import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Loader callback that returns the raw bytes for a [PdfStampDefinition].
///
/// Invoked at placement time (and may be invoked at app start for eager
/// pre-warming caches). The returned bytes are embedded verbatim into the
/// document's Instant JSON `attachments` map keyed by their SHA-256 hash,
/// so the loader must return *exactly* the bytes that should be persisted.
typedef PdfStampBytesLoader = FutureOr<Uint8List> Function();

/// Builder for the on-page widget that renders an embedded stamp image.
///
/// Receives the raw bytes, declared MIME type, and the *exact* display
/// size in widget pixels. The builder must respect the requested size
/// (no intrinsic sizing) — the stamp's bbox is laid out by the
/// annotation layer, and the rendered widget should fill it.
typedef PdfStampImageBuilder =
    Widget Function(BuildContext context, Uint8List bytes, String contentType, Size displaySize);

/// Library entry describing a stamp the host app exposes via
/// `PdfViewerParams.stampCategories`. Distinct from the placed stamp
/// instance that lives in the document.
///
/// Stamps are an SVG-renderer-agnostic abstraction: pdfrx does not know
/// how to render the bytes. The host supplies a
/// `PdfViewerParams.stampImageBuilder` callback that receives the raw
/// [bytesLoader] output along with the declared [contentType], and is
/// responsible for rendering it into a widget.
@immutable
class PdfStampDefinition {
  /// Creates a stamp library entry. The asserts fail loudly when the
  /// host's library is malformed (empty ids, empty content type,
  /// non-positive intrinsic size).
  ///
  /// Not a `const` constructor: `intrinsicSize.width`/`height` access
  /// is not const-evaluable, and the size assert is too useful to drop.
  // ignore: prefer_const_constructors_in_immutables
  PdfStampDefinition({
    required this.id,
    required this.name,
    required this.contentType,
    required this.bytesLoader,
    required this.intrinsicSize,
  }) : assert(id.isNotEmpty, 'PdfStampDefinition.id must be non-empty'),
       assert(contentType.isNotEmpty, 'PdfStampDefinition.contentType must be non-empty'),
       assert(
         intrinsicSize.width > 0 && intrinsicSize.height > 0,
         'PdfStampDefinition.intrinsicSize must have positive width and height',
       );

  /// Picker-only identifier. Used for sorting and as a stable widget
  /// key in the picker. Not embedded into Instant JSON.
  final String id;

  /// Human-readable label shown as a tooltip in the picker.
  final String name;

  /// MIME type of the bytes returned by [bytesLoader]. Embedded verbatim
  /// into the Instant JSON `pspdfkit/image` entry's `contentType` field.
  final String contentType;

  /// Loader for the raw bytes. The exact bytes returned are embedded as
  /// an Instant JSON attachment keyed by their SHA-256 hash.
  final PdfStampBytesLoader bytesLoader;

  /// Aspect-preserving size used to compute placement-time bounding
  /// boxes. Only the ratio matters — the placement algorithm scales the
  /// stamp so its longest side equals a fixed PDF-point default.
  final Size intrinsicSize;
}

/// Ordered group of [PdfStampDefinition]s shown as a single section in
/// the host's stamp picker UI.
@immutable
class PdfViewerStampCategory {
  /// Creates a category. The asserts fail loudly when the host's library
  /// is malformed (empty id).
  const PdfViewerStampCategory({required this.id, required this.title, required this.stamps})
    : assert(id.length > 0, 'PdfViewerStampCategory.id must be non-empty');
  // Note: keeping `id.length > 0` rather than `id.isNotEmpty` because
  // `String.isNotEmpty` is not const-evaluable in const constructors,
  // while `String.length > 0` is.

  /// Picker-only identifier. Used for sorting categories.
  final String id;

  /// Display title shown as the section header in the picker.
  final String title;

  /// Stamps in this category. The picker sorts by [PdfStampDefinition.id]
  /// at render time without mutating this list.
  final List<PdfStampDefinition> stamps;
}
