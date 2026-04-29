import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

/// Friendly display titles for known music-notation categories. Falls
/// back to the directory id with underscores → spaces, capitalized,
/// when the id isn't in this map.
const Map<String, String> _kFriendlyCategoryTitles = {
  'dynamics': 'Dynamics',
  'keys': 'Keys',
  'notes': 'Notes',
  'ornaments': 'Ornaments',
  'repetition': 'Repetition',
  'silence': 'Silences',
  'time_signatures': 'Time signatures',
};

final RegExp _kAssetPattern = RegExp(r'^assets/music_stamps/([^/]+)/([^/]+)\.svg$');
final RegExp _kSortPrefix = RegExp(r'^\d+_');

/// Scan [bundle]'s `AssetManifest` for `assets/music_stamps/<category>/<file>.svg`
/// entries and group them into [PdfViewerStampCategory] objects.
///
/// Categories are returned sorted by `id` ascending; stamps within each
/// category are returned sorted by `id` ascending. Display names strip
/// any leading `\d+_` sort prefix; ids preserve it.
Future<List<PdfViewerStampCategory>> loadStampLibrary({AssetBundle? bundle}) async {
  final assetBundle = bundle ?? rootBundle;
  final manifest = await AssetManifest.loadFromAssetBundle(assetBundle);
  final assets = manifest.listAssets();

  final groups = <String, List<PdfStampDefinition>>{};
  for (final assetKey in assets) {
    final match = _kAssetPattern.firstMatch(assetKey);
    if (match == null) continue;
    final categoryId = match.group(1)!;
    final stampId = match.group(2)!;
    final displayName = _displayNameForStampId(stampId);
    final stamp = PdfStampDefinition(
      id: stampId,
      name: displayName,
      contentType: 'image/svg+xml',
      bytesLoader: () => _loadAssetBytes(assetBundle, assetKey),
      intrinsicSize: const Size(24, 24),
    );
    groups.putIfAbsent(categoryId, () => []).add(stamp);
  }

  final categories = <PdfViewerStampCategory>[];
  final sortedIds = groups.keys.toList()..sort();
  for (final id in sortedIds) {
    final stamps = groups[id]!..sort((a, b) => a.id.compareTo(b.id));
    categories.add(PdfViewerStampCategory(id: id, title: friendlyCategoryTitle(id), stamps: stamps));
  }
  return categories;
}

/// Resolve [categoryId] to its display title using [_kFriendlyCategoryTitles].
/// Falls back to capitalized-with-spaces form for unknown ids.
String friendlyCategoryTitle(String categoryId) {
  final mapped = _kFriendlyCategoryTitles[categoryId];
  if (mapped != null) return mapped;
  if (categoryId.isEmpty) return categoryId;
  final words = categoryId.replaceAll('_', ' ');
  return words[0].toUpperCase() + words.substring(1);
}

/// Strip `^\d+_` from a stamp id and turn underscores into spaces, then
/// capitalize the first letter.
String _displayNameForStampId(String stampId) {
  final stripped = stampId.replaceFirst(_kSortPrefix, '');
  final words = stripped.replaceAll('_', ' ');
  if (words.isEmpty) return stampId;
  return words[0].toUpperCase() + words.substring(1);
}

Future<Uint8List> _loadAssetBytes(AssetBundle bundle, String key) async {
  final data = await bundle.load(key);
  return data.buffer.asUint8List();
}
