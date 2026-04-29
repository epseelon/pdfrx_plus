import 'package:flutter/material.dart';

import 'annotation_storage.dart';
import 'main_page.dart';
import 'music_document.dart';

/// Top-level [MaterialApp] shared by every entry point. Each platform's
/// `main.dart` builds its own list of [MusicDocument]s and picks the
/// matching [AnnotationStorage]; everything else is identical.
class MusicViewerApp extends StatelessWidget {
  const MusicViewerApp({
    required this.documents,
    required this.annotationStorage,
    super.key,
  });

  final List<MusicDocument> documents;
  final AnnotationStorage annotationStorage;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Music Viewer',
      home: MainPage(
        documents: documents,
        annotationStorage: annotationStorage,
      ),
    );
  }
}
