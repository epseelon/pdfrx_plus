import 'selection_geometry.dart';

/// Strings shown by the annotation selection overlay: the rotation
/// control, the delete control, and the eight resize handles.
///
/// Supplied through `PdfViewerParams.annotationOverlayLabels`. The
/// defaults are English so the fork and its example stay usable
/// standalone; a localised host passes its own translations.
///
/// The labels are shape-neutral ("Rotate", not "Rotate stamp") because
/// the same gizmo serves every annotation kind.
///
/// They serve the `Semantics` labels of every affordance, plus the
/// delete control's visible tooltip. The rotation control and the
/// resize handles have no tooltip.
///
/// This is a value object rather than a set of fields on
/// `PdfViewerParams` so future overlay strings can be added without
/// widening that class's constructor, `==` and `hashCode` each time.
class PdfAnnotationOverlayLabels {
  /// Creates a set of overlay labels, defaulting to English.
  const PdfAnnotationOverlayLabels({
    this.rotate = 'Rotate',
    this.delete = 'Delete',
    this.resizeTopLeft = 'Resize top-left',
    this.resizeTop = 'Resize top',
    this.resizeTopRight = 'Resize top-right',
    this.resizeRight = 'Resize right',
    this.resizeBottomRight = 'Resize bottom-right',
    this.resizeBottom = 'Resize bottom',
    this.resizeBottomLeft = 'Resize bottom-left',
    this.resizeLeft = 'Resize left',
  });

  /// Label for the rotation control.
  final String rotate;

  /// Label for the delete control, used for both its `Semantics` label
  /// and its visible tooltip.
  final String delete;

  /// Label for the top-left resize handle.
  final String resizeTopLeft;

  /// Label for the top edge resize handle.
  final String resizeTop;

  /// Label for the top-right resize handle.
  final String resizeTopRight;

  /// Label for the right edge resize handle.
  final String resizeRight;

  /// Label for the bottom-right resize handle.
  final String resizeBottomRight;

  /// Label for the bottom edge resize handle.
  final String resizeBottom;

  /// Label for the bottom-left resize handle.
  final String resizeBottomLeft;

  /// Label for the left edge resize handle.
  final String resizeLeft;

  /// The label for [handle]. [PdfAnnotationHandle.body] has no
  /// affordance of its own and returns the empty string.
  String labelFor(PdfAnnotationHandle handle) => switch (handle) {
    PdfAnnotationHandle.rotation => rotate,
    PdfAnnotationHandle.topLeft => resizeTopLeft,
    PdfAnnotationHandle.top => resizeTop,
    PdfAnnotationHandle.topRight => resizeTopRight,
    PdfAnnotationHandle.right => resizeRight,
    PdfAnnotationHandle.bottomRight => resizeBottomRight,
    PdfAnnotationHandle.bottom => resizeBottom,
    PdfAnnotationHandle.bottomLeft => resizeBottomLeft,
    PdfAnnotationHandle.left => resizeLeft,
    PdfAnnotationHandle.body => '',
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PdfAnnotationOverlayLabels &&
          other.rotate == rotate &&
          other.delete == delete &&
          other.resizeTopLeft == resizeTopLeft &&
          other.resizeTop == resizeTop &&
          other.resizeTopRight == resizeTopRight &&
          other.resizeRight == resizeRight &&
          other.resizeBottomRight == resizeBottomRight &&
          other.resizeBottom == resizeBottom &&
          other.resizeBottomLeft == resizeBottomLeft &&
          other.resizeLeft == resizeLeft;

  @override
  int get hashCode => Object.hash(
    rotate,
    delete,
    resizeTopLeft,
    resizeTop,
    resizeTopRight,
    resizeRight,
    resizeBottomRight,
    resizeBottom,
    resizeBottomLeft,
    resizeLeft,
  );
}
