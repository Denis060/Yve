-- Yve — model call observability.
--
-- One row per provider invocation. Lets us answer:
--   - which task types burn the most tokens / dollars?
--   - what's the p50/p95 latency per model?
--   - are any task → model routes silently failing?
--   - which users are heaviest on cost?
--
-- The router writes this on every call (success or failure). Reads happen
-- via the daily rollup view + future cost dashboards. We deliberately keep
-- this server-only — no client policy — so the data can't be tampered with.

create table if not exists public.model_calls (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  task_type text not null,
  provider text not null,
  model text not null,
  input_tokens int not null default 0,
  output_tokens int not null default 0,
  cache_read_tokens int not null default 0,
  latency_ms int not null default 0,
  estimated_cost_usd numeric(12, 6) not null default 0,
  success boolean not null default true,
  error_message text,
  created_at timestamptz not null default now()
);

create index if not exists model_calls_user_idx
  on public.model_calls(user_id, created_at desc);
create index if not exists model_calls_task_idx
  on public.model_calls(task_type, created_at desc);
create index if not exists model_calls_model_idx
  on public.model_calls(model, created_at desc);

alter table public.model_calls enable row level security;

-- Read-only to the owning user; writes are server-role only (the router
-- runs inside the Edge Function with the service-role JWT).
create policy "model_calls_self_select" on public.model_calls
  for select using (auth.uid() = user_id);

-- Daily cost rollup. Filterable by user/task/model. Used by the future
-- internal cost dashboard and by client-side "your usage" surfaces.
create or replace view public.daily_model_cost as
select
  user_id,
  date_trunc('day', created_at)::date as day,
  task_type,
  provider,
  model,
  count(*) as call_count,
  count(*) filter (where success) as success_count,
  count(*) filter (where not success) as failure_count,
  sum(input_tokens) as input_tokens,
  sum(output_tokens) as output_tokens,
  sum(cache_read_tokens) as cache_read_tokens,
  sum(estimated_cost_usd) as estimated_cost_usd,
  avg(latency_ms)::int as avg_latency_ms,
  percentile_cont(0.95) within group (order by latency_ms)::int as p95_latency_ms
from public.model_calls
group by user_id, day, task_type, provider, model;

alter view public.daily_model_cost set (security_invoker = on);
