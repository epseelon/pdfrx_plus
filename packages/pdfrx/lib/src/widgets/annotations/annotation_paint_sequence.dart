import 'pdf_ink_annotation.dart';
import 'pdf_rect_annotation.dart';
import 'pdf_stamp_annotation.dart';
import 'pdf_text_annotation.dart';

/// Annotation kind, used as the third key of the unified paint order.
///
/// The ordinal is part of that order's contract, so the declaration
/// order is load-bearing and members are never reordered. [rect] is
/// declared ahead of its producer: the rectangle tool drops its entries
/// into this same sequence, and giving it its ordinal now keeps the
/// order of the two kinds that already exist stable when it arrives.
enum PdfAnnotationPaintKind {
  /// A freehand [PdfInkAnnotation] (pen or highlighter).
  ink,

  /// A [PdfRectAnnotation] laid down by the rectangle tool.
  rect,

  /// A [PdfStampAnnotation].
  stamp,

  /// A [PdfTextAnnotation]. Appended last, so the ordinals of the kinds
  /// that shipped before it, and with them every existing order, are
  /// unchanged.
  text,
}

/// One step of a page's unified paint sequence: a single committed
/// annotation, of whatever kind, together with the keys that place it in
/// the page's creation order.
sealed class PdfAnnotationPaintEntry {
  const PdfAnnotationPaintEntry({required this.indexInKind});

  /// Index of this annotation within the controller's own list for its
  /// kind. The last tie-break of [comparePaintEntries], and the reason
  /// that comparator is total.
  final int indexInKind;

  /// Which kind this entry paints.
  PdfAnnotationPaintKind get kind;

  /// Creation timestamp: the primary sort key.
  DateTime get createdAt;

  /// The annotation's id for sorting purposes. A `null` or empty id
  /// compares as the empty string, so a legacy annotation that predates
  /// ids still has a defined position.
  String get sortId;
}

/// A committed ink stroke's step in the sequence.
final class PdfInkPaintEntry extends PdfAnnotationPaintEntry {
  /// Wraps [stroke], which sits at [indexInKind] of the controller's
  /// stroke list.
  const PdfInkPaintEntry(this.stroke, {required super.indexInKind});

  /// The stroke to paint.
  final PdfInkAnnotation stroke;

  @override
  PdfAnnotationPaintKind get kind => PdfAnnotationPaintKind.ink;

  @override
  DateTime get createdAt => stroke.createdAt;

  @override
  String get sortId => stroke.id ?? '';
}

/// A laid rectangle's step in the sequence.
final class PdfRectPaintEntry extends PdfAnnotationPaintEntry {
  /// Wraps [rect], which sits at [indexInKind] of the controller's
  /// rectangle list.
  const PdfRectPaintEntry(this.rect, {required super.indexInKind});

  /// The rectangle to paint.
  final PdfRectAnnotation rect;

  @override
  PdfAnnotationPaintKind get kind => PdfAnnotationPaintKind.rect;

  @override
  DateTime get createdAt => rect.createdAt;

  @override
  String get sortId => rect.id;
}

/// A placed stamp's step in the sequence.
final class PdfStampPaintEntry extends PdfAnnotationPaintEntry {
  /// Wraps [stamp], which sits at [indexInKind] of the controller's
  /// stamp list.
  const PdfStampPaintEntry(this.stamp, {required super.indexInKind});

  /// The stamp to paint.
  final PdfStampAnnotation stamp;

  @override
  PdfAnnotationPaintKind get kind => PdfAnnotationPaintKind.stamp;

  @override
  DateTime get createdAt => stamp.createdAt;

  @override
  String get sortId => stamp.id;
}

/// A text annotation's step in the sequence.
final class PdfTextPaintEntry extends PdfAnnotationPaintEntry {
  /// Wraps [text], which sits at [indexInKind] of the controller's text
  /// annotation list.
  const PdfTextPaintEntry(this.text, {required super.indexInKind});

  /// The text annotation to paint.
  final PdfTextAnnotation text;

  @override
  PdfAnnotationPaintKind get kind => PdfAnnotationPaintKind.text;

  @override
  DateTime get createdAt => text.createdAt;

  @override
  String get sortId => text.id;
}

/// Orders two paint entries so that the one created later paints over
/// the one created earlier, whatever their kinds.
///
/// The order is **total**, which is a requirement rather than a
/// nicety: [PdfInkAnnotation.id] is nullable and `List.sort` is not
/// stable, so a partial comparator would let a shape cover a stroke on
/// one device and not on another. The keys, in order:
///
/// 1. `createdAt` ascending. Annotations that carry the Unix-epoch
///    sentinel (a decoded entry whose JSON had no timestamp) tie with
///    each other and sit under anything carrying a real timestamp.
/// 2. `sortId`, with a `null` or empty id compared as the empty string.
/// 3. The kind ordinal, [PdfAnnotationPaintKind].
/// 4. The index within the controller's list for that kind.
///
/// The last two exist so two legacy strokes that share the sentinel and
/// carry no id still paint in a reproducible order on every client and
/// on every frame.
///
/// Accepted consequence: a multi-segment ink entry expands to ids of the
/// form `'<id>#<i>'`, which sort lexicographically, so segment `#10`
/// paints under segment `#2`. Segments of one entry share a `createdAt`
/// and are contiguous fragments of a single stroke, so their relative
/// order is not observable.
int comparePaintEntries(PdfAnnotationPaintEntry a, PdfAnnotationPaintEntry b) {
  final byCreatedAt = a.createdAt.compareTo(b.createdAt);
  if (byCreatedAt != 0) return byCreatedAt;
  final bySortId = a.sortId.compareTo(b.sortId);
  if (bySortId != 0) return bySortId;
  final byKind = a.kind.index.compareTo(b.kind.index);
  if (byKind != 0) return byKind;
  return a.indexInKind.compareTo(b.indexInKind);
}

/// Every committed annotation anchored to [pageIndex], as the one
/// creation-ordered sequence the page painter walks, earliest first.
///
/// [strokes], [rects], [stamps] and [texts] are the controller's own lists; an
/// entry's position in them becomes its
/// [PdfAnnotationPaintEntry.indexInKind], so the result is reproducible
/// for identical inputs.
List<PdfAnnotationPaintEntry> buildPageAnnotationPaintSequence({
  required int pageIndex,
  required List<PdfInkAnnotation> strokes,
  required List<PdfStampAnnotation> stamps,
  List<PdfRectAnnotation> rects = const [],
  List<PdfTextAnnotation> texts = const [],
}) {
  final entries = <PdfAnnotationPaintEntry>[];
  for (var i = 0; i < strokes.length; i++) {
    if (strokes[i].pageIndex != pageIndex) continue;
    entries.add(PdfInkPaintEntry(strokes[i], indexInKind: i));
  }
  for (var i = 0; i < rects.length; i++) {
    if (rects[i].pageIndex != pageIndex) continue;
    entries.add(PdfRectPaintEntry(rects[i], indexInKind: i));
  }
  for (var i = 0; i < stamps.length; i++) {
    if (stamps[i].pageIndex != pageIndex) continue;
    entries.add(PdfStampPaintEntry(stamps[i], indexInKind: i));
  }
  for (var i = 0; i < texts.length; i++) {
    if (texts[i].pageIndex != pageIndex) continue;
    entries.add(PdfTextPaintEntry(texts[i], indexInKind: i));
  }
  entries.sort(comparePaintEntries);
  return entries;
}
