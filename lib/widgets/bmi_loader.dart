import 'package:flutter/material.dart';

class BmiLoader extends StatelessWidget {
  const BmiLoader({
    super.key,
    this.size = 54,
    this.strokeWidth = 4,
    this.label,
    this.showLabel = false,
  });

  final double size;
  final double strokeWidth;
  final String? label;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final secondary = Theme.of(context).colorScheme.tertiary;

    final loader = SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            strokeWidth: strokeWidth,
            valueColor: AlwaysStoppedAnimation<Color>(primary),
            backgroundColor: primary.withValues(alpha: 0.16),
          ),
          Container(
            width: size * 0.52,
            height: size * 0.52,
            decoration: BoxDecoration(
              color: secondary.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.monitor_heart_outlined,
              color: secondary,
              size: size * 0.28,
            ),
          ),
        ],
      ),
    );

    if (!showLabel) return loader;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        loader,
        const SizedBox(height: 10),
        Text(
          label ?? 'Calculating BMI...',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
