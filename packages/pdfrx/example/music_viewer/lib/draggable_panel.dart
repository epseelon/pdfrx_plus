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
class DraggablePanel extends StatefulWidget {
  const DraggablePanel({required this.builder, this.initialOffset, this.bottomSafeAreaInset = 16.0, super.key});

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
  Size? _measuredSize;

  void _onChildSize(Size size) {
    if (size == _measuredSize) return;
    // Defer to after the current layout pass so we don't trigger setState
    // during build / layout.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || size == _measuredSize) return;
      setState(() => _measuredSize = size);
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final measured = _measuredSize;
        final defaultOffset = widget.initialOffset ?? _defaultOffset(context, constraints, measured);
        final raw = _offset ?? defaultOffset;
        final pos = measured == null
            ? raw
            : Offset(
                raw.dx.clamp(0.0, (constraints.maxWidth - measured.width).clamp(0.0, double.infinity)),
                raw.dy.clamp(0.0, (constraints.maxHeight - measured.height).clamp(0.0, double.infinity)),
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
              child: Visibility(
                visible: measured != null,
                maintainSize: true,
                maintainState: true,
                maintainAnimation: true,
                child: _SizeReporter(onSize: _onChildSize, child: widget.builder(context, dragHandle)),
              ),
            ),
          ],
        );
      },
    );
  }

  Offset _defaultOffset(BuildContext context, BoxConstraints constraints, Size? measured) {
    final mq = MediaQuery.of(context);
    final width = measured?.width ?? 0;
    final height = measured?.height ?? 0;
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
