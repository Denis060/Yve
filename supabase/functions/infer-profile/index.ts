// POST /infer-profile
//
// Yve observes the learner from their chat history and writes a short
// adaptation note (and optionally a writing-voice note) into the auto_*
// columns on learner_profiles. The user-set columns are never overwritten.
//
// Manual trigger only for now — the client invokes this from the Profile
// tab's "Refresh" control. Periodic background inference lands later.
//
// Request: {} (operates on the authed user)
//
// Response:
//   {
//     auto_observed_patterns: string,
//     auto_voice_notes: string | null,
//     last_inferred_at: string,
//     turns_considered: number,
//   }

import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { trackCall } from '../_shared/providers/observability.ts';
import { route } from '../_shared/providers/router.ts';
import type { ProviderMessage } from '../_shared/providers/types.ts';

const CORS_HEADERS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers':
    'authorization, x-client-info, apikey, content-type',
  'access-control-allow-methods': 'POST, OPTIONS',
};

const INFER_SYSTEM_PROMPT = `You are observing a learner's chat history with Yve to write a short, useful adaptation note that Yve will honor in future conversations.

Look at:
- What subjects and concepts they engage with (and which they struggle vs. grasp)
- How they phrase questions — terse and transactional? Exploratory? Often asking for "simplify" or "harder"?
- The shape of their requests — assignment-heavy, curiosity-driven, exam-prep, writing polish?
- When they use the app (time-of-day patterns from timestamps)
- Whether they prefer worked examples first, formulas first, or analogies

Write two short notes:
- observed_patterns (required): 2–4 sentences in third-person describing actionable adaptation tips. Concrete, not generic. Examples: "Studies in short bursts after 9pm; values a worked example before the formula; gets frustrated with multi-step proofs unless each step is explicit." If there's not enough data yet (fewer than 5 user turns), write a brief honest note like "Not enough data yet — needs a few more sessions." Do not invent patterns you can't see.
- voice_notes (optional): only populate if the history contains Write-mode samples or substantial user prose. 1–2 sentences describing their writing voice. Example: "Short sentences, conversational, uses contractions, favors 'so' as a transition."

Be warm, concrete, and honest. The learner will see these notes on their Profile tab.`;

const RECORD_TOOL = {
  name: 'record_observations',
  description:
    'Persist Yve\'s observations about this learner. Call exactly once.',
  input_schema: {
    type: 'object',
    properties: {
      observed_patterns: { type: 'string' },
      voice_notes: { type: 'string' },
    },
    required: ['observed_patterns'],
  },
} as const;

interface MessageRow {
  role: string;
  content: string;
  created_at: string;
  concept_tags: string[] | null;
  confidence_signal: string | null;
}

interface ConceptRow {
  concept: string;
  current_confidence: string;
  n_observations: number;
}

interface SessionRow {
  mode: string;
  created_at: string;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!supabaseUrl || !serviceKey) {
      throw new Error('Server missing SUPABASE env vars.');
    }
    const client = createClient(supabaseUrl, serviceKey, {
      global: {
        headers: { Authorization: req.headers.get('Authorization') ?? '' },
      },
    });
    const {
      data: { user },
    } = await client.auth.getUser();
    if (!user) return json({ error: 'not authenticated' }, 401);

    // Pull the three signal sources Yve will reason over.
    const [msgRes, conceptRes, sessionRes] = await Promise.all([
      client
        .from('chat_messages')
        .select('role, content, created_at, concept_tags, confidence_signal')
        .eq('user_id', user.id)
        .order('created_at', { ascending: false })
        .limit(50),
      client
        .from('concept_mastery')
        .select('concept, current_confidence, n_observations')
        .eq('user_id', user.id)
        .order('n_observations', { ascending: false })
        .limit(20),
      client
        .from('chat_sessions')
        .select('mode, created_at')
        .eq('user_id', user.id)
        .order('created_at', { ascending: false })
        .limit(20),
    ]);

    const messages: MessageRow[] = (msgRes.data ?? []) as MessageRow[];
    const concepts: ConceptRow[] = (conceptRes.data ?? []) as ConceptRow[];
    const sessions: SessionRow[] = (sessionRes.data ?? []) as SessionRow[];

    const userTurnCount = messages.filter((m) => m.role === 'user').length;

    const context = buildContext({ messages, concepts, sessions });
    const inferRoute = route({ taskType: 'infer-profile' });
    const result = await inferRoute.provider.complete(
      {
        systemPrompt: INFER_SYSTEM_PROMPT,
        messages: <ProviderMessage[]>[
          { role: 'user', content: context },
        ],
        tools: [{
          name: RECORD_TOOL.name,
          description: RECORD_TOOL.description,
          inputSchema: RECORD_TOOL.input_schema as Record<string, unknown>,
        }],
        forceTool: RECORD_TOOL.name,
        maxTokens: 512,
      },
      inferRoute.model,
    );
    void trackCall({
      client,
      userId: user.id,
      taskType: 'infer-profile',
      observability: result,
    });

    if (!result.toolUse || result.toolUse.name !== RECORD_TOOL.name) {
      return json({ error: 'Inference call did not return structured output.' }, 502);
    }
    const input = result.toolUse.input as {
      observed_patterns?: string;
      voice_notes?: string;
    };

    const observed = (input.observed_patterns ?? '').trim();
    const voice = (input.voice_notes ?? '').trim();
    const now = new Date().toISOString();

    // Upsert. We never touch the user-set observed_patterns / voice_notes
    // columns — only the auto_* ones plus last_inferred_at.
    const { error: upsertErr } = await client
      .from('learner_profiles')
      .upsert(
        {
          user_id: user.id,
          auto_observed_patterns: observed.length > 0 ? observed : null,
          auto_voice_notes: voice.length > 0 ? voice : null,
          last_inferred_at: now,
          updated_at: now,
        },
        { onConflict: 'user_id' },
      );
    if (upsertErr) throw new Error(`upsert failed: ${upsertErr.message}`);

    return json({
      auto_observed_patterns: observed,
      auto_voice_notes: voice.length > 0 ? voice : null,
      last_inferred_at: now,
      turns_considered: userTurnCount,
    });
  } catch (err) {
    console.error(err);
    return json({ error: (err as Error).message }, 500);
  }
});

function buildContext(args: {
  messages: MessageRow[];
  concepts: ConceptRow[];
  sessions: SessionRow[];
}): string {
  const lines: string[] = [];

  // Session timestamps for time-of-day patterns. Group by hour bucket.
  const hourCounts: Record<string, number> = {};
  for (const s of args.sessions) {
    const h = new Date(s.created_at).getUTCHours();
    const bucket = h < 5
      ? 'late-night'
      : h < 12
      ? 'morning'
      : h < 17
      ? 'afternoon'
      : h < 22
      ? 'evening'
      : 'late-night';
    hourCounts[bucket] = (hourCounts[bucket] ?? 0) + 1;
  }
  const modes = args.sessions.map((s) => s.mode);
  const modeCounts: Record<string, number> = {};
  for (const m of modes) modeCounts[m] = (modeCounts[m] ?? 0) + 1;

  lines.push('Session patterns:');
  lines.push(
    `- Sessions analyzed: ${args.sessions.length}; modes used: ${
      Object.entries(modeCounts)
        .map(([k, v]) => `${k}×${v}`)
        .join(', ')
    }`,
  );
  lines.push(
    `- Time-of-day buckets (UTC): ${
      Object.entries(hourCounts).map(([k, v]) => `${k}×${v}`).join(', ')
    }`,
  );
  lines.push('');

  // Concept mastery rollup.
  lines.push('Concept mastery so far:');
  if (args.concepts.length === 0) {
    lines.push('- (none yet)');
  } else {
    for (const c of args.concepts.slice(0, 15)) {
      lines.push(
        `- ${c.concept}: ${c.current_confidence} (×${c.n_observations})`,
      );
    }
  }
  lines.push('');

  // Conversation samples — newest first, both roles. Trim long messages.
  lines.push('Recent conversation samples (newest first):');
  for (const m of args.messages.slice(0, 30)) {
    const short = m.content.length > 280
      ? `${m.content.slice(0, 277)}...`
      : m.content;
    const tags = (m.concept_tags ?? []).length > 0
      ? ` [tags: ${m.concept_tags!.join(', ')}]`
      : '';
    const conf = m.confidence_signal && m.role === 'assistant'
      ? ` [confidence: ${m.confidence_signal}]`
      : '';
    lines.push(`- ${m.role}${conf}${tags}: ${short.replace(/\n+/g, ' / ')}`);
  }

  return lines.join('\n');
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'content-type': 'application/json' },
  });
}
