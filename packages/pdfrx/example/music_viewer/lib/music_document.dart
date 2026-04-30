import 'package:pdfrx/pdfrx.dart';

/// One entry in the music viewer carousel.
///
/// Decouples `MainPage` from how the underlying PDF is sourced (file,
/// asset, network, …) and from how annotations are keyed for storage.
/// The native entry point builds documents backed by [PdfDocumentRefFile];
/// the web entry point builds documents backed by [PdfDocumentRefAsset].
class MusicDocument {
  const MusicDocument({
    required this.storageKey,
    required this.displayName,
    required this.refBuilder,
  });

  /// Stable identifier the annotation storage uses to persist
  /// annotations for this document. Must be unique across the carousel
  /// and stable across launches (so saved annotations survive).
  final String storageKey;

  /// Human-readable name of the document. Currently unused by the
  /// viewer chrome but kept for future UI (file picker, breadcrumbs, …).
  final String displayName;

  /// Builds a fresh [PdfDocumentRef]. Called every time the user
  /// switches to this document.
  final PdfDocumentRef Function({bool useProgressiveLoading}) refBuilder;
}
