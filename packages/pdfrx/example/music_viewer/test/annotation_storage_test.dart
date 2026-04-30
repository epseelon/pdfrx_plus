import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_viewer/annotation_storage_file.dart';

void main() {
  late Directory tempDir;
  late FileAnnotationStorage storage;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('annot_test_');
    storage = FileAnnotationStorage(overrideRootDir: tempDir);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('write then read round-trips JSON', () async {
    const path = '/some/absolute/path/score.pdf';
    const json = '{"format":"https://pspdfkit.com/instant-json/v1","annotations":[]}';

    await storage.write(path, json);
    final loaded = await storage.read(path);

    expect(loaded, equals(json));
  });

  test('read returns null for a path that has never been written', () async {
    final loaded = await storage.read('/never/written/score.pdf');

    expect(loaded, isNull);
  });

  test('write overwrites prior content', () async {
    const path = '/some/absolute/path/score.pdf';

    await storage.write(path, 'first');
    await storage.write(path, 'second');
    final loaded = await storage.read(path);

    expect(loaded, equals('second'));
  });

  test('delete after write removes the file', () async {
    const path = '/some/absolute/path/score.pdf';
    await storage.write(path, '{}');

    await storage.delete(path);

    expect(await storage.read(path), isNull);
    final files = Directory('${tempDir.path}/pdfrx_annotations').listSync().whereType<File>().toList();
    expect(files, isEmpty);
  });

  test('delete on a path that has never been written is a no-op', () async {
    await storage.delete('/never/written/score.pdf');
    expect(await storage.read('/never/written/score.pdf'), isNull);
  });

  test('SHA-1-keyed filename: same path produces same file, different paths produce different files', () async {
    const pathA = '/docs/score-a.pdf';
    const pathB = '/docs/score-b.pdf';

    await storage.write(pathA, 'A1');
    await storage.write(pathA, 'A2');
    await storage.write(pathB, 'B1');

    final files = Directory('${tempDir.path}/pdfrx_annotations').listSync().whereType<File>().toList();
    expect(files.length, 2);

    expect(await storage.read(pathA), 'A2');
    expect(await storage.read(pathB), 'B1');
  });
}
