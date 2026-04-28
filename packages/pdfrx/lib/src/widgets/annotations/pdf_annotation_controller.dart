import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'instant_json.dart';
import 'pdf_ink_annotation.dart';

/// Active annotation tool while [PdfAnnotationController.annotationModeListenable]
/// is `true`.
enum PdfAnnotationTool {
  /// Default. Pan input creates new ink strokes.
  pen,

  /// Pan input erases existing strokes that the current session owns.
  eraser,
}

/// Internal annotation state for a `PdfViewer`. Owns the list of strokes,
/// the annotation-mode flag, and the in-flight stroke buffer.
///
/// Not exported from `pdfrx.dart`. Public access goes through
/// `PdfViewerController`'s annotation methods.
class PdfAnnotationController extends ChangeNotifier {
  final List<PdfInkAnnotation> _strokes = [];
  final ValueNotifier<bool> _modeListenable = ValueNotifier<bool>(false);
  final ValueNotifier<int> _inFlightTick = ValueNotifier<int>(0);
  final ValueNotifier<int> _eraserCursorTick = ValueNotifier<int>(0);
  final ValueNotifier<PdfAnnotationTool> _toolListenable = ValueNotifier<PdfAnnotationTool>(PdfAnnotationTool.pen);
  final ValueNotifier<Color> _strokeColor = ValueNotifier<Color>(const Color(0xFFFF3B30));
  final ValueNotifier<double> _strokeWidth = ValueNotifier<double>(2.0);
  final ValueNotifier<double> _eraserRadius = ValueNotifier<double>(10.0);
  final List<List<PdfInkAnnotation>> _undoStack = [];
  final List<List<PdfInkAnnotation>> _redoStack = [];
  final ValueNotifier<bool> _canUndo = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _canRedo = ValueNotifier<bool>(false);

  String? _currentCreator;
  _InFlightStroke? _inFlight;
  Offset? _eraserPrevPoint;
  int? _eraserPrevPage;

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

  /// Stroke color applied to every new ink stroke (the layer reads this
  /// at pan-start and bakes it into the committed annotation). Persists
  /// across `enterMode` / `exitMode` cycles.
  ValueListenable<Color> get strokeColorListenable => _strokeColor;

  /// Current stroke color value. See [strokeColorListenable] for change
  /// notifications.
  Color get strokeColor => _strokeColor.value;

  /// Stroke width (PDF points) applied to every new ink stroke. Persists
  /// across `enterMode` / `exitMode` cycles.
  ValueListenable<double> get strokeWidthListenable => _strokeWidth;

  /// Current stroke width value. See [strokeWidthListenable] for change
  /// notifications.
  double get strokeWidth => _strokeWidth.value;

  /// Hit radius (PDF points) used by the eraser tool to decide whether a
  /// stroke segment is touched, and the size of the on-screen eraser
  /// cursor preview. Persists across `enterMode` / `exitMode` cycles.
  ValueListenable<double> get eraserRadiusListenable => _eraserRadius;

  /// Current eraser radius value. See [eraserRadiusListenable] for change
  /// notifications.
  double get eraserRadius => _eraserRadius.value;

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

  /// Replace the active eraser radius (PDF points). Idempotent.
  void setEraserRadius(double value) {
    if (_eraserRadius.value == value) return;
    _eraserRadius.value = value;
  }

  /// Enter annotation drawing mode.
  ///
  /// Idempotent — calling while mode is already `true` does not re-fire
  /// the mode listener. Any non-null override values ([tool],
  /// [strokeColor], [strokeWidth], [eraserRadius]) are applied through
  /// the matching setters; null overrides keep the previously-set value
  /// (the controller remembers tool/color/thickness across mode
  /// toggles).
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
    double? eraserRadius,
  }) {
    _currentCreator = creatorName;
    if (tool != null) _toolListenable.value = tool;
    if (strokeColor != null) setStrokeColor(strokeColor);
    if (strokeWidth != null) setStrokeWidth(strokeWidth);
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

  /// Remove all strokes and notify listeners.
  void clear() {
    if (_strokes.isEmpty) return;
    _strokes.clear();
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
  /// is missing those fields.
  void importJson(String json, {required int pageCount}) {
    final decoded = decodeInstantJson(
      json,
      pageCount: pageCount,
      defaultColor: _strokeColor.value,
      defaultLineWidth: _strokeWidth.value,
    );
    setAll(decoded);
  }

  /// Serialize all strokes as an Instant JSON document.
  String exportJson() => encodeInstantJson(_strokes);

  String _exportJsonForCreator(String? creator) {
    if (creator == null) return encodeInstantJson(_strokes);
    final mine = _strokes.where((s) => s.creatorName == creator).toList(growable: false);
    return encodeInstantJson(mine);
  }

  /// Switch the active tool. No-op if [tool] is already active.
  void setTool(PdfAnnotationTool tool) {
    if (_toolListenable.value == tool) return;
    _toolListenable.value = tool;
  }

  /// Begin a new in-flight stroke anchored to [pageIndex] starting at
  /// [firstPoint] (PDF point space, top-left origin). Notifies listeners so
  /// the layer can paint the new stroke as it grows.
  void startStroke({
    required int pageIndex,
    required Offset firstPoint,
    required double lineWidth,
    required Color strokeColor,
    required double opacity,
  }) {
    final now = DateTime.now().toUtc();
    _inFlight = _InFlightStroke(
      pageIndex: pageIndex,
      points: [firstPoint],
      lineWidth: lineWidth,
      strokeColor: strokeColor,
      opacity: opacity,
      createdAt: now,
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

  /// Pop the most recent undo snapshot and restore it as the current
  /// stroke list. The displaced state is pushed onto the redo stack so
  /// it can be restored by [redo].
  ///
  /// No-op when [canUndoListenable] is `false` — does not throw, does
  /// not notify listeners.
  void undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(List<PdfInkAnnotation>.unmodifiable(_strokes));
    final snapshot = _undoStack.removeLast();
    _strokes
      ..clear()
      ..addAll(snapshot);
    _refreshHistoryListenables();
    notifyListeners();
  }

  /// Pop the most recent redo snapshot and restore it as the current
  /// stroke list. The displaced state is pushed onto the undo stack so
  /// it can be restored by [undo].
  ///
  /// No-op when [canRedoListenable] is `false` — does not throw, does
  /// not notify listeners.
  void redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(List<PdfInkAnnotation>.unmodifiable(_strokes));
    final snapshot = _redoStack.removeLast();
    _strokes
      ..clear()
      ..addAll(snapshot);
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
            ),
          );
        }
        runStart = -1;
      }
    }
    return result;
  }

  bool _ownsStroke(PdfInkAnnotation s) => s.creatorName == _currentCreator;

  void _pushUndoSnapshot() {
    _undoStack.add(List<PdfInkAnnotation>.unmodifiable(_strokes));
    _redoStack.clear();
    _refreshHistoryListenables();
  }

  void _refreshHistoryListenables() {
    final canUndo = _undoStack.isNotEmpty;
    if (_canUndo.value != canUndo) _canUndo.value = canUndo;
    final canRedo = _redoStack.isNotEmpty;
    if (_canRedo.value != canRedo) _canRedo.value = canRedo;
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
      ),
    ];
  }

  @override
  void dispose() {
    _modeListenable.dispose();
    _inFlightTick.dispose();
    _eraserCursorTick.dispose();
    _toolListenable.dispose();
    _strokeColor.dispose();
    _strokeWidth.dispose();
    _eraserRadius.dispose();
    _canUndo.dispose();
    _canRedo.dispose();
    super.dispose();
  }
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
  });

  final int pageIndex;
  final List<Offset> points;
  final double lineWidth;
  final Color strokeColor;
  final double opacity;
  final DateTime createdAt;
}
