import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'instant_json.dart';
import 'pdf_ink_annotation.dart';

/// Internal annotation state for a `PdfViewer`. Owns the list of strokes,
/// the annotation-mode flag, and the in-flight stroke buffer.
///
/// Not exported from `pdfrx.dart`. Public access goes through
/// `PdfViewerController`'s annotation methods.
class PdfAnnotationController extends ChangeNotifier {
  final List<PdfInkAnnotation> _strokes = [];
  final ValueNotifier<bool> _modeListenable = ValueNotifier<bool>(false);
  final ValueNotifier<int> _inFlightTick = ValueNotifier<int>(0);

  _InFlightStroke? _inFlight;

  /// Bumps on every [appendPoint] so the live-drawing layer can repaint
  /// without rebuilding the committed-strokes painter.
  Listenable get inFlightChangedListenable => _inFlightTick;

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

  /// Enter annotation drawing mode. Idempotent — calling while mode is
  /// already `true` is a no-op (no listener notifications).
  void enterMode() {
    if (_modeListenable.value) return;
    _modeListenable.value = true;
  }

  /// Exit annotation drawing mode and, if [onAnnotationsChanged] is
  /// non-null, await it with the current Instant JSON snapshot. Idempotent —
  /// calling while mode is already `false` is a no-op (callback not invoked).
  Future<void> exitMode({required Future<void> Function(String json)? onAnnotationsChanged}) async {
    if (!_modeListenable.value) return;
    _modeListenable.value = false;
    if (onAnnotationsChanged != null) {
      await onAnnotationsChanged(exportJson());
    }
  }

  /// Read-only view of the committed strokes.
  List<PdfInkAnnotation> get strokes => List.unmodifiable(_strokes);

  /// Replace all strokes with [next] and notify listeners.
  void setAll(List<PdfInkAnnotation> next) {
    _strokes
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  /// Remove all strokes and notify listeners.
  void clear() {
    if (_strokes.isEmpty) return;
    _strokes.clear();
    notifyListeners();
  }

  /// Replace all strokes by decoding [json] in Instant JSON format.
  ///
  /// [pageCount] bounds-checks `pageIndex` entries; out-of-range entries
  /// are silently skipped. [defaultColor] / [defaultLineWidth] are used
  /// when an entry's stroke style is missing.
  void importJson(
    String json, {
    required int pageCount,
    required Color defaultColor,
    required double defaultLineWidth,
  }) {
    final decoded = decodeInstantJson(
      json,
      pageCount: pageCount,
      defaultColor: defaultColor,
      defaultLineWidth: defaultLineWidth,
    );
    setAll(decoded);
  }

  /// Serialize all strokes as an Instant JSON document.
  String exportJson() => encodeInstantJson(_strokes);

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
  /// points are discarded (cannot be painted). Notifies listeners.
  void commitStroke() {
    final inFlight = _inFlight;
    if (inFlight == null) return;
    _inFlight = null;
    if (inFlight.points.length < 2) {
      notifyListeners();
      return;
    }
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

  /// Append a fully-formed [stroke] to [strokes] and notify listeners.
  void addStroke(PdfInkAnnotation stroke) {
    _strokes.add(stroke);
    notifyListeners();
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
      ),
    ];
  }

  @override
  void dispose() {
    _modeListenable.dispose();
    _inFlightTick.dispose();
    super.dispose();
  }
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
