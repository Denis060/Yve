-- Yve — materials self-update RLS policy + backfill stuck rows.
--
-- Bug: materials had only insert/select/delete policies, no update.
-- ingest-material flips status from 'processing' → 'ready' at end of
-- the pipeline, but the update was silently dropped by RLS. Chunks
-- got inserted (insert policy exists) but the materials row stayed
-- 'processing' forever — so the UI thought ingest had failed even
-- though retrieval would have worked.
--
-- The user OWNS their materials and can already insert + delete them
-- with arbitrary data — adding update doesn't open any new attack
-- surface, it just lets the server-side status flip land.

create policy "materials_self_update" on public.materials
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- Backfill: any material that has chunks indexed but is still stuck
-- in 'processing' was actually a successful ingest — its status was
-- just blocked by the missing policy. Flip them to 'ready' so the UI
-- + downstream queries see them as usable.
update public.materials m
   set status = 'ready'
 where status = 'processing'
   and exists (
     select 1 from public.material_chunks c where c.material_id = m.id
   );
