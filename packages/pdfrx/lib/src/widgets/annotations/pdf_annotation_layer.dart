import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pdfrx_engine/pdfrx_engine.dart';

import 'pdf_annotation_controller.dart';
import 'pdf_ink_annotation.dart';
import 'pdf_stamp_annotation.dart';
import 'pdf_stamp_definition.dart';

/// Internal per-page widget that paints all [PdfInkAnnotation]s and
/// [PdfStampAnnotation]s anchored to [page]. Mounted by `PdfViewer` for
/// every visible page.
///
/// Coordinates are converted from PDF point space (top-left origin) to
/// widget pixels using the page's current display rect. Strokes that
/// extend past the page bounds are visually clipped.
///
/// While [PdfAnnotationController.annotationModeListenable] is `true`, a
/// per-page [GestureDetector] is mounted on top of the painter to capture
/// pan and tap input. The active tool ([PdfAnnotationController.currentToolListenable])
/// determines whether pan input draws ([PdfAnnotationTool.pen]), erases
/// ([PdfAnnotationTool.eraser]), or places/manipulates stamps
/// ([PdfAnnotationTool.stamp]). Page rotation is assumed to be `0°`
/// (see spec §17).
class PdfAnnotationLayer extends StatefulWidget {
  const PdfAnnotationLayer({
    required this.controller,
    required this.page,
    required this.pageRect,
    required this.highlighterOpacity,
    this.stampImageBuilder,
    super.key,
  });

  final PdfAnnotationController controller;
  final PdfPage page;
  final Rect pageRect;

  /// Opacity stamped onto every newly-committed highlighter stroke. The
  /// caller (the `PdfViewer`) sources this from
  /// `PdfViewerParams.highlighterOpacity`. The layer clamps to
  /// `[0.0, 1.0]` at use time, so out-of-range values from the params
  /// are silently coerced rather than rejected.
  final double highlighterOpacity;

  /// Optional builder for stamp widgets. When `null` (the host did not
  /// supply a renderer), stamps still render as a transparent
  /// placeholder; placement gestures still work for testing.
  final PdfStampImageBuilder? stampImageBuilder;

  @override
  State<PdfAnnotationLayer> createState() => _PdfAnnotationLayerState();
}

// Selection-overlay sizing constants. Handles render at fixed *screen*
// pixels regardless of zoom.
const double _kHandleScreenPx = 10.0;
const double _kHandleHitRadiusPx = 14.0;
const double _kRotateHandleInsetPx = 6.0;
const double _kDeleteButtonPx = 24.0;
const double _kSelectionOutlinePx = 1.5;

class _PdfAnnotationLayerState extends State<PdfAnnotationLayer> {
  // Drag bookkeeping captured at pan-start so subsequent updates can be
  // routed without re-hit-testing.
  PdfStampHandle? _activeHandle;
  Offset? _panStartLocal;
  Offset? _stampCenterLocal;
  double? _initialRotationAngle;
  double? _originalStampRotationDeg;

  PdfAnnotationController get _controller => widget.controller;
  PdfPage get _page => widget.page;
  Rect get _pageRect => widget.pageRect;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _controller.annotationModeListenable,
      builder: (context, modeOn, _) {
        return IgnorePointer(
          ignoring: !modeOn,
          child: AnimatedBuilder(
            animation: Listenable.merge([_controller, _controller.stampDragChangedListenable]),
            builder: (context, _) {
              final committed = _controller.strokes
                  .where((s) => s.pageIndex == _page.pageNumber - 1)
                  .toList(growable: false);
              final pageStamps = _controller.stamps
                  .where((s) => s.pageIndex == _page.pageNumber - 1)
                  .toList(growable: false);
              final scaleX = _pageRect.width / _page.width;
              final scaleY = _pageRect.height / _page.height;

              final selectedId = _controller.selectedStampIdListenable.value;
              final selectedStamp = selectedId == null ? null : _findSelected(pageStamps, selectedId);

              return Stack(
                children: [
                  CustomPaint(
                    painter: InkPainter(
                      strokes: committed,
                      inFlightProvider: () => _controller.inFlightStrokesFor(_page.pageNumber - 1),
                      eraserCursorProvider: () => _controller.eraserCursorPageIndex == _page.pageNumber - 1
                          ? _controller.eraserCursorPdfPoint
                          : null,
                      eraserRadiusProvider: () => _controller.eraserRadius,
                      repaint: Listenable.merge([
                        _controller.inFlightChangedListenable,
                        _controller.eraserCursorChangedListenable,
                        _controller.eraserRadiusListenable,
                      ]),
                      pageWidth: _page.width,
                      pageHeight: _page.height,
                    ),
                    size: _pageRect.size,
                  ),
                  for (final stamp in pageStamps)
                    Positioned(
                      key: Key('stamp:${stamp.id}'),
                      left: stamp.rectInPdfSpace.left * scaleX,
                      top: stamp.rectInPdfSpace.top * scaleY,
                      width: stamp.rectInPdfSpace.width * scaleX,
                      height: stamp.rectInPdfSpace.height * scaleY,
                      child: Transform.rotate(
                        angle: -stamp.rotationDeg * math.pi / 180.0,
                        child: SizedBox(
                          width: stamp.rectInPdfSpace.width * scaleX,
                          height: stamp.rectInPdfSpace.height * scaleY,
                          child: _buildStampChild(context, stamp, scaleX, scaleY),
                        ),
                      ),
                    ),
                  if (selectedStamp != null) _buildSelectionOverlay(selectedStamp, scaleX, scaleY),
                  if (modeOn)
                    Positioned.fill(
                      child: ValueListenableBuilder<PdfAnnotationTool>(
                        valueListenable: _controller.currentToolListenable,
                        builder: (context, tool, _) => GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapUp: (details) => _onTapUp(tool, details.localPosition),
                          onPanStart: (details) => _onPanStart(tool, details.localPosition),
                          onPanUpdate: (details) => _onPanUpdate(tool, details.localPosition),
                          onPanEnd: (_) => _onPanEnd(tool),
                          onPanCancel: () => _onPanCancel(tool),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  PdfStampAnnotation? _findSelected(List<PdfStampAnnotation> pageStamps, String id) {
    for (final s in pageStamps) {
      if (s.id == id) return s;
    }
    return null;
  }

  Widget _buildStampChild(BuildContext context, PdfStampAnnotation stamp, double scaleX, double scaleY) {
    final builder = widget.stampImageBuilder;
    final attachment = _controller.attachments[stamp.attachmentSha256];
    if (builder == null || attachment == null) {
      return const SizedBox.shrink();
    }
    final displaySize = Size(stamp.rectInPdfSpace.width * scaleX, stamp.rectInPdfSpace.height * scaleY);
    return builder(context, attachment.bytes, stamp.contentType, displaySize);
  }

  Widget _buildSelectionOverlay(PdfStampAnnotation stamp, double scaleX, double scaleY) {
    final left = stamp.rectInPdfSpace.left * scaleX;
    final top = stamp.rectInPdfSpace.top * scaleY;
    final width = stamp.rectInPdfSpace.width * scaleX;
    final height = stamp.rectInPdfSpace.height * scaleY;
    final color = Theme.of(context).colorScheme.primary;

    return Positioned(
      key: Key('stampSelection:${stamp.id}'),
      left: left,
      top: top,
      width: width,
      height: height,
      child: IgnorePointer(
        // Affordances are visual only; the gesture detector sitting on
        // top of the stack handles their hit-tests via PDF-space math.
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Outline traced just inside the bbox.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: color, width: _kSelectionOutlinePx),
                ),
              ),
            ),
            // Resize handles at corners + edge midpoints.
            for (final handle in _resizeHandles)
              Positioned(
                left: _handleX(handle, width) - _kHandleScreenPx / 2,
                top: _handleY(handle, height) - _kHandleScreenPx / 2,
                width: _kHandleScreenPx,
                height: _kHandleScreenPx,
                child: Semantics(
                  label: 'Resize ${_handleLabel(handle)}',
                  button: true,
                  child: DecoratedBox(decoration: BoxDecoration(color: color)),
                ),
              ),
            // Rotation handle (small filled circle inset below the top edge).
            Positioned(
              left: width / 2 - _kHandleScreenPx / 2,
              top: _kRotateHandleInsetPx,
              width: _kHandleScreenPx,
              height: _kHandleScreenPx,
              child: Semantics(
                label: 'Rotate stamp',
                button: true,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
              ),
            ),
            // Delete IconButton anchored at the inner top-right.
            Positioned(
              right: 2,
              top: 2,
              width: _kDeleteButtonPx,
              height: _kDeleteButtonPx,
              child: Semantics(
                label: 'Delete stamp',
                button: true,
                child: Material(
                  color: Theme.of(context).colorScheme.surface,
                  shape: const CircleBorder(),
                  elevation: 2,
                  child: const Icon(Icons.close, size: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static const _resizeHandles = <PdfStampHandle>[
    PdfStampHandle.topLeft,
    PdfStampHandle.top,
    PdfStampHandle.topRight,
    PdfStampHandle.right,
    PdfStampHandle.bottomRight,
    PdfStampHandle.bottom,
    PdfStampHandle.bottomLeft,
    PdfStampHandle.left,
  ];

  String _handleLabel(PdfStampHandle h) => switch (h) {
    PdfStampHandle.topLeft => 'top-left',
    PdfStampHandle.top => 'top',
    PdfStampHandle.topRight => 'top-right',
    PdfStampHandle.right => 'right',
    PdfStampHandle.bottomRight => 'bottom-right',
    PdfStampHandle.bottom => 'bottom',
    PdfStampHandle.bottomLeft => 'bottom-left',
    PdfStampHandle.left => 'left',
    PdfStampHandle.body => 'body',
    PdfStampHandle.rotation => 'rotation',
  };

  double _handleX(PdfStampHandle h, double width) => switch (h) {
    PdfStampHandle.topLeft || PdfStampHandle.left || PdfStampHandle.bottomLeft => 0,
    PdfStampHandle.top || PdfStampHandle.bottom => width / 2,
    PdfStampHandle.topRight || PdfStampHandle.right || PdfStampHandle.bottomRight => width,
    _ => width / 2,
  };

  double _handleY(PdfStampHandle h, double height) => switch (h) {
    PdfStampHandle.topLeft || PdfStampHandle.top || PdfStampHandle.topRight => 0,
    PdfStampHandle.left || PdfStampHandle.right => height / 2,
    PdfStampHandle.bottomLeft || PdfStampHandle.bottom || PdfStampHandle.bottomRight => height,
    _ => height / 2,
  };

  // Hit-test helpers — all in widget-local space.

  /// Returns the topmost selectable stamp (current creator's) whose
  /// rect contains the local point, or null. Iterates in reverse Z so
  /// the most recently placed stamp wins overlap resolution.
  PdfStampAnnotation? _hitTestSelectableStampBody(List<PdfStampAnnotation> pageStamps, Offset local) {
    for (var i = pageStamps.length - 1; i >= 0; i--) {
      final s = pageStamps[i];
      if (s.creatorName != _controller.currentCreator) continue;
      if (_stampLocalRect(s).contains(local)) return s;
    }
    return null;
  }

  /// Returns the first stamp (any creator) whose rect contains the
  /// local point — used purely to decide that "a stamp is here, fall
  /// through to placement only if it's foreign-creator".
  PdfStampAnnotation? _hitTestAnyStampBody(List<PdfStampAnnotation> pageStamps, Offset local) {
    for (var i = pageStamps.length - 1; i >= 0; i--) {
      final s = pageStamps[i];
      if (_stampLocalRect(s).contains(local)) return s;
    }
    return null;
  }

  Rect _stampLocalRect(PdfStampAnnotation stamp) {
    final scaleX = _pageRect.width / _page.width;
    final scaleY = _pageRect.height / _page.height;
    return Rect.fromLTWH(
      stamp.rectInPdfSpace.left * scaleX,
      stamp.rectInPdfSpace.top * scaleY,
      stamp.rectInPdfSpace.width * scaleX,
      stamp.rectInPdfSpace.height * scaleY,
    );
  }

  /// Returns the handle (corner/edge/rotation/body/delete) of [stamp]
  /// hit by [local], or `null` if no affordance is within hit-radius.
  /// `body` is returned only when the local point is inside the bbox
  /// but no other affordance is closer.
  _StampHitTestResult? _hitTestStampHandles(PdfStampAnnotation stamp, Offset local) {
    final rect = _stampLocalRect(stamp);
    // Delete button: top-right of bbox, _kDeleteButtonPx square.
    final deleteRect = Rect.fromLTWH(
      rect.right - _kDeleteButtonPx - 2,
      rect.top + 2,
      _kDeleteButtonPx,
      _kDeleteButtonPx,
    );
    if (deleteRect.inflate(2).contains(local)) {
      return _StampHitTestResult.delete();
    }
    // Resize handles.
    for (final h in _resizeHandles) {
      final hx = rect.left + _handleX(h, rect.width);
      final hy = rect.top + _handleY(h, rect.height);
      if ((local - Offset(hx, hy)).distance <= _kHandleHitRadiusPx) {
        return _StampHitTestResult.handle(h);
      }
    }
    // Rotation handle.
    final rotX = rect.left + rect.width / 2;
    final rotY = rect.top + _kRotateHandleInsetPx;
    if ((local - Offset(rotX, rotY)).distance <= _kHandleHitRadiusPx) {
      return _StampHitTestResult.handle(PdfStampHandle.rotation);
    }
    // Body fallback.
    if (rect.contains(local)) return _StampHitTestResult.handle(PdfStampHandle.body);
    return null;
  }

  void _onTapUp(PdfAnnotationTool tool, Offset local) {
    if (tool != PdfAnnotationTool.stamp) return;
    final pageStamps = _pageStamps();
    final selectedId = _controller.selectedStampIdListenable.value;

    // Delete-button tap on the selected stamp wins outright.
    if (selectedId != null) {
      final selected = _findSelected(pageStamps, selectedId);
      if (selected != null) {
        final hit = _hitTestStampHandles(selected, local);
        if (hit != null && hit.isDelete) {
          _controller.deleteStamp(selected.id);
          return;
        }
      }
    }

    final pending = _controller.pendingStampListenable.value;

    // Selectable stamp under the tap → select.
    final selectable = _hitTestSelectableStampBody(pageStamps, local);
    if (selectable != null) {
      _controller.selectStamp(selectable.id);
      // Clear pending so subsequent taps don't drop a new stamp.
      if (pending != null) _controller.setPendingStamp(null);
      return;
    }

    // Foreign-creator stamp under the tap → fall through to place /
    // deselect (the spec calls for transparency to the place branch).
    final any = _hitTestAnyStampBody(pageStamps, local);
    final overForeign = any != null && any.creatorName != _controller.currentCreator;

    if (pending != null && (any == null || overForeign)) {
      unawaited(_placePendingStamp(pending, local));
      return;
    }

    // No pending and tap landed on empty area (or only over foreign
    // stamps) — clear selection.
    _controller.clearStampSelection();
  }

  List<PdfStampAnnotation> _pageStamps() =>
      _controller.stamps.where((s) => s.pageIndex == _page.pageNumber - 1).toList(growable: false);

  Future<void> _placePendingStamp(PdfStampDefinition pending, Offset local) async {
    try {
      final bytes = await pending.bytesLoader();
      final pdfPoint = _toPdfSpace(local);
      _controller.placeStamp(
        bytes: bytes,
        contentType: pending.contentType,
        pageIndex: _page.pageNumber - 1,
        pdfPoint: pdfPoint,
        intrinsicSize: pending.intrinsicSize,
        pageSize: Size(_page.width, _page.height),
      );
    } catch (e, st) {
      debugPrint('stamp placement failed: $e\n$st');
    }
  }

  void _onPanStart(PdfAnnotationTool tool, Offset local) {
    switch (tool) {
      case PdfAnnotationTool.pen:
        if (_controller.inFlightPageIndex != null) return;
        _controller.startStroke(
          pageIndex: _page.pageNumber - 1,
          firstPoint: _toPdfSpace(local),
          lineWidth: _controller.strokeWidth,
          strokeColor: _controller.strokeColor,
          opacity: 1.0,
          kind: PdfInkAnnotationKind.pen,
        );
      case PdfAnnotationTool.highlighter:
        if (_controller.inFlightPageIndex != null) return;
        _controller.startStroke(
          pageIndex: _page.pageNumber - 1,
          firstPoint: _toPdfSpace(local),
          lineWidth: _controller.highlighterWidth,
          strokeColor: _controller.highlighterColor,
          opacity: widget.highlighterOpacity.clamp(0.0, 1.0),
          kind: PdfInkAnnotationKind.highlighter,
        );
      case PdfAnnotationTool.eraser:
        _controller.startErase(
          pageIndex: _page.pageNumber - 1,
          pdfPoint: _toPdfSpace(local),
          radiusInPdfPoints: _controller.eraserRadius,
        );
      case PdfAnnotationTool.stamp:
        _onStampPanStart(local);
    }
  }

  void _onStampPanStart(Offset local) {
    final selectedId = _controller.selectedStampIdListenable.value;
    if (selectedId == null) return;
    final pageStamps = _pageStamps();
    final selected = _findSelected(pageStamps, selectedId);
    if (selected == null) return;
    if (selected.creatorName != _controller.currentCreator) return;

    final hit = _hitTestStampHandles(selected, local);
    if (hit == null) {
      // Pan landed off the selected stamp — the spec consumes the
      // gesture as a no-op (no pen draw, no marquee, no deselect).
      return;
    }
    if (hit.isDelete) {
      // The delete tap is handled in onTapUp; don't begin a drag here.
      return;
    }
    final handle = hit.handle!;
    if (handle == PdfStampHandle.rotation) {
      final rect = _stampLocalRect(selected);
      _stampCenterLocal = rect.center;
      _initialRotationAngle = math.atan2(local.dy - rect.center.dy, local.dx - rect.center.dx);
      _originalStampRotationDeg = selected.rotationDeg;
    }
    _activeHandle = handle;
    _panStartLocal = local;
    _controller.beginStampDrag(handle);
  }

  void _onPanUpdate(PdfAnnotationTool tool, Offset local) {
    switch (tool) {
      case PdfAnnotationTool.pen:
      case PdfAnnotationTool.highlighter:
        if (_controller.inFlightPageIndex != _page.pageNumber - 1) return;
        _controller.appendPoint(_toPdfSpace(local));
      case PdfAnnotationTool.eraser:
        _controller.continueErase(
          pageIndex: _page.pageNumber - 1,
          pdfPoint: _toPdfSpace(local),
          radiusInPdfPoints: _controller.eraserRadius,
        );
      case PdfAnnotationTool.stamp:
        _onStampPanUpdate(local);
    }
  }

  void _onStampPanUpdate(Offset local) {
    final handle = _activeHandle;
    final start = _panStartLocal;
    if (handle == null || start == null) return;
    if (handle == PdfStampHandle.rotation) {
      final center = _stampCenterLocal!;
      final initial = _initialRotationAngle!;
      final current = math.atan2(local.dy - center.dy, local.dx - center.dx);
      // CCW positive: subtract because screen y grows downward.
      final deltaRad = -(current - initial);
      _controller.applyStampRotate(_originalStampRotationDeg! + deltaRad * 180.0 / math.pi);
      return;
    }
    final cumulativePdf = _toPdfSpace(local) - _toPdfSpace(start);
    if (handle == PdfStampHandle.body) {
      _controller.applyStampMove(cumulativePdf);
    } else {
      _controller.applyStampResize(cumulativePdf);
    }
  }

  void _onPanEnd(PdfAnnotationTool tool) {
    switch (tool) {
      case PdfAnnotationTool.pen:
      case PdfAnnotationTool.highlighter:
        _controller.commitStroke();
      case PdfAnnotationTool.eraser:
        _controller.endErase();
      case PdfAnnotationTool.stamp:
        _endStampDrag();
    }
  }

  void _onPanCancel(PdfAnnotationTool tool) {
    switch (tool) {
      case PdfAnnotationTool.pen:
      case PdfAnnotationTool.highlighter:
        _controller.cancelStroke();
      case PdfAnnotationTool.eraser:
        _controller.endErase();
      case PdfAnnotationTool.stamp:
        _endStampDrag();
    }
  }

  void _endStampDrag() {
    if (_activeHandle == null) return;
    _controller.endStampDrag();
    _activeHandle = null;
    _panStartLocal = null;
    _stampCenterLocal = null;
    _initialRotationAngle = null;
    _originalStampRotationDeg = null;
  }

  Offset _toPdfSpace(Offset local) =>
      Offset(local.dx * _page.width / _pageRect.width, local.dy * _page.height / _pageRect.height);
}

class _StampHitTestResult {
  const _StampHitTestResult.handle(this.handle) : isDelete = false;
  const _StampHitTestResult.delete() : handle = null, isDelete = true;

  final PdfStampHandle? handle;
  final bool isDelete;
}

@visibleForTesting
class InkPainter extends CustomPainter {
  InkPainter({
    required this.strokes,
    required this.inFlightProvider,
    required this.eraserCursorProvider,
    required this.eraserRadiusProvider,
    required Listenable repaint,
    required this.pageWidth,
    required this.pageHeight,
  }) : super(repaint: repaint);

  final List<PdfInkAnnotation> strokes;
  final Iterable<PdfInkAnnotation> Function() inFlightProvider;
  final Offset? Function() eraserCursorProvider;
  final double Function() eraserRadiusProvider;
  final double pageWidth;
  final double pageHeight;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final scaleX = size.width / pageWidth;
    final scaleY = size.height / pageHeight;
    for (final stroke in strokes) {
      _paintStroke(canvas, stroke, scaleX: scaleX, scaleY: scaleY);
    }
    for (final stroke in inFlightProvider()) {
      _paintStroke(canvas, stroke, scaleX: scaleX, scaleY: scaleY);
    }
    final cursor = eraserCursorProvider();
    if (cursor != null) {
      _paintEraserCursor(canvas, cursor, scaleX: scaleX, scaleY: scaleY);
    }
  }

  void _paintEraserCursor(Canvas canvas, Offset pdfPoint, {required double scaleX, required double scaleY}) {
    final center = Offset(pdfPoint.dx * scaleX, pdfPoint.dy * scaleY);
    final radius = eraserRadiusProvider() * scaleX;
    final outer = Paint()
      ..style = PaintingStyle.stroke
      ..color = const Color(0xFF000000)
      ..strokeWidth = 1.5;
    final inner = Paint()
      ..style = PaintingStyle.stroke
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = 0.75;
    canvas.drawCircle(center, radius, outer);
    canvas.drawCircle(center, radius, inner);
  }

  void _paintStroke(Canvas canvas, PdfInkAnnotation stroke, {required double scaleX, required double scaleY}) {
    final (cap, join) = switch (stroke.kind) {
      PdfInkAnnotationKind.pen => (StrokeCap.round, StrokeJoin.round),
      PdfInkAnnotationKind.highlighter => (StrokeCap.butt, StrokeJoin.miter),
    };
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..color = stroke.strokeColor.withValues(alpha: stroke.opacity)
      ..strokeWidth = stroke.lineWidth * scaleX
      ..strokeCap = cap
      ..strokeJoin = join;
    final points = stroke.pointsInPdfSpace;
    if (points.isEmpty) return;
    final path = Path()..moveTo(points.first.dx * scaleX, points.first.dy * scaleY);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx * scaleX, points[i].dy * scaleY);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(InkPainter old) =>
      !identical(old.strokes, strokes) || old.pageWidth != pageWidth || old.pageHeight != pageHeight;
}
