-- Yve — schedule cron-trial-ending.
--
-- Runs every hour. Each invocation scans subscriptions for trials
-- ending in the next 25h, fires trial_ending_24h via notify(), and
-- skips any subscription that's already been notified within 25h
-- (idempotency check is inside the Edge Function — see
-- supabase/functions/cron-trial-ending/index.ts).
--
-- Why hourly: gives ±30-minute accuracy on the 24h-before warning
-- without firing too many noisy jobs. The email body doesn't claim
-- a specific hour so this precision is plenty.
--
-- The CRON_SECRET env var must be set on the Edge Functions project
-- AND inserted into this DB as a vault secret (Settings → Vault →
-- New secret named `cron_secret`) so pg_net can read it without us
-- hard-coding it in the SQL. The job below pulls it from vault at
-- run time.

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Drop a prior version of this schedule before re-creating, so this
-- migration is idempotent.
do $$
begin
  perform cron.unschedule('yve_trial_ending');
exception
  when others then null;
end;
$$;

-- Hourly at minute 5 (offset from the top to avoid collisions with
-- other infra). Adjust freely.
select cron.schedule(
  'yve_trial_ending',
  '5 * * * *',
  $$
  select net.http_post(
    url := 'https://ftekdhcomxxhbihvsyyw.supabase.co/functions/v1/cron-trial-ending',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-Cron-Secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')
    ),
    body := '{}'::jsonb
  ) as request_id;
  $$
);

-- Inspect with:
--   select * from cron.job;
--   select * from cron.job_run_details order by start_time desc limit 20;
