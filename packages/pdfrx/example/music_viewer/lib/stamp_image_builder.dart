import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Builder for `PdfViewerParams.stampImageBuilder`. Renders SVG bytes via
/// `flutter_svg` and falls back to a broken-image placeholder for any
/// other content type.
///
/// Wraps the rendered child in a `SizedBox.fromSize` to enforce the exact
/// `displaySize` requested by the annotation layer (the builder contract
/// requires no intrinsic sizing). Uses [BoxFit.fill] so edge-handle
/// resize actually stretches the image (corner handles preserve aspect
/// at the bbox layer, so a uniformly-scaled rect renders identically
/// under fill or contain).
Widget stampImageBuilder(BuildContext context, Uint8List bytes, String contentType, Size displaySize) {
  if (contentType == 'image/svg+xml') {
    return SizedBox.fromSize(
      size: displaySize,
      child: SvgPicture.memory(
        bytes,
        width: displaySize.width,
        height: displaySize.height,
        fit: BoxFit.fill,
      ),
    );
  }
  return SizedBox.fromSize(
    size: displaySize,
    child: const Icon(Icons.broken_image_outlined),
  );
}
