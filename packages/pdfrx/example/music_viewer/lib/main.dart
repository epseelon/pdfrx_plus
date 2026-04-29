import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'annotation_storage.dart';
import 'app.dart';
import 'music_document.dart';
// `kIsWeb` picks the runtime branch; the conditional import keeps the
// `dart:io`/`path_provider` code out of the JS bundle so the web build
// still compiles. Both files expose the same `prepareNativeSetup` and
// re-export the same `NativeSetup` type.
import 'native_setup.dart' if (dart.library.io) 'native_setup_io.dart';

const _bundledPdfs = ['01.pdf', '02.pdf', '03.pdf'];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final List<MusicDocument> documents;
  final AnnotationStorage storage;
  if (kIsWeb) {
    documents = [
      for (final name in _bundledPdfs)
        MusicDocument(
          storageKey: 'asset:$name',
          displayName: name,
          refBuilder: ({useProgressiveLoading = true}) =>
              PdfDocumentRefAsset('assets/$name', useProgressiveLoading: useProgressiveLoading),
        ),
    ];
    storage = InMemoryAnnotationStorage();
  } else {
    final setup = await prepareNativeSetup(bundledPdfs: _bundledPdfs);
    documents = setup.documents;
    storage = setup.storage;
  }
  runApp(MusicViewerApp(documents: documents, annotationStorage: storage));
}
