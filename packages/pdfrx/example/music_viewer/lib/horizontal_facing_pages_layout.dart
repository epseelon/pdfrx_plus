import 'dart:math' show max, min;

import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

/// Horizontally-scrolling facing-pages layout.
///
/// Pages are grouped into spreads `(1,2), (3,4), ...` (no cover) and the
/// spreads are laid out left-to-right. A trailing odd page becomes a
/// single-page spread.
///
/// Combine with [PageTransition.discrete] to snap one spread at a time.
class HorizontalFacingPagesLayout extends PdfSpreadLayout {
  HorizontalFacingPagesLayout({
    required super.pageLayouts,
    required super.documentSize,
    required super.spreadLayouts,
    required super.pageToSpreadIndex,
  });

  factory HorizontalFacingPagesLayout.fromPages(
    List<PdfPage> pages,
    PdfViewerParams params, {
    required PdfLayoutHelper helper,
    double? gutter,
  }) {
    final pageLayouts = <Rect>[];
    final spreadLayouts = <Rect>[];
    final pageToSpreadIndex = <int>[];
    final m = params.margin;
    final g = gutter ?? m;
    var x = m;

    for (var i = 0; i < pages.length; i += 2) {
      final left = pages[i];
      final right = i + 1 < pages.length ? pages[i + 1] : null;
      final pairW = left.width + (right == null ? 0 : right.width + g);
      final pairH = right == null ? left.height : max(left.height, right.height);
      final scale = min(helper.availableWidth / pairW, helper.availableHeight / pairH);

      final lw = left.width * scale, lh = left.height * scale;
      final rw = (right?.width ?? 0) * scale, rh = (right?.height ?? 0) * scale;
      final spreadH = max(lh, rh);
      final spreadW = lw + (right == null ? 0 : g + rw);
      final y = m + (helper.availableHeight - spreadH) / 2;

      pageLayouts.add(Rect.fromLTWH(x, y + (spreadH - lh) / 2, lw, lh));
      pageToSpreadIndex.add(spreadLayouts.length);
      if (right != null) {
        pageLayouts.add(Rect.fromLTWH(x + lw + g, y + (spreadH - rh) / 2, rw, rh));
        pageToSpreadIndex.add(spreadLayouts.length);
      }
      spreadLayouts.add(Rect.fromLTWH(x, y, spreadW, spreadH));
      x += spreadW + m;
    }

    return HorizontalFacingPagesLayout(
      pageLayouts: pageLayouts,
      documentSize: Size(x, helper.availableHeight + m * 2),
      spreadLayouts: spreadLayouts,
      pageToSpreadIndex: pageToSpreadIndex,
    );
  }

  @override
  Axis get primaryAxis => Axis.horizontal;
}
