import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

/// Vertically-scrollable picker UI rendering one section per
/// [PdfViewerStampCategory]. Tapping a thumbnail arms the
/// corresponding stamp via [PdfViewerController.setPendingStamp]; the
/// armed thumbnail shows a 2 px primary-coloured border so the user can
/// see what's currently active.
///
/// Categories are sorted by `id` ascending; stamps within each category
/// are sorted by `id` ascending — the picker never mutates the input
/// lists. Each thumbnail carries a stable `Key('stampThumb:$catId/$stampId')`
/// for tests to drive.
class StampPickerPanel extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final sortedCategories = [...categories]..sort((a, b) => a.id.compareTo(b.id));
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320, maxHeight: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(8),
          child: ValueListenableBuilder<PdfStampDefinition?>(
            valueListenable: controller.pendingStampListenable,
            builder: (context, pending, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final category in sortedCategories)
                  _StampCategorySection(
                    category: category,
                    pending: pending,
                    onTap: controller.setPendingStamp,
                    stampImageBuilder: stampImageBuilder,
                  ),
              ],
            ),
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
                  onTap: () => onTap(stamp),
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
                : widget.stampImageBuilder(context, bytes, widget.stamp.contentType, const Size(40, 40)),
          ),
        ),
      ),
    );
  }
}
