import 'dart:math' as math;
import 'dart:ui' hide TextStyle;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show TextStyle;

import 'annotation_paint_sequence.dart';
import 'annotation_text_layout.dart';
import 'instant_json.dart';
import 'pdf_ink_annotation.dart';
import 'pdf_rect_annotation.dart';
import 'pdf_stamp_annotation.dart';
import 'pdf_stamp_definition.dart';
import 'pdf_stamp_picture.dart';
import 'pdf_text_annotation.dart';
import 'selection_geometry.dart';

export 'selection_geometry.dart' show PdfAnnotationHandle, kMinAnnotationSizePts;

/// Active annotation tool while [PdfAnnotationController.annotationModeListenable]
/// is `true`.
enum PdfAnnotationTool {
  /// Default. Pan input creates new opaque round-capped ink strokes.
  pen,

  /// Pan input creates new translucent round-capped highlighter strokes.
  /// Color and width are tracked separately from the pen via
  /// [PdfAnnotationController.highlighterColor] / [PdfAnnotationController.highlighterWidth];
  /// opacity is sourced at draw time from `PdfViewerParams.highlighterOpacity`.
  highlighter,

  /// Pan input erases existing strokes that the current session owns.
  eraser,

  /// Tap input places the controller's current pending
  /// [PdfStampDefinition] onto the page (or selects/manipulates an
  /// existing stamp owned by the current creator).
  stamp,

  /// Press-and-drag rubber-bands a new opaque borderless
  /// [PdfRectAnnotation] over the page; a tap selects or deselects an
  /// existing one owned by the current creator.
  rectangle,

  /// A tap creates auto-sized text at the tap point and opens the inline
  /// editor; a press-and-drag rubber-bands a text area. A tap on an
  /// existing [PdfTextAnnotation] owned by the current creator selects
  /// it, and a second tap edits it.
  text,

  /// Navigation tool. Input is not captured by the annotation layer; the
  /// underlying viewer handles pan, scroll, tap, and pinch-zoom. No
  /// annotation is created.
  hand,
}

/// Legacy alias for [PdfAnnotationHandle], kept so the fork stays
/// mergeable with upstream pdfrx. The gizmo is shape-neutral now: the
/// same handles serve stamps and rectangles.
@Deprecated('Renamed to PdfAnnotationHandle now that the gizmo serves every annotation kind.')
typedef PdfStampHandle = PdfAnnotationHandle;

/// Legacy alias for [kMinAnnotationSizePts], kept so the fork stays
/// mergeable with upstream pdfrx.
@Deprecated('Renamed to kMinAnnotationSizePts now that the clamp serves every annotation kind.')
const double kMinStampSizePts = kMinAnnotationSizePts;

/// Internal annotation state for a `PdfViewer`. Owns the list of strokes,
/// the annotation-mode flag, and the in-flight stroke buffer.
///
/// Not exported from `pdfrx.dart`. Public access goes through
/// `PdfViewerController`'s annotation methods.
class PdfAnnotationController extends ChangeNotifier {
  /// Default longest-side size (PDF points) used by [placeStamp] when
  /// the caller does not override the placement bbox.
  static const double _kDefaultStampLongestSidePts = 36.0;

  /// Fill a rectangle takes when the caller does not choose one. White,
  /// so the tool reads as correction fluid on a printed score.
  static const Color kDefaultRectFillColor = Color(0xFFFFFFFF);

  final List<PdfInkAnnotation> _strokes = [];
  final List<PdfStampAnnotation> _stamps = [];
  final List<PdfRectAnnotation> _rects = [];

  /// Text annotations. Until the Text tool lands they are only ever
  /// imported, held and exported, which is already load-bearing: the
  /// decoder recognises `pspdfkit/text`, so such an entry no longer
  /// travels in [_unknowns], and every path below that carries rectangles
  /// must carry these too or an export silently deletes them.
  final List<PdfTextAnnotation> _texts = [];

  /// Imported entries whose `type` this build does not recognise, held
  /// verbatim so an export puts them back (see
  /// [DecodedInstantJson.unknowns]). They are never painted, never
  /// selectable and never editable: the controller is their custodian,
  /// not their editor. Without this the viewer would quietly strip a
  /// newer client's annotation kind from every document it re-exported.
  final List<Map<String, dynamic>> _unknowns = [];
  final Map<String, PdfStampAttachment> _attachments = {};
  final ValueNotifier<bool> _modeListenable = ValueNotifier<bool>(false);
  final ValueNotifier<int> _inFlightTick = ValueNotifier<int>(0);
  final ValueNotifier<int> _eraserCursorTick = ValueNotifier<int>(0);
  final ValueNotifier<int> _stampDragTick = ValueNotifier<int>(0);
  final ValueNotifier<PdfAnnotationTool> _toolListenable = ValueNotifier<PdfAnnotationTool>(PdfAnnotationTool.pen);
  final ValueNotifier<Color> _strokeColor = ValueNotifier<Color>(const Color(0xFFFF3B30));
  final ValueNotifier<double> _strokeWidth = ValueNotifier<double>(2.0);
  final ValueNotifier<Color> _highlighterColor = ValueNotifier<Color>(const Color(0xFFFFFF00));
  final ValueNotifier<double> _highlighterWidth = ValueNotifier<double>(12.0);
  final ValueNotifier<double> _eraserRadius = ValueNotifier<double>(10.0);
  final ValueNotifier<Color> _rectFillColor = ValueNotifier<Color>(kDefaultRectFillColor);
  final ValueNotifier<PdfStampDefinition?> _pendingStamp = ValueNotifier<PdfStampDefinition?>(null);
  final ValueNotifier<String?> _selectedStampId = ValueNotifier<String?>(null);
  final ValueNotifier<String?> _selectedRectId = ValueNotifier<String?>(null);
  final ValueNotifier<String?> _selectedTextId = ValueNotifier<String?>(null);
  final ValueNotifier<String?> _editingTextId = ValueNotifier<String?>(null);
  final ValueNotifier<int> _textEditTick = ValueNotifier<int>(0);
  final PdfStampPictureCache _stampPictures = PdfStampPictureCache();
  final Map<int, List<PdfAnnotationPaintEntry>> _paintSequences = <int, List<PdfAnnotationPaintEntry>>{};
  final Map<String, _MemoizedTextLayout> _textLayouts = <String, _MemoizedTextLayout>{};
  PdfAnnotationFonts _annotationFonts = const PdfAnnotationFonts.none();
  PdfAnnotationTextLayouter _textLayouter = layoutAnnotationText;
  final List<_AnnotationSnapshot> _undoStack = [];
  final List<_AnnotationSnapshot> _redoStack = [];
  final ValueNotifier<bool> _canUndo = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _canRedo = ValueNotifier<bool>(false);

  String? _currentCreator;
  _InFlightStroke? _inFlight;
  Offset? _eraserPrevPoint;
  int? _eraserPrevPage;
  _ShapeDragState? _stampDragState;
  _ShapeDragState? _rectDragState;
  _RectDraft? _rectDraft;
  _TextAreaDraft? _textDraft;
  _TextEditSession? _textEdit;
  final Map<int, _PageLayoutInfo> _pageLayouts = {};

  /// Bumps on every [appendPoint] so the live-drawing layer can repaint
  /// without rebuilding the committed-strokes painter.
  Listenable get inFlightChangedListenable => _inFlightTick;

  /// Bumps on every eraser pan transition (start, move, end) so the
  /// layer can repaint the eraser cursor preview without doing any other
  /// state work.
  Listenable get eraserCursorChangedListenable => _eraserCursorTick;

  /// PDF-point-space coordinate of the most recent eraser sample, or
  /// `null` while no eraser pan is in progress.
  Offset? get eraserCursorPdfPoint => _eraserPrevPoint;

  /// Page index of the currently-active eraser pan, or `null` while no
  /// eraser pan is in progress.
  int? get eraserCursorPageIndex => _eraserPrevPage;

  /// The page index of the in-flight stroke, or `null` if no stroke is
  /// currently being drawn. Exposed for the per-page gesture detector so it
  /// can ignore secondary pointers landing on a different page while a
  /// stroke is in progress.
  int? get inFlightPageIndex => _inFlight?.pageIndex;

  /// `true` while the viewer is in annotation drawing mode.
  ///
  /// Listenable so callers can show/hide overlays in lock-step with mode
  /// changes without polling.
  ValueListenable<bool> get annotationModeListenable => _modeListenable;

  /// Active tool while [annotationModeListenable] is `true`. Persists
  /// across mode toggles — calling [enterMode] without a `tool` override
  /// keeps whatever tool was last selected.
  ValueListenable<PdfAnnotationTool> get currentToolListenable => _toolListenable;

  /// Pen-scoped stroke color applied to every new ink stroke when the
  /// active tool is [PdfAnnotationTool.pen] (the layer reads this at
  /// pan-start and bakes it into the committed annotation). The
  /// highlighter has its own [highlighterColorListenable] — switching
  /// tools does not clobber the other tool's settings. Persists across
  /// `enterMode` / `exitMode` cycles.
  ValueListenable<Color> get strokeColorListenable => _strokeColor;

  /// Current pen stroke color value. See [strokeColorListenable] for
  /// change notifications.
  Color get strokeColor => _strokeColor.value;

  /// Pen-scoped stroke width (PDF points) applied to every new ink
  /// stroke when the active tool is [PdfAnnotationTool.pen]. The
  /// highlighter has its own [highlighterWidthListenable]. Persists
  /// across `enterMode` / `exitMode` cycles.
  ValueListenable<double> get strokeWidthListenable => _strokeWidth;

  /// Current pen stroke width value. See [strokeWidthListenable] for
  /// change notifications.
  double get strokeWidth => _strokeWidth.value;

  /// Highlighter-scoped stroke color applied to every new highlighter
  /// stroke (the layer reads this at pan-start and bakes it into the
  /// committed annotation). Persists across `enterMode` / `exitMode`
  /// cycles.
  ValueListenable<Color> get highlighterColorListenable => _highlighterColor;

  /// Current highlighter color value. See [highlighterColorListenable]
  /// for change notifications.
  Color get highlighterColor => _highlighterColor.value;

  /// Highlighter-scoped stroke width (PDF points) applied to every new
  /// highlighter stroke. Persists across `enterMode` / `exitMode`
  /// cycles.
  ValueListenable<double> get highlighterWidthListenable => _highlighterWidth;

  /// Current highlighter width value. See [highlighterWidthListenable]
  /// for change notifications.
  double get highlighterWidth => _highlighterWidth.value;

  /// Hit radius (PDF points) used by the eraser tool to decide whether a
  /// stroke segment is touched, and the size of the on-screen eraser
  /// cursor preview. Persists across `enterMode` / `exitMode` cycles.
  ValueListenable<double> get eraserRadiusListenable => _eraserRadius;

  /// Current eraser radius value. See [eraserRadiusListenable] for change
  /// notifications.
  double get eraserRadius => _eraserRadius.value;

  /// Rectangle-scoped fill color baked into every new rectangle
  /// ([startRectDraft] reads it when the caller passes no explicit
  /// `fillColor`). The pen and highlighter keep their own colors, so
  /// switching tools never clobbers another tool's setting. Persists
  /// across `enterMode` / `exitMode` cycles, not across app sessions.
  ValueListenable<Color> get rectFillColorListenable => _rectFillColor;

  /// Current rectangle fill color value. Always fully opaque: the tool
  /// exposes no opacity control. See [rectFillColorListenable] for
  /// change notifications.
  Color get rectFillColor => _rectFillColor.value;

  /// The stamp library entry currently armed for placement, or `null`
  /// when no stamp is pending. While non-null and the active tool is
  /// [PdfAnnotationTool.stamp], a tap on a page places this stamp.
  ValueListenable<PdfStampDefinition?> get pendingStampListenable => _pendingStamp;

  /// `id` of the currently-selected placed stamp, or `null` when no
  /// stamp is selected. Only stamps owned by the current creator can
  /// become selected.
  ValueListenable<String?> get selectedStampIdListenable => _selectedStampId;

  /// Bumps on every stamp drag delta (move/resize/rotate) so the layer
  /// can repaint affordances live without flushing the main listener.
  Listenable get stampDragChangedListenable => _stampDragTick;

  /// Bumps when a stamp attachment finishes decoding into a paintable
  /// picture. The page painter is synchronous and skips stamps it cannot
  /// draw yet, so the canvas must be invalidated when one arrives.
  Listenable get stampPicturesChangedListenable => _stampPictures.changedListenable;

  /// The decoder turning stamp attachment bytes into paintable pictures.
  ///
  /// Sourced by the `PdfViewer` from `PdfViewerParams.stampPictureDecoder`
  /// on attach and whenever the params change, falling back to the
  /// package's own [decodeStampPictureWithVectorGraphics]. Held here
  /// rather than read from the params because the cache's lifetime is
  /// the controller's, and this class has no reference to the params.
  ///
  /// Idempotent: re-setting the same decoder keeps the cache; a
  /// different one invalidates everything the previous one produced.
  set stampPictureDecoder(PdfStampPictureDecoder value) => _stampPictures.decoder = value;

  /// The decoded picture for the attachment [sha], or `null` when it has
  /// not been decoded. The painter draws only non-null entries.
  PdfDecodedStampPicture? stampPictureFor(String sha) => _stampPictures[sha];

  /// Schedules a decode of the attachment [sha] if it is not already
  /// decoded, in flight, or known to be undecodable. No-op when no
  /// attachment is stored under [sha].
  ///
  /// Called by the painter when it meets a stamp it cannot draw yet;
  /// [setAllWithStamps] pre-warms every referenced attachment so that
  /// path is rarely taken.
  void ensureStampPictureDecoded(String sha) {
    final attachment = _attachments[sha];
    if (attachment == null) return;
    _stampPictures.ensureDecoded(sha: sha, bytes: attachment.bytes, contentType: attachment.contentType);
  }

  /// The page's committed annotations of every kind, in the single
  /// creation-ordered sequence the page painter walks. Built once per
  /// content change and cached per page: `_invalidate` fires on every
  /// pointer sample of a stroke, so sorting on each paint would put
  /// O(n log n) work on every frame of every drag.
  ///
  /// The in-flight stroke is not part of this sequence; the painter
  /// draws it last, on top.
  List<PdfAnnotationPaintEntry> paintSequenceForPage(int pageIndex) => _paintSequences.putIfAbsent(
    pageIndex,
    () => buildPageAnnotationPaintSequence(
      pageIndex: pageIndex,
      strokes: _strokes,
      stamps: _stamps,
      rects: _rects,
      texts: _texts,
    ),
  );

  /// The font families text annotations resolve their stored family name
  /// against, and the default one.
  ///
  /// Sourced by the `PdfViewer` from `PdfViewerParams.annotationFonts`,
  /// the way [stampPictureDecoder] is and for the same reason. Compared
  /// by value: re-setting an equal set keeps every memoized layout, a
  /// different one drops them all and repaints.
  PdfAnnotationFonts get annotationFonts => _annotationFonts;
  set annotationFonts(PdfAnnotationFonts value) {
    if (value == _annotationFonts) return;
    _annotationFonts = value;
    invalidateTextLayouts();
  }

  /// Replaces the layout seam, so a test can count the calls that reach
  /// it or stand in for a device whose fonts measure differently.
  @visibleForTesting
  set textLayouter(PdfAnnotationTextLayouter value) {
    _textLayouter = value;
    _clearTextLayouts();
  }

  /// How many annotations currently hold a memoized layout.
  @visibleForTesting
  int get memoizedTextLayoutCount => _textLayouts.length;

  /// Drops every memoized text layout and repaints. For what changes how
  /// text measures without changing any annotation: the font set, or a
  /// font that finished loading.
  void invalidateTextLayouts() {
    _clearTextLayouts();
    notifyListeners();
  }

  void _clearTextLayouts() {
    for (final memo in _textLayouts.values) {
      memo.dispose();
    }
    _textLayouts.clear();
  }

  /// Where [text] is painted on a page of [pageSize] (PDF points): its
  /// display box, derived from the stored box with this device's
  /// metrics, and the laid-out text.
  ///
  /// The display box is never written back into
  /// [PdfTextAnnotation.rectInPdfSpace] from here. Rendering is not an
  /// edit: an export after a mere paint re-emits the stored box, so a
  /// device whose metrics differ by a fraction of a point never rewrites
  /// an element it did not touch.
  ///
  /// Memoized per annotation id. Laying text out is the expensive part
  /// and reruns only when the text, the resolved style, the alignment or
  /// the wrap width changed; the box arithmetic on top of it also reruns
  /// when the stored box, the rotation, the sizing mode or the page size
  /// did.
  PdfTextDisplayBox textDisplayBoxFor(PdfTextAnnotation text, {required Size pageSize}) {
    final style = resolveAnnotationTextStyle(text, _annotationFonts);
    final wrapWidth = textAnnotationWrapWidth(text, pageSize: pageSize);
    var memo = _textLayouts[text.id];
    if (memo == null ||
        memo.text != text.text ||
        memo.style != style ||
        memo.align != text.align ||
        memo.wrapWidth != wrapWidth) {
      memo?.dispose();
      memo = _textLayouts[text.id] = _MemoizedTextLayout(
        text: text.text,
        style: style,
        align: text.align,
        wrapWidth: wrapWidth,
        layout: _textLayouter(text: text.text, style: style, align: text.align, wrapWidth: wrapWidth),
      );
    }
    final box = memo.box;
    if (box != null &&
        memo.storedRect == text.rectInPdfSpace &&
        memo.rotationDeg == text.rotationDeg &&
        memo.autoSize == text.autoSize &&
        memo.pageSize == pageSize) {
      return box;
    }
    memo
      ..storedRect = text.rectInPdfSpace
      ..rotationDeg = text.rotationDeg
      ..autoSize = text.autoSize
      ..pageSize = pageSize;
    return memo.box = computeTextDisplayBox(annotation: text, pageSize: pageSize, layout: memo.layout);
  }

  /// Forgets the layouts of annotations that are no longer held. Cheap
  /// enough to run with every content change: it walks the memo, which is
  /// empty until a text annotation has been painted.
  void _pruneTextLayouts() {
    if (_textLayouts.isEmpty) return;
    final live = {for (final t in _texts) t.id, ?_textEdit?.working.id};
    _textLayouts.removeWhere((id, memo) {
      if (live.contains(id)) return false;
      memo.dispose();
      return true;
    });
  }

  /// Read-only view of the placed stamp annotations.
  List<PdfStampAnnotation> get stamps => List.unmodifiable(_stamps);

  /// Read-only view of the placed rectangle annotations.
  List<PdfRectAnnotation> get rects => List.unmodifiable(_rects);

  /// Read-only view of the text annotations.
  List<PdfTextAnnotation> get texts => List.unmodifiable(_texts);

  /// Read-only view of the attachment store (sha256 → bytes + content
  /// type). Bytes referenced by at least one stamp are emitted under
  /// the document's `attachments` map at export time.
  Map<String, PdfStampAttachment> get attachments => Map.unmodifiable(_attachments);

  /// `true` while the undo stack has at least one snapshot. Wire to
  /// disabled-state UI; calling [undo] when this is `false` is a no-op.
  ValueListenable<bool> get canUndoListenable => _canUndo;

  /// `true` while the redo stack has at least one snapshot. Wire to
  /// disabled-state UI; calling [redo] when this is `false` is a no-op.
  ValueListenable<bool> get canRedoListenable => _canRedo;

  /// `creatorName` declared by the active annotation session, or `null`
  /// when the caller did not pass one to [enterMode]. New strokes
  /// committed in this session inherit this value, and ownership-aware
  /// operations (e.g. the eraser) compare against it.
  String? get currentCreator => _currentCreator;

  /// Replace the active stroke color. Idempotent — re-setting the same
  /// color does not fire listeners.
  void setStrokeColor(Color value) {
    if (_strokeColor.value == value) return;
    _strokeColor.value = value;
  }

  /// Replace the active stroke width (PDF points). Idempotent.
  void setStrokeWidth(double value) {
    if (_strokeWidth.value == value) return;
    _strokeWidth.value = value;
  }

  /// Replace the active highlighter color. Idempotent — re-setting the
  /// same color does not fire listeners.
  void setHighlighterColor(Color value) {
    if (_highlighterColor.value == value) return;
    _highlighterColor.value = value;
  }

  /// Replace the active highlighter width (PDF points). Idempotent.
  void setHighlighterWidth(double value) {
    if (_highlighterWidth.value == value) return;
    _highlighterWidth.value = value;
  }

  /// Replace the active eraser radius (PDF points). Idempotent.
  void setEraserRadius(double value) {
    if (_eraserRadius.value == value) return;
    _eraserRadius.value = value;
  }

  /// Replace the fill color new rectangles are created with. Idempotent.
  ///
  /// Already-committed rectangles keep the color they were created
  /// with; this only arms the next [startRectDraft].
  void setRectFillColor(Color value) {
    if (_rectFillColor.value == value) return;
    _rectFillColor.value = value;
  }

  /// Enter annotation drawing mode.
  ///
  /// Idempotent — calling while mode is already `true` does not re-fire
  /// the mode listener. Any non-null override values ([tool],
  /// [strokeColor], [strokeWidth], [highlighterColor], [highlighterWidth],
  /// [eraserRadius], [rectFillColor]) are applied through the matching setters; null
  /// overrides keep the previously-set value (the controller remembers
  /// tool/color/thickness across mode toggles).
  ///
  /// Per-tool overrides apply regardless of which tool is active —
  /// passing `highlighterColor:` while the pen is selected updates the
  /// highlighter's remembered color; the change becomes visible to the
  /// user only when they switch to the highlighter (or the same call
  /// also passes `tool: PdfAnnotationTool.highlighter`).
  ///
  /// [creatorName] follows a separate lifecycle: it is set on every
  /// `enterMode` call and cleared on `exitMode`. Pass `null` to enter a
  /// session whose new strokes are untagged (single-user / legacy
  /// behavior).
  void enterMode({
    String? creatorName,
    PdfAnnotationTool? tool,
    Color? strokeColor,
    double? strokeWidth,
    Color? highlighterColor,
    double? highlighterWidth,
    double? eraserRadius,
    Color? rectFillColor,
  }) {
    _currentCreator = creatorName;
    if (tool != null) _toolListenable.value = tool;
    if (strokeColor != null) setStrokeColor(strokeColor);
    if (strokeWidth != null) setStrokeWidth(strokeWidth);
    if (highlighterColor != null) setHighlighterColor(highlighterColor);
    if (highlighterWidth != null) setHighlighterWidth(highlighterWidth);
    if (eraserRadius != null) setEraserRadius(eraserRadius);
    if (rectFillColor != null) setRectFillColor(rectFillColor);
    if (_modeListenable.value) return;
    _undoStack.clear();
    _redoStack.clear();
    _refreshHistoryListenables();
    _modeListenable.value = true;
  }

  /// Exit annotation drawing mode and, if [onAnnotationsChanged] is
  /// non-null, await it with the current session's Instant JSON snapshot.
  ///
  /// When [enterMode] was called with a non-null `creatorName`, the JSON
  /// passed to the callback contains only strokes whose
  /// [PdfInkAnnotation.creatorName] matches that value; foreign strokes
  /// are filtered out so they cannot leak into the user's persisted file.
  /// When `creatorName` was null (single-user mode), the callback receives
  /// the full export.
  ///
  /// Idempotent — calling while mode is already `false` is a no-op
  /// (callback not invoked).
  Future<void> exitMode({required Future<void> Function(String json)? onAnnotationsChanged}) async {
    if (!_modeListenable.value) return;
    final creator = _currentCreator;
    // An edit in progress is committed first, and before the export
    // below, so the JSON handed to the callback carries the typed text
    // (or, for an empty edit, no longer carries the annotation).
    commitTextEdit(keepSelected: false);
    // Tear down transient selection state before flipping mode off so
    // the selection overlay (handles + delete button) doesn't leak past
    // the session boundary, and any half-finished drag or rubber band
    // is dropped.
    if (_stampDragState != null) _stampDragState = null;
    if (_rectDragState != null) _rectDragState = null;
    if (_rectDraft != null) _rectDraft = null;
    if (_textDraft != null) _textDraft = null;
    if (_selectedStampId.value != null) _selectedStampId.value = null;
    if (_selectedRectId.value != null) _selectedRectId.value = null;
    if (_selectedTextId.value != null) _selectedTextId.value = null;
    if (_pendingStamp.value != null) _pendingStamp.value = null;
    _modeListenable.value = false;
    if (onAnnotationsChanged != null) {
      await onAnnotationsChanged(_exportJsonForCreator(creator));
    }
    _currentCreator = null;
  }

  /// Read-only view of the committed strokes.
  List<PdfInkAnnotation> get strokes => List.unmodifiable(_strokes);

  /// Replace all strokes with [next] and notify listeners.
  void setAll(List<PdfInkAnnotation> next) {
    _strokes
      ..clear()
      ..addAll(next);
    _undoStack.clear();
    _redoStack.clear();
    _refreshHistoryListenables();
    notifyListeners();
  }

  /// Replace strokes, stamps, rectangles, text annotations, unrecognised
  /// entries, and attachments in a single update. History is cleared, listeners
  /// notified once.
  ///
  /// [rects], [texts] and [unknowns] default to empty so call sites that
  /// predate them keep compiling; they then replace those sets with nothing,
  /// which is the right reading of a wholesale replacement.
  void setAllWithStamps({
    required List<PdfInkAnnotation> strokes,
    required List<PdfStampAnnotation> stamps,
    required Map<String, PdfStampAttachment> attachments,
    List<PdfRectAnnotation> rects = const [],
    List<PdfTextAnnotation> texts = const [],
    List<Map<String, dynamic>> unknowns = const [],
  }) {
    _strokes
      ..clear()
      ..addAll(strokes);
    _stamps
      ..clear()
      ..addAll(stamps);
    _rects
      ..clear()
      ..addAll(rects);
    _texts
      ..clear()
      ..addAll(texts);
    _unknowns
      ..clear()
      ..addAll(unknowns);
    _attachments
      ..clear()
      ..addAll(attachments);
    // A wholesale replacement can retire the very shape a selection
    // points at, so every kind's selection goes, not just the stamp's.
    if (_selectedStampId.value != null) _selectedStampId.value = null;
    if (_selectedRectId.value != null) _selectedRectId.value = null;
    if (_selectedTextId.value != null) _selectedTextId.value = null;
    // Likewise an edit whose annotation was just replaced away. An edit
    // on a new annotation is not part of any set yet and carries on.
    final edit = _textEdit;
    if (edit != null && !edit.isNew && _textById(edit.working.id) == null) _abandonTextEdit();
    _undoStack.clear();
    _redoStack.clear();
    _refreshHistoryListenables();
    // Wholesale replacement is the one point where an attachment can
    // stop being referenced, so it is where decoded pictures are evicted
    // (and disposed). Undo/redo never evicts, so restoring a deleted
    // stamp never costs a re-decode.
    _stampPictures.retainOnly(_attachments.keys.toSet());
    // Pre-warm rather than waiting for the first paint: an undecoded
    // stamp draws nothing for that frame, which would show as a flash of
    // missing stamps every time a document or a remote refresh lands.
    for (final sha in _referencedAttachmentShas()) {
      ensureStampPictureDecoded(sha);
    }
    notifyListeners();
  }

  Set<String> _referencedAttachmentShas() => _stamps.map((s) => s.attachmentSha256).toSet();

  /// Remove all strokes, stamps, rectangles, text annotations,
  /// attachments, selection, and
  /// pending stamp (the last reset matches the spec's `clearAnnotations`
  /// contract). No-op when everything is already empty / null.
  ///
  /// The viewer calls this on every document swap, so a rectangle list
  /// left untouched here would paint the previous part's rectangles over
  /// the newly opened score and export them into the wrong part.
  void clear() {
    final hadStrokes = _strokes.isNotEmpty;
    final hadStamps = _stamps.isNotEmpty;
    final hadRects = _rects.isNotEmpty;
    final hadTexts = _texts.isNotEmpty;
    final hadUnknowns = _unknowns.isNotEmpty;
    final hadAttachments = _attachments.isNotEmpty;
    final hadSelection =
        _selectedStampId.value != null || _selectedRectId.value != null || _selectedTextId.value != null;
    final hadTextEdit = _textEdit != null || _textDraft != null;
    final hadHistory = _undoStack.isNotEmpty || _redoStack.isNotEmpty;
    final hadPictures = !_stampPictures.isEmpty;
    if (!hadStrokes &&
        !hadStamps &&
        !hadRects &&
        !hadTexts &&
        !hadUnknowns &&
        !hadAttachments &&
        !hadSelection &&
        !hadTextEdit &&
        !hadHistory &&
        !hadPictures) {
      return;
    }
    _strokes.clear();
    _stamps.clear();
    _rects.clear();
    _texts.clear();
    // Carried entries belong to the document that was open. Leaving them
    // here would export the previous part's unrecognised annotations into
    // the newly opened one, exactly as a stale rectangle list would.
    _unknowns.clear();
    _attachments.clear();
    // The viewer calls this on every document swap, so a cache left
    // undrained here leaks every picture decoded for the previous
    // document.
    _stampPictures.clear();
    if (_selectedStampId.value != null) _selectedStampId.value = null;
    if (_selectedRectId.value != null) _selectedRectId.value = null;
    if (_selectedTextId.value != null) _selectedTextId.value = null;
    // The edit belonged to the document that was open: committing it
    // here would write it into the one being opened.
    _abandonTextEdit();
    _textDraft = null;
    _rectDraft = null;
    _stampDragState = null;
    _rectDragState = null;
    _undoStack.clear();
    _redoStack.clear();
    _refreshHistoryListenables();
    notifyListeners();
  }

  /// Replace all strokes by decoding [json] in Instant JSON format.
  ///
  /// [pageCount] bounds-checks `pageIndex` entries; out-of-range entries
  /// are silently skipped. The controller's current [strokeColor] and
  /// [strokeWidth] are used as fallback defaults when an imported entry
  /// is missing those fields. Stamps and attachments embedded in the
  /// document are imported as well, as are entries of a kind this build
  /// does not recognise (held verbatim for re-export, never painted).
  void importJson(String json, {required int pageCount}) {
    final decoded = decodeInstantJsonFull(
      json,
      pageCount: pageCount,
      defaultColor: _strokeColor.value,
      defaultLineWidth: _strokeWidth.value,
    );
    setAllWithStamps(
      strokes: decoded.strokes,
      stamps: decoded.stamps,
      rects: decoded.rects,
      texts: decoded.texts,
      unknowns: decoded.unknowns,
      attachments: decoded.attachments,
    );
  }

  /// Serialize all strokes (and stamps, rectangles, text annotations,
  /// carried unrecognised entries + attachments, if any) as an Instant
  /// JSON document.
  String exportJson() => encodeInstantJson(
    _strokes,
    stamps: _stamps,
    rects: _rects,
    texts: _texts,
    unknowns: _unknowns,
    attachments: _attachments,
  );

  /// The `creatorName` of a carried entry, or null when it names none.
  static String? _unknownCreator(Map<String, dynamic> entry) {
    final name = entry['creatorName'];
    return name is String ? name : null;
  }

  String _exportJsonForCreator(String? creator) {
    if (creator == null) {
      return encodeInstantJson(
        _strokes,
        stamps: _stamps,
        rects: _rects,
        texts: _texts,
        unknowns: _unknowns,
        attachments: _attachments,
      );
    }
    final mineStrokes = _strokes.where((s) => s.creatorName == creator).toList(growable: false);
    final mineStamps = _stamps.where((s) => s.creatorName == creator).toList(growable: false);
    final mineRects = _rects.where((r) => r.creatorName == creator).toList(growable: false);
    final mineTexts = _texts.where((t) => t.creatorName == creator).toList(growable: false);
    // Carried entries are filtered by `creatorName` exactly as the kinds
    // above are. Exporting every carried entry regardless of author would
    // be worse than dropping them: the caller persists this export as
    // THIS creator's own set, so another creator's entry would be
    // re-attributed and duplicated on every save. An entry naming no
    // creator is not attributable to anyone and is excluded too, which is
    // how a null `creatorName` already behaves for ink, stamps and rects.
    final mineUnknowns = _unknowns.where((e) => _unknownCreator(e) == creator).toList(growable: false);
    return encodeInstantJson(
      mineStrokes,
      stamps: mineStamps,
      rects: mineRects,
      texts: mineTexts,
      unknowns: mineUnknowns,
      attachments: _attachments,
    );
  }

  /// Switch the active tool. No-op if [tool] is already active. Commits
  /// a text edit in progress, then clears every kind's selection and the
  /// pending stamp: a gizmo belongs to the tool that put it there.
  void setTool(PdfAnnotationTool tool) {
    if (_toolListenable.value == tool) return;
    commitTextEdit(keepSelected: false);
    if (_textDraft != null) cancelTextDraft();
    _toolListenable.value = tool;
    if (_selectedStampId.value != null) _selectedStampId.value = null;
    if (_selectedRectId.value != null) _selectedRectId.value = null;
    if (_selectedTextId.value != null) _selectedTextId.value = null;
    if (_pendingStamp.value != null) _pendingStamp.value = null;
  }

  /// Begin a new in-flight stroke anchored to [pageIndex] starting at
  /// [firstPoint] (PDF point space, top-left origin). Notifies listeners so
  /// the layer can paint the new stroke as it grows.
  ///
  /// [kind] selects the visual variant ([PdfInkAnnotationKind.pen] /
  /// [PdfInkAnnotationKind.highlighter]) and is propagated unchanged
  /// onto the produced [PdfInkAnnotation] when the stroke is committed.
  void startStroke({
    required int pageIndex,
    required Offset firstPoint,
    required double lineWidth,
    required Color strokeColor,
    required double opacity,
    PdfInkAnnotationKind kind = PdfInkAnnotationKind.pen,
  }) {
    final now = DateTime.now().toUtc();
    _inFlight = _InFlightStroke(
      pageIndex: pageIndex,
      points: [firstPoint],
      lineWidth: lineWidth,
      strokeColor: strokeColor,
      opacity: opacity,
      createdAt: now,
      kind: kind,
    );
    notifyListeners();
  }

  /// Append [point] (PDF point space) to the in-flight stroke. No-op if no
  /// stroke is currently in flight. Fires [inFlightChangedListenable] only
  /// (the main listener notifies on commit, not on every move).
  void appendPoint(Offset point) {
    final inFlight = _inFlight;
    if (inFlight == null) return;
    inFlight.points.add(point);
    _inFlightTick.value++;
  }

  /// Commit the in-flight stroke to [strokes]. Strokes with fewer than 2
  /// points are discarded (cannot be painted). The stroke inherits
  /// [currentCreator] from the active mode session so ownership-aware
  /// operations can scope to it later. Notifies listeners.
  ///
  /// The committed stroke is assigned a fresh 24-character hex [PdfInkAnnotation.id]
  /// so downstream consumers can identify it stably across export/import.
  /// [idGenerator] is a testability seam; it defaults to a random 24-hex
  /// generator.
  void commitStroke({String Function()? idGenerator}) {
    final inFlight = _inFlight;
    if (inFlight == null) return;
    _inFlight = null;
    if (inFlight.points.length < 2) {
      notifyListeners();
      return;
    }
    _pushUndoSnapshot();
    final now = DateTime.now().toUtc();
    _strokes.add(
      PdfInkAnnotation(
        id: (idGenerator ?? _defaultIdGenerator)(),
        pageIndex: inFlight.pageIndex,
        pointsInPdfSpace: List<Offset>.unmodifiable(inFlight.points),
        lineWidth: inFlight.lineWidth,
        strokeColor: inFlight.strokeColor,
        opacity: inFlight.opacity,
        createdAt: inFlight.createdAt,
        updatedAt: now,
        creatorName: _currentCreator,
        kind: inFlight.kind,
      ),
    );
    notifyListeners();
  }

  /// Discard the in-flight stroke without committing. No-op if no stroke
  /// is in flight.
  void cancelStroke() {
    if (_inFlight == null) return;
    _inFlight = null;
    notifyListeners();
  }

  /// Pop the most recent undo snapshot and restore the captured strokes,
  /// stamps, and attachments. The displaced state is pushed onto the
  /// redo stack so it can be restored by [redo].
  ///
  /// No-op when [canUndoListenable] is `false` — does not throw, does
  /// not notify listeners.
  void undo() {
    if (_undoStack.isEmpty || _textEdit != null) return;
    _redoStack.add(_currentSnapshot());
    final snapshot = _undoStack.removeLast();
    _restoreSnapshot(snapshot);
    _refreshHistoryListenables();
    notifyListeners();
  }

  /// Pop the most recent redo snapshot and restore the captured strokes,
  /// stamps, and attachments. The displaced state is pushed onto the
  /// undo stack so it can be restored by [undo].
  ///
  /// No-op when [canRedoListenable] is `false` — does not throw, does
  /// not notify listeners.
  void redo() {
    if (_redoStack.isEmpty || _textEdit != null) return;
    _undoStack.add(_currentSnapshot());
    final snapshot = _redoStack.removeLast();
    _restoreSnapshot(snapshot);
    _refreshHistoryListenables();
    notifyListeners();
  }

  /// Append a fully-formed [stroke] to [strokes] and notify listeners.
  /// Treated as an undoable user-driven action: pushes an undo snapshot
  /// before appending.
  void addStroke(PdfInkAnnotation stroke) {
    _pushUndoSnapshot();
    _strokes.add(stroke);
    notifyListeners();
  }

  /// Begin an eraser pan on [pageIndex] starting at [pdfPoint] (a
  /// PDF-point-space coordinate with top-left origin), with hit
  /// [radiusInPdfPoints]. The first sample is processed as a degenerate
  /// (zero-length) eraser segment so a tap-and-release still removes
  /// nearby strokes.
  ///
  /// Use [continueErase] for each subsequent pan-update sample and
  /// [endErase] when the pan ends (or is cancelled).
  ///
  /// Eraser semantics: each pen-stroke's individual segments are tested
  /// against the eraser segment; only segments within
  /// [radiusInPdfPoints] are removed, and the surviving runs are emitted
  /// as new sub-strokes (each ≥ 2 points). This means a single pen-stroke
  /// may be split into multiple sub-strokes by a single eraser pass, and
  /// short tail-strokes that drop below 2 points are dropped entirely.
  ///
  /// Ownership is enforced by [PdfInkAnnotation.creatorName] vs
  /// [currentCreator]: foreign-creator strokes survive untouched. In
  /// single-user mode (both null) every stroke is fair game.
  void startErase({required int pageIndex, required Offset pdfPoint, required double radiusInPdfPoints}) {
    _pushUndoSnapshot();
    _eraserPrevPoint = pdfPoint;
    _eraserPrevPage = pageIndex;
    _eraserCursorTick.value++;
    _applyEraseSegment(pageIndex, pdfPoint, pdfPoint, radiusInPdfPoints);
  }

  /// Process the next eraser sample at [pdfPoint] and erase any owned
  /// stroke segment within [radiusInPdfPoints] of the segment from the
  /// previous sample to this one.
  ///
  /// If the eraser jumps to a different page (e.g. the gesture moved off
  /// the anchor page), the previous-sample buffer resets so the
  /// cross-page segment is not interpreted as a stroke-cutting line.
  void continueErase({required int pageIndex, required Offset pdfPoint, required double radiusInPdfPoints}) {
    final prev = _eraserPrevPoint;
    final prevPage = _eraserPrevPage;
    if (prev == null || prevPage != pageIndex) {
      _eraserPrevPoint = pdfPoint;
      _eraserPrevPage = pageIndex;
      _eraserCursorTick.value++;
      _applyEraseSegment(pageIndex, pdfPoint, pdfPoint, radiusInPdfPoints);
      return;
    }
    _applyEraseSegment(pageIndex, prev, pdfPoint, radiusInPdfPoints);
    _eraserPrevPoint = pdfPoint;
    _eraserCursorTick.value++;
  }

  /// Clear the in-flight eraser-stroke buffer. Safe to call when no
  /// eraser pan is in progress.
  void endErase() {
    if (_eraserPrevPoint == null && _eraserPrevPage == null) return;
    _eraserPrevPoint = null;
    _eraserPrevPage = null;
    _eraserCursorTick.value++;
  }

  void _applyEraseSegment(int pageIndex, Offset a, Offset b, double radius) {
    if (_strokes.isEmpty) return;
    final replaced = <PdfInkAnnotation>[];
    var changed = false;
    for (final s in _strokes) {
      if (s.pageIndex != pageIndex || !_ownsStroke(s)) {
        replaced.add(s);
        continue;
      }
      final pieces = _splitStrokeByEraserSegment(s, a, b, radius);
      if (pieces == null) {
        replaced.add(s);
      } else {
        replaced.addAll(pieces);
        changed = true;
      }
    }
    if (changed) {
      _strokes
        ..clear()
        ..addAll(replaced);
      notifyListeners();
    }
  }

  List<PdfInkAnnotation>? _splitStrokeByEraserSegment(PdfInkAnnotation s, Offset a, Offset b, double radius) {
    final pts = s.pointsInPdfSpace;
    if (pts.length < 2) return null;
    final kept = List<bool>.filled(pts.length - 1, true);
    var anyErased = false;
    for (var i = 0; i < pts.length - 1; i++) {
      if (_segmentsCloseOrIntersect(pts[i], pts[i + 1], a, b, radius)) {
        kept[i] = false;
        anyErased = true;
      }
    }
    if (!anyErased) return null;
    final result = <PdfInkAnnotation>[];
    var runStart = -1;
    final now = DateTime.now().toUtc();
    for (var i = 0; i <= kept.length; i++) {
      final isKept = i < kept.length && kept[i];
      if (isKept && runStart == -1) {
        runStart = i;
      } else if (!isKept && runStart != -1) {
        final subPoints = pts.sublist(runStart, i + 1);
        if (subPoints.length >= 2) {
          result.add(
            PdfInkAnnotation(
              // Each surviving fragment is a new stroke and must get a FRESH
              // id — copying the parent's id would collapse the fragments to
              // one element in the downstream diff and silently lose strokes.
              id: _defaultIdGenerator(),
              pageIndex: s.pageIndex,
              pointsInPdfSpace: List<Offset>.unmodifiable(subPoints),
              lineWidth: s.lineWidth,
              strokeColor: s.strokeColor,
              opacity: s.opacity,
              createdAt: s.createdAt,
              updatedAt: now,
              creatorName: s.creatorName,
              kind: s.kind,
            ),
          );
        }
        runStart = -1;
      }
    }
    return result;
  }

  bool _ownsStroke(PdfInkAnnotation s) => s.creatorName == _currentCreator;

  bool _ownsStamp(PdfStampAnnotation s) => s.creatorName == _currentCreator;

  void _pushUndoSnapshot() {
    _undoStack.add(_currentSnapshot());
    _redoStack.clear();
    _refreshHistoryListenables();
  }

  // `_unknowns` is deliberately NOT captured here. No tool mutates a
  // carried entry, so it is identical in every snapshot on the stack;
  // the only two writers (`setAllWithStamps` and `clear`) both clear the
  // history. Adding it would be harmless but misleading: undo has no
  // business restoring something undo can never have changed.
  _AnnotationSnapshot _currentSnapshot() {
    return _AnnotationSnapshot(
      strokes: List<PdfInkAnnotation>.unmodifiable(_strokes),
      stamps: List<PdfStampAnnotation>.unmodifiable(_stamps),
      rects: List<PdfRectAnnotation>.unmodifiable(_rects),
      texts: List<PdfTextAnnotation>.unmodifiable(_texts),
      attachments: Map<String, PdfStampAttachment>.unmodifiable(_attachments),
    );
  }

  void _restoreSnapshot(_AnnotationSnapshot snapshot) {
    _strokes
      ..clear()
      ..addAll(snapshot.strokes);
    _stamps
      ..clear()
      ..addAll(snapshot.stamps);
    _rects
      ..clear()
      ..addAll(snapshot.rects);
    _texts
      ..clear()
      ..addAll(snapshot.texts);
    _attachments
      ..clear()
      ..addAll(snapshot.attachments);
    final selectedStampId = _selectedStampId.value;
    if (selectedStampId != null && !_stamps.any((s) => s.id == selectedStampId)) {
      _selectedStampId.value = null;
    }
    final selectedRectId = _selectedRectId.value;
    if (selectedRectId != null && !_rects.any((r) => r.id == selectedRectId)) {
      _selectedRectId.value = null;
    }
    final selectedTextId = _selectedTextId.value;
    if (selectedTextId != null && !_texts.any((t) => t.id == selectedTextId)) {
      _selectedTextId.value = null;
    }
  }

  void _refreshHistoryListenables() {
    // Both are off while a text edit is in progress.
    final editing = _textEdit != null;
    final canUndo = !editing && _undoStack.isNotEmpty;
    if (_canUndo.value != canUndo) _canUndo.value = canUndo;
    final canRedo = !editing && _redoStack.isNotEmpty;
    if (_canRedo.value != canRedo) _canRedo.value = canRedo;
  }

  /// Register the viewer-local rect (in the parent stack's pixel space)
  /// and PDF-point size for [pageIndex]. Per-page annotation layers call
  /// this on mount and whenever their `pageRect` changes so the
  /// controller can reason about cross-page stamp drags.
  ///
  /// Idempotent — a register call with identical [viewerRect] and
  /// [pageSize] does not mutate state.
  void registerPageLayout({required int pageIndex, required Rect viewerRect, required Size pageSize}) {
    final existing = _pageLayouts[pageIndex];
    if (existing != null && existing.viewerRect == viewerRect && existing.pageSize == pageSize) {
      return;
    }
    _pageLayouts[pageIndex] = _PageLayoutInfo(viewerRect: viewerRect, pageSize: pageSize);
  }

  /// Drop the registered layout for [pageIndex] (called when an
  /// annotation layer unmounts).
  void unregisterPageLayout(int pageIndex) {
    _pageLayouts.remove(pageIndex);
  }

  /// Arm a [PdfStampDefinition] for placement. Pass `null` to disarm.
  /// Setting a pending stamp clears any current stamp selection so the
  /// next page tap drops a new stamp instead of moving the selection.
  /// Idempotent — re-arming the same stamp does not fire listeners.
  void setPendingStamp(PdfStampDefinition? stamp) {
    if (_pendingStamp.value == stamp) return;
    _pendingStamp.value = stamp;
    if (stamp != null && _selectedStampId.value != null) {
      _selectedStampId.value = null;
    }
  }

  /// Clear the current stamp selection. Idempotent — no-op when nothing
  /// is selected.
  void clearStampSelection() {
    if (_selectedStampId.value == null) return;
    _selectedStampId.value = null;
  }

  /// Internal — set the selected stamp by id. Foreign-creator stamps
  /// cannot become selected (no-op). Idempotent.
  ///
  /// Selection is mutually exclusive across kinds: one gizmo is on
  /// screen at a time, so selecting a stamp drops any rectangle
  /// selection.
  void selectStamp(String? id) {
    if (id == null) {
      clearStampSelection();
      return;
    }
    if (_selectedStampId.value == id) return;
    final stamp = _stampById(id);
    if (stamp == null || !_ownsStamp(stamp)) return;
    clearRectSelection();
    clearTextSelection();
    _selectedStampId.value = id;
  }

  /// `id` of the currently-selected rectangle, or `null` when none is
  /// selected. The rectangle half of the shared gizmo's state.
  ValueListenable<String?> get selectedRectIdListenable => _selectedRectId;

  /// Clear the current rectangle selection. Idempotent.
  void clearRectSelection() {
    if (_selectedRectId.value == null) return;
    _selectedRectId.value = null;
  }

  /// Select the rectangle [id]. Foreign-creator rectangles cannot become
  /// selected (no-op), and selecting one drops any stamp selection.
  /// Idempotent.
  void selectRect(String? id) {
    if (id == null) {
      clearRectSelection();
      return;
    }
    if (_selectedRectId.value == id) return;
    final rect = _rectById(id);
    if (rect == null || !_ownsRect(rect)) return;
    clearStampSelection();
    clearTextSelection();
    _selectedRectId.value = id;
  }

  PdfRectAnnotation? _rectById(String id) {
    for (final r in _rects) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// The rectangles on [pageIndex] the current creator may select, in
  /// reverse unified paint order: topmost first.
  ///
  /// Foreign-creator rectangles are skipped rather than ending the walk,
  /// so an own rectangle lying under a bandmate's is still reachable, by
  /// the same rule `_hitTestSelectableStampBody` applies to stamps. The
  /// order is the paint sequence's, not the list's, so overlap resolves
  /// the way the page actually renders.
  List<PdfRectAnnotation> selectableRectsForHitTest(int pageIndex) {
    final result = <PdfRectAnnotation>[];
    final sequence = paintSequenceForPage(pageIndex);
    for (var i = sequence.length - 1; i >= 0; i--) {
      final entry = sequence[i];
      if (entry is! PdfRectPaintEntry) continue;
      if (!_ownsRect(entry.rect)) continue;
      result.add(entry.rect);
    }
    return result;
  }

  PdfStampAnnotation? _stampById(String id) {
    for (final s in _stamps) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Place a stamp at [pdfPoint] on [pageIndex] with the given raw
  /// [bytes] and [contentType], sized so its longest side equals the
  /// default placement size and its aspect matches [intrinsicSize].
  /// Pushes one undo snapshot. The bytes are deduped via SHA-256: two
  /// stamps with identical bytes share a single attachment entry.
  ///
  /// [clock] / [idGenerator] are testability seams. They default to
  /// `DateTime.now().toUtc()` and a 24-character random hex generator.
  ///
  /// Synchronous failures (e.g. pathological arguments) are caught and
  /// logged via [debugPrint]; no partial state is leaked.
  ///
  /// Returns the new stamp's `id` on success, or `null` when placement
  /// failed (so the caller can auto-select the new stamp).
  String? placeStamp({
    required Uint8List bytes,
    required String contentType,
    required int pageIndex,
    required Offset pdfPoint,
    required Size intrinsicSize,
    required Size pageSize,
    DateTime Function()? clock,
    String Function()? idGenerator,
  }) {
    try {
      final aspect = _aspectFit(intrinsicSize, _kDefaultStampLongestSidePts);
      var rect = Rect.fromCenter(center: pdfPoint, width: aspect.width, height: aspect.height);
      rect = _clampRectInsidePage(rect, pageSize);

      final hash = sha256.convert(bytes).toString();
      final now = (clock ?? _defaultClock)();
      final id = (idGenerator ?? _defaultIdGenerator)();

      // Snapshot before any mutation so undo restores the pre-placement
      // state, including dropping the attachment when it was newly added.
      _pushUndoSnapshot();
      _attachments.putIfAbsent(hash, () => PdfStampAttachment(bytes: bytes, contentType: contentType));
      // Start decoding now rather than leaving it to the first paint, so
      // a freshly-placed stamp appears as soon as the decode lands
      // instead of a frame after the painter first notices it.
      ensureStampPictureDecoded(hash);
      _stamps.add(
        PdfStampAnnotation(
          id: id,
          pageIndex: pageIndex,
          rectInPdfSpace: rect,
          rotationDeg: 0,
          attachmentSha256: hash,
          contentType: contentType,
          createdAt: now,
          updatedAt: now,
          creatorName: _currentCreator,
        ),
      );
      notifyListeners();
      return id;
    } catch (e, st) {
      debugPrint('placeStamp failed: $e\n$st');
      return null;
    }
  }

  /// Remove the stamp identified by [id] from the document. No-op when
  /// the stamp does not exist or its `creatorName` differs from the
  /// current creator (foreign-creator protection). The associated
  /// attachment is dropped only when no other stamp still references
  /// the same SHA-256.
  void deleteStamp(String id) {
    final stamp = _stampById(id);
    if (stamp == null) return;
    if (!_ownsStamp(stamp)) return;
    _pushUndoSnapshot();
    _stamps.removeWhere((s) => s.id == id);
    final stillReferenced = _stamps.any((s) => s.attachmentSha256 == stamp.attachmentSha256);
    if (!stillReferenced) {
      _attachments.remove(stamp.attachmentSha256);
    }
    if (_selectedStampId.value == id) {
      _selectedStampId.value = null;
    }
    notifyListeners();
  }

  /// Begin a stamp drag (move/resize/rotate). Pushes one undo snapshot
  /// at the start of the drag and captures the original rect + rotation
  /// of the currently-selected stamp so subsequent
  /// [applyStampMove] / [applyStampResize] / [applyStampRotate] calls can
  /// reconstruct the new state from a cumulative delta.
  ///
  /// No-op when no stamp is selected, the selected stamp is owned by a
  /// different creator (foreign-creator protection), or a drag is
  /// already in progress.
  void beginStampDrag(PdfAnnotationHandle handle) {
    if (_stampDragState != null) return;
    final id = _selectedStampId.value;
    if (id == null) return;
    final stamp = _stampById(id);
    if (stamp == null || !_ownsStamp(stamp)) return;
    _pushUndoSnapshot();
    _stampDragState = _ShapeDragState(
      shapeId: id,
      handle: handle,
      originalRect: stamp.rectInPdfSpace,
      originalRotation: stamp.rotationDeg,
      originalPageIndex: stamp.pageIndex,
    );
  }

  /// End the in-progress stamp drag (commit boundary). Safe to call when
  /// no drag is in progress.
  void endStampDrag() {
    if (_stampDragState == null) return;
    _stampDragState = null;
  }

  /// Translate the selected stamp by [cumulativeDeltaPdf] from the
  /// position captured at [beginStampDrag]. Bumps [stampDragChangedListenable].
  void applyStampMove(Offset cumulativeDeltaPdf) {
    final state = _stampDragState;
    if (state == null) return;
    if (state.handle != PdfAnnotationHandle.body) return;
    final newRect = state.originalRect.shift(cumulativeDeltaPdf);
    _replaceSelectedStamp((s) => s.copyWith(rectInPdfSpace: newRect, updatedAt: _defaultClock()));
    _bumpShapeDrag();
  }

  /// Translate the selected stamp by [cumulativeDeltaViewer] expressed
  /// in the viewer's pixel coordinate space (the parent stack the
  /// per-page annotation layers sit in). Reassigns the stamp's
  /// `pageIndex` when the bbox center crosses into a different
  /// registered page so multi-page users can drag a stamp from page A
  /// onto page B and continue interacting with it on the new page.
  ///
  /// Falls back to keeping the stamp on its original page when the new
  /// center is outside every registered page (gutter / off-screen). The
  /// rect is always recomputed in the destination page's PDF point
  /// space, preserving its visible pixel size.
  ///
  /// No-op when no drag is in progress, the active handle isn't
  /// [PdfAnnotationHandle.body], or the original page's layout is no longer
  /// registered.
  void applyStampMoveViewer(Offset cumulativeDeltaViewer) {
    final state = _stampDragState;
    if (state == null) return;
    if (state.handle != PdfAnnotationHandle.body) return;

    final origPageInfo = _pageLayouts[state.originalPageIndex];
    if (origPageInfo == null) return;

    final origRectViewer = _pdfRectToViewer(state.originalRect, origPageInfo);
    final newRectViewer = origRectViewer.shift(cumulativeDeltaViewer);
    final center = newRectViewer.center;

    var targetPageIdx = state.originalPageIndex;
    for (final entry in _pageLayouts.entries) {
      if (entry.value.viewerRect.contains(center)) {
        targetPageIdx = entry.key;
        break;
      }
    }
    final targetPageInfo = _pageLayouts[targetPageIdx];
    if (targetPageInfo == null) return;

    final newPdfRect = _viewerRectToPdf(newRectViewer, targetPageInfo);
    _replaceSelectedStamp(
      (s) => s.copyWith(pageIndex: targetPageIdx, rectInPdfSpace: newPdfRect, updatedAt: _defaultClock()),
    );
    _bumpShapeDrag();
  }

  Rect _pdfRectToViewer(Rect pdfRect, _PageLayoutInfo info) {
    final scaleX = info.viewerRect.width / info.pageSize.width;
    final scaleY = info.viewerRect.height / info.pageSize.height;
    return Rect.fromLTWH(
      info.viewerRect.left + pdfRect.left * scaleX,
      info.viewerRect.top + pdfRect.top * scaleY,
      pdfRect.width * scaleX,
      pdfRect.height * scaleY,
    );
  }

  Rect _viewerRectToPdf(Rect viewerRect, _PageLayoutInfo info) {
    final scaleX = info.pageSize.width / info.viewerRect.width;
    final scaleY = info.pageSize.height / info.viewerRect.height;
    return Rect.fromLTWH(
      (viewerRect.left - info.viewerRect.left) * scaleX,
      (viewerRect.top - info.viewerRect.top) * scaleY,
      viewerRect.width * scaleX,
      viewerRect.height * scaleY,
    );
  }

  /// Resize the selected stamp's bbox by applying [cumulativeDeltaPdf]
  /// to the corner/edge captured at [beginStampDrag].
  ///
  /// The delta arrives in screen-axis PDF space and is projected into
  /// the stamp's own frame by [resizeInLocalFrame], so pulling the
  /// right handle of a rotated stamp widens it along its own axis and
  /// the opposite corner or edge stays fixed on screen.
  ///
  /// Corner handles preserve the bbox's aspect ratio at drag-start —
  /// the dominant axis (the one the cursor pulls further in proportion
  /// to its original size) drives a uniform scale; the opposite corner
  /// anchors. Edge handles stretch a single axis. Both modes clamp each
  /// axis to [kMinAnnotationSizePts]. Bumps [stampDragChangedListenable].
  void applyStampResize(Offset cumulativeDeltaPdf) {
    final state = _stampDragState;
    if (state == null) return;
    final handle = state.handle;
    if (handle == PdfAnnotationHandle.body || handle == PdfAnnotationHandle.rotation) return;

    final newRect = resizeInLocalFrame(
      originalRect: state.originalRect,
      rotationDeg: state.originalRotation,
      handle: handle,
      delta: cumulativeDeltaPdf,
      // Stamps keep their aspect lock on corner drags; rectangles do
      // not (they pass `false`).
      lockAspect: true,
    );

    _replaceSelectedStamp((s) => s.copyWith(rectInPdfSpace: newRect, updatedAt: _defaultClock()));
    _bumpShapeDrag();
  }

  /// Set the selected stamp's rotation to [absoluteAngleDeg] (degrees,
  /// CCW). Caller is responsible for atan2 of (cursor − centroid) etc.
  /// Bumps [stampDragChangedListenable].
  void applyStampRotate(double absoluteAngleDeg) {
    final state = _stampDragState;
    if (state == null) return;
    if (state.handle != PdfAnnotationHandle.rotation) return;
    _replaceSelectedStamp((s) => s.copyWith(rotationDeg: absoluteAngleDeg, updatedAt: _defaultClock()));
    _bumpShapeDrag();
  }

  // ───────────────────────────── Rectangles ─────────────────────────────

  /// Start a rubber band on [pageIndex], anchored at [anchorPdfPoint].
  ///
  /// The anchor corner stays pinned there for the whole gesture;
  /// [updateRectDraft] moves only the free corner. No undo snapshot is
  /// pushed here: a draft that never commits must leave no trace.
  /// No-op while a draft is already in flight.
  ///
  /// [fillColor] defaults to the armed [rectFillColor], so the gesture
  /// layer does not have to read the palette itself.
  void startRectDraft({
    required int pageIndex,
    required Offset anchorPdfPoint,
    required Size pageSize,
    Color? fillColor,
  }) {
    if (_rectDraft != null) return;
    _rectDraft = _RectDraft(
      pageIndex: pageIndex,
      anchor: _clampPointInsidePage(anchorPdfPoint, pageSize),
      pageSize: pageSize,
      fillColor: fillColor ?? _rectFillColor.value,
    );
    _bumpRectDraft();
  }

  /// Move the in-flight rubber band's free corner to [freeCornerPdfPoint].
  ///
  /// The corner is clamped **componentwise** into the page, so a drag
  /// that crosses a gutter in continuous scroll never produces off-page
  /// geometry. The rectangle is never translated to fit:
  /// [_clampRectInsidePage] shifts rather than shrinks, which would drag
  /// the anchored corner off the user's finger mid-preview and silently
  /// relocate the committed rectangle, so it is deliberately not used
  /// here. It stays the right call for [placeStamp] and for a body move.
  void updateRectDraft(Offset freeCornerPdfPoint) {
    final draft = _rectDraft;
    if (draft == null) return;
    draft.free = _clampPointInsidePage(freeCornerPdfPoint, draft.pageSize);
    _bumpRectDraft();
  }

  /// Discard the in-flight rubber band. Pushes no undo snapshot, and
  /// leaves no rectangle behind: the pointer-cancel path, mirroring
  /// [cancelStroke]. Safe to call when no draft is in flight.
  void cancelRectDraft() {
    if (_rectDraft == null) return;
    _rectDraft = null;
    _bumpRectDraft();
  }

  /// Commit the in-flight rubber band and return the new rectangle's id,
  /// or `null` when there was nothing to commit.
  ///
  /// A drag whose width or height is below [kMinAnnotationSizePts] is
  /// **discarded, not clamped**, and pushes no undo snapshot, mirroring
  /// [commitStroke] dropping a stroke with fewer than two points. The
  /// caller is expected to fall through to its tap handling at the
  /// pointer-up point rather than treating the gesture as consumed: the
  /// tap/drag slop is 4 screen pixels while this threshold is 8 PDF
  /// points, so at low zoom an ordinary fingertip tap clears the slop
  /// and still lands here. Without that fall-through, tapping an
  /// invisible white rectangle to select it would frequently do nothing.
  ///
  /// A committed rectangle is auto-selected, so its gizmo is available
  /// immediately.
  ///
  /// [clock] / [idGenerator] are testability seams, as on [placeStamp].
  String? commitRectDraft({DateTime Function()? clock, String Function()? idGenerator}) {
    final draft = _rectDraft;
    if (draft == null) return null;
    _rectDraft = null;
    final rect = draft.rect;
    if (rect.width < kMinAnnotationSizePts || rect.height < kMinAnnotationSizePts) {
      _bumpRectDraft();
      return null;
    }
    final now = (clock ?? _defaultClock)();
    final id = (idGenerator ?? _defaultIdGenerator)();
    _pushUndoSnapshot();
    _rects.add(
      PdfRectAnnotation(
        id: id,
        pageIndex: draft.pageIndex,
        rectInPdfSpace: rect,
        rotationDeg: 0,
        fillColor: draft.fillColor,
        createdAt: now,
        updatedAt: now,
        creatorName: _currentCreator,
      ),
    );
    notifyListeners();
    selectRect(id);
    return id;
  }

  /// The in-flight rubber band as a paintable rectangle, or `null` when
  /// no draft is in flight on [pageIndex]. Painted last, over everything
  /// already committed.
  PdfRectAnnotation? inFlightRectFor(int pageIndex) {
    final draft = _rectDraft;
    if (draft == null || draft.pageIndex != pageIndex) return null;
    final now = _defaultClock();
    return PdfRectAnnotation(
      id: '',
      pageIndex: draft.pageIndex,
      rectInPdfSpace: draft.rect,
      rotationDeg: 0,
      fillColor: draft.fillColor,
      createdAt: now,
      updatedAt: now,
      creatorName: _currentCreator,
    );
  }

  /// Remove the rectangle [id]. No-op when it does not exist or its
  /// `creatorName` differs from the current creator. Pushes one undo
  /// snapshot.
  void deleteRect(String id) {
    final rect = _rectById(id);
    if (rect == null) return;
    if (!_ownsRect(rect)) return;
    _pushUndoSnapshot();
    _rects.removeWhere((r) => r.id == id);
    if (_selectedRectId.value == id) _selectedRectId.value = null;
    notifyListeners();
  }

  /// Begin a rectangle drag (move/resize/rotate), pushing one undo
  /// snapshot for the whole drag and capturing the selected rectangle's
  /// geometry so the apply methods can rebuild it from a cumulative
  /// delta. Mirrors [beginStampDrag], including its guards: no
  /// selection, a foreign-creator selection, or a drag already in
  /// progress are all no-ops.
  void beginRectDrag(PdfAnnotationHandle handle) {
    if (_rectDragState != null) return;
    final id = _selectedRectId.value;
    if (id == null) return;
    final rect = _rectById(id);
    if (rect == null || !_ownsRect(rect)) return;
    _pushUndoSnapshot();
    _rectDragState = _ShapeDragState(
      shapeId: id,
      handle: handle,
      originalRect: rect.rectInPdfSpace,
      originalRotation: rect.rotationDeg,
      originalPageIndex: rect.pageIndex,
    );
  }

  /// End the in-progress rectangle drag (commit boundary). Safe to call
  /// when no drag is in progress.
  void endRectDrag() {
    if (_rectDragState == null) return;
    _rectDragState = null;
  }

  /// Translate the selected rectangle by [cumulativeDeltaPdf] from the
  /// position captured at [beginRectDrag].
  void applyRectMove(Offset cumulativeDeltaPdf) {
    final state = _rectDragState;
    if (state == null) return;
    if (state.handle != PdfAnnotationHandle.body) return;
    _replaceSelectedRect(
      (r) => r.copyWith(rectInPdfSpace: state.originalRect.shift(cumulativeDeltaPdf), updatedAt: _defaultClock()),
    );
    _bumpShapeDrag();
  }

  /// Translate the selected rectangle by [cumulativeDeltaViewer] in the
  /// viewer's pixel space, reassigning its `pageIndex` when the bbox
  /// centre crosses into another registered page. The same cross-page
  /// logic [applyStampMoveViewer] uses, so a rectangle can be dragged
  /// from page A onto page B.
  void applyRectMoveViewer(Offset cumulativeDeltaViewer) {
    final state = _rectDragState;
    if (state == null) return;
    if (state.handle != PdfAnnotationHandle.body) return;

    final origPageInfo = _pageLayouts[state.originalPageIndex];
    if (origPageInfo == null) return;

    final newRectViewer = _pdfRectToViewer(state.originalRect, origPageInfo).shift(cumulativeDeltaViewer);
    final center = newRectViewer.center;

    var targetPageIdx = state.originalPageIndex;
    for (final entry in _pageLayouts.entries) {
      if (entry.value.viewerRect.contains(center)) {
        targetPageIdx = entry.key;
        break;
      }
    }
    final targetPageInfo = _pageLayouts[targetPageIdx];
    if (targetPageInfo == null) return;

    final newPdfRect = _viewerRectToPdf(newRectViewer, targetPageInfo);
    _replaceSelectedRect(
      (r) => r.copyWith(pageIndex: targetPageIdx, rectInPdfSpace: newPdfRect, updatedAt: _defaultClock()),
    );
    _bumpShapeDrag();
  }

  /// Resize the selected rectangle's bbox by applying
  /// [cumulativeDeltaPdf] to the handle captured at [beginRectDrag].
  ///
  /// Unlike a stamp, a corner drag does **not** lock the aspect ratio: a
  /// cover is sized to the passage it hides, not to a symbol's
  /// proportions. Each axis still clamps at [kMinAnnotationSizePts]
  /// rather than discarding the shape: discard-not-clamp applies to the
  /// creation gesture only.
  void applyRectResize(Offset cumulativeDeltaPdf) {
    final state = _rectDragState;
    if (state == null) return;
    final handle = state.handle;
    if (handle == PdfAnnotationHandle.body || handle == PdfAnnotationHandle.rotation) return;

    final newRect = resizeInLocalFrame(
      originalRect: state.originalRect,
      rotationDeg: state.originalRotation,
      handle: handle,
      delta: cumulativeDeltaPdf,
      lockAspect: false,
    );
    _replaceSelectedRect((r) => r.copyWith(rectInPdfSpace: newRect, updatedAt: _defaultClock()));
    _bumpShapeDrag();
  }

  /// Set the selected rectangle's rotation to [absoluteAngleDeg]
  /// (degrees, CCW about the centre). A free angle: nothing snaps.
  void applyRectRotate(double absoluteAngleDeg) {
    final state = _rectDragState;
    if (state == null) return;
    if (state.handle != PdfAnnotationHandle.rotation) return;
    _replaceSelectedRect((r) => r.copyWith(rotationDeg: absoluteAngleDeg, updatedAt: _defaultClock()));
    _bumpShapeDrag();
  }

  void _replaceSelectedRect(PdfRectAnnotation Function(PdfRectAnnotation) update) {
    final id = _selectedRectId.value;
    if (id == null) return;
    final idx = _rects.indexWhere((r) => r.id == id);
    if (idx < 0) return;
    _rects[idx] = update(_rects[idx]);
  }

  bool _ownsRect(PdfRectAnnotation r) => r.creatorName == _currentCreator;

  // ─────────────────────────── Text annotations ──────────────────────────

  /// `id` of the currently-selected text annotation, or `null` when none
  /// is selected. The text half of the shared gizmo's state.
  ValueListenable<String?> get selectedTextIdListenable => _selectedTextId;

  /// `id` of the text annotation whose inline edit is in progress, or
  /// `null` when there is none.
  ValueListenable<String?> get editingTextIdListenable => _editingTextId;

  /// Bumps on every [updateTextEdit], so the layer can re-box the inline
  /// editor as the text grows without repainting the page canvas.
  Listenable get textEditChangedListenable => _textEditTick;

  /// The annotation being edited, carrying the text typed so far, or
  /// `null` when no edit is in progress.
  ///
  /// It is deliberately NOT what [texts] holds. A new annotation joins
  /// the model at its first commit, and an existing one keeps its last
  /// committed text there, so an export taken mid-edit never carries a
  /// half-typed word.
  PdfTextAnnotation? get editingText => _textEdit?.working;

  /// Clear the current text annotation selection. Idempotent.
  void clearTextSelection() {
    if (_selectedTextId.value == null) return;
    _selectedTextId.value = null;
  }

  /// Select the text annotation [id]. A bandmate's text annotation
  /// cannot become selected (no-op), and selecting one drops any stamp
  /// or rectangle selection: one gizmo is on screen at a time.
  /// Idempotent.
  void selectText(String? id) {
    if (id == null) {
      clearTextSelection();
      return;
    }
    if (_selectedTextId.value == id) return;
    final text = _textById(id);
    if (text == null || !_ownsText(text)) return;
    clearStampSelection();
    clearRectSelection();
    _selectedTextId.value = id;
  }

  PdfTextAnnotation? _textById(String id) {
    for (final t in _texts) {
      if (t.id == id) return t;
    }
    return null;
  }

  bool _ownsText(PdfTextAnnotation t) => t.creatorName == _currentCreator;

  /// The text annotations on [pageIndex] the current creator may select,
  /// in reverse unified paint order: topmost first. A bandmate's text is
  /// skipped rather than ending the walk, by the rule
  /// [selectableRectsForHitTest] applies to rectangles.
  List<PdfTextAnnotation> selectableTextsForHitTest(int pageIndex) {
    final result = <PdfTextAnnotation>[];
    final sequence = paintSequenceForPage(pageIndex);
    for (var i = sequence.length - 1; i >= 0; i--) {
      final entry = sequence[i];
      if (entry is! PdfTextPaintEntry) continue;
      if (!_ownsText(entry.text)) continue;
      result.add(entry.text);
    }
    return result;
  }

  /// Start rubber-banding a text area on [pageIndex], anchored at
  /// [anchorPdfPoint]. Mirrors [startRectDraft]: the anchor stays pinned,
  /// no undo snapshot is pushed, and it is a no-op while a draft is
  /// already in flight.
  void startTextDraft({required int pageIndex, required Offset anchorPdfPoint, required Size pageSize}) {
    if (_textDraft != null) return;
    _textDraft = _TextAreaDraft(
      pageIndex: pageIndex,
      anchor: _clampPointInsidePage(anchorPdfPoint, pageSize),
      pageSize: pageSize,
    );
    _bumpRectDraft();
  }

  /// Move the in-flight text area's free corner to [freeCornerPdfPoint],
  /// clamped **componentwise** into the page and never translated to
  /// fit, for the reason [updateRectDraft] gives.
  void updateTextDraft(Offset freeCornerPdfPoint) {
    final draft = _textDraft;
    if (draft == null) return;
    draft.free = _clampPointInsidePage(freeCornerPdfPoint, draft.pageSize);
    _bumpRectDraft();
  }

  /// Discard the in-flight text area: the pointer-cancel path. Safe to
  /// call when no draft is in flight.
  void cancelTextDraft() {
    if (_textDraft == null) return;
    _textDraft = null;
    _bumpRectDraft();
  }

  /// Turn the in-flight rubber band into a text area and open its edit,
  /// returning the new annotation's id, or `null` when there was nothing
  /// to commit.
  ///
  /// A band below [kMinAnnotationSizePts] on either axis is not a text
  /// area: it is discarded and the caller falls through to its tap
  /// handling, as [commitRectDraft] documents, but at the pointer-DOWN
  /// point, because a tap point becomes the text's anchor.
  ///
  /// Unlike a rectangle, nothing joins the model and no undo snapshot is
  /// pushed here: that waits for the first commit of non-empty text.
  String? commitTextDraft({DateTime Function()? clock, String Function()? idGenerator}) {
    final draft = _textDraft;
    if (draft == null) return null;
    _textDraft = null;
    final rect = draft.rect;
    if (rect.width < kMinAnnotationSizePts || rect.height < kMinAnnotationSizePts) {
      _bumpRectDraft();
      return null;
    }
    return _beginNewTextEdit(
      pageIndex: draft.pageIndex,
      rect: rect,
      autoSize: false,
      pageSize: draft.pageSize,
      clock: clock,
      idGenerator: idGenerator,
    );
  }

  /// The in-flight text area's box on [pageIndex] (PDF points), or `null`
  /// when no rubber band is in flight there. Painted as an outline over
  /// everything committed.
  Rect? inFlightTextAreaFor(int pageIndex) {
    final draft = _textDraft;
    if (draft == null || draft.pageIndex != pageIndex) return null;
    return draft.rect;
  }

  /// Create auto-sized text whose top-left corner (the top-left of its
  /// first line) is [pdfPoint], and open its edit. Returns the new
  /// annotation's id, or `null` while another edit is in progress.
  ///
  /// The annotation is empty, carries no placeholder, and is not part of
  /// the model yet: see [commitTextEdit].
  String? createTextAt({
    required int pageIndex,
    required Offset pdfPoint,
    required Size pageSize,
    DateTime Function()? clock,
    String Function()? idGenerator,
  }) => _beginNewTextEdit(
    pageIndex: pageIndex,
    rect: _clampPointInsidePage(pdfPoint, pageSize) & Size.zero,
    autoSize: true,
    pageSize: pageSize,
    clock: clock,
    idGenerator: idGenerator,
  );

  String? _beginNewTextEdit({
    required int pageIndex,
    required Rect rect,
    required bool autoSize,
    required Size pageSize,
    DateTime Function()? clock,
    String Function()? idGenerator,
  }) {
    if (_textEdit != null) return null;
    final now = (clock ?? _defaultClock)();
    final id = (idGenerator ?? _defaultIdGenerator)();
    clearStampSelection();
    clearRectSelection();
    clearTextSelection();
    _startTextEdit(
      _TextEditSession(
        isNew: true,
        pageSize: pageSize,
        working: PdfTextAnnotation(
          id: id,
          pageIndex: pageIndex,
          rectInPdfSpace: rect,
          rotationDeg: 0,
          text: '',
          fontFamily: _annotationFonts.defaultFamily,
          autoSize: autoSize,
          createdAt: now,
          updatedAt: now,
          creatorName: _currentCreator,
        ),
      ),
    );
    return id;
  }

  /// Open an edit on the existing text annotation [id], which becomes
  /// the selection. No-op when it does not exist, belongs to a bandmate,
  /// or another edit is in progress.
  void beginTextEdit(String id, {required Size pageSize}) {
    if (_textEdit != null) return;
    final text = _textById(id);
    if (text == null || !_ownsText(text)) return;
    selectText(id);
    _startTextEdit(_TextEditSession(isNew: false, pageSize: pageSize, working: text));
  }

  void _startTextEdit(_TextEditSession session) {
    _textEdit = session;
    _editingTextId.value = session.working.id;
    // Undo and redo are off for the length of the edit: a snapshot
    // restored underneath an open editor would leave it editing an
    // annotation that is no longer there.
    _refreshHistoryListenables();
    // The canvas stops painting the annotation: the editor is its only
    // rendering for now.
    notifyListeners();
  }

  /// Replace the text typed so far. Touches neither the model nor the
  /// undo history: an edit session is one undo step, taken at commit.
  void updateTextEdit(String text) {
    final session = _textEdit;
    if (session == null || session.working.text == text) return;
    session.working = session.working.copyWith(text: text);
    _textEditTick.value++;
  }

  /// End the edit in progress and write it to the in-memory model. No-op
  /// when there is none.
  ///
  /// Text that is empty or whitespace-only discards the annotation: a
  /// new one leaves no trace, an existing one is deleted in one undo
  /// snapshot. Otherwise the session is exactly one undo step, and none
  /// at all when it changed nothing. The box written back is the display
  /// box, because a text edit is a mutation (see [textDisplayBoxFor]).
  ///
  /// [keepSelected] leaves the annotation selected with its gizmo up,
  /// which is what a tap outside or Escape wants; a tool switch and
  /// leaving annotation mode pass `false`.
  ///
  /// This never saves. Persisting stays where it is for every other
  /// kind: once, when annotation mode is left.
  void commitTextEdit({bool keepSelected = true, DateTime Function()? clock}) {
    final session = _textEdit;
    if (session == null) return;
    _textEdit = null;
    _editingTextId.value = null;

    final working = session.working;
    final id = working.id;
    final index = _texts.indexWhere((t) => t.id == id);
    final isEmpty = working.text.trim().isEmpty;
    var kept = !isEmpty;

    if (isEmpty) {
      if (index >= 0) {
        _pushUndoSnapshot();
        _texts.removeAt(index);
      }
    } else if (index < 0) {
      _pushUndoSnapshot();
      _texts.add(_withDisplayBox(working, session.pageSize));
    } else if (_texts[index].text != working.text) {
      _pushUndoSnapshot();
      _texts[index] = _withDisplayBox(working, session.pageSize).copyWith(updatedAt: (clock ?? _defaultClock)());
    } else {
      kept = true;
    }

    if (kept && keepSelected) {
      clearStampSelection();
      clearRectSelection();
      _selectedTextId.value = id;
    } else {
      clearTextSelection();
    }
    _refreshHistoryListenables();
    notifyListeners();
  }

  /// [text] with its display box written into its stored box.
  PdfTextAnnotation _withDisplayBox(PdfTextAnnotation text, Size pageSize) =>
      text.copyWith(rectInPdfSpace: textDisplayBoxFor(text, pageSize: pageSize).displayRect);

  /// Remove the text annotation [id]. No-op when it does not exist or
  /// belongs to a bandmate. Pushes one undo snapshot.
  void deleteText(String id) {
    final text = _textById(id);
    if (text == null) return;
    if (!_ownsText(text)) return;
    _pushUndoSnapshot();
    _texts.removeWhere((t) => t.id == id);
    if (_selectedTextId.value == id) _selectedTextId.value = null;
    notifyListeners();
  }

  /// Drops the edit in progress without committing it, for the paths
  /// where the document it belonged to is gone.
  void _abandonTextEdit() {
    if (_textEdit == null) return;
    _textEdit = null;
    _editingTextId.value = null;
  }

  /// Every committed-content mutation in this class ends in a
  /// [notifyListeners], so dropping the cached per-page paint sequences
  /// here catches all of them, including any added later.
  ///
  /// The in-flight tick is deliberately *not* routed through this: an
  /// in-flight stroke is painted outside the sequence, so a pointer
  /// sample must not cost a re-sort.
  @override
  void notifyListeners() {
    _paintSequences.clear();
    _pruneTextLayouts();
    super.notifyListeners();
  }

  /// Signals a live drag delta. Shapes are painted from the cached
  /// sequence, which holds the pre-drag geometry, so the cache has to go
  /// even though no listener on [notifyListeners] fires.
  void _bumpShapeDrag() {
    _paintSequences.clear();
    _stampDragTick.value++;
  }

  /// Signals an in-flight rubber-band frame.
  ///
  /// Unlike a drag, a draft changes nothing in the committed sequence:
  /// the preview is painted outside it, like an in-flight stroke. So the
  /// memo survives, and a rubber band costs no re-sort per pointer
  /// sample, which is the whole reason the sequence is cached.
  void _bumpRectDraft() => _stampDragTick.value++;

  void _replaceSelectedStamp(PdfStampAnnotation Function(PdfStampAnnotation) update) {
    final id = _selectedStampId.value;
    if (id == null) return;
    final idx = _stamps.indexWhere((s) => s.id == id);
    if (idx < 0) return;
    _stamps[idx] = update(_stamps[idx]);
  }

  /// In-flight strokes (only the start page's; max one) for layer
  /// rendering during the live drag.
  Iterable<PdfInkAnnotation> inFlightStrokesFor(int pageIndex) {
    final inFlight = _inFlight;
    if (inFlight == null || inFlight.pageIndex != pageIndex) return const [];
    if (inFlight.points.length < 2) return const [];
    return [
      PdfInkAnnotation(
        pageIndex: inFlight.pageIndex,
        pointsInPdfSpace: List<Offset>.unmodifiable(inFlight.points),
        lineWidth: inFlight.lineWidth,
        strokeColor: inFlight.strokeColor,
        opacity: inFlight.opacity,
        createdAt: inFlight.createdAt,
        updatedAt: inFlight.createdAt,
        creatorName: _currentCreator,
        kind: inFlight.kind,
      ),
    ];
  }

  @override
  void dispose() {
    _modeListenable.dispose();
    _inFlightTick.dispose();
    _eraserCursorTick.dispose();
    _stampDragTick.dispose();
    _toolListenable.dispose();
    _strokeColor.dispose();
    _strokeWidth.dispose();
    _highlighterColor.dispose();
    _highlighterWidth.dispose();
    _eraserRadius.dispose();
    _rectFillColor.dispose();
    _pendingStamp.dispose();
    _selectedStampId.dispose();
    _selectedRectId.dispose();
    _selectedTextId.dispose();
    _editingTextId.dispose();
    _textEditTick.dispose();
    _canUndo.dispose();
    _canRedo.dispose();
    _stampPictures.dispose();
    _clearTextLayouts();
    super.dispose();
  }
}

/// One annotation's memoized layout, the inputs it was laid out from, and
/// the display box last derived from it.
class _MemoizedTextLayout {
  _MemoizedTextLayout({
    required this.text,
    required this.style,
    required this.align,
    required this.wrapWidth,
    required this.layout,
  });

  final String text;
  final TextStyle style;
  final PdfTextAnnotationAlign align;
  final double wrapWidth;
  final PdfAnnotationTextLayout layout;

  Rect? storedRect;
  double? rotationDeg;
  bool? autoSize;
  Size? pageSize;
  PdfTextDisplayBox? box;

  void dispose() => layout.dispose();
}

DateTime _defaultClock() => DateTime.now().toUtc();

final math.Random _idRng = math.Random();

String _defaultIdGenerator() {
  final buf = StringBuffer();
  for (var i = 0; i < 24; i++) {
    buf.write(_idRng.nextInt(16).toRadixString(16));
  }
  return buf.toString();
}

Size _aspectFit(Size intrinsic, double longestSide) {
  if (intrinsic.width <= 0 || intrinsic.height <= 0) {
    return Size(longestSide, longestSide);
  }
  if (intrinsic.width >= intrinsic.height) {
    final h = longestSide * intrinsic.height / intrinsic.width;
    return Size(longestSide, h);
  }
  final w = longestSide * intrinsic.width / intrinsic.height;
  return Size(w, longestSide);
}

/// Clamps [point] componentwise into `[0, pageSize]` on both axes.
///
/// Componentwise is the whole point: the rubber band's free corner has
/// to stop at the page edge while the anchored corner stays exactly
/// where the finger went down.
Offset _clampPointInsidePage(Offset point, Size pageSize) =>
    Offset(point.dx.clamp(0.0, pageSize.width), point.dy.clamp(0.0, pageSize.height));

Rect _clampRectInsidePage(Rect rect, Size pageSize) {
  // Shift (don't shrink) so the bbox stays in [0, page) on both axes.
  // If the rect is wider/taller than the page, leave it as-is on that
  // axis (no shrink).
  var left = rect.left;
  var top = rect.top;
  if (rect.width <= pageSize.width) {
    if (left < 0) left = 0;
    final maxLeft = pageSize.width - rect.width;
    if (left > maxLeft) left = maxLeft;
  }
  if (rect.height <= pageSize.height) {
    if (top < 0) top = 0;
    final maxTop = pageSize.height - rect.height;
    if (top > maxTop) top = maxTop;
  }
  return Rect.fromLTWH(left, top, rect.width, rect.height);
}

class _AnnotationSnapshot {
  const _AnnotationSnapshot({
    required this.strokes,
    required this.stamps,
    required this.rects,
    required this.texts,
    required this.attachments,
  });

  final List<PdfInkAnnotation> strokes;
  final List<PdfStampAnnotation> stamps;
  final List<PdfRectAnnotation> rects;
  final List<PdfTextAnnotation> texts;
  final Map<String, PdfStampAttachment> attachments;
}

/// Geometry captured at the start of a move/resize/rotate drag, for a
/// shape of either kind: the mutators reconstruct the new state from the
/// original plus a cumulative delta, so the original must survive the
/// whole drag.
class _ShapeDragState {
  _ShapeDragState({
    required this.shapeId,
    required this.handle,
    required this.originalRect,
    required this.originalRotation,
    required this.originalPageIndex,
  });

  final String shapeId;
  final PdfAnnotationHandle handle;
  final Rect originalRect;
  final double originalRotation;
  final int originalPageIndex;
}

/// The in-flight rubber band: the anchor corner pinned at pointer-down,
/// the page it lives on, and the fill the committed rectangle will take.
class _RectDraft {
  _RectDraft({required this.pageIndex, required this.anchor, required this.pageSize, required this.fillColor})
    : free = anchor;

  final int pageIndex;
  final Offset anchor;
  final Size pageSize;
  final Color fillColor;

  /// The corner that follows the finger, already clamped into the page.
  Offset free;

  Rect get rect => Rect.fromPoints(anchor, free);
}

/// The in-flight text area rubber band: the anchor corner pinned at
/// pointer-down and the corner that follows the finger, already clamped
/// into the page.
class _TextAreaDraft {
  _TextAreaDraft({required this.pageIndex, required this.anchor, required this.pageSize}) : free = anchor;

  final int pageIndex;
  final Offset anchor;
  final Size pageSize;
  Offset free;

  Rect get rect => Rect.fromPoints(anchor, free);
}

/// One inline edit of a text annotation, from the editor opening to the
/// commit.
class _TextEditSession {
  _TextEditSession({required this.isNew, required this.pageSize, required this.working});

  /// Whether the annotation was created by this session, and so is not
  /// part of the model until it commits.
  final bool isNew;

  /// Size of the annotation's page, which its display box depends on.
  final Size pageSize;

  /// The annotation as typed so far.
  PdfTextAnnotation working;
}

class _PageLayoutInfo {
  _PageLayoutInfo({required this.viewerRect, required this.pageSize});

  final Rect viewerRect;
  final Size pageSize;
}

bool _segmentsCloseOrIntersect(Offset a1, Offset a2, Offset b1, Offset b2, double radius) {
  if (_segmentsIntersect(a1, a2, b1, b2)) return true;
  final d1 = _distancePointToSegment(a1, b1, b2);
  if (d1 <= radius) return true;
  final d2 = _distancePointToSegment(a2, b1, b2);
  if (d2 <= radius) return true;
  final d3 = _distancePointToSegment(b1, a1, a2);
  if (d3 <= radius) return true;
  final d4 = _distancePointToSegment(b2, a1, a2);
  return d4 <= radius;
}

bool _segmentsIntersect(Offset p1, Offset p2, Offset p3, Offset p4) {
  double cross(Offset o, Offset a, Offset b) => (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);
  final d1 = cross(p3, p4, p1);
  final d2 = cross(p3, p4, p2);
  final d3 = cross(p1, p2, p3);
  final d4 = cross(p1, p2, p4);
  return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
}

double _distancePointToSegment(Offset p, Offset a, Offset b) {
  final dx = b.dx - a.dx;
  final dy = b.dy - a.dy;
  final lenSq = dx * dx + dy * dy;
  if (lenSq == 0) return (p - a).distance;
  final t = (((p.dx - a.dx) * dx) + ((p.dy - a.dy) * dy)) / lenSq;
  final tc = t.clamp(0.0, 1.0);
  final qx = a.dx + tc * dx;
  final qy = a.dy + tc * dy;
  final ex = p.dx - qx;
  final ey = p.dy - qy;
  return math.sqrt(ex * ex + ey * ey);
}

class _InFlightStroke {
  _InFlightStroke({
    required this.pageIndex,
    required this.points,
    required this.lineWidth,
    required this.strokeColor,
    required this.opacity,
    required this.createdAt,
    required this.kind,
  });

  final int pageIndex;
  final List<Offset> points;
  final double lineWidth;
  final Color strokeColor;
  final double opacity;
  final DateTime createdAt;
  final PdfInkAnnotationKind kind;
}
