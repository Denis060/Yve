import 'package:flutter/material.dart';

import '../models/daily_activity.dart';
import '../theme/yve_colors.dart';

/// 7-dot activity strip rendered in the Home greeting. A filled dot means
/// "you showed up today" — no streak counter, no penalty for missed days
/// (Product Vision: calm, non-judgmental).
///
/// The strip sits over the brand-gradient header so dots use light tints.
class ActivityStrip extends StatelessWidget {
  const ActivityStrip({super.key, required this.week});

  final List<DailyActivity> week;

  int get _daysActive =>
      week.where((DailyActivity d) => d.messageCount > 0).length;

  String get _line {
    if (_daysActive == 0) return 'A fresh week to start when you\'re ready.';
    if (_daysActive == 1) return 'You showed up 1 day this week.';
    if (_daysActive == 7) return 'You\'ve been here every day this week.';
    return 'You showed up $_daysActive days this week.';
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Expanded(
          child: Text(
            _line,
            style: const TextStyle(
              fontSize: 13,
              color: YveColors.textOnGradient,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 12),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final DailyActivity d in week)
              _Dot(filled: d.messageCount > 0),
          ],
        ),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.filled});
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 5),
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? YveColors.accent : const Color(0x33FFFFFF),
      ),
    );
  }
}
