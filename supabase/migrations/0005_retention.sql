-- Yve — Retention surfaces.
--
-- This migration introduces the views that turn observations into a real
-- retention loop:
--
--   concept_review_queue   per-concept next_due_at, computed from the most
--                          recent confidence signal in concept_mastery
--   daily_activity         per-day message count for the calm "you showed up"
--                          strip in the Home greeting
--
-- The schedule is intentionally simple (no SM-2 doubling yet) — predictable
-- intervals are easier to tune and easier for Yve to talk about honestly.

create or replace view public.concept_review_queue as
with intervals as (
  select
    user_id,
    subject_id,
    concept,
    n_observations,
    last_seen_at,
    current_confidence,
    case current_confidence
      when 'grasped' then interval '7 days'
      when 'partial' then interval '3 days'
      when 'struggling' then interval '1 day'
      else interval '2 days'
    end as gap
  from public.concept_mastery
)
select
  user_id,
  subject_id,
  concept,
  n_observations,
  last_seen_at,
  current_confidence,
  (last_seen_at + gap) as next_due_at,
  -- Positive when due now or overdue; negative when still in the future.
  extract(epoch from (now() - (last_seen_at + gap))) as overdue_seconds
from intervals;

alter view public.concept_review_queue set (security_invoker = on);

create or replace view public.daily_activity as
select
  user_id,
  date_trunc('day', created_at)::date as day,
  count(*) as message_count
from public.chat_messages
group by user_id, date_trunc('day', created_at)::date;

alter view public.daily_activity set (security_invoker = on);
