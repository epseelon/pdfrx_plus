import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'pdf_text_annotation.dart';
import 'selection_geometry.dart';

/// A face a font family really ships, as opposed to one the text engine
/// would fake by emboldening or slanting the regular face.
enum PdfAnnotationFontStyle {
  regular,
  bold,
  italic,
  boldItalic;

  /// Whether this face is drawn bold.
  bool get isBold => this == bold || this == boldItalic;

  /// Whether this face is drawn italic.
  bool get isItalic => this == italic || this == boldItalic;
}

/// A font family the host app can render text annotations in, and the
/// real faces it ships.
///
/// This package never names a font file: [name] is the family name the
/// host registered (in its `pubspec.yaml`, or through a `FontLoader`),
/// and the same string a `PdfTextAnnotation.fontFamily` stores.
@immutable
class PdfAnnotationFontFamily {
  const PdfAnnotationFontFamily(this.name, {this.styles = const [PdfAnnotationFontStyle.regular]});

  /// The registered family name.
  final String name;

  /// The faces the family really has. Bold or italic is only ever
  /// requested from the engine when the matching face is listed here, so
  /// the engine never has anything to synthesize.
  final List<PdfAnnotationFontStyle> styles;

  /// Whether the family ships [style] as a real face.
  bool has(PdfAnnotationFontStyle style) => styles.contains(style);

  /// The face really drawn when [bold] and [italic] are asked for: the
  /// matching face when the family ships it, else the nearest one it does
  /// (bold italic falls back to bold, then italic, then regular).
  ///
  /// A host's Bold or Italic toggle is meaningful exactly when the face
  /// this returns with that flag on is drawn that way.
  PdfAnnotationFontStyle realFace({required bool bold, required bool italic}) {
    final wanted = <PdfAnnotationFontStyle>[
      if (bold && italic) PdfAnnotationFontStyle.boldItalic,
      if (bold) PdfAnnotationFontStyle.bold,
      if (italic) PdfAnnotationFontStyle.italic,
    ];
    for (final style in wanted) {
      if (has(style)) return style;
    }
    return PdfAnnotationFontStyle.regular;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PdfAnnotationFontFamily && other.name == name && listEquals(other.styles, styles);

  @override
  int get hashCode => Object.hash(name, Object.hashAll(styles));

  @override
  String toString() => 'PdfAnnotationFontFamily($name, $styles)';
}

/// The font families text annotations can be rendered in, and the one
/// that stands in for a family this build does not know.
///
/// Passed by the host app through `PdfViewerParams.annotationFonts`.
/// Compares by value, because a `PdfViewerParams` is typically rebuilt on
/// every frame and a new-but-equal font set must not read as a change.
@immutable
class PdfAnnotationFonts {
  const PdfAnnotationFonts({required this.families, required this.defaultFamily});

  /// No family declared: text renders in the platform's default font,
  /// upright and at regular weight.
  const PdfAnnotationFonts.none() : families = const [], defaultFamily = null;

  /// The known families.
  final List<PdfAnnotationFontFamily> families;

  /// Name of the family a stored annotation falls back to when it names
  /// none, or one that is not in [families].
  final String? defaultFamily;

  /// The family [name] renders in: itself when known, otherwise the
  /// default family, otherwise `null` (nothing is declared at all).
  PdfAnnotationFontFamily? resolve(String? name) => _find(name) ?? _find(defaultFamily);

  PdfAnnotationFontFamily? _find(String? name) {
    if (name == null) return null;
    for (final family in families) {
      if (family.name == name) return family;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PdfAnnotationFonts && other.defaultFamily == defaultFamily && listEquals(other.families, families);

  @override
  int get hashCode => Object.hash(defaultFamily, Object.hashAll(families));
}

/// The `TextStyle` [annotation] is laid out and painted with, its family
/// resolved against [fonts].
///
/// Sizes are PDF points: the painter scales the canvas by the page zoom,
/// so the style itself never depends on the zoom.
///
/// Bold and italic are requested only when the resolved family declares
/// the real face; otherwise the nearest real face is requested instead
/// (bold italic falls back to bold, then italic, then regular). The
/// annotation is never modified, so a flag the family cannot honour is
/// still stored and shows again under a family that can.
TextStyle resolveAnnotationTextStyle(PdfTextAnnotation annotation, PdfAnnotationFonts fonts) {
  final family = fonts.resolve(annotation.fontFamily);
  final face = family?.realFace(bold: annotation.bold, italic: annotation.italic) ?? PdfAnnotationFontStyle.regular;
  return TextStyle(
    inherit: false,
    fontFamily: family?.name,
    fontSize: annotation.fontSize,
    color: annotation.color,
    fontWeight: face.isBold ? FontWeight.w700 : FontWeight.w400,
    fontStyle: face.isItalic ? FontStyle.italic : FontStyle.normal,
    decoration: annotation.underline ? TextDecoration.underline : TextDecoration.none,
    decorationColor: annotation.color,
    textBaseline: TextBaseline.alphabetic,
  );
}

/// Text laid out by [layoutAnnotationText].
class PdfAnnotationTextLayout {
  PdfAnnotationTextLayout({required this.size, required this.painter});

  /// The box that hugs the laid-out lines: as wide as the longest line,
  /// as tall as all of them.
  final Size size;

  /// The painter holding the layout. Paint it at the box's top-left.
  final TextPainter painter;

  /// The range of the source text each laid-out line covers, in order.
  /// What two devices compare to agree they broke the text alike.
  List<TextRange> get lineRanges {
    final ranges = <TextRange>[];
    final length = painter.plainText.length;
    var offset = 0;
    while (offset < length) {
      final line = painter.getLineBoundary(TextPosition(offset: offset));
      if (line.end <= offset) break;
      ranges.add(line);
      offset = line.end;
    }
    return ranges;
  }

  /// Releases the native paragraph. The layout is unusable afterwards.
  void dispose() => painter.dispose();
}

/// Signature of [layoutAnnotationText], so a test can count calls or
/// substitute metrics.
typedef PdfAnnotationTextLayouter =
    PdfAnnotationTextLayout Function({
      required String text,
      required TextStyle style,
      required PdfTextAnnotationAlign align,
      required double? wrapWidth,
    });

/// The one place annotation text is laid out. The canvas painter, the
/// auto-size computation, the never-clip rule and the page-edge rules
/// all go through it, so they cannot disagree on a line break.
///
/// Lines wrap at [wrapWidth], or never when it is `null`. The returned
/// size hugs the lines either way; [align] positions each line inside
/// that hugging box. Units are whatever [style]'s `fontSize` is in, PDF
/// points for annotations, and the operating system's text scale is
/// deliberately ignored: an annotation covers the same area of the page
/// on every device.
PdfAnnotationTextLayout layoutAnnotationText({
  required String text,
  required TextStyle style,
  required PdfTextAnnotationAlign align,
  required double? wrapWidth,
}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textAlign: switch (align) {
      PdfTextAnnotationAlign.left => TextAlign.left,
      PdfTextAnnotationAlign.center => TextAlign.center,
      PdfTextAnnotationAlign.right => TextAlign.right,
    },
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.noScaling,
    textWidthBasis: TextWidthBasis.longestLine,
  )..layout(maxWidth: wrapWidth == null ? double.infinity : math.max(wrapWidth, 0.0));
  return PdfAnnotationTextLayout(size: painter.size, painter: painter);
}

/// The width [annotation]'s lines wrap at on a page of [pageSize].
///
/// A text area wraps at its own width. Auto-sized text has an implicit
/// maximum width, the distance from its left edge to the page's right
/// edge in its unrotated frame: it is derived here on every device and
/// never stored.
double textAnnotationWrapWidth(PdfTextAnnotation annotation, {required Size pageSize}) {
  final rect = annotation.rectInPdfSpace;
  if (!annotation.autoSize) return rect.width;
  return math.max(pageSize.width - rect.left, kMinAnnotationSizePts);
}

/// Where a text annotation is painted (and, later, hit-tested and
/// wrapped by the gizmo), as opposed to the box it stores.
@immutable
class PdfTextDisplayBox {
  const PdfTextDisplayBox({required this.displayRect, required this.textOffset, required this.layout});

  /// The box, in PDF points, in the annotation's unrotated frame.
  final Rect displayRect;

  /// Where the hugging box of [layout] sits inside [displayRect].
  final Offset textOffset;

  /// The laid-out text.
  final PdfAnnotationTextLayout layout;
}

/// Derives [annotation]'s display box from its stored box and [layout],
/// which must come from [layoutAnnotationText] at
/// [textAnnotationWrapWidth].
PdfTextDisplayBox computeTextDisplayBox({
  required PdfTextAnnotation annotation,
  required Size pageSize,
  required PdfAnnotationTextLayout layout,
}) {
  final stored = annotation.rectInPdfSpace;
  // Auto-sized text hugs its lines. A text area keeps its width and is
  // never shorter than its content, so nothing is ever clipped.
  final size = annotation.autoSize ? layout.size : Size(stored.width, math.max(stored.height, layout.size.height));

  // The box grows rightward and downward from its top-left corner. For a
  // rotated box that corner is the rotated one, the point that stays put
  // on screen, and the centre is re-derived from it: the rule
  // `resizeInLocalFrame` applies to a resize.
  final corner = stored.center + rotateVectorToScreen(stored.topLeft - stored.center, annotation.rotationDeg);
  final center = corner + rotateVectorToScreen(size.center(Offset.zero), annotation.rotationDeg);
  var rect = Rect.fromCenter(center: center, width: size.width, height: size.height);
  if (annotation.rotationDeg == 0) {
    // Same box, without the float noise of a round trip through the centre.
    rect = stored.topLeft & size;
  }

  // Page-edge rule, in the unrotated frame: a box past the bottom edge
  // moves up to stay on the page, and one taller than the page pins to
  // the top and is allowed to overflow.
  if (rect.bottom > pageSize.height) {
    rect = rect.shift(Offset(0, math.max(pageSize.height - rect.height, 0.0) - rect.top));
  }

  final slack = rect.width - layout.size.width;
  final textOffset = switch (annotation.align) {
    PdfTextAnnotationAlign.left => Offset.zero,
    PdfTextAnnotationAlign.center => Offset(slack / 2, 0),
    PdfTextAnnotationAlign.right => Offset(slack, 0),
  };
  return PdfTextDisplayBox(displayRect: rect, textOffset: textOffset, layout: layout);
}
