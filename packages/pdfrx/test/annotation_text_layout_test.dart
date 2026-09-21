import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/annotation_text_layout.dart';
import 'package:pdfrx/src/widgets/annotations/pdf_text_annotation.dart';

// `flutter test` draws every glyph, the space included, as a 1 em square
// (the Ahem-style test font), so at 10 pt a character is 10 wide and a
// line is 10 tall. Every size below is exact arithmetic on that.
const TextStyle _style = TextStyle(fontSize: 10);
const Size _page = Size(200, 300);

final DateTime _t = DateTime.utc(2026, 1, 1);

PdfTextAnnotation _annotation(
  String text, {
  required Rect rect,
  bool autoSize = true,
  double rotationDeg = 0,
  PdfTextAnnotationAlign align = PdfTextAnnotationAlign.left,
  String? fontFamily,
  bool bold = false,
  bool italic = false,
  bool underline = false,
}) => PdfTextAnnotation(
  id: 'text',
  pageIndex: 0,
  rectInPdfSpace: rect,
  rotationDeg: rotationDeg,
  text: text,
  fontSize: 10,
  fontFamily: fontFamily,
  bold: bold,
  italic: italic,
  underline: underline,
  align: align,
  autoSize: autoSize,
  createdAt: _t,
  updatedAt: _t,
);

PdfTextDisplayBox _boxOf(PdfTextAnnotation annotation, {Size pageSize = _page}) => computeTextDisplayBox(
  annotation: annotation,
  pageSize: pageSize,
  layout: layoutAnnotationText(
    text: annotation.text,
    style: _style,
    align: annotation.align,
    wrapWidth: textAnnotationWrapWidth(annotation, pageSize: pageSize),
  ),
);

List<String> _linesOf(PdfAnnotationTextLayout layout, String text) => [
  for (final line in layout.lineRanges) text.substring(line.start, line.end).trimRight(),
];

void main() {
  group('layoutAnnotationText', () {
    test('a box hugs its content', () {
      final oneLine = layoutAnnotationText(
        text: 'abcd',
        style: _style,
        align: PdfTextAnnotationAlign.left,
        wrapWidth: null,
      );
      expect(oneLine.size, const Size(40, 10));

      final twoLines = layoutAnnotationText(
        text: 'ab\ncdef',
        style: _style,
        align: PdfTextAnnotationAlign.left,
        wrapWidth: null,
      );
      expect(twoLines.size, const Size(40, 20));
    });

    test('a width change rewraps', () {
      const text = 'aaaa bbbb';
      final wide = layoutAnnotationText(text: text, style: _style, align: PdfTextAnnotationAlign.left, wrapWidth: 100);
      expect(wide.size, const Size(90, 10));
      expect(_linesOf(wide, text), ['aaaa bbbb']);

      final narrow = layoutAnnotationText(text: text, style: _style, align: PdfTextAnnotationAlign.left, wrapWidth: 50);
      expect(narrow.size.height, 20);
      expect(_linesOf(narrow, text), ['aaaa', 'bbbb']);
    });

    test('the text does not follow the operating system text scale', () {
      final layout = layoutAnnotationText(
        text: 'abcd',
        style: _style,
        align: PdfTextAnnotationAlign.left,
        wrapWidth: null,
      );
      expect(layout.painter.textScaler, TextScaler.noScaling);
    });

    test('alignment positions the lines inside the hugging box', () {
      const text = 'aaaa\nbb';
      double leftOfSecondLine(PdfTextAnnotationAlign align) {
        final layout = layoutAnnotationText(text: text, style: _style, align: align, wrapWidth: null);
        expect(layout.size, const Size(40, 20), reason: 'alignment must never change the box');
        return layout.painter.computeLineMetrics()[1].left;
      }

      expect(leftOfSecondLine(PdfTextAnnotationAlign.left), 0);
      expect(leftOfSecondLine(PdfTextAnnotationAlign.center), 10);
      expect(leftOfSecondLine(PdfTextAnnotationAlign.right), 20);
    });
  });

  group('computeTextDisplayBox, auto-sized text', () {
    test('hugs its content whatever the stored box says', () {
      final box = _boxOf(_annotation('abcd', rect: const Rect.fromLTWH(20, 30, 7, 3)));
      expect(box.displayRect, const Rect.fromLTWH(20, 30, 40, 10));
    });

    test('does not wrap below the implicit maximum width', () {
      // Left edge at 100 on a 200 wide page: 100 of room, 90 of text.
      final box = _boxOf(_annotation('aaaa bbbb', rect: const Rect.fromLTWH(100, 30, 1, 1)));
      expect(box.displayRect, const Rect.fromLTWH(100, 30, 90, 10));
    });

    test('wraps at the distance from its left edge to the right page edge, and shrinks back', () {
      // Left edge at 150: 50 of room, so the 90 wide line wraps.
      final wrapped = _boxOf(_annotation('aaaa bbbb', rect: const Rect.fromLTWH(150, 30, 1, 1)));
      expect(wrapped.displayRect, const Rect.fromLTWH(150, 30, 40, 20));
      expect(wrapped.displayRect.right, lessThanOrEqualTo(_page.width));

      final shorter = _boxOf(_annotation('aaaa', rect: const Rect.fromLTWH(150, 30, 40, 20)));
      expect(shorter.displayRect, const Rect.fromLTWH(150, 30, 40, 10));
    });

    test('the implicit maximum width follows the page size, not the stored box', () {
      final annotation = _annotation('aaaa bbbb', rect: const Rect.fromLTWH(150, 30, 40, 20));
      expect(textAnnotationWrapWidth(annotation, pageSize: const Size(200, 300)), 50);
      expect(textAnnotationWrapWidth(annotation, pageSize: const Size(400, 300)), 250);
      expect(_boxOf(annotation, pageSize: const Size(400, 300)).displayRect, const Rect.fromLTWH(150, 30, 90, 10));
    });

    test('grows rightward and downward from its top-left corner whatever the alignment', () {
      for (final align in PdfTextAnnotationAlign.values) {
        final box = _boxOf(_annotation('aaaa\nbb', rect: const Rect.fromLTWH(20, 30, 1, 1), align: align));
        expect(box.displayRect, const Rect.fromLTWH(20, 30, 40, 20), reason: '$align');
        expect(box.textOffset, Offset.zero, reason: '$align');
      }
    });
  });

  group('computeTextDisplayBox, text area', () {
    test('wraps at its own width and is never shorter than its content', () {
      final box = _boxOf(_annotation('aaaa bbbb', rect: const Rect.fromLTWH(20, 30, 50, 10), autoSize: false));
      expect(box.displayRect, const Rect.fromLTWH(20, 30, 50, 20));
    });

    test('keeps a stored height larger than its content', () {
      final box = _boxOf(_annotation('aaaa bbbb', rect: const Rect.fromLTWH(20, 30, 50, 80), autoSize: false));
      expect(box.displayRect, const Rect.fromLTWH(20, 30, 50, 80));
    });

    test('alignment positions the block of lines inside the box', () {
      Offset offsetFor(PdfTextAnnotationAlign align) => _boxOf(
        _annotation('aaaa', rect: const Rect.fromLTWH(20, 30, 100, 40), autoSize: false, align: align),
      ).textOffset;

      expect(offsetFor(PdfTextAnnotationAlign.left), Offset.zero);
      expect(offsetFor(PdfTextAnnotationAlign.center), const Offset(30, 0));
      expect(offsetFor(PdfTextAnnotationAlign.right), const Offset(60, 0));
    });
  });

  group('computeTextDisplayBox, page edges', () {
    test('a box growing past the bottom edge is shifted up, in both modes', () {
      // Top at 295 on a 300 tall page, 20 of content.
      final auto = _boxOf(_annotation('aaaa\nbbbb', rect: const Rect.fromLTWH(20, 295, 1, 1)));
      expect(auto.displayRect, const Rect.fromLTWH(20, 280, 40, 20));

      final area = _boxOf(_annotation('aaaa bbbb', rect: const Rect.fromLTWH(20, 290, 50, 10), autoSize: false));
      expect(area.displayRect, const Rect.fromLTWH(20, 280, 50, 20));
    });

    test('a box taller than the page pins to the top and overflows the bottom', () {
      final text = List.filled(40, 'aa').join('\n'); // 400 tall on a 300 tall page.
      final box = _boxOf(_annotation(text, rect: const Rect.fromLTWH(20, 120, 1, 1)));
      expect(box.displayRect, const Rect.fromLTWH(20, 0, 20, 400));
    });

    test('a box that fits is not moved', () {
      final box = _boxOf(_annotation('aaaa', rect: const Rect.fromLTWH(20, 290, 1, 1)));
      expect(box.displayRect, const Rect.fromLTWH(20, 290, 40, 10));
    });

    test('the top-left corner of a rotated box stays where it was when the content grows', () {
      // Rotated a quarter turn, stored as 40 x 10, now holding two lines.
      const stored = Rect.fromLTWH(100, 100, 40, 10);
      final box = _boxOf(_annotation('aaaa\nbbbb', rect: stored, rotationDeg: 90));
      expect(box.displayRect.size, const Size(40, 20));

      Offset cornerOf(Rect rect) {
        // Counter-clockwise by 90 degrees on a y-down canvas: (x, y) -> (y, -x).
        final v = rect.topLeft - rect.center;
        return rect.center + Offset(v.dy, -v.dx);
      }

      expect(cornerOf(box.displayRect).dx, closeTo(cornerOf(stored).dx, 1e-9));
      expect(cornerOf(box.displayRect).dy, closeTo(cornerOf(stored).dy, 1e-9));
    });
  });

  group('resolveAnnotationTextStyle', () {
    const fonts = PdfAnnotationFonts(
      families: [
        PdfAnnotationFontFamily('Serif', styles: PdfAnnotationFontStyle.values),
        PdfAnnotationFontFamily('Hand', styles: [PdfAnnotationFontStyle.regular, PdfAnnotationFontStyle.bold]),
      ],
      defaultFamily: 'Serif',
    );

    TextStyle resolve({String? family, bool bold = false, bool italic = false, bool underline = false}) =>
        resolveAnnotationTextStyle(
          _annotation('a', rect: Rect.zero, fontFamily: family, bold: bold, italic: italic, underline: underline),
          fonts,
        );

    test('a family that has the real styles gets them', () {
      final style = resolve(family: 'Serif', bold: true, italic: true);
      expect(style.fontFamily, 'Serif');
      expect(style.fontWeight, FontWeight.w700);
      expect(style.fontStyle, FontStyle.italic);
      expect(style.fontSize, 10);
    });

    test('never synthesizes: a style the family lacks requests the regular face', () {
      final italicOnly = resolve(family: 'Hand', italic: true);
      expect(italicOnly.fontFamily, 'Hand');
      expect(italicOnly.fontWeight, FontWeight.w400);
      expect(italicOnly.fontStyle, FontStyle.normal);

      // Bold italic on a family with bold but no bold italic: the real
      // bold face, upright.
      final boldItalic = resolve(family: 'Hand', bold: true, italic: true);
      expect(boldItalic.fontWeight, FontWeight.w700);
      expect(boldItalic.fontStyle, FontStyle.normal);
    });

    test('a style the family lacks leaves the stored flags alone', () {
      final annotation = _annotation('a', rect: Rect.zero, fontFamily: 'Hand', italic: true);
      resolveAnnotationTextStyle(annotation, fonts);
      expect(annotation.italic, isTrue);
      expect(annotation.fontFamily, 'Hand');
    });

    test('an unknown or missing family renders in the default family', () {
      expect(resolve(family: 'Comic Sans MS', bold: true).fontFamily, 'Serif');
      expect(resolve(family: 'Comic Sans MS', bold: true).fontWeight, FontWeight.w700);
      expect(resolve().fontFamily, 'Serif');
    });

    test('with no families declared nothing is named and nothing is synthesized', () {
      final style = resolveAnnotationTextStyle(
        _annotation('a', rect: Rect.zero, fontFamily: 'Serif', bold: true, italic: true),
        const PdfAnnotationFonts.none(),
      );
      expect(style.fontFamily, isNull);
      expect(style.fontWeight, FontWeight.w400);
      expect(style.fontStyle, FontStyle.normal);
    });

    test('underline is a decoration, available to every family', () {
      expect(resolve(family: 'Hand', underline: true).decoration, TextDecoration.underline);
      expect(resolve(family: 'Hand').decoration, TextDecoration.none);
    });

    test('font sets compare by value, so a rebuilt params object is not a change', () {
      const again = PdfAnnotationFonts(
        families: [
          PdfAnnotationFontFamily('Serif', styles: PdfAnnotationFontStyle.values),
          PdfAnnotationFontFamily('Hand', styles: [PdfAnnotationFontStyle.regular, PdfAnnotationFontStyle.bold]),
        ],
        defaultFamily: 'Serif',
      );
      // ignore: prefer_const_constructors
      final rebuilt = PdfAnnotationFonts(families: [...again.families], defaultFamily: 'Serif');
      expect(rebuilt, fonts);
      expect(rebuilt.hashCode, fonts.hashCode);
      expect(const PdfAnnotationFonts(families: [], defaultFamily: 'Serif'), isNot(fonts));
    });
  });
}
