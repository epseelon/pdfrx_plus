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
/// per-page input handler is mounted on top of the painter to capture
/// pan and tap input. The active tool ([PdfAnnotationController.currentToolListenable])
/// determines whether pan input draws ([PdfAnnotationTool.pen]), erases
/// ([PdfAnnotationTool.eraser]), or places/manipulates stamps
/// ([PdfAnnotationTool.stamp]). For the stamp tool the layer uses a raw
/// [Listener] (rather than a [GestureDetector]) so handle drags don't
/// have to clear the system pan-slop threshold — important for touch
/// devices where small fingertip drags otherwise get lost in the
/// gesture arena.
///
/// Page rotation is assumed to be `0°` (see spec §17).
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
// pixels regardless of zoom. Hit radius is bumped well above the visual
// size so fingertips have a comfortable target on touch screens.
const double _kHandleScreenPx = 12.0;
const double _kHandleHitRadiusPx = 22.0;
// Rotation handle floats above the bbox's top edge so it never hides
// the stamp content (which used to be a problem when the stamp was
// small). Sized larger than the resize handles to fit a rotation icon.
const double _kRotateHandlePx = 24.0;
const double _kRotateHandleGapPx = 8.0;
// Delete button floats at the top-right corner of the bbox (offset
// outward by the same gap as the rotation handle) so it never hides
// the stamp content.
const double _kDeleteButtonPx = 24.0;
const double _kSelectionOutlinePx = 1.5;

/// Movement threshold (in widget pixels) past which a stamp-tool
/// pointer-down is treated as a drag rather than a tap. Deliberately
/// looser than the framework's `kPanSlop` (~18 px) so handle drags fire
/// reliably from a fingertip; the trade-off is that "tap" is committed
/// only when the finger barely moves between down and up.
const double _kStampDragSlopPx = 4.0;

class _PdfAnnotationLayerState extends State<PdfAnnotationLayer> {
  // Drag bookkeeping captured at pointer-down so subsequent updates can
  // be routed without re-hit-testing.
  PdfStampHandle? _activeHandle;
  Offset? _pointerDownLocal;
  PdfStampHandle? _pendingHandle;
  bool _dragRecognized = false;
  Offset? _stampCenterLocal;
  double? _initialRotationAngle;
  double? _originalStampRotationDeg;

  PdfAnnotationController get _controller => widget.controller;
  PdfPage get _page => widget.page;
  Rect get _pageRect => widget.pageRect;

  @override
  void initState() {
    super.initState();
    _registerPageLayout();
  }

  @override
  void didUpdateWidget(covariant PdfAnnotationLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller || oldWidget.page.pageNumber != widget.page.pageNumber) {
      oldWidget.controller.unregisterPageLayout(oldWidget.page.pageNumber - 1);
    }
    _registerPageLayout();
  }

  @override
  void dispose() {
    _controller.unregisterPageLayout(_page.pageNumber - 1);
    super.dispose();
  }

  void _registerPageLayout() {
    _controller.registerPageLayout(
      pageIndex: _page.pageNumber - 1,
      viewerRect: _pageRect,
      pageSize: Size(_page.width, _page.height),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _controller.annotationModeListenable,
      builder: (context, modeOn, _) {
        return IgnorePointer(
          ignoring: !modeOn,
          child: AnimatedBuilder(
            // Selection-driven UI (the overlay + delete button) hangs
            // off `selectedStampIdListenable`, so it must trigger a
            // rebuild here. Without it, taps that select/deselect a
            // stamp would update the controller silently and the user
            // would only see handles appear after some other state
            // change happened to bump the merged listenable.
            animation: Listenable.merge([
              _controller,
              _controller.stampDragChangedListenable,
              _controller.selectedStampIdListenable,
            ]),
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
                clipBehavior: Clip.none,
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
                  if (modeOn)
                    Positioned.fill(
                      child: ValueListenableBuilder<PdfAnnotationTool>(
                        valueListenable: _controller.currentToolListenable,
                        builder: (context, tool, _) {
                          if (tool == PdfAnnotationTool.stamp) {
                            return Listener(
                              behavior: HitTestBehavior.opaque,
                              onPointerDown: (e) => _onStampPointerDown(e.localPosition),
                              onPointerMove: (e) => _onStampPointerMove(e.localPosition),
                              onPointerUp: (e) => _onStampPointerUp(e.localPosition),
                              onPointerCancel: (_) => _onStampPointerCancel(),
                            );
                          }
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanStart: (details) => _onPanStart(tool, details.localPosition),
                            onPanUpdate: (details) => _onPanUpdate(tool, details.localPosition),
                            onPanEnd: (_) => _onPanEnd(tool),
                            onPanCancel: () => _onPanCancel(tool),
                          );
                        },
                      ),
                    ),
                  // Selection overlay is rendered above the input
                  // handler but is fully pointer-transparent — every
                  // affordance (resize/rotate handles, delete button)
                  // is purely visual. Taps and drags fall through to
                  // the Listener below, which routes them based on
                  // our own hit-tests in page-local space (so handles
                  // floating outside the bbox still receive input).
                  if (selectedStamp != null) _buildSelectionOverlay(selectedStamp, scaleX, scaleY),
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
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Outline + resize/rotation handles render visually only —
          // pointer-transparent so the Listener below catches drags.
          IgnorePointer(
            child: SizedBox(
              width: width,
              height: height,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(color: color, width: _kSelectionOutlinePx),
                      ),
                    ),
                  ),
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
                  Positioned(
                    left: width / 2 - _kRotateHandlePx / 2,
                    top: -(_kRotateHandleGapPx + _kRotateHandlePx),
                    width: _kRotateHandlePx,
                    height: _kRotateHandlePx,
                    child: Semantics(
                      label: 'Rotate stamp',
                      button: true,
                      child: Material(
                        color: color,
                        shape: const CircleBorder(),
                        elevation: 2,
                        child: Icon(Icons.refresh, size: 16, color: Theme.of(context).colorScheme.onPrimary),
                      ),
                    ),
                  ),
                  // Delete button. Floats outside the bbox at the
                  // top-right corner — diagonally offset from the
                  // top-right resize handle so fingers reaching the
                  // corner still hit the resize handle. Pointer events
                  // fall through to the Listener (IgnorePointer wraps
                  // the whole affordance group); the actual tap-test
                  // for this button lives in _handleStampTap so the
                  // tap path is uniform across all the stamp tool's
                  // affordances.
                  Positioned(
                    left: width + _kRotateHandleGapPx,
                    top: -(_kRotateHandleGapPx + _kDeleteButtonPx),
                    width: _kDeleteButtonPx,
                    height: _kDeleteButtonPx,
                    child: Semantics(
                      label: 'Delete stamp',
                      button: true,
                      child: Material(
                        color: color,
                        shape: const CircleBorder(),
                        elevation: 2,
                        child: Tooltip(
                          message: 'Delete stamp',
                          child: Icon(Icons.delete_outline, size: 16, color: Theme.of(context).colorScheme.onPrimary),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
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

  /// Local-coord rect of the floating delete button for [stamp]. Sits
  /// just outside the bbox at the top-right corner. Used for tap
  /// hit-testing only — the visual is rendered as a pointer-transparent
  /// affordance.
  Rect _stampDeleteButtonRect(PdfStampAnnotation stamp) {
    final bbox = _stampLocalRect(stamp);
    return Rect.fromLTWH(
      bbox.right + _kRotateHandleGapPx,
      bbox.top - _kRotateHandleGapPx - _kDeleteButtonPx,
      _kDeleteButtonPx,
      _kDeleteButtonPx,
    );
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

  /// Returns the closest handle of [stamp] to [local], or `null` if no
  /// handle is within hit radius. When [local] falls inside the bbox
  /// without hitting any handle, returns [PdfStampHandle.body]. Closest
  /// wins over priority order so e.g. the top-edge midpoint beats the
  /// rotation handle when the user taps right at the edge.
  PdfStampHandle? _hitTestStampHandles(PdfStampAnnotation stamp, Offset local) {
    final rect = _stampLocalRect(stamp);
    PdfStampHandle? bestHandle;
    var bestDistSq = _kHandleHitRadiusPx * _kHandleHitRadiusPx;

    void consider(PdfStampHandle h, Offset pos) {
      final dx = local.dx - pos.dx;
      final dy = local.dy - pos.dy;
      final d2 = dx * dx + dy * dy;
      if (d2 <= bestDistSq) {
        bestHandle = h;
        bestDistSq = d2;
      }
    }

    for (final h in _resizeHandles) {
      consider(h, Offset(rect.left + _handleX(h, rect.width), rect.top + _handleY(h, rect.height)));
    }
    consider(PdfStampHandle.rotation, Offset(rect.center.dx, rect.top - _kRotateHandleGapPx - _kRotateHandlePx / 2));

    if (bestHandle != null) return bestHandle;
    if (rect.contains(local)) return PdfStampHandle.body;
    return null;
  }

  /// Returns the topmost selectable stamp (current creator's) whose
  /// rect contains [local], or null. Iterates in reverse Z-order so the
  /// most recently placed stamp wins overlap resolution.
  PdfStampAnnotation? _hitTestSelectableStampBody(List<PdfStampAnnotation> pageStamps, Offset local) {
    for (var i = pageStamps.length - 1; i >= 0; i--) {
      final s = pageStamps[i];
      if (s.creatorName != _controller.currentCreator) continue;
      if (_stampLocalRect(s).contains(local)) return s;
    }
    return null;
  }

  /// Returns the first stamp (any creator) whose rect contains the
  /// local point — used purely to decide whether to fall through to
  /// placement (only when the topmost stamp is foreign-creator).
  PdfStampAnnotation? _hitTestAnyStampBody(List<PdfStampAnnotation> pageStamps, Offset local) {
    for (var i = pageStamps.length - 1; i >= 0; i--) {
      final s = pageStamps[i];
      if (_stampLocalRect(s).contains(local)) return s;
    }
    return null;
  }

  // ───────────────────────── Stamp tool: Listener ─────────────────────────

  void _onStampPointerDown(Offset local) {
    _pointerDownLocal = local;
    _dragRecognized = false;
    _pendingHandle = null;

    final selectedId = _controller.selectedStampIdListenable.value;
    if (selectedId == null) return;
    final pageStamps = _pageStamps();
    final selected = _findSelected(pageStamps, selectedId);
    if (selected == null) return;
    if (selected.creatorName != _controller.currentCreator) return;

    final hit = _hitTestStampHandles(selected, local);
    if (hit == null) return;
    _pendingHandle = hit;
    if (hit == PdfStampHandle.rotation) {
      final rect = _stampLocalRect(selected);
      _stampCenterLocal = rect.center;
      _initialRotationAngle = math.atan2(local.dy - rect.center.dy, local.dx - rect.center.dx);
      _originalStampRotationDeg = selected.rotationDeg;
    }
  }

  void _onStampPointerMove(Offset local) {
    final start = _pointerDownLocal;
    if (start == null) return;
    final dx = local.dx - start.dx;
    final dy = local.dy - start.dy;
    final distSq = dx * dx + dy * dy;

    if (!_dragRecognized) {
      if (distSq < _kStampDragSlopPx * _kStampDragSlopPx) return;
      _dragRecognized = true;
      final pending = _pendingHandle;
      if (pending == null) {
        // Pan over empty area (or off the selected stamp): consume
        // silently so it doesn't fall through to a place/deselect.
        return;
      }
      _activeHandle = pending;
      _controller.beginStampDrag(pending);
    }

    final handle = _activeHandle;
    if (handle == null) return;

    if (handle == PdfStampHandle.rotation) {
      final center = _stampCenterLocal!;
      final initial = _initialRotationAngle!;
      final current = math.atan2(local.dy - center.dy, local.dx - center.dx);
      // Screen-y grows downward, so a clockwise angular delta in screen
      // space is a CCW rotation in our PDF-space convention.
      final deltaRad = -(current - initial);
      _controller.applyStampRotate(_originalStampRotationDeg! + deltaRad * 180.0 / math.pi);
      return;
    }

    if (handle == PdfStampHandle.body) {
      // Body drag works in viewer-pixel space so cross-page page
      // reassignment can hand off the stamp to a sibling annotation
      // layer mid-drag. The Listener is mounted on a Positioned at
      // pageRect.topLeft, so the local-space delta is identical to a
      // pure viewer-coord delta.
      _controller.applyStampMoveViewer(local - start);
      return;
    }
    final cumulativePdf = _toPdfSpace(local) - _toPdfSpace(start);
    _controller.applyStampResize(cumulativePdf);
  }

  void _onStampPointerUp(Offset local) {
    if (_dragRecognized) {
      _endStampDrag();
    } else {
      // No movement crossed the slop — treat as a tap at the down
      // position so taps don't drift if the finger settles slightly.
      _handleStampTap(_pointerDownLocal ?? local);
    }
    _resetStampPointerState();
  }

  void _onStampPointerCancel() {
    if (_dragRecognized) _endStampDrag();
    _resetStampPointerState();
  }

  void _resetStampPointerState() {
    _pointerDownLocal = null;
    _pendingHandle = null;
    _dragRecognized = false;
    _stampCenterLocal = null;
    _initialRotationAngle = null;
    _originalStampRotationDeg = null;
  }

  void _handleStampTap(Offset local) {
    final pageStamps = _pageStamps();
    final pending = _controller.pendingStampListenable.value;

    // Delete-button tap on the currently-selected stamp wins over
    // every other branch — it's the affordance the user explicitly
    // aimed at and it sits OUTSIDE the bbox, so the body / empty-area
    // hit-tests would otherwise eat the tap.
    final selectedId = _controller.selectedStampIdListenable.value;
    if (selectedId != null) {
      final selectedStamp = _findSelected(pageStamps, selectedId);
      if (selectedStamp != null && _stampDeleteButtonRect(selectedStamp).contains(local)) {
        _controller.deleteStamp(selectedStamp.id);
        return;
      }
    }

    final selectable = _hitTestSelectableStampBody(pageStamps, local);
    if (selectable != null) {
      _controller.selectStamp(selectable.id);
      // Repeat-place is only meaningful on empty areas — once the user
      // commits to a placed stamp, drop the pending so the next tap
      // doesn't duplicate.
      if (pending != null) _controller.setPendingStamp(null);
      return;
    }

    // Tap on empty area (or over a foreign-creator stamp). Deselection
    // takes priority over placement: if the user has a stamp selected,
    // a tap outside that stamp clears the selection first — even when
    // a library stamp is armed. The next "empty" tap (with no
    // selection) is the one that drops a new stamp.
    if (_controller.selectedStampIdListenable.value != null) {
      _controller.clearStampSelection();
      return;
    }

    final any = _hitTestAnyStampBody(pageStamps, local);
    final overForeign = any != null && any.creatorName != _controller.currentCreator;

    if (pending != null && (any == null || overForeign)) {
      unawaited(_placePendingStamp(pending, local));
      return;
    }
  }

  List<PdfStampAnnotation> _pageStamps() =>
      _controller.stamps.where((s) => s.pageIndex == _page.pageNumber - 1).toList(growable: false);

  Future<void> _placePendingStamp(PdfStampDefinition pending, Offset local) async {
    try {
      final bytes = await pending.bytesLoader();
      final pdfPoint = _toPdfSpace(local);
      final newId = _controller.placeStamp(
        bytes: bytes,
        contentType: pending.contentType,
        pageIndex: _page.pageNumber - 1,
        pdfPoint: pdfPoint,
        intrinsicSize: pending.intrinsicSize,
        pageSize: Size(_page.width, _page.height),
      );
      // Auto-select on placement so the user immediately sees the
      // selection affordances and can adjust the new stamp.
      if (newId != null) _controller.selectStamp(newId);
    } catch (e, st) {
      debugPrint('stamp placement failed: $e\n$st');
    }
  }

  // ───────────────────────── Other tools: GestureDetector ────────────────

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
        // Handled by the Listener branch.
        return;
    }
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
        return;
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
        return;
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
        return;
    }
  }

  void _endStampDrag() {
    if (_activeHandle == null) return;
    _controller.endStampDrag();
    _activeHandle = null;
  }

  Offset _toPdfSpace(Offset local) =>
      Offset(local.dx * _page.width / _pageRect.width, local.dy * _page.height / _pageRect.height);
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
