// Per-model pricing for cost estimation. Prices in USD per 1M tokens.
// Update when providers change rates or new models land. Missing models
// fall back to zero — `model_calls.estimated_cost_usd` of 0 is the signal
// that a model's pricing isn't tracked yet (worth fixing here when seen
// in the cost dashboard).

export interface ModelPricing {
  input: number;
  output: number;
  cacheRead: number;
}

const PRICING: Record<string, ModelPricing> = {
  // Anthropic
  'claude-sonnet-4-6':         { input: 3.00, output: 15.00, cacheRead: 0.30 },
  'claude-haiku-4-5-20251001': { input: 1.00, output:  5.00, cacheRead: 0.10 },
  // Add OpenAI / Gemini rows when those providers land. The router
  // already supports them via the provider abstraction; pricing is the
  // only thing missing.
};

export function estimateCostUsd(
  model: string,
  inputTokens: number,
  outputTokens: number,
  cacheReadTokens: number,
): number {
  const p = PRICING[model];
  if (!p) return 0;
  const cost =
    (inputTokens * p.input +
      outputTokens * p.output +
      cacheReadTokens * p.cacheRead) /
    1_000_000;
  // Round to 6dp so the numeric(12,6) column doesn't round-trip ugly.
  return Math.round(cost * 1_000_000) / 1_000_000;
}
