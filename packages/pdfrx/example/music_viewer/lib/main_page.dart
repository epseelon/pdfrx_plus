import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';

import 'annotation_storage.dart';
import 'horizontal_facing_pages_layout.dart';

class MainPage extends StatefulWidget {
  const MainPage({required this.pdfFilePaths, super.key});

  final List<String> pdfFilePaths;

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final documentRef = ValueNotifier<PdfDocumentRef?>(null);
  final controller = PdfViewerController();
  final _currentPage = ValueNotifier<int>(1);

  final String _creatorName = 'alice';

  int? _fileIndex;
  bool _twoPageMode = true;
  bool _gotoLastOnReady = false;

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
  }

  @override
  void dispose() {
    _magnifierAnimController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    documentRef.dispose();
    _currentPage.dispose();
    super.dispose();
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
                  duration: Duration(milliseconds: 500),
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
                  layoutPages: _twoPageMode ? _layoutTwoPages : _layoutSinglePage,
                  customizeContextMenuItems: (params, items) {},
                  viewerOverlayBuilder: (context, size, handleLinkTap) => [
                    ValueListenableBuilder<bool>(
                      valueListenable: controller.annotationModeListenable,
                      builder: (context, annotating, _) {
                        if (annotating) return const SizedBox.shrink();
                        return Positioned.fill(
                          child: Row(
                            children: [
                              Expanded(
                                child: GestureDetector(
                                  behavior: HitTestBehavior.translucent,
                                  onTapDown: (_) => _prev(),
                                ),
                              ),
                              Expanded(
                                child: GestureDetector(
                                  behavior: HitTestBehavior.translucent,
                                  onTapDown: (_) => _next(),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
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
              return Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Material(
                  elevation: 8,
                  color: Theme.of(context).colorScheme.surface,
                  child: SafeArea(
                    top: false,
                    child: SizedBox(
                      height: 56,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          ValueListenableBuilder<PdfAnnotationTool>(
                            valueListenable: controller.annotationToolListenable,
                            builder: (context, tool, _) {
                              final eraserOn = tool == PdfAnnotationTool.eraser;
                              return IconButton(
                                tooltip: eraserOn ? 'Pen' : 'Eraser',
                                icon: Icon(eraserOn ? Icons.edit : Icons.cleaning_services),
                                onPressed: () => controller.setAnnotationTool(
                                  eraserOn ? PdfAnnotationTool.pen : PdfAnnotationTool.eraser,
                                ),
                              );
                            },
                          ),
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
                  ),
                ),
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
