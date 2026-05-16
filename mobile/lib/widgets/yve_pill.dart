import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';

/// A pill-shaped chip used for quick actions and follow-ups.
class YvePill extends StatelessWidget {
  const YvePill({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.filled = false,
    this.dense = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool filled;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final Color fg = filled ? YveColors.textInverse : YveColors.primary;
    final Color bg = filled ? YveColors.primary : YveColors.surface;
    final Color border = filled ? YveColors.primary : YveColors.border;

    return Material(
      color: bg,
      borderRadius: YveSpacing.pillRadius,
      child: InkWell(
        borderRadius: YveSpacing.pillRadius,
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap!();
              },
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: dense ? YveSpacing.md : YveSpacing.lg,
            vertical: dense ? 6 : 10,
          ),
          decoration: BoxDecoration(
            borderRadius: YveSpacing.pillRadius,
            border: Border.all(color: border, width: 1.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 14, color: fg),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w600,
                  fontSize: dense ? 12 : 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
