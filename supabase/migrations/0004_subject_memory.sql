-- Yve — Subject Memory.
--
-- This migration introduces the persistent memory layer that turns Subjects
-- from folders into AI knowledge spaces:
--
--   subjects               persistent learning workspaces
--   materials              files / notes / URLs / images uploaded into a subject
--   material_chunks        chunked + embedded text used for retrieval
--   chat_sessions          persistent conversations
--   chat_messages          per-turn record (supersedes study_sessions)
--   concept_observations   per-turn record of what Yve taught and how the
--                          learner did, feeding the mastery view
--
-- The old study_sessions table is dropped — chat_messages is its successor
-- and adds the session_id grouping that was missing.
--
-- pgvector powers the materials retrieval used by Materials mode chats.

create extension if not exists vector;

------------------------------------------------------------------------
-- Subjects
------------------------------------------------------------------------

create table if not exists public.subjects (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  emoji text not null default '✨',
  color_seed int not null default 0,
  subtitle text,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists subjects_user_idx
  on public.subjects(user_id, archived_at, updated_at desc);

alter table public.subjects enable row level security;

create policy "subjects_self_select" on public.subjects
  for select using (auth.uid() = user_id);
create policy "subjects_self_insert" on public.subjects
  for insert with check (auth.uid() = user_id);
create policy "subjects_self_update" on public.subjects
  for update using (auth.uid() = user_id);
create policy "subjects_self_delete" on public.subjects
  for delete using (auth.uid() = user_id);

------------------------------------------------------------------------
-- Materials + chunks (RAG corpus per subject)
------------------------------------------------------------------------

create table if not exists public.materials (
  id uuid primary key default gen_random_uuid(),
  subject_id uuid not null references public.subjects(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('pdf', 'image', 'note', 'url', 'doc')),
  name text not null,
  source_uri text,
  raw_text text,
  -- ingestion lifecycle: queued -> processing -> ready | failed
  status text not null default 'queued'
    check (status in ('queued', 'processing', 'ready', 'failed')),
  error text,
  created_at timestamptz not null default now()
);

create index if not exists materials_subject_idx
  on public.materials(subject_id, created_at desc);

alter table public.materials enable row level security;

create policy "materials_self_select" on public.materials
  for select using (auth.uid() = user_id);
create policy "materials_self_insert" on public.materials
  for insert with check (auth.uid() = user_id);
create policy "materials_self_delete" on public.materials
  for delete using (auth.uid() = user_id);

-- Chunks: one row per ~1.5KB span of a material's text, plus its embedding.
create table if not exists public.material_chunks (
  id uuid primary key default gen_random_uuid(),
  material_id uuid not null references public.materials(id) on delete cascade,
  subject_id uuid not null references public.subjects(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  chunk_index int not null,
  content text not null,
  embedding vector(512),
  created_at timestamptz not null default now()
);

create index if not exists material_chunks_subject_idx
  on public.material_chunks(subject_id);

-- HNSW index for cosine-similarity retrieval. Good quality at small data
-- volumes; rebuild with different parameters if usage grows past tens of
-- thousands of chunks per user.
create index if not exists material_chunks_embedding_idx
  on public.material_chunks
  using hnsw (embedding vector_cosine_ops);

alter table public.material_chunks enable row level security;

create policy "material_chunks_self_select" on public.material_chunks
  for select using (auth.uid() = user_id);
create policy "material_chunks_self_insert" on public.material_chunks
  for insert with check (auth.uid() = user_id);
create policy "material_chunks_self_delete" on public.material_chunks
  for delete using (auth.uid() = user_id);

------------------------------------------------------------------------
-- Chat sessions + messages (persistent conversations)
------------------------------------------------------------------------

create table if not exists public.chat_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  subject_id uuid references public.subjects(id) on delete set null,
  title text not null default 'New session',
  mode text not null default 'open'
    check (mode in ('open', 'learn', 'practice', 'assignment', 'write', 'materials')),
  message_count int not null default 0,
  last_message_preview text,
  summary text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists chat_sessions_user_idx
  on public.chat_sessions(user_id, updated_at desc);
create index if not exists chat_sessions_subject_idx
  on public.chat_sessions(subject_id, updated_at desc)
  where subject_id is not null;

alter table public.chat_sessions enable row level security;

create policy "chat_sessions_self_select" on public.chat_sessions
  for select using (auth.uid() = user_id);
create policy "chat_sessions_self_insert" on public.chat_sessions
  for insert with check (auth.uid() = user_id);
create policy "chat_sessions_self_update" on public.chat_sessions
  for update using (auth.uid() = user_id);
create policy "chat_sessions_self_delete" on public.chat_sessions
  for delete using (auth.uid() = user_id);

create table if not exists public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.chat_sessions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('user', 'assistant')),
  content text not null,
  concept_tags text[] not null default '{}',
  offer jsonb,
  confidence_signal text
    check (confidence_signal in ('grasped', 'partial', 'struggling', 'unknown')),
  save_to_subject text,
  input_tokens int,
  output_tokens int,
  created_at timestamptz not null default now()
);

create index if not exists chat_messages_session_idx
  on public.chat_messages(session_id, created_at);

alter table public.chat_messages enable row level security;

create policy "chat_messages_self_select" on public.chat_messages
  for select using (auth.uid() = user_id);
create policy "chat_messages_self_insert" on public.chat_messages
  for insert with check (auth.uid() = user_id);
create policy "chat_messages_self_delete" on public.chat_messages
  for delete using (auth.uid() = user_id);

-- Drop the old per-turn analytics table. chat_messages supersedes it.
drop table if exists public.study_sessions cascade;

------------------------------------------------------------------------
-- Concept observations (memory feed for retention)
------------------------------------------------------------------------

create table if not exists public.concept_observations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  subject_id uuid references public.subjects(id) on delete cascade,
  session_id uuid references public.chat_sessions(id) on delete set null,
  concept text not null,
  confidence_signal text not null default 'unknown'
    check (confidence_signal in ('grasped', 'partial', 'struggling', 'unknown')),
  observed_at timestamptz not null default now()
);

create index if not exists concept_observations_subject_idx
  on public.concept_observations(user_id, subject_id, concept);
create index if not exists concept_observations_recent_idx
  on public.concept_observations(user_id, observed_at desc);

alter table public.concept_observations enable row level security;

create policy "concept_observations_self_select" on public.concept_observations
  for select using (auth.uid() = user_id);
create policy "concept_observations_self_insert" on public.concept_observations
  for insert with check (auth.uid() = user_id);

------------------------------------------------------------------------
-- Views
------------------------------------------------------------------------

-- Per-concept rollup. The most recent confidence signal is the working
-- mastery state; n_observations + last_seen_at feed the retention queue.
create or replace view public.concept_mastery as
select
  user_id,
  subject_id,
  concept,
  count(*) as n_observations,
  max(observed_at) as last_seen_at,
  (
    select confidence_signal
    from public.concept_observations co2
    where co2.user_id = co.user_id
      and co2.subject_id is not distinct from co.subject_id
      and co2.concept = co.concept
    order by observed_at desc
    limit 1
  ) as current_confidence
from public.concept_observations co
group by user_id, subject_id, concept;

-- Subject row + live counts. Cheaper than maintaining counters via triggers
-- and accurate even when materials/sessions are deleted.
create or replace view public.subjects_with_counts as
select
  s.id,
  s.user_id,
  s.name,
  s.emoji,
  s.color_seed,
  s.subtitle,
  s.archived_at,
  s.created_at,
  s.updated_at,
  coalesce((select count(*) from public.materials m
            where m.subject_id = s.id), 0) as material_count,
  coalesce((select count(*) from public.chat_sessions cs
            where cs.subject_id = s.id), 0) as session_count,
  coalesce((select count(distinct concept) from public.concept_observations co
            where co.subject_id = s.id), 0) as concept_count
from public.subjects s;

-- Views inherit RLS from their base tables, but Postgres requires
-- security_invoker for that to work in newer versions. Set it explicitly.
alter view public.concept_mastery set (security_invoker = on);
alter view public.subjects_with_counts set (security_invoker = on);

------------------------------------------------------------------------
-- Helper: cosine similarity search over a subject's chunks
------------------------------------------------------------------------

create or replace function public.match_material_chunks(
  p_subject_id uuid,
  p_query_embedding vector(512),
  p_match_count int default 5,
  p_min_similarity float default 0.3
)
returns table (
  id uuid,
  material_id uuid,
  content text,
  similarity float
)
language plpgsql
security invoker
as $$
begin
  return query
  select
    mc.id,
    mc.material_id,
    mc.content,
    1 - (mc.embedding <=> p_query_embedding) as similarity
  from public.material_chunks mc
  where mc.subject_id = p_subject_id
    and mc.embedding is not null
    and 1 - (mc.embedding <=> p_query_embedding) > p_min_similarity
  order by mc.embedding <=> p_query_embedding
  limit p_match_count;
end;
$$;
