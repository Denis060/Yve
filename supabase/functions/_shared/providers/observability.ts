// Persists per-call cost / latency / token data to model_calls.
//
// Called once per provider invocation (success or failure) so the rollup
// view daily_model_cost stays accurate even when calls fail. Fire-and-
// forget by convention — never block the response on a logging write.

import type { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import type { CallObservability, TaskType } from './types.ts';

export interface TrackArgs {
  client: SupabaseClient;
  userId: string | null;
  taskType: TaskType;
  observability: CallObservability;
  success?: boolean;
  errorMessage?: string;
}

export async function trackCall(args: TrackArgs): Promise<void> {
  try {
    await args.client.from('model_calls').insert({
      user_id: args.userId,
      task_type: args.taskType,
      provider: args.observability.providerUsed,
      model: args.observability.modelUsed,
      input_tokens: args.observability.inputTokens,
      output_tokens: args.observability.outputTokens,
      cache_read_tokens: args.observability.cacheReadTokens,
      latency_ms: args.observability.latencyMs,
      estimated_cost_usd: args.observability.estimatedCostUsd,
      success: args.success ?? true,
      error_message: args.errorMessage ?? null,
    });
  } catch (e) {
    // Never block on observability bookkeeping. Stale rollups are fine;
    // broken chats are not.
    console.error('trackCall failed', e);
  }
}
