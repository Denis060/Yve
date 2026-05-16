-- Yve — notifications preference.
--
-- Single boolean per user. Notifications are local (scheduled on-device via
-- flutter_local_notifications) for this slice; the server isn't involved in
-- sending. The column lives on learner_profiles so it round-trips with the
-- rest of the adaptation preferences and a future FCM layer can read it as
-- the opt-in source of truth.

alter table public.learner_profiles
  add column if not exists notifications_enabled boolean not null default false;
