import 'package:flutter/widgets.dart';
import 'package:pdfrx_engine/pdfrx_engine.dart';

import 'pdf_annotation_controller.dart';
import 'pdf_ink_annotation.dart';

/// Internal per-page widget that paints all [PdfInkAnnotation]s anchored
/// to [page]. Mounted by `PdfViewer` for every visible page.
///
/// Coordinates are converted from PDF point space (top-left origin) to
/// widget pixels using the page's current display rect. Strokes that
/// extend past the page bounds are visually clipped.
///
/// While [PdfAnnotationController.annotationModeListenable] is `true`, a
/// per-page [GestureDetector] is mounted on top of the painter to capture
/// pan input. The active tool ([PdfAnnotationController.currentToolListenable])
/// determines whether pan input draws ([PdfAnnotationTool.pen]) or erases
/// ([PdfAnnotationTool.eraser]). Page rotation is assumed to be `0°`
/// (see spec §17).
class PdfAnnotationLayer extends StatelessWidget {
  const PdfAnnotationLayer({required this.controller, required this.page, required this.pageRect, super.key});

  final PdfAnnotationController controller;
  final PdfPage page;
  final Rect pageRect;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final committed = controller.strokes.where((s) => s.pageIndex == page.pageNumber - 1).toList(growable: false);
        return Stack(
          children: [
            CustomPaint(
              painter: _InkPainter(
                strokes: committed,
                inFlightProvider: () => controller.inFlightStrokesFor(page.pageNumber - 1),
                eraserCursorProvider: () =>
                    controller.eraserCursorPageIndex == page.pageNumber - 1 ? controller.eraserCursorPdfPoint : null,
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
            ValueListenableBuilder<bool>(
              valueListenable: controller.annotationModeListenable,
              builder: (context, modeOn, _) {
                if (!modeOn) return const SizedBox.shrink();
                return Positioned.fill(
                  child: ValueListenableBuilder<PdfAnnotationTool>(
                    valueListenable: controller.currentToolListenable,
                    builder: (context, tool, _) => GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (details) => _onPanStart(tool, details.localPosition),
                      onPanUpdate: (details) => _onPanUpdate(tool, details.localPosition),
                      onPanEnd: (_) => _onPanEnd(tool),
                      onPanCancel: () => _onPanCancel(tool),
                    ),
                  ),
                );
              },
            ),
          ],
        );
      },
    );
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
        );
      case PdfAnnotationTool.eraser:
        controller.startErase(
          pageIndex: page.pageNumber - 1,
          pdfPoint: _toPdfSpace(local),
          radiusInPdfPoints: controller.eraserRadius,
        );
    }
  }

  void _onPanUpdate(PdfAnnotationTool tool, Offset local) {
    switch (tool) {
      case PdfAnnotationTool.pen:
        if (controller.inFlightPageIndex != page.pageNumber - 1) return;
        controller.appendPoint(_toPdfSpace(local));
      case PdfAnnotationTool.eraser:
        controller.continueErase(
          pageIndex: page.pageNumber - 1,
          pdfPoint: _toPdfSpace(local),
          radiusInPdfPoints: controller.eraserRadius,
        );
    }
  }

  void _onPanEnd(PdfAnnotationTool tool) {
    switch (tool) {
      case PdfAnnotationTool.pen:
        controller.commitStroke();
      case PdfAnnotationTool.eraser:
        controller.endErase();
    }
  }

  void _onPanCancel(PdfAnnotationTool tool) {
    switch (tool) {
      case PdfAnnotationTool.pen:
        controller.cancelStroke();
      case PdfAnnotationTool.eraser:
        controller.endErase();
    }
  }

  Offset _toPdfSpace(Offset local) =>
      Offset(local.dx * page.width / pageRect.width, local.dy * page.height / pageRect.height);
}

class _InkPainter extends CustomPainter {
  _InkPainter({
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
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..color = stroke.strokeColor.withValues(alpha: stroke.opacity)
      ..strokeWidth = stroke.lineWidth * scaleX
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final points = stroke.pointsInPdfSpace;
    if (points.isEmpty) return;
    final path = Path()..moveTo(points.first.dx * scaleX, points.first.dy * scaleY);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx * scaleX, points[i].dy * scaleY);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_InkPainter old) =>
      !identical(old.strokes, strokes) || old.pageWidth != pageWidth || old.pageHeight != pageHeight;
}
