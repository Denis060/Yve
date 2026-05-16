import 'package:flutter/foundation.dart';

/// User-visible plan tier. v1 ships three Pro cadences plus the
/// 3-day trial (which renders to the user as "Pro Trial" but resolves
/// to Pro caps everywhere it matters).
enum Plan { free, proTrial, proMonthly, proSemester, proAnnual }

extension PlanX on Plan {
  /// Wire (database / Stripe) identifier — matches plan_limits.plan_code.
  String get wire => switch (this) {
        Plan.free => 'free',
        Plan.proTrial => 'pro_trial',
        Plan.proMonthly => 'pro_monthly',
        Plan.proSemester => 'pro_semester',
        Plan.proAnnual => 'pro_annual',
      };

  /// Short display label for badges + settings.
  String get label => switch (this) {
        Plan.free => 'Free',
        Plan.proTrial => 'Pro Trial',
        Plan.proMonthly => 'Pro Monthly',
        Plan.proSemester => 'Pro Semester',
        Plan.proAnnual => 'Pro Annual',
      };

  /// True for any paid-or-trialing tier. Most product code only needs
  /// "is this user Pro?" — use this rather than enumerating tiers.
  bool get isPro => this != Plan.free;

  static Plan fromWire(String? value) {
    return switch (value) {
      'free' => Plan.free,
      'pro_trial' => Plan.proTrial,
      'pro_monthly' => Plan.proMonthly,
      'pro_semester' => Plan.proSemester,
      'pro_annual' => Plan.proAnnual,
      // Backwards-compat: pre-Phase-1 schema used 'plus' as the wire
      // value. Anyone on that legacy row reads as Pro Monthly.
      'plus' => Plan.proMonthly,
      _ => Plan.free,
    };
  }
}

enum EntitlementStatus { active, trialing, pastDue, canceled, paused, incomplete }

extension EntitlementStatusX on EntitlementStatus {
  String get wire => switch (this) {
        EntitlementStatus.active => 'active',
        EntitlementStatus.trialing => 'trialing',
        EntitlementStatus.pastDue => 'past_due',
        EntitlementStatus.canceled => 'canceled',
        EntitlementStatus.paused => 'paused',
        EntitlementStatus.incomplete => 'incomplete',
      };

  static EntitlementStatus fromWire(String? value) {
    return switch (value) {
      'active' => EntitlementStatus.active,
      'trialing' => EntitlementStatus.trialing,
      'past_due' => EntitlementStatus.pastDue,
      'canceled' => EntitlementStatus.canceled,
      'paused' => EntitlementStatus.paused,
      'incomplete' => EntitlementStatus.incomplete,
      _ => EntitlementStatus.active,
    };
  }
}

/// Current plan + status for the authed user. Default for everyone who
/// hasn't upgraded (and for anonymous users) is `(Plan.free, active)`.
@immutable
class Entitlement {
  const Entitlement({
    required this.plan,
    required this.status,
    this.currentPeriodEnd,
    this.trialEnd,
    this.cancelAtPeriodEnd = false,
  });

  final Plan plan;
  final EntitlementStatus status;
  final DateTime? currentPeriodEnd;
  final DateTime? trialEnd;
  final bool cancelAtPeriodEnd;

  static const Entitlement freeDefault = Entitlement(
    plan: Plan.free,
    status: EntitlementStatus.active,
  );

  /// True for any tier that grants Pro caps right now — paid OR
  /// trialing OR past_due (Stripe's 21-day retry grace). Canceled and
  /// paused users drop back to Free; this returns false for them.
  bool get isPro =>
      plan.isPro &&
      (status == EntitlementStatus.active ||
          status == EntitlementStatus.trialing ||
          status == EntitlementStatus.pastDue ||
          status == EntitlementStatus.incomplete);

  /// Legacy alias for code paths that still call `isPlus`. Same meaning.
  bool get isPlus => isPro;

  factory Entitlement.fromRow(Map<String, dynamic> row) {
    final String? endRaw = row['current_period_end'] as String?;
    final String? trialRaw = row['trial_end'] as String?;
    return Entitlement(
      // Phase-1 migration renamed `plan` to `plan_code`. Read the new
      // column with a fallback to the old key for any cached row.
      plan: PlanX.fromWire(
        (row['plan_code'] as String?) ?? (row['plan'] as String?),
      ),
      status: EntitlementStatusX.fromWire(row['status'] as String?),
      currentPeriodEnd: endRaw == null ? null : DateTime.parse(endRaw),
      trialEnd: trialRaw == null ? null : DateTime.parse(trialRaw),
      cancelAtPeriodEnd: (row['cancel_at_period_end'] as bool?) ?? false,
    );
  }
}

/// Which cap fired. Drives the headline + framing on the cap-hit
/// screen — "you're out of daily chats" hits differently than "your
/// draft is too long for free." `word` and `scan` and `subjects` are
/// declared so the parser is forward-compatible with caps not yet
/// wired in v1.
enum CapKind { chat, polish, word, scan, subjects }

extension CapKindX on CapKind {
  static CapKind fromWire(String? wire) {
    return switch (wire) {
      'chat' => CapKind.chat,
      'polish' => CapKind.polish,
      'word' => CapKind.word,
      'scan' => CapKind.scan,
      'subjects' => CapKind.subjects,
      _ => CapKind.chat,
    };
  }
}

/// Snapshot of "you've hit the cap" — produced by the chat stream when
/// the server refuses a turn. Carries everything the conversion-moment
/// screen needs to render context-aware copy and the right CTA.
///
/// [resetAtUtc] is null for the word cap (no time-based reset — upgrade
/// is the only path forward).
@immutable
class QuotaExceeded {
  const QuotaExceeded({
    required this.plan,
    required this.kind,
    required this.used,
    required this.limit,
    this.resetAtUtc,
    this.mode,
    this.sessionId,
    this.sessionTitle,
    this.turnsThisSession,
    this.primaryConcept,
    this.draftPreview,
  });

  final Plan plan;
  final CapKind kind;
  final int used;
  final int limit;
  final DateTime? resetAtUtc;

  // Contextual fields — present when the server can attribute the
  // cap-hit to in-progress work. The screen falls back to generic copy
  // when these are null.
  final String? mode;
  final String? sessionId;
  final String? sessionTitle;
  final int? turnsThisSession;
  final String? primaryConcept;
  // For polish/word caps, the first ~80 chars of what the learner was
  // trying to polish. Renders as "Your draft: 'Social media has…'"
  final String? draftPreview;

  /// Friendly relative time to the next reset, in the learner's local
  /// zone. Empty string when [resetAtUtc] is null (word cap).
  String get resetRelative {
    final DateTime? at = resetAtUtc;
    if (at == null) return '';
    final Duration until = at.toLocal().difference(DateTime.now());
    if (until.inMinutes <= 0) return 'any moment now';
    if (until.inHours < 1) return 'in ${until.inMinutes} min';
    if (until.inHours < 24) return 'in ${until.inHours} hours';
    if (until.inDays < 7) return 'in ${until.inDays} days';
    return 'next week';
  }

  /// True when the server provided enough context to render the
  /// "you and Yve were N turns into <title>" headline. Falls back to
  /// generic copy when false.
  bool get hasSessionContext =>
      sessionTitle != null && (turnsThisSession ?? 0) > 0;
}
