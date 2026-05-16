// POST /create-checkout-session
//
// Creates a Stripe Checkout session for a specific plan + trial. The
// client opens the returned URL in an in-app browser; Stripe collects
// the card, creates a `trialing` subscription, redirects back. The
// stripe-webhook function persists the subscriptions row.
//
// Request:
//   {
//     plan_code:    'pro_monthly' | 'pro_semester' | 'pro_annual',
//     success_url?: string,   // overrides STRIPE_SUCCESS_URL
//     cancel_url?:  string,   // overrides STRIPE_CANCEL_URL
//   }
//
// Response (200):
//   { url: string }
//
// Errors:
//   400  invalid / missing plan_code
//   400  anonymous user (no email = can't be charged)
//   401  not authenticated
//   409  subscription already active
//   409  user has had a trial before (no second trial allowed)
//   500  Stripe / server failure
//
// Architecture:
//   - Single source of truth for prices: plan_limits.stripe_price_id.
//     A new plan = a new row + a Stripe price + an UPDATE. No code change.
//   - The webhook is the only writer to subscriptions; this function
//     never writes. That keeps local state from drifting from Stripe.
//   - subscription_data.metadata.user_id is stamped on the subscription
//     Stripe creates from this Checkout — the webhook reads it to map
//     the subscription back to our user.
//   - No-second-trial: the same guard as stripe-create-subscription.
//     A user who trialed → canceled → came back can subscribe directly
//     (Stripe Checkout supports that), but not trial again.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Stripe from 'https://esm.sh/stripe@14.25.0?target=denonext';

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

  const stripeKey = Deno.env.get('STRIPE_SECRET_KEY');
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!stripeKey || !supabaseUrl || !serviceKey) {
    return json({ error: 'server not configured' }, 500);
  }

  // Auth ─────────────────────────────────────────────────────────────
  const authHeader = req.headers.get('Authorization') ?? '';
  const userClient = createClient(supabaseUrl, serviceKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: { user }, error: userErr } = await userClient.auth.getUser();
  if (userErr || !user) {
    return json({ error: 'not authenticated' }, 401);
  }
  if (user.is_anonymous === true) {
    return json(
      {
        error: 'Sign in first — Pro needs an account to attach the subscription to.',
        code: 'anonymous_user',
      },
      400,
    );
  }

  // Body ─────────────────────────────────────────────────────────────
  let body: { plan_code?: string; success_url?: string; cancel_url?: string };
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

  const successUrl =
    body.success_url ?? Deno.env.get('STRIPE_SUCCESS_URL') ??
    'https://yve.app/upgrade/success';
  const cancelUrl =
    body.cancel_url ?? Deno.env.get('STRIPE_CANCEL_URL') ??
    'https://yve.app/upgrade/cancel';

  // Service client for privileged reads ──────────────────────────────
  const svc = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Plan resolution ──────────────────────────────────────────────────
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

  // Guards ───────────────────────────────────────────────────────────
  const { data: existing } = await svc
    .from('subscriptions')
    .select('status, trial_end, provider_customer_id')
    .eq('user_id', user.id)
    .maybeSingle();

  if (
    existing &&
    ['active', 'trialing', 'past_due', 'incomplete'].includes(existing.status as string)
  ) {
    return json({
      error: 'subscription already active',
      detail: 'Use the customer portal to change plans or cancel.',
      code: 'already_subscribed',
    }, 409);
  }

  // No-second-trial: any prior subscriptions row with trial_end set
  // means the user has used their trial. They can subscribe directly
  // (no trial_period_days on the new Checkout) but not get another
  // free 3 days.
  const hasUsedTrial = existing && existing.trial_end !== null;

  // Stripe ───────────────────────────────────────────────────────────
  const stripe = new Stripe(stripeKey, {
    apiVersion: '2024-06-20',
    httpClient: Stripe.createFetchHttpClient(),
  });

  try {
    const sessionParams: Stripe.Checkout.SessionCreateParams = {
      mode: 'subscription',
      payment_method_types: ['card'],
      line_items: [{ price: stripePriceId, quantity: 1 }],
      success_url: successUrl,
      cancel_url: cancelUrl,
      allow_promotion_codes: true,
      // Map back to our user. client_reference_id is on the Checkout
      // Session itself; subscription_data.metadata.user_id is stamped
      // on the Subscription that Stripe creates from the Checkout —
      // that's what the webhook reads.
      client_reference_id: user.id,
      customer_email: user.email ?? undefined,
      subscription_data: {
        metadata: { user_id: user.id, plan_code: planCode },
      },
    };

    // Reuse the existing Stripe customer if we have one (from a prior
    // canceled subscription). Stripe Checkout will create one if not
    // provided.
    if (existing?.provider_customer_id) {
      sessionParams.customer = existing.provider_customer_id as string;
      // customer_email is incompatible with passing a customer.
      delete sessionParams.customer_email;
    }

    // Trial only for first-time users.
    if (!hasUsedTrial) {
      sessionParams.subscription_data!.trial_period_days = TRIAL_DAYS;
      // If the user's payment method becomes invalid during trial,
      // cancel rather than try to charge a bad card.
      sessionParams.subscription_data!.trial_settings = {
        end_behavior: { missing_payment_method: 'cancel' },
      };
    }

    const session = await stripe.checkout.sessions.create(sessionParams);
    return json({
      url: session.url,
      // Tell the client whether a trial was granted so the success
      // screen can show the right copy ("Trial starts now" vs "Pro
      // active — first charge today").
      trial_granted: !hasUsedTrial,
    });
  } catch (e) {
    return json({
      error: 'stripe checkout session failed',
      detail: (e as Error).message,
    }, 500);
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'content-type': 'application/json' },
  });
}
