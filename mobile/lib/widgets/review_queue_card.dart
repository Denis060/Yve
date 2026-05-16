import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/concept_review.dart';
import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';

/// A single "revisit this concept" row on Home. Tapping launches a
/// practice-mode chat pre-seeded with "Quiz me on X", which is how the
/// retention loop closes — fresh observation written, next_due_at advances.
class ReviewRow extends StatelessWidget {
  const ReviewRow({super.key, required this.review, required this.onTap});

  final ConceptReview review;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Material(
      color: YveColors.surface,
      borderRadius: YveSpacing.cardRadius,
      child: InkWell(
        borderRadius: YveSpacing.cardRadius,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: YveSpacing.lg,
            vertical: 14,
          ),
          decoration: BoxDecoration(
            borderRadius: YveSpacing.cardRadius,
            boxShadow: YveSpacing.cardShadow,
            color: YveColors.surface,
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: YveColors.primarySurface,
                  borderRadius: BorderRadius.circular(11),
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.refresh_rounded,
                  size: 18,
                  color: YveColors.primary,
                ),
              ),
              const SizedBox(width: YveSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      review.concept,
                      style: text.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: <Widget>[
                        if (review.subjectName != null) ...<Widget>[
                          Text(
                            '${review.subjectEmoji ?? '✦'} ${review.subjectName!}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: YveColors.textSecondary,
                            ),
                          ),
                          const Text(
                            '  ·  ',
                            style: TextStyle(
                              fontSize: 12,
                              color: YveColors.textTertiary,
                            ),
                          ),
                        ],
                        Text(
                          review.dueLabel,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: YveColors.accent,
                          ),
                        ),
                      ],
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
    );
  }
}
