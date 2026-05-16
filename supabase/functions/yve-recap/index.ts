// POST /yve-recap
//
// Pulls the learner's recent activity + concept observations and asks Yve to
// compose a brief, warm recap. Forces a structured-output tool so the client
// can render highlights and suggested focuses without parsing prose.
//
// Request: {} (body is empty; the function operates on the authed user)
//
// Response:
//   {
//     greeting: string,
//     summary: string,
//     highlights: Array<{ title: string, detail: string }>,
//     suggested_focus: Array<{ concept: string, why: string, subject?: string }>,
//     closing: string,
//     days_active: number,
//     observations_total: number,
//   }
//
// The function does NOT create a chat session. The client uses the structured
// suggested_focus list to launch practice-mode chats on demand — keeps the
// recap itself a calm, read-only moment.

import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { trackCall } from '../_shared/providers/observability.ts';
import { route } from '../_shared/providers/router.ts';

const CORS_HEADERS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers':
    'authorization, x-client-info, apikey, content-type',
  'access-control-allow-methods': 'POST, OPTIONS',
};

const RECAP_SYSTEM_PROMPT = `You are Yve composing a brief, warm weekly recap for a learner.

Voice:
- Speak directly to them. Use "you", not "the learner".
- Warm and supportive. Never grading. Never numerical-sounding.
- Calm. No filler. No "Great week!" openers. No exclamation marks unless something genuinely warrants it.
- Specific. Reference actual concepts and subjects from their week, not generic encouragement.

What to compose:
- greeting: a short, calm opener — 1 sentence. ("Here's where you've been this week.")
- summary: 2–3 sentences describing the shape of their week — what subjects, how many days, the overall feel. Don't list numbers; describe.
- highlights: 1–3 concrete wins or moments worth noting. Each has a title (short, specific) and a detail (1 sentence). Concepts they grasped, sessions where they got somewhere, anything specific. Skip if there's nothing real to highlight.
- suggested_focus: 1–3 concepts you'd recommend they revisit. Each has the concept name, a 1-sentence "why" (drawn from their actual struggle/partial signals), and the subject if applicable. Skip if their grasped signals all look solid.
- closing: a short, calm wrap-up — 1 sentence. ("See you tomorrow when you're ready.")

Length budget: the full recap should read in under 30 seconds. Trim ruthlessly.`;

const RECAP_TOOL = {
  name: 'compose_recap',
  description: 'Yve\'s structured weekly recap. Call this exactly once.',
  input_schema: {
    type: 'object',
    properties: {
      greeting: { type: 'string' },
      summary: { type: 'string' },
      highlights: {
        type: 'array',
        maxItems: 3,
        items: {
          type: 'object',
          properties: {
            title: { type: 'string' },
            detail: { type: 'string' },
          },
          required: ['title', 'detail'],
        },
      },
      suggested_focus: {
        type: 'array',
        maxItems: 3,
        items: {
          type: 'object',
          properties: {
            concept: { type: 'string' },
            why: { type: 'string' },
            subject: { type: 'string' },
          },
          required: ['concept', 'why'],
        },
      },
      closing: { type: 'string' },
    },
    required: ['greeting', 'summary', 'closing'],
  },
} as const;

interface ObservationRow {
  concept: string;
  confidence_signal: string;
  observed_at: string;
  subject_id: string | null;
}

interface ActivityRow {
  day: string;
  message_count: number;
}

interface SubjectRow {
  id: string;
  name: string;
  emoji: string;
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

    const since = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString();

    // Pull the data Yve will reason over.
    const [obsRes, actRes, subRes] = await Promise.all([
      client
        .from('concept_observations')
        .select('concept, confidence_signal, observed_at, subject_id')
        .gte('observed_at', since)
        .order('observed_at', { ascending: false })
        .limit(80),
      client
        .from('daily_activity')
        .select('day, message_count')
        .gte('day', since.slice(0, 10))
        .order('day', { ascending: true }),
      client.from('subjects').select('id, name, emoji'),
    ]);

    const observations: ObservationRow[] = (obsRes.data ?? []) as ObservationRow[];
    const activity: ActivityRow[] = (actRes.data ?? []) as ActivityRow[];
    const subjects: SubjectRow[] = (subRes.data ?? []) as SubjectRow[];

    if (observations.length === 0 && activity.length === 0) {
      // Nothing real to recap on. Return a calm "fresh start" shape instead
      // of asking Claude to confabulate.
      return json({
        greeting: 'Nothing to recap yet.',
        summary:
          'You haven\'t opened a session this week. Whenever you\'re ready, scan something or pick a study mode.',
        highlights: [],
        suggested_focus: [],
        closing: 'See you when you\'re back.',
        days_active: 0,
        observations_total: 0,
      });
    }

    const context = buildContext({ observations, activity, subjects });
    const recapRoute = route({ taskType: 'recap' });
    const result = await recapRoute.provider.complete(
      {
        systemPrompt: RECAP_SYSTEM_PROMPT,
        messages: [{ role: 'user', content: context }],
        tools: [{
          name: RECAP_TOOL.name,
          description: RECAP_TOOL.description,
          inputSchema: RECAP_TOOL.input_schema as Record<string, unknown>,
        }],
        forceTool: RECAP_TOOL.name,
        maxTokens: 1024,
      },
      recapRoute.model,
    );
    void trackCall({
      client,
      userId: user.id,
      taskType: 'recap',
      observability: result,
    });

    if (!result.toolUse || result.toolUse.name !== RECAP_TOOL.name) {
      return json({ error: 'Recap call did not return structured output.' }, 502);
    }
    const recap = result.toolUse.input as Record<string, unknown>;

    return json({
      ...recap,
      days_active: activity.length,
      observations_total: observations.length,
    });
  } catch (err) {
    console.error(err);
    return json({ error: (err as Error).message }, 500);
  }
});

function buildContext(args: {
  observations: ObservationRow[];
  activity: ActivityRow[];
  subjects: SubjectRow[];
}): string {
  const subjectMap = new Map<string, string>();
  for (const s of args.subjects) subjectMap.set(s.id, s.name);

  // Group observations by concept + subject for a denser, easier-to-reason
  // view. Yve gets the latest confidence and the count so she can talk
  // honestly about what's solid vs shaky.
  const grouped = new Map<string, {
    concept: string;
    subject?: string;
    grasped: number;
    partial: number;
    struggling: number;
    unknown: number;
    last_at: string;
  }>();

  for (const o of args.observations) {
    const key = `${o.subject_id ?? ''}::${o.concept}`;
    const entry = grouped.get(key) ?? {
      concept: o.concept,
      subject: o.subject_id ? subjectMap.get(o.subject_id) : undefined,
      grasped: 0,
      partial: 0,
      struggling: 0,
      unknown: 0,
      last_at: o.observed_at,
    };
    if (o.confidence_signal === 'grasped') entry.grasped += 1;
    else if (o.confidence_signal === 'partial') entry.partial += 1;
    else if (o.confidence_signal === 'struggling') entry.struggling += 1;
    else entry.unknown += 1;
    if (o.observed_at > entry.last_at) entry.last_at = o.observed_at;
    grouped.set(key, entry);
  }

  const lines: string[] = [];
  lines.push(`Days active this week: ${args.activity.length}`);
  if (args.activity.length > 0) {
    lines.push(
      `Activity: ${args.activity.map((a) => `${a.day}=${a.message_count}msg`).join(', ')}`,
    );
  }
  lines.push('');
  lines.push('Concepts observed this week (most recent first):');
  const rows = Array.from(grouped.values())
    .sort((a, b) => b.last_at.localeCompare(a.last_at))
    .slice(0, 20);
  for (const r of rows) {
    const subj = r.subject ? ` [${r.subject}]` : '';
    lines.push(
      `- ${r.concept}${subj} — grasped:${r.grasped} partial:${r.partial} struggling:${r.struggling} unknown:${r.unknown}`,
    );
  }
  return lines.join('\n');
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'content-type': 'application/json' },
  });
}
