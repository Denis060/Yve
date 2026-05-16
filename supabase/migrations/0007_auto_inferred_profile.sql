-- Yve — auto-inferred adaptation profile.
--
-- The companion loop closes here: Yve observes the learner from their chat
-- history and writes short adaptation notes into auto_* columns. The user
-- can still override via the existing observed_patterns / voice_notes
-- columns; the addendum builder prefers user-set values and falls back to
-- the auto-inferred ones.

alter table public.learner_profiles
  add column if not exists auto_observed_patterns text,
  add column if not exists auto_voice_notes text,
  add column if not exists last_inferred_at timestamptz;
