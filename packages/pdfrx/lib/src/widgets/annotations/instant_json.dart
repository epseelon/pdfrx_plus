import 'dart:convert';
import 'dart:ui';

import 'pdf_ink_annotation.dart';

/// Instant JSON document-format URL written into exported documents.
const String instantJsonFormat = 'https://pspdfkit.com/instant-json/v1';

/// Annotation type identifier for freehand ink strokes.
const String _inkAnnotationType = 'pspdfkit/ink';

/// Encode a list of [PdfInkAnnotation] as an Instant JSON document.
///
/// The result is a wrapped document `{"format": ..., "annotations": [...]}`
/// containing one `pspdfkit/ink` entry per stroke. The `pdfId` field is
/// intentionally omitted (per Nutrient's storage guidance, since the
/// document fingerprint becomes stale as the PDF evolves).
String encodeInstantJson(List<PdfInkAnnotation> annotations) {
  final entries = annotations.map(_encodeInkEntry).toList(growable: false);
  return jsonEncode({'format': instantJsonFormat, 'annotations': entries});
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

/// Decode an Instant JSON document into a list of [PdfInkAnnotation].
///
/// Tolerates both the wrapped form (`{"annotations": [...]}`) and a bare
/// array of annotations (`[...]`). Empty / whitespace input returns an
/// empty list. Malformed JSON throws [FormatException].
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
  final trimmed = json.trim();
  if (trimmed.isEmpty) return const [];

  final dynamic decoded = jsonDecode(trimmed);
  final List<dynamic> entries;
  if (decoded is List) {
    entries = decoded;
  } else if (decoded is Map<String, dynamic>) {
    final annotations = decoded['annotations'];
    entries = annotations is List ? annotations : const [];
  } else {
    return const [];
  }

  final result = <PdfInkAnnotation>[];
  for (final entry in entries) {
    if (entry is! Map<String, dynamic>) continue;
    final annotation = _decodeInkEntry(
      entry,
      pageCount: pageCount,
      defaultColor: defaultColor,
      defaultLineWidth: defaultLineWidth,
    );
    if (annotation != null) result.add(annotation);
  }
  return result;
}

PdfInkAnnotation? _decodeInkEntry(
  Map<String, dynamic> entry, {
  required int pageCount,
  required Color defaultColor,
  required double defaultLineWidth,
}) {
  if (entry['type'] != _inkAnnotationType) return null;
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
