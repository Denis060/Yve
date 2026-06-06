// POST /resend-webhook   — Resend → Yve email delivery lifecycle
//
// Receives Resend's delivery events and updates email_send_log + the
// suppression list. We do NOT retry sends on our end; Resend handles
// delivery retries internally.
//
// Events handled:
//   email.sent              informational
//   email.delivered         state → delivered
//   email.opened            state → opened (or higher)
//   email.clicked           state → clicked
//   email.delivery_delayed  log only
//   email.bounced           state → bounced; if hard, suppress address
//   email.complained        state → complained; suppress address +
//                             flip user's continuity/recap prefs off
//                             (because they signaled they don't want
//                             email from us)
//
// Signature verification uses Resend's Svix-style headers:
//   svix-id, svix-timestamp, svix-signature
// Computed as base64(HMAC-SHA256(secret, `${id}.${timestamp}.${body}`)),
// compared against any of the comma-separated v1 sigs.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SIGNING_REPLAY_TOLERANCE_SEC = 300;

interface ResendEvent {
  type: string;
  created_at: string;
  data: {
    email_id?: string;
    to?: string[];
    subject?: string;
    bounce?: { type?: string; message?: string };
    complaint?: { type?: string };
    [key: string]: unknown;
  };
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response('method not allowed', { status: 405 });
  }

  const signingSecret = Deno.env.get('RESEND_WEBHOOK_SECRET');
  if (!signingSecret) {
    console.error('RESEND_WEBHOOK_SECRET not set');
    return new Response('server not configured', { status: 500 });
  }

  const svixId = req.headers.get('svix-id');
  const svixTs = req.headers.get('svix-timestamp');
  const svixSig = req.headers.get('svix-signature');
  if (!svixId || !svixTs || !svixSig) {
    return new Response('missing svix headers', { status: 400 });
  }

  const rawBody = await req.text();
  const verified = await verifySvixSignature({
    id: svixId,
    timestamp: svixTs,
    sigHeader: svixSig,
    body: rawBody,
    secret: signingSecret,
  });
  if (!verified.ok) {
    console.error('Resend signature verification failed:', verified.reason);
    return new Response(`signature invalid: ${verified.reason}`, { status: 400 });
  }

  let event: ResendEvent;
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

  try {
    await dispatch(svc, event);
    return new Response('ok', { status: 200 });
  } catch (e) {
    console.error(`[resend-webhook] handler failed for ${event.type}:`, e);
    return new Response(`handler error: ${(e as Error).message}`, { status: 500 });
  }
});

// ─────────────────────────────────────────────────────────────────────
// Dispatch
// ─────────────────────────────────────────────────────────────────────

async function dispatch(
  svc: ReturnType<typeof createClient>,
  event: ResendEvent,
): Promise<void> {
  const resendId = event.data.email_id;
  if (!resendId) {
    console.warn(`[resend-webhook] event ${event.type} has no email_id`);
    return;
  }

  const now = new Date().toISOString();

  switch (event.type) {
    case 'email.sent':
      // Send-log row was already inserted by notify() when we got
      // the API response. Nothing to do.
      return;

    case 'email.delivered':
      await updateState(svc, resendId, {
        state: 'delivered',
        delivered_at: now,
      });
      return;

    case 'email.opened':
      // Don't downgrade — if we're already at 'clicked', stay there.
      await updateState(svc, resendId, {
        state: 'opened',
        opened_at: now,
      }, { onlyIfStateIn: ['sent', 'delivered'] });
      return;

    case 'email.clicked':
      await updateState(svc, resendId, {
        state: 'clicked',
        clicked_at: now,
      });
      return;

    case 'email.delivery_delayed':
      // Log but don't change state. Resend keeps retrying.
      console.log(`[resend-webhook] delivery_delayed: ${resendId}`);
      return;

    case 'email.bounced': {
      const bounceType = event.data.bounce?.type ?? 'unknown';
      const bounceMsg = event.data.bounce?.message ?? '';
      await updateState(svc, resendId, {
        state: 'bounced',
        state_detail: `${bounceType}: ${bounceMsg}`.slice(0, 500),
        bounced_at: now,
      });
      // Hard bounce → suppress so we never email this address again.
      // Soft bounces (mailbox full, temporary) we leave; Resend
      // surfaces those as delivery_delayed.
      if (bounceType.toLowerCase().includes('hard')) {
        await suppressAddress(svc, resendId, 'hard_bounce');
      }
      return;
    }

    case 'email.complained': {
      const complaintType = event.data.complaint?.type ?? 'spam';
      await updateState(svc, resendId, {
        state: 'complained',
        state_detail: complaintType.slice(0, 500),
        complained_at: now,
      });
      // Complaint = user marked Yve as spam. Suppress AND flip
      // their continuity + recap prefs off — they signaled they
      // don't want non-transactional email from us.
      await suppressAddress(svc, resendId, 'complaint');
      await disableNonTransactionalEmail(svc, resendId);
      return;
    }

    default:
      console.log(`[resend-webhook] unhandled event type: ${event.type}`);
      return;
  }
}

// ─────────────────────────────────────────────────────────────────────
// State updates
// ─────────────────────────────────────────────────────────────────────

async function updateState(
  svc: ReturnType<typeof createClient>,
  resendId: string,
  fields: Record<string, unknown>,
  options: { onlyIfStateIn?: string[] } = {},
): Promise<void> {
  let q = svc
    .from('email_send_log')
    .update(fields)
    .eq('resend_id', resendId);
  if (options.onlyIfStateIn) {
    q = q.in('state', options.onlyIfStateIn);
  }
  const { error } = await q;
  if (error) {
    console.error(`[resend-webhook] state update failed for ${resendId}:`, error);
  }
}

async function suppressAddress(
  svc: ReturnType<typeof createClient>,
  resendId: string,
  reason: 'hard_bounce' | 'complaint',
): Promise<void> {
  // Look up the address for this send.
  const { data } = await svc
    .from('email_send_log')
    .select('to_email')
    .eq('resend_id', resendId)
    .maybeSingle();
  const toEmail = (data?.to_email as string | undefined)?.toLowerCase();
  if (!toEmail) return;

  await svc.from('email_suppression').upsert(
    {
      email: toEmail,
      reason,
      resend_id: resendId,
    },
    { onConflict: 'email' },
  );
  console.log(`[resend-webhook] suppressed ${toEmail} (${reason})`);
}

async function disableNonTransactionalEmail(
  svc: ReturnType<typeof createClient>,
  resendId: string,
): Promise<void> {
  // Find the user this address belongs to + flip prefs off.
  const { data } = await svc
    .from('email_send_log')
    .select('user_id')
    .eq('resend_id', resendId)
    .maybeSingle();
  const userId = data?.user_id as string | undefined;
  if (!userId) return;

  await svc.from('notification_preferences').upsert(
    {
      user_id: userId,
      continuity: false,
      recap: false,
      async: false,
      updated_at: new Date().toISOString(),
    },
    { onConflict: 'user_id' },
  );
}

// ─────────────────────────────────────────────────────────────────────
// Svix signature verification
// ─────────────────────────────────────────────────────────────────────

interface VerifyArgs {
  id: string;
  timestamp: string;
  sigHeader: string;
  body: string;
  secret: string;
}

interface VerifyResult { ok: boolean; reason?: string }

async function verifySvixSignature(args: VerifyArgs): Promise<VerifyResult> {
  // Replay window
  const ts = parseInt(args.timestamp, 10);
  if (
    !ts ||
    Math.abs(Date.now() / 1000 - ts) > SIGNING_REPLAY_TOLERANCE_SEC
  ) {
    return { ok: false, reason: 'timestamp outside tolerance window' };
  }

  // Resend's signing secret is base64 with a 'whsec_' prefix.
  const secretRaw = args.secret.startsWith('whsec_')
    ? args.secret.slice('whsec_'.length)
    : args.secret;
  const secretBytes = base64Decode(secretRaw);

  const key = await crypto.subtle.importKey(
    'raw',
    secretBytes,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const payload = `${args.id}.${args.timestamp}.${args.body}`;
  const sigBytes = await crypto.subtle.sign(
    'HMAC',
    key,
    new TextEncoder().encode(payload),
  );
  const computed = base64Encode(new Uint8Array(sigBytes));

  // svix-signature is "v1,<base64>" possibly with multiple v1 entries
  // separated by spaces. Match against any.
  const presented = args.sigHeader
    .split(' ')
    .map((s) => s.trim())
    .filter((s) => s.startsWith('v1,'))
    .map((s) => s.slice('v1,'.length));

  if (presented.length === 0) {
    return { ok: false, reason: 'no v1 signature in header' };
  }
  const match = presented.some((v) => constantTimeEq(v, computed));
  if (!match) return { ok: false, reason: 'no v1 signature matched HMAC' };
  return { ok: true };
}

function base64Decode(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function base64Encode(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s);
}

function constantTimeEq(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}
