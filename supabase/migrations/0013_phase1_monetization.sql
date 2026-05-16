-- Yve — Phase 1 monetization foundation.
--
-- Two emotionally-segmented tiers (Monthly and Semester) plus Annual,
-- a 3-day card-required Pro Trial, and a Free tier sized to complete
-- one meaningful assignment loop without replacing the full product.
--
-- This migration is the *database source-of-truth* for plan caps and
-- subscription lifecycle. Anything in lib/billing/plans.ts is marketing
-- copy that mirrors these values — if the two drift, the DB wins.
--
-- New tables:
--   plan_limits           per-tier caps, primary key = plan_code
--   user_limit_overrides  per-user cap bumps (founder grants, comps)
--   stripe_webhook_events idempotency log (no duplicate processing)
--   usage_events          audit log of every cap bump and cap hit
--   weekly_usage          polish runs per ISO week (UTC Monday)
--
-- Evolved tables:
--   subscriptions  plan→plan_code, expanded status states, lifecycle cols
--   daily_usage    +scan_count

-- ─────────────────────────────────────────────────────────────────────
-- 1) plan_limits — source of truth for tier caps
-- ─────────────────────────────────────────────────────────────────────
-- NULL on a cap column means "unlimited" (subject to the fair-use
-- hard_daily_message_cap that protects against runaway costs).
create table if not exists public.plan_limits (
  plan_code text primary key,
  display_name text not null,
  -- Stripe price ID for paid tiers. Backfilled via the STRIPE_SETUP doc
  -- once the Stripe dashboard products are created. NULL for free + trial.
  stripe_price_id text,

  -- Visible caps the user feels.
  chat_messages_per_day  int,
  scans_per_day          int,
  polish_runs_per_week   int,
  polish_runs_per_day    int,
  polish_max_words       int,
  subjects_max           int,
  storage_mb             int,

  -- Fair-use ceiling for "unlimited" tiers. Realistic users never hit
  -- this; it exists so a single scripted account can't bankrupt us.
  hard_daily_message_cap int,

  created_at timestamptz not null default now()
);

-- Seed the five tiers. Updating cap values later → use a follow-up
-- migration that updates this seed, never a backfill script.
insert into public.plan_limits (
  plan_code, display_name, stripe_price_id,
  chat_messages_per_day, scans_per_day,
  polish_runs_per_week, polish_runs_per_day, polish_max_words,
  subjects_max, storage_mb, hard_daily_message_cap
) values
  -- Free: complete one assignment loop, feel the polish magic once.
  ('free',         'Free',         null,
   10, 3,
   1,  null, 300,
   1,  25,   null),

  -- Pro Trial: 3 days, generous enough to feel "this is what Pro is."
  ('pro_trial',    'Pro Trial',    null,
   30, 10,
   null, 5, 3000,
   null, 500, 30),

  -- Pro Monthly: flexible, short-program users (CNA, EMT, MA, etc.)
  ('pro_monthly',  'Pro Monthly',  null,
   null, null,
   null, null, 10000,
   null, 10240, 500),

  -- Pro Semester: 4 months, term-aligned for nursing/allied-health.
  ('pro_semester', 'Pro Semester', null,
   null, null,
   null, null, 10000,
   null, 10240, 500),

  -- Pro Annual: long-term commitment, best per-month price.
  ('pro_annual',   'Pro Annual',   null,
   null, null,
   null, null, 10000,
   null, 10240, 500)
on conflict (plan_code) do nothing;

-- ─────────────────────────────────────────────────────────────────────
-- 2) subscriptions — evolve plan→plan_code + Stripe lifecycle cols
-- ─────────────────────────────────────────────────────────────────────
-- Pre-launch: no production data, safe to mutate in place.
alter table public.subscriptions
  drop constraint if exists subscriptions_plan_check;

alter table public.subscriptions
  rename column plan to plan_code;

alter table public.subscriptions
  alter column plan_code set default 'free';

-- FK to plan_limits so typos can't enter (and so cascading rename
-- becomes a single-row edit).
alter table public.subscriptions
  add constraint subscriptions_plan_code_fk
  foreign key (plan_code) references public.plan_limits(plan_code);

-- Lifecycle columns Stripe webhooks populate.
alter table public.subscriptions
  add column if not exists trial_end            timestamptz,
  add column if not exists cancel_at_period_end boolean not null default false,
  add column if not exists canceled_at          timestamptz,
  -- Captured during Semester onboarding ("when are your finals?").
  -- Drives the mid-semester check-in and renewal nudge.
  add column if not exists semester_end_date    date,
  add column if not exists stripe_price_id      text;

-- Stripe lifecycle states. 'trialing' = card on file + active trial.
-- 'incomplete' = SetupIntent pending. Both grant Pro caps.
alter table public.subscriptions
  drop constraint if exists subscriptions_status_check;
alter table public.subscriptions
  add constraint subscriptions_status_check
  check (status in (
    'active', 'trialing', 'past_due', 'canceled', 'paused', 'incomplete'
  ));

-- One *paid* row per user. Free is the lazy default — we don't insert
-- a subscriptions row for free users at all; loadEntitlement falls
-- back to free when there's no row. So the unique index only needs to
-- cover the paid/trial states.
create unique index if not exists subscriptions_one_active_per_user
  on public.subscriptions(user_id)
  where status in ('active', 'trialing', 'past_due', 'incomplete');

-- ─────────────────────────────────────────────────────────────────────
-- 3) user_limit_overrides — per-user cap bumps, audited
-- ─────────────────────────────────────────────────────────────────────
-- One row per user. NULL cap = use plan default; non-NULL overrides
-- the plan default. reason + admin email are required so future you
-- can audit every grant. expires_at NULL = permanent; set a date to
-- have it auto-ignored after that point.
create table if not exists public.user_limit_overrides (
  user_id uuid primary key references auth.users(id) on delete cascade,

  chat_messages_per_day  int,
  scans_per_day          int,
  polish_runs_per_week   int,
  polish_runs_per_day    int,
  polish_max_words       int,
  subjects_max           int,
  storage_mb             int,
  hard_daily_message_cap int,

  reason                 text not null,
  granted_by_admin_email text not null,
  expires_at             timestamptz,
  created_at             timestamptz not null default now()
);

alter table public.user_limit_overrides enable row level security;
create policy "overrides_self_select" on public.user_limit_overrides
  for select using (auth.uid() = user_id);
-- writes are service-role only.

-- ─────────────────────────────────────────────────────────────────────
-- 4) stripe_webhook_events — idempotency log
-- ─────────────────────────────────────────────────────────────────────
-- Stripe retries on any non-2xx response, sometimes after we've already
-- processed an event. The webhook handler INSERTs into this table at
-- the top of the handler; a duplicate insert raises a unique-key error,
-- and we return 200 (already processed) without re-running side effects.
create table if not exists public.stripe_webhook_events (
  stripe_event_id text primary key,
  event_type      text not null,
  received_at     timestamptz not null default now(),
  processed_at    timestamptz,
  error           text
);
-- No RLS — only the webhook handler (service role) touches this.

-- ─────────────────────────────────────────────────────────────────────
-- 5) usage_events — audit log of cap bumps and hits
-- ─────────────────────────────────────────────────────────────────────
-- Every cap bump and every cap hit writes a row. Lets us:
--   - reconstruct exact usage for any user (support inbox queries)
--   - tune caps based on real distributions before launch
--   - power the cap-hit UX (recent activity → "you and Yve were…")
create table if not exists public.usage_events (
  id         bigserial primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  kind       text not null check (kind in (
    'chat_turn',
    'chat_cap_hit',
    'scan_run',
    'scan_cap_hit',
    'polish_run',
    'polish_cap_hit',
    'subject_cap_hit',
    'storage_cap_hit'
  )),
  occurred_at timestamptz not null default now(),
  plan_code   text,
  metadata    jsonb
);

create index if not exists usage_events_user_time
  on public.usage_events(user_id, occurred_at desc);
create index if not exists usage_events_kind_time
  on public.usage_events(kind, occurred_at desc);

alter table public.usage_events enable row level security;
-- writes are service-role only; users can't self-write usage events.

-- ─────────────────────────────────────────────────────────────────────
-- 6) daily_usage — track scans alongside chat turns
-- ─────────────────────────────────────────────────────────────────────
alter table public.daily_usage
  add column if not exists scan_count int not null default 0;

-- ─────────────────────────────────────────────────────────────────────
-- 7) weekly_usage — polish runs per ISO week (Monday UTC)
-- ─────────────────────────────────────────────────────────────────────
-- Polish is the only weekly-capped feature. week_start is the Monday
-- 00:00 UTC of that ISO week, so two calls on the same Wednesday both
-- write to the same row. Resolver computes it inline; no triggers.
create table if not exists public.weekly_usage (
  user_id     uuid not null references auth.users(id) on delete cascade,
  week_start  date not null,
  polish_runs int  not null default 0,
  primary key (user_id, week_start)
);

alter table public.weekly_usage enable row level security;
create policy "weekly_usage_self_select" on public.weekly_usage
  for select using (auth.uid() = user_id);
-- writes are service-role only.
