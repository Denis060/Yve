import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';

/// 5-tab bottom navigation with an elevated, pill-shaped center Scan button
/// (Product Vision §5). The center action lifts above the bar because the
/// camera is the highest-frequency path for the target audience.
class YveBottomNav extends StatelessWidget {
  const YveBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;

  static const int scanIndex = 2;

  @override
  Widget build(BuildContext context) {
    final double bottomInset = MediaQuery.of(context).padding.bottom;

    return Container(
      decoration: const BoxDecoration(
        color: YveColors.surface,
        border: Border(
          top: BorderSide(color: YveColors.borderSubtle),
        ),
      ),
      padding: EdgeInsets.only(top: 8, bottom: 8 + bottomInset),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          _NavItem(
            icon: Icons.home_rounded,
            label: 'Home',
            active: currentIndex == 0,
            onTap: () => _select(0),
          ),
          _NavItem(
            icon: Icons.menu_book_rounded,
            label: 'Subjects',
            active: currentIndex == 1,
            onTap: () => _select(1),
          ),
          _ScanButton(
            active: currentIndex == scanIndex,
            onTap: () => _select(scanIndex),
          ),
          _NavItem(
            icon: Icons.school_rounded,
            label: 'Study',
            active: currentIndex == 3,
            onTap: () => _select(3),
          ),
          _NavItem(
            icon: Icons.person_rounded,
            label: 'Profile',
            active: currentIndex == 4,
            onTap: () => _select(4),
          ),
        ],
      ),
    );
  }

  void _select(int index) {
    HapticFeedback.selectionClick();
    onTap(index);
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color color = active ? YveColors.primary : YveColors.textTertiary;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, color: color, size: 24),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScanButton extends StatelessWidget {
  const _ScanButton({required this.active, required this.onTap});

  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      child: Transform.translate(
        offset: const Offset(0, -16),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: YveColors.primary,
            borderRadius: YveSpacing.pillRadius,
            boxShadow: YveSpacing.fabShadow,
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: YveSpacing.pillRadius,
            child: InkWell(
              onTap: onTap,
              borderRadius: YveSpacing.pillRadius,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                child: Icon(
                  Icons.center_focus_strong_rounded,
                  color: YveColors.textInverse,
                  size: 26,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
