import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'annotation_storage.dart';
import 'color_popup.dart';
import 'draggable_panel.dart';
import 'eraser_radius_popup.dart';
import 'horizontal_facing_pages_layout.dart';
import 'music_document.dart';
import 'page_indicator.dart';
import 'stamp_image_builder.dart';
import 'stamp_library.dart';
import 'stamp_picker_panel.dart';
import 'stroke_thickness_popup.dart';

class MainPage extends StatefulWidget {
  const MainPage({
    required this.documents,
    required this.annotationStorage,
    super.key,
  });

  /// The carousel of documents the user can swipe between.
  final List<MusicDocument> documents;

  /// Backend the page reads from on document open and writes to on
  /// every annotation change.
  final AnnotationStorage annotationStorage;

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final _documentRef = ValueNotifier<PdfDocumentRef?>(null);
  final _controller = PdfViewerController();
  final _currentPage = ValueNotifier<int>(1);

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
    _loadStamps();
  }

  @override
  void dispose() {
    _magnifierAnimController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _documentRef.dispose();
    _currentPage.dispose();
    super.dispose();
  }

  Future<void> _loadStamps() async {
    try {
      final categories = await loadStampLibrary();
      if (!mounted) return;
      setState(() => _stampCategories = categories);
    } catch (e, st) {
      debugPrint('loadStampLibrary failed: $e\n$st');
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (mounted) setState(() {});
  }

  Future<void> _openFile({int? index, bool useProgressiveLoading = true}) async {
    if (index == null) {
      _documentRef.value = null;
    } else {
      final doc = widget.documents[index];
      _documentRef.value = doc.refBuilder(useProgressiveLoading: useProgressiveLoading);
    }
  }

  void _togglePageMode() {
    setState(() => _twoPageMode = !_twoPageMode);
    WidgetsBinding.instance.addPostFrameCallback((_) => _controller.invalidate());
  }

  Widget _buildAnnotationToolbar(DragHandleBuilder dragHandle, PdfAnnotationTool tool) {
    final stampAvailable = _stampCategories?.isNotEmpty ?? false;
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
                child: Tooltip(
                  message: 'Drag to move',
                  child: Icon(Icons.drag_indicator),
                ),
              ),
            ),
            IconButton.filledTonal(
              tooltip: 'Pen',
              isSelected: tool == PdfAnnotationTool.pen,
              selectedIcon: const Icon(Icons.edit),
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _controller.setAnnotationTool(PdfAnnotationTool.pen),
            ),
            IconButton.filledTonal(
              tooltip: 'Highlighter',
              isSelected: tool == PdfAnnotationTool.highlighter,
              selectedIcon: const Icon(Icons.highlight),
              icon: const Icon(Icons.highlight_outlined),
              onPressed: () => _controller.setAnnotationTool(PdfAnnotationTool.highlighter),
            ),
            IconButton.filledTonal(
              tooltip: 'Eraser',
              isSelected: tool == PdfAnnotationTool.eraser,
              selectedIcon: const Icon(Icons.cleaning_services),
              icon: const Icon(Icons.cleaning_services_outlined),
              onPressed: () => _controller.setAnnotationTool(PdfAnnotationTool.eraser),
            ),
            if (stampAvailable)
              IconButton.filledTonal(
                tooltip: 'Stamp',
                isSelected: tool == PdfAnnotationTool.stamp,
                selectedIcon: const Icon(Icons.approval_rounded),
                icon: const Icon(Icons.approval_outlined),
                onPressed: () => _controller.setAnnotationTool(PdfAnnotationTool.stamp),
              ),
            const VerticalDivider(width: 16, thickness: 1, indent: 8, endIndent: 8),
            switch (tool) {
              PdfAnnotationTool.pen => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ColorPopup(
                    tooltip: 'Color',
                    palette: <ColorPopupEntry>[
                      (color: Color(0xFFFF3B30), label: 'Red'),
                      (color: Color(0xFF000000), label: 'Black'),
                      (color: Color(0xFF007AFF), label: 'Blue'),
                      (color: Color(0xFF34C759), label: 'Green'),
                      (color: Color(0xFFFF9500), label: 'Orange'),
                      (color: Color(0xFFAF52DE), label: 'Purple'),
                    ],
                    valueListenable: _controller.annotationStrokeColorListenable,
                    onSelected: _controller.setAnnotationStrokeColor,
                  ),
                  StrokeThicknessPopup(
                    tooltip: 'Pen thickness',
                    thicknesses: const <double>[1.0, 2.0, 3.0, 5.0, 8.0],
                    widthListenable: _controller.annotationStrokeWidthListenable,
                    colorListenable: _controller.annotationStrokeColorListenable,
                    onSelected: _controller.setAnnotationStrokeWidth,
                  ),
                ],
              ),
              PdfAnnotationTool.highlighter => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ColorPopup(
                    tooltip: 'Highlighter color',
                    palette: <ColorPopupEntry>[
                      (color: Color(0xFFFFFF00), label: 'Yellow'),
                      (color: Color(0xFF00FF00), label: 'Green'),
                      (color: Color(0xFFFF69B4), label: 'Pink'),
                      (color: Color(0xFFFFA500), label: 'Orange'),
                      (color: Color(0xFF00BFFF), label: 'Blue'),
                    ],
                    valueListenable: _controller.annotationHighlighterColorListenable,
                    onSelected: _controller.setAnnotationHighlighterColor,
                  ),
                  StrokeThicknessPopup(
                    tooltip: 'Highlighter thickness',
                    thicknesses: const <double>[8.0, 12.0, 16.0, 24.0],
                    widthListenable: _controller.annotationHighlighterWidthListenable,
                    colorListenable: _controller.annotationHighlighterColorListenable,
                    onSelected: _controller.setAnnotationHighlighterWidth,
                    opacity: 0.35,
                    iconMaxThickness: 24.0,
                  ),
                ],
              ),
              PdfAnnotationTool.eraser => EraserRadiusPopup(
                tooltip: 'Eraser size',
                radii: const <double>[5.0, 10.0, 20.0, 40.0],
                radiusListenable: _controller.annotationEraserRadiusListenable,
                onSelected: _controller.setAnnotationEraserRadius,
              ),
              PdfAnnotationTool.stamp => const SizedBox.shrink(),
              PdfAnnotationTool.hand => const SizedBox.shrink(),
            },
            if (tool != PdfAnnotationTool.stamp)
              const VerticalDivider(width: 16, thickness: 1, indent: 8, endIndent: 8),
            ValueListenableBuilder<bool>(
              valueListenable: _controller.canUndoListenable,
              builder: (context, canUndo, _) => IconButton(
                tooltip: 'Undo',
                icon: const Icon(Icons.undo),
                onPressed: canUndo ? _controller.undo : null,
              ),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: _controller.canRedoListenable,
              builder: (context, canRedo, _) => IconButton(
                tooltip: 'Redo',
                icon: const Icon(Icons.redo),
                onPressed: canRedo ? _controller.redo : null,
              ),
            ),
            const VerticalDivider(width: 16, thickness: 1, indent: 8, endIndent: 8),
            IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close),
              onPressed: () => _controller.exitAnnotationMode(),
            ),
          ],
        ),
      ),
    );
  }

  int get _step => _twoPageMode ? 2 : 1;

  int _spreadStart(int p) => _twoPageMode && p.isEven ? p - 1 : p;

  int _lastSpreadStart(int pageCount) => _twoPageMode && pageCount.isEven ? pageCount - 1 : pageCount;

  void _switchDocument(int delta, {bool gotoLast = false}) {
    final n = widget.documents.length;
    setState(() {
      _fileIndex = ((_fileIndex! + delta) % n + n) % n;
      _gotoLastOnReady = gotoLast;
      _openFile(index: _fileIndex);
    });
    _currentPage.value = 1;
  }

  void _next() {
    if (!_controller.isReady) return;
    final next = _spreadStart(_controller.pageNumber ?? 1) + _step;
    if (next > _controller.pageCount) {
      _switchDocument(1);
    } else {
      _controller.goToPage(pageNumber: next, duration: Duration.zero);
    }
  }

  void _prev() {
    if (!_controller.isReady) return;
    final prev = _spreadStart(_controller.pageNumber ?? 1) - _step;
    if (prev < 1) {
      _switchDocument(-1, gotoLast: true);
    } else {
      _controller.goToPage(pageNumber: prev, duration: Duration.zero);
    }
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
            valueListenable: _documentRef,
            builder: (context, docRef, child) {
              if (docRef == null) {
                return const Center(child: CircularProgressIndicator());
              }
              return PdfViewer(
                docRef,
                controller: _controller,
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
                      valueListenable: _controller.annotationModeListenable,
                      builder: (context, annotating, _) {
                        if (annotating) return const SizedBox.shrink();
                        return PageIndicator(
                          controller: _controller,
                          twoPageMode: _twoPageMode,
                          currentPage: _currentPage,
                        );
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
                    await widget.annotationStorage.write(widget.documents[idx].storageKey, json);
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
                        final json = await widget.annotationStorage.read(widget.documents[idx].storageKey);
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
              valueListenable: _controller.annotationModeListenable,
              builder: (context, annotating, _) {
                if (annotating) return const SizedBox.shrink();
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FloatingActionButton(
                      heroTag: 'annotate',
                      tooltip: 'Annotate',
                      onPressed: () => _controller.enterAnnotationMode(
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
            valueListenable: _controller.annotationModeListenable,
            builder: (context, annotating, _) {
              if (!annotating) return const SizedBox.shrink();
              return Positioned.fill(
                child: DraggablePanel(
                  builder: (context, dragHandle) => ValueListenableBuilder<PdfAnnotationTool>(
                    valueListenable: _controller.annotationToolListenable,
                    builder: (context, tool, _) => _buildAnnotationToolbar(dragHandle, tool),
                  ),
                ),
              );
            },
          ),
          ValueListenableBuilder<bool>(
            valueListenable: _controller.annotationModeListenable,
            builder: (context, annotating, _) {
              final categories = _stampCategories;
              if (!annotating || categories == null || categories.isEmpty) {
                return const SizedBox.shrink();
              }
              return ValueListenableBuilder<PdfAnnotationTool>(
                valueListenable: _controller.annotationToolListenable,
                builder: (context, tool, _) {
                  // Library visibility tracks the active tool: visible
                  // when the user is in stamp mode, hidden otherwise.
                  if (tool != PdfAnnotationTool.stamp) return const SizedBox.shrink();
                  return Positioned.fill(
                    child: DraggablePanel(
                      // iPad-friendly default: dock at the right edge,
                      // vertically centered, so it doesn't overlap the
                      // status-bar clock or window controls in the
                      // top-left corner.
                      initialAlignment: Alignment.centerRight,
                      resizable: true,
                      initialSize: const Size(280, 480),
                      minSize: const Size(220, 260),
                      builder: (context, dragHandle) => Material(
                        elevation: 8,
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(8),
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          mainAxisSize: MainAxisSize.max,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            dragHandle(
                              SizedBox(
                                height: 28,
                                child: Tooltip(
                                  message: 'Drag to move',
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                      spacing: 3,
                                      children: [
                                        Container(
                                          height: 2,
                                          decoration: BoxDecoration(
                                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                                            borderRadius: BorderRadius.circular(1.5),
                                          ),
                                        ),
                                        Container(
                                          height: 2,
                                          decoration: BoxDecoration(
                                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                                            borderRadius: BorderRadius.circular(1.5),
                                          ),
                                        ),
                                        Container(
                                          height: 2,
                                          decoration: BoxDecoration(
                                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                                            borderRadius: BorderRadius.circular(1.5),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const Divider(height: 1, thickness: 1),
                            Expanded(
                              child: StampPickerPanel(
                                controller: _controller,
                                categories: categories,
                                stampImageBuilder: stampImageBuilder,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ],
      ),
      floatingActionButton: ValueListenableBuilder<bool>(
        valueListenable: _controller.annotationModeListenable,
        builder: (context, annotating, _) {
          if (annotating) return const SizedBox.shrink();
          return FloatingActionButton(
            heroTag: 'skipNext',
            child: const Icon(Icons.skip_next),
            onPressed: () {
              if (_fileIndex != null) {
                setState(() {
                  _fileIndex = (_fileIndex! + 1) % widget.documents.length;
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
