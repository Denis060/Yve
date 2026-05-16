// Entitlement + quota helpers — the single read path for "what is this
// user allowed to do right now?"
//
// Resolution flow (all inside loadEntitlement):
//   1. Read subscriptions row → plan_code + status. No row = 'free'.
//   2. Read plan_limits[plan_code] → base caps for the tier.
//   3. Read user_limit_overrides[user_id] → overlay any non-null fields,
//      ignoring overrides whose expires_at is in the past.
//   4. Return { planCode, status, caps } where caps has every cap field
//      resolved to a number-or-null. NULL = unlimited (modulo the
//      fair-use hard_daily_message_cap, which is a number even on Pro).
//
// Quota state functions (loadChatQuota / loadScanQuota / loadPolishQuota)
// take a resolved Entitlement and return whether the user is over the
// relevant cap, plus the values the cap-hit UX needs to render
// ("you've used 10/10 chats today, resets at midnight UTC").
//
// All writes (increments + cap-hit logging) are best-effort: a failed
// counter bump shouldn't block the user's turn going through.

import type { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';

import { getServiceClient } from './service_client.ts';

// ─────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────

export type PlanCode =
  | 'free'
  | 'pro_trial'
  | 'pro_monthly'
  | 'pro_semester'
  | 'pro_annual';

export type SubStatus =
  | 'active'
  | 'trialing'
  | 'past_due'
  | 'canceled'
  | 'paused'
  | 'incomplete';

/// Resolved caps for a single user. `null` means "unlimited" for that
/// cap. The hard_daily_message_cap is always a number — it's the
/// fair-use ceiling that even Pro can't exceed.
export interface PlanCaps {
  chatMessagesPerDay: number | null;
  scansPerDay: number | null;
  polishRunsPerWeek: number | null;
  polishRunsPerDay: number | null;
  polishMaxWords: number;
  subjectsMax: number | null;
  storageMb: number | null;
  hardDailyMessageCap: number | null;
}

export interface Entitlement {
  planCode: PlanCode;
  status: SubStatus;
  caps: PlanCaps;
  // True if this user is on a paid tier (or trialing one). Used to
  // decide things like "should we increment the counter at all" — on
  // unlimited tiers we still bump for telemetry, but we don't gate.
  isPaid: boolean;
}

export interface QuotaState {
  exceeded: boolean;
  used: number;
  // The cap that applied — handy for the cap-hit UX ("10 / 10").
  limit: number | null; // null = unlimited
  resetAtUtc: string; // ISO timestamp of the next boundary
}

// ─────────────────────────────────────────────────────────────────────
// Internal — raw row shapes returned by Supabase
// ─────────────────────────────────────────────────────────────────────

interface PlanLimitsRow {
  plan_code: string;
  chat_messages_per_day: number | null;
  scans_per_day: number | null;
  polish_runs_per_week: number | null;
  polish_runs_per_day: number | null;
  polish_max_words: number | null;
  subjects_max: number | null;
  storage_mb: number | null;
  hard_daily_message_cap: number | null;
}

interface OverrideRow {
  chat_messages_per_day: number | null;
  scans_per_day: number | null;
  polish_runs_per_week: number | null;
  polish_runs_per_day: number | null;
  polish_max_words: number | null;
  subjects_max: number | null;
  storage_mb: number | null;
  hard_daily_message_cap: number | null;
  expires_at: string | null;
}

// ─────────────────────────────────────────────────────────────────────
// Resolver
// ─────────────────────────────────────────────────────────────────────

/// Resolve the full entitlement for a user. Lazy-defaults to free/active
/// when no subscriptions row exists yet — important because anonymous
/// users and brand-new signups hit yve-chat before they've touched the
/// upgrade flow.
///
/// All reads use the service client. Entitlement is privileged
/// server-side state; routing it through the user's RLS context was
/// observed to silently drop the SELECT (and resolve users as Free
/// even when they had an active Pro subscription). The `client`
/// parameter is kept for backwards compatibility with existing
/// callsites; it's no longer used here.
export async function loadEntitlement(
  _unused: SupabaseClient,
  userId: string,
): Promise<Entitlement> {
  const svc = getServiceClient();
  let planCode: PlanCode = 'free';
  let status: SubStatus = 'active';

  try {
    const { data, error } = await svc
      .from('subscriptions')
      .select('plan_code, status')
      .eq('user_id', userId)
      .in('status', ['active', 'trialing', 'past_due', 'incomplete'])
      .maybeSingle();
    if (error) console.error('loadEntitlement: select error', error);
    if (data) {
      planCode = (data.plan_code as PlanCode) ?? 'free';
      status = (data.status as SubStatus) ?? 'active';
    }
  } catch (e) {
    console.error('loadEntitlement: subscriptions read failed', e);
  }

  const base = await loadPlanLimits(svc, planCode);
  const override = await loadOverride(svc, userId);
  const caps = mergeCaps(base, override);

  // "Paid-or-trialing" is the only meaningful binary for gating. A
  // past_due user keeps Pro features through Stripe's 21-day retry
  // window; an incomplete (mid-SetupIntent) user has paid intent but
  // hasn't confirmed yet — for v1 we treat them as Pro on a short
  // optimistic window. Canceled drops to free via the row no longer
  // matching the IN-list above (so this code path won't see it).
  const isPaid = planCode !== 'free';

  return { planCode, status, caps, isPaid };
}

async function loadPlanLimits(
  client: SupabaseClient,
  planCode: PlanCode,
): Promise<PlanLimitsRow> {
  try {
    const { data } = await client
      .from('plan_limits')
      .select(
        'plan_code, chat_messages_per_day, scans_per_day, polish_runs_per_week, polish_runs_per_day, polish_max_words, subjects_max, storage_mb, hard_daily_message_cap',
      )
      .eq('plan_code', planCode)
      .maybeSingle();
    if (data) return data as PlanLimitsRow;
  } catch (e) {
    console.error(`loadPlanLimits(${planCode}) failed`, e);
  }
  // Fallback if plan_limits is somehow empty — be conservative, not
  // generous. This should never happen in a working environment.
  return {
    plan_code: planCode,
    chat_messages_per_day: 10,
    scans_per_day: 3,
    polish_runs_per_week: 1,
    polish_runs_per_day: null,
    polish_max_words: 300,
    subjects_max: 1,
    storage_mb: 25,
    hard_daily_message_cap: null,
  };
}

async function loadOverride(
  client: SupabaseClient,
  userId: string,
): Promise<OverrideRow | null> {
  try {
    const { data } = await client
      .from('user_limit_overrides')
      .select(
        'chat_messages_per_day, scans_per_day, polish_runs_per_week, polish_runs_per_day, polish_max_words, subjects_max, storage_mb, hard_daily_message_cap, expires_at',
      )
      .eq('user_id', userId)
      .maybeSingle();
    if (!data) return null;
    const expiresAt = (data as OverrideRow).expires_at;
    if (expiresAt && new Date(expiresAt).getTime() < Date.now()) {
      // Expired override — ignore.
      return null;
    }
    return data as OverrideRow;
  } catch (e) {
    console.error('loadOverride failed', e);
    return null;
  }
}

/// Overlay non-null override fields onto the plan base. The semantics:
///   override field is NULL → use plan value
///   override field is non-NULL → use override value (including 0 and
///                                 explicitly-"unlimited" cases where
///                                 someone wants to bump a free user)
function mergeCaps(
  base: PlanLimitsRow,
  override: OverrideRow | null,
): PlanCaps {
  const pick = <K extends keyof OverrideRow>(
    key: K,
  ): OverrideRow[K] => {
    if (override && override[key] !== null && override[key] !== undefined) {
      return override[key];
    }
    return base[key as keyof PlanLimitsRow] as OverrideRow[K];
  };
  return {
    chatMessagesPerDay: pick('chat_messages_per_day'),
    scansPerDay: pick('scans_per_day'),
    polishRunsPerWeek: pick('polish_runs_per_week'),
    polishRunsPerDay: pick('polish_runs_per_day'),
    polishMaxWords: (pick('polish_max_words') as number | null) ?? 300,
    subjectsMax: pick('subjects_max'),
    storageMb: pick('storage_mb'),
    hardDailyMessageCap: pick('hard_daily_message_cap'),
  };
}

// ─────────────────────────────────────────────────────────────────────
// Quota state — chat
// ─────────────────────────────────────────────────────────────────────

/// Reads today's chat-turn count and returns the resolved quota state.
/// Two ceilings apply: the per-tier cap, and the fair-use cap. The
/// effective limit is the minimum of the two (handling nulls). When
/// both are null the user is truly unlimited.
export async function loadChatQuota(
  client: SupabaseClient,
  userId: string,
  caps: PlanCaps,
): Promise<QuotaState> {
  const today = utcDayString();
  const limit = minLimit(caps.chatMessagesPerDay, caps.hardDailyMessageCap);

  let used = 0;
  try {
    const { data } = await client
      .from('daily_usage')
      .select('chat_turns')
      .eq('user_id', userId)
      .eq('day', today)
      .maybeSingle();
    used = (data?.chat_turns as number | undefined) ?? 0;
  } catch (e) {
    console.error('loadChatQuota failed', e);
  }

  return {
    exceeded: limit !== null && used >= limit,
    used,
    limit,
    resetAtUtc: nextUtcMidnight(),
  };
}

// ─────────────────────────────────────────────────────────────────────
// Quota state — scans
// ─────────────────────────────────────────────────────────────────────

export async function loadScanQuota(
  client: SupabaseClient,
  userId: string,
  caps: PlanCaps,
): Promise<QuotaState> {
  const today = utcDayString();
  const limit = caps.scansPerDay;

  let used = 0;
  try {
    const { data } = await client
      .from('daily_usage')
      .select('scan_count')
      .eq('user_id', userId)
      .eq('day', today)
      .maybeSingle();
    used = (data?.scan_count as number | undefined) ?? 0;
  } catch (e) {
    console.error('loadScanQuota failed', e);
  }

  return {
    exceeded: limit !== null && used >= limit,
    used,
    limit,
    resetAtUtc: nextUtcMidnight(),
  };
}

// ─────────────────────────────────────────────────────────────────────
// Quota state — polish (weekly cap OR daily cap, depending on tier)
// ─────────────────────────────────────────────────────────────────────

/// Polish caps come in two flavors: weekly (free) and daily (trial).
/// Pro tiers are unlimited (subject to fair-use). The shape of the
/// returned QuotaState mirrors whichever cap actually applies — the
/// caller doesn't need to know which window was used.
export async function loadPolishQuota(
  client: SupabaseClient,
  userId: string,
  caps: PlanCaps,
): Promise<QuotaState> {
  // Daily cap takes precedence when both are set (trial = 5/day,
  // weekly = null). For free (weekly = 1, daily = null) we fall
  // through to the weekly branch.
  if (caps.polishRunsPerDay !== null) {
    return loadPolishDailyQuota(client, userId, caps.polishRunsPerDay);
  }
  if (caps.polishRunsPerWeek !== null) {
    return loadPolishWeeklyQuota(client, userId, caps.polishRunsPerWeek);
  }
  // Both null = unlimited.
  return {
    exceeded: false,
    used: 0,
    limit: null,
    resetAtUtc: nextUtcMidnight(),
  };
}

async function loadPolishDailyQuota(
  client: SupabaseClient,
  userId: string,
  limit: number,
): Promise<QuotaState> {
  // For daily polish caps we piggy-back on a simple count of today's
  // polish_run usage_events rows. Cheap, accurate, no extra table.
  const since = utcStartOfToday();
  let used = 0;
  try {
    const { count } = await client
      .from('usage_events')
      .select('*', { count: 'exact', head: true })
      .eq('user_id', userId)
      .eq('kind', 'polish_run')
      .gte('occurred_at', since);
    used = count ?? 0;
  } catch (e) {
    console.error('loadPolishDailyQuota failed', e);
  }
  return {
    exceeded: used >= limit,
    used,
    limit,
    resetAtUtc: nextUtcMidnight(),
  };
}

async function loadPolishWeeklyQuota(
  client: SupabaseClient,
  userId: string,
  limit: number,
): Promise<QuotaState> {
  const weekStart = isoWeekStartUtc();
  let used = 0;
  try {
    const { data } = await client
      .from('weekly_usage')
      .select('polish_runs')
      .eq('user_id', userId)
      .eq('week_start', weekStart)
      .maybeSingle();
    used = (data?.polish_runs as number | undefined) ?? 0;
  } catch (e) {
    console.error('loadPolishWeeklyQuota failed', e);
  }
  return {
    exceeded: used >= limit,
    used,
    limit,
    resetAtUtc: nextIsoWeekStartUtc(),
  };
}

// ─────────────────────────────────────────────────────────────────────
// Counter bumps (best-effort)
// ─────────────────────────────────────────────────────────────────────

// All writes go through the service-role client. The standard yve-chat
// client passes the user's Authorization through, which causes RLS to
// evaluate as the user — fine for chat_messages (self-insert policy
// exists) but silently no-ops for daily_usage / weekly_usage /
// usage_events / subscriptions (server-only writes by design).

export async function incrementChatTurns(
  _unused: SupabaseClient,
  userId: string,
): Promise<void> {
  const svc = getServiceClient();
  const today = utcDayString();
  try {
    const { data } = await svc
      .from('daily_usage')
      .select('chat_turns')
      .eq('user_id', userId)
      .eq('day', today)
      .maybeSingle();
    const current = (data?.chat_turns as number | undefined) ?? 0;
    const { error } = await svc.from('daily_usage').upsert(
      { user_id: userId, day: today, chat_turns: current + 1 },
      { onConflict: 'user_id,day' },
    );
    if (error) console.error('incrementChatTurns upsert error', error);
    await logUsageEvent(userId, 'chat_turn');
  } catch (e) {
    console.error('incrementChatTurns failed', e);
  }
}

export async function incrementScans(
  _unused: SupabaseClient,
  userId: string,
): Promise<void> {
  const svc = getServiceClient();
  const today = utcDayString();
  try {
    const { data } = await svc
      .from('daily_usage')
      .select('scan_count')
      .eq('user_id', userId)
      .eq('day', today)
      .maybeSingle();
    const current = (data?.scan_count as number | undefined) ?? 0;
    const { error } = await svc.from('daily_usage').upsert(
      { user_id: userId, day: today, scan_count: current + 1 },
      { onConflict: 'user_id,day' },
    );
    if (error) console.error('incrementScans upsert error', error);
    await logUsageEvent(userId, 'scan_run');
  } catch (e) {
    console.error('incrementScans failed', e);
  }
}

export async function incrementPolishRuns(
  _unused: SupabaseClient,
  userId: string,
): Promise<void> {
  const svc = getServiceClient();
  const weekStart = isoWeekStartUtc();
  try {
    const { data } = await svc
      .from('weekly_usage')
      .select('polish_runs')
      .eq('user_id', userId)
      .eq('week_start', weekStart)
      .maybeSingle();
    const current = (data?.polish_runs as number | undefined) ?? 0;
    const { error } = await svc.from('weekly_usage').upsert(
      { user_id: userId, week_start: weekStart, polish_runs: current + 1 },
      { onConflict: 'user_id,week_start' },
    );
    if (error) console.error('incrementPolishRuns upsert error', error);
    await logUsageEvent(userId, 'polish_run');
  } catch (e) {
    console.error('incrementPolishRuns failed', e);
  }
}

/// Log a cap-hit event for tuning + the cap-hit UX. Pass the user's
/// resolved planCode so we can group "free vs trial vs paid" usage in
/// rollups later. Best-effort.
export async function logUsageEvent(
  userId: string,
  kind:
    | 'chat_turn'
    | 'chat_cap_hit'
    | 'scan_run'
    | 'scan_cap_hit'
    | 'polish_run'
    | 'polish_cap_hit'
    | 'subject_cap_hit'
    | 'storage_cap_hit',
  metadata?: Record<string, unknown>,
  planCode?: PlanCode,
): Promise<void> {
  try {
    const { error } = await getServiceClient().from('usage_events').insert({
      user_id: userId,
      kind,
      plan_code: planCode ?? null,
      metadata: metadata ?? null,
    });
    if (error) console.error(`logUsageEvent(${kind}) insert error`, error);
  } catch (e) {
    console.error(`logUsageEvent(${kind}) failed`, e);
  }
}

// ─────────────────────────────────────────────────────────────────────
// Time helpers
// ─────────────────────────────────────────────────────────────────────

function utcDayString(): string {
  return new Date().toISOString().slice(0, 10);
}

function utcStartOfToday(): string {
  const d = new Date();
  d.setUTCHours(0, 0, 0, 0);
  return d.toISOString();
}

function nextUtcMidnight(): string {
  const d = new Date();
  d.setUTCHours(24, 0, 0, 0);
  return d.toISOString();
}

/// Monday 00:00 UTC of the current ISO week, as a YYYY-MM-DD date
/// string. Used as the week_start primary key for weekly_usage.
function isoWeekStartUtc(): string {
  const d = new Date();
  d.setUTCHours(0, 0, 0, 0);
  // getUTCDay() returns 0 for Sunday; we want Monday to be the start.
  const day = d.getUTCDay();
  const offsetToMonday = day === 0 ? -6 : 1 - day;
  d.setUTCDate(d.getUTCDate() + offsetToMonday);
  return d.toISOString().slice(0, 10);
}

function nextIsoWeekStartUtc(): string {
  const d = new Date(isoWeekStartUtc());
  d.setUTCDate(d.getUTCDate() + 7);
  return d.toISOString();
}

/// Returns the smaller of two limits, ignoring nulls. Two-null → null.
function minLimit(a: number | null, b: number | null): number | null {
  if (a === null && b === null) return null;
  if (a === null) return b;
  if (b === null) return a;
  return Math.min(a, b);
}
