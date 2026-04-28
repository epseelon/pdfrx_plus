import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

const _annotationsSubdir = 'pdfrx_annotations';

/// Returns the [File] that stores annotations for the document at
/// [absolutePdfPath].
///
/// The filename is the hex SHA-1 of [absolutePdfPath] suffixed with `.json`,
/// placed under `<tempDir>/pdfrx_annotations/`. Pass [overrideTempDir] in
/// tests; production code falls back to [getTemporaryDirectory].
Future<File> annotationsFileFor(
  String absolutePdfPath, {
  Directory? overrideTempDir,
}) async {
  final tempDir = overrideTempDir ?? await getTemporaryDirectory();
  final dir = Directory('${tempDir.path}/$_annotationsSubdir');
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  final hash = sha1.convert(utf8.encode(absolutePdfPath)).toString();
  return File('${dir.path}/$hash.json');
}

/// Reads the saved annotations JSON for [absolutePdfPath], or `null` if no
/// file exists. I/O failures are caught and logged.
Future<String?> readAnnotations(
  String absolutePdfPath, {
  Directory? overrideTempDir,
}) async {
  try {
    final file = await annotationsFileFor(
      absolutePdfPath,
      overrideTempDir: overrideTempDir,
    );
    if (!await file.exists()) return null;
    return await file.readAsString();
  } catch (e, st) {
    debugPrint('readAnnotations failed for $absolutePdfPath: $e\n$st');
    return null;
  }
}

/// Writes [json] to the annotations file for [absolutePdfPath], overwriting
/// any prior content. I/O failures are caught and logged.
Future<void> writeAnnotations(
  String absolutePdfPath,
  String json, {
  Directory? overrideTempDir,
}) async {
  try {
    final file = await annotationsFileFor(
      absolutePdfPath,
      overrideTempDir: overrideTempDir,
    );
    await file.writeAsString(json);
  } catch (e, st) {
    debugPrint('writeAnnotations failed for $absolutePdfPath: $e\n$st');
  }
}

/// Removes the annotations file for [absolutePdfPath], if any. No-op when
/// no file has been written for that path. I/O failures are caught and
/// logged.
Future<void> deleteAnnotations(
  String absolutePdfPath, {
  Directory? overrideTempDir,
}) async {
  try {
    final file = await annotationsFileFor(
      absolutePdfPath,
      overrideTempDir: overrideTempDir,
    );
    if (await file.exists()) {
      await file.delete();
    }
  } catch (e, st) {
    debugPrint('deleteAnnotations failed for $absolutePdfPath: $e\n$st');
  }
}
