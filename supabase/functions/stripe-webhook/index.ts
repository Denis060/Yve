// POST /stripe-webhook   — Stripe → Yve subscription lifecycle
//
// Single inbound endpoint for every Stripe event we care about.
// Architecture:
//
//   1. Verify HMAC-SHA256 signature against raw body. Reject if missing,
//      wrong, or older than 5 minutes (replay-window).
//   2. Idempotency-insert into stripe_webhook_events. Duplicate event_id
//      → respond 200 immediately (Stripe sometimes redelivers).
//   3. Dispatch on event.type. Each handler resolves the Stripe customer
//      to our user_id (via subscription.metadata.user_id, stamped at
//      checkout), resolves stripe_price_id → plan_code via plan_limits,
//      and upserts the subscriptions row. Every cap check in the rest
//      of the system reads subscriptions.plan_code, so plan resolution
//      flows from this single write.
//   4. Mark processed_at. On failure, leave processed_at NULL and let
//      Stripe retry — but record the error so we can debug.
//
// Events handled:
//   customer.subscription.created   first signup, trial start
//   customer.subscription.updated   plan change, cancel toggle,
//                                   trial→active, status changes
//   customer.subscription.deleted   final cancellation → drop to free
//   invoice.payment_succeeded       informational; status already
//                                   carried on the subscription event
//   invoice.payment_failed          mirror past_due immediately
//
// Everything else is acked with 200 + a log line (we don't want Stripe
// retrying events we don't care about).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

import { notify } from '../_shared/notifications.ts';

const SIGNING_REPLAY_TOLERANCE_SEC = 300;

interface StripeEvent {
  id: string;
  type: string;
  data: { object: Record<string, unknown> };
  created: number;
}

interface StripeSubscription {
  id: string;
  customer: string;
  status: string;
  cancel_at_period_end?: boolean;
  canceled_at?: number | null;
  current_period_end?: number;
  trial_end?: number | null;
  items: {
    data: Array<{ price: { id: string } }>;
  };
  metadata?: Record<string, string>;
}

interface StripeInvoice {
  id: string;
  customer: string;
  subscription?: string;
  status: string;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response('method not allowed', { status: 405 });
  }

  const signingSecret = Deno.env.get('STRIPE_WEBHOOK_SECRET');
  if (!signingSecret) {
    console.error('STRIPE_WEBHOOK_SECRET not set');
    return new Response('server not configured', { status: 500 });
  }

  const sigHeader = req.headers.get('Stripe-Signature');
  if (!sigHeader) {
    return new Response('missing signature', { status: 400 });
  }

  // Raw body — required byte-for-byte for signature verification.
  const rawBody = await req.text();

  const verified = await verifyStripeSignature(rawBody, sigHeader, signingSecret);
  if (!verified.ok) {
    console.error('Stripe signature verification failed:', verified.reason);
    return new Response(`signature invalid: ${verified.reason}`, { status: 400 });
  }

  let event: StripeEvent;
  try {
    event = JSON.parse(rawBody);
  } catch (e) {
    return new Response(`invalid JSON: ${(e as Error).message}`, { status: 400 });
  }

  const svc = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );

  // Idempotency: try to insert the event id. Duplicate → ack 200 so
  // Stripe stops retrying. Anything else → 500 (we want a retry).
  const { error: insertErr } = await svc
    .from('stripe_webhook_events')
    .insert({ stripe_event_id: event.id, event_type: event.type });
  if (insertErr) {
    if (insertErr.code === '23505') {
      console.log(
        `[stripe-webhook] duplicate event ${event.id} (${event.type}) — acking`,
      );
      return new Response('duplicate', { status: 200 });
    }
    console.error('[stripe-webhook] failed to record event', insertErr);
    return new Response('server error', { status: 500 });
  }

  try {
    await dispatch(svc, event);
    await svc
      .from('stripe_webhook_events')
      .update({ processed_at: new Date().toISOString() })
      .eq('stripe_event_id', event.id);
    return new Response('ok', { status: 200 });
  } catch (e) {
    const msg = (e as Error).message;
    console.error(`[stripe-webhook] handler failed for ${event.type}:`, msg);
    await svc
      .from('stripe_webhook_events')
      .update({ error: msg.slice(0, 500) })
      .eq('stripe_event_id', event.id);
    return new Response(`handler error: ${msg}`, { status: 500 });
  }
});

// ─────────────────────────────────────────────────────────────────────
// Dispatch
// ─────────────────────────────────────────────────────────────────────

async function dispatch(
  svc: ReturnType<typeof createClient>,
  event: StripeEvent,
): Promise<void> {
  switch (event.type) {
    case 'customer.subscription.created':
    case 'customer.subscription.updated':
      await upsertFromSubscription(
        svc,
        event.data.object as unknown as StripeSubscription,
      );
      return;

    case 'customer.subscription.deleted':
      await markCanceled(
        svc,
        event.data.object as unknown as StripeSubscription,
      );
      return;

    case 'invoice.payment_succeeded':
      console.log(
        `[stripe-webhook] invoice paid: ${(event.data.object as StripeInvoice).id}`,
      );
      return;

    case 'invoice.payment_failed': {
      const inv = event.data.object as unknown as StripeInvoice;
      console.log(
        `[stripe-webhook] invoice failed: ${inv.id} customer=${inv.customer}`,
      );
      // Mirror past_due immediately. The accompanying subscription
      // event will also fire and overwrite — this is belt-and-braces
      // for delivery-ordering edge cases.
      await svc
        .from('subscriptions')
        .update({ status: 'past_due', updated_at: new Date().toISOString() })
        .eq('provider_customer_id', inv.customer);
      // Look up the user to notify. The subscriptions row is the
      // bridge between Stripe customer id and our user_id.
      const { data: subRow } = await svc
        .from('subscriptions')
        .select('user_id')
        .eq('provider_customer_id', inv.customer)
        .maybeSingle();
      const userId = subRow?.user_id as string | undefined;
      if (userId) {
        await notify(userId, 'payment_failed', { invoice_id: inv.id });
      } else {
        console.warn(
          `[stripe-webhook] payment_failed: no subscriptions row for customer ${inv.customer}`,
        );
      }
      return;
    }

    default:
      console.log(`[stripe-webhook] unhandled event type: ${event.type}`);
      return;
  }
}

// ─────────────────────────────────────────────────────────────────────
// Subscription upsert — the core handler
// ─────────────────────────────────────────────────────────────────────

async function upsertFromSubscription(
  svc: ReturnType<typeof createClient>,
  sub: StripeSubscription,
): Promise<void> {
  // user_id is stamped on the subscription's metadata when
  // create-subscription builds the Stripe Customer and Subscription.
  // No metadata = no way to map this to a user. Loud error.
  const userId = sub.metadata?.user_id;
  if (!userId) {
    throw new Error(
      `subscription ${sub.id} has no user_id metadata — was create-subscription wired correctly?`,
    );
  }

  const priceId = sub.items?.data?.[0]?.price?.id;
  if (!priceId) {
    throw new Error(`subscription ${sub.id} has no price id`);
  }

  // Resolve price → plan_code via plan_limits. Single source of truth.
  const { data: planRow, error: planErr } = await svc
    .from('plan_limits')
    .select('plan_code')
    .eq('stripe_price_id', priceId)
    .maybeSingle();
  if (planErr) throw new Error(`plan lookup failed: ${planErr.message}`);
  if (!planRow) {
    throw new Error(
      `no plan_limits row for stripe_price_id=${priceId} — backfill required (see STRIPE_SETUP.md)`,
    );
  }
  const planCode = planRow.plan_code as string;
  const status = mapStripeStatus(sub.status);

  // Read the prior status *before* upserting so we can detect the
  // trialing→active transition and fire trial_converted exactly once.
  const { data: priorRow } = await svc
    .from('subscriptions')
    .select('status')
    .eq('user_id', userId)
    .maybeSingle();
  const priorStatus = (priorRow?.status as string | undefined) ?? null;

  const row = {
    user_id: userId,
    plan_code: planCode,
    status,
    provider: 'stripe' as const,
    provider_customer_id: sub.customer,
    provider_subscription_id: sub.id,
    stripe_price_id: priceId,
    current_period_end: sub.current_period_end
      ? new Date(sub.current_period_end * 1000).toISOString()
      : null,
    trial_end: sub.trial_end
      ? new Date(sub.trial_end * 1000).toISOString()
      : null,
    cancel_at_period_end: sub.cancel_at_period_end ?? false,
    canceled_at: sub.canceled_at
      ? new Date(sub.canceled_at * 1000).toISOString()
      : null,
    updated_at: new Date().toISOString(),
  };

  const { error } = await svc
    .from('subscriptions')
    .upsert(row, { onConflict: 'user_id' });
  if (error) throw new Error(`subscriptions upsert failed: ${error.message}`);

  console.log(
    `[stripe-webhook] upserted subscription user=${userId} plan=${planCode} status=${status} (prior=${priorStatus})`,
  );

  // Trial started: fire the welcome email once, the first time we
  // see this subscription enter the trialing state. priorStatus is
  // null when this is the very first event for the row (Stripe's
  // customer.subscription.created firing); checking that protects
  // against duplicate sends when Stripe re-delivers the same event.
  if (priorStatus === null && status === 'trialing') {
    await notify(userId, 'trial_started', {
      plan_label: planLabelFor(planCode),
      trial_end_human: sub.trial_end
        ? formatHumanDate(new Date(sub.trial_end * 1000))
        : undefined,
      subscription_id: sub.id,
    });
  }

  // Trial → active transition: fire trial_converted email once.
  // We rely on the exact prior-status check + the unified frequency
  // cap to prevent duplicates if Stripe re-delivers the event after
  // the row is already 'active'.
  if (priorStatus === 'trialing' && status === 'active') {
    await notify(userId, 'trial_converted', {
      plan_label: planLabelFor(planCode),
      subscription_id: sub.id,
    });
  }
}

function planLabelFor(planCode: string): string {
  switch (planCode) {
    case 'pro_monthly':  return 'Pro Monthly';
    case 'pro_semester': return 'Pro Semester';
    case 'pro_annual':   return 'Pro Annual';
    case 'pro_trial':    return 'Pro Trial';
    default:             return 'Pro';
  }
}

async function markCanceled(
  svc: ReturnType<typeof createClient>,
  sub: StripeSubscription,
): Promise<void> {
  // Pull current_period_end first — that's the human-meaningful "your
  // access continues through X" date we want to put in the email.
  const { data: priorRow } = await svc
    .from('subscriptions')
    .select('user_id, current_period_end')
    .eq('provider_subscription_id', sub.id)
    .maybeSingle();

  const { error } = await svc
    .from('subscriptions')
    .update({
      status: 'canceled',
      canceled_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq('provider_subscription_id', sub.id);
  if (error) throw new Error(`mark canceled failed: ${error.message}`);
  console.log(`[stripe-webhook] canceled subscription ${sub.id}`);

  const userId = priorRow?.user_id as string | undefined;
  if (userId) {
    await notify(userId, 'subscription_canceled', {
      access_until: formatHumanDate(priorRow?.current_period_end as string | null | undefined),
      subscription_id: sub.id,
    });
  }
}

function formatHumanDate(iso: string | null | undefined): string {
  if (!iso) return 'the end of your billing period';
  try {
    const d = new Date(iso);
    // "May 19, 2026" — readable across locales without depending on
    // the user's locale being set on the Edge runtime.
    return d.toLocaleDateString('en-US', {
      year: 'numeric', month: 'long', day: 'numeric',
    });
  } catch {
    return 'the end of your billing period';
  }
}

/// Stripe → our enum. Coalesce unpaid→past_due (same meaning) and
/// incomplete_expired→canceled (Stripe gave up). Unknown states get
/// treated as past_due so the user keeps caps while we investigate;
/// better than silently dropping them to free.
function mapStripeStatus(stripeStatus: string): string {
  switch (stripeStatus) {
    case 'trialing':
    case 'active':
    case 'past_due':
    case 'canceled':
    case 'incomplete':
    case 'paused':
      return stripeStatus;
    case 'unpaid':
      return 'past_due';
    case 'incomplete_expired':
      return 'canceled';
    default:
      console.warn(`[stripe-webhook] unknown Stripe status: ${stripeStatus}`);
      return 'past_due';
  }
}

// ─────────────────────────────────────────────────────────────────────
// HMAC-SHA256 signature verification
// ─────────────────────────────────────────────────────────────────────

interface VerifyResult { ok: boolean; reason?: string }

async function verifyStripeSignature(
  rawBody: string,
  sigHeader: string,
  secret: string,
): Promise<VerifyResult> {
  // Format: "t=<timestamp>,v1=<sig>,v1=<sig>,v0=<sig>..."
  const parts = sigHeader.split(',').reduce<Record<string, string[]>>(
    (acc, kv) => {
      const eqIdx = kv.indexOf('=');
      if (eqIdx < 0) return acc;
      const k = kv.slice(0, eqIdx);
      const v = kv.slice(eqIdx + 1);
      (acc[k] ||= []).push(v);
      return acc;
    },
    {},
  );
  const t = parts.t?.[0];
  const v1List = parts.v1 ?? [];
  if (!t || v1List.length === 0) {
    return { ok: false, reason: 'missing t or v1 in signature header' };
  }

  // Replay-window: reject events older than ~5 minutes.
  const eventTs = parseInt(t, 10);
  if (
    !eventTs ||
    Math.abs(Date.now() / 1000 - eventTs) > SIGNING_REPLAY_TOLERANCE_SEC
  ) {
    return { ok: false, reason: 'timestamp outside tolerance window' };
  }

  const payload = `${t}.${rawBody}`;
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sigBytes = await crypto.subtle.sign(
    'HMAC',
    key,
    new TextEncoder().encode(payload),
  );
  const computed = Array.from(new Uint8Array(sigBytes))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');

  // Stripe may send multiple v1 signatures during signing-secret rotation.
  // Match against any of them in constant time.
  const match = v1List.some((v) => constantTimeEq(v, computed));
  if (!match) return { ok: false, reason: 'no v1 signature matched HMAC' };
  return { ok: true };
}

function constantTimeEq(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}
