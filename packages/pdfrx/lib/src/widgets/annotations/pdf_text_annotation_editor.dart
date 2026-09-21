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
/// widget reports what is typed through [onChanged] and where the caret
/// is through [onCaretChanged], asks for a commit through [onCommit], and
/// does nothing when it merely loses focus. It asks for a commit on:
///
/// - Escape;
/// - a back press (the Android back button), through a [PopScope] it
///   holds for as long as it is mounted, which is as long as the edit is
///   in progress: that press only commits and never pops the route;
/// - the on-screen keyboard going away (see `_onKeyboardGone`);
/// - the app being paused, so typed text is not lost with the process.
class PdfTextAnnotationEditor extends StatefulWidget {
  const PdfTextAnnotationEditor({
    required this.initialText,
    required this.style,
    required this.align,
    required this.cursorWidth,
    required this.onChanged,
    required this.onCaretChanged,
    required this.onCommit,
    super.key,
  });

  final String initialText;
  final TextStyle style;
  final PdfTextAnnotationAlign align;
  final double cursorWidth;
  final ValueChanged<String> onChanged;

  /// Extent offset of the selection, whenever it moves.
  final ValueChanged<int> onCaretChanged;

  /// Asks the caller to commit the edit. May be called when the edit is
  /// already over, so the caller's commit must be idempotent.
  final VoidCallback onCommit;

  @override
  State<PdfTextAnnotationEditor> createState() => _PdfTextAnnotationEditorState();
}

class _PdfTextAnnotationEditorState extends State<PdfTextAnnotationEditor> with WidgetsBindingObserver {
  late final TextEditingController _text = TextEditingController(text: widget.initialText);
  final FocusNode _focus = FocusNode(debugLabel: 'PdfTextAnnotationEditor');

  /// The keyboard inset last seen, to tell the keyboard going away (a
  /// fall to zero) from there never having been one.
  double _keyboardInset = 0;
  ModalRoute<Object?>? _route;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _text.addListener(_reportCaret);
    // Requested rather than left to `autofocus`, which yields to whatever
    // already holds the focus in the scope (the host's key listener).
    _focus.requestFocus();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    final gone = _keyboardInset > 0 && inset <= 0;
    _keyboardInset = inset;
    // Not from here: this runs during a build, and a commit notifies
    // widgets that are not allowed to rebuild in the middle of one.
    if (gone) WidgetsBinding.instance.addPostFrameCallback((_) => _onKeyboardGone());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) widget.onCommit();
  }

  void _reportCaret() {
    final offset = _text.selection.extentOffset;
    if (offset >= 0) widget.onCaretChanged(offset);
  }

  /// The on-screen keyboard went away: its inset fell back to zero.
  ///
  /// That commits when the USER sent it away, and must not when it went
  /// because something else took the focus, a toolbar popup above all (a
  /// `PopupMenuButton` pushes a route, the editor loses the focus, the
  /// keyboard closes; when the popup closes the editor gets both back).
  /// The two are told apart by who holds the focus once the keyboard is
  /// gone:
  ///
  /// - Android's back gesture and its keyboard's own hide key close the
  ///   keyboard and leave the focus on the editor;
  /// - the dismiss key of the iOS keyboard closes the input connection,
  ///   which makes `EditableText` unfocus itself: the focus falls back to
  ///   the enclosing scope, and nothing else claims it;
  /// - a popup, or another field, holds the focus itself, and a popup
  ///   also leaves this editor's route no longer the current one.
  ///
  /// With a hardware keyboard there is no inset, so none of this runs. A
  /// host whose `Scaffold` resizes for the keyboard strips the inset from
  /// the `MediaQuery` below it, so it never runs there either.
  void _onKeyboardGone() {
    if (!mounted || _keyboardInset > 0) return;
    if (_route?.isCurrent == false) return;
    final focused = FocusManager.instance.primaryFocus;
    final nothingElseTookTheFocus = focused == null || focused == _focus || focused is FocusScopeNode;
    if (nothingElseTookTheFocus) widget.onCommit();
  }

  @override
  Widget build(BuildContext context) {
    // Annotation text is measured in PDF points and scales with the page
    // zoom only: it does not follow the operating system's text scale.
    return PopScope(
      // Held for as long as the edit is in progress: a back press only
      // commits. The commit unmounts this editor, and back is the
      // route's again.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.onCommit();
      },
      child: MediaQuery.withNoTextScaling(
        child: CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): widget.onCommit},
          child: _buildField(),
        ),
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
