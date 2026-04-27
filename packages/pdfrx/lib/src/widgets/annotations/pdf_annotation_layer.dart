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
/// pan input. Page rotation is assumed to be `0°` (see spec §17).
class PdfAnnotationLayer extends StatelessWidget {
  const PdfAnnotationLayer({
    required this.controller,
    required this.page,
    required this.pageRect,
    required this.newStrokeColor,
    required this.newStrokeWidth,
    super.key,
  });

  final PdfAnnotationController controller;
  final PdfPage page;
  final Rect pageRect;

  /// Stroke color applied to new strokes drawn on this page in annotation
  /// mode. Imported strokes carry their own color and ignore this default.
  final Color newStrokeColor;

  /// Stroke width (PDF points) applied to new strokes drawn on this page.
  /// Imported strokes carry their own width and ignore this default.
  final double newStrokeWidth;

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
                inFlightRepaint: controller.inFlightChangedListenable,
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
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (details) => _onPanStart(details.localPosition),
                    onPanUpdate: (details) => _onPanUpdate(details.localPosition),
                    onPanEnd: (_) => controller.commitStroke(),
                    onPanCancel: controller.cancelStroke,
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }

  void _onPanStart(Offset local) {
    final inFlightPage = controller.inFlightPageIndex;
    if (inFlightPage != null) return;
    controller.startStroke(
      pageIndex: page.pageNumber - 1,
      firstPoint: _toPdfSpace(local),
      lineWidth: newStrokeWidth,
      strokeColor: newStrokeColor,
      opacity: 1.0,
    );
  }

  void _onPanUpdate(Offset local) {
    if (controller.inFlightPageIndex != page.pageNumber - 1) return;
    controller.appendPoint(_toPdfSpace(local));
  }

  Offset _toPdfSpace(Offset local) =>
      Offset(local.dx * page.width / pageRect.width, local.dy * page.height / pageRect.height);
}

class _InkPainter extends CustomPainter {
  _InkPainter({
    required this.strokes,
    required this.inFlightProvider,
    required Listenable inFlightRepaint,
    required this.pageWidth,
    required this.pageHeight,
  }) : super(repaint: inFlightRepaint);

  final List<PdfInkAnnotation> strokes;
  final Iterable<PdfInkAnnotation> Function() inFlightProvider;
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
