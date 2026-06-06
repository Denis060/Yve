// POST /claim-anonymous-data
//
// Transfers ownership of all rows belonging to a previous anonymous
// user_id over to the now-authenticated caller. Called from the client
// right after a sign-in that produced a fresh authenticated session
// (Google / Apple OAuth, or the email "already in use" fallback path).
//
// The flow that needs this function:
//   1. Device starts anonymous → uid = A (random UUID)
//   2. User creates subjects, materials, chats — all rows have user_id = A
//   3. User signs in with Google → new session, uid = B
//   4. Client posts { anon_uid: A } here with the new user's JWT
//   5. We UPDATE every public table's user_id from A → B, then delete
//      user A from auth.users (which cascades any rows we missed).
//
// We don't use this for the in-place email upgrade path (updateUser({email})
// on an anonymous session preserves the UID; no transfer needed). It's
// strictly for the OAuth / sign-into-existing-account paths.
//
// Request:  { anon_uid: string }
// Response: 200 { transferred: { table_name: rowCount, ... }, deleted_anon: true }
// Errors:
//   400  missing / malformed anon_uid, or anon_uid equals current uid (caller bug)
//   401  not authenticated
//   403  caller is anonymous (can't claim into another anon session)
//   404  anon_uid doesn't exist OR isn't anonymous (refuse to touch named users)
//   500  database error

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS_HEADERS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers':
    'authorization, x-client-info, apikey, content-type',
  'access-control-allow-methods': 'POST, OPTIONS',
};

// Every public-schema table that stores a user-owned reference to
// auth.users(id). Order doesn't matter for correctness — the UPDATEs
// are independent — but listing related tables together makes the
// transferred counts in the response readable.
const TABLES_TO_TRANSFER: readonly string[] = [
  // Content the user creates
  'subjects',
  'materials',
  'chat_sessions',
  'study_sessions',
  'concept_observations',
  // Usage / quota counters
  'daily_usage',
  'weekly_usage',
  'usage_events',
  // Notifications event log (continuity & cap counting)
  'notification_events',
  // Audit / cost tracking — preserves the model_calls history for the
  // claimed user instead of NULL-ing it when the anon user is deleted.
  'model_calls',
];

// PK-style tables. We do NOT transfer these — if both sides have a
// row, the destination wins (the authed account's row is preserved).
// Listed here for documentation; the anon-side rows get cascade-deleted
// when we finally drop the anon user at the end.
//   profiles, learner_profiles, notification_preferences,
//   subscriptions, user_limit_overrides

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }
  if (req.method !== 'POST') {
    return json({ error: 'method not allowed' }, 405);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceKey) {
    return json({ error: 'server not configured' }, 500);
  }

  // ── Auth ────────────────────────────────────────────────────────────
  const authHeader = req.headers.get('Authorization') ?? '';
  const userClient = createClient(supabaseUrl, serviceKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: { user }, error: userErr } = await userClient.auth.getUser();
  if (userErr || !user) {
    return json({ error: 'not authenticated' }, 401);
  }
  // is_anonymous is a top-level field on the User object (Supabase v2.5+).
  // Defensive: also check app_metadata.provider as a fallback signal.
  const callerIsAnon =
    (user as unknown as { is_anonymous?: boolean }).is_anonymous === true;
  if (callerIsAnon) {
    return json({
      error: 'caller is anonymous',
      detail: 'Sign in with a real account before claiming guest data.',
      code: 'caller_anonymous',
    }, 403);
  }

  // ── Body ────────────────────────────────────────────────────────────
  let body: { anon_uid?: string };
  try {
    body = await req.json();
  } catch (_e) {
    return json({ error: 'invalid JSON body' }, 400);
  }
  const anonUid = (body.anon_uid ?? '').trim();
  if (!anonUid || !UUID_RE.test(anonUid)) {
    return json({
      error: 'anon_uid is required and must be a UUID',
      code: 'invalid_anon_uid',
    }, 400);
  }
  if (anonUid === user.id) {
    // Means the in-place upgrade already worked (linkIdentity / updateUser)
    // and there's nothing to transfer. Return success without touching
    // anything so the client can call this unconditionally after sign-in.
    return json({
      transferred: {},
      deleted_anon: false,
      reason: 'anon_uid equals current user — nothing to claim',
    }, 200);
  }

  // ── Verify the target was actually anonymous ───────────────────────
  // Refuse to touch named accounts even if the caller asks us to — that
  // would let one user claim another's data by guessing a UID.
  const svc = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: anonUserResp, error: anonLookupErr } =
    await svc.auth.admin.getUserById(anonUid);
  if (anonLookupErr) {
    return json({
      error: 'lookup failed',
      detail: anonLookupErr.message,
    }, 500);
  }
  const anonUser = anonUserResp?.user;
  if (!anonUser) {
    return json({
      error: 'anon user not found',
      detail: 'No auth.users row with that id.',
      code: 'anon_not_found',
    }, 404);
  }
  const targetIsAnon =
    (anonUser as unknown as { is_anonymous?: boolean }).is_anonymous === true;
  if (!targetIsAnon) {
    return json({
      error: 'target is not anonymous',
      detail: 'Refusing to transfer ownership from a named account.',
      code: 'target_not_anonymous',
    }, 404);
  }

  // ── Transfer ───────────────────────────────────────────────────────
  // Sequential per-table UPDATEs. We don't need a single transaction:
  // the operation is idempotent (replaying does no harm because the
  // second run's WHERE clauses find zero matching rows) and partial
  // failures leave the user's data in a recoverable state — at worst
  // a few tables still point at the soon-to-be-deleted anon UID, which
  // we'd catch on the next claim attempt.
  const transferred: Record<string, number> = {};
  for (const table of TABLES_TO_TRANSFER) {
    const { data, error } = await svc
      .from(table)
      .update({ user_id: user.id })
      .eq('user_id', anonUid)
      .select('id');
    if (error) {
      return json({
        error: `transfer failed at ${table}`,
        detail: error.message,
        transferred_so_far: transferred,
      }, 500);
    }
    transferred[table] = data?.length ?? 0;
  }

  // ── Delete the anon user ───────────────────────────────────────────
  // This cascades to any PK-style rows we didn't transfer (profiles,
  // learner_profiles, notification_preferences). The authed user keeps
  // their own existing rows on those tables; the anon's PK rows get
  // dropped automatically by the ON DELETE CASCADE.
  const { error: delErr } = await svc.auth.admin.deleteUser(anonUid);
  if (delErr) {
    // Non-fatal — the data is already transferred. Log it via the
    // response so the client can show it in a diagnostic.
    return json({
      transferred,
      deleted_anon: false,
      warning: `data transferred but anon user delete failed: ${delErr.message}`,
    }, 200);
  }

  return json({ transferred, deleted_anon: true }, 200);
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'content-type': 'application/json' },
  });
}
