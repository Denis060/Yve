// POST /cron-trial-ending
//
// Scheduled job: fires trial_ending_24h for every subscription whose
// trial_end is between now and now+25h. Idempotent — re-running within
// the same window is a no-op for already-notified subscriptions.
//
// Designed to be triggered hourly via pg_cron (see Phase 6.1 docs).
// Running hourly gives ±30-minute timing accuracy on the 24h-before
// notification, which is acceptable for a "your trial ends tomorrow"
// reminder where the body doesn't claim any specific hour.
//
// Idempotency: for each candidate subscription, we look at
// notification_events for a prior trial_ending_24h send tagged with
// the same subscription_id in the last 25h. If one exists, skip.
// This holds even if pg_cron fires twice or this endpoint is called
// manually — each subscription gets exactly one warning per trial.
//
// Authorization: requires the X-Cron-Secret header to match the
// CRON_SECRET env var. This stops public traffic from triggering the
// cron without locking out pg_net (which sets the header before
// calling). For ad-hoc admin triggers, set the same header.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

import { notify } from '../_shared/notifications.ts';

const HOURS_25_MS = 25 * 60 * 60 * 1000;

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response('method not allowed', { status: 405 });
  }

  // Lightweight gate so this isn't trivially abusable from the public
  // internet. pg_cron sets the header via pg_net.http_post().
  const expected = Deno.env.get('CRON_SECRET');
  const presented = req.headers.get('X-Cron-Secret');
  if (expected && presented !== expected) {
    return new Response('forbidden', { status: 403 });
  }

  const svc = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );

  const now = Date.now();
  const windowEnd = new Date(now + HOURS_25_MS).toISOString();
  const nowIso = new Date(now).toISOString();

  // Candidate subscriptions: trial ends in the next 25h, status is
  // trialing (not yet converted), not canceled.
  const { data: candidates, error } = await svc
    .from('subscriptions')
    .select('user_id, provider_subscription_id, plan_code, trial_end, status')
    .eq('status', 'trialing')
    .gte('trial_end', nowIso)
    .lte('trial_end', windowEnd);
  if (error) {
    console.error('[cron-trial-ending] candidate scan failed', error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { 'content-type': 'application/json' },
    });
  }

  let sent = 0;
  let skipped = 0;
  let failed = 0;

  for (const sub of candidates ?? []) {
    const userId = sub.user_id as string;
    const subId = sub.provider_subscription_id as string;
    const planCode = sub.plan_code as string;

    // Idempotency: have we already sent trial_ending_24h for this
    // subscription in the last 25h? Match on payload->>subscription_id
    // so a user who somehow has two trials (shouldn't happen given
    // our guards, but defensive) gets one warning per trial.
    const sinceIso = new Date(now - HOURS_25_MS).toISOString();
    const { count: priorCount } = await svc
      .from('notification_events')
      .select('*', { count: 'exact', head: true })
      .eq('user_id', userId)
      .eq('event_type', 'trial_ending_24h')
      .eq('payload->>subscription_id', subId)
      .in('status', ['sent', 'partial'])
      .gte('created_at', sinceIso);
    if ((priorCount ?? 0) > 0) {
      skipped++;
      continue;
    }

    try {
      const result = await notify(userId, 'trial_ending_24h', {
        plan_label: planLabelFor(planCode),
        subscription_id: subId,
        trial_end: sub.trial_end,
      });
      if (result.status === 'sent' || result.status === 'partial') {
        sent++;
      } else {
        // skipped_* counts as 'skipped' from the cron's POV — notify()
        // had a legitimate reason (suppressed address, etc.).
        skipped++;
      }
    } catch (e) {
      console.error(`[cron-trial-ending] notify failed for user=${userId}`, e);
      failed++;
    }
  }

  return new Response(
    JSON.stringify({
      candidates: candidates?.length ?? 0,
      sent,
      skipped,
      failed,
      window_end: windowEnd,
    }),
    {
      status: 200,
      headers: { 'content-type': 'application/json' },
    },
  );
});

function planLabelFor(planCode: string): string {
  switch (planCode) {
    case 'pro_monthly':  return 'Pro Monthly';
    case 'pro_semester': return 'Pro Semester';
    case 'pro_annual':   return 'Pro Annual';
    case 'pro_trial':    return 'Pro Trial';
    default:             return 'Pro';
  }
}
