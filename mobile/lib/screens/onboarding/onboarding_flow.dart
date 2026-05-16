import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/onboarding_service.dart';
import '../../services/subjects_service.dart';
import '../../theme/yve_colors.dart';
import '../../theme/yve_spacing.dart';
import '../../utils/app_error.dart';
import '../app_shell.dart';

/// Three-screen onboarding (Product Vision §10).
///
/// 1. Welcome — meet Yve
/// 2. Subject picker — auto-creates the first workspace
/// 3. First action — into Scan or Chat immediately
///
/// Skippable, no tutorials. Users learn by doing.
class OnboardingFlow extends ConsumerStatefulWidget {
  const OnboardingFlow({super.key});

  @override
  ConsumerState<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends ConsumerState<OnboardingFlow> {
  final PageController _controller = PageController();
  int _page = 0;

  static const List<_SubjectOption> _options = <_SubjectOption>[
    _SubjectOption('Nursing', '🩺'),
    _SubjectOption('Math', '📐'),
    _SubjectOption('English', '📚'),
    _SubjectOption('Business', '💼'),
    _SubjectOption('Science', '🔬'),
    _SubjectOption('Other', '✨'),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_page < 2) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    } else {
      _finish();
    }
  }

  Future<void> _finish({int? initialTabIndex}) async {
    await ref.read(onboardingServiceProvider).markComplete();
    ref.invalidate(onboardingCompleteProvider);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => AppShell(initialIndex: initialTabIndex ?? 0),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                YveSpacing.xl,
                YveSpacing.md,
                YveSpacing.xl,
                0,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Row(
                    children: List<Widget>.generate(3, (int i) {
                      final bool active = i <= _page;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 240),
                        margin: const EdgeInsets.only(right: 6),
                        width: active ? 24 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: active
                              ? YveColors.primary
                              : YveColors.border,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      );
                    }),
                  ),
                  TextButton(
                    onPressed: _finish,
                    child: const Text('Skip'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                controller: _controller,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (int i) => setState(() => _page = i),
                children: <Widget>[
                  _WelcomePage(onNext: _next),
                  _SubjectPickerPage(
                    options: _options,
                    onPick: (_SubjectOption opt) async {
                      try {
                        await ref
                            .read(subjectsProvider.notifier)
                            .addSubject(
                              name: '${opt.name} 101',
                              emoji: opt.emoji,
                            );
                      } catch (e) {
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              AppError.from(e, actionContext: 'onboarding_subject').userMessage,
                            ),
                          ),
                        );
                      }
                      if (mounted) _next();
                    },
                  ),
                  _FirstActionPage(
                    onScan: () => _finish(initialTabIndex: 2),
                    onChat: () => _finish(initialTabIndex: 0),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubjectOption {
  const _SubjectOption(this.name, this.emoji);
  final String name;
  final String emoji;
}

class _WelcomePage extends StatelessWidget {
  const _WelcomePage({required this.onNext});

  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        YveSpacing.xxl,
        YveSpacing.xxxl,
        YveSpacing.xxl,
        YveSpacing.xxl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Spacer(),
          Center(
            child: Container(
              width: 140,
              height: 140,
              decoration: const BoxDecoration(
                gradient: YveColors.brandGradient,
                shape: BoxShape.circle,
              ),
              child: const Center(
                child: Text(
                  '✦',
                  style: TextStyle(fontSize: 64, color: YveColors.textInverse),
                ),
              ),
            ),
          ),
          const SizedBox(height: YveSpacing.xxl),
          Text(
            'Meet Yve.',
            textAlign: TextAlign.center,
            style: text.displayMedium,
          ),
          const SizedBox(height: YveSpacing.sm),
          Text(
            'Your calm AI study companion. Scan an assignment, ask a question, organize what you learn.',
            textAlign: TextAlign.center,
            style: text.bodyLarge?.copyWith(color: YveColors.textSecondary),
          ),
          const Spacer(),
          FilledButton(
            onPressed: onNext,
            child: const Text('Get started'),
          ),
        ],
      ),
    );
  }
}

class _SubjectPickerPage extends StatelessWidget {
  const _SubjectPickerPage({required this.options, required this.onPick});

  final List<_SubjectOption> options;
  final ValueChanged<_SubjectOption> onPick;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        YveSpacing.xxl,
        YveSpacing.xxl,
        YveSpacing.xxl,
        YveSpacing.xxl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('What are you studying?', style: text.headlineMedium),
          const SizedBox(height: YveSpacing.sm),
          Text(
            'Pick one to start. You can add more anytime.',
            style: text.bodyMedium?.copyWith(color: YveColors.textSecondary),
          ),
          const SizedBox(height: YveSpacing.xxl),
          Expanded(
            child: GridView.builder(
              physics: const BouncingScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: YveSpacing.md,
                mainAxisSpacing: YveSpacing.md,
                childAspectRatio: 1.4,
              ),
              itemCount: options.length,
              itemBuilder: (BuildContext context, int i) {
                final _SubjectOption opt = options[i];
                return Material(
                  color: YveColors.surface,
                  borderRadius: YveSpacing.cardRadius,
                  child: InkWell(
                    borderRadius: YveSpacing.cardRadius,
                    onTap: () => onPick(opt),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: YveSpacing.cardRadius,
                        border: Border.all(color: YveColors.border),
                      ),
                      padding: const EdgeInsets.all(YveSpacing.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: <Widget>[
                          Text(opt.emoji,
                              style: const TextStyle(fontSize: 28)),
                          Text(opt.name, style: text.titleSmall),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _FirstActionPage extends StatelessWidget {
  const _FirstActionPage({required this.onScan, required this.onChat});

  final VoidCallback onScan;
  final VoidCallback onChat;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        YveSpacing.xxl,
        YveSpacing.xxl,
        YveSpacing.xxl,
        YveSpacing.xxl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('Your first action', style: text.headlineMedium),
          const SizedBox(height: YveSpacing.sm),
          Text(
            'Scan an assignment or jump into a conversation with Yve.',
            style: text.bodyMedium?.copyWith(color: YveColors.textSecondary),
          ),
          const Spacer(),
          _ActionTile(
            icon: Icons.center_focus_strong_rounded,
            title: 'Scan an assignment',
            subtitle: 'Snap a photo and Yve will read it.',
            tint: YveColors.primarySurface,
            iconColor: YveColors.primary,
            onTap: onScan,
          ),
          const SizedBox(height: YveSpacing.md),
          _ActionTile(
            icon: Icons.auto_awesome_rounded,
            title: 'Ask Yve a question',
            subtitle: 'Paste a problem or type what you\'re stuck on.',
            tint: YveColors.tintPurple,
            iconColor: const Color(0xFF8B5CF6),
            onTap: onChat,
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.tint,
    required this.iconColor,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color tint;
  final Color iconColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Material(
      color: YveColors.surface,
      borderRadius: YveSpacing.cardRadius,
      child: InkWell(
        onTap: onTap,
        borderRadius: YveSpacing.cardRadius,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: YveSpacing.cardRadius,
            boxShadow: YveSpacing.cardShadow,
            color: YveColors.surface,
          ),
          padding: const EdgeInsets.all(YveSpacing.lg),
          child: Row(
            children: <Widget>[
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: tint,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: iconColor),
              ),
              const SizedBox(width: YveSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(title, style: text.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: text.bodySmall,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  color: YveColors.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}
