-- Yve — conversion engine.
--
-- Every chat turn now produces structured learning state in addition to the
-- markdown answer. This migration extends study_sessions to carry:
--   - mode             which study mode was active (learn/practice/...)
--   - subject_id       optional link to the subject this turn belongs to
--   - concept_tags     teachable units this turn covered (memory feed)
--   - confidence_signal Yve's read of how the learner is doing (retention feed)
--
-- The legacy feature column stays for backwards compat; new code sets feature
-- to 'chat' and uses mode for the finer-grained categorization.

alter table public.study_sessions
  add column if not exists mode text,
  add column if not exists subject_id text,
  add column if not exists concept_tags text[] not null default '{}',
  add column if not exists confidence_signal text;

create index if not exists study_sessions_subject_idx
  on public.study_sessions(user_id, subject_id, created_at desc)
  where subject_id is not null;

-- Allow the new mode values. We keep the existing feature check tolerant so
-- legacy rows ('solve', 'quiz', etc.) still validate.
alter table public.study_sessions
  drop constraint if exists study_sessions_mode_check;

alter table public.study_sessions
  add constraint study_sessions_mode_check
  check (
    mode is null or mode in (
      'open',
      'learn',
      'practice',
      'assignment',
      'write',
      'materials'
    )
  );
