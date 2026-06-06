// Voyage AI embeddings client.
//
// Voyage is Anthropic's recommended embeddings vendor; voyage-3-lite gives
// 512-dim embeddings at low cost which is the right operating point for
// Yve's MVP retrieval load. The pgvector column in 0004_subject_memory.sql
// is sized for exactly this model.

const VOYAGE_URL = 'https://api.voyageai.com/v1/embeddings';
const DEFAULT_MODEL = 'voyage-3-lite';

export type EmbedInputType = 'document' | 'query';

export interface VoyageResult {
  embeddings: number[][];
  inputTokens: number;
}

// Backoff schedule between Voyage 429 retries. Total max wait ~25s
// which is tolerable for an interactive "Yve is reading this material"
// loading state. On the free tier (3 RPM, no payment method) we
// frequently hit the cap during testing; this schedule lets the
// embed self-heal without bouncing the user.
const VOYAGE_RETRY_DELAYS_MS = <const>[3_000, 7_000, 15_000];

/// Embed an array of strings. Pass `input_type: 'document'` when storing
/// material chunks; pass `'query'` when embedding the learner's question.
/// Voyage uses different vector spaces for these two cases.
///
/// Retries on Voyage 429 with exponential-ish backoff
/// ([VOYAGE_RETRY_DELAYS_MS]). After all retries are exhausted, throws
/// the typed `voyage_rate_limited` error for the UI to surface calmly.
export async function embedTexts(
  texts: string[],
  inputType: EmbedInputType = 'document',
): Promise<VoyageResult> {
  if (texts.length === 0) {
    return { embeddings: [], inputTokens: 0 };
  }
  const apiKey = Deno.env.get('VOYAGE_API_KEY');
  if (!apiKey) {
    throw new Error(
      'VOYAGE_API_KEY is not set. Add it under Supabase → Project Settings → Edge Functions → Secrets to enable materials retrieval.',
    );
  }

  const maxAttempts = VOYAGE_RETRY_DELAYS_MS.length + 1;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const res = await fetch(VOYAGE_URL, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model: Deno.env.get('VOYAGE_MODEL') ?? DEFAULT_MODEL,
        input: texts,
        input_type: inputType,
      }),
    });

    if (res.ok) {
      const data = await res.json();
      const embeddings: number[][] = (data.data ?? []).map(
        (d: { embedding: number[] }) => d.embedding,
      );
      return {
        embeddings,
        inputTokens: data.usage?.total_tokens ?? 0,
      };
    }

    const body = await res.text();
    if (res.status === 429 && attempt < maxAttempts) {
      const wait = VOYAGE_RETRY_DELAYS_MS[attempt - 1];
      console.warn(
        `[voyage] 429 on attempt ${attempt}/${maxAttempts}, ` +
          `sleeping ${wait}ms before retry`,
      );
      await new Promise<void>((r) => setTimeout(r, wait));
      continue;
    }
    if (res.status === 429) {
      throw new Error(`voyage_rate_limited: ${body.slice(0, 200)}`);
    }
    throw new Error(`Voyage error ${res.status}: ${body}`);
  }

  // Unreachable — every loop iteration either returns or throws.
  throw new Error('voyage_rate_limited: retries exhausted');
}

/// Paragraph-greedy chunker. Walks the source text, accumulating paragraphs
/// until the chunk would exceed [targetChars]. Paragraphs longer than the
/// target are emitted as their own chunk (we don't hard-split inside them
/// because that breaks sentence boundaries and degrades retrieval quality).
export function chunkText(
  text: string,
  options: { targetChars?: number } = {},
): string[] {
  const target = options.targetChars ?? 1500;
  const paragraphs = text
    .split(/\n{2,}|\r\n{2,}/g)
    .map((p) => p.trim())
    .filter((p) => p.length > 0);

  const chunks: string[] = [];
  let buffer = '';

  for (const p of paragraphs) {
    if (buffer.length === 0) {
      buffer = p;
      continue;
    }
    if (buffer.length + p.length + 2 <= target) {
      buffer = `${buffer}\n\n${p}`;
    } else {
      chunks.push(buffer);
      buffer = p;
    }
  }
  if (buffer.length > 0) chunks.push(buffer);
  return chunks;
}
