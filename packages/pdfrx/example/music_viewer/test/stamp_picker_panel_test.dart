import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_viewer/stamp_picker_panel.dart';
import 'package:pdfrx/pdfrx.dart';

Widget _stampBuilder(BuildContext context, Uint8List bytes, String contentType, Size displaySize) {
  return SizedBox.fromSize(
    size: displaySize,
    child: const ColoredBox(color: Color(0xFFCCCCCC)),
  );
}

PdfStampDefinition _def(String id, {Uint8List? bytes}) => PdfStampDefinition(
  id: id,
  name: id,
  contentType: 'image/svg+xml',
  bytesLoader: () async => bytes ?? Uint8List.fromList([1, 2, 3]),
  intrinsicSize: const Size(24, 24),
);

Future<void> _pumpPanel(
  WidgetTester tester, {
  required PdfViewerController controller,
  required List<PdfViewerStampCategory> categories,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StampPickerPanel(
          controller: controller,
          categories: categories,
          stampImageBuilder: _stampBuilder,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders categories sorted by id with stamps sorted by id', (tester) async {
    final controller = PdfViewerController();
    final categories = [
      PdfViewerStampCategory(
        id: 'notes',
        title: 'Notes',
        stamps: [_def('sharp'), _def('flat')],
      ),
      PdfViewerStampCategory(
        id: 'dynamics',
        title: 'Dynamics',
        stamps: [_def('forte')],
      ),
    ];
    await _pumpPanel(tester, controller: controller, categories: categories);
    await tester.pump();

    // Categories sorted: dynamics → notes.
    final headers = tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList();
    expect(headers.indexOf('Dynamics'), lessThan(headers.indexOf('Notes')));

    // Each category's stamps sorted by id ascending. Use the stable
    // Key('stampThumb:$catId/$stampId') selectors.
    expect(find.byKey(const Key('stampThumb:dynamics/forte')), findsOneWidget);
    expect(find.byKey(const Key('stampThumb:notes/flat')), findsOneWidget);
    expect(find.byKey(const Key('stampThumb:notes/sharp')), findsOneWidget);
  });

  testWidgets('tapping a thumbnail invokes setPendingStamp and applies the highlight', (tester) async {
    final controller = PdfViewerController();
    final sharp = _def('sharp');
    final flat = _def('flat');
    await _pumpPanel(
      tester,
      controller: controller,
      categories: [
        PdfViewerStampCategory(id: 'notes', title: 'Notes', stamps: [sharp, flat]),
      ],
    );
    await tester.pump();

    expect(controller.pendingStampListenable.value, isNull);

    await tester.tap(find.byKey(const Key('stampThumb:notes/sharp')));
    await tester.pumpAndSettle();
    expect(controller.pendingStampListenable.value, same(sharp));

    await tester.tap(find.byKey(const Key('stampThumb:notes/flat')));
    await tester.pumpAndSettle();
    expect(controller.pendingStampListenable.value, same(flat));
  });

  testWidgets('tapping the armed thumbnail again disarms it (toggle)', (tester) async {
    final controller = PdfViewerController();
    final sharp = _def('sharp');
    await _pumpPanel(
      tester,
      controller: controller,
      categories: [
        PdfViewerStampCategory(id: 'notes', title: 'Notes', stamps: [sharp]),
      ],
    );
    await tester.pump();

    final thumb = find.byKey(const Key('stampThumb:notes/sharp'));

    await tester.tap(thumb);
    await tester.pumpAndSettle();
    expect(controller.pendingStampListenable.value, same(sharp));

    // Second tap on the same (now armed) thumbnail clears the
    // pending stamp so subsequent page taps place nothing.
    await tester.tap(thumb);
    await tester.pumpAndSettle();
    expect(controller.pendingStampListenable.value, isNull);
  });
}
