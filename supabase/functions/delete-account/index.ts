// POST /delete-account
//
// Permanently wipes the calling user's Yve account. Required by both
// the Google Play Console User Data policy ("apps must offer in-app
// account deletion") and basic privacy expectations.
//
// The flow:
//
//   1. Read the user's Stripe subscription (if any) BEFORE we wipe
//      the row — otherwise the cascade delete kills the customer_id
//      we need to cancel.
//   2. If they have an active or trialing subscription, cancel it
//      immediately in Stripe so they're not charged after the account
//      is gone. We use `cancel_at_period_end: false` (cancel now) plus
//      `prorate: true` (refund unused time) — the user is leaving
//      Yve, no reason to nickel-and-dime.
//   3. `auth.admin.deleteUser(user.id)` removes the auth.users row.
//      Every public.* table that holds a `user_id` has
//      `references auth.users(id) on delete cascade`, so this single
//      call wipes:
//        subjects, materials, material_chunks (via materials cascade),
//        chat_sessions, chat_messages, concept_observations,
//        study_sessions, profiles, learner_profiles, subscriptions,
//        user_limit_overrides, usage_events, daily_usage, weekly_usage,
//        notification_preferences, notification_events, model_calls.
//
// Anonymous data (rows orphaned because the user was a guest with
// random anon_uid) is NOT touched by this function — it gets swept up
// by Supabase's own anonymous-user cleanup based on
// `external_anonymous_users_enabled` settings.
//
// Request:  {} (no body needed — we use the JWT's user_id)
// Response: 200 { deleted: true, stripe_canceled: bool }
// Errors:
//   401  not authenticated
//   500  database / Stripe error

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Stripe from 'https://esm.sh/stripe@16.0.0?target=deno&deno-std=0.224.0';

const CORS_HEADERS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers':
    'authorization, x-client-info, apikey, content-type',
  'access-control-allow-methods': 'POST, OPTIONS',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceKey) return json({ error: 'server not configured' }, 500);

  // ── Auth ────────────────────────────────────────────────────────
  const authHeader = req.headers.get('Authorization') ?? '';
  const userClient = createClient(supabaseUrl, serviceKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: { user }, error: userErr } = await userClient.auth.getUser();
  if (userErr || !user) return json({ error: 'not authenticated' }, 401);

  // We allow anonymous users to delete too — same Play Store rule
  // applies regardless of whether they ever named their account.

  const svc = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // ── Cancel Stripe subscription if any ───────────────────────────
  // Read the row first; the auth-delete cascade below will drop it,
  // and we'd lose the IDs we need to cancel.
  let stripeCanceled = false;
  const stripeKey = Deno.env.get('STRIPE_SECRET_KEY');
  if (stripeKey) {
    try {
      const { data: sub } = await svc
        .from('subscriptions')
        .select('provider_subscription_id, provider_customer_id, status')
        .eq('user_id', user.id)
        .maybeSingle();
      const cancellableStatus = sub && [
        'active', 'trialing', 'past_due', 'incomplete',
      ].includes(sub.status as string);
      if (cancellableStatus && sub?.provider_subscription_id) {
        const stripe = new Stripe(stripeKey, {
          apiVersion: '2024-06-20',
          httpClient: Stripe.createFetchHttpClient(),
        });
        await stripe.subscriptions.cancel(
          sub.provider_subscription_id as string,
          { prorate: true },
        );
        console.log(
          `[delete-account] canceled stripe sub ${sub.provider_subscription_id} for user=${user.id}`,
        );
        stripeCanceled = true;
      }
    } catch (e) {
      // Non-fatal: better to delete the account and have a dangling
      // Stripe subscription that the user can manage themselves than
      // to refuse deletion. Log so we notice in production.
      console.error(
        `[delete-account] stripe cancel failed for user=${user.id}:`,
        e,
      );
    }
  }

  // ── Delete the auth user — cascades public.* ───────────────────
  const { error: delErr } = await svc.auth.admin.deleteUser(user.id);
  if (delErr) {
    return json({
      error: 'account deletion failed',
      detail: delErr.message,
    }, 500);
  }

  console.log(
    `[delete-account] deleted user=${user.id} stripe_canceled=${stripeCanceled}`,
  );

  return json({
    deleted: true,
    stripe_canceled: stripeCanceled,
  }, 200);
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'content-type': 'application/json' },
  });
}
