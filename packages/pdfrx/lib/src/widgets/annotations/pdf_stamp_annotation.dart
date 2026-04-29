import 'dart:typed_data';
import 'dart:ui';

/// Image stamp annotation rendered on top of a PDF page.
///
/// Stamps are vector or raster images embedded into the document's Instant
/// JSON `attachments` map keyed by [attachmentSha256]. The annotation
/// itself only carries the hash — the bytes live in the controller's
/// attachment store.
///
/// Coordinates in [rectInPdfSpace] are PDF points with the origin at the
/// page's top-left (Instant JSON convention). [rotationDeg] is a free
/// angle in degrees, counter-clockwise (CCW), matching Instant JSON's
/// rotation convention.
///
/// Page rotation other than 0° is unsupported (matches the existing ink
/// layer assumption).
class PdfStampAnnotation {
  const PdfStampAnnotation({
    required this.id,
    required this.pageIndex,
    required this.rectInPdfSpace,
    required this.rotationDeg,
    required this.attachmentSha256,
    required this.contentType,
    required this.createdAt,
    required this.updatedAt,
    this.creatorName,
  });

  /// Stable identifier (ULID/UUID). Used for hit-testing and selection;
  /// preserved across move/resize/rotate.
  final String id;

  /// 0-based page index this stamp is anchored to.
  final int pageIndex;

  /// Bounding box in PDF point space (top-left origin, x right, y down).
  final Rect rectInPdfSpace;

  /// Rotation in degrees, counter-clockwise. Free angle (no snap).
  final double rotationDeg;

  /// Lowercase hex SHA-256 of the embedded bytes. Key into the
  /// controller's attachment store.
  final String attachmentSha256;

  /// MIME type of the embedded bytes (e.g. `image/svg+xml`).
  final String contentType;

  /// When the stamp was first placed.
  final DateTime createdAt;

  /// When the stamp was last modified (move/resize/rotate). Equals
  /// [createdAt] for stamps that have not been edited.
  final DateTime updatedAt;

  /// Identifier of the user who placed this stamp, or `null` when the
  /// caller did not declare an identity (single-user / legacy mode).
  ///
  /// Maps directly to Instant JSON's `creatorName` field. Used by the
  /// annotation controller to scope ownership-aware operations: stamps
  /// owned by other creators render normally but cannot be selected,
  /// moved, resized, rotated, or deleted by the current creator.
  final String? creatorName;

  /// Returns a copy of this annotation with the given fields replaced.
  /// Fields not supplied retain the original value.
  PdfStampAnnotation copyWith({
    String? id,
    int? pageIndex,
    Rect? rectInPdfSpace,
    double? rotationDeg,
    String? attachmentSha256,
    String? contentType,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? creatorName,
  }) {
    return PdfStampAnnotation(
      id: id ?? this.id,
      pageIndex: pageIndex ?? this.pageIndex,
      rectInPdfSpace: rectInPdfSpace ?? this.rectInPdfSpace,
      rotationDeg: rotationDeg ?? this.rotationDeg,
      attachmentSha256: attachmentSha256 ?? this.attachmentSha256,
      contentType: contentType ?? this.contentType,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      creatorName: creatorName ?? this.creatorName,
    );
  }
}

/// In-memory bytes + content type for an attachment referenced by one or
/// more [PdfStampAnnotation]s. Held by the annotation controller's
/// attachment store and persisted into the Instant JSON `attachments`
/// map at export time.
class PdfStampAttachment {
  const PdfStampAttachment({required this.bytes, required this.contentType});

  /// Raw bytes referenced by [PdfStampAnnotation.attachmentSha256].
  final Uint8List bytes;

  /// MIME type of the bytes (must match the referencing annotations).
  final String contentType;
}
