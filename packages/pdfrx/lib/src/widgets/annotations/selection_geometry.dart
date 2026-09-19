import 'dart:math' as math;
import 'dart:ui';

/// Active drag affordance on the currently-selected annotation. The
/// annotation layer captures one of these at pointer-down and uses it to
/// dispatch subsequent updates to the corresponding controller mutator.
///
/// Shape-neutral: the same gizmo serves stamps and rectangles.
enum PdfAnnotationHandle {
  /// Drag the shape's body to translate it.
  body,

  /// Drag the rotation handle (floats above the rotated top edge).
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

/// The eight resize handles, in clockwise order starting at the
/// top-left corner. Excludes [PdfAnnotationHandle.body] and
/// [PdfAnnotationHandle.rotation], which are not resize affordances.
const List<PdfAnnotationHandle> kResizeHandles = <PdfAnnotationHandle>[
  PdfAnnotationHandle.topLeft,
  PdfAnnotationHandle.top,
  PdfAnnotationHandle.topRight,
  PdfAnnotationHandle.right,
  PdfAnnotationHandle.bottomRight,
  PdfAnnotationHandle.bottom,
  PdfAnnotationHandle.bottomLeft,
  PdfAnnotationHandle.left,
];

/// Minimum annotation width/height (PDF points) clamped during a resize
/// so the affordances stay tappable.
const double kMinAnnotationSizePts = 8.0;

/// Whether [handle] is one of the four corner handles.
bool isCornerHandle(PdfAnnotationHandle handle) =>
    handle == PdfAnnotationHandle.topLeft ||
    handle == PdfAnnotationHandle.topRight ||
    handle == PdfAnnotationHandle.bottomLeft ||
    handle == PdfAnnotationHandle.bottomRight;

/// Rotates [vector] out of a shape's local frame into screen space.
///
/// [rotationDeg] is degrees counter-clockwise, the convention the whole
/// annotation stack uses; the widget layer renders it as
/// `Transform.rotate(angle: -rotationDeg * pi / 180)`. Screen space has
/// y growing downward, which is why the angle is negated here.
Offset rotateVectorToScreen(Offset vector, double rotationDeg) {
  if (rotationDeg == 0) return vector;
  final theta = -rotationDeg * math.pi / 180.0;
  final cos = math.cos(theta);
  final sin = math.sin(theta);
  return Offset(vector.dx * cos - vector.dy * sin, vector.dx * sin + vector.dy * cos);
}

/// Rotates [vector] from screen space into a shape's local frame. The
/// inverse of [rotateVectorToScreen].
Offset unrotateVectorToLocal(Offset vector, double rotationDeg) => rotateVectorToScreen(vector, -rotationDeg);

/// Rotates [point] out of a shape's local frame into screen space,
/// about [center].
Offset rotatePointToScreen(Offset point, {required Offset center, required double rotationDeg}) =>
    center + rotateVectorToScreen(point - center, rotationDeg);

/// Rotates [point] from screen space into a shape's local frame, about
/// [center]. This is the un-rotation every hit-test starts with: once
/// the pointer is in the shape's own frame, containment and handle
/// distances are plain axis-aligned arithmetic again.
Offset unrotatePointToLocal(Offset point, {required Offset center, required double rotationDeg}) =>
    center + unrotateVectorToLocal(point - center, rotationDeg);

/// Whether [point] (screen space) falls inside [rect] once [rect] is
/// rotated by [rotationDeg] about its own centre.
bool containsRotated({required Rect rect, required double rotationDeg, required Offset point}) =>
    rect.contains(unrotatePointToLocal(point, center: rect.center, rotationDeg: rotationDeg));

/// The anchor of [handle] on [rect], in the shape's own local frame.
///
/// [rotationHandleOffset] is how far above the top edge the rotation
/// handle's centre floats (its gap plus half its size).
Offset handleAnchorInLocalFrame({
  required Rect rect,
  required PdfAnnotationHandle handle,
  required double rotationHandleOffset,
}) => switch (handle) {
  PdfAnnotationHandle.topLeft => rect.topLeft,
  PdfAnnotationHandle.top => Offset(rect.center.dx, rect.top),
  PdfAnnotationHandle.topRight => rect.topRight,
  PdfAnnotationHandle.right => Offset(rect.right, rect.center.dy),
  PdfAnnotationHandle.bottomRight => rect.bottomRight,
  PdfAnnotationHandle.bottom => Offset(rect.center.dx, rect.bottom),
  PdfAnnotationHandle.bottomLeft => rect.bottomLeft,
  PdfAnnotationHandle.left => Offset(rect.left, rect.center.dy),
  PdfAnnotationHandle.rotation => Offset(rect.center.dx, rect.top - rotationHandleOffset),
  PdfAnnotationHandle.body => rect.center,
};

/// The anchor of [handle] on [rect] in screen space, i.e. where the
/// affordance is actually drawn once the shape is rotated.
Offset handleAnchorOnScreen({
  required Rect rect,
  required double rotationDeg,
  required PdfAnnotationHandle handle,
  required double rotationHandleOffset,
}) => rotatePointToScreen(
  handleAnchorInLocalFrame(rect: rect, handle: handle, rotationHandleOffset: rotationHandleOffset),
  center: rect.center,
  rotationDeg: rotationDeg,
);

/// Returns the handle of the shape described by [rect] / [rotationDeg]
/// closest to [point] (screen space) within [hitRadius], falling back to
/// [PdfAnnotationHandle.body] when [point] is inside the rotated shape
/// and to `null` when it misses entirely.
///
/// [point] is un-rotated into the shape's own frame first, so a rotated
/// shape's corners are grabbable exactly where they are drawn. Closest
/// wins over priority order, so the top-edge midpoint beats the rotation
/// handle when the user presses right on the edge.
PdfAnnotationHandle? hitTestHandles({
  required Rect rect,
  required double rotationDeg,
  required Offset point,
  required double hitRadius,
  required double rotationHandleOffset,
}) {
  final local = unrotatePointToLocal(point, center: rect.center, rotationDeg: rotationDeg);
  PdfAnnotationHandle? best;
  var bestDistSq = hitRadius * hitRadius;

  void consider(PdfAnnotationHandle handle) {
    final anchor = handleAnchorInLocalFrame(rect: rect, handle: handle, rotationHandleOffset: rotationHandleOffset);
    final dx = local.dx - anchor.dx;
    final dy = local.dy - anchor.dy;
    final distSq = dx * dx + dy * dy;
    if (distSq <= bestDistSq) {
      best = handle;
      bestDistSq = distSq;
    }
  }

  for (final handle in kResizeHandles) {
    consider(handle);
  }
  consider(PdfAnnotationHandle.rotation);

  if (best != null) return best;
  if (rect.contains(local)) return PdfAnnotationHandle.body;
  return null;
}

/// Resizes [originalRect] by dragging [handle] with the cumulative
/// screen-space [delta], for a shape turned by [rotationDeg] about its
/// own centre.
///
/// [delta] is projected into the shape's local frame first, so pulling
/// the right handle widens the shape along *its* axis rather than the
/// screen's. Each axis clamps at [minSize] rather than collapsing.
///
/// With [lockAspect] the four corner handles preserve the start-of-drag
/// aspect ratio: the axis the cursor pulls further in proportion to its
/// original size drives a uniform scale. Without it every handle moves
/// its own edges independently.
///
/// Because a shape is rendered rotated about its *centre*, resizing has
/// to re-derive that centre, not merely change the rect's bounds: the
/// local resize moves the centre, and that displacement has to be
/// rotated back into screen space for the handle's opposite corner or
/// edge to stay where the user sees it. The returned rect is therefore
/// the un-rotated model rect (its width and height are local), centred
/// where the shape must now sit on screen.
Rect resizeInLocalFrame({
  required Rect originalRect,
  required double rotationDeg,
  required PdfAnnotationHandle handle,
  required Offset delta,
  required bool lockAspect,
  double minSize = kMinAnnotationSizePts,
}) {
  if (handle == PdfAnnotationHandle.body || handle == PdfAnnotationHandle.rotation) return originalRect;

  final localDelta = unrotateVectorToLocal(delta, rotationDeg);
  final resized = lockAspect && isCornerHandle(handle)
      ? _resizeCornerLocked(orig: originalRect, handle: handle, delta: localDelta, minSize: minSize)
      : _resizeFree(orig: originalRect, handle: handle, delta: localDelta, minSize: minSize);

  final center = originalRect.center + rotateVectorToScreen(resized.center - originalRect.center, rotationDeg);
  return Rect.fromCenter(center: center, width: resized.width, height: resized.height);
}

/// Moves whichever edges [handle] owns by [delta], anchoring the
/// others. Each axis clamps at [minSize] by pulling the moved edge
/// back, so the anchored edge never shifts.
Rect _resizeFree({
  required Rect orig,
  required PdfAnnotationHandle handle,
  required Offset delta,
  required double minSize,
}) {
  var left = orig.left;
  var top = orig.top;
  var right = orig.right;
  var bottom = orig.bottom;

  if (_movesLeftEdge(handle)) {
    left = orig.left + delta.dx;
    if (right - left < minSize) left = right - minSize;
  }
  if (_movesRightEdge(handle)) {
    right = orig.right + delta.dx;
    if (right - left < minSize) right = left + minSize;
  }
  if (_movesTopEdge(handle)) {
    top = orig.top + delta.dy;
    if (bottom - top < minSize) top = bottom - minSize;
  }
  if (_movesBottomEdge(handle)) {
    bottom = orig.bottom + delta.dy;
    if (bottom - top < minSize) bottom = top + minSize;
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

/// Corner resize that preserves [orig]'s aspect ratio. The dominant
/// axis (the one pulled further in proportion to its original size)
/// drives a uniform scale; the opposite corner anchors.
Rect _resizeCornerLocked({
  required Rect orig,
  required PdfAnnotationHandle handle,
  required Offset delta,
  required double minSize,
}) {
  final candidateWidth = orig.width + (_movesRightEdge(handle) ? delta.dx : -delta.dx);
  final candidateHeight = orig.height + (_movesBottomEdge(handle) ? delta.dy : -delta.dy);

  final scaleW = candidateWidth / orig.width;
  final scaleH = candidateHeight / orig.height;
  var scale = (scaleW - 1).abs() >= (scaleH - 1).abs() ? scaleW : scaleH;

  // Min-size clamp respects the aspect: take the larger of the two
  // axis-specific minimum scales so neither dimension drops below it.
  final minScale = math.max(minSize / orig.width, minSize / orig.height);
  if (scale < minScale) scale = minScale;

  final width = orig.width * scale;
  final height = orig.height * scale;

  return Rect.fromLTRB(
    _movesLeftEdge(handle) ? orig.right - width : orig.left,
    _movesTopEdge(handle) ? orig.bottom - height : orig.top,
    _movesLeftEdge(handle) ? orig.right : orig.left + width,
    _movesTopEdge(handle) ? orig.bottom : orig.top + height,
  );
}

bool _movesLeftEdge(PdfAnnotationHandle h) =>
    h == PdfAnnotationHandle.topLeft || h == PdfAnnotationHandle.left || h == PdfAnnotationHandle.bottomLeft;

bool _movesRightEdge(PdfAnnotationHandle h) =>
    h == PdfAnnotationHandle.topRight || h == PdfAnnotationHandle.right || h == PdfAnnotationHandle.bottomRight;

bool _movesTopEdge(PdfAnnotationHandle h) =>
    h == PdfAnnotationHandle.topLeft || h == PdfAnnotationHandle.top || h == PdfAnnotationHandle.topRight;

bool _movesBottomEdge(PdfAnnotationHandle h) =>
    h == PdfAnnotationHandle.bottomLeft || h == PdfAnnotationHandle.bottom || h == PdfAnnotationHandle.bottomRight;
