-- Yve — voice preference.
--
-- A single boolean for now: when on, Yve speaks her responses aloud via
-- the device TTS engine, and her server-side addendum adapts to keep
-- responses spoken-friendly (shorter, less markdown structure).

alter table public.learner_profiles
  add column if not exists read_aloud boolean not null default false;
