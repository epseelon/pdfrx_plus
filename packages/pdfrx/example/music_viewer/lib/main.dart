import 'package:flutter/material.dart';

import 'main_page.dart';

void main(List<String> args) {
  runApp(MyApp(fileOrUri: args.isNotEmpty ? args[0] : null));
}

class MyApp extends StatelessWidget {
  const MyApp({this.fileOrUri, super.key});

  final String? fileOrUri;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(title: 'Music Viewer', home: MainPage());
  }
}
