import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:music_viewer/color_popup.dart';
import 'package:music_viewer/eraser_radius_popup.dart';
import 'package:music_viewer/stroke_thickness_popup.dart';
import 'package:pdfrx/pdfrx.dart';

const _penPalette = <ColorPopupEntry>[
  (color: Color(0xFFFF3B30), label: 'Red'),
  (color: Color(0xFF000000), label: 'Black'),
  (color: Color(0xFF007AFF), label: 'Blue'),
  (color: Color(0xFF34C759), label: 'Green'),
  (color: Color(0xFFFF9500), label: 'Orange'),
  (color: Color(0xFFAF52DE), label: 'Purple'),
];

const _highlighterPalette = <ColorPopupEntry>[
  (color: Color(0xFFFFFF00), label: 'Yellow'),
  (color: Color(0xFF00FF00), label: 'Green'),
  (color: Color(0xFFFF69B4), label: 'Pink'),
  (color: Color(0xFFFFA500), label: 'Orange'),
  (color: Color(0xFF00BFFF), label: 'Blue'),
];

class AnnotationUndoRedoButtons extends StatelessWidget {
  const AnnotationUndoRedoButtons({
    required this.canUndoListenable,
    required this.canRedoListenable,
    required this.onUndo,
    required this.onRedo,
    super.key,
  });

  final ValueListenable<bool> canUndoListenable;
  final ValueListenable<bool> canRedoListenable;
  final VoidCallback onUndo;
  final VoidCallback onRedo;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ValueListenableBuilder<bool>(
          valueListenable: canUndoListenable,
          builder: (context, canUndo, _) => IconButton(
            tooltip: 'Undo',
            icon: const Icon(Icons.undo),
            onPressed: canUndo ? onUndo : null,
          ),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: canRedoListenable,
          builder: (context, canRedo, _) => IconButton(
            tooltip: 'Redo',
            icon: const Icon(Icons.redo),
            onPressed: canRedo ? onRedo : null,
          ),
        ),
      ],
    );
  }
}

class AnnotationToolButtons extends StatelessWidget {
  const AnnotationToolButtons({
    required this.toolListenable,
    required this.onSelectTool,
    this.stampAvailable = false,
    super.key,
  });

  final ValueListenable<PdfAnnotationTool> toolListenable;
  final ValueChanged<PdfAnnotationTool> onSelectTool;
  final bool stampAvailable;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PdfAnnotationTool>(
      valueListenable: toolListenable,
      builder: (context, tool, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton.filledTonal(
            tooltip: 'Pen',
            isSelected: tool == PdfAnnotationTool.pen,
            selectedIcon: const Icon(Icons.edit),
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => onSelectTool(PdfAnnotationTool.pen),
          ),
          IconButton.filledTonal(
            tooltip: 'Highlighter',
            isSelected: tool == PdfAnnotationTool.highlighter,
            selectedIcon: const Icon(Icons.highlight),
            icon: const Icon(Icons.highlight_outlined),
            onPressed: () => onSelectTool(PdfAnnotationTool.highlighter),
          ),
          IconButton.filledTonal(
            tooltip: 'Eraser',
            isSelected: tool == PdfAnnotationTool.eraser,
            selectedIcon: const Icon(Icons.cleaning_services),
            icon: const Icon(Icons.cleaning_services_outlined),
            onPressed: () => onSelectTool(PdfAnnotationTool.eraser),
          ),
          if (stampAvailable)
            IconButton.filledTonal(
              tooltip: 'Stamp',
              isSelected: tool == PdfAnnotationTool.stamp,
              selectedIcon: const Icon(Icons.bookmark),
              icon: const Icon(Icons.bookmark_border),
              onPressed: () => onSelectTool(PdfAnnotationTool.stamp),
            ),
        ],
      ),
    );
  }
}

class AnnotationStylePopups extends StatelessWidget {
  const AnnotationStylePopups({required this.controller, required this.tool, super.key});

  final PdfViewerController controller;
  final PdfAnnotationTool tool;

  @override
  Widget build(BuildContext context) {
    switch (tool) {
      case PdfAnnotationTool.pen:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ColorPopup(
              tooltip: 'Color',
              palette: _penPalette,
              valueListenable: controller.annotationStrokeColorListenable,
              onSelected: controller.setAnnotationStrokeColor,
            ),
            StrokeThicknessPopup(
              tooltip: 'Pen thickness',
              thicknesses: const <double>[1.0, 2.0, 3.0, 5.0, 8.0],
              widthListenable: controller.annotationStrokeWidthListenable,
              colorListenable: controller.annotationStrokeColorListenable,
              onSelected: controller.setAnnotationStrokeWidth,
            ),
          ],
        );
      case PdfAnnotationTool.highlighter:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ColorPopup(
              tooltip: 'Highlighter color',
              palette: _highlighterPalette,
              valueListenable: controller.annotationHighlighterColorListenable,
              onSelected: controller.setAnnotationHighlighterColor,
            ),
            StrokeThicknessPopup(
              tooltip: 'Highlighter thickness',
              thicknesses: const <double>[8.0, 12.0, 16.0, 24.0],
              widthListenable: controller.annotationHighlighterWidthListenable,
              colorListenable: controller.annotationHighlighterColorListenable,
              onSelected: controller.setAnnotationHighlighterWidth,
              opacity: 0.35,
              iconMaxThickness: 24.0,
            ),
          ],
        );
      case PdfAnnotationTool.eraser:
        return EraserRadiusPopup(
          tooltip: 'Eraser size',
          radii: const <double>[5.0, 10.0, 20.0, 40.0],
          radiusListenable: controller.annotationEraserRadiusListenable,
          onSelected: controller.setAnnotationEraserRadius,
        );
      case PdfAnnotationTool.stamp:
      case PdfAnnotationTool.hand:
        return const SizedBox.shrink();
    }
  }
}
