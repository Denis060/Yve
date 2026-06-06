// POST /create-subject
//
// Creates a subject for the authed user, enforcing the per-tier
// subjects_max cap server-side. For anonymous users this is the cap
// gate that stops them from adding a 2nd subject (lifetime cap of 1
// per the anonymous plan).
//
// Request:
//   {
//     name: string,
//     emoji?: string,
//     color_seed?: number,
//   }
//
// Response (200):
//   { id, user_id, name, emoji, color_seed, ...row }
//
// Errors:
//   400  missing/invalid name
//   401  not authenticated
//   409  subject cap reached for the user's tier
//         (anonymous: code='anonymous_subject_limit')
//         (free:      code='subject_limit')
//   500  insert failure
//
// Once the user upgrades from anonymous → authed via in-place
// linkIdentity / updateUser, the same user_id is preserved and the
// existing guest subject carries forward — they just gain the ability
// to add more.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

import { loadEntitlement } from '../_shared/entitlements.ts';

const CORS_HEADERS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers':
    'authorization, x-client-info, apikey, content-type',
  'access-control-allow-methods': 'POST, OPTIONS',
};

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

  const authHeader = req.headers.get('Authorization') ?? '';
  const userClient = createClient(supabaseUrl, serviceKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: { user }, error: userErr } = await userClient.auth.getUser();
  if (userErr || !user) {
    return json({ error: 'not authenticated' }, 401);
  }

  let body: { name?: string; emoji?: string; color_seed?: number };
  try {
    body = await req.json();
  } catch (_e) {
    return json({ error: 'invalid JSON body' }, 400);
  }
  const name = (body.name ?? '').trim();
  if (!name) {
    return json({ error: 'name is required' }, 400);
  }

  const svc = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Cap gate. Anonymous users have subjects_max=1 lifetime; free users
  // also have subjects_max=1 today (per plan_limits); Pro is null
  // (unlimited).
  const entitlement = await loadEntitlement(
    userClient,
    user.id,
    user.is_anonymous === true,
  );
  const cap = entitlement.caps.subjectsMax;
  if (cap !== null) {
    const { count } = await svc
      .from('subjects')
      .select('*', { count: 'exact', head: true })
      .eq('user_id', user.id)
      .is('archived_at', null);
    if ((count ?? 0) >= cap) {
      const isAnonymous = entitlement.planCode === 'anonymous';
      return json({
        error: isAnonymous
          ? "You've started one subject as a guest."
          : "You're at the subjects limit for your plan.",
        code: isAnonymous ? 'anonymous_subject_limit' : 'subject_limit',
        used: count,
        limit: cap,
        plan: entitlement.planCode,
      }, 409);
    }
  }

  const { data, error } = await svc
    .from('subjects')
    .insert({
      user_id: user.id,
      name,
      emoji: body.emoji ?? '✦',
      color_seed: body.color_seed ?? 0,
    })
    .select()
    .single();
  if (error || !data) {
    return json({
      error: 'create failed',
      detail: error?.message ?? 'no row returned',
    }, 500);
  }

  return json(data, 200);
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'content-type': 'application/json' },
  });
}
