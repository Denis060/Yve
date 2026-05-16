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

/// Embed an array of strings. Pass `input_type: 'document'` when storing
/// material chunks; pass `'query'` when embedding the learner's question.
/// Voyage uses different vector spaces for these two cases.
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

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Voyage error ${res.status}: ${body}`);
  }

  const data = await res.json();
  const embeddings: number[][] = (data.data ?? []).map(
    (d: { embedding: number[] }) => d.embedding,
  );
  return {
    embeddings,
    inputTokens: data.usage?.total_tokens ?? 0,
  };
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
