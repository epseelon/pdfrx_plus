import 'dart:math' as math;
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'instant_json.dart';
import 'pdf_ink_annotation.dart';
import 'pdf_stamp_annotation.dart';
import 'pdf_stamp_definition.dart';

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

  /// Navigation tool. Input is not captured by the annotation layer; the
  /// underlying viewer handles pan, scroll, tap, and pinch-zoom. No
  /// annotation is created.
  hand,
}

/// Active drag affordance on the currently-selected stamp. The annotation
/// layer captures one of these at pan-start and uses it to dispatch
/// subsequent updates to the corresponding controller mutator.
enum PdfStampHandle {
  /// Drag the stamp body to translate it.
  body,

  /// Drag the rotation handle (small circle inset below the top edge).
  rotation,

  /// Resize from the top-left corner.
  topLeft,

  /// Resize from the top edge midpoint (vertical-only).
  top,

  /// Resize from the top-right corner.
  topRight,

  /// Resize from the right edge midpoint (horizontal-only).
  right,

  /// Resize from the bottom-right corner.
  bottomRight,

  /// Resize from the bottom edge midpoint (vertical-only).
  bottom,

  /// Resize from the bottom-left corner.
  bottomLeft,

  /// Resize from the left edge midpoint (horizontal-only).
  left,
}

/// Minimum stamp width/height (PDF points) clamped during resize so the
/// affordances stay tappable.
const double kMinStampSizePts = 8.0;

/// Internal annotation state for a `PdfViewer`. Owns the list of strokes,
/// the annotation-mode flag, and the in-flight stroke buffer.
///
/// Not exported from `pdfrx.dart`. Public access goes through
/// `PdfViewerController`'s annotation methods.
class PdfAnnotationController extends ChangeNotifier {
  /// Default longest-side size (PDF points) used by [placeStamp] when
  /// the caller does not override the placement bbox.
  static const double _kDefaultStampLongestSidePts = 36.0;

  final List<PdfInkAnnotation> _strokes = [];
  final List<PdfStampAnnotation> _stamps = [];
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
  final ValueNotifier<PdfStampDefinition?> _pendingStamp = ValueNotifier<PdfStampDefinition?>(null);
  final ValueNotifier<String?> _selectedStampId = ValueNotifier<String?>(null);
  final List<_AnnotationSnapshot> _undoStack = [];
  final List<_AnnotationSnapshot> _redoStack = [];
  final ValueNotifier<bool> _canUndo = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _canRedo = ValueNotifier<bool>(false);

  String? _currentCreator;
  _InFlightStroke? _inFlight;
  Offset? _eraserPrevPoint;
  int? _eraserPrevPage;
  _StampDragState? _stampDragState;
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

  /// Read-only view of the placed stamp annotations.
  List<PdfStampAnnotation> get stamps => List.unmodifiable(_stamps);

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

  /// Enter annotation drawing mode.
  ///
  /// Idempotent — calling while mode is already `true` does not re-fire
  /// the mode listener. Any non-null override values ([tool],
  /// [strokeColor], [strokeWidth], [highlighterColor], [highlighterWidth],
  /// [eraserRadius]) are applied through the matching setters; null
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
  }) {
    _currentCreator = creatorName;
    if (tool != null) _toolListenable.value = tool;
    if (strokeColor != null) setStrokeColor(strokeColor);
    if (strokeWidth != null) setStrokeWidth(strokeWidth);
    if (highlighterColor != null) setHighlighterColor(highlighterColor);
    if (highlighterWidth != null) setHighlighterWidth(highlighterWidth);
    if (eraserRadius != null) setEraserRadius(eraserRadius);
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
    // Tear down transient stamp state before flipping mode off so the
    // selection overlay (handles + delete button) doesn't leak past
    // the session boundary, and any half-finished drag is dropped.
    if (_stampDragState != null) _stampDragState = null;
    if (_selectedStampId.value != null) _selectedStampId.value = null;
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

  /// Replace strokes, stamps, and attachments in a single update.
  /// History is cleared, listeners notified once.
  void setAllWithStamps({
    required List<PdfInkAnnotation> strokes,
    required List<PdfStampAnnotation> stamps,
    required Map<String, PdfStampAttachment> attachments,
  }) {
    _strokes
      ..clear()
      ..addAll(strokes);
    _stamps
      ..clear()
      ..addAll(stamps);
    _attachments
      ..clear()
      ..addAll(attachments);
    if (_selectedStampId.value != null) _selectedStampId.value = null;
    _undoStack.clear();
    _redoStack.clear();
    _refreshHistoryListenables();
    notifyListeners();
  }

  /// Remove all strokes, stamps, attachments, selection, and pending
  /// stamp (the last reset matches the spec's `clearAnnotations`
  /// contract). No-op when everything is already empty / null.
  void clear() {
    final hadStrokes = _strokes.isNotEmpty;
    final hadStamps = _stamps.isNotEmpty;
    final hadAttachments = _attachments.isNotEmpty;
    final hadSelection = _selectedStampId.value != null;
    final hadHistory = _undoStack.isNotEmpty || _redoStack.isNotEmpty;
    if (!hadStrokes && !hadStamps && !hadAttachments && !hadSelection && !hadHistory) {
      return;
    }
    _strokes.clear();
    _stamps.clear();
    _attachments.clear();
    if (hadSelection) _selectedStampId.value = null;
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
  /// document are imported as well.
  void importJson(String json, {required int pageCount}) {
    final decoded = decodeInstantJsonFull(
      json,
      pageCount: pageCount,
      defaultColor: _strokeColor.value,
      defaultLineWidth: _strokeWidth.value,
    );
    setAllWithStamps(strokes: decoded.strokes, stamps: decoded.stamps, attachments: decoded.attachments);
  }

  /// Serialize all strokes (and stamps + attachments, if any) as an
  /// Instant JSON document.
  String exportJson() => encodeInstantJson(_strokes, stamps: _stamps, attachments: _attachments);

  String _exportJsonForCreator(String? creator) {
    if (creator == null) return encodeInstantJson(_strokes, stamps: _stamps, attachments: _attachments);
    final mineStrokes = _strokes.where((s) => s.creatorName == creator).toList(growable: false);
    final mineStamps = _stamps.where((s) => s.creatorName == creator).toList(growable: false);
    return encodeInstantJson(mineStrokes, stamps: mineStamps, attachments: _attachments);
  }

  /// Switch the active tool. No-op if [tool] is already active. Clears
  /// any current stamp selection and pending stamp on tool change.
  void setTool(PdfAnnotationTool tool) {
    if (_toolListenable.value == tool) return;
    _toolListenable.value = tool;
    if (_selectedStampId.value != null) _selectedStampId.value = null;
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
  void commitStroke() {
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
    if (_undoStack.isEmpty) return;
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
    if (_redoStack.isEmpty) return;
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

  _AnnotationSnapshot _currentSnapshot() {
    return _AnnotationSnapshot(
      strokes: List<PdfInkAnnotation>.unmodifiable(_strokes),
      stamps: List<PdfStampAnnotation>.unmodifiable(_stamps),
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
    _attachments
      ..clear()
      ..addAll(snapshot.attachments);
    final selectedId = _selectedStampId.value;
    if (selectedId != null && !_stamps.any((s) => s.id == selectedId)) {
      _selectedStampId.value = null;
    }
  }

  void _refreshHistoryListenables() {
    final canUndo = _undoStack.isNotEmpty;
    if (_canUndo.value != canUndo) _canUndo.value = canUndo;
    final canRedo = _redoStack.isNotEmpty;
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
  void selectStamp(String? id) {
    if (id == null) {
      clearStampSelection();
      return;
    }
    if (_selectedStampId.value == id) return;
    final stamp = _stampById(id);
    if (stamp == null || !_ownsStamp(stamp)) return;
    _selectedStampId.value = id;
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
  void beginStampDrag(PdfStampHandle handle) {
    if (_stampDragState != null) return;
    final id = _selectedStampId.value;
    if (id == null) return;
    final stamp = _stampById(id);
    if (stamp == null || !_ownsStamp(stamp)) return;
    _pushUndoSnapshot();
    _stampDragState = _StampDragState(
      stampId: id,
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
    if (state.handle != PdfStampHandle.body) return;
    final newRect = state.originalRect.shift(cumulativeDeltaPdf);
    _replaceSelectedStamp((s) => s.copyWith(rectInPdfSpace: newRect, updatedAt: _defaultClock()));
    _stampDragTick.value++;
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
  /// [PdfStampHandle.body], or the original page's layout is no longer
  /// registered.
  void applyStampMoveViewer(Offset cumulativeDeltaViewer) {
    final state = _stampDragState;
    if (state == null) return;
    if (state.handle != PdfStampHandle.body) return;

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
    _stampDragTick.value++;
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
  /// Corner handles preserve the bbox's aspect ratio at drag-start —
  /// the dominant axis (the one the cursor pulls further in proportion
  /// to its original size) drives a uniform scale; the opposite corner
  /// anchors. Edge handles stretch a single axis. Both modes clamp each
  /// axis to [kMinStampSizePts]. Bumps [stampDragChangedListenable].
  void applyStampResize(Offset cumulativeDeltaPdf) {
    final state = _stampDragState;
    if (state == null) return;
    final handle = state.handle;
    if (handle == PdfStampHandle.body || handle == PdfStampHandle.rotation) return;

    final orig = state.originalRect;
    final dx = cumulativeDeltaPdf.dx;
    final dy = cumulativeDeltaPdf.dy;

    final newRect = _isCornerHandle(handle)
        ? _resizeCornerLocked(orig: orig, handle: handle, dx: dx, dy: dy)
        : _resizeEdge(orig: orig, handle: handle, dx: dx, dy: dy);

    _replaceSelectedStamp((s) => s.copyWith(rectInPdfSpace: newRect, updatedAt: _defaultClock()));
    _stampDragTick.value++;
  }

  static bool _isCornerHandle(PdfStampHandle h) =>
      h == PdfStampHandle.topLeft ||
      h == PdfStampHandle.topRight ||
      h == PdfStampHandle.bottomLeft ||
      h == PdfStampHandle.bottomRight;

  Rect _resizeCornerLocked({
    required Rect orig,
    required PdfStampHandle handle,
    required double dx,
    required double dy,
  }) {
    // Per-axis candidate dims based on the raw cursor delta.
    double candidateWidth;
    double candidateHeight;
    switch (handle) {
      case PdfStampHandle.topLeft:
        candidateWidth = orig.width - dx;
        candidateHeight = orig.height - dy;
      case PdfStampHandle.topRight:
        candidateWidth = orig.width + dx;
        candidateHeight = orig.height - dy;
      case PdfStampHandle.bottomLeft:
        candidateWidth = orig.width - dx;
        candidateHeight = orig.height + dy;
      case PdfStampHandle.bottomRight:
        candidateWidth = orig.width + dx;
        candidateHeight = orig.height + dy;
      // ignore: no_default_cases
      default:
        candidateWidth = orig.width;
        candidateHeight = orig.height;
    }

    // Pick the dominant axis by proportional change away from 1.0;
    // the loser is recomputed from the original aspect ratio.
    final scaleW = candidateWidth / orig.width;
    final scaleH = candidateHeight / orig.height;
    var scale = (scaleW - 1).abs() >= (scaleH - 1).abs() ? scaleW : scaleH;

    // Min-size clamp respects aspect: pick the larger of the two
    // axis-specific min scales so neither dim drops below the limit.
    final minScale = math.max(kMinStampSizePts / orig.width, kMinStampSizePts / orig.height);
    if (scale < minScale) scale = minScale;

    final newWidth = orig.width * scale;
    final newHeight = orig.height * scale;

    // Anchor on the opposite corner.
    switch (handle) {
      case PdfStampHandle.topLeft:
        return Rect.fromLTRB(orig.right - newWidth, orig.bottom - newHeight, orig.right, orig.bottom);
      case PdfStampHandle.topRight:
        return Rect.fromLTRB(orig.left, orig.bottom - newHeight, orig.left + newWidth, orig.bottom);
      case PdfStampHandle.bottomLeft:
        return Rect.fromLTRB(orig.right - newWidth, orig.top, orig.right, orig.top + newHeight);
      case PdfStampHandle.bottomRight:
        return Rect.fromLTRB(orig.left, orig.top, orig.left + newWidth, orig.top + newHeight);
      // ignore: no_default_cases
      default:
        return orig;
    }
  }

  Rect _resizeEdge({required Rect orig, required PdfStampHandle handle, required double dx, required double dy}) {
    var left = orig.left;
    var top = orig.top;
    var right = orig.right;
    var bottom = orig.bottom;

    if (handle == PdfStampHandle.left) {
      left = orig.left + dx;
      if (right - left < kMinStampSizePts) left = right - kMinStampSizePts;
    } else if (handle == PdfStampHandle.right) {
      right = orig.right + dx;
      if (right - left < kMinStampSizePts) right = left + kMinStampSizePts;
    } else if (handle == PdfStampHandle.top) {
      top = orig.top + dy;
      if (bottom - top < kMinStampSizePts) top = bottom - kMinStampSizePts;
    } else if (handle == PdfStampHandle.bottom) {
      bottom = orig.bottom + dy;
      if (bottom - top < kMinStampSizePts) bottom = top + kMinStampSizePts;
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  /// Set the selected stamp's rotation to [absoluteAngleDeg] (degrees,
  /// CCW). Caller is responsible for atan2 of (cursor − centroid) etc.
  /// Bumps [stampDragChangedListenable].
  void applyStampRotate(double absoluteAngleDeg) {
    final state = _stampDragState;
    if (state == null) return;
    if (state.handle != PdfStampHandle.rotation) return;
    _replaceSelectedStamp((s) => s.copyWith(rotationDeg: absoluteAngleDeg, updatedAt: _defaultClock()));
    _stampDragTick.value++;
  }

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
    _pendingStamp.dispose();
    _selectedStampId.dispose();
    _canUndo.dispose();
    _canRedo.dispose();
    super.dispose();
  }
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
  const _AnnotationSnapshot({required this.strokes, required this.stamps, required this.attachments});

  final List<PdfInkAnnotation> strokes;
  final List<PdfStampAnnotation> stamps;
  final Map<String, PdfStampAttachment> attachments;
}

class _StampDragState {
  _StampDragState({
    required this.stampId,
    required this.handle,
    required this.originalRect,
    required this.originalRotation,
    required this.originalPageIndex,
  });

  final String stampId;
  final PdfStampHandle handle;
  final Rect originalRect;
  final double originalRotation;
  final int originalPageIndex;
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
