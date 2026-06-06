// POST /delete-material
//
// Deletes a material the authed user owns. The material_chunks rows
// for it cascade-delete via the FK (confirmed via pg_constraint).
//
// Request:  { material_id: string }
// Response: 200 { deleted: 1 }
// Errors:
//   400  missing/invalid material_id
//   401  not authenticated
//   404  no material with that id owned by this user
//
// Ownership is enforced with an explicit user_id match in the DELETE
// (rather than relying on RLS) so the function works the same whether
// the materials table has a self-delete policy or not.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

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

  let body: { material_id?: string };
  try {
    body = await req.json();
  } catch (_e) {
    return json({ error: 'invalid JSON body' }, 400);
  }
  const materialId = body.material_id;
  if (!materialId) {
    return json({ error: 'material_id is required' }, 400);
  }

  const svc = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Single ownership-scoped DELETE. material_chunks rows cascade out
  // automatically via the FK. Returns the deleted rows so we can tell
  // 200-deleted from 404-not-found-for-this-user.
  const { data, error } = await svc
    .from('materials')
    .delete()
    .eq('id', materialId)
    .eq('user_id', user.id)
    .select('id');
  if (error) {
    return json({
      error: 'delete failed',
      detail: error.message,
    }, 500);
  }
  if (!data || data.length === 0) {
    return json({
      error: 'not found',
      detail: "That material doesn't exist or doesn't belong to you.",
    }, 404);
  }

  return json({ deleted: data.length }, 200);
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'content-type': 'application/json' },
  });
}
