import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import 'annotation_storage_file.dart';
import 'music_document.dart';
import 'native_setup.dart';

export 'native_setup.dart' show NativeSetup;

/// Native-side implementation: copies the bundled PDFs out of the asset
/// bundle into the temporary directory once, then exposes them as
/// [PdfDocumentRefFile]s. Annotations land on disk via
/// [FileAnnotationStorage].
Future<NativeSetup> prepareNativeSetup({required List<String> bundledPdfs}) async {
  final tempDir = await getTemporaryDirectory();
  final documents = <MusicDocument>[];
  for (final name in bundledPdfs) {
    final target = File('${tempDir.path}/$name');
    if (target.existsSync()) {
      target.deleteSync();
    }
    final data = await rootBundle.load('assets/$name');
    await target.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    final path = target.path;
    documents.add(
      MusicDocument(
        storageKey: path,
        displayName: name,
        refBuilder: ({useProgressiveLoading = true}) =>
            PdfDocumentRefFile(path, useProgressiveLoading: useProgressiveLoading),
      ),
    );
  }
  return NativeSetup(documents: documents, storage: FileAnnotationStorage());
}
