// A Supabase client that runs as the service role for server-only
// writes — usage counters, audit events, subscription updates.
//
// The yve-chat client (and other Edge Function clients that need to
// resolve auth.uid()) is built with the user's Authorization header
// passed through; that means PostgREST evaluates RLS *as the user*,
// even though we provide the service-role key. Useful for chat_messages
// inserts where we want the user's own context — but it silently
// breaks writes to tables that have no self-insert policy.
//
// This helper builds a separate client with no user Authorization
// header, so writes bypass RLS as intended.

import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';

let cached: SupabaseClient | null = null;

export function getServiceClient(): SupabaseClient {
  if (cached) return cached;
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) {
    throw new Error('SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY not set');
  }
  cached = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return cached;
}
