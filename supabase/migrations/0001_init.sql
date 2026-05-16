-- Profile row per auth.user, plus a log of every study session.
-- Row-Level Security is on; users only see their own rows.

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "profiles_self_select" on public.profiles
  for select using (auth.uid() = id);

create policy "profiles_self_upsert" on public.profiles
  for insert with check (auth.uid() = id);

create policy "profiles_self_update" on public.profiles
  for update using (auth.uid() = id);

-- One row per AI call (solve / quiz / flashcards / humanize).
create table if not exists public.study_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  feature text not null check (feature in ('solve', 'quiz', 'flashcards', 'humanize')),
  prompt text not null,
  response text,
  input_tokens int,
  output_tokens int,
  created_at timestamptz not null default now()
);

create index study_sessions_user_idx on public.study_sessions(user_id, created_at desc);

alter table public.study_sessions enable row level security;

create policy "study_sessions_self_select" on public.study_sessions
  for select using (auth.uid() = user_id);

create policy "study_sessions_self_insert" on public.study_sessions
  for insert with check (auth.uid() = user_id);
