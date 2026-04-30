import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

typedef ColorPopupEntry = ({Color color, String label});

class ColorPopup extends StatelessWidget {
  const ColorPopup({
    required this.tooltip,
    required this.palette,
    required this.valueListenable,
    required this.onSelected,
    super.key,
  });

  final String tooltip;
  final List<ColorPopupEntry> palette;
  final ValueListenable<Color> valueListenable;
  final ValueChanged<Color> onSelected;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Color>(
      valueListenable: valueListenable,
      builder: (context, current, _) => PopupMenuButton<Color>(
        tooltip: tooltip,
        icon: Icon(Icons.circle, color: current),
        onSelected: onSelected,
        itemBuilder: (context) => [
          for (final entry in palette)
            CheckedPopupMenuItem<Color>(
              value: entry.color,
              checked: entry.color == current,
              child: Row(
                children: [
                  Icon(Icons.circle, color: entry.color, size: 20),
                  const SizedBox(width: 8),
                  Text(entry.label),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
