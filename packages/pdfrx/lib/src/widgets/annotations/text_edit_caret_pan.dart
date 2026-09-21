import 'dart:ui';

/// Room kept between the caret and the top of the on-screen keyboard, in
/// logical pixels, so the line being typed is not flush against it.
const double kTextEditCaretPanMargin = 24.0;

/// How far the view has to move, in logical pixels along y, for the caret
/// of the inline text editor to stay clear of the on-screen keyboard.
///
/// [caret] is the caret in viewer-local coordinates **as the view stood
/// when the edit started**, so the answer is absolute, not a step from
/// wherever an earlier answer left the view. [visibleBottom] is where the
/// keyboard's top edge cuts the viewer, in the same coordinates (the
/// viewer's own height when there is no keyboard).
///
/// The answer is never positive: the view only ever lifts, and it is
/// exactly `0` when the keyboard does not cover the caret, which is what
/// keeps the view still with a hardware keyboard, and brings it back by
/// itself when the on-screen keyboard goes away mid-edit. Only the
/// caret's bottom counts, because that is where the next character
/// lands: a caret taller than the room left keeps its bottom in view.
double textEditCaretPanShift({
  required Rect caret,
  required double visibleBottom,
  double margin = kTextEditCaretPanMargin,
}) {
  final overlap = caret.bottom + margin - visibleBottom;
  return overlap <= 0 ? 0 : -overlap;
}
