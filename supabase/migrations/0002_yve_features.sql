-- Yve — expand the study_sessions feature set to cover every flow the new
-- product surfaces (Product Vision & Design System §11). The previous set was
-- only the four legacy StudyBuddy verbs; Yve adds scan, chat, summarize,
-- polish, practice, and subject_chat.
--
-- This drops the old check constraint and re-adds it with the wider set.
-- Existing rows already carry only legacy values, so no backfill needed.

alter table public.study_sessions
  drop constraint if exists study_sessions_feature_check;

alter table public.study_sessions
  add constraint study_sessions_feature_check
  check (feature in (
    'solve',
    'quiz',
    'flashcards',
    'humanize',
    'scan',
    'chat',
    'summarize',
    'polish',
    'practice',
    'subject_chat'
  ));
