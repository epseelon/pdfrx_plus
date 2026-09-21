import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'pdf_ink_annotation.dart';
import 'pdf_rect_annotation.dart';
import 'pdf_stamp_annotation.dart';
import 'pdf_text_annotation.dart';

/// Instant JSON document-format URL written into exported documents.
const String instantJsonFormat = 'https://pspdfkit.com/instant-json/v1';

/// Annotation type identifier for freehand ink strokes.
const String _inkAnnotationType = 'pspdfkit/ink';

/// Annotation type identifier for image stamps.
const String _imageAnnotationType = 'pspdfkit/image';

/// Annotation type identifier for rectangles (the format's native shape
/// type, so a rectangle stays readable by any Instant JSON consumer).
const String _rectAnnotationType = 'pspdfkit/shape/rectangle';

/// Annotation type identifier for text annotations (the format's native
/// text type).
const String _textAnnotationType = 'pspdfkit/text';

/// `strokeColor` emitted for a rectangle that has no fill. The shape
/// schema requires `strokeColor`, and with `strokeWidth: 0` the value is
/// never painted, so any hex is schema-valid; a constant keeps the
/// payload stable across round trips.
const String _noFillStrokeColor = '#000000';

/// Result of [decodeInstantJson]. Carries ink strokes, rectangles, image
/// stamps, text annotations, the entries this build does not recognise,
/// and the attachment store referenced by stamp and unknown annotations.
class DecodedInstantJson {
  const DecodedInstantJson({
    required this.strokes,
    required this.stamps,
    required this.attachments,
    this.rects = const [],
    this.texts = const [],
    this.unknowns = const [],
  });

  /// Decoded freehand ink strokes (`pspdfkit/ink` entries).
  final List<PdfInkAnnotation> strokes;

  /// Decoded image stamps (`pspdfkit/image` entries) whose
  /// [PdfStampAnnotation.attachmentSha256] resolves in [attachments].
  /// Stamps with missing or malformed attachments are silently skipped.
  final List<PdfStampAnnotation> stamps;

  /// Decoded rectangles (`pspdfkit/shape/rectangle` entries).
  final List<PdfRectAnnotation> rects;

  /// Decoded text annotations (`pspdfkit/text` entries). Defaults to empty
  /// so call sites that predate the kind keep compiling.
  ///
  /// A consumer that re-encodes a decoded document MUST carry this bucket:
  /// a `pspdfkit/text` entry no longer travels in [unknowns], so a consumer
  /// that forwards only the older buckets deletes every text annotation.
  final List<PdfTextAnnotation> texts;

  /// Entries whose `type` this build does not recognise, kept VERBATIM as
  /// their raw JSON maps so they survive a decode/encode round trip.
  ///
  /// There is no model class to decode them into and no painter that can
  /// draw them, so they are carried, not interpreted: a build that
  /// predates a newer annotation kind renders everything it understands
  /// and hands the rest back unchanged on export. Dropping them here
  /// instead would let an older client silently erase a newer client's
  /// work the first time it re-exported a shared document.
  ///
  /// An unknown entry naming an `imageAttachmentId` keeps that
  /// attachment alive in [attachments] too, so its binary travels with
  /// it rather than being pruned as unreferenced.
  final List<Map<String, dynamic>> unknowns;

  /// Attachment store keyed by lowercase hex SHA-256.
  final Map<String, PdfStampAttachment> attachments;
}

/// The attachment ids referenced by [unknowns], read from each entry's
/// `imageAttachmentId`. Shared by the encoder and the decoder so both
/// agree on which binaries an unrecognised entry keeps alive.
Set<String> _attachmentIdsOfUnknowns(List<Map<String, dynamic>> unknowns) {
  final out = <String>{};
  for (final entry in unknowns) {
    final id = entry['imageAttachmentId'];
    if (id is String && id.isNotEmpty) out.add(id);
  }
  return out;
}

/// Encode ink strokes (and optionally stamps, rectangles, text
/// annotations + attachments) as an Instant JSON document.
///
/// The result is a wrapped document
/// `{"format": ..., "annotations": [...], "attachments": {...}}` containing
/// one entry per annotation. The `pdfId` field is intentionally omitted
/// (per Nutrient's storage guidance, since the document fingerprint becomes
/// stale as the PDF evolves).
///
/// The `attachments` field is omitted entirely when there are no stamps
/// (i.e. legacy ink-only output is byte-identical to today). Only
/// attachments referenced by at least one [stamps] or [unknowns] entry
/// are included; orphaned bytes in [attachments] are dropped.
///
/// [unknowns] are entries this build could not interpret (see
/// [DecodedInstantJson.unknowns]). They are re-emitted verbatim so a
/// decode/encode round trip through a build that predates a newer
/// annotation kind preserves that kind instead of erasing it.
String encodeInstantJson(
  List<PdfInkAnnotation> annotations, {
  List<PdfStampAnnotation> stamps = const [],
  List<PdfRectAnnotation> rects = const [],
  List<PdfTextAnnotation> texts = const [],
  List<Map<String, dynamic>> unknowns = const [],
  Map<String, PdfStampAttachment> attachments = const {},
}) {
  final entries = <Map<String, dynamic>>[];
  for (final ink in annotations) {
    entries.add(_encodeInkEntry(ink));
  }
  for (final stamp in stamps) {
    entries.add(_encodeStampEntry(stamp));
  }
  // Rectangles are emitted last so adding the kind leaves the entry order
  // of every pre-existing payload untouched. Entry order carries no paint
  // meaning: the page painter sorts by `createdAt` (see
  // `buildPageAnnotationPaintSequence`).
  for (final rect in rects) {
    entries.add(_encodeRectEntry(rect));
  }
  // Text annotations follow rectangles for the same reason rectangles
  // follow stamps: every payload that predates the kind keeps its order.
  for (final text in texts) {
    entries.add(_encodeTextEntry(text));
  }
  // Unrecognised entries trail the kinds this build understands, for the
  // same reason rectangles do. They are emitted exactly as they were
  // decoded: this encoder must not normalise a shape it cannot read.
  entries.addAll(unknowns);

  final referenced = <String>{for (final s in stamps) s.attachmentSha256, ..._attachmentIdsOfUnknowns(unknowns)};
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
  // Payload shrink: coordinates are rounded to 2 decimals and `lines.intensities`
  // is no longer emitted (the decoder never read it). The bbox is derived from
  // the SAME rounded points so `encode(decode(x)) == x` for fork-authored
  // payloads (a decode reads back the rounded points verbatim).
  final points = a.pointsInPdfSpace.map((p) => Offset(_round2(p.dx), _round2(p.dy))).toList(growable: false);
  final jsonPoints = points.map((p) => [p.dx, p.dy]).toList(growable: false);
  return {
    'v': 1,
    'type': _inkAnnotationType,
    if (a.id != null) 'id': a.id,
    'pageIndex': a.pageIndex,
    'bbox': _bbox(points),
    'opacity': a.opacity,
    'createdAt': _formatTimestamp(a.createdAt),
    'updatedAt': _formatTimestamp(a.updatedAt),
    'lines': {
      'points': [jsonPoints],
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

Map<String, dynamic> _encodeRectEntry(PdfRectAnnotation a) {
  final r = a.rectInPdfSpace;
  final fill = a.fillColor;
  // `strokeColor` is required by the Instant JSON shape schema, so it is
  // emitted equal to `fillColor` with `strokeWidth: 0`: schema-valid and
  // borderless. Unlike the stamp encoder, NO cardinal `rotation` key is
  // emitted: the shape schema defines no rotation, so pushing one would
  // put an off-schema key into a document a real PSPDFKit importer might
  // read. Only the namespaced extension carries the angle.
  return {
    'v': 1,
    'type': _rectAnnotationType,
    'id': a.id,
    'pageIndex': a.pageIndex,
    'bbox': [r.left, r.top, r.width, r.height],
    'opacity': 1.0,
    'strokeWidth': 0,
    'strokeColor': fill == null ? _noFillStrokeColor : colorToHex(fill),
    if (fill != null) 'fillColor': colorToHex(fill),
    'pdfrx:rotation': _normalizeAngle(a.rotationDeg),
    'createdAt': _formatTimestamp(a.createdAt),
    'updatedAt': _formatTimestamp(a.updatedAt),
    if (a.creatorName != null) 'creatorName': a.creatorName,
  };
}

/// The stored entry of [a]: what its modelled fields encode to, with
/// every raw value the decoder preserved put back over it (see
/// [PdfTextAnnotation.preservedJson]). A preserved key the model also
/// emits keeps its position; an unmodelled one is appended.
Map<String, dynamic> _encodeTextEntry(PdfTextAnnotation a) => {..._encodeTextModel(a), ...a.preservedJson};

Map<String, dynamic> _encodeTextModel(PdfTextAnnotation a) {
  final r = a.rectInPdfSpace;
  // The text schema DOES define `rotation` (restricted to 0/90/180/270),
  // so this follows the stamp encoder, not the rectangle's: the snapped
  // cardinal in `rotation`, the free angle in the namespaced extension.
  final freeAngle = _normalizeAngle(a.rotationDeg);
  // Underline and the sizing mode have no field in the format, so they
  // travel in the `pdfrx:` namespace. No `backgroundColor`, `borderStyle`,
  // `callout` or `isFitting` is ever written.
  return {
    'v': 1,
    'type': _textAnnotationType,
    'id': a.id,
    'pageIndex': a.pageIndex,
    'bbox': [_round2(r.left), _round2(r.top), _round2(r.width), _round2(r.height)],
    'opacity': 1.0,
    'text': a.text,
    if (a.fontFamily != null) 'font': a.fontFamily,
    'fontSize': _wholeAsInt(a.fontSize),
    'fontStyle': [if (a.bold) 'bold', if (a.italic) 'italic'],
    'fontColor': colorToHex(a.color),
    'horizontalAlign': a.align.name,
    'verticalAlign': 'top',
    'rotation': _snapAngleToCardinal(freeAngle),
    'pdfrx:rotation': freeAngle,
    'pdfrx:underline': a.underline,
    'pdfrx:autoSize': a.autoSize,
    'createdAt': _formatTimestamp(a.createdAt),
    'updatedAt': _formatTimestamp(a.updatedAt),
    if (a.creatorName != null) 'creatorName': a.creatorName,
  };
}

/// A whole [value] as an `int`, so a font size of 18 is written `18` on
/// every platform (the VM would otherwise write `18.0` where the web
/// writes `18`). Any other value is returned unchanged.
num _wholeAsInt(double value) => value.isFinite && value == value.truncateToDouble() ? value.toInt() : value;

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
  // Round the derived width/height too so a bbox computed from rounded points
  // stays a stable 2-decimal value (float subtraction can otherwise reintroduce
  // long tails) and the payload round-trips idempotently.
  return [_round2(minX), _round2(minY), _round2(maxX - minX), _round2(maxY - minY)];
}

/// Round a coordinate to 2 decimals for the payload shrink (requirement 5).
/// Idempotent: `_round2(_round2(x)) == _round2(x)`.
double _round2(double value) => (value * 100).round() / 100;

String _formatTimestamp(DateTime t) => t.toUtc().toIso8601String();

/// Decode an Instant JSON document into ink strokes only (legacy form).
///
/// Tolerates both the wrapped form (`{"annotations": [...]}`) and a bare
/// array of annotations (`[...]`). Empty / whitespace input returns an
/// empty list. Malformed JSON throws [FormatException].
///
/// Stamp (`pspdfkit/image`), rectangle (`pspdfkit/shape/rectangle`) and
/// text (`pspdfkit/text`) entries are silently dropped; callers that need them must use
/// [decodeInstantJsonFull] instead.
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

/// Decode an Instant JSON document into ink strokes, image stamps,
/// rectangles, text annotations, unrecognised entries, and the referenced
/// attachment store.
///
/// Same input tolerance as [decodeInstantJson]. Stamp entries whose
/// `imageAttachmentId` is missing from the document's `attachments` map
/// are silently skipped; attachments whose `binary` is malformed base64
/// are dropped along with every annotation that references them.
///
/// An entry whose `type` this build does not recognise is NOT dropped: it
/// is carried verbatim in [DecodedInstantJson.unknowns] (with its
/// attachment, if it names one) so [encodeInstantJson] can put it back
/// exactly as it arrived. Forward compatibility here means preserving a
/// newer client's annotation kind through a round trip, not merely
/// tolerating its presence in the input.
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
  final rects = <PdfRectAnnotation>[];
  final texts = <PdfTextAnnotation>[];
  final unknowns = <Map<String, dynamic>>[];
  for (final entry in entries) {
    if (entry is! Map<String, dynamic>) continue;
    final type = entry['type'];
    if (type == _inkAnnotationType) {
      strokes.addAll(
        _decodeInkEntry(entry, pageCount: pageCount, defaultColor: defaultColor, defaultLineWidth: defaultLineWidth),
      );
    } else if (type == _imageAnnotationType) {
      final stamp = _decodeStampEntry(entry, pageCount: pageCount, attachments: attachments);
      if (stamp != null) stamps.add(stamp);
    } else if (type == _rectAnnotationType) {
      final rect = _decodeRectEntry(entry, pageCount: pageCount);
      if (rect != null) rects.add(rect);
    } else if (type == _textAnnotationType) {
      final plainText = _plainTextOf(entry);
      final id = entry['id'];
      if (plainText == null || id is! String || id.isEmpty) {
        // A text entry this build cannot model (rich text, no readable
        // text, no id). It is CARRIED like any unknown kind, never
        // dropped: dropping it would delete it for the whole band on the
        // next save.
        unknowns.add(entry);
        continue;
      }
      final text = _decodeTextEntry(entry, id: id, text: plainText, pageCount: pageCount);
      if (text != null) texts.add(text);
    } else {
      // A kind this build does not know. Carried verbatim rather than
      // ignored: see [DecodedInstantJson.unknowns].
      unknowns.add(entry);
    }
  }

  // Drop attachments referenced by nothing that survived the decode, so
  // the in-memory store stays in sync with the payload's actual usage.
  // An unknown entry counts as a reference: its binary must outlive the
  // round trip exactly as a stamp's does.
  final referenced = <String>{for (final s in stamps) s.attachmentSha256, ..._attachmentIdsOfUnknowns(unknowns)};
  attachments.removeWhere((k, _) => !referenced.contains(k));

  return DecodedInstantJson(
    strokes: strokes,
    stamps: stamps,
    rects: rects,
    texts: texts,
    unknowns: unknowns,
    attachments: attachments,
  );
}

List<PdfInkAnnotation> _decodeInkEntry(
  Map<String, dynamic> entry, {
  required int pageCount,
  required Color defaultColor,
  required double defaultLineWidth,
}) {
  // Accept any positive integer version. pspdfkit's Instant JSON v2 differs
  // from v1 only in fields pdfrx doesn't read (e.g. `bbox`, `name`); the ink
  // schema itself is forward-compatible. Treating the version as a soft
  // forward-compat marker rather than a strict v:1 gate lets us round-trip
  // legacy pspdfkit-authored documents and any future v:N revisions whose
  // additions don't touch the fields this decoder consumes.
  final version = entry['v'];
  if (version is! int || version < 1) return const [];

  final pageIndex = entry['pageIndex'];
  if (pageIndex is! int) return const [];
  if (pageIndex < 0 || pageIndex >= pageCount) return const [];

  final lines = entry['lines'];
  if (lines is! Map<String, dynamic>) return const [];
  final segments = lines['points'];
  if (segments is! List || segments.isEmpty) return const [];

  final rawLineWidth = entry['lineWidth'];
  final lineWidth = (rawLineWidth is num && rawLineWidth.toDouble() > 0) ? rawLineWidth.toDouble() : defaultLineWidth;

  final strokeColor = colorFromHex(entry['strokeColor']) ?? defaultColor;

  final rawOpacity = entry['opacity'];
  final opacity = rawOpacity is num ? rawOpacity.toDouble().clamp(0.0, 1.0) : 1.0;

  // Missing timestamps fall back to a deterministic Unix-epoch sentinel, NOT
  // `DateTime.now()`: a `now()` fallback would give a timestamp-less entry a
  // fresh identity on every decode, causing permanent delete-and-recreate churn
  // of its persisted element doc (requirement 4).
  final createdAt = _parseTimestamp(entry['createdAt']) ?? _epochSentinel;
  final updatedAt = _parseTimestamp(entry['updatedAt']) ?? createdAt;

  final rawCreatorName = entry['creatorName'];
  final creatorName = rawCreatorName is String ? rawCreatorName : null;

  // Stable identity: the entry's embedded `id` when present. A multi-segment
  // entry expands to one stroke per segment, so each carries `'$id#$i'` to keep
  // the fragments distinct; a single-segment entry keeps the id verbatim.
  final rawId = entry['id'];
  final entryId = rawId is String && rawId.isNotEmpty ? rawId : null;
  final isMultiSegment = segments.length > 1;

  // Resolve kind: explicit `pdfrx:kind` field wins; missing/malformed/unknown
  // values silently fall back to opacity-based inference. This keeps legacy
  // documents (no `pdfrx:kind`, opacity == 1.0) round-tripping as pen, while
  // tolerating forward-compatible future kinds without dropping the entry.
  final kind =
      _kindFromString(entry['pdfrx:kind']) ??
      (opacity < 1.0 ? PdfInkAnnotationKind.highlighter : PdfInkAnnotationKind.pen);

  // pspdfkit's wire format groups multiple polylines under a single
  // annotation entry — `lines.points: [[seg1...], [seg2...], ...]` — and
  // each segment is a separate stroke that shares the entry's metadata
  // (color, width, creator, timestamps, …). pdfrx's data model uses one
  // [PdfInkAnnotation] per polyline, so we expand each non-empty segment
  // into its own annotation. Single-point "dot tap" segments are
  // preserved as-is — the renderer draws them as round-capped circles
  // of diameter `lineWidth` (pen and highlighter both use round caps).
  final out = <PdfInkAnnotation>[];
  for (var i = 0; i < segments.length; i++) {
    final segment = segments[i];
    if (segment is! List || segment.isEmpty) continue;
    final points = <Offset>[];
    var malformed = false;
    for (final raw in segment) {
      if (raw is! List || raw.length < 2) {
        malformed = true;
        break;
      }
      final x = (raw[0] as num).toDouble();
      final y = (raw[1] as num).toDouble();
      points.add(Offset(x, y));
    }
    if (malformed || points.isEmpty) continue;
    final strokeId = entryId == null ? null : (isMultiSegment ? '$entryId#$i' : entryId);
    out.add(
      PdfInkAnnotation(
        id: strokeId,
        pageIndex: pageIndex,
        pointsInPdfSpace: points,
        lineWidth: lineWidth,
        strokeColor: strokeColor,
        opacity: opacity,
        createdAt: createdAt,
        updatedAt: updatedAt,
        creatorName: creatorName,
        kind: kind,
      ),
    );
  }
  return out;
}

PdfStampAnnotation? _decodeStampEntry(
  Map<String, dynamic> entry, {
  required int pageCount,
  required Map<String, PdfStampAttachment> attachments,
}) {
  // See [_decodeInkEntry] — version is a soft forward-compat marker, not a
  // strict gate.
  final version = entry['v'];
  if (version is! int || version < 1) return null;
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

  // Same deterministic Unix-epoch sentinel the ink decoder uses, NOT
  // `DateTime.now()`. A `now()` fallback floats a timestamp-less stamp to the
  // top of the unified z-order on every decode and moves it again on the next
  // one, and because [encodeInstantJson] re-emits that fresh `createdAt`, the
  // re-split element id churns in the backing store on every round trip. See
  // [_decodeInkEntry] for the same reasoning.
  final createdAt = _parseTimestamp(entry['createdAt']) ?? _epochSentinel;
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

PdfRectAnnotation? _decodeRectEntry(Map<String, dynamic> entry, {required int pageCount}) {
  // Same tolerances as the ink and stamp decoders: a soft `v >= 1`
  // forward-compat marker, a bounds-checked `pageIndex`, a bbox of at
  // least 4 numbers, and a non-empty string id. A malformed entry is
  // skipped on its own; its siblings still decode.
  final version = entry['v'];
  if (version is! int || version < 1) return null;
  final pageIndex = entry['pageIndex'];
  if (pageIndex is! int) return null;
  if (pageIndex < 0 || pageIndex >= pageCount) return null;

  final bbox = entry['bbox'];
  if (bbox is! List || bbox.length < 4) return null;
  for (var i = 0; i < 4; i++) {
    if (bbox[i] is! num) return null;
  }
  final rect = Rect.fromLTWH(
    (bbox[0] as num).toDouble(),
    (bbox[1] as num).toDouble(),
    (bbox[2] as num).toDouble(),
    (bbox[3] as num).toDouble(),
  );

  final id = entry['id'];
  if (id is! String || id.isEmpty) return null;

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

  // A missing or unparseable `fillColor` means NO fill, never white: see
  // [PdfRectAnnotation.fillColor]. The entry is still kept so it
  // round-trips intact.
  final fillColor = colorFromHex(entry['fillColor']);

  // Same deterministic Unix-epoch sentinel the ink and stamp decoders
  // use, NOT `DateTime.now()`. See [_decodeInkEntry].
  final createdAt = _parseTimestamp(entry['createdAt']) ?? _epochSentinel;
  final updatedAt = _parseTimestamp(entry['updatedAt']) ?? createdAt;
  final rawCreatorName = entry['creatorName'];
  final creatorName = rawCreatorName is String ? rawCreatorName : null;

  return PdfRectAnnotation(
    id: id,
    pageIndex: pageIndex,
    rectInPdfSpace: rect,
    rotationDeg: rotationDeg,
    fillColor: fillColor,
    createdAt: createdAt,
    updatedAt: updatedAt,
    creatorName: creatorName,
  );
}

/// The plain text of a `pspdfkit/text` [entry], or `null` when it has none
/// this build can read. The format's guide declares `text` as a string and
/// shows it as `{"format": "plain", "value": "..."}`; both are accepted.
/// Any other `format` (rich text) is not plain text and is not decoded.
String? _plainTextOf(Map<String, dynamic> entry) {
  final text = entry['text'];
  if (text is String) return text;
  if (text is Map<String, dynamic> && text['format'] == 'plain') {
    final value = text['value'];
    if (value is String) return value;
  }
  return null;
}

PdfTextAnnotation? _decodeTextEntry(
  Map<String, dynamic> entry, {
  required String id,
  required String text,
  required int pageCount,
}) {
  final version = entry['v'];
  if (version is! int || version < 1) return null;
  final pageIndex = entry['pageIndex'];
  if (pageIndex is! int) return null;
  if (pageIndex < 0 || pageIndex >= pageCount) return null;

  final bbox = entry['bbox'];
  if (bbox is! List || bbox.length < 4) return null;
  for (var i = 0; i < 4; i++) {
    final v = bbox[i];
    // A non-finite coordinate is malformed too: it has no JSON form, so
    // it could never be written back.
    if (v is! num || !v.isFinite) return null;
  }
  // The stored box is kept verbatim: the codec has no fonts and never
  // lays the text out.
  final rect = Rect.fromLTWH(
    (bbox[0] as num).toDouble(),
    (bbox[1] as num).toDouble(),
    (bbox[2] as num).toDouble(),
    (bbox[3] as num).toDouble(),
  );

  final pdfrxRotation = entry['pdfrx:rotation'];
  final fallbackRotation = entry['rotation'];
  double rotationDeg;
  if (pdfrxRotation is num && pdfrxRotation.isFinite) {
    rotationDeg = pdfrxRotation.toDouble();
  } else if (fallbackRotation is num && fallbackRotation.isFinite) {
    rotationDeg = fallbackRotation.toDouble();
  } else {
    rotationDeg = 0.0;
  }

  final font = entry['font'];
  // Any positive finite size is kept, on the tool's list or not. Anything
  // else renders at the default, and the stored value is preserved below.
  final rawFontSize = entry['fontSize'];
  final fontSize = rawFontSize is num && rawFontSize.isFinite && rawFontSize > 0
      ? rawFontSize.toDouble()
      : kDefaultTextAnnotationFontSize;
  final fontStyle = entry['fontStyle'];
  final style = fontStyle is List ? fontStyle : const <dynamic>[];

  // Same deterministic Unix-epoch sentinel the other decoders use, NOT
  // `DateTime.now()`. See [_decodeInkEntry].
  final createdAt = _parseTimestamp(entry['createdAt']) ?? _epochSentinel;
  final updatedAt = _parseTimestamp(entry['updatedAt']) ?? createdAt;
  final rawCreatorName = entry['creatorName'];

  final model = PdfTextAnnotation(
    id: id,
    pageIndex: pageIndex,
    rectInPdfSpace: rect,
    rotationDeg: rotationDeg,
    text: text,
    fontFamily: font is String ? font : null,
    fontSize: fontSize,
    color: colorFromHex(entry['fontColor']) ?? const Color(0xFF000000),
    bold: style.contains('bold'),
    italic: style.contains('italic'),
    underline: entry['pdfrx:underline'] == true,
    align: PdfTextAnnotationAlign.values.asNameMap()[entry['horizontalAlign']] ?? PdfTextAnnotationAlign.left,
    autoSize: entry['pdfrx:autoSize'] == true,
    createdAt: createdAt,
    updatedAt: updatedAt,
    creatorName: rawCreatorName is String ? rawCreatorName : null,
  );

  // Preserve what this build cannot use. Every stored value that differs
  // from what [model] encodes to under the same key is kept raw: a key
  // this build does not model (`backgroundColor`), a value it had to
  // replace with a default (`fontSize: "big"`, `horizontalAlign:
  // "justify"`), a form it normalises (`text` as `{format, value}`, an
  // unrounded `bbox`). [_encodeTextEntry] puts them back, so re-saving an
  // entry this build did not edit never rewrites it.
  final encoded = _encodeTextModel(model);
  final preserved = <String, dynamic>{
    for (final e in entry.entries)
      if (!(encoded.containsKey(e.key) && _jsonEquals(encoded[e.key], e.value)) && _isJsonEncodable(e.value))
        e.key: e.value,
  };
  return preserved.isEmpty ? model : model.copyWith(preservedJson: preserved);
}

/// Deep equality of two decoded-JSON values. Numbers compare by value, so
/// `18` equals `18.0`: the VM and the web write the same double either way.
bool _jsonEquals(Object? a, Object? b) {
  if (a is num && b is num) return a == b;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_jsonEquals(a[key], b[key])) return false;
    }
    return true;
  }
  return a == b;
}

/// Whether [value] can be written back by `jsonEncode`. Only a non-finite
/// number cannot: `1e400` is valid JSON text that parses to infinity.
bool _isJsonEncodable(Object? value) {
  if (value is num) return value.isFinite;
  if (value is List) return value.every(_isJsonEncodable);
  if (value is Map) return value.values.every(_isJsonEncodable);
  return true;
}

/// Deterministic fallback timestamp (Unix epoch 0, UTC) for entries whose
/// `createdAt`/`updatedAt` are missing or unparseable. See [_decodeInkEntry].
final DateTime _epochSentinel = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

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
