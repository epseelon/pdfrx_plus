import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

/// Vertically-scrollable picker UI rendering one section per
/// [PdfViewerStampCategory]. Tapping a thumbnail toggles arming for
/// the corresponding stamp via [PdfViewerController.setPendingStamp]:
/// tap an unarmed thumbnail to arm it; tap the same thumbnail again to
/// disarm (so the next page-tap places nothing). The armed thumbnail
/// shows a 2 px primary-coloured border so the user can see what's
/// currently active.
///
/// Categories are sorted by `id` ascending; stamps within each category
/// are sorted by `id` ascending — the picker never mutates the input
/// lists. Each thumbnail carries a stable `Key('stampThumb:$catId/$stampId')`
/// for tests to drive.
///
/// The panel renders flat (no `Material`/elevation/border-radius of its
/// own); callers wrap it in whatever container they want. The
/// scrollable content fills the available constraints, so the picker
/// works equally well inside a fixed-size box (e.g. a resizable
/// floating panel) or as a flex child via `Expanded`.
class StampPickerPanel extends StatefulWidget {
  const StampPickerPanel({
    required this.controller,
    required this.categories,
    required this.stampImageBuilder,
    super.key,
  });

  final PdfViewerController controller;
  final List<PdfViewerStampCategory> categories;
  final PdfStampImageBuilder stampImageBuilder;

  @override
  State<StampPickerPanel> createState() => _StampPickerPanelState();
}

class _StampPickerPanelState extends State<StampPickerPanel> {
  // Held by the panel so the always-visible Scrollbar can attach to the
  // SingleChildScrollView's Scrollable.
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sortedCategories = [...widget.categories]..sort((a, b) => a.id.compareTo(b.id));
    return ValueListenableBuilder<PdfStampDefinition?>(
      valueListenable: widget.controller.pendingStampListenable,
      builder: (context, pending, _) => Scrollbar(
        controller: _scrollController,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _scrollController,
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final category in sortedCategories)
                _StampCategorySection(
                  category: category,
                  pending: pending,
                  onTap: widget.controller.setPendingStamp,
                  stampImageBuilder: widget.stampImageBuilder,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StampCategorySection extends StatelessWidget {
  const _StampCategorySection({
    required this.category,
    required this.pending,
    required this.onTap,
    required this.stampImageBuilder,
  });

  final PdfViewerStampCategory category;
  final PdfStampDefinition? pending;
  final ValueChanged<PdfStampDefinition?> onTap;
  final PdfStampImageBuilder stampImageBuilder;

  @override
  Widget build(BuildContext context) {
    final sortedStamps = [...category.stamps]..sort((a, b) => a.id.compareTo(b.id));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Text(category.title, style: Theme.of(context).textTheme.titleSmall),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final stamp in sortedStamps)
                _StampThumbnail(
                  key: Key('stampThumb:${category.id}/${stamp.id}'),
                  stamp: stamp,
                  isPending: identical(pending, stamp),
                  onTap: () => onTap(identical(pending, stamp) ? null : stamp),
                  stampImageBuilder: stampImageBuilder,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StampThumbnail extends StatefulWidget {
  const _StampThumbnail({
    required this.stamp,
    required this.isPending,
    required this.onTap,
    required this.stampImageBuilder,
    super.key,
  });

  final PdfStampDefinition stamp;
  final bool isPending;
  final VoidCallback onTap;
  final PdfStampImageBuilder stampImageBuilder;

  @override
  State<_StampThumbnail> createState() => _StampThumbnailState();
}

class _StampThumbnailState extends State<_StampThumbnail> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await widget.stamp.bytesLoader();
      if (!mounted) return;
      setState(() => _bytes = result);
    } catch (e, st) {
      debugPrint('stamp thumbnail load failed: $e\n$st');
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    final border = widget.isPending ? Border.all(color: Theme.of(context).colorScheme.primary, width: 2) : null;
    return Semantics(
      label: widget.stamp.name,
      button: true,
      child: Tooltip(
        message: widget.stamp.name,
        child: InkWell(
          onTap: widget.onTap,
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(border: border, borderRadius: BorderRadius.circular(4)),
            padding: const EdgeInsets.all(4),
            child: bytes == null
                ? const SizedBox.shrink()
                : Center(
                    // Aspect-fit the builder's displaySize into the
                    // 40×40 inner area so thumbnails show the stamp
                    // in its natural proportions (page-level rendering
                    // keeps using BoxFit.fill so edge-resize stretches
                    // the image — the library never stretches).
                    child: widget.stampImageBuilder(
                      context,
                      bytes,
                      widget.stamp.contentType,
                      _aspectFit(widget.stamp.intrinsicSize, 40),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// Scales [intrinsic] so its longest side equals [longestSide] while
/// preserving aspect. Falls back to a square of [longestSide] when the
/// intrinsic is degenerate (zero or negative).
Size _aspectFit(Size intrinsic, double longestSide) {
  if (intrinsic.width <= 0 || intrinsic.height <= 0) {
    return Size(longestSide, longestSide);
  }
  if (intrinsic.width >= intrinsic.height) {
    final h = longestSide * intrinsic.height / intrinsic.width;
    return Size(longestSide, h);
  }
  final w = longestSide * intrinsic.width / intrinsic.height;
  return Size(w, longestSide);
}
