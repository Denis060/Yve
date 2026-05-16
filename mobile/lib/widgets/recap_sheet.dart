import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/recap.dart';
import '../models/study_mode.dart';
import '../screens/chat_screen.dart';
import '../services/retention_service.dart';
import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';

/// Launches the "How am I doing?" recap. Shows a loading state while
/// yve-recap composes the response, then slides into the rendered sheet.
Future<void> showYveRecap(BuildContext context, WidgetRef ref) async {
  final Future<Recap> futureRecap =
      ref.read(retentionRepositoryProvider).composeRecap();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _RecapSheet(future: futureRecap),
  );
}

class _RecapSheet extends StatelessWidget {
  const _RecapSheet({required this.future});

  final Future<Recap> future;

  @override
  Widget build(BuildContext context) {
    final double topInset = MediaQuery.of(context).padding.top;
    return DraggableScrollableSheet(
      initialChildSize: 0.82,
      minChildSize: 0.5,
      maxChildSize: 1 - (topInset / MediaQuery.of(context).size.height),
      builder: (BuildContext ctx, ScrollController scroll) {
        return Container(
          decoration: const BoxDecoration(
            color: YveColors.surface,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(28),
              topRight: Radius.circular(28),
            ),
          ),
          child: FutureBuilder<Recap>(
            future: future,
            builder: (BuildContext ctx2, AsyncSnapshot<Recap> snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const _LoadingShell();
              }
              if (snap.hasError) {
                return _ErrorShell(message: snap.error.toString());
              }
              final Recap recap = snap.data!;
              return _Rendered(recap: recap, scroll: scroll);
            },
          ),
        );
      },
    );
  }
}

class _LoadingShell extends StatelessWidget {
  const _LoadingShell();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        const _Handle(),
        const Spacer(),
        const CircularProgressIndicator(),
        const SizedBox(height: YveSpacing.md),
        Text(
          'Yve is gathering your week…',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: YveColors.textSecondary,
              ),
        ),
        const Spacer(),
      ],
    );
  }
}

class _ErrorShell extends StatelessWidget {
  const _ErrorShell({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        const _Handle(),
        const SizedBox(height: YveSpacing.xl),
        const Icon(Icons.cloud_off_rounded,
            size: 36, color: YveColors.textTertiary),
        const SizedBox(height: YveSpacing.sm),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: YveSpacing.xl),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              color: YveColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

class _Rendered extends ConsumerWidget {
  const _Rendered({required this.recap, required this.scroll});

  final Recap recap;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: <Widget>[
        const _Handle(),
        Expanded(
          child: ListView(
            controller: scroll,
            padding: EdgeInsets.zero,
            children: <Widget>[
              _Header(greeting: recap.greeting),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  YveSpacing.xl,
                  YveSpacing.xl,
                  YveSpacing.xl,
                  YveSpacing.xxxl,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      recap.summary,
                      style: const TextStyle(
                        fontSize: 15,
                        color: YveColors.textPrimary,
                        height: 1.55,
                      ),
                    ),
                    if (recap.highlights.isNotEmpty) ...<Widget>[
                      const SizedBox(height: YveSpacing.xxl),
                      const _SectionLabel('Worth noting'),
                      const SizedBox(height: YveSpacing.md),
                      for (final RecapHighlight h in recap.highlights)
                        _HighlightRow(highlight: h),
                    ],
                    if (recap.suggestedFocus.isNotEmpty) ...<Widget>[
                      const SizedBox(height: YveSpacing.xxl),
                      const _SectionLabel('Worth revisiting'),
                      const SizedBox(height: YveSpacing.md),
                      for (final RecapFocus f in recap.suggestedFocus)
                        _FocusRow(
                          focus: f,
                          onTap: () {
                            Navigator.of(context).pop();
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => ChatScreen(
                                  initialMode: StudyMode.practice,
                                  initialDraft: 'Quiz me on ${f.concept}',
                                ),
                              ),
                            );
                          },
                        ),
                    ],
                    if (recap.closing.isNotEmpty) ...<Widget>[
                      const SizedBox(height: YveSpacing.xxl),
                      const _Signature(),
                      const SizedBox(height: YveSpacing.sm),
                      Text(
                        recap.closing,
                        style: const TextStyle(
                          fontSize: 14,
                          fontStyle: FontStyle.italic,
                          color: YveColors.textSecondary,
                          height: 1.55,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Handle extends StatelessWidget {
  const _Handle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Center(
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: YveColors.border,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.greeting});
  final String greeting;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(gradient: YveColors.brandGradient),
      padding: const EdgeInsets.fromLTRB(
        YveSpacing.xl,
        YveSpacing.xl,
        YveSpacing.xl,
        YveSpacing.xxl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Row(
            children: <Widget>[
              Icon(Icons.auto_awesome,
                  size: 14, color: YveColors.textOnGradient),
              SizedBox(width: 6),
              Text(
                'YVE RECAP',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: YveColors.textOnGradient,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
          const SizedBox(height: YveSpacing.sm),
          Text(
            greeting,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: YveColors.textInverse,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: YveColors.textTertiary,
        letterSpacing: 0.8,
      ),
    );
  }
}

class _HighlightRow extends StatelessWidget {
  const _HighlightRow({required this.highlight});
  final RecapHighlight highlight;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: YveSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            margin: const EdgeInsets.only(top: 6),
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: YveColors.accent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: YveSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  highlight.title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: YveColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  highlight.detail,
                  style: const TextStyle(
                    fontSize: 13,
                    color: YveColors.textSecondary,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FocusRow extends StatelessWidget {
  const _FocusRow({required this.focus, required this.onTap});

  final RecapFocus focus;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: YveSpacing.sm),
      child: Material(
        color: YveColors.surface,
        borderRadius: YveSpacing.cardRadius,
        child: InkWell(
          borderRadius: YveSpacing.cardRadius,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(YveSpacing.md),
            decoration: BoxDecoration(
              borderRadius: YveSpacing.cardRadius,
              border: Border.all(color: YveColors.border),
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: YveColors.primarySurface,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.track_changes_rounded,
                      size: 18, color: YveColors.primary),
                ),
                const SizedBox(width: YveSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        focus.concept,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: YveColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        focus.subject != null
                            ? '${focus.subject} · ${focus.why}'
                            : focus.why,
                        style: const TextStyle(
                          fontSize: 12,
                          color: YveColors.textSecondary,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.play_arrow_rounded,
                    color: YveColors.textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Signature extends StatelessWidget {
  const _Signature();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: <Widget>[
        Icon(Icons.auto_awesome, size: 14, color: YveColors.accent),
        SizedBox(width: 4),
        Text(
          '— Yve',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: YveColors.accent,
            letterSpacing: 0.4,
          ),
        ),
      ],
    );
  }
}
