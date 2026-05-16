import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/scan_result.dart';
import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';

/// Bottom sheet shown immediately after a successful vision-ingest. The
/// thumbnail anchors the moment; the one-line summary tells the learner
/// Yve actually understood what they handed her; the action ladder routes
/// them into the right chat with one tap.
Future<ScanAction?> showScanResultSheet(
  BuildContext context, {
  required ScanResult result,
  Uint8List? imageBytes,
  VoidCallback? onTypeInstead,
}) {
  return showModalBottomSheet<ScanAction>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ScanResultSheet(
      result: result,
      imageBytes: imageBytes,
      onTypeInstead: onTypeInstead,
    ),
  );
}

class _ScanResultSheet extends StatelessWidget {
  const _ScanResultSheet({
    required this.result,
    this.imageBytes,
    this.onTypeInstead,
  });

  final ScanResult result;
  final Uint8List? imageBytes;
  final VoidCallback? onTypeInstead;

  @override
  Widget build(BuildContext context) {
    final double topInset = MediaQuery.of(context).padding.top;
    return DraggableScrollableSheet(
      initialChildSize: 0.78,
      minChildSize: 0.55,
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
          child: Column(
            children: <Widget>[
              const _Handle(),
              Expanded(
                child: ListView(
                  controller: scroll,
                  padding: const EdgeInsets.fromLTRB(
                    YveSpacing.xl,
                    YveSpacing.md,
                    YveSpacing.xl,
                    YveSpacing.xl,
                  ),
                  children: <Widget>[
                    _Hero(result: result, imageBytes: imageBytes),
                    const SizedBox(height: YveSpacing.lg),
                    Text(
                      result.oneLineSummary,
                      style: Theme.of(ctx).textTheme.titleMedium,
                    ),
                    if (result.conceptTags.isNotEmpty) ...<Widget>[
                      const SizedBox(height: YveSpacing.md),
                      _ConceptChips(tags: result.conceptTags),
                    ],
                    const SizedBox(height: YveSpacing.xl),
                    if (result.actions.isNotEmpty)
                      _ActionLadder(
                        actions: result.actions,
                        onTap: (ScanAction a) {
                          HapticFeedback.lightImpact();
                          Navigator.of(ctx).pop(a);
                        },
                      ),
                    if (result.saveToSubjectSuggestion != null) ...<Widget>[
                      const SizedBox(height: YveSpacing.md),
                      _SaveHint(subject: result.saveToSubjectSuggestion!),
                    ],
                    const SizedBox(height: YveSpacing.xl),
                    Center(
                      child: TextButton(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          onTypeInstead?.call();
                        },
                        child: const Text('Type instead'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Placeholder thumbnail for non-image scans (e.g. PDFs). Uses the document
/// type's tint + icon to keep the moment visually anchored.
class _DocumentThumbnail extends StatelessWidget {
  const _DocumentThumbnail({required this.documentType});
  final DocumentType documentType;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: documentType.tint,
      alignment: Alignment.center,
      child: Icon(
        documentType.icon,
        size: 40,
        color: documentType.accent,
      ),
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

class _Hero extends StatelessWidget {
  const _Hero({required this.result, this.imageBytes});

  final ScanResult result;
  final Uint8List? imageBytes;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: 86,
            height: 110,
            child: imageBytes != null
                ? Image.memory(imageBytes!, fit: BoxFit.cover)
                : _DocumentThumbnail(documentType: result.documentType),
          ),
        ),
        const SizedBox(width: YveSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: result.documentType.tint,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      result.documentType.icon,
                      size: 12,
                      color: result.documentType.accent,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      result.documentType.label,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: result.documentType.accent,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: YveSpacing.sm),
              Row(
                children: const <Widget>[
                  Icon(Icons.auto_awesome,
                      size: 12, color: YveColors.accent),
                  SizedBox(width: 4),
                  Text(
                    'YVE READ THIS',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: YveColors.accent,
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Pick a next step below — or open the chat to ask anything about it.',
                style: TextStyle(
                  fontSize: 12,
                  color: YveColors.textSecondary,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ConceptChips extends StatelessWidget {
  const _ConceptChips({required this.tags});
  final List<String> tags;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final String t in tags)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: YveColors.primarySurface,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              t,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: YveColors.primary,
              ),
            ),
          ),
      ],
    );
  }
}

class _ActionLadder extends StatelessWidget {
  const _ActionLadder({required this.actions, required this.onTap});

  final List<ScanAction> actions;
  final ValueChanged<ScanAction> onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < actions.length; i++) ...<Widget>[
          _ActionTile(
            action: actions[i],
            primary: i == 0,
            onTap: () => onTap(actions[i]),
          ),
          if (i < actions.length - 1) const SizedBox(height: YveSpacing.sm),
        ],
      ],
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.action,
    required this.primary,
    required this.onTap,
  });

  final ScanAction action;
  final bool primary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (primary) {
      return Material(
        color: YveColors.primary,
        borderRadius: YveSpacing.cardRadius,
        child: InkWell(
          onTap: onTap,
          borderRadius: YveSpacing.cardRadius,
          child: Container(
            padding: const EdgeInsets.all(YveSpacing.lg),
            decoration: const BoxDecoration(
              gradient: YveColors.brandGradient,
              borderRadius: YveSpacing.cardRadius,
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0x33FFFFFF),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child:
                      Icon(action.kind.icon, color: YveColors.textInverse),
                ),
                const SizedBox(width: YveSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        action.label,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: YveColors.textInverse,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        action.mode.label,
                        style: const TextStyle(
                          fontSize: 12,
                          color: YveColors.textOnGradient,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.arrow_forward_rounded,
                    color: YveColors.textInverse),
              ],
            ),
          ),
        ),
      );
    }

    return Material(
      color: YveColors.surface,
      borderRadius: YveSpacing.cardRadius,
      child: InkWell(
        onTap: onTap,
        borderRadius: YveSpacing.cardRadius,
        child: Container(
          padding: const EdgeInsets.all(YveSpacing.md),
          decoration: BoxDecoration(
            borderRadius: YveSpacing.cardRadius,
            border: Border.all(color: YveColors.border),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: action.mode.tint,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(action.kind.icon,
                    color: action.mode.iconColor, size: 18),
              ),
              const SizedBox(width: YveSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      action.label,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      action.mode.label,
                      style: const TextStyle(
                        fontSize: 12,
                        color: YveColors.textSecondary,
                      ),
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

class _SaveHint extends StatelessWidget {
  const _SaveHint({required this.subject});
  final String subject;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(YveSpacing.md),
      decoration: BoxDecoration(
        color: YveColors.primarySurface,
        borderRadius: YveSpacing.cardRadius,
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.auto_awesome,
              size: 14, color: YveColors.primaryLight),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Looks like this belongs to $subject. Yve will offer to save it once you start chatting.',
              style: const TextStyle(
                fontSize: 12,
                color: YveColors.primary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
