import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class StrokeThicknessPopup extends StatelessWidget {
  const StrokeThicknessPopup({
    required this.tooltip,
    required this.thicknesses,
    required this.widthListenable,
    required this.colorListenable,
    required this.onSelected,
    this.opacity = 1.0,
    this.iconMaxThickness,
    super.key,
  });

  final String tooltip;
  final List<double> thicknesses;
  final ValueListenable<double> widthListenable;
  final ValueListenable<Color> colorListenable;
  final ValueChanged<double> onSelected;

  /// Stroke opacity applied to all previews. Pen tools pass 1.0 (default);
  /// highlighter passes 0.35.
  final double opacity;

  /// Optional cap on the icon-preview thickness so very wide highlighter
  /// strokes don't overflow the toolbar. Menu-item previews are not
  /// clamped. When null, no clamp is applied.
  final double? iconMaxThickness;

  static const _iconWidth = 22.0;
  static const _menuItemWidth = 60.0;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Color>(
      valueListenable: colorListenable,
      builder: (context, color, _) => ValueListenableBuilder<double>(
        valueListenable: widthListenable,
        builder: (context, current, _) {
          final iconThickness = iconMaxThickness == null ? current : current.clamp(0.0, iconMaxThickness!);
          return PopupMenuButton<double>(
            tooltip: tooltip,
            icon: _strokePreview(iconThickness, color, width: _iconWidth),
            onSelected: onSelected,
            itemBuilder: (context) => [
              for (final t in thicknesses)
                CheckedPopupMenuItem<double>(
                  value: t,
                  checked: t == current,
                  child: Row(
                    children: [
                      _strokePreview(t, color, width: _menuItemWidth),
                      const SizedBox(width: 12),
                      Text('${t.toStringAsFixed(1)} pt'),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _strokePreview(double thickness, Color color, {required double width}) => SizedBox(
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
}
