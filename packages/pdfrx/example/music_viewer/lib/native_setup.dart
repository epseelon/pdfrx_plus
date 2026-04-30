import 'annotation_storage.dart';
import 'music_document.dart';

/// The two halves the entry point needs to wire up the app on a given
/// platform: the carousel of documents and the annotation backend.
class NativeSetup {
  const NativeSetup({required this.documents, required this.storage});

  final List<MusicDocument> documents;
  final AnnotationStorage storage;
}

/// Web-side stub. The web build never calls this — `main()` short-circuits
/// on `kIsWeb` before reaching here — but it exists so the file still
/// compiles to JS without pulling in `dart:io`.
Future<NativeSetup> prepareNativeSetup({required List<String> bundledPdfs}) {
  throw UnsupportedError(
    'prepareNativeSetup is only available on dart:io platforms.',
  );
}
