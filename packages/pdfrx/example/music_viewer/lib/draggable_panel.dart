import 'package:flutter/material.dart';

/// Function passed to a [DraggablePanel.builder] that wraps an arbitrary
/// widget so that pan gestures on it move the panel.
typedef DragHandleBuilder = Widget Function(Widget child);

/// A fixed-size panel that floats over its parent and can be moved by
/// dragging a caller-designated handle.
///
/// Embed this in a [Stack] (or anywhere with bounded constraints) — it
/// expects to fill its parent so it can compute clamp bounds and the
/// initial position from the parent's size.
///
/// The [builder] is given a `dragHandle` function. Wrap any widget with
/// it (typically an [Icon]) to mark that widget as the drag affordance
/// — pan gestures on it will translate the panel.
class DraggablePanel extends StatefulWidget {
  const DraggablePanel({
    required this.size,
    required this.builder,
    this.initialOffset,
    this.bottomSafeAreaInset = 16.0,
    super.key,
  });

  /// Outer dimensions of the panel. Drives initial placement and clamp
  /// bounds.
  final Size size;

  /// Builds the panel content. The `dragHandle` callback wraps a child
  /// so pan gestures on it move the panel.
  final Widget Function(BuildContext context, DragHandleBuilder dragHandle) builder;

  /// Optional starting offset (top-left of the panel) in parent
  /// coordinates. When `null`, the panel starts bottom-center, inset
  /// above the system safe area by [bottomSafeAreaInset].
  final Offset? initialOffset;

  /// Padding above the bottom safe area when computing the default
  /// initial position. Ignored when [initialOffset] is set.
  final double bottomSafeAreaInset;

  @override
  State<DraggablePanel> createState() => _DraggablePanelState();
}

class _DraggablePanelState extends State<DraggablePanel> {
  Offset? _offset;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final defaultOffset = widget.initialOffset ?? _defaultOffset(context, constraints);
        final raw = _offset ?? defaultOffset;
        final pos = Offset(
          raw.dx.clamp(0.0, constraints.maxWidth - widget.size.width),
          raw.dy.clamp(0.0, constraints.maxHeight - widget.size.height),
        );

        Widget dragHandle(Widget child) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (details) {
            setState(() {
              _offset = (_offset ?? defaultOffset) + details.delta;
            });
          },
          child: child,
        );

        return Stack(
          children: [
            Positioned(
              left: pos.dx,
              top: pos.dy,
              child: SizedBox(
                width: widget.size.width,
                height: widget.size.height,
                child: widget.builder(context, dragHandle),
              ),
            ),
          ],
        );
      },
    );
  }

  Offset _defaultOffset(BuildContext context, BoxConstraints constraints) {
    final mq = MediaQuery.of(context);
    return Offset(
      (constraints.maxWidth - widget.size.width) / 2,
      constraints.maxHeight - widget.size.height - mq.padding.bottom - widget.bottomSafeAreaInset,
    );
  }
}
