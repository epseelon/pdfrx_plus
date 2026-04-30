import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';

/// Pill-shaped dots indicator anchored to the top of the viewer overlay.
/// Reads the current page from [currentPage] and tells [controller] to
/// jump when the user taps a dot. Renders nothing when the document
/// isn't ready yet or when there's only one spread to show.
///
/// Designed to be returned from [PdfViewerParams.viewerOverlayBuilder],
/// which mounts it inside a Stack — the widget anchors itself with
/// Positioned + SafeArea.
class PageIndicator extends StatelessWidget {
  const PageIndicator({
    required this.controller,
    required this.twoPageMode,
    required this.currentPage,
    super.key,
  });

  final PdfViewerController controller;
  final bool twoPageMode;
  final ValueListenable<int> currentPage;

  @override
  Widget build(BuildContext context) {
    if (!controller.isReady) return const SizedBox.shrink();
    final pageCount = controller.pageCount;
    final spreadCount = twoPageMode ? (pageCount + 1) ~/ 2 : pageCount;
    if (spreadCount < 2) return const SizedBox.shrink();
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Center(
          child: ValueListenableBuilder<int>(
            valueListenable: currentPage,
            builder: (context, current, _) {
              final currentSpread = twoPageMode ? (current - 1) ~/ 2 : current - 1;
              return Container(
                margin: const EdgeInsets.only(top: 12),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: AnimatedSmoothIndicator(
                  activeIndex: currentSpread.clamp(0, spreadCount - 1),
                  count: spreadCount,
                  duration: const Duration(milliseconds: 0),
                  effect: const ExpandingDotsEffect(
                    dotColor: Colors.white54,
                    activeDotColor: Colors.white,
                    dotHeight: 8,
                    dotWidth: 8,
                    spacing: 8,
                  ),
                  onDotClicked: (i) => controller.goToPage(
                    pageNumber: twoPageMode ? i * 2 + 1 : i + 1,
                    duration: Duration.zero,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
