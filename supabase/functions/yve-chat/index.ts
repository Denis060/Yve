// POST /yve-chat   (streaming for chat modes; pre-buffered stream for write mode)
//
// Routes every model call through AIRouter so observability lands in
// model_calls and provider swaps are a single-file change in router.ts.
//
// Two execution shapes:
//   - Write mode → forced polish_text tool → run the Anthropic call BEFORE
//     creating the ReadableStream (a nested fetch inside the controller
//     callback deadlocks reading Anthropic's body on Supabase Edge). The
//     response is buffered, then streamed out as start / polish / metadata /
//     done events so the client's NDJSON parser is unchanged.
//   - All other modes → streaming text + post-stream metadata extraction
//     inside the ReadableStream controller. Standard chat experience.
//
// The Flutter client treats the two shapes identically — same NDJSON event
// names, same parser, same UI bubble selection logic.
//
//
// Body-deadlock note (kept here so the next person to touch this doesn't
// re-introduce it):
//   `await fetch(...).text()` inside a ReadableStream `start` callback
//   intermittently hangs reading Anthropic's response body. The fetch
//   resolves with status 200, the first TCP chunk arrives, then the body
//   never drains. Running the exact same fetch outside the controller
//   resolves in ~2 s. Hypothesis: Deno's HTTP/2 reader and the outer
//   stream's writer share a runtime resource that backpressures into a
//   deadlock under certain timing. Don't nest non-streaming Anthropic
//   calls inside the chat stream — move them above it.

import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import {
  incrementChatTurns,
  incrementPolishRuns,
  loadChatQuota,
  loadEntitlement,
  loadPolishQuota,
  logUsageEvent,
} from '../_shared/entitlements.ts';
import { route } from '../_shared/providers/router.ts';
import { trackCall } from '../_shared/providers/observability.ts';
import type {
  ProviderMessage,
  ProviderResult,
} from '../_shared/providers/types.ts';
import {
  LearnerProfile,
  METADATA_TOOL,
  HUMANIZE_SYSTEM_PROMPT,
  metadataSystemPrompt,
  ModeName,
  POLISH_SYSTEM_PROMPT,
  POLISH_TOOL,
  systemPromptFor,
} from '../_shared/yve_modes.ts';
import {
  formatChunksForPrompt,
  retrieveRelevantChunks,
  RetrievedChunk,
} from '../_shared/retrieval.ts';

const CORS_HEADERS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers':
    'authorization, x-client-info, apikey, content-type',
  'access-control-allow-methods': 'POST, OPTIONS',
};

const VALID_MODES: ReadonlySet<ModeName> = new Set<ModeName>([
  'open',
  'learn',
  'practice',
  'assignment',
  'write',
  'materials',
]);

interface IncomingMessage {
  role: 'user' | 'assistant';
  content: string;
}

type ConfidenceSignal = 'grasped' | 'partial' | 'struggling' | 'unknown';

interface PolishPayload {
  polished_text: string;
  change_summary: unknown;
  preserved_phrases: unknown;
  flags: unknown;
  follow_up_suggestions: unknown;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch (_e) {
    return json({ error: 'invalid JSON body' }, 400);
  }

  const mode: ModeName = VALID_MODES.has(payload.mode as ModeName)
    ? (payload.mode as ModeName)
    : 'open';

  const incomingRaw = payload.messages;
  const incoming: IncomingMessage[] = Array.isArray(incomingRaw)
    ? incomingRaw.filter(
        (m: unknown): m is IncomingMessage =>
          !!m &&
          typeof m === 'object' &&
          typeof (m as IncomingMessage).content === 'string' &&
          ((m as IncomingMessage).role === 'user' ||
            (m as IncomingMessage).role === 'assistant'),
      )
    : [];
  if (incoming.length === 0) {
    return json({ error: 'messages is required' }, 400);
  }

  const subjectId =
    typeof payload.subject_id === 'string' && payload.subject_id.length > 0
      ? (payload.subject_id as string)
      : undefined;
  const sessionIdIn =
    typeof payload.session_id === 'string' && payload.session_id.length > 0
      ? (payload.session_id as string)
      : undefined;
  // Write-mode sub-action. 'polish' (default) gently improves the learner's
  // own draft; 'humanize' rewrites likely-AI text to read human while
  // preserving meaning. Only meaningful when mode === 'write'.
  const writeIntent: 'polish' | 'humanize' =
    payload.intent === 'humanize' ? 'humanize' : 'polish';
  // BCP-47 device locale ("es", "es-MX", "fr-FR"…). The shared
  // `buildLocaleAddendum` normalises this to the primary subtag and only
  // emits a system-prompt line for languages we trust Claude to produce
  // idiomatic learner-grade output in. Unknown / English locales pass
  // through silently so the persona stays unchanged.
  const locale =
    typeof payload.locale === 'string' && payload.locale.length > 0
      ? (payload.locale as string)
      : undefined;

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceKey) {
    return json({ error: 'Server missing SUPABASE env vars.' }, 500);
  }

  const authHeader = req.headers.get('Authorization') ?? '';
  const client = createClient(supabaseUrl, serviceKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const {
    data: { user },
  } = await client.auth.getUser();
  if (!user) return json({ error: 'not authenticated' }, 401);

  // ────────────────────────────────────────────────────────────────
  // Write mode: run the Anthropic polish call BEFORE the stream is
  // created (see "Body-deadlock note" above). Then emit a buffered
  // stream so the client sees the same event shape as chat modes.
  // ────────────────────────────────────────────────────────────────
  if (mode === 'write') {
    const lastUser = incoming[incoming.length - 1];

    const entitlement = await loadEntitlement(
      client,
      user.id,
      user.is_anonymous === true,
    );

    // Anonymous users get a special cap kind so the client routes to
    // the AnonymousContinuationPanel (save-your-work framing) instead
    // of the regular cap-hit pricing card. Everything else identical.
    const isAnonymous = entitlement.planCode === 'anonymous';

    // 1) Word cap — cheapest check, no DB round-trip needed.
    const draftText = lastUser.content;
    const draftWords = countWords(draftText);
    if (draftWords > entitlement.caps.polishMaxWords) {
      await logUsageEvent(user.id, 'polish_cap_hit', {
        reason: 'word_cap', words: draftWords, max: entitlement.caps.polishMaxWords,
      }, entitlement.planCode);
      return ndjsonResponse([
        {
          type: 'quota_exceeded',
          kind: isAnonymous ? 'anonymous_limit' : 'word',
          plan: entitlement.planCode,
          used: draftWords,
          limit: entitlement.caps.polishMaxWords,
          mode,
          draft_preview: previewText(draftText, 80),
        },
      ]);
    }

    // 2) Polish-run cap (weekly on Free, daily on Trial, lifetime on
    // anonymous, unlimited on Pro).
    const polishQuota = await loadPolishQuota(
      client,
      user.id,
      entitlement.caps,
      entitlement.planCode,
    );
    if (polishQuota.exceeded) {
      await logUsageEvent(user.id, 'polish_cap_hit', {
        reason: 'run_cap', used: polishQuota.used, limit: polishQuota.limit,
      }, entitlement.planCode);
      return ndjsonResponse([
        {
          type: 'quota_exceeded',
          kind: isAnonymous ? 'anonymous_limit' : 'polish',
          plan: entitlement.planCode,
          used: polishQuota.used,
          limit: polishQuota.limit,
          reset_at: polishQuota.resetAtUtc,
          mode,
          draft_preview: previewText(draftText, 80),
        },
      ]);
    }

    let session: { id: string };
    try {
      session = await ensureSession({
        client,
        userId: user.id,
        sessionIdIn,
        subjectId,
        mode,
        firstUserMessage: lastUser.content,
      });
    } catch (e) {
      return ndjsonResponse([
        { type: 'error', message: (e as Error).message },
      ]);
    }

    const polishRoute = route({
      taskType: 'polish',
      userPlan: entitlement.planCode,
    });
    const messages: ProviderMessage[] = incoming.map((m) => ({
      role: m.role,
      content: m.content,
    }));

    let polishResult: ProviderResult;
    try {
      polishResult = await polishRoute.provider.complete(
        {
          systemPrompt: writeIntent === 'humanize'
            ? HUMANIZE_SYSTEM_PROMPT
            : POLISH_SYSTEM_PROMPT,
          messages,
          tools: [{
            name: POLISH_TOOL.name,
            description: POLISH_TOOL.description,
            inputSchema: POLISH_TOOL.input_schema as Record<string, unknown>,
          }],
          forceTool: POLISH_TOOL.name,
          maxTokens: 2048,
        },
        polishRoute.model,
      );
    } catch (e) {
      void trackCall({
        client,
        userId: user.id,
        taskType: 'polish',
        observability: {
          providerUsed: polishRoute.provider.name,
          modelUsed: polishRoute.model,
          inputTokens: 0,
          outputTokens: 0,
          cacheReadTokens: 0,
          latencyMs: 0,
          estimatedCostUsd: 0,
        },
        success: false,
        errorMessage: (e as Error).message,
      });
      return ndjsonResponse([
        { type: 'start', session_id: session.id },
        { type: 'error', message: (e as Error).message },
      ]);
    }

    void trackCall({
      client,
      userId: user.id,
      taskType: 'polish',
      observability: polishResult,
    });

    const polishInput =
      (polishResult.toolUse?.input as Record<string, unknown>) ?? {};
    const polish: PolishPayload = {
      // Strip any em-dashes the model leaked despite the prompt ban — the
      // loudest AI tell in submitted work. Applies to both polish and
      // humanize since neither should ever ship an em-dash.
      polished_text: stripEmDashes((polishInput.polished_text as string) ?? ''),
      change_summary: polishInput.change_summary ?? [],
      preserved_phrases: polishInput.preserved_phrases ?? [],
      flags: polishInput.flags ?? [],
      follow_up_suggestions: polishInput.follow_up_suggestions ?? [],
    };

    const offerSuggestions = (polish.follow_up_suggestions as string[])
      .map((label) => ({
        label,
        kind: 'rephrase',
        payload: label,
      }));
    const metadata = {
      concept_tags: writeIntent === 'humanize'
        ? ['humanized writing']
        : ['writing voice'],
      post_solve_offer: { suggestions: offerSuggestions },
      confidence_signal: 'unknown' as const,
    };

    // Awaited: this is fire-once and the isolate terminates as soon as we
    // return the response below. A bare `void` here races the DB write
    // against isolate shutdown and silently drops persisted turns.
    await persistTurn({
      client,
      sessionId: session.id,
      userId: user.id,
      mode,
      lastUserMessage: lastUser.content,
      answer: polish.polished_text,
      metadata: {
        concept_tags: metadata.concept_tags,
        post_solve_offer: metadata.post_solve_offer,
        confidence_signal: 'unknown',
      },
      polish,
      tokens: {
        input: polishResult.inputTokens,
        output: polishResult.outputTokens,
      },
      historyLength: incoming.length,
    });
    // Polish run consumed → bump the polish counter (not the chat
    // counter). Awaited so the upsert lands before the Edge isolate
    // terminates the response.
    await incrementPolishRuns(client, user.id);

    return ndjsonResponse([
      { type: 'start', session_id: session.id },
      { type: 'polish', polish },
      { type: 'metadata', ...metadata },
      { type: 'done' },
    ]);
  }

  // ────────────────────────────────────────────────────────────────
  // Chat modes (open / learn / practice / assignment / materials).
  // Real streaming through the provider; tokens go out as they arrive.
  // ────────────────────────────────────────────────────────────────
  const stream = new ReadableStream<Uint8Array>({
    start: async (controller) => {
      const encoder = new TextEncoder();
      const send = (obj: Record<string, unknown>) => {
        controller.enqueue(encoder.encode(`${JSON.stringify(obj)}\n`));
      };

      try {
        const lastUser = incoming[incoming.length - 1];

        const entitlement = await loadEntitlement(
      client,
      user.id,
      user.is_anonymous === true,
    );
        const quota = await loadChatQuota(
          client,
          user.id,
          entitlement.caps,
          entitlement.planCode,
        );
        if (quota.exceeded) {
          await logUsageEvent(user.id, 'chat_cap_hit', {
            used: quota.used, limit: quota.limit,
          }, entitlement.planCode);
          // If the user was resuming a session, the cap-hit screen can
          // render "you and Yve were N turns into <title>". For a brand
          // new turn that hits cap before a session exists, ctx is empty
          // and the screen falls back to the generic copy.
          const ctx = await loadSessionContext(client, user.id, sessionIdIn);
          send({
            type: 'quota_exceeded',
            // Anonymous users get a different cap kind so the client
            // shows the AnonymousContinuationPanel (save-your-work)
            // instead of the regular trial-CTA pricing card.
            kind: entitlement.planCode === 'anonymous' ? 'anonymous_limit' : 'chat',
            plan: entitlement.planCode,
            used: quota.used,
            limit: quota.limit,
            reset_at: quota.resetAtUtc,
            mode,
            ...ctx,
          });
          controller.close();
          return;
        }

        const session = await ensureSession({
          client,
          userId: user.id,
          sessionIdIn,
          subjectId,
          mode,
          firstUserMessage: lastUser.content,
        });
        send({ type: 'start', session_id: session.id });

        let groundedChunks: RetrievedChunk[] = [];
        let materialsPrompt = '';
        if (
          subjectId &&
          (mode === 'materials' || mode === 'open' || mode === 'learn')
        ) {
          try {
            groundedChunks = await retrieveRelevantChunks({
              client,
              subjectId,
              query: lastUser.content,
            });
            if (groundedChunks.length > 0) {
              const matMap = await loadMaterialNames(
                client,
                groundedChunks.map((c) => c.material_id),
              );
              materialsPrompt = formatChunksForPrompt(groundedChunks, matMap);
            } else if (mode === 'materials') {
              materialsPrompt = formatChunksForPrompt(
                [],
                new Map<string, string>(),
              );
            }
          } catch (e) {
            console.error('retrieval failed', e);
          }
        }

        const profile = await loadProfile(client, user.id);

        const messages: ProviderMessage[] = incoming.map((m) => ({
          role: m.role,
          content: m.content,
        }));

        const chatRoute = route({
          taskType: 'chat',
          userPlan: entitlement.planCode,
        });
        const systemPrompt =
          systemPromptFor(mode, profile, locale) + materialsPrompt;

        let answer = '';
        let chatObs:
          | {
              inputTokens: number;
              outputTokens: number;
              cacheReadTokens: number;
              latencyMs: number;
              estimatedCostUsd: number;
              providerUsed: typeof chatRoute.provider.name;
              modelUsed: string;
            }
          | null = null;
        let streamErrored = false;

        // Assignment mode often answers multi-section worksheets/PDFs
        // (5–10 pages, dozens of questions) — 2048 tokens truncates the
        // model mid-response and the learner sees only the first few
        // sections. 8192 matches what vision-ingest already uses for
        // PDF analysis and gives the deliverable room to breathe.
        // Other modes (open/learn/practice/materials) finish well under
        // 2048 and don't need the higher cap.
        const chatMaxTokens = mode === 'assignment' ? 8192 : 2048;
        for await (
          const evt of chatRoute.provider.stream(
            {
              systemPrompt,
              messages,
              maxTokens: chatMaxTokens,
            },
            chatRoute.model,
          )
        ) {
          if (evt.kind === 'text') {
            answer += evt.delta;
            send({ type: 'text', delta: evt.delta });
          } else if (evt.kind === 'done') {
            chatObs = evt.observability;
          } else if (evt.kind === 'error') {
            send({ type: 'error', message: evt.message });
            if (evt.observability) {
              void trackCall({
                client,
                userId: user.id,
                taskType: 'chat',
                observability: evt.observability,
                success: false,
                errorMessage: evt.message,
              });
            }
            streamErrored = true;
            break;
          }
        }
        if (streamErrored) {
          controller.close();
          return;
        }
        if (chatObs) {
          void trackCall({
            client,
            userId: user.id,
            taskType: 'chat',
            observability: chatObs,
          });
        }
        if (!answer.trim()) {
          send({
            type: 'error',
            message: 'Yve had trouble forming a response. Try again?',
          });
          controller.close();
          return;
        }

        // Post-stream metadata extraction.
        const metaRoute = route({
          taskType: 'chat-metadata',
          userPlan: entitlement.planCode,
        });
        let metadata = emptyMetadata();
        try {
          const metaResult = await metaRoute.provider.complete(
            {
              systemPrompt: metadataSystemPrompt(mode, locale),
              messages: [
                ...messages,
                { role: 'assistant', content: answer },
                {
                  role: 'user',
                  content:
                    'Extract the metadata for that response now. Call extract_metadata with concept tags, follow-up chips, and your confidence read.',
                },
              ],
              tools: [{
                name: METADATA_TOOL.name,
                description: METADATA_TOOL.description,
                inputSchema: METADATA_TOOL.input_schema as Record<string, unknown>,
              }],
              forceTool: METADATA_TOOL.name,
              maxTokens: 1024,
            },
            metaRoute.model,
          );
          void trackCall({
            client,
            userId: user.id,
            taskType: 'chat-metadata',
            observability: metaResult,
          });
          metadata = readMetadata(metaResult);
        } catch (e) {
          console.error('metadata extraction failed', e);
        }

        send({
          type: 'metadata',
          concept_tags: metadata.concept_tags,
          post_solve_offer: metadata.post_solve_offer,
          confidence_signal: metadata.confidence_signal,
          save_to_subject: metadata.save_to_subject,
          grounded_material_ids: groundedChunks.length > 0
            ? Array.from(new Set(groundedChunks.map((c) => c.material_id)))
            : undefined,
        });

        // Always increment so the fair-use ceiling applies on paid tiers
        // and so usage_events captures complete telemetry.
        void incrementChatTurns(client, user.id);
        // Awaited before `done` + controller.close() below: a bare `void`
        // races the DB write against isolate shutdown and silently drops
        // the persisted turn (user sees the reply, reload loses it).
        await persistTurn({
          client,
          sessionId: session.id,
          userId: user.id,
          mode,
          lastUserMessage: lastUser.content,
          answer,
          metadata,
          tokens: {
            input: chatObs?.inputTokens ?? 0,
            output: chatObs?.outputTokens ?? 0,
          },
          historyLength: incoming.length,
        });
        void writeObservations({
          client,
          userId: user.id,
          subjectId,
          sessionId: session.id,
          conceptTags: metadata.concept_tags,
          confidence: metadata.confidence_signal,
        });

        send({ type: 'done' });
      } catch (e) {
        console.error(e);
        send({ type: 'error', message: (e as Error).message });
      } finally {
        controller.close();
      }
    },
  });

  return new Response(stream, {
    status: 200,
    headers: {
      ...CORS_HEADERS,
      'content-type': 'application/x-ndjson',
      'cache-control': 'no-cache, no-transform',
      'x-content-type-options': 'nosniff',
    },
  });
});

interface MetadataPayload {
  concept_tags: string[];
  post_solve_offer: { suggestions: Array<Record<string, unknown>> };
  confidence_signal: ConfidenceSignal;
  save_to_subject?: string;
}

function emptyMetadata(): MetadataPayload {
  return {
    concept_tags: [],
    post_solve_offer: { suggestions: [] },
    confidence_signal: 'unknown',
  };
}

/// Naive word count — splits on whitespace. Good enough for the
/// polish_max_words gate (we don't need linguistically-perfect counts).
function countWords(text: string): number {
  const trimmed = text.trim();
  if (!trimmed) return 0;
  return trimmed.split(/\s+/).length;
}

/// Deterministic safety net for the anti-AI-tell rule the model most often
/// leaks: em-dashes. Both POLISH and HUMANIZE prompts forbid them, but the
/// model occasionally slips one in, and an em-dash is the single loudest
/// "AI wrote this" signal in submitted text. We strip them in code so the
/// guarantee doesn't depend on the model obeying.
///
/// Replacement logic mirrors the prompt guidance:
///   "word—word"  → "word, word"   (em/en-dash used as a pause → comma)
///   "word -- word" → "word, word" (double-hyphen variant)
/// Spacing around the dash is normalised so we never produce double spaces
/// or a comma glued to the previous word incorrectly.
function stripEmDashes(text: string): string {
  if (!text) return text;
  return text
    // " — " or "—" (em U+2014 / en U+2013), with optional surrounding
    // spaces, becomes a comma + single space.
    .replace(/\s*[—–]\s*/g, ', ')
    // ASCII double-hyphen used as a dash: "a -- b" or "a--b".
    .replace(/\s*--\s*/g, ', ')
    // Guard: never leave ", ." or duplicate ", ," from edge cases.
    .replace(/,\s*([.,;:!?])/g, '$1')
    .replace(/,\s*,/g, ',');
}

/// First `max` characters of `text`, with an ellipsis if truncated.
/// Used to seed the cap-hit screen with what the user was trying to do.
function previewText(text: string, max: number): string {
  const t = text.trim();
  if (t.length <= max) return t;
  return `${t.slice(0, max - 1)}…`;
}

interface SessionContext {
  session_id?: string;
  session_title?: string;
  turns_this_session?: number;
  primary_concept?: string;
}

/// Pulls the conversational context the cap-hit screen needs to render
/// "You and Yve were N turns into <session_title>". Only meaningful
/// when the user is resuming an existing session (sessionIdIn set) —
/// otherwise the cap fired before any session was created and the
/// screen falls back to its generic copy. Best-effort: any DB failure
/// silently returns an empty object so the cap-hit response still ships.
async function loadSessionContext(
  client: SupabaseClient,
  userId: string,
  sessionIdIn?: string,
): Promise<SessionContext> {
  if (!sessionIdIn) return {};
  try {
    const { data: sess } = await client
      .from('chat_sessions')
      .select('id, title')
      .eq('id', sessionIdIn)
      .eq('user_id', userId)
      .maybeSingle();
    if (!sess) return {};

    // Count user turns directly. chat_sessions.message_count is
    // overwritten per turn by persistTurn() based on the request's
    // history length, so trusting it for "turns this session" is wrong
    // when the client sends single-message bodies. Counting rows is
    // boring + correct.
    const { count: userTurnCount } = await client
      .from('chat_messages')
      .select('*', { count: 'exact', head: true })
      .eq('session_id', sessionIdIn)
      .eq('role', 'user');

    // Most recent assistant message — its first concept tag is the
    // "what was Yve teaching you" signal that the cap-hit screen
    // references.
    const { data: lastMsg } = await client
      .from('chat_messages')
      .select('concept_tags')
      .eq('session_id', sessionIdIn)
      .eq('role', 'assistant')
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();
    const tags = (lastMsg?.concept_tags as string[] | undefined) ?? [];

    return {
      session_id: sess.id as string,
      session_title: (sess.title as string) ?? undefined,
      turns_this_session: userTurnCount ?? 0,
      primary_concept: tags[0],
    };
  } catch (e) {
    console.error('loadSessionContext failed', e);
    return {};
  }
}

function readMetadata(result: ProviderResult): MetadataPayload {
  if (!result.toolUse || result.toolUse.name !== METADATA_TOOL.name) {
    return emptyMetadata();
  }
  const input = result.toolUse.input as Partial<MetadataPayload> & {
    post_solve_offer?: { suggestions?: Array<Record<string, unknown>> };
  };
  return {
    concept_tags: input.concept_tags ?? [],
    post_solve_offer: {
      suggestions: input.post_solve_offer?.suggestions ?? [],
    },
    confidence_signal:
      (input.confidence_signal as ConfidenceSignal) ?? 'unknown',
    save_to_subject: input.save_to_subject,
  };
}

async function loadProfile(
  client: SupabaseClient,
  userId: string,
): Promise<LearnerProfile | null> {
  try {
    const { data, error } = await client
      .from('learner_profiles')
      .select(
        'reading_level, explanation_depth, tone_preference, observed_patterns, voice_notes, auto_observed_patterns, auto_voice_notes, read_aloud',
      )
      .eq('user_id', userId)
      .maybeSingle();
    if (error) {
      console.error('loadProfile error', error);
      return null;
    }
    return (data as LearnerProfile | null) ?? null;
  } catch (e) {
    console.error('loadProfile threw', e);
    return null;
  }
}

async function ensureSession(args: {
  client: SupabaseClient;
  userId: string;
  sessionIdIn?: string;
  subjectId?: string;
  mode: ModeName;
  firstUserMessage: string;
}): Promise<{ id: string }> {
  if (args.sessionIdIn) {
    return { id: args.sessionIdIn };
  }
  const title = autoTitle(args.firstUserMessage);
  const { data, error } = await args.client
    .from('chat_sessions')
    .insert({
      user_id: args.userId,
      subject_id: args.subjectId ?? null,
      title,
      mode: args.mode,
    })
    .select('id')
    .single();
  if (error || !data) {
    throw new Error(`could not create chat_session: ${error?.message}`);
  }
  return { id: data.id as string };
}

function autoTitle(text: string): string {
  const trimmed = text.trim();
  if (trimmed.length <= 60) return trimmed;
  return `${trimmed.slice(0, 57)}...`;
}

async function loadMaterialNames(
  client: SupabaseClient,
  materialIds: string[],
): Promise<Map<string, string>> {
  if (materialIds.length === 0) return new Map();
  const { data } = await client
    .from('materials')
    .select('id,name')
    .in('id', materialIds);
  const m = new Map<string, string>();
  for (const row of data ?? []) {
    m.set(row.id as string, row.name as string);
  }
  return m;
}

async function persistTurn(args: {
  client: SupabaseClient;
  sessionId: string;
  userId: string;
  mode: ModeName;
  lastUserMessage: string;
  answer: string;
  metadata: MetadataPayload;
  polish?: Record<string, unknown>;
  tokens: { input: number; output: number };
  historyLength: number;
}): Promise<void> {
  try {
    const yveOffer = args.polish
      ? { ...args.metadata.post_solve_offer, polish: args.polish }
      : args.metadata.post_solve_offer;
    const rows = [
      {
        session_id: args.sessionId,
        user_id: args.userId,
        role: 'user' as const,
        content: args.lastUserMessage,
        concept_tags: [],
      },
      {
        session_id: args.sessionId,
        user_id: args.userId,
        role: 'assistant' as const,
        content: args.answer,
        concept_tags: args.metadata.concept_tags,
        offer: yveOffer,
        confidence_signal: args.metadata.confidence_signal,
        save_to_subject: args.metadata.save_to_subject ?? null,
        input_tokens: args.tokens.input,
        output_tokens: args.tokens.output,
      },
    ];
    await args.client.from('chat_messages').insert(rows);

    const preview = args.answer.length > 140
      ? `${args.answer.slice(0, 137)}...`
      : args.answer;
    await args.client
      .from('chat_sessions')
      .update({
        message_count: args.historyLength + 1,
        last_message_preview: preview,
        updated_at: new Date().toISOString(),
      })
      .eq('id', args.sessionId);
  } catch (e) {
    console.error('persistTurn failed', e);
  }
}

async function writeObservations(args: {
  client: SupabaseClient;
  userId: string;
  subjectId?: string;
  sessionId: string;
  conceptTags: string[];
  confidence: ConfidenceSignal;
}): Promise<void> {
  if (args.conceptTags.length === 0) return;
  try {
    const rows = args.conceptTags.map((concept) => ({
      user_id: args.userId,
      subject_id: args.subjectId ?? null,
      session_id: args.sessionId,
      concept,
      confidence_signal: args.confidence,
    }));
    await args.client.from('concept_observations').insert(rows);
  } catch (e) {
    console.error('writeObservations failed', e);
  }
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'content-type': 'application/json' },
  });
}

function ndjsonResponse(events: Array<Record<string, unknown>>): Response {
  const body = events.map((e) => `${JSON.stringify(e)}\n`).join('');
  return new Response(body, {
    status: 200,
    headers: {
      ...CORS_HEADERS,
      'content-type': 'application/x-ndjson',
      'cache-control': 'no-cache, no-transform',
      'x-content-type-options': 'nosniff',
    },
  });
}
