import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

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
                  pageTransition: PageTransition.continuous,
                  customizeContextMenuItems: (params, items) {},
                  //pageTransition: PageTransition.discrete,
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
                  },
                ),
              );
            },
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
