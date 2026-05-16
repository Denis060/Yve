# Stripe setup — Yve monetization Phase 1

Step-by-step to connect Stripe to the three pricing tiers. Do this in
the Stripe **test mode** first; the same steps work in live mode when
you flip the toggle.

This connects:

- Three products + prices (Monthly, Semester, Annual) → `plan_limits.stripe_price_id`
- A webhook endpoint → `stripe-webhook` Edge Function
- One signing secret → `STRIPE_WEBHOOK_SECRET` env var

Total time: ~15 minutes if you've used Stripe before.

---

## 1. Create the three Pro products in Stripe

Stripe dashboard → **Products** → **+ Add product**.

### Pro Monthly

| Field | Value |
|---|---|
| Name | `Pro Monthly` |
| Description | `Yve Pro — month-to-month. Cancel anytime.` |
| Pricing model | Standard pricing |
| Price | `$29.00` USD |
| Billing period | Monthly (`interval=month`, `interval_count=1`) |
| Tax behavior | Exclusive (or per your jurisdiction) |

After creating, copy the **Price ID** (starts with `price_…`).

### Pro Semester

| Field | Value |
|---|---|
| Name | `Pro Semester` |
| Description | `Yve Pro through finals — 4 months of Pro at a saving.` |
| Pricing model | Standard pricing |
| Price | `$89.00` USD |
| Billing period | Custom: `interval=month`, `interval_count=4` |
| Tax behavior | Exclusive |

Copy the Price ID.

> **Note on the 4-month interval:** Stripe doesn't have a native
> "semester" interval. We use `interval=month, interval_count=4`, which
> means renewals happen 4 calendar months from signup. For someone
> signing up Aug 15, renewal lands Dec 15 — comfortably past finals
> for most US academic semesters.

### Pro Annual

| Field | Value |
|---|---|
| Name | `Pro Annual` |
| Description | `Yve Pro for a year — best per-month price.` |
| Pricing model | Standard pricing |
| Price | `$229.00` USD |
| Billing period | Yearly (`interval=year`, `interval_count=1`) |
| Tax behavior | Exclusive |

Copy the Price ID.

---

## 2. Backfill the Price IDs into plan_limits

The `stripe_price_id` columns on `plan_limits` are NULL today (only
populated for paid tiers). Run this SQL once you have the three IDs:

```sql
update public.plan_limits set stripe_price_id = 'price_…MONTHLY'  where plan_code = 'pro_monthly';
update public.plan_limits set stripe_price_id = 'price_…SEMESTER' where plan_code = 'pro_semester';
update public.plan_limits set stripe_price_id = 'price_…ANNUAL'   where plan_code = 'pro_annual';
```

Verify:

```sql
select plan_code, stripe_price_id from public.plan_limits where plan_code like 'pro_%';
```

All three should show `price_…` values. The webhook resolver looks up
`plan_code` by `stripe_price_id` — if a Stripe event references a
price not in this table, the webhook fails loudly with "no plan_limits
row for stripe_price_id=… — backfill required (see STRIPE_SETUP.md)".

---

## 3. Create the webhook endpoint

Stripe dashboard → **Developers** → **Webhooks** → **+ Add endpoint**.

| Field | Value |
|---|---|
| Endpoint URL | `https://ftekdhcomxxhbihvsyyw.supabase.co/functions/v1/stripe-webhook` |
| API version | Latest (default) |
| Events to send | See list below |

**Events to subscribe to:**

- `customer.subscription.created`
- `customer.subscription.updated`
- `customer.subscription.deleted`
- `invoice.payment_succeeded`
- `invoice.payment_failed`

That's the complete list. The handler ignores any other event type
with a 200 ack and a log line.

After creating, click **Reveal signing secret** and copy the
`whsec_…` value.

---

## 4. Set the signing secret as an Edge Function env var

The webhook handler reads `STRIPE_WEBHOOK_SECRET` from the function's
environment. Set it via the Supabase dashboard or CLI:

**Supabase dashboard:** Project → Edge Functions → `stripe-webhook` →
Secrets → Add secret.

**Supabase CLI:**

```bash
supabase secrets set --project-ref ftekdhcomxxhbihvsyyw \
  STRIPE_WEBHOOK_SECRET=whsec_…
```

**Management API:**

```bash
curl -X PATCH "https://api.supabase.com/v1/projects/ftekdhcomxxhbihvsyyw/secrets" \
  -H "Authorization: Bearer $SUPABASE_PAT" \
  -H "Content-Type: application/json" \
  -d '[{"name":"STRIPE_WEBHOOK_SECRET","value":"whsec_…"}]'
```

You also need `STRIPE_SECRET_KEY` set the same way (your `sk_test_…`
or `sk_live_…`) for the create-subscription path that ships in Phase 2.

---

## 5. Smoke-test the webhook end-to-end

Stripe dashboard → **Developers** → **Webhooks** → click your endpoint
→ **Send test webhook**.

Send a `customer.subscription.created` test event. Stripe will populate
fake data; the handler will:

1. Verify the signature (passes — same `whsec_…` secret).
2. Insert into `stripe_webhook_events` (idempotency log).
3. Try to resolve the price ID → plan_code. Stripe's test fixture uses
   a fake price, so this will **fail with "no plan_limits row for
   stripe_price_id=…"**. This is expected and proves the lookup is
   wired correctly.

To smoke-test a real path, use the [Stripe CLI](https://stripe.com/docs/stripe-cli):

```bash
stripe listen --forward-to https://ftekdhcomxxhbihvsyyw.supabase.co/functions/v1/stripe-webhook
stripe trigger customer.subscription.created
```

(But this also uses Stripe's test fixture prices — so still fails the
lookup unless you point the trigger at one of your real test prices.)

The most reliable end-to-end smoke test is to actually walk through a
checkout in the app once Phase 2 (`create-subscription` + the upgrade
UI) is shipped.

---

## 6. Webhook delivery sanity checks

Once your webhook has been live for a day:

- `stripe_webhook_events` table should have rows with `processed_at`
  set and `error` NULL. Any row with a non-NULL `error` is a webhook
  that failed — Stripe will retry, but investigate the cause.
- `subscriptions` should have one row per paying user with
  `provider_subscription_id` matching the Stripe dashboard.

If you see `unhandled event type: …` in the function logs for an
event you actually wanted to handle, add it to the `switch` in
`stripe-webhook/index.ts` and redeploy.

---

## 7. Going live

When ready to switch from test to live mode:

1. Repeat steps 1–4 in Stripe's **live** mode (separate products,
   separate prices, separate webhook, separate signing secret).
2. Run the SQL backfill again with the live `price_…` IDs.
3. Update `STRIPE_WEBHOOK_SECRET` and `STRIPE_SECRET_KEY` env vars to
   the live values.
4. The webhook URL stays the same — just the secret it validates
   against changes.

---

## Customer metadata contract

The webhook handler relies on `subscription.metadata.user_id` to know
which Yve account a Stripe subscription belongs to. The Phase 2
`create-subscription` route is responsible for stamping that metadata
when it builds the Stripe Customer and Subscription. Specifically:

- On Customer create: `metadata: { user_id: <auth.uid> }`
- On Subscription create: `metadata: { user_id: <auth.uid> }` AND
  pass `subscription_data: { metadata: { user_id: <auth.uid> } }` so
  the metadata is on both the customer and the subscription.

The webhook reads from the subscription's metadata, but having it on
the customer too is belt-and-braces in case Stripe ever returns a
subscription event with missing subscription metadata (it shouldn't,
but defensive coding pays here).

If the webhook ever errors with `subscription … has no user_id
metadata`, it means `create-subscription` was deployed without the
metadata-stamping logic. Fix that route, then **manually replay** the
failed events from the Stripe dashboard webhook page.
