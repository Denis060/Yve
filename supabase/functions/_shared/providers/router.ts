// AIRouter — central decision point for "which provider + which model"
// per task. Today every route resolves to Claude; the matrix below makes
// the next swap a single-file change.
//
// Routing principles:
//   - The chat spine (chat, chat-metadata, polish) stays on Claude. Forced
//     tool use is the substrate of the conversion engine; we don't risk it
//     on providers with shakier function-call reliability until we have
//     A/B quality data.
//   - Background / non-conversation tasks (recap, infer-profile) can move
//     to cheaper models when the cost data justifies it.
//   - Quality level is currently a soft hint — Premium users always get
//     the best-available model; Free users can be routed to cheaper models
//     when the route table allows (none today).

import { ClaudeProvider } from './anthropic.ts';
import type {
  AiProvider,
  ProviderName,
  QualityLevel,
  TaskType,
} from './types.ts';

export interface RouteRequest {
  taskType: TaskType;
  // Hint for future routing decisions ("Pro gets Sonnet, Free gets Haiku").
  // Currently unused — all routes resolve to the DEFAULTS matrix below.
  // Accepts every plan_code; treat any non-'free' value as "paid".
  userPlan?: string;
  qualityLevel?: QualityLevel;
  estimatedInputTokens?: number;
  estimatedOutputTokens?: number;
}

export interface RouteDecision {
  provider: AiProvider;
  model: string;
  rationale: string;
}

// Default model per task. Changing one row here changes the provider for
// every callsite of that task — the whole point of the abstraction.
const DEFAULTS: Record<TaskType, { provider: ProviderName; model: string }> = {
  // The chat spine — premium quality, no risk on tool reliability.
  'chat':           { provider: 'anthropic', model: 'claude-sonnet-4-6' },
  // Post-stream metadata extraction. Haiku is plenty for "extract these
  // four fields from a conversation" and runs ~3x faster than Sonnet.
  'chat-metadata':  { provider: 'anthropic', model: 'claude-haiku-4-5-20251001' },
  // Vision: classify + OCR. Haiku 4.5 vision is strong + cheap.
  'vision':         { provider: 'anthropic', model: 'claude-haiku-4-5-20251001' },
  // PDF text extraction. No reasoning needed; pure transcription.
  'pdf-extract':    { provider: 'anthropic', model: 'claude-haiku-4-5-20251001' },
  // Write-mode polish. Sonnet because voice preservation requires nuance.
  // (Probing — temporarily on Haiku to isolate a Sonnet-via-Edge hang.)
  'polish':         { provider: 'anthropic', model: 'claude-haiku-4-5-20251001' },
  // Background structured summary — Haiku is fine.
  'recap':          { provider: 'anthropic', model: 'claude-haiku-4-5-20251001' },
  // Background pattern observation — Haiku is fine.
  'infer-profile':  { provider: 'anthropic', model: 'claude-haiku-4-5-20251001' },
};

const PROVIDERS: Record<ProviderName, AiProvider> = {
  anthropic: new ClaudeProvider(),
  // openai: new OpenAIProvider(),  // future
  // google:  new GeminiProvider(),  // future
};

export function route(req: RouteRequest): RouteDecision {
  // Env override knob — handy for forcing a specific model in testing
  // without rebuilding the router rules. Format:
  //   ANTHROPIC_MODEL_OVERRIDE_CHAT=claude-haiku-4-5-20251001
  const overrideEnv =
    `ANTHROPIC_MODEL_OVERRIDE_${req.taskType.replace(/-/g, '_').toUpperCase()}`;
  const override = Deno.env.get(overrideEnv);

  const base = DEFAULTS[req.taskType];
  const model = override ?? base.model;
  const provider = PROVIDERS[base.provider];
  if (!provider) {
    throw new Error(
      `No provider implementation for ${base.provider} (task=${req.taskType})`,
    );
  }
  return {
    provider,
    model,
    rationale: override
      ? `task=${req.taskType} → ${base.provider}/${model} (env override)`
      : `task=${req.taskType} → ${base.provider}/${model} (default)`,
  };
}
