# Resend setup — Yve email infrastructure

End-to-end wiring of Resend as Yve's email sender. Three integration
points:

1. **Outbound product email** (via `notify()` in `_shared/notifications.ts`)
   — uses the Resend HTTP API directly.
2. **Inbound delivery events** (bounces, complaints, opens, clicks)
   — handled by `supabase/functions/resend-webhook`.
3. **Supabase auth emails** (magic link OTP, password recovery)
   — Supabase Auth → SMTP Settings → point at Resend's SMTP server so
   our OTP codes also ship from `yve@getyve.com`.

Total setup time: ~30 minutes if your DNS provider is responsive.

---

## 1. Create the Resend account

[resend.com](https://resend.com) → sign up. Free tier gives 3,000 emails/month
and 100/day. Plenty for v1.

After signup:

- **API keys** → create one named `yve-production`. Save the key (`re_…`).
  You'll set it as `RESEND_API_KEY` on the Edge Functions project later.
- **Webhooks** → defer until step 5 below (we need the function URL first).

---

## 2. Add getyve.com as a sending domain

Resend dashboard → **Domains** → **Add Domain** → `getyve.com`.

Resend will generate 3 DNS records you need to add at your registrar:

- **SPF** — TXT record at root `getyve.com`. Resend's value usually
  reads `v=spf1 include:_spf.resend.com ~all` or similar. If you
  already have an SPF record (Google Workspace, etc.), MERGE the
  `include:` clause into the existing record — don't add a second TXT,
  most DNS validators will then ignore both.
- **DKIM** — TXT record at a subdomain like `resend._domainkey.getyve.com`.
  Long base64 string. Paste verbatim.
- **DMARC** — TXT record at `_dmarc.getyve.com`. Recommended value
  for v1: `v=DMARC1; p=none; rua=mailto:postmaster@getyve.com`.
  `p=none` means "monitor only" — safer to start there and tighten
  to `p=quarantine` or `p=reject` after 30 days of clean reports.

Add all three at your DNS provider (Cloudflare, Namecheap, Squarespace,
whatever). DNS propagation usually settles in 5–60 minutes.

In Resend, click **Verify domain**. Wait for all three records to flip
green. **Do not send a single email before all three are green.** Sending
from an unverified domain bakes in a bad sender reputation immediately
that's painful to undo.

---

## 3. Confirm the sender identity

After domain verification, Resend lets you send from any address
on `getyve.com`. Confirm these two mailbox conventions:

- **From:** `Yve ✦ <yve@getyve.com>` — the ✦ is intentional, it's
  part of the brand voice.
- **Reply-To:** `hello@getyve.com` — even if you don't actively monitor
  this inbox, the *affordance* of being able to reply matters. Set up
  forwarding from `hello@getyve.com` to your personal inbox via your
  email host so replies don't disappear into the void.

These are the defaults in `_shared/notifications.ts`. Override via
env vars if needed:

```
RESEND_FROM="Yve ✦ <yve@getyve.com>"
RESEND_REPLY_TO="hello@getyve.com"
```

---

## 4. Set RESEND_API_KEY on the Supabase project

```bash
PAT="<your supabase PAT>"
REF="ftekdhcomxxhbihvsyyw"

curl -X POST "https://api.supabase.com/v1/projects/$REF/secrets" \
  -H "Authorization: Bearer $PAT" \
  -H "Content-Type: application/json" \
  -d '[{"name":"RESEND_API_KEY","value":"re_YOUR_KEY_HERE"}]'
```

Or via the Supabase dashboard → Project Settings → Edge Functions → Secrets.

This unblocks `notify()` to actually call the Resend API. Until this
is set, the router logs every email it *would* have sent and writes a
`failed` row to `email_send_log` with `state_detail=RESEND_API_KEY not configured`
— useful for testing without burning sends.

---

## 5. Register the webhook endpoint

The `resend-webhook` Edge Function is already deployed at:

```
https://ftekdhcomxxhbihvsyyw.supabase.co/functions/v1/resend-webhook
```

Resend dashboard → **Webhooks** → **Add endpoint**:

- **Endpoint URL:** the URL above
- **Events to send:** check all of these:
  - `email.sent`
  - `email.delivered`
  - `email.opened`
  - `email.clicked`
  - `email.delivery_delayed`
  - `email.bounced`
  - `email.complained`

After creating, click **Reveal signing secret** and copy the `whsec_…`
value. Set it on the Supabase project:

```bash
curl -X POST "https://api.supabase.com/v1/projects/$REF/secrets" \
  -H "Authorization: Bearer $PAT" \
  -H "Content-Type: application/json" \
  -d '[{"name":"RESEND_WEBHOOK_SECRET","value":"whsec_YOUR_SECRET_HERE"}]'
```

To verify the wiring: Resend dashboard → Webhooks → click the endpoint
→ **Send test event**. The function should respond 200; check
`stripe_webhook_events` for the audit trail (wait — that's the wrong
table for Resend tests; the resend-webhook doesn't persist its own
event log because Resend has its own retry-and-dashboard side, so the
verification is the 200 response in Resend's webhook event log).

---

## 6. Route Supabase Auth emails through Resend

This is the move that makes the magic-link OTP also ship from
`yve@getyve.com` instead of Supabase's default `noreply@mail.supabase.io`.

Supabase dashboard → **Authentication** → **Email Templates** →
**SMTP Settings** (it's at the bottom of the templates page).

Toggle **Enable Custom SMTP** and fill in:

| Field | Value |
|---|---|
| **Host** | `smtp.resend.com` |
| **Port** | `465` (or `587` for STARTTLS) |
| **Username** | `resend` |
| **Password** | your `re_…` API key (yes, the API key — Resend uses it as the SMTP password) |
| **Sender email** | `yve@getyve.com` |
| **Sender name** | `Yve ✦` |
| **Minimum interval between emails per user** | leave default |

Click **Save**. Supabase will now route every auth email (magic link,
email change confirmation, signup confirmation) through Resend.

The OTP templates we wrote in migration 0014 era stay exactly as they
are — they use `{{ .Token }}` which Supabase resolves before sending.
The only difference: the sender address + the deliverability headers
now belong to `getyve.com`.

**Note on the Supabase free SMTP rate limit:** Supabase's built-in SMTP
caps at ~3–4 emails/hour per project. The moment you switch to Resend
SMTP, that cap goes away (replaced by Resend's much higher tier limits).

---

## 7. Smoke test

```bash
# Trigger a magic link OTP for an email you control.
curl -X POST "https://$REF.supabase.co/auth/v1/otp" \
  -H "apikey: <anon key>" \
  -H "Content-Type: application/json" \
  -d '{"email":"you@example.com","create_user":true}'
```

Expected:
- Email arrives in inbox in <30 seconds
- From: `Yve ✦ <yve@getyve.com>`
- Subject: `Your Yve sign-in code`
- Body has a 6-digit code prominently displayed
- DKIM/SPF show green in the email client's "show details"
- Resend dashboard → Logs shows the send
- Resend dashboard → Webhooks shows `email.sent` and `email.delivered`
  events fired (within ~minutes)
- `email_send_log` table has a new row with `state='delivered'`

If any of those fail, work backwards from the failure point.

---

## 8. Smoke test a notify() send

Once `RESEND_API_KEY` is set, call `notify()` from any Edge Function:

```ts
import { notify } from '../_shared/notifications.ts';

await notify('USER_UUID', 'trial_ending_24h', { plan_label: 'Pro Semester' });
```

Expected:
- A row in `notification_events` with `status='sent'` and
  `channels_attempted=['email', 'in_app']`
- A row in `email_send_log` with `state='sent'` (then 'delivered'
  once the webhook fires)
- The email arrives in the user's inbox

---

## 9. Operations checklist

Once everything's wired and live, here's what to monitor:

```sql
-- Bounces/complaints from the last 7 days.
select state, count(*)
from email_send_log
where sent_at > now() - interval '7 days'
  and state in ('bounced', 'complained', 'failed')
group by state;

-- Suppressed addresses.
select email, reason, created_at from email_suppression order by created_at desc limit 20;

-- Notification volume by category in the last 7 days.
select category, status, count(*)
from notification_events
where created_at > now() - interval '7 days'
group by category, status
order by category, status;
```

A complaint rate above 0.1% is concerning. A bounce rate above 5% is
critical and will tank deliverability for all users — investigate
immediately (usually means we're trying to send to invalid addresses).

---

## What's NOT in this setup

- **Per-user email preferences UI** — the schema supports it
  (`notification_preferences`), but the settings screen to expose it
  isn't built yet. Plan to ship that alongside the first non-
  transactional email (Phase 6.2).
- **Templated React Email / MJML rendering** — the v1 templates are
  inline HTML strings in `_shared/notifications.ts`. They look fine
  in any client, render readably as plain text, and are easy to edit.
  Move to a template engine only when we have enough emails that
  inline HTML becomes painful.
- **Send-time analytics** — Resend tracks opens + clicks at the
  email level. We don't aggregate them into a dashboard yet. Use the
  SQL above for ad-hoc rollups.
- **A/B testing email subject lines** — not for v1. Calibrate by
  observation first.
