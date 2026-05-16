import 'package:flutter/material.dart';

import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';

/// Standard Yve card surface — 16px radius, soft shadow, optional tap.
class YveCard extends StatelessWidget {
  const YveCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(YveSpacing.lg),
    this.color = YveColors.surface,
    this.borderRadius,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final Color color;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius = borderRadius ?? YveSpacing.cardRadius;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: radius,
        boxShadow: YveSpacing.cardShadow,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}
