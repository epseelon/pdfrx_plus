import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'main_page.dart';

const _bundledPdfs = ['01.pdf', '02.pdf', '03.pdf'];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final tempDir = await getTemporaryDirectory();
  final paths = List<String>.of([]);
  for (final name in _bundledPdfs) {
    final target = File('${tempDir.path}/$name');
    if (target.existsSync()) {
      target.deleteSync();
    }
    final data = await rootBundle.load('assets/$name');
    await target.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    paths.add(target.path);
  }
  runApp(MyApp(pdfFilePaths: paths));
}

class MyApp extends StatelessWidget {
  const MyApp({required this.pdfFilePaths, super.key});

  final List<String> pdfFilePaths;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Music Viewer',
      home: MainPage(pdfFilePaths: pdfFilePaths),
    );
  }
}
