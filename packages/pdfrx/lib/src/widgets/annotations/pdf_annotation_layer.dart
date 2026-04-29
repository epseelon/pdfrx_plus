import 'dart:async';

import 'package:flutter/widgets.dart';
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
/// ([PdfAnnotationTool.eraser]), or places stamps
/// ([PdfAnnotationTool.stamp]). Page rotation is assumed to be `0°`
/// (see spec §17).
class PdfAnnotationLayer extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: controller.annotationModeListenable,
      builder: (context, modeOn, _) {
        // When annotation mode is off, the layer is purely visual: stroke
        // painting must never absorb taps or pinches that belong to the
        // viewer's pan/scale + onGeneralTap pipeline below us in the stack.
        return IgnorePointer(
          ignoring: !modeOn,
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, _) {
              final committed = controller.strokes
                  .where((s) => s.pageIndex == page.pageNumber - 1)
                  .toList(growable: false);
              final pageStamps = controller.stamps
                  .where((s) => s.pageIndex == page.pageNumber - 1)
                  .toList(growable: false);
              final scaleX = pageRect.width / page.width;
              final scaleY = pageRect.height / page.height;
              return Stack(
                children: [
                  CustomPaint(
                    painter: InkPainter(
                      strokes: committed,
                      inFlightProvider: () => controller.inFlightStrokesFor(page.pageNumber - 1),
                      eraserCursorProvider: () => controller.eraserCursorPageIndex == page.pageNumber - 1
                          ? controller.eraserCursorPdfPoint
                          : null,
                      eraserRadiusProvider: () => controller.eraserRadius,
                      repaint: Listenable.merge([
                        controller.inFlightChangedListenable,
                        controller.eraserCursorChangedListenable,
                        controller.eraserRadiusListenable,
                      ]),
                      pageWidth: page.width,
                      pageHeight: page.height,
                    ),
                    size: pageRect.size,
                  ),
                  for (final stamp in pageStamps)
                    Positioned(
                      key: Key('stamp:${stamp.id}'),
                      left: stamp.rectInPdfSpace.left * scaleX,
                      top: stamp.rectInPdfSpace.top * scaleY,
                      width: stamp.rectInPdfSpace.width * scaleX,
                      height: stamp.rectInPdfSpace.height * scaleY,
                      child: Transform.rotate(
                        angle: -stamp.rotationDeg * 3.141592653589793 / 180.0,
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
                        valueListenable: controller.currentToolListenable,
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

  Widget _buildStampChild(BuildContext context, PdfStampAnnotation stamp, double scaleX, double scaleY) {
    final builder = stampImageBuilder;
    final attachment = controller.attachments[stamp.attachmentSha256];
    if (builder == null || attachment == null) {
      return const SizedBox.shrink();
    }
    final displaySize = Size(stamp.rectInPdfSpace.width * scaleX, stamp.rectInPdfSpace.height * scaleY);
    return builder(context, attachment.bytes, stamp.contentType, displaySize);
  }

  void _onTapUp(PdfAnnotationTool tool, Offset local) {
    if (tool != PdfAnnotationTool.stamp) return;
    final pending = controller.pendingStampListenable.value;
    if (pending == null) {
      // Phase 2 will handle selection; for Phase 1 a tap with no pending
      // is a consumed no-op.
      return;
    }
    unawaited(_placePendingStamp(pending, local));
  }

  Future<void> _placePendingStamp(PdfStampDefinition pending, Offset local) async {
    try {
      final bytes = await pending.bytesLoader();
      final pdfPoint = _toPdfSpace(local);
      controller.placeStamp(
        bytes: bytes,
        contentType: pending.contentType,
        pageIndex: page.pageNumber - 1,
        pdfPoint: pdfPoint,
        intrinsicSize: pending.intrinsicSize,
        pageSize: Size(page.width, page.height),
      );
    } catch (e, st) {
      debugPrint('stamp placement failed: $e\n$st');
    }
  }

  void _onPanStart(PdfAnnotationTool tool, Offset local) {
    switch (tool) {
      case PdfAnnotationTool.pen:
        final inFlightPage = controller.inFlightPageIndex;
        if (inFlightPage != null) return;
        controller.startStroke(
          pageIndex: page.pageNumber - 1,
          firstPoint: _toPdfSpace(local),
          lineWidth: controller.strokeWidth,
          strokeColor: controller.strokeColor,
          opacity: 1.0,
          kind: PdfInkAnnotationKind.pen,
        );
      case PdfAnnotationTool.highlighter:
        final inFlightPage = controller.inFlightPageIndex;
        if (inFlightPage != null) return;
        controller.startStroke(
          pageIndex: page.pageNumber - 1,
          firstPoint: _toPdfSpace(local),
          lineWidth: controller.highlighterWidth,
          strokeColor: controller.highlighterColor,
          opacity: highlighterOpacity.clamp(0.0, 1.0),
          kind: PdfInkAnnotationKind.highlighter,
        );
      case PdfAnnotationTool.eraser:
        controller.startErase(
          pageIndex: page.pageNumber - 1,
          pdfPoint: _toPdfSpace(local),
          radiusInPdfPoints: controller.eraserRadius,
        );
      case PdfAnnotationTool.stamp:
        // Phase 2 wires drag-to-move/resize/rotate. For Phase 1 a pan in
        // stamp mode is a consumed no-op so the gesture detector does
        // not draw a stroke.
        return;
    }
  }

  void _onPanUpdate(PdfAnnotationTool tool, Offset local) {
    switch (tool) {
      case PdfAnnotationTool.pen:
      case PdfAnnotationTool.highlighter:
        if (controller.inFlightPageIndex != page.pageNumber - 1) return;
        controller.appendPoint(_toPdfSpace(local));
      case PdfAnnotationTool.eraser:
        controller.continueErase(
          pageIndex: page.pageNumber - 1,
          pdfPoint: _toPdfSpace(local),
          radiusInPdfPoints: controller.eraserRadius,
        );
      case PdfAnnotationTool.stamp:
        return;
    }
  }

  void _onPanEnd(PdfAnnotationTool tool) {
    switch (tool) {
      case PdfAnnotationTool.pen:
      case PdfAnnotationTool.highlighter:
        controller.commitStroke();
      case PdfAnnotationTool.eraser:
        controller.endErase();
      case PdfAnnotationTool.stamp:
        return;
    }
  }

  void _onPanCancel(PdfAnnotationTool tool) {
    switch (tool) {
      case PdfAnnotationTool.pen:
      case PdfAnnotationTool.highlighter:
        controller.cancelStroke();
      case PdfAnnotationTool.eraser:
        controller.endErase();
      case PdfAnnotationTool.stamp:
        return;
    }
  }

  Offset _toPdfSpace(Offset local) =>
      Offset(local.dx * page.width / pageRect.width, local.dy * page.height / pageRect.height);
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
