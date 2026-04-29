/// Persistence backend for per-document annotations.
///
/// `MainPage` talks to this interface only; concrete implementations
/// pick the appropriate medium for their host platform — files on
/// native (see `annotation_storage_file.dart`), in-memory on web.
abstract class AnnotationStorage {
  /// Returns the saved annotations JSON for [key], or `null` if none
  /// has been written yet.
  Future<String?> read(String key);

  /// Persists [json] for [key], overwriting any prior content.
  Future<void> write(String key, String json);

  /// Removes any saved annotations for [key]. No-op when there are none.
  Future<void> delete(String key);
}

/// In-memory [AnnotationStorage] used on the web. Annotations are kept
/// only for the current page session — a hard reload starts from a
/// clean slate. Good enough to demo the flow without depending on
/// `dart:io` or a browser-storage package.
class InMemoryAnnotationStorage implements AnnotationStorage {
  final Map<String, String> _store = <String, String>{};

  @override
  Future<String?> read(String key) async => _store[key];

  @override
  Future<void> write(String key, String json) async {
    _store[key] = json;
  }

  @override
  Future<void> delete(String key) async {
    _store.remove(key);
  }
}
