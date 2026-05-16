# Admin operations — Yve

Copy-pasteable SQL for the operational tasks that have no admin UI in
v1. Everything here uses the `user_limit_overrides` table (Phase 1) or
the `subscriptions` table directly. Run via:

- **Supabase dashboard** → SQL editor → paste → Run, OR
- **psql** with the project's direct connection string, OR
- **Management API** (`POST /v1/projects/{ref}/database/query` with
  `{"query":"..."}` body, Bearer token = PAT)

The `user_limit_overrides` row is what the entitlements resolver
overlays on top of the plan's defaults. NULL columns = use plan
default. Non-NULL columns = override the plan default. `expires_at`
NULL = permanent; set a date to have it auto-ignored after that point.

---

## Find a user's id from their email

```sql
select id, email, created_at
from auth.users
where email ilike 'someone@example.com';
```

Anonymous users (no email) — find them by recent activity:

```sql
select user_id, count(*) as messages, max(created_at) as last_seen
from chat_messages
where created_at > now() - interval '7 days'
group by user_id
order by max(created_at) desc
limit 20;
```

---

## Inspect a user's current entitlement

```sql
-- One-shot read showing plan, status, and any active override.
select
  s.user_id,
  coalesce(s.plan_code, 'free') as plan_code,
  coalesce(s.status, 'active')  as status,
  s.trial_end,
  s.current_period_end,
  s.cancel_at_period_end,
  o.chat_messages_per_day  as override_chat,
  o.scans_per_day          as override_scans,
  o.polish_runs_per_week   as override_polish,
  o.subjects_max           as override_subjects,
  o.storage_mb             as override_storage,
  o.reason                 as override_reason,
  o.expires_at             as override_expires
from auth.users u
left join subscriptions s          on s.user_id = u.id
left join user_limit_overrides o   on o.user_id = u.id
where u.id = 'USER_UUID_HERE';
```

---

## Grant overrides — by intent

The `reason` and `granted_by_admin_email` columns are required. Always
fill them in honestly — future-you (and your accountant) needs to know
why someone is on a non-standard plan.

### Beta tester — extended free pilot

Goal: bump a free user to 100 chats/day, 5 subjects, 1 GB storage,
for 90 days while they help shape the product.

```sql
insert into user_limit_overrides (
  user_id, chat_messages_per_day, scans_per_day,
  polish_runs_per_week, subjects_max, storage_mb,
  reason, granted_by_admin_email, expires_at
) values (
  'USER_UUID_HERE',
  100, 20,
  null, 5, 1024,
  'beta tester — extended pilot through Aug 2026',
  'ibrahim@getyve.com',
  now() + interval '90 days'
)
on conflict (user_id) do update set
  chat_messages_per_day = excluded.chat_messages_per_day,
  scans_per_day         = excluded.scans_per_day,
  subjects_max          = excluded.subjects_max,
  storage_mb            = excluded.storage_mb,
  reason                = excluded.reason,
  granted_by_admin_email= excluded.granted_by_admin_email,
  expires_at            = excluded.expires_at;
```

### Press / influencer comp — full Pro for 60 days

Goal: everything unlimited, time-bounded.

```sql
insert into user_limit_overrides (
  user_id,
  chat_messages_per_day, scans_per_day,
  polish_runs_per_week, polish_runs_per_day, polish_max_words,
  subjects_max, storage_mb, hard_daily_message_cap,
  reason, granted_by_admin_email, expires_at
) values (
  'USER_UUID_HERE',
  null, null,
  null, null, 10000,
  null, 10240, 500,
  'press comp — Verge review through 2026-07-15',
  'ibrahim@getyve.com',
  now() + interval '60 days'
)
on conflict (user_id) do update set
  chat_messages_per_day  = excluded.chat_messages_per_day,
  scans_per_day          = excluded.scans_per_day,
  polish_runs_per_week   = excluded.polish_runs_per_week,
  polish_runs_per_day    = excluded.polish_runs_per_day,
  polish_max_words       = excluded.polish_max_words,
  subjects_max           = excluded.subjects_max,
  storage_mb             = excluded.storage_mb,
  hard_daily_message_cap = excluded.hard_daily_message_cap,
  reason                 = excluded.reason,
  granted_by_admin_email = excluded.granted_by_admin_email,
  expires_at             = excluded.expires_at;
```

### ESL / education discount — Pro caps without Stripe

Goal: a learner can't afford $29 but has a real need. Give them Pro
caps for one academic year. NOT a substitute for the planned regional
pricing — use sparingly + record the reason.

```sql
insert into user_limit_overrides (
  user_id,
  chat_messages_per_day, scans_per_day,
  polish_runs_per_week, polish_runs_per_day, polish_max_words,
  subjects_max, storage_mb, hard_daily_message_cap,
  reason, granted_by_admin_email, expires_at
) values (
  'USER_UUID_HERE',
  null, null,
  null, null, 10000,
  null, 10240, 500,
  'ESL hardship grant — nursing program through 2027-05-15',
  'ibrahim@getyve.com',
  now() + interval '12 months'
);
```

### Founder grant — friends + family, permanent

Goal: lifetime Pro caps for someone you actually know. `expires_at`
NULL = no expiry. Use very sparingly.

```sql
insert into user_limit_overrides (
  user_id,
  chat_messages_per_day, scans_per_day,
  polish_runs_per_week, polish_runs_per_day, polish_max_words,
  subjects_max, storage_mb, hard_daily_message_cap,
  reason, granted_by_admin_email
) values (
  'USER_UUID_HERE',
  null, null,
  null, null, 10000,
  null, 10240, 500,
  'founder grant — early supporter',
  'ibrahim@getyve.com'
);
```

---

## Revoke an override

```sql
delete from user_limit_overrides where user_id = 'USER_UUID_HERE';
```

Or expire it on a specific date (kept in the table for audit):

```sql
update user_limit_overrides
   set expires_at = now()
 where user_id = 'USER_UUID_HERE';
```

The resolver ignores overrides whose `expires_at` is in the past, so
this immediately drops the user back to their plan defaults.

---

## See all active overrides (audit)

```sql
select
  o.user_id,
  u.email,
  o.reason,
  o.granted_by_admin_email,
  o.created_at,
  o.expires_at,
  case when o.expires_at is null then 'permanent'
       when o.expires_at < now() then 'expired'
       else 'active'
  end as state
from user_limit_overrides o
join auth.users u on u.id = o.user_id
order by o.created_at desc;
```

---

## Force-cancel a subscription (chargeback, fraud, abuse)

Stripe handles legitimate cancellations through the Customer Portal.
For everything else — chargeback win, suspected fraud, abuse review —
cancel on the Stripe side first, then let the webhook reconcile. If
the webhook can't deliver (Stripe outage), manually mark it:

```sql
update subscriptions
   set status = 'canceled',
       canceled_at = now(),
       updated_at  = now()
 where user_id = 'USER_UUID_HERE';
```

The user will drop to Free on their next entitlement read. Their data
is preserved. They can re-subscribe later via `/upgrade`, but the
no-second-trial guard will refuse (they had a trial_end on this row).

---

## Verify webhook delivery health

```sql
-- Recent failed webhooks (anything with error set OR processed_at NULL
-- and more than 5 min old).
select stripe_event_id, event_type, received_at, error
  from stripe_webhook_events
 where (error is not null)
    or (processed_at is null and received_at < now() - interval '5 minutes')
 order by received_at desc
 limit 50;
```

If anything appears here, the webhook handler hit an error. Most
likely causes:

- `no plan_limits row for stripe_price_id=…` → run the SQL backfill
  from `STRIPE_SETUP.md`, then replay the event in Stripe dashboard
  (Developers → Webhooks → click event → Resend).
- `subscription … has no user_id metadata` → the `create-subscription`
  function didn't stamp metadata. Fix the function, deploy, replay.

---

## Daily / weekly usage audit (for tuning caps)

How active are paying vs free users in practice?

```sql
-- Last 14 days, by plan tier.
select
  coalesce(s.plan_code, 'free') as plan,
  count(distinct du.user_id)    as users_active,
  avg(du.chat_turns)            as avg_chats_per_day,
  max(du.chat_turns)            as max_chats_per_day,
  avg(du.scan_count)            as avg_scans_per_day,
  max(du.scan_count)            as max_scans_per_day
from daily_usage du
left join subscriptions s on s.user_id = du.user_id
where du.day > current_date - interval '14 days'
group by coalesce(s.plan_code, 'free')
order by users_active desc;
```

If `max_chats_per_day` for free users is consistently hitting 10, your
free cap is biting — tune up. If `max_chats_per_day` for Pro users
never exceeds 50, your fair-use `hard_daily_message_cap` of 500 is way
overkill and could come down (though it's free to leave high).

```sql
-- Cap-hit rate by tier — directly tells you which users are
-- frustrated vs. comfortable.
select
  ue.plan_code,
  ue.kind,
  count(*) as hits,
  count(distinct ue.user_id) as users_affected
from usage_events ue
where ue.kind like '%cap_hit%'
  and ue.occurred_at > now() - interval '14 days'
group by ue.plan_code, ue.kind
order by hits desc;
```

A high free-user cap_hit rate means people are bouncing off your wall
before converting. A high Pro-user cap_hit rate means your fair-use
ceiling is too tight for engaged users.
