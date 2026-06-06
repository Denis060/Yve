-- Yve — Phase 6.0 notifications + email infrastructure.
--
-- One event-driven architecture for everything Yve sends: in-app
-- notifications, email, and (future) push. The notify() helper in
-- _shared/notifications.ts is the only writer; product code never
-- calls Resend or schedules notifications directly.
--
-- Four tables:
--
--   notification_preferences  per-user opt-in by category + quiet
--                              hours + timezone. Defaults defined here.
--   notification_events       central log per event with planned and
--                              attempted channels + final status. Lets
--                              us reconstruct "what did Yve send to
--                              user X in the last week" for any user.
--   email_send_log            Resend message_id + delivery state
--                              (delivered, bounced, complained, opened,
--                              clicked). Populated by the resend-webhook.
--   email_suppression         hard-block list for addresses that bounced
--                              or complained. notify() checks this before
--                              attempting an email send.
--
-- The frequency cap is computed at send time by counting recent
-- notification_events rows — no separate counter table needed (and one
-- fewer thing to keep in sync).

-- ─────────────────────────────────────────────────────────────────────
-- 1) notification_preferences — per-user opt-in + quiet hours
-- ─────────────────────────────────────────────────────────────────────
-- One row per user, created lazily by notify() on first call. Defaults
-- are coded here so a brand-new user has sensible behavior before they
-- ever visit the preferences screen.
--
-- Categories:
--   transactional   billing, magic-link, account dignity. NOT opt-out-
--                    able from the table level (legally and ethically
--                    required). notify() ignores this column for the
--                    transactional category — included only so the
--                    schema is uniform.
--   continuity      "your work is waiting" nudges, mid-semester check-
--                    ins. Opt-in by default; users can disable.
--   recap           end-of-semester recap email. Opt-in by default.
--   async           polish-complete, materials-processed pings. Opt-in
--                    by default — these are *invited* (user took an
--                    action and is waiting).
--   in_app          master switch for in-app banners + local push.
--                    Subordinate to learner_profiles.notifications_enabled
--                    which is the absolute master kill switch.
create table if not exists public.notification_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  transactional boolean not null default true,
  continuity    boolean not null default true,
  recap         boolean not null default true,
  async         boolean not null default true,
  in_app        boolean not null default true,
  -- IANA timezone string ("America/New_York"). Default UTC; the
  -- client should update this on first launch from device timezone.
  timezone      text    not null default 'UTC',
  -- Quiet hours in the user's local timezone. Notifications scheduled
  -- inside the quiet window get deferred to the next quiet_hours_end.
  -- Transactional emails ignore quiet hours (billing can't wait).
  quiet_hours_start time not null default '21:00',
  quiet_hours_end   time not null default '08:00',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.notification_preferences enable row level security;
create policy "prefs_self_select" on public.notification_preferences
  for select using (auth.uid() = user_id);
create policy "prefs_self_update" on public.notification_preferences
  for update using (auth.uid() = user_id);
-- Inserts come from notify() via service-role; no self-insert policy.

-- ─────────────────────────────────────────────────────────────────────
-- 2) notification_events — central event log
-- ─────────────────────────────────────────────────────────────────────
-- Every call to notify() writes one row. The row captures:
--   - what was requested (event_type, payload, channels_planned)
--   - what was actually attempted (channels_attempted)
--   - why (status: 'sent', 'skipped_*', 'failed')
--   - error if failed
--
-- This is the source of truth for "did Yve send X to user Y" — both
-- for admin debugging ("the user says they didn't get the email")
-- and for frequency-cap computation (count recent rows by category).
--
-- Known event_type values (extend by string constants — no enum so
-- new events don't need a migration):
--   'magic_link', 'trial_ending_24h', 'trial_converted',
--   'payment_failed', 'subscription_canceled', 'polish_complete',
--   'materials_processed', 'session_idle_3d', 'mid_semester_checkin',
--   'semester_recap'.
create table if not exists public.notification_events (
  id          bigserial primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  event_type  text not null,
  -- Routing category — drives preference + frequency-cap lookup.
  -- One of: 'transactional', 'continuity', 'recap', 'async'.
  category    text not null check (category in (
    'transactional', 'continuity', 'recap', 'async'
  )),
  payload     jsonb,
  channels_planned   text[] not null default '{}',
  channels_attempted text[] not null default '{}',
  status      text not null check (status in (
    'sent', 'partial', 'skipped_preference', 'skipped_frequency',
    'skipped_quiet_hours', 'skipped_suppressed', 'failed'
  )),
  error       text,
  created_at  timestamptz not null default now()
);

create index if not exists notification_events_user_time
  on public.notification_events(user_id, created_at desc);
create index if not exists notification_events_user_category_time
  on public.notification_events(user_id, category, created_at desc);

alter table public.notification_events enable row level security;
create policy "events_self_select" on public.notification_events
  for select using (auth.uid() = user_id);
-- writes are service-role only.

-- ─────────────────────────────────────────────────────────────────────
-- 3) email_send_log — Resend message id + delivery state
-- ─────────────────────────────────────────────────────────────────────
-- One row per email Resend accepted. Updated by the resend-webhook as
-- delivery events arrive: delivered, bounced, complained, opened,
-- clicked. We don't retry on our end — Resend handles delivery retries.
create table if not exists public.email_send_log (
  id            bigserial primary key,
  -- FK to the notification_events row that triggered the send.
  event_id      bigint references public.notification_events(id)
                  on delete set null,
  user_id       uuid not null references auth.users(id) on delete cascade,
  -- Resend's id for this email — the join key for incoming webhooks.
  resend_id     text unique,
  to_email      text not null,
  subject       text,
  -- Delivery state. Progresses sent → delivered → opened → clicked.
  -- Or sent → bounced / complained. Resend may also emit 'delivery_delayed'
  -- which we just log without changing state.
  state         text not null default 'sent' check (state in (
    'sent', 'delivered', 'opened', 'clicked', 'bounced', 'complained',
    'delivery_delayed', 'failed'
  )),
  -- For bounces / complaints, the raw reason from Resend (truncated).
  state_detail  text,
  sent_at       timestamptz not null default now(),
  delivered_at  timestamptz,
  opened_at     timestamptz,
  clicked_at    timestamptz,
  bounced_at    timestamptz,
  complained_at timestamptz
);

create index if not exists email_send_log_user_time
  on public.email_send_log(user_id, sent_at desc);
create index if not exists email_send_log_state_time
  on public.email_send_log(state, sent_at desc);

alter table public.email_send_log enable row level security;
create policy "send_log_self_select" on public.email_send_log
  for select using (auth.uid() = user_id);
-- writes are service-role only.

-- ─────────────────────────────────────────────────────────────────────
-- 4) email_suppression — hard-block addresses we should never email
-- ─────────────────────────────────────────────────────────────────────
-- Populated automatically when an email hard-bounces or the user
-- marks Yve as spam. notify() checks this *before* calling Resend so
-- we never try to deliver to a known-bad address — protects our
-- sender reputation for everyone else.
--
-- Keyed by lower(email) so case variations match. Includes a reason
-- + the resend_id of the offending email so admins can audit.
create table if not exists public.email_suppression (
  email         text primary key,
  reason        text not null check (reason in (
    'hard_bounce', 'complaint', 'manual'
  )),
  resend_id     text,
  created_at    timestamptz not null default now()
);
-- No RLS — service-role-only access for admin queries.
