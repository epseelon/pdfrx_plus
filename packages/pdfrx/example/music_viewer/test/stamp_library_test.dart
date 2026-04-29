import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_viewer/stamp_library.dart';

class _FakeAssetBundle extends CachingAssetBundle {
  _FakeAssetBundle(this._assets);

  final Map<String, Uint8List> _assets;

  @override
  Future<ByteData> load(String key) async {
    if (key == 'AssetManifest.bin') {
      // Encode the manifest using StandardMessageCodec so
      // AssetManifest.loadFromAssetBundle can deserialize it.
      final entries = <String, List<dynamic>>{
        for (final assetKey in _assets.keys) assetKey: const [],
      };
      final encoded = const StandardMessageCodec().encodeMessage(entries);
      if (encoded == null) throw FlutterError('Failed to encode fake AssetManifest.bin');
      return encoded;
    }
    if (key == 'AssetManifest.json') {
      final entries = <String, List<dynamic>>{
        for (final assetKey in _assets.keys) assetKey: const [],
      };
      final json = utf8.encode(jsonEncode(entries));
      return ByteData.view(Uint8List.fromList(json).buffer);
    }
    final bytes = _assets[key];
    if (bytes == null) throw FlutterError('Fake bundle missing asset: $key');
    return ByteData.view(bytes.buffer);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loadStampLibrary groups by category, sorts by id, defaults intrinsic to 24×24', () async {
    final bundle = _FakeAssetBundle({
      'assets/music_stamps/notes/sharp.svg': Uint8List.fromList(utf8.encode('<svg>S</svg>')),
      'assets/music_stamps/notes/flat.svg': Uint8List.fromList(utf8.encode('<svg>F</svg>')),
      'assets/music_stamps/dynamics/01_pianississimo.svg': Uint8List.fromList(utf8.encode('<svg>P</svg>')),
      'assets/other/ignored.svg': Uint8List.fromList(utf8.encode('ignored')),
    });

    final categories = await loadStampLibrary(bundle: bundle);

    expect(categories.map((c) => c.id), ['dynamics', 'notes']);
    final dynamics = categories[0];
    expect(dynamics.title, 'Dynamics');
    expect(dynamics.stamps.map((s) => s.id), ['01_pianississimo']);
    expect(dynamics.stamps.single.intrinsicSize.width, 24);
    expect(dynamics.stamps.single.intrinsicSize.height, 24);

    final notes = categories[1];
    expect(notes.title, 'Notes');
    expect(notes.stamps.map((s) => s.id), ['flat', 'sharp']);
  });

  test('friendlyCategoryTitle: known map wins; unknown falls back to capitalized + underscores→spaces', () {
    expect(friendlyCategoryTitle('notes'), 'Notes');
    expect(friendlyCategoryTitle('time_signatures'), 'Time signatures');
    expect(friendlyCategoryTitle('unknown_cat'), 'Unknown cat');
  });

  test('display name strips ^\\d+_ from id while preserving the id itself', () async {
    final bundle = _FakeAssetBundle({
      'assets/music_stamps/dynamics/01_pianississimo.svg': Uint8List.fromList(utf8.encode('<svg/>')),
    });
    final categories = await loadStampLibrary(bundle: bundle);
    final stamp = categories.single.stamps.single;
    expect(stamp.id, '01_pianississimo');
    expect(stamp.name, 'Pianississimo');
  });

  test('bytesLoader returns the bundle bytes for the matching asset key', () async {
    final bytes = Uint8List.fromList(utf8.encode('<svg>X</svg>'));
    final bundle = _FakeAssetBundle({'assets/music_stamps/notes/sharp.svg': bytes});
    final categories = await loadStampLibrary(bundle: bundle);
    final loaded = await categories.single.stamps.single.bytesLoader();
    expect(loaded, bytes);
  });
}
