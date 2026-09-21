import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pdf_text_annotation.dart';

/// The most characters the inline editor lets a text annotation hold.
///
/// It is a cap on INPUT only. A stored text that is longer (written by
/// another producer, or by a build with a higher cap) is rendered in
/// full and is never truncated, including by editing it.
const int kMaxTextAnnotationLength = 2000;

/// Gap `RenderEditable` keeps between the text and the edge of its box so
/// the caret has somewhere to go past the last glyph of a full line. The
/// framework keeps it private (`_kCaretGap`); it is restated here because
/// the editor's box has to be that much wider than the width its text
/// must wrap at.
const double _kEditableCaretGap = 1.0;

/// Refuses any edit that would leave more than [maxLength] characters,
/// without ever shortening what is already there.
///
/// `LengthLimitingTextInputFormatter` is not used because it truncates:
/// fed a stored text that is already over the cap, its first keystroke
/// would cut the text down to the cap. Here an over-long text can still
/// be edited down, a character at a time, and only growth is refused.
class PdfTextAnnotationLengthFormatter extends TextInputFormatter {
  const PdfTextAnnotationLengthFormatter([this.maxLength = kMaxTextAnnotationLength]);

  final int maxLength;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final newLength = newValue.text.characters.length;
    if (newLength <= maxLength) return newValue;
    if (newLength < oldValue.text.characters.length) return newValue;
    return oldValue;
  }
}

/// The width an editor box needs for its text to wrap at exactly
/// [wrapWidth], given the caret's width.
///
/// `RenderEditable` lays its text out at its own width minus the caret
/// margin. The sum is nudged up when float rounding would make that
/// subtraction land a hair under [wrapWidth], which would wrap a line
/// that fits exactly.
double textEditorWidthFor(double wrapWidth, {required double cursorWidth}) {
  final margin = _kEditableCaretGap + cursorWidth;
  var width = wrapWidth + margin;
  if (width - margin < wrapWidth) width += wrapWidth * 1e-12;
  return width;
}

/// The inline editor of a text annotation: a real text input, laid out
/// in PDF points by the caller's transform.
///
/// It is built from the very `TextStyle` the layout function paints the
/// committed text with, with no decoration, no padding, no strut and no
/// text scaling, so the text does not move when the edit commits.
///
/// Committing is the caller's business and is never focus-driven: this
/// widget reports what is typed through [onChanged] and an Escape press
/// through [onEscape], and does nothing when it loses focus.
class PdfTextAnnotationEditor extends StatefulWidget {
  const PdfTextAnnotationEditor({
    required this.initialText,
    required this.style,
    required this.align,
    required this.cursorWidth,
    required this.onChanged,
    required this.onEscape,
    super.key,
  });

  final String initialText;
  final TextStyle style;
  final PdfTextAnnotationAlign align;
  final double cursorWidth;
  final ValueChanged<String> onChanged;
  final VoidCallback onEscape;

  @override
  State<PdfTextAnnotationEditor> createState() => _PdfTextAnnotationEditorState();
}

class _PdfTextAnnotationEditorState extends State<PdfTextAnnotationEditor> {
  late final TextEditingController _text = TextEditingController(text: widget.initialText);
  final FocusNode _focus = FocusNode(debugLabel: 'PdfTextAnnotationEditor');

  @override
  void initState() {
    super.initState();
    // Requested rather than left to `autofocus`, which yields to whatever
    // already holds the focus in the scope (the host's key listener).
    _focus.requestFocus();
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Annotation text is measured in PDF points and scales with the page
    // zoom only: it does not follow the operating system's text scale.
    return MediaQuery.withNoTextScaling(
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): widget.onEscape},
        child: _buildField(),
      ),
    );
  }

  Widget _buildField() {
    return Material(
      type: MaterialType.transparency,
      child: TextField(
        controller: _text,
        focusNode: _focus,
        style: widget.style,
        strutStyle: StrutStyle.disabled,
        textAlign: switch (widget.align) {
          PdfTextAnnotationAlign.left => TextAlign.left,
          PdfTextAnnotationAlign.center => TextAlign.center,
          PdfTextAnnotationAlign.right => TextAlign.right,
        },
        textAlignVertical: TextAlignVertical.top,
        textDirection: TextDirection.ltr,
        decoration: const InputDecoration.collapsed(hintText: null),
        // Enter is a newline. Nothing the keyboard does commits.
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        maxLines: null,
        expands: true,
        // Musical abbreviations are not typos: "rit.", "cresc.", "D.S.".
        autocorrect: false,
        enableSuggestions: false,
        textCapitalization: TextCapitalization.none,
        inputFormatters: const [PdfTextAnnotationLengthFormatter()],
        cursorWidth: widget.cursorWidth,
        cursorColor: widget.style.color,
        scrollPadding: EdgeInsets.zero,
        scrollPhysics: const NeverScrollableScrollPhysics(),
        // A tap on the toolbar must leave the caret and the keyboard
        // where they are; a tap on the score is the layer's to commit.
        onTapOutside: (_) {},
        onChanged: widget.onChanged,
      ),
    );
  }
}
