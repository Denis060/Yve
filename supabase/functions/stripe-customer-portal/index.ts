// POST /stripe-customer-portal
//
// Mints a Stripe Billing Portal session URL for the authenticated user.
// The browser redirects to that URL — Stripe's hosted UI handles
// cancel, update card, switch plan, and download invoices. All state
// changes flow back to Yve via the existing stripe-webhook lifecycle.
//
// Request:
//   { return_url?: string }   default: app's /settings/billing
//
// Response (200):
//   { url: string }
//
// Errors:
//   401  not authenticated
//   404  no Stripe customer for this user (they've never subscribed)
//   500  Stripe failure

import Stripe from 'https://esm.sh/stripe@14.21.0?target=denonext';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS_HEADERS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers':
    'authorization, x-client-info, apikey, content-type',
  'access-control-allow-methods': 'POST, OPTIONS',
};

const DEFAULT_RETURN_URL = 'https://app.getyve.com/settings/billing';

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

  const authHeader = req.headers.get('Authorization') ?? '';
  const userClient = createClient(supabaseUrl, serviceKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: { user }, error: userErr } = await userClient.auth.getUser();
  if (userErr || !user) {
    return json({ error: 'not authenticated' }, 401);
  }

  let body: { return_url?: string } = {};
  try { body = await req.json(); } catch (_e) { /* empty body is fine */ }
  const returnUrl = body.return_url ?? DEFAULT_RETURN_URL;

  const svc = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // We need the Stripe customer id. It's on subscriptions, written by
  // the webhook the first time a subscription is created. A user who
  // has never subscribed has no customer_id → 404 ("nothing to manage").
  const { data: sub, error: subErr } = await svc
    .from('subscriptions')
    .select('provider_customer_id')
    .eq('user_id', user.id)
    .maybeSingle();
  if (subErr) {
    return json({ error: `subscription lookup failed: ${subErr.message}` }, 500);
  }
  const customerId = sub?.provider_customer_id as string | null | undefined;
  if (!customerId) {
    return json({
      error: 'no billing account',
      detail: 'You don\'t have a Stripe account yet — start a subscription to access billing.',
    }, 404);
  }

  const stripe = new Stripe(stripeKey, {
    apiVersion: '2024-06-20',
    httpClient: Stripe.createFetchHttpClient(),
  });

  try {
    const session = await stripe.billingPortal.sessions.create({
      customer: customerId,
      return_url: returnUrl,
    });
    return json({ url: session.url }, 200);
  } catch (e) {
    return json({
      error: 'stripe portal session failed',
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
