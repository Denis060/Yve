-- Yve — anonymous plan_limits row.
--
-- Anonymous (guest) users hit caps that look superficially like Free,
-- but they're enforced LIFETIME (not daily/weekly). The cap *values*
-- live in plan_limits like every other tier; the daily-vs-lifetime
-- semantics are handled in code (_shared/entitlements.ts) based on
-- planCode='anonymous'.
--
-- Sized for "one meaningful assignment loop, then save to continue":
--   5 chat turns total (enough to scan → ask → 2-3 follow-ups)
--   1 scan total
--   1 polish total
--   1 subject total
--   5 MB storage (one PDF)
--
-- After any cap fires, the client shows the AnonymousContinuationPanel
-- ("Keep going with Yve") instead of the regular cap-hit screen. The
-- only path forward is account creation — which via Supabase's
-- updateUser({email}) flow preserves the same user_id and carries the
-- guest's existing work into their new account.

insert into public.plan_limits (
  plan_code, display_name, stripe_price_id,
  chat_messages_per_day, scans_per_day,
  polish_runs_per_week, polish_runs_per_day, polish_max_words,
  subjects_max, storage_mb, hard_daily_message_cap
) values (
  'anonymous', 'Guest preview', null,
  5,    -- chat cap (interpreted as LIFETIME for anonymous, not per-day)
  1,    -- scan cap (LIFETIME)
  null, -- polish_runs_per_week unused for anonymous
  1,    -- polish_runs_per_day (interpreted as LIFETIME for anonymous)
  300,  -- polish word cap
  1,    -- 1 subject lifetime
  5,    -- 5 MB storage
  null  -- no fair-use ceiling (the lifetime caps are the only ceiling)
)
on conflict (plan_code) do update set
  display_name = excluded.display_name,
  chat_messages_per_day = excluded.chat_messages_per_day,
  scans_per_day = excluded.scans_per_day,
  polish_runs_per_day = excluded.polish_runs_per_day,
  polish_max_words = excluded.polish_max_words,
  subjects_max = excluded.subjects_max,
  storage_mb = excluded.storage_mb;
