// POST /stripe-create-subscription
//
// Starts a 3-day trial subscription with a card on file. The browser
// follows up with stripe.confirmSetup using the returned client_secret.
// After confirmation, Stripe fires customer.subscription.created — the
// stripe-webhook function persists the row.
//
// Request:
//   { plan_code: 'pro_monthly' | 'pro_semester' | 'pro_annual' }
//
// Response (200):
//   { client_secret: string, subscription_id: string, plan_code: string }
//
// Errors:
//   400  invalid plan_code
//   401  not authenticated
//   409  user has had a trial before (no second trial allowed)
//   409  user already has an active subscription
//   500  Stripe failure (with reason)
//
// Guard rails:
//   - No-second-trial: server-side check. We refuse if ANY prior
//     subscriptions row for this user has trial_end set (regardless of
//     current status). This covers "trialed, canceled, came back later"
//     so a user can't farm trials by re-subscribing.
//   - One-active-per-user: the unique partial index on subscriptions
//     prevents double-subscription at the DB layer too, but we surface
//     a clear 409 here so the client can route to the customer portal
//     instead of a generic error.
//   - Customer reuse: if the user already has a Stripe customer_id
//     (from a prior canceled subscription, say), we reuse it. New
//     users get a freshly-created customer with metadata.user_id stamped.
//   - Idempotency: Stripe Idempotency-Key header is set per request so
//     a client retry after a network blip doesn't create two
//     subscriptions.

import Stripe from 'https://esm.sh/stripe@14.21.0?target=denonext';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS_HEADERS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers':
    'authorization, x-client-info, apikey, content-type',
  'access-control-allow-methods': 'POST, OPTIONS',
};

const ALLOWED_PLANS = new Set([
  'pro_monthly',
  'pro_semester',
  'pro_annual',
]);

const TRIAL_DAYS = 3;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }
  if (req.method !== 'POST') {
    return json({ error: 'method not allowed' }, 405);
  }

  // ── Env ───────────────────────────────────────────────────────────
  const stripeKey = Deno.env.get('STRIPE_SECRET_KEY');
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!stripeKey || !supabaseUrl || !serviceKey) {
    return json({ error: 'server not configured' }, 500);
  }

  // ── Auth ──────────────────────────────────────────────────────────
  const authHeader = req.headers.get('Authorization') ?? '';
  const userClient = createClient(supabaseUrl, serviceKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: { user }, error: userErr } = await userClient.auth.getUser();
  if (userErr || !user) {
    return json({ error: 'not authenticated' }, 401);
  }
  const userId = user.id;
  const userEmail = user.email ?? undefined;

  // ── Body ──────────────────────────────────────────────────────────
  let body: { plan_code?: string };
  try {
    body = await req.json();
  } catch (_e) {
    return json({ error: 'invalid JSON body' }, 400);
  }
  const planCode = body.plan_code;
  if (!planCode || !ALLOWED_PLANS.has(planCode)) {
    return json({
      error: 'invalid plan_code',
      detail: `plan_code must be one of: ${[...ALLOWED_PLANS].join(', ')}`,
    }, 400);
  }

  // ── Service client for the privileged reads ──────────────────────
  const svc = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // ── Plan resolution ──────────────────────────────────────────────
  const { data: planRow, error: planErr } = await svc
    .from('plan_limits')
    .select('stripe_price_id, display_name')
    .eq('plan_code', planCode)
    .maybeSingle();
  if (planErr) {
    return json({ error: `plan lookup failed: ${planErr.message}` }, 500);
  }
  if (!planRow?.stripe_price_id) {
    return json({
      error: 'plan not configured',
      detail: `plan_limits.stripe_price_id is NULL for ${planCode}. Run the SQL backfill from STRIPE_SETUP.md.`,
    }, 500);
  }
  const stripePriceId = planRow.stripe_price_id as string;

  // ── Existing-subscription / prior-trial guards ───────────────────
  const { data: existing, error: existingErr } = await svc
    .from('subscriptions')
    .select('status, trial_end, provider_customer_id, provider_subscription_id')
    .eq('user_id', userId)
    .maybeSingle();
  if (existingErr) {
    return json({ error: `subscription lookup failed: ${existingErr.message}` }, 500);
  }

  if (
    existing &&
    ['active', 'trialing', 'past_due', 'incomplete'].includes(existing.status as string)
  ) {
    return json({
      error: 'subscription already active',
      detail: 'Use the customer portal to change plans or cancel.',
    }, 409);
  }

  // No-second-trial: if any prior subscriptions row has trial_end set,
  // refuse. This catches "trialed → canceled → came back" reliably.
  if (existing && existing.trial_end !== null) {
    return json({
      error: 'trial already used',
      detail: 'You\'ve already used your free trial. Subscribe directly to continue.',
      // Hint to the client so it can switch the UI from "Start trial"
      // to "Subscribe now" and skip the SetupIntent flow entirely once
      // we ship the "no-trial direct subscribe" path.
      already_trialed: true,
    }, 409);
  }

  // ── Stripe ────────────────────────────────────────────────────────
  const stripe = new Stripe(stripeKey, {
    apiVersion: '2024-06-20',
    httpClient: Stripe.createFetchHttpClient(),
  });

  // Customer: reuse the prior provider_customer_id if we have one
  // (canceled-then-returned), otherwise create a fresh customer with
  // user_id stamped in metadata.
  let customerId = existing?.provider_customer_id as string | null | undefined;
  if (!customerId) {
    try {
      const customer = await stripe.customers.create(
        {
          email: userEmail,
          metadata: { user_id: userId },
        },
        // Idempotency key tied to the user — if this exact call is
        // retried, Stripe returns the same customer rather than making
        // a second one.
        { idempotencyKey: `customer:${userId}` },
      );
      customerId = customer.id;
    } catch (e) {
      return json({
        error: 'stripe customer create failed',
        detail: (e as Error).message,
      }, 500);
    }
  }

  // Subscription: trial + card-required via default_incomplete +
  // payment_settings.save_default_payment_method='on_subscription'.
  // The SetupIntent in pending_setup_intent is what the browser
  // confirms with Stripe Elements. After confirm, Stripe activates the
  // subscription and webhook fires.
  let subscription: Stripe.Subscription;
  try {
    subscription = await stripe.subscriptions.create(
      {
        customer: customerId!,
        items: [{ price: stripePriceId }],
        trial_period_days: TRIAL_DAYS,
        payment_behavior: 'default_incomplete',
        payment_settings: {
          save_default_payment_method: 'on_subscription',
        },
        // Stripe's "trial requires payment method" enforces the card
        // requirement at subscription level. cancel = auto-cancel if
        // no card is confirmed by trial end (defensive — our flow
        // confirms card upfront).
        trial_settings: {
          end_behavior: { missing_payment_method: 'cancel' },
        },
        metadata: { user_id: userId, plan_code: planCode },
        expand: ['pending_setup_intent'],
      },
      // Per-user-per-plan idempotency: a retry of the same request
      // returns the same subscription; a different plan creates a
      // separate one (but the existing-subscription guard above will
      // catch that case first in practice).
      { idempotencyKey: `subscribe:${userId}:${planCode}` },
    );
  } catch (e) {
    return json({
      error: 'stripe subscription create failed',
      detail: (e as Error).message,
    }, 500);
  }

  const setupIntent = subscription.pending_setup_intent as
    | Stripe.SetupIntent
    | null;
  if (!setupIntent?.client_secret) {
    return json({
      error: 'stripe returned no setup intent',
      detail: `subscription ${subscription.id} created but pending_setup_intent missing — check Stripe dashboard for state.`,
    }, 500);
  }

  // We intentionally do NOT write to subscriptions here. The
  // stripe-webhook is the single writer. That keeps the data model
  // unambiguous: every subscription state change comes from Stripe's
  // event lifecycle, never from an optimistic local write that might
  // diverge from Stripe's truth.
  return json({
    client_secret: setupIntent.client_secret,
    subscription_id: subscription.id,
    plan_code: planCode,
    trial_end: subscription.trial_end,
  }, 200);
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'content-type': 'application/json' },
  });
}
