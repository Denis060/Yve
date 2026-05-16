-- Yve — Learner profile.
--
-- One row per user holding the adaptation substrate. Explicit preferences
-- (reading_level, explanation_depth, tone) shift Yve's voice and pacing on
-- every turn. Free-form fields (observed_patterns, voice_notes) carry Yve's
-- accumulated read of the learner and their writing voice for Write mode.
--
-- The row is created lazily on first read by the client (no auth trigger).

create table if not exists public.learner_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,

  -- Explicit preferences (user-settable from the Profile tab)
  reading_level text not null default 'standard'
    check (reading_level in ('basic', 'standard', 'advanced')),
  explanation_depth text not null default 'standard'
    check (explanation_depth in ('brief', 'standard', 'thorough')),
  tone_preference text not null default 'warm'
    check (tone_preference in ('warm', 'direct', 'playful')),

  -- Free-form context Yve injects into every chat. observed_patterns is
  -- intended to be Yve-maintained in a later slice; for now it's user-editable
  -- alongside voice_notes so the loop is testable end-to-end.
  observed_patterns text,
  voice_notes text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.learner_profiles enable row level security;

create policy "learner_profiles_self_select" on public.learner_profiles
  for select using (auth.uid() = user_id);
create policy "learner_profiles_self_insert" on public.learner_profiles
  for insert with check (auth.uid() = user_id);
create policy "learner_profiles_self_update" on public.learner_profiles
  for update using (auth.uid() = user_id);
