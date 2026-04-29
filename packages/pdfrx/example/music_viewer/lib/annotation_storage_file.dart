import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'annotation_storage.dart';

const _annotationsSubdir = 'pdfrx_annotations';

/// File-backed [AnnotationStorage] used on native platforms.
///
/// Each document's annotations live in a file named after the hex SHA-1
/// of its `AnnotationStorage` key, under
/// `<appDocumentsDir>/pdfrx_annotations/`. Pass `overrideRootDir` in
/// tests; production code falls back to
/// [getApplicationDocumentsDirectory] so annotations survive across
/// app launches and OS-level temp cleanup.
class FileAnnotationStorage implements AnnotationStorage {
  FileAnnotationStorage({Directory? overrideRootDir}) : _overrideRootDir = overrideRootDir;

  final Directory? _overrideRootDir;

  Future<File> _fileFor(String key) async {
    final rootDir = _overrideRootDir ?? await getApplicationDocumentsDirectory();
    final dir = Directory('${rootDir.path}/$_annotationsSubdir');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final hash = sha1.convert(utf8.encode(key)).toString();
    return File('${dir.path}/$hash.json');
  }

  @override
  Future<String?> read(String key) async {
    try {
      final file = await _fileFor(key);
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (e, st) {
      debugPrint('readAnnotations failed for $key: $e\n$st');
      return null;
    }
  }

  @override
  Future<void> write(String key, String json) async {
    try {
      final file = await _fileFor(key);
      await file.writeAsString(json);
      debugPrint('writeAnnotations succeeded in ${file.absolute}');
    } catch (e, st) {
      debugPrint('writeAnnotations failed for $key: $e\n$st');
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      final file = await _fileFor(key);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e, st) {
      debugPrint('deleteAnnotations failed for $key: $e\n$st');
    }
  }
}
