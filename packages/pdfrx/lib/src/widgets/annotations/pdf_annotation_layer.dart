import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pdfrx_engine/pdfrx_engine.dart';

import 'annotation_paint_sequence.dart';
import 'pdf_annotation_controller.dart';
import 'pdf_annotation_overlay_labels.dart';
import 'pdf_ink_annotation.dart';
import 'pdf_rect_annotation.dart';
import 'pdf_stamp_annotation.dart';
import 'pdf_stamp_definition.dart';
import 'pdf_stamp_picture.dart';
import 'selection_geometry.dart';

/// Internal per-page input and overlay layer for the annotations
/// anchored to [page]. Mounted by `PdfViewer` for every visible page.
///
/// No annotation kind renders as a widget here: ink strokes and stamps
/// are both painted onto the page canvas by [paintPageAnnotations], as
/// one creation-ordered sequence, which is what makes a single z-order
/// across kinds possible. This layer contributes only the transient
/// eraser cursor, the selection gizmo and the gesture handling.
///
/// Coordinates are converted from PDF point space (top-left origin) to
/// widget pixels using the page's current display rect.
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
    this.selectedStampInterfaceColor,
    this.selectedStampPadding = 0.0,
    this.labels = const PdfAnnotationOverlayLabels(),
    super.key,
  });

  final PdfAnnotationController controller;
  final PdfPage page;
  final Rect pageRect;

  /// Color of the selection outline, handles, and buttons around the
  /// currently selected stamp. `null` falls back to the theme's primary.
  final Color? selectedStampInterfaceColor;

  /// Uniform padding in screen pixels between a selected stamp's symbol
  /// and its handle rectangle. Inflates the selection box, the
  /// handle/delete-button positions, and the body hit-region; the
  /// rendered symbol stays at its true bounds. Sourced by the
  /// `PdfViewer` from `PdfViewerParams.selectedStampPadding`.
  final double selectedStampPadding;

  /// Opacity stamped onto every newly-committed highlighter stroke. The
  /// caller (the `PdfViewer`) sources this from
  /// `PdfViewerParams.highlighterOpacity`. The layer clamps to
  /// `[0.0, 1.0]` at use time, so out-of-range values from the params
  /// are silently coerced rather than rejected.
  final double highlighterOpacity;

  /// Strings for the selection overlay's affordances. Sourced by the
  /// `PdfViewer` from `PdfViewerParams.annotationOverlayLabels`;
  /// defaults to English.
  final PdfAnnotationOverlayLabels labels;

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
// Distance from the top edge to the rotation handle's *centre*. The
// geometry module places and hit-tests the handle from this.
const double _kRotateHandleOffsetPx = _kRotateHandleGapPx + _kRotateHandlePx / 2;
// Delete button floats at the top-right corner of the bbox (offset
// outward by the same gap as the rotation handle) so it never hides
// the stamp content.
const double _kDeleteButtonPx = 24.0;
const double _kSelectionOutlinePx = 1.5;

/// Padding between a rectangle's own bounds and its handle rectangle.
/// Zero, so the handles sit exactly on the border: unlike a stamp, a
/// rectangle has no symbol for them to clear.
const double _kRectHandlePaddingPx = 0.0;

/// Movement threshold (in widget pixels) past which a stamp-tool
/// pointer-down is treated as a drag rather than a tap. Deliberately
/// looser than the framework's `kPanSlop` (~18 px) so handle drags fire
/// reliably from a fingertip; the trade-off is that "tap" is committed
/// only when the finger barely moves between down and up.
const double _kStampDragSlopPx = 4.0;

class _PdfAnnotationLayerState extends State<PdfAnnotationLayer> {
  // Drag bookkeeping captured at pointer-down so subsequent updates can
  // be routed without re-hit-testing.
  PdfAnnotationHandle? _activeHandle;
  Offset? _pointerDownLocal;
  PdfAnnotationHandle? _pendingHandle;
  bool _dragRecognized = false;
  bool _rubberBanding = false;
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
        return ValueListenableBuilder<PdfAnnotationTool>(
          valueListenable: _controller.currentToolListenable,
          builder: (context, layerTool, _) {
            return IgnorePointer(
              // Ignore pointers entirely when annotation mode is off, or
              // when the hand (navigation) tool is active — so pan, tap,
              // scroll, and pinch-zoom fall straight through to the
              // underlying PdfViewer instead of being absorbed here.
              ignoring: !modeOn || layerTool == PdfAnnotationTool.hand,
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
                  _controller.selectedRectIdListenable,
                ]),
                builder: (context, _) {
                  final pageStamps = _controller.stamps
                      .where((s) => s.pageIndex == _page.pageNumber - 1)
                      .toList(growable: false);

                  final selectedId = _controller.selectedStampIdListenable.value;
                  final selectedStamp = selectedId == null ? null : _findSelected(pageStamps, selectedId);
                  final selectedRectId = _controller.selectedRectIdListenable.value;
                  final selectedRect = selectedRectId == null ? null : _findSelectedRect(selectedRectId);

                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // Ink strokes and stamps are both painted on the
                      // page canvas by the `PdfViewer` page painter: one
                      // sequence, so they share a z-order, and so the
                      // highlighter can multiply-blend with the page
                      // content. This painter only renders the transient
                      // eraser cursor preview.
                      CustomPaint(
                        painter: EraserCursorPainter(
                          eraserCursorProvider: () => _controller.eraserCursorPageIndex == _page.pageNumber - 1
                              ? _controller.eraserCursorPdfPoint
                              : null,
                          eraserRadiusProvider: () => _controller.eraserRadius,
                          repaint: Listenable.merge([
                            _controller.eraserCursorChangedListenable,
                            _controller.eraserRadiusListenable,
                          ]),
                          pageWidth: _page.width,
                          pageHeight: _page.height,
                        ),
                        size: _pageRect.size,
                      ),
                      if (modeOn)
                        Positioned.fill(
                          child: ValueListenableBuilder<PdfAnnotationTool>(
                            valueListenable: _controller.currentToolListenable,
                            builder: (context, tool, _) {
                              if (tool == PdfAnnotationTool.hand) {
                                // Navigation tool: capture nothing. The
                                // whole layer is also wrapped in an
                                // IgnorePointer for `hand` so pan, tap,
                                // scroll, and pinch-zoom fall straight
                                // through to the underlying PdfViewer.
                                return const SizedBox.shrink();
                              }
                              if (tool == PdfAnnotationTool.stamp) {
                                return Listener(
                                  behavior: HitTestBehavior.opaque,
                                  onPointerDown: (e) => _onStampPointerDown(e.localPosition),
                                  onPointerMove: (e) => _onStampPointerMove(e.localPosition),
                                  onPointerUp: (e) => _onStampPointerUp(e.localPosition),
                                  onPointerCancel: (_) => _onStampPointerCancel(),
                                );
                              }
                              if (tool == PdfAnnotationTool.rectangle) {
                                // Raw Listener for the same reason the
                                // stamp tool uses one: handle drags must
                                // not have to clear the gesture arena's
                                // pan slop on touch devices.
                                return Listener(
                                  behavior: HitTestBehavior.opaque,
                                  onPointerDown: (e) => _onRectPointerDown(e.localPosition),
                                  onPointerMove: (e) => _onRectPointerMove(e.localPosition),
                                  onPointerUp: (e) => _onRectPointerUp(e.localPosition),
                                  onPointerCancel: (_) => _onRectPointerCancel(),
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
                      // Selection is mutually exclusive across kinds,
                      // so at most one of these is non-null.
                      if (selectedStamp != null)
                        _buildSelectionOverlay(
                          id: selectedStamp.id,
                          selectionRect: _stampSelectionRect(selectedStamp),
                          rotationDeg: selectedStamp.rotationDeg,
                        )
                      else if (selectedRect != null)
                        _buildSelectionOverlay(
                          id: selectedRect.id,
                          selectionRect: _rectSelectionRect(selectedRect),
                          rotationDeg: selectedRect.rotationDeg,
                        ),
                    ],
                  );
                },
              ),
            );
          },
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

  /// The shape-neutral selection gizmo: an outline, eight resize
  /// handles, a rotation handle and a delete button, all turned by
  /// [rotationDeg] about the shape's centre so they sit on its rotated
  /// borders.
  ///
  /// Rendered above the input handler but fully pointer-transparent:
  /// every affordance is purely visual. Taps and drags fall through to
  /// the [Listener] below, which routes them from this layer's own
  /// hit-tests in page-local space, so handles floating outside the
  /// bbox still receive input.
  Widget _buildSelectionOverlay({required String id, required Rect selectionRect, required double rotationDeg}) {
    final color = widget.selectedStampInterfaceColor ?? Theme.of(context).colorScheme.primary;
    final iconColor = ThemeData.estimateBrightnessForColor(color) == Brightness.dark ? Colors.white : Colors.black;
    final labels = widget.labels;
    // Affordances are laid out in the shape's own frame, with the
    // Transform below turning the whole group; this is the same frame
    // the hit-tests un-rotate the pointer into.
    final localRect = Offset.zero & selectionRect.size;
    final rotationAnchor = handleAnchorInLocalFrame(
      rect: localRect,
      handle: PdfAnnotationHandle.rotation,
      rotationHandleOffset: _kRotateHandleOffsetPx,
    );
    final deleteRect = _deleteButtonRectInLocalFrame(localRect);

    return Positioned(
      key: Key('annotationSelection:$id'),
      left: selectionRect.left,
      top: selectionRect.top,
      width: selectionRect.width,
      height: selectionRect.height,
      child: IgnorePointer(
        child: Transform.rotate(
          angle: -rotationDeg * math.pi / 180.0,
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
              for (final handle in kResizeHandles)
                () {
                  final anchor = handleAnchorInLocalFrame(
                    rect: localRect,
                    handle: handle,
                    rotationHandleOffset: _kRotateHandleOffsetPx,
                  );
                  return Positioned(
                    left: anchor.dx - _kHandleScreenPx / 2,
                    top: anchor.dy - _kHandleScreenPx / 2,
                    width: _kHandleScreenPx,
                    height: _kHandleScreenPx,
                    child: Semantics(
                      label: labels.labelFor(handle),
                      button: true,
                      child: DecoratedBox(decoration: BoxDecoration(color: color)),
                    ),
                  );
                }(),
              Positioned(
                left: rotationAnchor.dx - _kRotateHandlePx / 2,
                top: rotationAnchor.dy - _kRotateHandlePx / 2,
                width: _kRotateHandlePx,
                height: _kRotateHandlePx,
                child: Semantics(
                  label: labels.rotate,
                  button: true,
                  child: Material(
                    color: color,
                    shape: const CircleBorder(),
                    elevation: 2,
                    child: _upright(rotationDeg, Icon(Icons.refresh, size: 16, color: iconColor)),
                  ),
                ),
              ),
              // Delete button. Floats outside the bbox at the top-right
              // corner, diagonally offset from the top-right resize
              // handle so fingers reaching the corner still hit the
              // resize handle. Pointer events fall through to the
              // Listener (the whole group is wrapped in IgnorePointer);
              // the tap-test lives in _handleStampTap so the tap path
              // is uniform across all the stamp tool's affordances.
              Positioned(
                left: deleteRect.left,
                top: deleteRect.top,
                width: deleteRect.width,
                height: deleteRect.height,
                child: Semantics(
                  label: labels.delete,
                  button: true,
                  child: Material(
                    color: color,
                    shape: const CircleBorder(),
                    elevation: 2,
                    child: Tooltip(
                      message: labels.delete,
                      child: _upright(rotationDeg, Icon(Icons.delete_outline, size: 16, color: iconColor)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Counter-rotates [child] so a glyph stays readable while its
  /// position travels with the rotated gizmo.
  Widget _upright(double rotationDeg, Widget child) =>
      rotationDeg == 0 ? child : Transform.rotate(angle: rotationDeg * math.pi / 180.0, child: child);

  /// Local-frame rect of the floating delete button, just outside the
  /// selection rect's top-right corner. Serves both the visual and the
  /// tap hit-test, which un-rotates the pointer into this same frame.
  Rect _deleteButtonRectInLocalFrame(Rect selectionRect) => Rect.fromLTWH(
    selectionRect.right + _kRotateHandleGapPx,
    selectionRect.top - _kRotateHandleGapPx - _kDeleteButtonPx,
    _kDeleteButtonPx,
    _kDeleteButtonPx,
  );

  /// Whether [local] (page-local pixels) falls on [stamp]'s delete
  /// button once the stamp is rotated.
  bool _hitTestDeleteButton(PdfStampAnnotation stamp, Offset local) {
    final selectionRect = _stampSelectionRect(stamp);
    final unrotated = unrotatePointToLocal(local, center: selectionRect.center, rotationDeg: stamp.rotationDeg);
    return _deleteButtonRectInLocalFrame(selectionRect).contains(unrotated);
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

  /// The handle rectangle for a shape whose own bounds are [localRect]:
  /// that rect inflated on every side by [padding] (screen pixels). The
  /// selection outline, resize/rotation handles, delete button, and
  /// every body/selection hit-test derive from this rect — the rendered
  /// shape itself stays at [localRect].
  ///
  /// Padding is a per-kind choice, which is why it is a parameter
  /// rather than read from the widget here: stamps pass
  /// [PdfAnnotationLayer.selectedStampPadding] so the handles clear the
  /// symbol, while a `0.0` padding makes the two rects identical
  /// (exact-fit handle box), which is what the rectangle tool passes,
  /// so its handles sit exactly on the border.
  Rect _selectionRect(Rect localRect, double padding) => localRect.inflate(padding);

  /// The handle rectangle for [stamp].
  Rect _stampSelectionRect(PdfStampAnnotation stamp) =>
      _selectionRect(_stampLocalRect(stamp), widget.selectedStampPadding);

  /// Returns the closest handle of [stamp] to [local], or `null` if no
  /// handle is within hit radius. When [local] falls inside the rotated
  /// bbox without hitting any handle, returns [PdfAnnotationHandle.body].
  /// Closest wins over priority order so e.g. the top-edge midpoint beats
  /// the rotation handle when the user taps right at the edge.
  PdfAnnotationHandle? _hitTestStampHandles(PdfStampAnnotation stamp, Offset local) => hitTestHandles(
    rect: _stampSelectionRect(stamp),
    rotationDeg: stamp.rotationDeg,
    point: local,
    hitRadius: _kHandleHitRadiusPx,
    rotationHandleOffset: _kRotateHandleOffsetPx,
  );

  /// Whether [local] falls inside [stamp]'s rotated selection rect.
  bool _stampBodyContains(PdfStampAnnotation stamp, Offset local) =>
      containsRotated(rect: _stampSelectionRect(stamp), rotationDeg: stamp.rotationDeg, point: local);

  /// Returns the topmost selectable stamp (current creator's) whose
  /// rotated rect contains [local], or null. Iterates in reverse Z-order
  /// so the most recently placed stamp wins overlap resolution.
  PdfStampAnnotation? _hitTestSelectableStampBody(List<PdfStampAnnotation> pageStamps, Offset local) {
    for (var i = pageStamps.length - 1; i >= 0; i--) {
      final s = pageStamps[i];
      if (s.creatorName != _controller.currentCreator) continue;
      if (_stampBodyContains(s, local)) return s;
    }
    return null;
  }

  /// Returns the first stamp (any creator) whose rotated rect contains
  /// the local point, used purely to decide whether to fall through to
  /// placement (only when the topmost stamp is foreign-creator).
  PdfStampAnnotation? _hitTestAnyStampBody(List<PdfStampAnnotation> pageStamps, Offset local) {
    for (var i = pageStamps.length - 1; i >= 0; i--) {
      final s = pageStamps[i];
      if (_stampBodyContains(s, local)) return s;
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
    if (hit == PdfAnnotationHandle.rotation) {
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

    if (handle == PdfAnnotationHandle.rotation) {
      final center = _stampCenterLocal!;
      final initial = _initialRotationAngle!;
      final current = math.atan2(local.dy - center.dy, local.dx - center.dx);
      // Screen-y grows downward, so a clockwise angular delta in screen
      // space is a CCW rotation in our PDF-space convention.
      final deltaRad = -(current - initial);
      _controller.applyStampRotate(_originalStampRotationDeg! + deltaRad * 180.0 / math.pi);
      return;
    }

    if (handle == PdfAnnotationHandle.body) {
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
      if (selectedStamp != null && _hitTestDeleteButton(selectedStamp, local)) {
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

  // ─────────────────────── Rectangle tool: geometry ──────────────────────

  List<PdfRectAnnotation> _pageRects() =>
      _controller.rects.where((r) => r.pageIndex == _page.pageNumber - 1).toList(growable: false);

  PdfRectAnnotation? _findSelectedRect(String id) {
    for (final r in _pageRects()) {
      if (r.id == id) return r;
    }
    return null;
  }

  Rect _rectLocalRect(PdfRectAnnotation rect) {
    final scaleX = _pageRect.width / _page.width;
    final scaleY = _pageRect.height / _page.height;
    return Rect.fromLTWH(
      rect.rectInPdfSpace.left * scaleX,
      rect.rectInPdfSpace.top * scaleY,
      rect.rectInPdfSpace.width * scaleX,
      rect.rectInPdfSpace.height * scaleY,
    );
  }

  /// The handle rectangle for [rect]. Padding is `0.0`, so it coincides
  /// with the shape's own bounds and the handles sit on the border.
  Rect _rectSelectionRect(PdfRectAnnotation rect) => _selectionRect(_rectLocalRect(rect), _kRectHandlePaddingPx);

  PdfAnnotationHandle? _hitTestRectHandles(PdfRectAnnotation rect, Offset local) => hitTestHandles(
    rect: _rectSelectionRect(rect),
    rotationDeg: rect.rotationDeg,
    point: local,
    hitRadius: _kHandleHitRadiusPx,
    rotationHandleOffset: _kRotateHandleOffsetPx,
  );

  bool _rectBodyContains(PdfRectAnnotation rect, Offset local) =>
      containsRotated(rect: _rectSelectionRect(rect), rotationDeg: rect.rotationDeg, point: local);

  bool _hitTestRectDeleteButton(PdfRectAnnotation rect, Offset local) {
    final selectionRect = _rectSelectionRect(rect);
    final unrotated = unrotatePointToLocal(local, center: selectionRect.center, rotationDeg: rect.rotationDeg);
    return _deleteButtonRectInLocalFrame(selectionRect).contains(unrotated);
  }

  /// The topmost rectangle the current creator may select whose rotated
  /// bounds contain [local], or `null`.
  ///
  /// The candidate list is already in reverse unified paint order with
  /// foreign-creator rectangles skipped, so an own rectangle lying under
  /// a bandmate's is still reachable.
  PdfRectAnnotation? _hitTestSelectableRectBody(Offset local) {
    for (final rect in _controller.selectableRectsForHitTest(_page.pageNumber - 1)) {
      if (_rectBodyContains(rect, local)) return rect;
    }
    return null;
  }

  // ─────────────────────── Rectangle tool: Listener ──────────────────────

  void _onRectPointerDown(Offset local) {
    _pointerDownLocal = local;
    _dragRecognized = false;
    _rubberBanding = false;
    _pendingHandle = null;

    // Drag precedence starts here: only the SELECTED rectangle can
    // capture a drag, and only through one of its handles or its body.
    // A press inside an unselected rectangle leaves `_pendingHandle`
    // null and becomes a new rubber band, so a cover can always be
    // drawn on top of an existing one.
    final selectedId = _controller.selectedRectIdListenable.value;
    if (selectedId == null) return;
    final selected = _findSelectedRect(selectedId);
    if (selected == null) return;
    if (selected.creatorName != _controller.currentCreator) return;

    final hit = _hitTestRectHandles(selected, local);
    if (hit == null) return;
    _pendingHandle = hit;
    if (hit == PdfAnnotationHandle.rotation) {
      final rect = _rectLocalRect(selected);
      _stampCenterLocal = rect.center;
      _initialRotationAngle = math.atan2(local.dy - rect.center.dy, local.dx - rect.center.dx);
      _originalStampRotationDeg = selected.rotationDeg;
    }
  }

  void _onRectPointerMove(Offset local) {
    final start = _pointerDownLocal;
    if (start == null) return;
    final dx = local.dx - start.dx;
    final dy = local.dy - start.dy;

    if (!_dragRecognized) {
      if (dx * dx + dy * dy < _kStampDragSlopPx * _kStampDragSlopPx) return;
      _dragRecognized = true;
      final pending = _pendingHandle;
      if (pending == null) {
        // The anchor is the pointer-DOWN point, not where the slop was
        // crossed, so the rubber band starts where the finger landed.
        _rubberBanding = true;
        _controller.startRectDraft(
          pageIndex: _page.pageNumber - 1,
          anchorPdfPoint: _toPdfSpace(start),
          pageSize: Size(_page.width, _page.height),
        );
      } else {
        _activeHandle = pending;
        _controller.beginRectDrag(pending);
      }
    }

    if (_rubberBanding) {
      _controller.updateRectDraft(_toPdfSpace(local));
      return;
    }

    final handle = _activeHandle;
    if (handle == null) return;

    if (handle == PdfAnnotationHandle.rotation) {
      final center = _stampCenterLocal!;
      final initial = _initialRotationAngle!;
      final current = math.atan2(local.dy - center.dy, local.dx - center.dx);
      // Screen-y grows downward, so a clockwise angular delta in screen
      // space is a CCW rotation in our PDF-space convention.
      final deltaRad = -(current - initial);
      _controller.applyRectRotate(_originalStampRotationDeg! + deltaRad * 180.0 / math.pi);
      return;
    }

    if (handle == PdfAnnotationHandle.body) {
      // Viewer-pixel space, so crossing a page boundary can hand the
      // rectangle to a sibling annotation layer mid-drag.
      _controller.applyRectMoveViewer(local - start);
      return;
    }
    _controller.applyRectResize(_toPdfSpace(local) - _toPdfSpace(start));
  }

  void _onRectPointerUp(Offset local) {
    if (_rubberBanding) {
      if (_controller.commitRectDraft() == null) {
        // Sub-minimum, so discarded. The gesture is NOT consumed: the
        // tap/drag slop is 4 screen pixels while the discard threshold
        // is 8 PDF points, so at low zoom an ordinary fingertip tap
        // lands here. Falling through to the tap precedence at the
        // pointer-up point is what makes an invisible white rectangle
        // selectable with a finger.
        _handleRectTap(local);
      }
    } else if (_dragRecognized) {
      _endRectDrag();
    } else {
      // No movement crossed the slop, so treat this as a tap at the
      // down position: taps don't drift if the finger settles slightly.
      _handleRectTap(_pointerDownLocal ?? local);
    }
    _resetRectPointerState();
  }

  void _onRectPointerCancel() {
    if (_rubberBanding) {
      _controller.cancelRectDraft();
    } else if (_dragRecognized) {
      _endRectDrag();
    }
    _resetRectPointerState();
  }

  void _resetRectPointerState() {
    _rubberBanding = false;
    _resetStampPointerState();
  }

  void _endRectDrag() {
    if (_activeHandle == null) return;
    _controller.endRectDrag();
    _activeHandle = null;
  }

  /// Tap precedence: the delete button, then selecting a rectangle,
  /// then deselecting.
  void _handleRectTap(Offset local) {
    // The delete button sits OUTSIDE the bbox, so the body and
    // empty-area branches below would otherwise eat the tap the user
    // explicitly aimed at.
    final selectedId = _controller.selectedRectIdListenable.value;
    if (selectedId != null) {
      final selected = _findSelectedRect(selectedId);
      if (selected != null && _hitTestRectDeleteButton(selected, local)) {
        _controller.deleteRect(selected.id);
        return;
      }
    }

    final selectable = _hitTestSelectableRectBody(local);
    if (selectable != null) {
      _controller.selectRect(selectable.id);
      return;
    }

    // Empty space, or a rectangle owned by another creator.
    _controller.clearRectSelection();
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
      case PdfAnnotationTool.rectangle:
      case PdfAnnotationTool.hand:
        // stamp and rectangle: handled by the Listener branch. hand:
        // no gesture widget is mounted, so this is unreachable, and is
        // covered for switch exhaustiveness only.
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
      case PdfAnnotationTool.rectangle:
      case PdfAnnotationTool.hand:
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
      case PdfAnnotationTool.rectangle:
      case PdfAnnotationTool.hand:
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
      case PdfAnnotationTool.rectangle:
      case PdfAnnotationTool.hand:
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

/// Builds the quadratic-bezier-smoothed [Path] for an ink stroke,
/// scaling [pointsInPdfSpace] from PDF point space into canvas pixels.
///
/// A naive `moveTo + lineTo*` polyline draws every recorded point
/// verbatim, including any "lift-off" jitter at the end of a touch
/// stroke (sparse trailing points after a dense traced shape). Pspdfkit
/// and most natural-ink renderers smooth ink at draw time, which both
/// softens the visual and absorbs the prominence of sparse trailing
/// points whose direction differs from the surrounding curve.
///
/// Algorithm: for each interior point `p[i]` (i in [1, len-2]), draw a
/// quadratic Bezier whose control point is `p[i]` itself and whose
/// endpoint is the midpoint of `p[i]` and `p[i+1]`. The path therefore
/// passes through the midpoints, with the original points pulling the
/// curve toward them as control points. The final segment is a
/// straight line to the actual last point so the curve terminates
/// exactly where the polyline ends.
///
/// [pointsInPdfSpace] must be non-empty.
@visibleForTesting
Path buildInkStrokePath(List<Offset> pointsInPdfSpace, {required double scaleX, required double scaleY}) {
  final points = pointsInPdfSpace;
  final path = Path()..moveTo(points.first.dx * scaleX, points.first.dy * scaleY);
  if (points.length == 1) {
    // Single-point segment: a tap with no drag, or a 1-point in-flight
    // stroke. Drawing a zero-length line at the same point produces a
    // round-capped dot of diameter `lineWidth` — pspdfkit's "marker
    // tap" rendering. Works for both pen and highlighter since both
    // use round caps.
    path.lineTo(points.first.dx * scaleX, points.first.dy * scaleY);
  } else if (points.length == 2) {
    path.lineTo(points[1].dx * scaleX, points[1].dy * scaleY);
  } else {
    for (var i = 1; i < points.length - 1; i++) {
      final cx = points[i].dx * scaleX;
      final cy = points[i].dy * scaleY;
      final mx = (points[i].dx + points[i + 1].dx) * 0.5 * scaleX;
      final my = (points[i].dy + points[i + 1].dy) * 0.5 * scaleY;
      path.quadraticBezierTo(cx, cy, mx, my);
    }
    path.lineTo(points.last.dx * scaleX, points.last.dy * scaleY);
  }
  return path;
}

/// Paints a single ink stroke onto [canvas], scaling from PDF point
/// space by [scaleX]/[scaleY].
///
/// Both pen and highlighter use round caps + round joins. Highlighter
/// is differentiated by opacity, (typically) larger lineWidth, and
/// [BlendMode.multiply] — not by stroke geometry. Matching pspdfkit's
/// render: highlighter strokes have rounded ends — like a wide-tipped
/// marker — rather than the butt/miter "ruler-edge" look that an
/// earlier prototype shipped.
///
/// The highlighter's [BlendMode.multiply] only tints the page content
/// (rather than covering it) when [canvas] already holds the page
/// bitmap underneath, i.e. when called via [paintPageAnnotations]
/// from the `PdfViewer` page painter.
@visibleForTesting
void paintInkStroke(Canvas canvas, PdfInkAnnotation stroke, {required double scaleX, required double scaleY}) {
  final points = stroke.pointsInPdfSpace;
  if (points.isEmpty) return;
  final paint = Paint()
    ..style = PaintingStyle.stroke
    ..color = stroke.strokeColor.withValues(alpha: stroke.opacity)
    ..strokeWidth = stroke.lineWidth * scaleX
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  if (stroke.kind == PdfInkAnnotationKind.highlighter) {
    paint.blendMode = BlendMode.multiply;
  }
  canvas.drawPath(buildInkStrokePath(points, scaleX: scaleX, scaleY: scaleY), paint);
}

/// Colour of a rectangle's hint outline: a low-contrast grey that reads
/// as a faint guide over a white cover without competing with the score.
const Color kRectHintColor = Color(0x8C7A7A7A);

/// Stroke width (screen pixels) of a rectangle's hint outline.
const double kRectHintStrokeWidthPx = 1.0;

/// Dash and gap lengths (screen pixels) of a rectangle's hint outline.
const double kRectHintDashPx = 4.0;
const double kRectHintGapPx = 3.0;

/// A [Path] tracing [rect]'s border as dashes of [dashLength] separated
/// by gaps of [gapLength], starting at the top-left corner of each edge.
///
/// Dart's `Paint` has no dash support, so the dashes are laid out here
/// rather than handed to the stroker.
@visibleForTesting
Path buildDashedRectPath(Rect rect, {required double dashLength, required double gapLength}) {
  final path = Path();
  final period = dashLength + gapLength;
  if (period <= 0 || dashLength <= 0) return path..addRect(rect);

  void dashEdge(Offset from, Offset to) {
    final length = (to - from).distance;
    if (length <= 0) return;
    final direction = (to - from) / length;
    for (var start = 0.0; start < length; start += period) {
      final end = math.min(start + dashLength, length);
      path
        ..moveTo(from.dx + direction.dx * start, from.dy + direction.dy * start)
        ..lineTo(from.dx + direction.dx * end, from.dy + direction.dy * end);
    }
  }

  dashEdge(rect.topLeft, rect.topRight);
  dashEdge(rect.topRight, rect.bottomRight);
  dashEdge(rect.bottomRight, rect.bottomLeft);
  dashEdge(rect.bottomLeft, rect.topLeft);
  return path;
}

/// Paints [rect] onto [canvas], scaling from PDF point space by
/// [scaleX]/[scaleY] and rotating about the bbox centre. Screen y grows
/// downward, so the package's counter-clockwise `rotationDeg` becomes a
/// negative canvas angle, the same sign [paintStamp] uses.
///
/// A rectangle with no [PdfRectAnnotation.fillColor] paints no fill.
/// `fillColor` is optional in the Instant JSON shape schema, so a
/// third-party or legacy pspdfkit-authored rectangle without one is an
/// outline-only shape: filling it white would hide score content its
/// author never meant to cover, on a build where the rectangle tool may
/// not even exist.
///
/// [showHint] draws the tool's dashed locator outline over the fill.
/// It is painted here, inside this rectangle's own step of the unified
/// sequence, rather than as a pass above it, so a rectangle covered by
/// a later shape has its hint covered too. It is a local viewing
/// affordance and is never persisted.
@visibleForTesting
void paintRect(
  Canvas canvas,
  PdfRectAnnotation rect, {
  required double scaleX,
  required double scaleY,
  required bool showHint,
}) {
  final fill = rect.fillColor;
  if (fill == null && !showHint) return;
  final bounds = Rect.fromLTWH(
    rect.rectInPdfSpace.left * scaleX,
    rect.rectInPdfSpace.top * scaleY,
    rect.rectInPdfSpace.width * scaleX,
    rect.rectInPdfSpace.height * scaleY,
  );
  if (bounds.width <= 0 || bounds.height <= 0) return;

  canvas.save();
  if (rect.rotationDeg != 0) {
    final center = bounds.center;
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-rect.rotationDeg * math.pi / 180.0);
    canvas.translate(-center.dx, -center.dy);
  }
  if (fill != null) {
    canvas.drawRect(bounds, Paint()..color = fill);
  }
  if (showHint) {
    canvas.drawPath(
      buildDashedRectPath(bounds, dashLength: kRectHintDashPx, gapLength: kRectHintGapPx),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = kRectHintStrokeWidthPx
        ..color = kRectHintColor,
    );
  }
  canvas.restore();
}

/// Paints [stamp]'s decoded [picture] onto [canvas], scaling from PDF
/// point space by [scaleX]/[scaleY].
///
/// The picture's intrinsic size is scaled onto the stamp's bbox on both
/// axes independently, reproducing the `BoxFit.fill` the widget layer
/// used, and the result is rotated about the bbox centre. Screen y grows
/// downward, so the package's counter-clockwise `rotationDeg` becomes a
/// negative canvas angle, the same sign the widget layer's
/// `Transform.rotate` used.
///
/// Draws nothing for a degenerate picture or bbox rather than emitting a
/// transform with an infinite or NaN scale factor.
@visibleForTesting
void paintStamp(
  Canvas canvas,
  PdfStampAnnotation stamp,
  PdfDecodedStampPicture picture, {
  required double scaleX,
  required double scaleY,
}) {
  final intrinsic = picture.size;
  if (intrinsic.width <= 0 || intrinsic.height <= 0) return;
  final rect = Rect.fromLTWH(
    stamp.rectInPdfSpace.left * scaleX,
    stamp.rectInPdfSpace.top * scaleY,
    stamp.rectInPdfSpace.width * scaleX,
    stamp.rectInPdfSpace.height * scaleY,
  );
  if (rect.width <= 0 || rect.height <= 0) return;

  canvas.save();
  if (stamp.rotationDeg != 0) {
    final center = rect.center;
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-stamp.rotationDeg * math.pi / 180.0);
    canvas.translate(-center.dx, -center.dy);
  }
  canvas.translate(rect.left, rect.top);
  canvas.scale(rect.width / intrinsic.width, rect.height / intrinsic.height);
  canvas.drawPicture(picture.picture);
  canvas.restore();
}

/// Paints every committed annotation anchored to [page] onto [canvas],
/// positioned and clipped to [pageRect], followed by any in-flight
/// stroke.
///
/// Called from the `PdfViewer` page painter so annotations share the
/// page bitmap's canvas: this is what lets highlighter strokes
/// ([BlendMode.multiply]) tint the underlying page content instead of
/// covering it, and it is why stamps are painted here rather than
/// mounted as widgets above the page: one canvas is what makes a single
/// z-order across annotation kinds possible.
///
/// Committed annotations of every kind are drawn as one sequence in the
/// page's creation order (see [buildPageAnnotationPaintSequence]), so a
/// shape created after another hides it regardless of kind. In-flight
/// strokes are drawn last, on top.
///
/// A rectangle whose `creatorName` matches the current creator carries a
/// dashed hint outline while annotation mode is on and the rectangle
/// tool is active, so an invisible white cover can still be found. The
/// hint is painted inside that rectangle's own step, never as a pass
/// above the sequence.
///
/// A stamp whose attachment has not been decoded yet draws nothing for
/// this frame and schedules its decode; the completion bumps
/// `PdfAnnotationController.stampPicturesChangedListenable`, which the
/// viewer wires to a canvas invalidation. A stamp whose bytes cannot be
/// decoded at all draws nothing for good (logged once by the cache) and
/// never throws from here, so one broken attachment cannot blank the
/// rest of the page.
void paintPageAnnotations(
  Canvas canvas, {
  required Rect pageRect,
  required PdfPage page,
  required PdfAnnotationController controller,
}) {
  final pageIndex = page.pageNumber - 1;
  final sequence = controller.paintSequenceForPage(pageIndex);
  final inFlight = controller.inFlightStrokesFor(pageIndex).toList(growable: false);
  final inFlightRect = controller.inFlightRectFor(pageIndex);
  if (sequence.isEmpty && inFlight.isEmpty && inFlightRect == null) return;
  // The hint is a viewing affordance of the rectangle tool, so both of
  // its gates are read once per paint rather than per entry.
  final hintsVisible =
      controller.annotationModeListenable.value && controller.currentToolListenable.value == PdfAnnotationTool.rectangle;
  final creator = controller.currentCreator;
  final scaleX = pageRect.width / page.width;
  final scaleY = pageRect.height / page.height;
  canvas.save();
  canvas.translate(pageRect.left, pageRect.top);
  // Annotations that extend past the page bounds are visually clipped.
  canvas.clipRect(Offset.zero & pageRect.size);
  for (final entry in sequence) {
    switch (entry) {
      case PdfInkPaintEntry():
        paintInkStroke(canvas, entry.stroke, scaleX: scaleX, scaleY: scaleY);
      case PdfRectPaintEntry():
        paintRect(
          canvas,
          entry.rect,
          scaleX: scaleX,
          scaleY: scaleY,
          showHint: hintsVisible && entry.rect.creatorName == creator,
        );
      case PdfStampPaintEntry():
        final sha = entry.stamp.attachmentSha256;
        final picture = controller.stampPictureFor(sha);
        if (picture == null) {
          controller.ensureStampPictureDecoded(sha);
        } else {
          paintStamp(canvas, entry.stamp, picture, scaleX: scaleX, scaleY: scaleY);
        }
    }
  }
  for (final stroke in inFlight) {
    paintInkStroke(canvas, stroke, scaleX: scaleX, scaleY: scaleY);
  }
  // The rubber band follows the finger, so it is painted last, over
  // everything already committed.
  if (inFlightRect != null) {
    paintRect(canvas, inFlightRect, scaleX: scaleX, scaleY: scaleY, showHint: false);
  }
  canvas.restore();
}

/// Legacy name for [paintPageAnnotations], kept so the fork stays
/// mergeable with upstream pdfrx. The painter is kind-neutral now: the
/// same sequence carries ink and stamps.
@Deprecated('Renamed to paintPageAnnotations now that the painter draws every annotation kind.')
void paintPageInkAnnotations(
  Canvas canvas, {
  required Rect pageRect,
  required PdfPage page,
  required PdfAnnotationController controller,
}) => paintPageAnnotations(canvas, pageRect: pageRect, page: page, controller: controller);

/// Paints the eraser tool's circular cursor preview onto the annotation
/// layer. Annotations themselves are painted on the page canvas by
/// [paintPageAnnotations]; this painter only renders the transient
/// eraser affordance.
@visibleForTesting
class EraserCursorPainter extends CustomPainter {
  EraserCursorPainter({
    required this.eraserCursorProvider,
    required this.eraserRadiusProvider,
    required Listenable repaint,
    required this.pageWidth,
    required this.pageHeight,
  }) : super(repaint: repaint);

  final Offset? Function() eraserCursorProvider;
  final double Function() eraserRadiusProvider;
  final double pageWidth;
  final double pageHeight;

  @override
  void paint(Canvas canvas, Size size) {
    final cursor = eraserCursorProvider();
    if (cursor == null) return;
    canvas.clipRect(Offset.zero & size);
    final scaleX = size.width / pageWidth;
    final scaleY = size.height / pageHeight;
    final center = Offset(cursor.dx * scaleX, cursor.dy * scaleY);
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

  @override
  bool shouldRepaint(EraserCursorPainter old) => old.pageWidth != pageWidth || old.pageHeight != pageHeight;
}
