import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_viewer/annotation_storage.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('annot_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('writeAnnotations then readAnnotations round-trips JSON', () async {
    const path = '/some/absolute/path/score.pdf';
    const json = '{"format":"https://pspdfkit.com/instant-json/v1","annotations":[]}';

    await writeAnnotations(path, json, overrideTempDir: tempDir);
    final loaded = await readAnnotations(path, overrideTempDir: tempDir);

    expect(loaded, equals(json));
  });

  test('readAnnotations returns null for a path that has never been written', () async {
    final loaded = await readAnnotations(
      '/never/written/score.pdf',
      overrideTempDir: tempDir,
    );

    expect(loaded, isNull);
  });

  test('writeAnnotations overwrites prior content', () async {
    const path = '/some/absolute/path/score.pdf';

    await writeAnnotations(path, 'first', overrideTempDir: tempDir);
    await writeAnnotations(path, 'second', overrideTempDir: tempDir);
    final loaded = await readAnnotations(path, overrideTempDir: tempDir);

    expect(loaded, equals('second'));
  });

  test('SHA-1-keyed filename: same path produces same file, different paths produce different files', () async {
    const pathA = '/docs/score-a.pdf';
    const pathB = '/docs/score-b.pdf';

    await writeAnnotations(pathA, 'A1', overrideTempDir: tempDir);
    await writeAnnotations(pathA, 'A2', overrideTempDir: tempDir);
    await writeAnnotations(pathB, 'B1', overrideTempDir: tempDir);

    final files = Directory('${tempDir.path}/pdfrx_annotations').listSync().whereType<File>().toList();
    expect(files.length, 2);

    expect(await readAnnotations(pathA, overrideTempDir: tempDir), 'A2');
    expect(await readAnnotations(pathB, overrideTempDir: tempDir), 'B1');
  });
}
