import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';

import 'annotation_storage.dart';
import 'draggable_panel.dart';
import 'horizontal_facing_pages_layout.dart';
import 'stamp_image_builder.dart';

class MainPage extends StatefulWidget {
  const MainPage({required this.pdfFilePaths, super.key});

  final List<String> pdfFilePaths;

  @override
  State<MainPage> createState() => _MainPageState();
}

/// Undo/Redo button pair in the annotation toolbar. Stable selectors are
/// the tooltip strings `'Undo'` and `'Redo'` — keep these in sync with
/// the toolbar widget test.
class AnnotationUndoRedoButtons extends StatelessWidget {
  const AnnotationUndoRedoButtons({
    required this.canUndoListenable,
    required this.canRedoListenable,
    required this.onUndo,
    required this.onRedo,
    super.key,
  });

  final ValueListenable<bool> canUndoListenable;
  final ValueListenable<bool> canRedoListenable;
  final VoidCallback onUndo;
  final VoidCallback onRedo;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ValueListenableBuilder<bool>(
          valueListenable: canUndoListenable,
          builder: (context, canUndo, _) => IconButton(
            tooltip: 'Undo',
            icon: const Icon(Icons.undo),
            onPressed: canUndo ? onUndo : null,
          ),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: canRedoListenable,
          builder: (context, canRedo, _) => IconButton(
            tooltip: 'Redo',
            icon: const Icon(Icons.redo),
            onPressed: canRedo ? onRedo : null,
          ),
        ),
      ],
    );
  }
}

/// Pen / Highlighter / Eraser / (optional) Stamp tool selector row.
/// Stable selectors are the tooltip strings `'Pen'`, `'Highlighter'`,
/// `'Eraser'`, and `'Stamp'` — keep these in sync with the toolbar
/// widget test. The Stamp button is rendered only when [stampAvailable]
/// is `true` (i.e. the host configured a non-empty stamp library).
class AnnotationToolButtons extends StatelessWidget {
  const AnnotationToolButtons({
    required this.toolListenable,
    required this.onSelectTool,
    this.stampAvailable = false,
    super.key,
  });

  final ValueListenable<PdfAnnotationTool> toolListenable;
  final ValueChanged<PdfAnnotationTool> onSelectTool;
  final bool stampAvailable;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PdfAnnotationTool>(
      valueListenable: toolListenable,
      builder: (context, tool, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton.filledTonal(
            tooltip: 'Pen',
            isSelected: tool == PdfAnnotationTool.pen,
            selectedIcon: const Icon(Icons.edit),
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => onSelectTool(PdfAnnotationTool.pen),
          ),
          IconButton.filledTonal(
            tooltip: 'Highlighter',
            isSelected: tool == PdfAnnotationTool.highlighter,
            selectedIcon: const Icon(Icons.highlight),
            icon: const Icon(Icons.highlight_outlined),
            onPressed: () => onSelectTool(PdfAnnotationTool.highlighter),
          ),
          IconButton.filledTonal(
            tooltip: 'Eraser',
            isSelected: tool == PdfAnnotationTool.eraser,
            selectedIcon: const Icon(Icons.cleaning_services),
            icon: const Icon(Icons.cleaning_services_outlined),
            onPressed: () => onSelectTool(PdfAnnotationTool.eraser),
          ),
          if (stampAvailable)
            IconButton.filledTonal(
              tooltip: 'Stamp',
              isSelected: tool == PdfAnnotationTool.stamp,
              selectedIcon: const Icon(Icons.bookmark),
              icon: const Icon(Icons.bookmark_border),
              onPressed: () => onSelectTool(PdfAnnotationTool.stamp),
            ),
        ],
      ),
    );
  }
}

/// The pair of popup buttons (color + thickness, or eraser-radius) shown
/// in the annotation toolbar. The contents change with [tool]:
///
/// * [PdfAnnotationTool.pen] — pen color popup + pen thickness popup
///   (tooltips `'Color'` / `'Pen thickness'`).
/// * [PdfAnnotationTool.highlighter] — highlighter color popup +
///   highlighter thickness popup (tooltips `'Highlighter color'` /
///   `'Highlighter thickness'`).
/// * [PdfAnnotationTool.eraser] — eraser-size popup only
///   (tooltip `'Eraser size'`).
///
/// Tooltips are stable selectors used by the toolbar widget test.
class AnnotationStylePopups extends StatelessWidget {
  const AnnotationStylePopups({
    required this.controller,
    required this.tool,
    this.onToggleStampPicker,
    this.stampPickerOpenListenable,
    super.key,
  });

  final PdfViewerController controller;
  final PdfAnnotationTool tool;

  /// Toggles the stamp picker visibility. Required when [tool] can be
  /// [PdfAnnotationTool.stamp]; ignored otherwise.
  final VoidCallback? onToggleStampPicker;

  /// Optional listenable surfacing the picker's open state so the
  /// toggle button can show its selected variant.
  final ValueListenable<bool>? stampPickerOpenListenable;

  @override
  Widget build(BuildContext context) {
    switch (tool) {
      case PdfAnnotationTool.pen:
      case PdfAnnotationTool.highlighter:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ColorPopup(controller: controller, tool: tool),
            _ThicknessPopup(controller: controller, tool: tool),
          ],
        );
      case PdfAnnotationTool.eraser:
        return _ThicknessPopup(controller: controller, tool: tool);
      case PdfAnnotationTool.stamp:
        final pickerListenable = stampPickerOpenListenable;
        if (pickerListenable == null) {
          return IconButton(
            tooltip: 'Stamp library',
            icon: const Icon(Icons.image_outlined),
            onPressed: onToggleStampPicker,
          );
        }
        return ValueListenableBuilder<bool>(
          valueListenable: pickerListenable,
          builder: (context, open, _) => IconButton.filledTonal(
            tooltip: 'Stamp library',
            isSelected: open,
            selectedIcon: const Icon(Icons.image),
            icon: const Icon(Icons.image_outlined),
            onPressed: onToggleStampPicker,
          ),
        );
    }
  }
}

class _ColorPopup extends StatelessWidget {
  const _ColorPopup({required this.controller, required this.tool});

  final PdfViewerController controller;
  final PdfAnnotationTool tool;

  static const _penPalette = <Color>[
    Color(0xFFFF3B30),
    Color(0xFF000000),
    Color(0xFF007AFF),
    Color(0xFF34C759),
    Color(0xFFFF9500),
    Color(0xFFAF52DE),
  ];
  static const _highlighterPalette = <Color>[
    Color(0xFFFFFF00),
    Color(0xFF00FF00),
    Color(0xFFFF69B4),
    Color(0xFFFFA500),
    Color(0xFF00BFFF),
  ];

  @override
  Widget build(BuildContext context) {
    final isHighlighter = tool == PdfAnnotationTool.highlighter;
    final listenable = isHighlighter
        ? controller.annotationHighlighterColorListenable
        : controller.annotationStrokeColorListenable;
    final ValueChanged<Color> onSelected = isHighlighter
        ? controller.setAnnotationHighlighterColor
        : controller.setAnnotationStrokeColor;
    final palette = isHighlighter ? _highlighterPalette : _penPalette;
    final tooltip = isHighlighter ? 'Highlighter color' : 'Color';
    return ValueListenableBuilder<Color>(
      valueListenable: listenable,
      builder: (context, current, _) => PopupMenuButton<Color>(
        tooltip: tooltip,
        icon: Icon(Icons.circle, color: current),
        onSelected: onSelected,
        itemBuilder: (context) => [
          for (final c in palette)
            CheckedPopupMenuItem<Color>(
              value: c,
              checked: c == current,
              child: Row(
                children: [
                  Icon(Icons.circle, color: c, size: 20),
                  const SizedBox(width: 8),
                  Text(_colorLabel(c)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _colorLabel(Color c) {
    if (c == const Color(0xFFFF3B30)) return 'Red';
    if (c == const Color(0xFF000000)) return 'Black';
    if (c == const Color(0xFF007AFF)) return 'Blue';
    if (c == const Color(0xFF34C759)) return 'Green';
    if (c == const Color(0xFFFF9500)) return 'Orange';
    if (c == const Color(0xFFAF52DE)) return 'Purple';
    if (c == const Color(0xFFFFFF00)) return 'Yellow';
    if (c == const Color(0xFF00FF00)) return 'Green';
    if (c == const Color(0xFFFF69B4)) return 'Pink';
    if (c == const Color(0xFFFFA500)) return 'Orange';
    if (c == const Color(0xFF00BFFF)) return 'Blue';
    return 'Custom';
  }
}

class _ThicknessPopup extends StatelessWidget {
  const _ThicknessPopup({required this.controller, required this.tool});

  final PdfViewerController controller;
  final PdfAnnotationTool tool;

  static const _penThicknesses = <double>[1.0, 2.0, 3.0, 5.0, 8.0];
  static const _highlighterThicknesses = <double>[8.0, 12.0, 16.0, 24.0];
  static const _eraserSizes = <double>[5.0, 10.0, 20.0, 40.0];

  @override
  Widget build(BuildContext context) {
    switch (tool) {
      case PdfAnnotationTool.pen:
        return ValueListenableBuilder<Color>(
          valueListenable: controller.annotationStrokeColorListenable,
          builder: (context, color, _) => ValueListenableBuilder<double>(
            valueListenable: controller.annotationStrokeWidthListenable,
            builder: (context, current, _) => PopupMenuButton<double>(
              tooltip: 'Pen thickness',
              icon: _strokePreview(current, color, width: 22),
              onSelected: controller.setAnnotationStrokeWidth,
              itemBuilder: (context) => [
                for (final w in _penThicknesses)
                  CheckedPopupMenuItem<double>(
                    value: w,
                    checked: w == current,
                    child: Row(
                      children: [
                        _strokePreview(w, color),
                        const SizedBox(width: 12),
                        Text('${w.toStringAsFixed(1)} pt'),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      case PdfAnnotationTool.highlighter:
        return ValueListenableBuilder<Color>(
          valueListenable: controller.annotationHighlighterColorListenable,
          builder: (context, color, _) => ValueListenableBuilder<double>(
            valueListenable: controller.annotationHighlighterWidthListenable,
            builder: (context, current, _) => PopupMenuButton<double>(
              tooltip: 'Highlighter thickness',
              icon: _strokePreview(current.clamp(0.0, 24.0), color, width: 22, opacity: 0.35),
              onSelected: controller.setAnnotationHighlighterWidth,
              itemBuilder: (context) => [
                for (final w in _highlighterThicknesses)
                  CheckedPopupMenuItem<double>(
                    value: w,
                    checked: w == current,
                    child: Row(
                      children: [
                        _strokePreview(w, color, opacity: 0.35),
                        const SizedBox(width: 12),
                        Text('${w.toStringAsFixed(1)} pt'),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      case PdfAnnotationTool.stamp:
        // The stamp tool's style row is rendered by AnnotationStylePopups
        // directly (a single picker-toggle button). _ThicknessPopup is
        // not invoked for stamps; return an empty widget defensively in
        // case a host wires it incorrectly.
        return const SizedBox.shrink();
      case PdfAnnotationTool.eraser:
        final borderColor = Theme.of(context).colorScheme.onSurface;
        return ValueListenableBuilder<double>(
          valueListenable: controller.annotationEraserRadiusListenable,
          builder: (context, current, _) => PopupMenuButton<double>(
            tooltip: 'Eraser size',
            icon: _eraserPreview(current.clamp(4, 22), borderColor, box: 22),
            onSelected: controller.setAnnotationEraserRadius,
            itemBuilder: (context) => [
              for (final r in _eraserSizes)
                CheckedPopupMenuItem<double>(
                  value: r,
                  checked: r == current,
                  child: Row(
                    children: [
                      _eraserPreview(r, borderColor),
                      const SizedBox(width: 12),
                      Text('${r.toStringAsFixed(0)} pt'),
                    ],
                  ),
                ),
            ],
          ),
        );
    }
  }

  Widget _strokePreview(double thickness, Color color, {double width = 60, double opacity = 1.0}) => SizedBox(
    width: width,
    height: 12,
    child: Center(
      child: Container(
        width: width,
        height: thickness,
        decoration: BoxDecoration(
          color: color.withValues(alpha: opacity),
          borderRadius: BorderRadius.circular(thickness / 2),
        ),
      ),
    ),
  );

  Widget _eraserPreview(double size, Color borderColor, {double box = 48}) {
    final diameter = size.clamp(0, box);
    return SizedBox(
      width: box,
      height: box,
      child: Center(
        child: Container(
          width: diameter.toDouble(),
          height: diameter.toDouble(),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: borderColor, width: 1.5),
          ),
        ),
      ),
    );
  }
}

class _MainPageState extends State<MainPage> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final documentRef = ValueNotifier<PdfDocumentRef?>(null);
  final controller = PdfViewerController();
  final _currentPage = ValueNotifier<int>(1);
  final _pickerOpen = ValueNotifier<bool>(true);

  final String _creatorName = 'alice';

  int? _fileIndex;
  bool _twoPageMode = true;
  bool _gotoLastOnReady = false;

  List<PdfViewerStampCategory>? _stampCategories;

  // Magnifier animation controller
  late final AnimationController _magnifierAnimController = AnimationController(
    duration: const Duration(milliseconds: 250),
    vsync: this,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fileIndex = 0;
    _openFile(index: _fileIndex);
    _loadStampCategoriesPlaceholder();
  }

  @override
  void dispose() {
    _magnifierAnimController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    documentRef.dispose();
    _currentPage.dispose();
    _pickerOpen.dispose();
    super.dispose();
  }

  // Phase 1 hand-built stamp library: 3 SVG stamps from the music notation
  // assets. Phase 3 replaces this with a full asset-manifest scanner.
  Future<void> _loadStampCategoriesPlaceholder() async {
    Future<Uint8List> load(String path) async {
      final bd = await rootBundle.load(path);
      return bd.buffer.asUint8List();
    }

    final categories = [
      PdfViewerStampCategory(
        id: 'notes',
        title: 'Notes',
        stamps: [
          PdfStampDefinition(
            id: 'sharp',
            name: 'Sharp',
            contentType: 'image/svg+xml',
            bytesLoader: () => load('assets/music_stamps/notes/sharp.svg'),
            intrinsicSize: const Size(24, 24),
          ),
          PdfStampDefinition(
            id: 'flat',
            name: 'Flat',
            contentType: 'image/svg+xml',
            bytesLoader: () => load('assets/music_stamps/notes/flat.svg'),
            intrinsicSize: const Size(24, 24),
          ),
          PdfStampDefinition(
            id: 'natural',
            name: 'Natural',
            contentType: 'image/svg+xml',
            bytesLoader: () => load('assets/music_stamps/notes/natural.svg'),
            intrinsicSize: const Size(24, 24),
          ),
        ],
      ),
    ];
    if (!mounted) return;
    setState(() => _stampCategories = categories);
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (mounted) setState(() {});
  }

  Future<void> _openFile({int? index, bool useProgressiveLoading = true}) async {
    if (index == null) {
      documentRef.value = null;
    } else {
      final path = widget.pdfFilePaths[index];
      documentRef.value = PdfDocumentRefFile(path, useProgressiveLoading: useProgressiveLoading);
    }
  }

  void _togglePageMode() {
    setState(() => _twoPageMode = !_twoPageMode);
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.invalidate());
  }

  Widget _buildAnnotationToolbar(DragHandleBuilder dragHandle, PdfAnnotationTool tool) {
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(8),
      child: IntrinsicHeight(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            dragHandle(
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Tooltip(message: 'Drag to move', child: Icon(Icons.drag_indicator)),
              ),
            ),
            AnnotationToolButtons(
              toolListenable: controller.annotationToolListenable,
              onSelectTool: controller.setAnnotationTool,
              stampAvailable: (_stampCategories?.isNotEmpty ?? false),
            ),
            const VerticalDivider(width: 16, thickness: 1, indent: 8, endIndent: 8),
            AnnotationStylePopups(
              controller: controller,
              tool: tool,
              onToggleStampPicker: () => _pickerOpen.value = !_pickerOpen.value,
              stampPickerOpenListenable: _pickerOpen,
            ),
            const VerticalDivider(width: 16, thickness: 1, indent: 8, endIndent: 8),
            AnnotationUndoRedoButtons(
              canUndoListenable: controller.canUndoListenable,
              canRedoListenable: controller.canRedoListenable,
              onUndo: controller.undo,
              onRedo: controller.redo,
            ),
            const VerticalDivider(width: 16, thickness: 1, indent: 8, endIndent: 8),
            IconButton(
              tooltip: 'Reset annotations',
              icon: const Icon(Icons.delete_forever),
              onPressed: _confirmResetAnnotations,
            ),
            IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close),
              onPressed: () => controller.exitAnnotationMode(),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmResetAnnotations() async {
    final idx = _fileIndex;
    if (idx == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset annotations?'),
        content: const Text('Delete all annotations for this document. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    controller.clearAnnotations();
    await deleteAnnotations(widget.pdfFilePaths[idx]);
  }

  int get _step => _twoPageMode ? 2 : 1;

  int _spreadStart(int p) => _twoPageMode && p.isEven ? p - 1 : p;

  int _lastSpreadStart(int pageCount) => _twoPageMode && pageCount.isEven ? pageCount - 1 : pageCount;

  void _switchDocument(int delta, {bool gotoLast = false}) {
    final n = widget.pdfFilePaths.length;
    setState(() {
      _fileIndex = ((_fileIndex! + delta) % n + n) % n;
      _gotoLastOnReady = gotoLast;
      _openFile(index: _fileIndex);
    });
    _currentPage.value = 1;
  }

  void _next() {
    if (!controller.isReady) return;
    final next = _spreadStart(controller.pageNumber ?? 1) + _step;
    if (next > controller.pageCount) {
      _switchDocument(1);
    } else {
      controller.goToPage(pageNumber: next, duration: Duration.zero);
    }
  }

  void _prev() {
    if (!controller.isReady) return;
    final prev = _spreadStart(controller.pageNumber ?? 1) - _step;
    if (prev < 1) {
      _switchDocument(-1, gotoLast: true);
    } else {
      controller.goToPage(pageNumber: prev, duration: Duration.zero);
    }
  }

  Widget _buildPageIndicator() {
    if (!controller.isReady) return const SizedBox.shrink();
    final pageCount = controller.pageCount;
    final spreadCount = _twoPageMode ? (pageCount + 1) ~/ 2 : pageCount;
    if (spreadCount < 2) return const SizedBox.shrink();
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Center(
          child: ValueListenableBuilder<int>(
            valueListenable: _currentPage,
            builder: (context, current, _) {
              final currentSpread = _twoPageMode ? (current - 1) ~/ 2 : current - 1;
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
                  duration: Duration(milliseconds: 0),
                  effect: const ExpandingDotsEffect(
                    dotColor: Colors.white54,
                    activeDotColor: Colors.white,
                    dotHeight: 8,
                    dotWidth: 8,
                    spacing: 8,
                  ),
                  onDotClicked: (i) => controller.goToPage(
                    pageNumber: _twoPageMode ? i * 2 + 1 : i + 1,
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

  PdfPageLayout _layoutSinglePage(List<PdfPage> pages, PdfViewerParams params, PdfLayoutHelper helper) =>
      SequentialPagesLayout.fromPages(
        pages,
        params,
        helper: helper,
        scrollDirection: Axis.horizontal,
      );

  PdfPageLayout _layoutTwoPages(List<PdfPage> pages, PdfViewerParams params, PdfLayoutHelper helper) =>
      HorizontalFacingPagesLayout.fromPages(
        pages,
        params,
        helper: helper,
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          ValueListenableBuilder(
            valueListenable: documentRef,
            builder: (context, docRef, child) {
              if (docRef == null) {
                return const Center(child: CircularProgressIndicator());
              }
              return PdfViewer(
                docRef,
                controller: controller,
                params: PdfViewerParams(
                  keyHandlerParams: PdfViewerKeyHandlerParams(autofocus: true),
                  maxScale: 8,
                  scrollPhysics: PdfViewerParams.getScrollPhysics(context),
                  pageTransition: PageTransition.discrete,
                  stampCategories: _stampCategories,
                  stampImageBuilder: _stampCategories == null ? null : stampImageBuilder,
                  layoutPages: _twoPageMode ? _layoutTwoPages : _layoutSinglePage,
                  customizeContextMenuItems: (params, items) {},
                  onGeneralTap: (context, controller, details) {
                    if (details.type != PdfViewerGeneralTapType.tap) return false;
                    if (controller.annotationModeListenable.value) return false;
                    final width = controller.viewSize.width;
                    if (details.localPosition.dx < width / 2) {
                      _prev();
                    } else {
                      _next();
                    }
                    return true;
                  },
                  viewerOverlayBuilder: (context, size, handleLinkTap) => [
                    ValueListenableBuilder<bool>(
                      valueListenable: controller.annotationModeListenable,
                      builder: (context, annotating, _) {
                        if (annotating) return const SizedBox.shrink();
                        return _buildPageIndicator();
                      },
                    ),
                  ],
                  onPageChanged: (pageNumber) {
                    if (pageNumber != null) _currentPage.value = pageNumber;
                  },
                  loadingBannerBuilder: (context, bytesDownloaded, totalBytes) => Center(
                    child: CircularProgressIndicator(
                      value: totalBytes != null ? bytesDownloaded / totalBytes : null,
                      backgroundColor: Colors.grey,
                    ),
                  ),
                  pagePaintCallbacks: [],
                  onDocumentChanged: (document) async {
                    if (document == null) {}
                  },
                  onAnnotationsChanged: (json) async {
                    final idx = _fileIndex;
                    if (idx == null) return;
                    await writeAnnotations(widget.pdfFilePaths[idx], json);
                  },
                  onViewerReady: (document, controller) async {
                    controller.requestFocus();
                    controller.document.events.listen((event) {});
                    if (_gotoLastOnReady) {
                      _gotoLastOnReady = false;
                      final p = _lastSpreadStart(document.pages.length);
                      _currentPage.value = p;
                      controller.goToPage(pageNumber: p, duration: Duration.zero);
                    } else {
                      _currentPage.value = controller.pageNumber ?? 1;
                    }
                    final idx = _fileIndex;
                    if (idx != null) {
                      try {
                        final json = await readAnnotations(widget.pdfFilePaths[idx]);
                        if (json != null) controller.applyAnnotationsFromJson(json);
                      } catch (e, st) {
                        debugPrint('annotation load failed: $e\n$st');
                      }
                    }
                  },
                ),
              );
            },
          ),
          Positioned(
            bottom: 32,
            left: 32,
            child: ValueListenableBuilder<bool>(
              valueListenable: controller.annotationModeListenable,
              builder: (context, annotating, _) {
                if (annotating) return const SizedBox.shrink();
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FloatingActionButton(
                      heroTag: 'annotate',
                      tooltip: 'Annotate',
                      onPressed: () => controller.enterAnnotationMode(
                        creatorName: _creatorName,
                      ),
                      child: const Icon(Icons.edit),
                    ),
                    const SizedBox(height: 16),
                    FloatingActionButton(
                      heroTag: 'toggleMode',
                      tooltip: _twoPageMode ? 'Switch to single page' : 'Switch to two pages',
                      onPressed: _togglePageMode,
                      child: Icon(_twoPageMode ? Icons.looks_one : Icons.menu_book),
                    ),
                  ],
                );
              },
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: controller.annotationModeListenable,
            builder: (context, annotating, _) {
              if (!annotating) return const SizedBox.shrink();
              return Positioned.fill(
                child: DraggablePanel(
                  builder: (context, dragHandle) => ValueListenableBuilder<PdfAnnotationTool>(
                    valueListenable: controller.annotationToolListenable,
                    builder: (context, tool, _) => _buildAnnotationToolbar(dragHandle, tool),
                  ),
                ),
              );
            },
          ),
          ValueListenableBuilder<bool>(
            valueListenable: controller.annotationModeListenable,
            builder: (context, annotating, _) {
              final categories = _stampCategories;
              if (!annotating || categories == null || categories.isEmpty) {
                return const SizedBox.shrink();
              }
              return ValueListenableBuilder<PdfAnnotationTool>(
                valueListenable: controller.annotationToolListenable,
                builder: (context, tool, _) {
                  if (tool != PdfAnnotationTool.stamp) return const SizedBox.shrink();
                  return ValueListenableBuilder<bool>(
                    valueListenable: _pickerOpen,
                    builder: (context, open, _) {
                      if (!open) return const SizedBox.shrink();
                      return Positioned.fill(
                        child: DraggablePanel(
                          initialOffset: const Offset(16, 16),
                          builder: (context, dragHandle) => _StampPickerPlaceholder(
                            dragHandle: dragHandle,
                            categories: categories,
                            controller: controller,
                          ),
                        ),
                      );
                    },
                  );
                },
              );
            },
          ),
        ],
      ),
      floatingActionButton: ValueListenableBuilder<bool>(
        valueListenable: controller.annotationModeListenable,
        builder: (context, annotating, _) {
          if (annotating) return const SizedBox.shrink();
          return FloatingActionButton(
            heroTag: 'skipNext',
            child: const Icon(Icons.skip_next),
            onPressed: () {
              if (_fileIndex != null) {
                setState(() {
                  _fileIndex = (_fileIndex! + 1) % widget.pdfFilePaths.length;
                  _openFile(index: _fileIndex);
                });
              }
            },
          );
        },
      ),
    );
  }
}

class _StampPickerPlaceholder extends StatelessWidget {
  const _StampPickerPlaceholder({
    required this.dragHandle,
    required this.categories,
    required this.controller,
  });

  final DragHandleBuilder dragHandle;
  final List<PdfViewerStampCategory> categories;
  final PdfViewerController controller;

  @override
  Widget build(BuildContext context) {
    final sortedCats = [...categories]..sort((a, b) => a.id.compareTo(b.id));
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            dragHandle(
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Tooltip(message: 'Drag to move', child: Icon(Icons.drag_indicator)),
              ),
            ),
            for (final cat in sortedCats) _StampCategoryRow(category: cat, controller: controller),
          ],
        ),
      ),
    );
  }
}

class _StampCategoryRow extends StatelessWidget {
  const _StampCategoryRow({required this.category, required this.controller});

  final PdfViewerStampCategory category;
  final PdfViewerController controller;

  @override
  Widget build(BuildContext context) {
    final sortedStamps = [...category.stamps]..sort((a, b) => a.id.compareTo(b.id));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(category.title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          ValueListenableBuilder<PdfStampDefinition?>(
            valueListenable: controller.pendingStampListenable,
            builder: (context, pending, _) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final stamp in sortedStamps)
                  _StampThumbnail(
                    key: Key('stampThumb:${category.id}/${stamp.id}'),
                    stamp: stamp,
                    isPending: identical(pending, stamp),
                    onTap: () => controller.setPendingStamp(stamp),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StampThumbnail extends StatefulWidget {
  const _StampThumbnail({required this.stamp, required this.isPending, required this.onTap, super.key});

  final PdfStampDefinition stamp;
  final bool isPending;
  final VoidCallback onTap;

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
    return Tooltip(
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
              : stampImageBuilder(context, bytes, widget.stamp.contentType, const Size(40, 40)),
        ),
      ),
    );
  }
}
