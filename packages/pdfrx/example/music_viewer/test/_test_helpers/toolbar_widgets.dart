import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

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
      case PdfAnnotationTool.highlighter:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ColorPopup(controller: controller, tool: tool),
            _ThicknessPopup(controller: controller, tool: tool),
          ],
        );
      case PdfAnnotationTool.eraser:
        return _ThicknessPopup(controller: controller, tool: tool);
      case PdfAnnotationTool.stamp:
        return const SizedBox.shrink();
    }
  }
}

class _ColorPopup extends StatelessWidget {
  const _ColorPopup({required this.controller, required this.tool});

  final PdfViewerController controller;
  final PdfAnnotationTool tool;

  static const _penPalette = <Color>[
    Color(0xFFFF3B30),
    Color(0xFF000000),
    Color(0xFF007AFF),
    Color(0xFF34C759),
    Color(0xFFFF9500),
    Color(0xFFAF52DE),
  ];
  static const _highlighterPalette = <Color>[
    Color(0xFFFFFF00),
    Color(0xFF00FF00),
    Color(0xFFFF69B4),
    Color(0xFFFFA500),
    Color(0xFF00BFFF),
  ];

  @override
  Widget build(BuildContext context) {
    final isHighlighter = tool == PdfAnnotationTool.highlighter;
    final listenable = isHighlighter
        ? controller.annotationHighlighterColorListenable
        : controller.annotationStrokeColorListenable;
    final ValueChanged<Color> onSelected = isHighlighter
        ? controller.setAnnotationHighlighterColor
        : controller.setAnnotationStrokeColor;
    final palette = isHighlighter ? _highlighterPalette : _penPalette;
    final tooltip = isHighlighter ? 'Highlighter color' : 'Color';
    return ValueListenableBuilder<Color>(
      valueListenable: listenable,
      builder: (context, current, _) => PopupMenuButton<Color>(
        tooltip: tooltip,
        icon: Icon(Icons.circle, color: current),
        onSelected: onSelected,
        itemBuilder: (context) => [
          for (final c in palette)
            CheckedPopupMenuItem<Color>(
              value: c,
              checked: c == current,
              child: Row(
                children: [
                  Icon(Icons.circle, color: c, size: 20),
                  const SizedBox(width: 8),
                  Text(_colorLabel(c)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _colorLabel(Color c) {
    if (c == const Color(0xFFFF3B30)) return 'Red';
    if (c == const Color(0xFF000000)) return 'Black';
    if (c == const Color(0xFF007AFF)) return 'Blue';
    if (c == const Color(0xFF34C759)) return 'Green';
    if (c == const Color(0xFFFF9500)) return 'Orange';
    if (c == const Color(0xFFAF52DE)) return 'Purple';
    if (c == const Color(0xFFFFFF00)) return 'Yellow';
    if (c == const Color(0xFF00FF00)) return 'Green';
    if (c == const Color(0xFFFF69B4)) return 'Pink';
    if (c == const Color(0xFFFFA500)) return 'Orange';
    if (c == const Color(0xFF00BFFF)) return 'Blue';
    return 'Custom';
  }
}

class _ThicknessPopup extends StatelessWidget {
  const _ThicknessPopup({required this.controller, required this.tool});

  final PdfViewerController controller;
  final PdfAnnotationTool tool;

  static const _penThicknesses = <double>[1.0, 2.0, 3.0, 5.0, 8.0];
  static const _highlighterThicknesses = <double>[8.0, 12.0, 16.0, 24.0];
  static const _eraserSizes = <double>[5.0, 10.0, 20.0, 40.0];

  @override
  Widget build(BuildContext context) {
    switch (tool) {
      case PdfAnnotationTool.pen:
        return ValueListenableBuilder<Color>(
          valueListenable: controller.annotationStrokeColorListenable,
          builder: (context, color, _) => ValueListenableBuilder<double>(
            valueListenable: controller.annotationStrokeWidthListenable,
            builder: (context, current, _) => PopupMenuButton<double>(
              tooltip: 'Pen thickness',
              icon: _strokePreview(current, color, width: 22),
              onSelected: controller.setAnnotationStrokeWidth,
              itemBuilder: (context) => [
                for (final w in _penThicknesses)
                  CheckedPopupMenuItem<double>(
                    value: w,
                    checked: w == current,
                    child: Row(
                      children: [
                        _strokePreview(w, color),
                        const SizedBox(width: 12),
                        Text('${w.toStringAsFixed(1)} pt'),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      case PdfAnnotationTool.highlighter:
        return ValueListenableBuilder<Color>(
          valueListenable: controller.annotationHighlighterColorListenable,
          builder: (context, color, _) => ValueListenableBuilder<double>(
            valueListenable: controller.annotationHighlighterWidthListenable,
            builder: (context, current, _) => PopupMenuButton<double>(
              tooltip: 'Highlighter thickness',
              icon: _strokePreview(current.clamp(0.0, 24.0), color, width: 22, opacity: 0.35),
              onSelected: controller.setAnnotationHighlighterWidth,
              itemBuilder: (context) => [
                for (final w in _highlighterThicknesses)
                  CheckedPopupMenuItem<double>(
                    value: w,
                    checked: w == current,
                    child: Row(
                      children: [
                        _strokePreview(w, color, opacity: 0.35),
                        const SizedBox(width: 12),
                        Text('${w.toStringAsFixed(1)} pt'),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      case PdfAnnotationTool.stamp:
        return const SizedBox.shrink();
      case PdfAnnotationTool.eraser:
        final borderColor = Theme.of(context).colorScheme.onSurface;
        return ValueListenableBuilder<double>(
          valueListenable: controller.annotationEraserRadiusListenable,
          builder: (context, current, _) => PopupMenuButton<double>(
            tooltip: 'Eraser size',
            icon: _eraserPreview(current.clamp(4, 22), borderColor, box: 22),
            onSelected: controller.setAnnotationEraserRadius,
            itemBuilder: (context) => [
              for (final r in _eraserSizes)
                CheckedPopupMenuItem<double>(
                  value: r,
                  checked: r == current,
                  child: Row(
                    children: [
                      _eraserPreview(r, borderColor),
                      const SizedBox(width: 12),
                      Text('${r.toStringAsFixed(0)} pt'),
                    ],
                  ),
                ),
            ],
          ),
        );
    }
  }

  Widget _strokePreview(double thickness, Color color, {double width = 60, double opacity = 1.0}) => SizedBox(
    width: width,
    height: 12,
    child: Center(
      child: Container(
        width: width,
        height: thickness,
        decoration: BoxDecoration(
          color: color.withValues(alpha: opacity),
          borderRadius: BorderRadius.circular(thickness / 2),
        ),
      ),
    ),
  );

  Widget _eraserPreview(double size, Color borderColor, {double box = 48}) {
    final diameter = size.clamp(0, box);
    return SizedBox(
      width: box,
      height: box,
      child: Center(
        child: Container(
          width: diameter.toDouble(),
          height: diameter.toDouble(),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: borderColor, width: 1.5),
          ),
        ),
      ),
    );
  }
}
