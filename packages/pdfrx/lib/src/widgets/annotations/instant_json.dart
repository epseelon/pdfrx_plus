import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'pdf_ink_annotation.dart';
import 'pdf_stamp_annotation.dart';

/// Instant JSON document-format URL written into exported documents.
const String instantJsonFormat = 'https://pspdfkit.com/instant-json/v1';

/// Annotation type identifier for freehand ink strokes.
const String _inkAnnotationType = 'pspdfkit/ink';

/// Annotation type identifier for image stamps.
const String _imageAnnotationType = 'pspdfkit/image';

/// Result of [decodeInstantJson]. Carries ink strokes, image stamps, and
/// the attachment store referenced by stamp annotations.
class DecodedInstantJson {
  const DecodedInstantJson({required this.strokes, required this.stamps, required this.attachments});

  /// Decoded freehand ink strokes (`pspdfkit/ink` entries).
  final List<PdfInkAnnotation> strokes;

  /// Decoded image stamps (`pspdfkit/image` entries) whose
  /// [PdfStampAnnotation.attachmentSha256] resolves in [attachments].
  /// Stamps with missing or malformed attachments are silently skipped.
  final List<PdfStampAnnotation> stamps;

  /// Attachment store keyed by lowercase hex SHA-256.
  final Map<String, PdfStampAttachment> attachments;
}

/// Encode ink strokes (and optionally stamps + attachments) as an Instant
/// JSON document.
///
/// The result is a wrapped document
/// `{"format": ..., "annotations": [...], "attachments": {...}}` containing
/// one entry per annotation. The `pdfId` field is intentionally omitted
/// (per Nutrient's storage guidance, since the document fingerprint becomes
/// stale as the PDF evolves).
///
/// The `attachments` field is omitted entirely when there are no stamps
/// (i.e. legacy ink-only output is byte-identical to today). Only
/// attachments referenced by at least one [stamps] entry are included;
/// orphaned bytes in [attachments] are dropped.
String encodeInstantJson(
  List<PdfInkAnnotation> annotations, {
  List<PdfStampAnnotation> stamps = const [],
  Map<String, PdfStampAttachment> attachments = const {},
}) {
  final entries = <Map<String, dynamic>>[];
  for (final ink in annotations) {
    entries.add(_encodeInkEntry(ink));
  }
  for (final stamp in stamps) {
    entries.add(_encodeStampEntry(stamp));
  }

  final referenced = <String>{for (final s in stamps) s.attachmentSha256};
  final emittedAttachments = <String, dynamic>{};
  for (final entry in attachments.entries) {
    if (!referenced.contains(entry.key)) continue;
    emittedAttachments[entry.key] = {'binary': base64Encode(entry.value.bytes), 'contentType': entry.value.contentType};
  }

  final out = <String, dynamic>{'format': instantJsonFormat, 'annotations': entries};
  if (emittedAttachments.isNotEmpty) {
    out['attachments'] = emittedAttachments;
  }
  return jsonEncode(out);
}

Map<String, dynamic> _encodeInkEntry(PdfInkAnnotation a) {
  final points = a.pointsInPdfSpace.map((p) => [p.dx, p.dy]).toList(growable: false);
  final intensities = List<double>.filled(a.pointsInPdfSpace.length, 1.0);
  return {
    'v': 1,
    'type': _inkAnnotationType,
    'pageIndex': a.pageIndex,
    'bbox': _bbox(a.pointsInPdfSpace),
    'opacity': a.opacity,
    'createdAt': _formatTimestamp(a.createdAt),
    'updatedAt': _formatTimestamp(a.updatedAt),
    'lines': {
      'intensities': [intensities],
      'points': [points],
    },
    'lineWidth': a.lineWidth,
    'isDrawnNaturally': false,
    'strokeColor': colorToHex(a.strokeColor),
    if (a.creatorName != null) 'creatorName': a.creatorName,
    if (a.kind != PdfInkAnnotationKind.pen) 'pdfrx:kind': _kindToString(a.kind),
  };
}

Map<String, dynamic> _encodeStampEntry(PdfStampAnnotation a) {
  final r = a.rectInPdfSpace;
  final freeAngle = _normalizeAngle(a.rotationDeg);
  final snapped = _snapAngleToCardinal(freeAngle);
  return {
    'v': 1,
    'type': _imageAnnotationType,
    'id': a.id,
    'pageIndex': a.pageIndex,
    'bbox': [r.left, r.top, r.width, r.height],
    'contentType': a.contentType,
    'imageAttachmentId': a.attachmentSha256,
    'rotation': snapped,
    'pdfrx:rotation': freeAngle,
    'createdAt': _formatTimestamp(a.createdAt),
    'updatedAt': _formatTimestamp(a.updatedAt),
    if (a.creatorName != null) 'creatorName': a.creatorName,
  };
}

double _normalizeAngle(double degrees) {
  final mod = degrees % 360;
  return mod < 0 ? mod + 360 : mod;
}

int _snapAngleToCardinal(double normalized) {
  // normalized is already in [0, 360). Snap to nearest of {0, 90, 180, 270, 360}
  // and fold 360 back to 0.
  final snapped = ((normalized + 45) ~/ 90) * 90;
  return snapped % 360;
}

String _kindToString(PdfInkAnnotationKind kind) => switch (kind) {
  PdfInkAnnotationKind.pen => 'pen',
  PdfInkAnnotationKind.highlighter => 'highlighter',
};

PdfInkAnnotationKind? _kindFromString(dynamic value) {
  if (value is! String) return null;
  return switch (value) {
    'pen' => PdfInkAnnotationKind.pen,
    'highlighter' => PdfInkAnnotationKind.highlighter,
    _ => null,
  };
}

List<double> _bbox(List<Offset> points) {
  if (points.isEmpty) return const [0.0, 0.0, 0.0, 0.0];
  var minX = points.first.dx, maxX = points.first.dx;
  var minY = points.first.dy, maxY = points.first.dy;
  for (final p in points) {
    if (p.dx < minX) minX = p.dx;
    if (p.dx > maxX) maxX = p.dx;
    if (p.dy < minY) minY = p.dy;
    if (p.dy > maxY) maxY = p.dy;
  }
  return [minX, minY, maxX - minX, maxY - minY];
}

String _formatTimestamp(DateTime t) => t.toUtc().toIso8601String();

/// Decode an Instant JSON document into ink strokes only (legacy form).
///
/// Tolerates both the wrapped form (`{"annotations": [...]}`) and a bare
/// array of annotations (`[...]`). Empty / whitespace input returns an
/// empty list. Malformed JSON throws [FormatException].
///
/// Stamp (`pspdfkit/image`) entries are silently dropped — callers that
/// need stamps must use [decodeInstantJsonFull] instead.
///
/// Entries are silently skipped when:
/// * `type` is not `"pspdfkit/ink"`
/// * `v` is not `1`
/// * `pageIndex` is outside `[0, pageCount)`
/// * the first segment of `lines.points` has fewer than 2 points
///
/// [defaultColor] / [defaultLineWidth] are used when a stroke's
/// `strokeColor` is missing/unparseable or its `lineWidth` is missing /
/// `<= 0`.
List<PdfInkAnnotation> decodeInstantJson(
  String json, {
  required int pageCount,
  required Color defaultColor,
  required double defaultLineWidth,
}) {
  return decodeInstantJsonFull(
    json,
    pageCount: pageCount,
    defaultColor: defaultColor,
    defaultLineWidth: defaultLineWidth,
  ).strokes;
}

/// Decode an Instant JSON document into ink strokes, image stamps, and
/// the referenced attachment store.
///
/// Same input tolerance as [decodeInstantJson]. Stamp entries whose
/// `imageAttachmentId` is missing from the document's `attachments` map
/// are silently skipped; attachments whose `binary` is malformed base64
/// are dropped along with every annotation that references them. Unknown
/// `type` values are ignored without dropping the document (forward
/// compatibility).
DecodedInstantJson decodeInstantJsonFull(
  String json, {
  required int pageCount,
  required Color defaultColor,
  required double defaultLineWidth,
}) {
  final trimmed = json.trim();
  if (trimmed.isEmpty) {
    return const DecodedInstantJson(strokes: [], stamps: [], attachments: {});
  }

  final dynamic decoded = jsonDecode(trimmed);
  final List<dynamic> entries;
  var rawAttachments = const <String, dynamic>{};
  if (decoded is List) {
    entries = decoded;
  } else if (decoded is Map<String, dynamic>) {
    final annotations = decoded['annotations'];
    entries = annotations is List ? annotations : const [];
    final attachments = decoded['attachments'];
    if (attachments is Map<String, dynamic>) {
      rawAttachments = attachments;
    }
  } else {
    return const DecodedInstantJson(strokes: [], stamps: [], attachments: {});
  }

  final attachments = <String, PdfStampAttachment>{};
  for (final entry in rawAttachments.entries) {
    final value = entry.value;
    if (value is! Map<String, dynamic>) continue;
    final binary = value['binary'];
    final contentType = value['contentType'];
    if (binary is! String || contentType is! String) continue;
    Uint8List bytes;
    try {
      bytes = base64Decode(binary);
    } on FormatException {
      continue;
    }
    attachments[entry.key] = PdfStampAttachment(bytes: bytes, contentType: contentType);
  }

  final strokes = <PdfInkAnnotation>[];
  final stamps = <PdfStampAnnotation>[];
  for (final entry in entries) {
    if (entry is! Map<String, dynamic>) continue;
    final type = entry['type'];
    if (type == _inkAnnotationType) {
      final stroke = _decodeInkEntry(
        entry,
        pageCount: pageCount,
        defaultColor: defaultColor,
        defaultLineWidth: defaultLineWidth,
      );
      if (stroke != null) strokes.add(stroke);
    } else if (type == _imageAnnotationType) {
      final stamp = _decodeStampEntry(entry, pageCount: pageCount, attachments: attachments);
      if (stamp != null) stamps.add(stamp);
    }
  }

  // Drop attachments not referenced by any decoded stamp so the in-memory
  // store stays in sync with the on-disk payload's actual usage.
  final referenced = <String>{for (final s in stamps) s.attachmentSha256};
  attachments.removeWhere((k, _) => !referenced.contains(k));

  return DecodedInstantJson(strokes: strokes, stamps: stamps, attachments: attachments);
}

PdfInkAnnotation? _decodeInkEntry(
  Map<String, dynamic> entry, {
  required int pageCount,
  required Color defaultColor,
  required double defaultLineWidth,
}) {
  if (entry['v'] != 1) return null;

  final pageIndex = entry['pageIndex'];
  if (pageIndex is! int) return null;
  if (pageIndex < 0 || pageIndex >= pageCount) return null;

  final lines = entry['lines'];
  if (lines is! Map<String, dynamic>) return null;
  final segments = lines['points'];
  if (segments is! List || segments.isEmpty) return null;
  final firstSegment = segments.first;
  if (firstSegment is! List || firstSegment.length < 2) return null;

  final points = <Offset>[];
  for (final raw in firstSegment) {
    if (raw is! List || raw.length < 2) return null;
    final x = (raw[0] as num).toDouble();
    final y = (raw[1] as num).toDouble();
    points.add(Offset(x, y));
  }

  final rawLineWidth = entry['lineWidth'];
  final lineWidth = (rawLineWidth is num && rawLineWidth.toDouble() > 0) ? rawLineWidth.toDouble() : defaultLineWidth;

  final strokeColor = colorFromHex(entry['strokeColor']) ?? defaultColor;

  final rawOpacity = entry['opacity'];
  final opacity = rawOpacity is num ? rawOpacity.toDouble().clamp(0.0, 1.0) : 1.0;

  final createdAt = _parseTimestamp(entry['createdAt']) ?? DateTime.now().toUtc();
  final updatedAt = _parseTimestamp(entry['updatedAt']) ?? createdAt;

  final rawCreatorName = entry['creatorName'];
  final creatorName = rawCreatorName is String ? rawCreatorName : null;

  // Resolve kind: explicit `pdfrx:kind` field wins; missing/malformed/unknown
  // values silently fall back to opacity-based inference. This keeps legacy
  // documents (no `pdfrx:kind`, opacity == 1.0) round-tripping as pen, while
  // tolerating forward-compatible future kinds without dropping the entry.
  final kind =
      _kindFromString(entry['pdfrx:kind']) ??
      (opacity < 1.0 ? PdfInkAnnotationKind.highlighter : PdfInkAnnotationKind.pen);

  return PdfInkAnnotation(
    pageIndex: pageIndex,
    pointsInPdfSpace: points,
    lineWidth: lineWidth,
    strokeColor: strokeColor,
    opacity: opacity,
    createdAt: createdAt,
    updatedAt: updatedAt,
    creatorName: creatorName,
    kind: kind,
  );
}

PdfStampAnnotation? _decodeStampEntry(
  Map<String, dynamic> entry, {
  required int pageCount,
  required Map<String, PdfStampAttachment> attachments,
}) {
  if (entry['v'] != 1) return null;
  final pageIndex = entry['pageIndex'];
  if (pageIndex is! int) return null;
  if (pageIndex < 0 || pageIndex >= pageCount) return null;

  final attachmentId = entry['imageAttachmentId'];
  if (attachmentId is! String) return null;
  if (!attachments.containsKey(attachmentId)) return null;

  final bbox = entry['bbox'];
  if (bbox is! List || bbox.length < 4) return null;
  for (final v in bbox) {
    if (v is! num) return null;
  }
  final rect = Rect.fromLTWH(
    (bbox[0] as num).toDouble(),
    (bbox[1] as num).toDouble(),
    (bbox[2] as num).toDouble(),
    (bbox[3] as num).toDouble(),
  );

  final contentType = entry['contentType'];
  final resolvedContentType = contentType is String ? contentType : attachments[attachmentId]!.contentType;

  final pdfrxRotation = entry['pdfrx:rotation'];
  final fallbackRotation = entry['rotation'];
  double rotationDeg;
  if (pdfrxRotation is num) {
    rotationDeg = pdfrxRotation.toDouble();
  } else if (fallbackRotation is num) {
    rotationDeg = fallbackRotation.toDouble();
  } else {
    rotationDeg = 0.0;
  }

  final id = entry['id'];
  if (id is! String || id.isEmpty) return null;

  final createdAt = _parseTimestamp(entry['createdAt']) ?? DateTime.now().toUtc();
  final updatedAt = _parseTimestamp(entry['updatedAt']) ?? createdAt;
  final rawCreatorName = entry['creatorName'];
  final creatorName = rawCreatorName is String ? rawCreatorName : null;

  return PdfStampAnnotation(
    id: id,
    pageIndex: pageIndex,
    rectInPdfSpace: rect,
    rotationDeg: rotationDeg,
    attachmentSha256: attachmentId,
    contentType: resolvedContentType,
    createdAt: createdAt,
    updatedAt: updatedAt,
    creatorName: creatorName,
  );
}

DateTime? _parseTimestamp(dynamic value) {
  if (value is! String) return null;
  return DateTime.tryParse(value)?.toUtc();
}

/// Parse a `#RRGGBB` hex string. Returns null on any malformed input.
Color? colorFromHex(dynamic value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.length != 7 || !trimmed.startsWith('#')) return null;
  final intValue = int.tryParse(trimmed.substring(1), radix: 16);
  if (intValue == null) return null;
  return Color(0xFF000000 | intValue);
}

/// Format [color]'s RGB channels as `#RRGGBB` (alpha ignored).
String colorToHex(Color color) {
  final r = (color.r * 255).round().clamp(0, 255);
  final g = (color.g * 255).round().clamp(0, 255);
  final b = (color.b * 255).round().clamp(0, 255);
  String hex(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();
  return '#${hex(r)}${hex(g)}${hex(b)}';
}
