import 'package:pdfrx/pdfrx.dart';

/// Minimal [PdfPage] stub for annotation-layer tests. The layer only
/// reads [pageNumber], [width], and [height] from the page; everything
/// else throws via `noSuchMethod` to surface accidental usage.
class FakePdfPage implements PdfPage {
  FakePdfPage({required this.pageNumber, required this.width, required this.height});

  @override
  final int pageNumber;
  @override
  final double width;
  @override
  final double height;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FakePdfPage does not implement ${invocation.memberName}');
}
