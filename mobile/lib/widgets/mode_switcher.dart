import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/study_mode.dart';
import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';

/// Horizontally scrollable pill row that lets the learner change Yve's mode
/// mid-conversation. The active pill carries the mode's tint so the shift in
/// Yve's behavior feels visible, not hidden.
class ModeSwitcher extends StatelessWidget {
  const ModeSwitcher({
    super.key,
    required this.current,
    required this.onChanged,
  });

  final StudyMode current;
  final ValueChanged<StudyMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: YveSpacing.lg),
        itemCount: StudyMode.userFacing.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (BuildContext context, int i) {
          final StudyMode m = StudyMode.userFacing[i];
          final bool active = m == current;
          return _ModePill(
            mode: m,
            active: active,
            onTap: () {
              if (active) return;
              HapticFeedback.selectionClick();
              onChanged(m);
            },
          );
        },
      ),
    );
  }
}

class _ModePill extends StatelessWidget {
  const _ModePill({
    required this.mode,
    required this.active,
    required this.onTap,
  });

  final StudyMode mode;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color bg = active ? mode.tint : YveColors.surface;
    final Color border = active ? mode.iconColor : YveColors.border;
    final Color fg = active ? mode.iconColor : YveColors.textSecondary;
    return Material(
      color: bg,
      borderRadius: YveSpacing.pillRadius,
      child: InkWell(
        onTap: onTap,
        borderRadius: YveSpacing.pillRadius,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: YveSpacing.pillRadius,
            border: Border.all(color: border, width: 1.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(mode.icon, size: 14, color: fg),
              const SizedBox(width: 6),
              Text(
                mode.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
