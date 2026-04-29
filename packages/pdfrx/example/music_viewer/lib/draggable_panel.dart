import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Function passed to a [DraggablePanel.builder] that wraps an arbitrary
/// widget so that pan gestures on it move the panel.
typedef DragHandleBuilder = Widget Function(Widget child);

/// A panel that floats over its parent and can be moved by dragging a
/// caller-designated handle. The panel sizes itself to its content; the
/// initial position is bottom-center, inset above the system safe area.
///
/// Embed this in a place with bounded constraints (typically inside a
/// [Stack] via `Positioned.fill`). The panel measures its own size after
/// the first layout pass and uses that to clamp drag positions to the
/// parent rect on subsequent frames.
///
/// The [builder] is given a `dragHandle` function. Wrap any widget with
/// it (typically an [Icon]) to mark that widget as the drag affordance —
/// pan gestures on it will translate the panel.
///
/// Set [resizable] to give the panel a fixed initial size and a
/// bottom-right resize handle. While resizable, the panel does not
/// auto-shrink to its content; the caller's [builder] should be ready
/// to fill the entire box (e.g. wrap scrollable content in `Expanded`).
class DraggablePanel extends StatefulWidget {
  const DraggablePanel({
    required this.builder,
    this.initialOffset,
    this.initialAlignment,
    this.bottomSafeAreaInset = 16.0,
    this.resizable = false,
    this.initialSize = const Size(320, 480),
    this.minSize = const Size(160, 200),
    this.maxSize,
    super.key,
  });

  /// Builds the panel content. The `dragHandle` callback wraps a child
  /// so pan gestures on it move the panel.
  final Widget Function(BuildContext context, DragHandleBuilder dragHandle) builder;

  /// Optional starting offset (top-left of the panel) in parent
  /// coordinates. When `null` and [initialAlignment] is also `null`,
  /// the panel starts bottom-center, inset above the system safe area
  /// by [bottomSafeAreaInset]. Takes precedence over [initialAlignment]
  /// when both are set.
  final Offset? initialOffset;

  /// Default alignment within the parent. Honored only after the
  /// panel's size is known (after measurement for non-resizable panels;
  /// immediately for resizable panels). Convenient for dropping the
  /// panel near a screen edge — e.g. `Alignment.centerRight` for a
  /// stamp-library-style sidebar. A 16 px inset is automatically
  /// applied along whichever axis the alignment touches an edge.
  final Alignment? initialAlignment;

  /// Padding above the bottom safe area when computing the default
  /// initial position. Ignored when [initialOffset] or [initialAlignment]
  /// is set.
  final double bottomSafeAreaInset;

  /// When `true`, the panel renders at a user-controllable size, with
  /// a resize affordance at the bottom-right corner.
  final bool resizable;

  /// Starting size when [resizable] is `true`. Ignored otherwise.
  final Size initialSize;

  /// Minimum size when [resizable] is `true`. The user cannot drag the
  /// resize affordance below this.
  final Size minSize;

  /// Optional maximum size when [resizable] is `true`. When `null`, the
  /// panel can grow up to the parent's available space.
  final Size? maxSize;

  @override
  State<DraggablePanel> createState() => _DraggablePanelState();
}

class _DraggablePanelState extends State<DraggablePanel> {
  Offset? _offset;
  Size? _measuredSize;
  Size? _resizableSize;

  @override
  void initState() {
    super.initState();
    if (widget.resizable) _resizableSize = widget.initialSize;
  }

  void _onChildSize(Size size) {
    if (size == _measuredSize) return;
    // Defer to after the current layout pass so we don't trigger setState
    // during build / layout.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || size == _measuredSize) return;
      setState(() => _measuredSize = size);
    });
  }

  Size? _currentSize() {
    if (widget.resizable) return _resizableSize ?? widget.initialSize;
    return _measuredSize;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final currentSize = _currentSize();
        final defaultOffset = widget.initialOffset ?? _defaultOffset(context, constraints, currentSize);
        final raw = _offset ?? defaultOffset;
        final pos = currentSize == null
            ? raw
            : Offset(
                raw.dx.clamp(0.0, (constraints.maxWidth - currentSize.width).clamp(0.0, double.infinity)),
                raw.dy.clamp(0.0, (constraints.maxHeight - currentSize.height).clamp(0.0, double.infinity)),
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

        Widget content;
        if (widget.resizable) {
          final size = _resizableSize ?? widget.initialSize;
          content = SizedBox(
            width: size.width,
            height: size.height,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(child: widget.builder(context, dragHandle)),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeDownRight,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: (details) {
                        setState(() {
                          final maxW = widget.maxSize?.width ?? constraints.maxWidth;
                          final maxH = widget.maxSize?.height ?? constraints.maxHeight;
                          final newW = (size.width + details.delta.dx).clamp(widget.minSize.width, maxW);
                          final newH = (size.height + details.delta.dy).clamp(widget.minSize.height, maxH);
                          _resizableSize = Size(newW, newH);
                        });
                      },
                      child: const Padding(
                        padding: EdgeInsets.all(2),
                        child: Tooltip(
                          message: 'Drag to resize',
                          child: Icon(Icons.south_east, size: 18),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        } else {
          content = _SizeReporter(onSize: _onChildSize, child: widget.builder(context, dragHandle));
        }

        return Stack(
          children: [
            Positioned(
              left: pos.dx,
              top: pos.dy,
              child: Visibility(
                visible: currentSize != null,
                maintainSize: true,
                maintainState: true,
                maintainAnimation: true,
                child: content,
              ),
            ),
          ],
        );
      },
    );
  }

  Offset _defaultOffset(BuildContext context, BoxConstraints constraints, Size? size) {
    final alignment = widget.initialAlignment;
    if (alignment != null && size != null) {
      const inset = 16.0;
      final maxLeft = (constraints.maxWidth - size.width).clamp(0.0, double.infinity);
      final maxTop = (constraints.maxHeight - size.height).clamp(0.0, double.infinity);
      var left = ((alignment.x + 1) / 2) * maxLeft;
      var top = ((alignment.y + 1) / 2) * maxTop;
      // Inset away from whichever edge the alignment touches.
      if (alignment.x > 0) left -= inset;
      if (alignment.x < 0) left += inset;
      if (alignment.y > 0) top -= inset;
      if (alignment.y < 0) top += inset;
      return Offset(left.clamp(0.0, maxLeft), top.clamp(0.0, maxTop));
    }
    final mq = MediaQuery.of(context);
    final width = size?.width ?? 0;
    final height = size?.height ?? 0;
    return Offset(
      ((constraints.maxWidth - width) / 2).clamp(0.0, double.infinity),
      (constraints.maxHeight - height - mq.padding.bottom - widget.bottomSafeAreaInset).clamp(0.0, double.infinity),
    );
  }
}

class _SizeReporter extends SingleChildRenderObjectWidget {
  const _SizeReporter({required this.onSize, required Widget super.child});

  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) => _SizeReporterBox(onSize);

  @override
  void updateRenderObject(BuildContext context, covariant _SizeReporterBox renderObject) {
    renderObject.onSize = onSize;
  }
}

class _SizeReporterBox extends RenderProxyBox {
  _SizeReporterBox(this.onSize);

  ValueChanged<Size> onSize;
  Size? _lastReported;

  @override
  void performLayout() {
    super.performLayout();
    if (size != _lastReported) {
      _lastReported = size;
      onSize(size);
    }
  }
}
