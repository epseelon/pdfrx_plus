import 'dart:ui';

/// Visual variant of a freehand [PdfInkAnnotation].
///
/// Both variants are *freehand* ink strokes — they share the same
/// [PdfInkAnnotation] model and persist to the same `pspdfkit/ink` Instant
/// JSON entry. Only the rendering and styling differ:
///
/// * [pen] — opaque, round-capped, narrow.
/// * [highlighter] — translucent, round-capped, thick.
///
/// This kind is **not** the PDF `/Highlight` text-attached annotation
/// type, which uses rectangle quads anchored to selected text and would
/// require a different model class entirely. Future contributors
/// extending this enum should restrict themselves to additional
/// *freehand* variants (e.g. marker, brush) — anything text-attached
/// belongs in a separate type.
enum PdfInkAnnotationKind {
  /// Default. Opaque round-capped stroke.
  pen,

  /// Translucent round-capped stroke. Opacity is sourced from
  /// `PdfViewerParams.highlighterOpacity` at draw time.
  highlighter,
}

/// Freehand ink annotation rendered on top of a PDF page.
///
/// Coordinates in [pointsInPdfSpace] are PDF points with the origin at the
/// page's top-left (Instant JSON convention), x-axis increasing to the right,
/// y-axis increasing downward.
///
/// Annotations are document-blind: a [PdfInkAnnotation] does not know which
/// PDF it belongs to. The caller is responsible for associating exported
/// annotation JSON with the correct document.
class PdfInkAnnotation {
  const PdfInkAnnotation({
    required this.pageIndex,
    required this.pointsInPdfSpace,
    required this.lineWidth,
    required this.strokeColor,
    required this.opacity,
    required this.createdAt,
    required this.updatedAt,
    this.creatorName,
    this.kind = PdfInkAnnotationKind.pen,
  });

  /// 0-based page index this stroke is anchored to.
  final int pageIndex;

  /// Points along the stroke, in PDF point space (top-left origin).
  ///
  /// May contain points outside `[0, page.width] × [0, page.height]` when
  /// the user dragged off the page; the renderer clips to the page rect.
  final List<Offset> pointsInPdfSpace;

  /// Stroke width in PDF points.
  final double lineWidth;

  /// Stroke color (alpha channel ignored; opacity is carried separately).
  final Color strokeColor;

  /// Stroke opacity in `[0.0, 1.0]`.
  final double opacity;

  /// When the stroke was first committed.
  final DateTime createdAt;

  /// When the stroke was last modified (same as [createdAt] for new strokes
  /// that have not been edited).
  final DateTime updatedAt;

  /// Identifier of the user who created this stroke, or `null` when the
  /// caller has not declared an identity (single-user / legacy mode).
  ///
  /// Maps directly to Instant JSON's `creatorName` field. Used by the
  /// annotation controller to scope ownership-aware operations such as the
  /// eraser tool, which only removes strokes whose [creatorName] matches the
  /// current annotation session.
  final String? creatorName;

  /// Visual variant of the stroke. Defaults to [PdfInkAnnotationKind.pen]
  /// for backwards compatibility with callers that predate the
  /// highlighter tool.
  final PdfInkAnnotationKind kind;
}
