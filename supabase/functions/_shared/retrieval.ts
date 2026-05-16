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

  const { data, error } = await args.client.rpc('match_material_chunks', {
    p_subject_id: args.subjectId,
    p_query_embedding: embeddings[0],
    p_match_count: args.matchCount ?? 5,
    p_min_similarity: args.minSimilarity ?? 0.3,
  });

  if (error) {
    console.error('match_material_chunks failed', error);
    return [];
  }
  return (data ?? []) as RetrievedChunk[];
}

/// Build the system-prompt fragment that injects retrieved chunks. We label
/// each chunk so Yve can cite them naturally ("from your week 3 notes…")
/// in Materials mode.
export function formatChunksForPrompt(
  chunks: RetrievedChunk[],
  materials: Map<string, string>,
): string {
  if (chunks.length === 0) {
    return '\n\nNo relevant material was found in this subject for the learner\'s current question. Say so plainly rather than inventing.';
  }
  const lines = chunks.map((c, i) => {
    const matName = materials.get(c.material_id) ?? 'material';
    return `[${i + 1}] from "${matName}":\n${c.content}`;
  });
  return `\n\nRelevant excerpts from the learner's subject materials:\n\n${lines.join('\n\n---\n\n')}\n\nWhen you reference one of these excerpts, name the source briefly so the learner knows where it came from.`;
}
