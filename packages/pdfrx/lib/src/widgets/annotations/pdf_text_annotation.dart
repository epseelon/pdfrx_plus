import 'dart:ui';

import 'package:flutter/foundation.dart';

/// Horizontal alignment of the lines of a [PdfTextAnnotation] inside its
/// box. Maps to Instant JSON's `horizontalAlign`.
enum PdfTextAnnotationAlign { left, center, right }

/// Font size, in PDF points, a text annotation takes when its stored
/// `fontSize` is missing or unusable.
const double kDefaultTextAnnotationFontSize = 18.0;

/// The style of a [PdfTextAnnotation]. It applies to the whole
/// annotation: one font, one size, one colour, one bold state, one italic
/// state, one underline state, one alignment.
///
/// [bold] and [italic] are what the user ASKED for, not what is drawn: a
/// family that lacks the face renders without it (see
/// `resolveAnnotationTextStyle`) and the flag is kept, so it shows again
/// under a family that has the face.
@immutable
class PdfTextAnnotationStyle {
  const PdfTextAnnotationStyle({
    this.fontFamily,
    this.fontSize = kDefaultTextAnnotationFontSize,
    this.color = const Color(0xFF000000),
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.align = PdfTextAnnotationAlign.left,
  });

  /// Font family NAME, or `null` for the host app's default family.
  final String? fontFamily;

  /// Font size in PDF points.
  final double fontSize;

  final Color color;
  final bool bold;
  final bool italic;
  final bool underline;
  final PdfTextAnnotationAlign align;

  PdfTextAnnotationStyle copyWith({
    String? fontFamily,
    double? fontSize,
    Color? color,
    bool? bold,
    bool? italic,
    bool? underline,
    PdfTextAnnotationAlign? align,
  }) => PdfTextAnnotationStyle(
    fontFamily: fontFamily ?? this.fontFamily,
    fontSize: fontSize ?? this.fontSize,
    color: color ?? this.color,
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    underline: underline ?? this.underline,
    align: align ?? this.align,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PdfTextAnnotationStyle &&
          other.fontFamily == fontFamily &&
          other.fontSize == fontSize &&
          other.color == color &&
          other.bold == bold &&
          other.italic == italic &&
          other.underline == underline &&
          other.align == align;

  @override
  int get hashCode => Object.hash(fontFamily, fontSize, color, bold, italic, underline, align);

  @override
  String toString() =>
      'PdfTextAnnotationStyle($fontFamily, $fontSize, $color, '
      'bold: $bold, italic: $italic, underline: $underline, $align)';
}

/// Text annotation laid over a PDF page.
///
/// Mirrors `PdfRectAnnotation` and `PdfStampAnnotation` field for field,
/// plus the text and its style: the three kinds share the selection gizmo,
/// the unified paint sequence, and the persistence pipeline, so keeping
/// their shapes aligned keeps that code free of per-kind special cases.
///
/// It is ONE kind with a sizing mode, [autoSize]: auto-sized text hugs its
/// content, a text area wraps its text inside the box the user drew.
///
/// Coordinates in [rectInPdfSpace] are PDF points with the origin at the
/// page's top-left (Instant JSON convention). [rotationDeg] is a free
/// angle in degrees, counter-clockwise (CCW), matching Instant JSON's
/// rotation convention.
///
/// Serialises to the Instant JSON native type `pspdfkit/text`. The style
/// applies to the whole annotation: there is no per-word styling.
class PdfTextAnnotation {
  const PdfTextAnnotation({
    required this.id,
    required this.pageIndex,
    required this.rectInPdfSpace,
    required this.rotationDeg,
    required this.text,
    required this.createdAt,
    required this.updatedAt,
    this.fontFamily,
    this.fontSize = kDefaultTextAnnotationFontSize,
    this.color = const Color(0xFF000000),
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.align = PdfTextAnnotationAlign.left,
    this.autoSize = false,
    this.creatorName,
    this.preservedJson = const {},
  });

  /// Stable identifier (ULID/UUID). Used for hit-testing and selection;
  /// preserved across move/resize/rotate.
  final String id;

  /// 0-based page index this text annotation is anchored to.
  final int pageIndex;

  /// Stored box in PDF point space (top-left origin, x right, y down).
  /// The codec keeps it verbatim: it has no fonts and never lays text out.
  final Rect rectInPdfSpace;

  /// Rotation in degrees, counter-clockwise. Free angle (no snap).
  final double rotationDeg;

  /// The text, with `\n` between lines.
  final String text;

  /// Stored font family NAME, or `null` when the entry names none. It is a
  /// plain string this package never resolves to a file: a family the
  /// host app does not know renders in its default family, and the stored
  /// name still round-trips.
  final String? fontFamily;

  /// Font size in PDF points.
  final double fontSize;

  /// Text colour. Persisted as `#RRGGBB`; alpha is not stored.
  final Color color;

  final bool bold;
  final bool italic;
  final bool underline;

  /// Alignment of the lines inside the box.
  final PdfTextAnnotationAlign align;

  /// Sizing mode: `true` for auto-sized text, `false` for a text area.
  final bool autoSize;

  /// When the text annotation was first committed.
  final DateTime createdAt;

  /// When the text annotation was last modified. Equals [createdAt] for
  /// text annotations that have not been edited.
  final DateTime updatedAt;

  /// Identifier of the user who wrote this text annotation, or `null` when
  /// the caller did not declare an identity (single-user / legacy mode).
  ///
  /// Maps directly to Instant JSON's `creatorName` field. Text annotations
  /// owned by other creators render normally but cannot be selected,
  /// edited, moved, resized, rotated, or deleted by the current creator.
  final String? creatorName;

  /// Raw Instant JSON values of the stored entry that this build does not
  /// model or could not use, keyed by their JSON key, so the encoder can
  /// put them back exactly as they arrived: a key written by another
  /// producer (`backgroundColor`), or a stored value the decoder had to
  /// replace with a default (a `fontSize` of `"big"`, a `horizontalAlign`
  /// of `"justify"`).
  ///
  /// On encode each of these values wins over what the modelled field
  /// emits under the same key. [copyWith] therefore retires the keys of
  /// every field it is given a new value for, so an edit is never
  /// silently reverted on save by the stored value it replaced.
  final Map<String, dynamic> preservedJson;

  /// The style fields, as one value.
  PdfTextAnnotationStyle get style => PdfTextAnnotationStyle(
    fontFamily: fontFamily,
    fontSize: fontSize,
    color: color,
    bold: bold,
    italic: italic,
    underline: underline,
    align: align,
  );

  /// Returns a copy restyled to [style]. Only the fields that differ are
  /// replaced, so a restyle retires the preserved raw value of what the
  /// user really changed and of nothing else (see [copyWith]).
  PdfTextAnnotation withStyle(PdfTextAnnotationStyle style) => copyWith(
    fontFamily: style.fontFamily != fontFamily ? style.fontFamily : null,
    fontSize: style.fontSize != fontSize ? style.fontSize : null,
    color: style.color != color ? style.color : null,
    bold: style.bold != bold ? style.bold : null,
    italic: style.italic != italic ? style.italic : null,
    underline: style.underline != underline ? style.underline : null,
    align: style.align != align ? style.align : null,
  );

  /// Returns a copy of this annotation with the given fields replaced.
  /// Fields not supplied retain the original value. Unless
  /// [preservedJson] is supplied, the raw values preserved for the
  /// replaced fields are retired (see [preservedJson]).
  PdfTextAnnotation copyWith({
    String? id,
    int? pageIndex,
    Rect? rectInPdfSpace,
    double? rotationDeg,
    String? text,
    String? fontFamily,
    double? fontSize,
    Color? color,
    bool? bold,
    bool? italic,
    bool? underline,
    PdfTextAnnotationAlign? align,
    bool? autoSize,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? creatorName,
    Map<String, dynamic>? preservedJson,
  }) {
    var preserved = preservedJson ?? this.preservedJson;
    if (preservedJson == null && preserved.isNotEmpty) {
      final retired = <String>{
        if (id != null) 'id',
        if (pageIndex != null) 'pageIndex',
        if (rectInPdfSpace != null) 'bbox',
        if (rotationDeg != null) ...['rotation', 'pdfrx:rotation'],
        if (text != null) 'text',
        if (fontFamily != null) 'font',
        if (fontSize != null) 'fontSize',
        if (color != null) 'fontColor',
        if (bold != null || italic != null) 'fontStyle',
        if (underline != null) 'pdfrx:underline',
        if (align != null) 'horizontalAlign',
        if (autoSize != null) 'pdfrx:autoSize',
        if (createdAt != null) 'createdAt',
        if (updatedAt != null) 'updatedAt',
        if (creatorName != null) 'creatorName',
      };
      if (retired.any(preserved.containsKey)) {
        preserved = {
          for (final e in preserved.entries)
            if (!retired.contains(e.key)) e.key: e.value,
        };
      }
    }
    return PdfTextAnnotation(
      id: id ?? this.id,
      pageIndex: pageIndex ?? this.pageIndex,
      rectInPdfSpace: rectInPdfSpace ?? this.rectInPdfSpace,
      rotationDeg: rotationDeg ?? this.rotationDeg,
      text: text ?? this.text,
      fontFamily: fontFamily ?? this.fontFamily,
      fontSize: fontSize ?? this.fontSize,
      color: color ?? this.color,
      bold: bold ?? this.bold,
      italic: italic ?? this.italic,
      underline: underline ?? this.underline,
      align: align ?? this.align,
      autoSize: autoSize ?? this.autoSize,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      creatorName: creatorName ?? this.creatorName,
      preservedJson: preserved,
    );
  }
}
