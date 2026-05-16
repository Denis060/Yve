import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/polish.dart';
import '../services/export_service.dart';
import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';
import '../utils/app_error.dart';

/// Render Yve's Write-mode polish response. Four sections — polished
/// draft, what changed, notes/flags, follow-up suggestions — each
/// suppressible if empty. Two copy actions:
///
///   • [Copy polished draft] → polished text only, no headings, no
///     analysis, no markdown separators. This is the deliverable.
///   • [Copy full analysis] → polished + change summary + flags +
///     preserved phrases, formatted for a plain text editor.
class PolishBubble extends StatelessWidget {
  const PolishBubble({
    super.key,
    required this.polish,
    required this.onFollowUpTap,
    this.subjectName,
    this.sessionTitle,
  });

  final Polish polish;
  final ValueChanged<String> onFollowUpTap;
  // Context used to build a structured export filename instead of one
  // derived from the polished text itself.
  final String? subjectName;
  final String? sessionTitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(YveSpacing.lg),
      decoration: BoxDecoration(
        color: YveColors.surface,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(4),
          topRight: Radius.circular(18),
          bottomLeft: Radius.circular(18),
          bottomRight: Radius.circular(18),
        ),
        boxShadow: YveSpacing.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const _SectionLabel('Polished draft'),
          const SizedBox(height: YveSpacing.sm),
          SelectableText(
            polish.polishedText,
            style: const TextStyle(
              fontSize: 14,
              color: YveColors.textPrimary,
              height: 1.6,
            ),
          ),
          const SizedBox(height: YveSpacing.md),
          _CopyActions(
            polish: polish,
            subjectName: subjectName,
            sessionTitle: sessionTitle,
          ),

          if (polish.changes.isNotEmpty) ...<Widget>[
            const SizedBox(height: YveSpacing.xl),
            const _SectionLabel('What changed and why'),
            const SizedBox(height: YveSpacing.sm),
            for (final PolishChange c in polish.changes) _ChangeRow(change: c),
          ],

          if (polish.preservedPhrases.isNotEmpty) ...<Widget>[
            const SizedBox(height: YveSpacing.lg),
            const _SectionLabel('Kept in your voice'),
            const SizedBox(height: YveSpacing.sm),
            for (final String p in polish.preservedPhrases)
              _BulletLine(text: p, accentColor: YveColors.accent),
          ],

          if (polish.flags.isNotEmpty) ...<Widget>[
            const SizedBox(height: YveSpacing.lg),
            const _SectionLabel('Worth a look'),
            const SizedBox(height: YveSpacing.sm),
            for (final String f in polish.flags)
              _BulletLine(text: f, accentColor: const Color(0xFFF59E0B)),
          ],

          if (polish.followUpSuggestions.isNotEmpty) ...<Widget>[
            const SizedBox(height: YveSpacing.lg),
            const _SectionLabel('Want me to keep going?'),
            const SizedBox(height: YveSpacing.sm),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final String s in polish.followUpSuggestions)
                  _FollowUpChip(label: s, onTap: () => onFollowUpTap(s)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _CopyActions extends StatelessWidget {
  const _CopyActions({
    required this.polish,
    this.subjectName,
    this.sessionTitle,
  });
  final Polish polish;
  final String? subjectName;
  final String? sessionTitle;

  Future<void> _copyPolished(BuildContext context) async {
    HapticFeedback.selectionClick();
    await ExportService().copyToClipboard(polish.polishedText);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Polished draft copied.')),
    );
  }

  Future<void> _openMore(BuildContext context) async {
    HapticFeedback.selectionClick();
    final ExportService svc = ExportService();
    // Build distinct names for the polished draft vs the full analysis so
    // a learner saving both ends up with two different files.
    final String polishedName = filenameFor(
      subjectName: subjectName,
      sessionTitle: sessionTitle,
      toolLabel: 'Polish',
      variant: 'Draft',
    );
    final String fullName = filenameFor(
      subjectName: subjectName,
      sessionTitle: sessionTitle,
      toolLabel: 'Polish',
      variant: 'Analysis',
    );
    final String fullText = polish.toFullAnalysisText();

    await showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext sheetCtx) {
        Future<void> close() async => Navigator.of(sheetCtx).pop();
        void snack(String msg) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(msg)),
          );
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(height: YveSpacing.sm),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: YveColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: YveSpacing.md),
              const _SheetSectionLabel('Polished draft'),
              ListTile(
                leading: const Icon(Icons.copy_rounded,
                    color: YveColors.primary),
                title: const Text('Copy'),
                onTap: () async {
                  await close();
                  await svc.copyToClipboard(polish.polishedText);
                  snack('Polished draft copied.');
                },
              ),
              ListTile(
                leading: const Icon(Icons.description_rounded,
                    color: YveColors.primary),
                title: const Text('Save as Word'),
                onTap: () async {
                  await close();
                  try {
                    await svc.shareAsWordDoc(
                      markdownText: polish.polishedText,
                      filename: polishedName,
                    );
                  } catch (e) {
                    snack(AppError.from(e, actionContext: 'polish_export').userMessage);
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.text_snippet_rounded,
                    color: YveColors.primary),
                title: const Text('Save as Markdown'),
                onTap: () async {
                  await close();
                  try {
                    await svc.shareAsMarkdown(
                      text: polish.polishedText,
                      filename: polishedName,
                    );
                  } catch (e) {
                    snack(AppError.from(e, actionContext: 'polish_export').userMessage);
                  }
                },
              ),
              const Divider(height: YveSpacing.lg),
              const _SheetSectionLabel('Full analysis'),
              ListTile(
                leading: const Icon(Icons.copy_rounded,
                    color: YveColors.textSecondary),
                title: const Text('Copy'),
                subtitle: const Text('Draft + changes + notes'),
                onTap: () async {
                  await close();
                  await svc.copyToClipboard(fullText);
                  snack('Full analysis copied.');
                },
              ),
              ListTile(
                leading: const Icon(Icons.description_rounded,
                    color: YveColors.textSecondary),
                title: const Text('Save as Word'),
                onTap: () async {
                  await close();
                  try {
                    await svc.shareAsWordDoc(
                      markdownText: fullText,
                      filename: fullName,
                    );
                  } catch (e) {
                    snack(AppError.from(e, actionContext: 'polish_export').userMessage);
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.text_snippet_rounded,
                    color: YveColors.textSecondary),
                title: const Text('Save as Markdown'),
                onTap: () async {
                  await close();
                  try {
                    await svc.shareAsMarkdown(
                      text: fullText,
                      filename: fullName,
                    );
                  } catch (e) {
                    snack(AppError.from(e, actionContext: 'polish_export').userMessage);
                  }
                },
              ),
              const SizedBox(height: YveSpacing.md),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Wrap (not Row) so the two pills flow to a second line on narrow
    // bubble widths instead of overflowing and collapsing the layout.
    return Wrap(
      spacing: YveSpacing.sm,
      runSpacing: YveSpacing.sm,
      children: <Widget>[
        FilledButton.icon(
          onPressed: () => _copyPolished(context),
          icon: const Icon(Icons.copy_rounded, size: 16),
          label: const Text('Copy polished draft'),
          style: FilledButton.styleFrom(
            backgroundColor: YveColors.primary,
            foregroundColor: YveColors.textInverse,
            padding: const EdgeInsets.symmetric(
              horizontal: YveSpacing.md,
              vertical: 10,
            ),
            shape: const StadiumBorder(),
            textStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        OutlinedButton.icon(
          onPressed: () => _openMore(context),
          icon: const Icon(Icons.more_horiz_rounded, size: 16),
          label: const Text('More'),
          style: OutlinedButton.styleFrom(
            foregroundColor: YveColors.textSecondary,
            side: const BorderSide(color: YveColors.border, width: 1.5),
            padding: const EdgeInsets.symmetric(
              horizontal: YveSpacing.md,
              vertical: 10,
            ),
            shape: const StadiumBorder(),
            textStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _SheetSectionLabel extends StatelessWidget {
  const _SheetSectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        YveSpacing.lg,
        YveSpacing.sm,
        YveSpacing.lg,
        4,
      ),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: YveColors.textTertiary,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: YveColors.textTertiary,
        letterSpacing: 0.8,
      ),
    );
  }
}

class _ChangeRow extends StatelessWidget {
  const _ChangeRow({required this.change});
  final PolishChange change;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: YveSpacing.sm),
      padding: const EdgeInsets.all(YveSpacing.md),
      decoration: BoxDecoration(
        color: YveColors.surface2,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          RichText(
            text: TextSpan(
              style: const TextStyle(
                fontSize: 13,
                color: YveColors.textPrimary,
                height: 1.5,
              ),
              children: <TextSpan>[
                TextSpan(
                  text: '"${change.original}"',
                  style: const TextStyle(
                    color: YveColors.textSecondary,
                    decoration: TextDecoration.lineThrough,
                  ),
                ),
                const TextSpan(text: '  →  '),
                TextSpan(
                  text: '"${change.revision}"',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: YveColors.primary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            change.reason,
            style: const TextStyle(
              fontSize: 12,
              color: YveColors.textSecondary,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _BulletLine extends StatelessWidget {
  const _BulletLine({required this.text, required this.accentColor});
  final String text;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            margin: const EdgeInsets.only(top: 6),
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              color: accentColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: YveSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 13,
                color: YveColors.textPrimary,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FollowUpChip extends StatelessWidget {
  const _FollowUpChip({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: YveColors.surface,
      borderRadius: YveSpacing.pillRadius,
      child: InkWell(
        borderRadius: YveSpacing.pillRadius,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: YveSpacing.pillRadius,
            border: Border.all(color: YveColors.border, width: 1.5),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: YveColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
