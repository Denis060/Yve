-- Yve — subscriptions + daily usage.
--
-- Two tables:
--   subscriptions  one row per user, current entitlement (plan/status)
--   daily_usage    one row per (user, day), counters for quota enforcement
--
-- Free tier gets 10 chat turns/day; Plus is unlimited. Quota is enforced
-- in the yve-chat Edge Function via _shared/entitlements.ts. The
-- subscriptions row is created lazily on first read so anonymous users
-- don't need a pre-seeded row to be quota-checked.
--
-- The `provider` column is a string rather than a hard FK so a future
-- RevenueCat slice can add 'apple' / 'google' values without schema work.

create table if not exists public.subscriptions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  plan text not null default 'free' check (plan in ('free', 'plus')),
  status text not null default 'active'
    check (status in ('active', 'past_due', 'canceled', 'paused')),
  provider text check (provider in ('stripe', 'apple', 'google')),
  provider_customer_id text,
  provider_subscription_id text,
  current_period_end timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.subscriptions enable row level security;

create policy "subscriptions_self_select" on public.subscriptions
  for select using (auth.uid() = user_id);
-- writes are server-only (via service role from the Stripe webhook); no
-- self-insert / self-update policy because the client must never edit
-- their own entitlement.

create table if not exists public.daily_usage (
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  chat_turns int not null default 0,
  primary key (user_id, day)
);

alter table public.daily_usage enable row level security;

create policy "daily_usage_self_select" on public.daily_usage
  for select using (auth.uid() = user_id);
-- writes are server-only — the yve-chat Edge Function bumps the counter
-- via service-role inside the same request that consumes the quota.
