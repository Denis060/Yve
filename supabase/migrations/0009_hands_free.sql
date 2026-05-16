-- Yve — hands-free conversation mode.
--
-- When on (and read_aloud is also on), the chat auto-listens after Yve
-- finishes speaking and auto-sends when the learner stops talking. Used
-- for car commutes / kitchen study / late-night-in-bed — the use cases
-- where touching the screen isn't an option.

alter table public.learner_profiles
  add column if not exists hands_free boolean not null default false;
