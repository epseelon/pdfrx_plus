import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class EraserRadiusPopup extends StatelessWidget {
  const EraserRadiusPopup({
    required this.tooltip,
    required this.radii,
    required this.radiusListenable,
    required this.onSelected,
    super.key,
  });

  final String tooltip;
  final List<double> radii;
  final ValueListenable<double> radiusListenable;
  final ValueChanged<double> onSelected;

  static const _iconBox = 22.0;
  static const _menuItemBox = 48.0;
  static const _iconRadiusMin = 4.0;
  static const _iconRadiusMax = 22.0;

  @override
  Widget build(BuildContext context) {
    final borderColor = Theme.of(context).colorScheme.onSurface;
    return ValueListenableBuilder<double>(
      valueListenable: radiusListenable,
      builder: (context, current, _) => PopupMenuButton<double>(
        tooltip: tooltip,
        icon: _eraserPreview(
          current.clamp(_iconRadiusMin, _iconRadiusMax),
          borderColor,
          box: _iconBox,
        ),
        onSelected: onSelected,
        itemBuilder: (context) => [
          for (final r in radii)
            CheckedPopupMenuItem<double>(
              value: r,
              checked: r == current,
              child: Row(
                children: [
                  _eraserPreview(r, borderColor, box: _menuItemBox),
                  const SizedBox(width: 12),
                  Text('${r.toStringAsFixed(0)} pt'),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _eraserPreview(double size, Color borderColor, {required double box}) {
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
