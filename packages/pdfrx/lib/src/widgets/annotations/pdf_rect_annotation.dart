import 'dart:ui';

/// Opaque borderless rectangle annotation laid over a PDF page.
///
/// Mirrors `PdfStampAnnotation` field for field, plus [fillColor]: the two
/// kinds share the selection gizmo, the unified paint sequence, and the
/// persistence pipeline, so keeping their shapes aligned keeps that code
/// free of per-kind special cases.
///
/// Coordinates in [rectInPdfSpace] are PDF points with the origin at the
/// page's top-left (Instant JSON convention). [rotationDeg] is a free
/// angle in degrees, counter-clockwise (CCW), matching Instant JSON's
/// rotation convention.
///
/// Serialises to the Instant JSON native type
/// `pspdfkit/shape/rectangle`. The shape schema defines no rotation
/// property, so the angle travels only in the namespaced
/// `pdfrx:rotation` extension.
///
/// Page rotation other than 0° is unsupported (matches the existing ink
/// layer assumption).
class PdfRectAnnotation {
  const PdfRectAnnotation({
    required this.id,
    required this.pageIndex,
    required this.rectInPdfSpace,
    required this.rotationDeg,
    required this.createdAt,
    required this.updatedAt,
    this.fillColor,
    this.creatorName,
  });

  /// Stable identifier (ULID/UUID). Used for hit-testing and selection;
  /// preserved across move/resize/rotate.
  final String id;

  /// 0-based page index this rectangle is anchored to.
  final int pageIndex;

  /// Bounding box in PDF point space (top-left origin, x right, y down).
  final Rect rectInPdfSpace;

  /// Rotation in degrees, counter-clockwise. Free angle (no snap).
  final double rotationDeg;

  /// Fill colour, or `null` for **no fill**.
  ///
  /// `fillColor` is optional in the Instant JSON shape schema, so an
  /// entry without one is an outline-only rectangle. Such a rectangle is
  /// kept in the model (so it still round-trips) but paints nothing. It
  /// must never fall back to white: that would render a third-party or
  /// legacy pspdfkit-authored rectangle as an opaque block hiding score
  /// content its author never intended to cover. White is the rectangle
  /// tool's creation default only.
  final Color? fillColor;

  /// When the rectangle was first drawn.
  final DateTime createdAt;

  /// When the rectangle was last modified (move/resize/rotate). Equals
  /// [createdAt] for rectangles that have not been edited.
  final DateTime updatedAt;

  /// Identifier of the user who drew this rectangle, or `null` when the
  /// caller did not declare an identity (single-user / legacy mode).
  ///
  /// Maps directly to Instant JSON's `creatorName` field. Used by the
  /// annotation controller to scope ownership-aware operations:
  /// rectangles owned by other creators render normally but cannot be
  /// selected, moved, resized, rotated, or deleted by the current
  /// creator.
  final String? creatorName;

  /// Returns a copy of this annotation with the given fields replaced.
  /// Fields not supplied retain the original value.
  PdfRectAnnotation copyWith({
    String? id,
    int? pageIndex,
    Rect? rectInPdfSpace,
    double? rotationDeg,
    Color? fillColor,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? creatorName,
  }) {
    return PdfRectAnnotation(
      id: id ?? this.id,
      pageIndex: pageIndex ?? this.pageIndex,
      rectInPdfSpace: rectInPdfSpace ?? this.rectInPdfSpace,
      rotationDeg: rotationDeg ?? this.rotationDeg,
      fillColor: fillColor ?? this.fillColor,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      creatorName: creatorName ?? this.creatorName,
    );
  }
}
