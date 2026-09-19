import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/annotations/selection_geometry.dart';

// A deliberately non-square rect so a 90° rotation is observable: 40
// wide by 10 tall, centred on (20, 5).
const _wide = Rect.fromLTWH(0, 0, 40, 10);

// A square large enough that its corner region holds points clear of
// every handle's grab radius both before and after a 45° rotation.
// Centre (300, 300); inradius 200, half-diagonal ~283.
const _big = Rect.fromLTWH(100, 100, 400, 400);

void main() {
  group('containsRotated', () {
    test('at 0° it matches the plain axis-aligned containment', () {
      expect(containsRotated(rect: _wide, rotationDeg: 0, point: const Offset(35, 5)), isTrue);
      expect(containsRotated(rect: _wide, rotationDeg: 0, point: const Offset(20, 20)), isFalse);
    });

    test('at 90° the long axis runs vertically', () {
      // (20, 20) is 15 below the centre: outside the unrotated rect,
      // inside it once the long axis stands up.
      expect(containsRotated(rect: _wide, rotationDeg: 90, point: const Offset(20, 20)), isTrue);
      // (35, 5) is 15 right of the centre: inside the unrotated rect,
      // outside once the short axis lies horizontally.
      expect(containsRotated(rect: _wide, rotationDeg: 90, point: const Offset(35, 5)), isFalse);
    });

    test('at 45° containment follows the rotated corners', () {
      // Local (39, 5) sits just inside the right edge at mid-height.
      // Rotated 45° CCW about (20, 5) it lands up and to the right.
      final rotated = rotatePointToScreen(
        const Offset(39, 5),
        center: _wide.center,
        rotationDeg: 45,
      );
      expect(containsRotated(rect: _wide, rotationDeg: 45, point: rotated), isTrue);
      // The same screen point is outside the unrotated rect, so the
      // test would pass vacuously without the rotation.
      expect(_wide.contains(rotated), isFalse);
      // The unrotated right edge is now empty space.
      expect(containsRotated(rect: _wide, rotationDeg: 45, point: const Offset(39, 5)), isFalse);
    });
  });

  group('hitTestHandles', () {
    // Matches the layer's constants: a 22 px grab radius and a rotation
    // handle floating 8 + 24/2 = 20 px above the top edge.
    const hitRadius = 22.0;
    const rotationHandleOffset = 20.0;

    PdfAnnotationHandle? hit(double rotationDeg, Offset point) => hitTestHandles(
      rect: _wide,
      rotationDeg: rotationDeg,
      point: point,
      hitRadius: hitRadius,
      rotationHandleOffset: rotationHandleOffset,
    );

    test('at 0° the corners, edges and rotation handle sit where they are drawn', () {
      expect(hit(0, _wide.topLeft), PdfAnnotationHandle.topLeft);
      expect(hit(0, _wide.bottomRight), PdfAnnotationHandle.bottomRight);
      expect(hit(0, Offset(_wide.right, _wide.center.dy)), PdfAnnotationHandle.right);
      expect(hit(0, Offset(_wide.center.dx, _wide.top - rotationHandleOffset)), PdfAnnotationHandle.rotation);
    });

    test('a press inside the shape but clear of every handle is a body drag', () {
      PdfAnnotationHandle? hitBig(double rotationDeg, Offset point) => hitTestHandles(
        rect: _big,
        rotationDeg: rotationDeg,
        point: point,
        hitRadius: hitRadius,
        rotationHandleOffset: rotationHandleOffset,
      );

      expect(hitBig(0, _big.center), PdfAnnotationHandle.body);
      expect(hitBig(0, const Offset(900, 900)), isNull);

      // The body region rotates with the shape. This point is 250 px
      // from the centre up the top-left diagonal: inside the unrotated
      // square (half-diagonal ~283) and 33 px clear of the corner
      // handle. Un-rotated by 45° it lands 250 px straight above the
      // centre, 50 px past the top edge, clear of both the top handle
      // and the rotation handle 20 px above it.
      final inCorner = _big.center - const Offset(1, 1) * (250 / math.sqrt2);
      expect(hitBig(0, inCorner), PdfAnnotationHandle.body);
      expect(hitBig(45, inCorner), isNull);
    });

    test('at 90° a corner is grabbable where it is drawn, not where it was', () {
      final drawnTopLeft = rotatePointToScreen(_wide.topLeft, center: _wide.center, rotationDeg: 90);
      expect(hit(90, drawnTopLeft), PdfAnnotationHandle.topLeft);
      // The rotation handle rides above the *rotated* top edge, which
      // at 90° points left on screen.
      final drawnRotation = rotatePointToScreen(
        Offset(_wide.center.dx, _wide.top - rotationHandleOffset),
        center: _wide.center,
        rotationDeg: 90,
      );
      expect(hit(90, drawnRotation), PdfAnnotationHandle.rotation);
      expect(drawnRotation.dx, lessThan(_wide.center.dx - rotationHandleOffset));
    });

    test('at 45° every resize handle is hit at its rotated anchor', () {
      for (final handle in kResizeHandles) {
        final anchor = handleAnchorOnScreen(
          rect: _wide,
          rotationDeg: 45,
          handle: handle,
          rotationHandleOffset: rotationHandleOffset,
        );
        expect(hit(45, anchor), handle, reason: 'handle $handle at its own rotated anchor');
      }
    });

    test('closest handle wins over the rotation handle at the top edge midpoint', () {
      // Decision record from the axis-aligned gizmo: a press right on
      // the top edge midpoint picks the `top` resize handle even though
      // the rotation handle is within the grab radius.
      expect(hit(0, Offset(_wide.center.dx, _wide.top)), PdfAnnotationHandle.top);
    });
  });

  group('resizeInLocalFrame', () {
    // A 40x20 shape centred on (100, 100).
    const shape = Rect.fromLTWH(80, 90, 40, 20);

    /// Where [handle]'s anchor is drawn on screen for a shape of
    /// [rect] turned by [rotationDeg].
    Offset drawnAnchor(Rect rect, double rotationDeg, PdfAnnotationHandle handle) =>
        handleAnchorOnScreen(rect: rect, rotationDeg: rotationDeg, handle: handle, rotationHandleOffset: 20);

    const opposite = <PdfAnnotationHandle, PdfAnnotationHandle>{
      PdfAnnotationHandle.topLeft: PdfAnnotationHandle.bottomRight,
      PdfAnnotationHandle.top: PdfAnnotationHandle.bottom,
      PdfAnnotationHandle.topRight: PdfAnnotationHandle.bottomLeft,
      PdfAnnotationHandle.right: PdfAnnotationHandle.left,
      PdfAnnotationHandle.bottomRight: PdfAnnotationHandle.topLeft,
      PdfAnnotationHandle.bottom: PdfAnnotationHandle.top,
      PdfAnnotationHandle.bottomLeft: PdfAnnotationHandle.topRight,
      PdfAnnotationHandle.left: PdfAnnotationHandle.right,
    };

    test('at 0° it reduces to a plain axis-aligned resize', () {
      final resized = resizeInLocalFrame(
        originalRect: shape,
        rotationDeg: 0,
        handle: PdfAnnotationHandle.right,
        delta: const Offset(10, 99),
        lockAspect: false,
      );
      expect(resized.left, closeTo(shape.left, 1e-9));
      expect(resized.top, closeTo(shape.top, 1e-9));
      expect(resized.bottom, closeTo(shape.bottom, 1e-9));
      expect(resized.right, closeTo(shape.right + 10, 1e-9));
    });

    test('a drag along the screen x axis widens a rotated shape along its own axis', () {
      // At 90° the shape's own +x axis points up the screen, so a
      // rightward screen drag must not widen it: the pull projects onto
      // the local -y axis instead, which the `right` handle ignores.
      final resized = resizeInLocalFrame(
        originalRect: shape,
        rotationDeg: 90,
        handle: PdfAnnotationHandle.right,
        delta: const Offset(10, 0),
        lockAspect: false,
      );
      expect(resized.width, closeTo(shape.width, 1e-9));

      // Dragging *up* the screen is the shape's own +x at 90°, so that
      // is what widens it.
      final widened = resizeInLocalFrame(
        originalRect: shape,
        rotationDeg: 90,
        handle: PdfAnnotationHandle.right,
        delta: const Offset(0, -10),
        lockAspect: false,
      );
      expect(widened.width, closeTo(shape.width + 10, 1e-9));
      expect(widened.height, closeTo(shape.height, 1e-9));
    });

    test('the opposite anchor stays fixed on screen for every handle while rotated', () {
      for (final rotationDeg in <double>[0, 30, 45, 90, 137, -60]) {
        for (final handle in kResizeHandles) {
          final before = drawnAnchor(shape, rotationDeg, opposite[handle]!);
          final resized = resizeInLocalFrame(
            originalRect: shape,
            rotationDeg: rotationDeg,
            handle: handle,
            delta: const Offset(13, -7),
            lockAspect: false,
          );
          final after = drawnAnchor(resized, rotationDeg, opposite[handle]!);
          expect(
            after.dx,
            closeTo(before.dx, 1e-9),
            reason: 'handle $handle at $rotationDeg° moved its opposite anchor on x',
          );
          expect(
            after.dy,
            closeTo(before.dy, 1e-9),
            reason: 'handle $handle at $rotationDeg° moved its opposite anchor on y',
          );
        }
      }
    });

    test('re-derives the centre rather than only changing the bounds', () {
      // The regression this guards: keeping the local rect as-is would
      // leave the centre where the un-rotated maths put it, which drags
      // the whole shape across the screen as it is resized.
      final resized = resizeInLocalFrame(
        originalRect: shape,
        rotationDeg: 90,
        handle: PdfAnnotationHandle.right,
        delta: const Offset(0, -20),
        lockAspect: false,
      );
      expect(resized.width, closeTo(shape.width + 20, 1e-9));
      // Local maths alone would put the centre at (110, 100); rotating
      // the growth direction into screen space puts it 10 px *above*
      // the original centre instead.
      expect(resized.center.dx, closeTo(shape.center.dx, 1e-9));
      expect(resized.center.dy, closeTo(shape.center.dy - 10, 1e-9));
    });

    test('clamps each axis at the minimum size instead of discarding the shape', () {
      for (final rotationDeg in <double>[0, 45, 90]) {
        // Pull both of the shape's own axes inward. Expressed on screen
        // that is a different drag per angle, which is exactly the
        // projection under test.
        final resized = resizeInLocalFrame(
          originalRect: shape,
          rotationDeg: rotationDeg,
          handle: PdfAnnotationHandle.bottomRight,
          delta: rotateVectorToScreen(const Offset(-500, -500), rotationDeg),
          lockAspect: false,
        );
        expect(resized.width, closeTo(kMinAnnotationSizePts, 1e-9));
        expect(resized.height, closeTo(kMinAnnotationSizePts, 1e-9));
        // Still anchored on the opposite corner, on screen.
        final before = drawnAnchor(shape, rotationDeg, PdfAnnotationHandle.topLeft);
        final after = drawnAnchor(resized, rotationDeg, PdfAnnotationHandle.topLeft);
        expect(after.dx, closeTo(before.dx, 1e-9));
        expect(after.dy, closeTo(before.dy, 1e-9));
      }
    });

    test('body and rotation handles leave the rect untouched', () {
      for (final handle in <PdfAnnotationHandle>[PdfAnnotationHandle.body, PdfAnnotationHandle.rotation]) {
        expect(
          resizeInLocalFrame(
            originalRect: shape,
            rotationDeg: 45,
            handle: handle,
            delta: const Offset(30, 30),
            lockAspect: false,
          ),
          shape,
        );
      }
    });
  });

  group('resizeInLocalFrame lockAspect', () {
    // 2:1 so an aspect change is unmistakable.
    const shape = Rect.fromLTWH(0, 0, 40, 20);

    test('a locked corner drag keeps the start-of-drag aspect ratio', () {
      final resized = resizeInLocalFrame(
        originalRect: shape,
        rotationDeg: 0,
        handle: PdfAnnotationHandle.bottomRight,
        delta: const Offset(10, 10),
        lockAspect: true,
      );
      expect(resized.width / resized.height, closeTo(2.0, 1e-9));
      // Height is pulled proportionally further (10/20 beats 10/40), so
      // it drives the uniform scale.
      expect(resized.height, closeTo(30, 1e-9));
      expect(resized.width, closeTo(60, 1e-9));
    });

    test('an unlocked corner drag moves each axis independently', () {
      final resized = resizeInLocalFrame(
        originalRect: shape,
        rotationDeg: 0,
        handle: PdfAnnotationHandle.bottomRight,
        delta: const Offset(10, 10),
        lockAspect: false,
      );
      expect(resized.width, closeTo(50, 1e-9));
      expect(resized.height, closeTo(30, 1e-9));
      expect(resized.width / resized.height, isNot(closeTo(2.0, 1e-9)));
    });

    test('lockAspect does not affect edge handles', () {
      for (final lockAspect in <bool>[true, false]) {
        final resized = resizeInLocalFrame(
          originalRect: shape,
          rotationDeg: 0,
          handle: PdfAnnotationHandle.right,
          delta: const Offset(10, 10),
          lockAspect: lockAspect,
        );
        expect(resized.width, closeTo(50, 1e-9), reason: 'lockAspect: $lockAspect');
        expect(resized.height, closeTo(20, 1e-9), reason: 'lockAspect: $lockAspect');
      }
    });

    test('both modes keep the opposite corner fixed on screen while rotated', () {
      for (final lockAspect in <bool>[true, false]) {
        final before = handleAnchorOnScreen(
          rect: shape,
          rotationDeg: 45,
          handle: PdfAnnotationHandle.topLeft,
          rotationHandleOffset: 20,
        );
        final resized = resizeInLocalFrame(
          originalRect: shape,
          rotationDeg: 45,
          handle: PdfAnnotationHandle.bottomRight,
          delta: const Offset(12, 9),
          lockAspect: lockAspect,
        );
        final after = handleAnchorOnScreen(
          rect: resized,
          rotationDeg: 45,
          handle: PdfAnnotationHandle.topLeft,
          rotationHandleOffset: 20,
        );
        expect(after.dx, closeTo(before.dx, 1e-9), reason: 'lockAspect: $lockAspect');
        expect(after.dy, closeTo(before.dy, 1e-9), reason: 'lockAspect: $lockAspect');
      }
    });
  });
}
