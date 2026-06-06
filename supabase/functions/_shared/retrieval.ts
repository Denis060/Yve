// Materials retrieval for subject-grounded chats.
//
// When the learner is chatting in `materials` mode (or any mode with an
// active subject that has uploaded materials), we embed the current question
// via Voyage and run the match_material_chunks RPC defined in
// 0004_subject_memory.sql to pull the top-k relevant snippets.

import type { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { embedTexts } from './voyage.ts';

export interface RetrievedChunk {
  id: string;
  material_id: string;
  content: string;
  similarity: number;
}

export async function retrieveRelevantChunks(args: {
  client: SupabaseClient;
  subjectId: string;
  query: string;
  matchCount?: number;
  minSimilarity?: number;
}): Promise<RetrievedChunk[]> {
  const trimmed = args.query.trim();
  if (trimmed.length === 0) return [];

  const { embeddings } = await embedTexts([trimmed], 'query');
  if (embeddings.length === 0) return [];

  // Threshold tuned for voyage-3-lite. 0.3 was too aggressive — it
  // missed obviously-relevant chunks (e.g. "nursing process is a
  // dynamic process" got filtered out of a "Dynamic and Cyclical"
  // query because similarity landed in the 0.2-0.3 range). 0.15
  // surfaces partial matches; the prompt still tells Yve to answer
  // from general knowledge if the excerpts are weak.
  const { data, error } = await args.client.rpc('match_material_chunks', {
    p_subject_id: args.subjectId,
    p_query_embedding: embeddings[0],
    p_match_count: args.matchCount ?? 5,
    p_min_similarity: args.minSimilarity ?? 0.15,
  });

  if (error) {
    console.error('match_material_chunks failed', error);
    return [];
  }
  return (data ?? []) as RetrievedChunk[];
}

/// Build the system-prompt fragment that injects retrieved chunks. We
/// label each chunk so Yve can cite them naturally ("from your week 3
/// notes…") in Materials mode.
///
/// When retrieval comes back empty, return an empty string instead of
/// telling Claude to announce "no material was found." The user
/// uploaded material and expects Yve to USE it — having her say "I
/// couldn't find anything in your materials" mid-answer feels like
/// gaslighting, especially when she still answers from general
/// knowledge right after. Silence lets her answer naturally; if the
/// answer happens to not draw from the materials, the absence speaks
/// for itself.
export function formatChunksForPrompt(
  chunks: RetrievedChunk[],
  materials: Map<string, string>,
): string {
  if (chunks.length === 0) {
    return '';
  }
  const lines = chunks.map((c, i) => {
    const matName = materials.get(c.material_id) ?? 'material';
    return `[${i + 1}] from "${matName}":\n${c.content}`;
  });
  return `\n\nRelevant excerpts from the learner's subject materials:\n\n${lines.join('\n\n---\n\n')}\n\nWhen you reference one of these excerpts, name the source briefly so the learner knows where it came from.`;
}
