import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

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

  void _toggleMode() {
    setState(() => _twoPageMode = !_twoPageMode);
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.invalidate());
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
                  viewerOverlayBuilder: (context, size, handleLinkTap) => [],
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
                  onViewerReady: (document, controller) async {
                    controller.requestFocus();
                    controller.document.events.listen((event) {});
                    if (_gotoLastOnReady) {
                      _gotoLastOnReady = false;
                      controller.goToPage(pageNumber: _lastSpreadStart(document.pages.length), duration: Duration.zero);
                    }
                  },
                ),
              );
            },
          ),
          Positioned(
            bottom: 32,
            left: 32,
            child: FloatingActionButton(
              tooltip: _twoPageMode ? 'Switch to single page' : 'Switch to two pages',
              onPressed: _toggleMode,
              child: Icon(_twoPageMode ? Icons.looks_one : Icons.menu_book),
            ),
          ),
          Positioned(
            top: 32,
            left: 32,
            child: FloatingActionButton(
              tooltip: 'Previous page',
              onPressed: _prev,
              child: const Icon(Icons.chevron_left),
            ),
          ),
          Positioned(
            top: 32,
            right: 32,
            child: FloatingActionButton(
              tooltip: 'Next page',
              onPressed: _next,
              child: const Icon(Icons.chevron_right),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        child: Icon(Icons.skip_next),
        onPressed: () {
          if (_fileIndex != null) {
            setState(() {
              _fileIndex = (_fileIndex! + 1) % widget.pdfFilePaths.length;
              _openFile(index: _fileIndex);
            });
          }
        },
      ),
    );
  }
}
