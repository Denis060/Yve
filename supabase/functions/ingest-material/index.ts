// POST /ingest-material
//
// Adds a material to a subject and indexes it for retrieval.
//
// Request:
//   {
//     subject_id: string,
//     kind: 'note' | 'url' | 'pdf' | 'image' | 'doc',
//     name?: string,                   // optional display name; auto-derived when missing
//     content?: string,                // raw text for note / pre-extracted PDF / image text
//     url?: string,                    // for kind=url; server fetches + strips HTML
//     pdf_base64?: string,             // for kind=pdf; server extracts text via Claude
//     docx_base64?: string,            // for kind=doc; server unzips + parses word/document.xml
//   }
//
// Response:
//   {
//     material_id: string,
//     chunk_count: number,
//     status: 'ready' | 'failed',
//     error?: string,
//   }
//
// The function:
//   1. inserts a materials row in 'processing'
//   2. extracts text (kind-dependent — note: passthrough, url: fetch+strip,
//      pdf: Claude document block)
//   3. chunks + embeds the text via Voyage
//   4. inserts material_chunks rows with the embeddings
//   5. flips the material to 'ready' (or 'failed' with an error)
//
// Image and doc kinds still expect pre-extracted text via `content` (image
// inputs flow through vision-ingest; DOCX parsing lands separately).

import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { extractDocxText } from '../_shared/docx.ts';
import { trackCall } from '../_shared/providers/observability.ts';
import { route } from '../_shared/providers/router.ts';
import { chunkText, embedTexts } from '../_shared/voyage.ts';

const CORS_HEADERS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers':
    'authorization, x-client-info, apikey, content-type',
  'access-control-allow-methods': 'POST, OPTIONS',
};

const VALID_KINDS = new Set<MaterialKind>([
  'note',
  'url',
  'pdf',
  'image',
  'doc',
]);

type MaterialKind = 'note' | 'url' | 'pdf' | 'image' | 'doc';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceKey) {
    return json({ error: 'Server missing SUPABASE env vars.' }, 500);
  }

  const client = createClient(supabaseUrl, serviceKey, {
    global: {
      headers: { Authorization: req.headers.get('Authorization') ?? '' },
    },
  });

  let materialId: string | null = null;
  try {
    const payload = await req.json();
    const subjectId = payload.subject_id as string;
    const kind = payload.kind as MaterialKind;
    if (!subjectId || !VALID_KINDS.has(kind)) {
      return json({ error: 'subject_id and valid kind are required' }, 400);
    }

    const {
      data: { user },
    } = await client.auth.getUser();
    if (!user) return json({ error: 'not authenticated' }, 401);

    // Step 1: insert a 'processing' row so the UI shows progress.
    const name: string = payload.name?.trim() || defaultName(kind, payload);
    const sourceUri: string | null = payload.url ?? null;

    const { data: matRow, error: matErr } = await client
      .from('materials')
      .insert({
        subject_id: subjectId,
        user_id: user.id,
        kind,
        name,
        source_uri: sourceUri,
        status: 'processing',
      })
      .select('id')
      .single();
    if (matErr || !matRow) {
      throw new Error(`materials insert failed: ${matErr?.message}`);
    }
    materialId = matRow.id as string;

    // Step 2: extract the text body.
    const rawText = await extractText({
      client,
      userId: user.id,
      kind,
      content: payload.content as string | undefined,
      url: payload.url as string | undefined,
      pdfBase64: payload.pdf_base64 as string | undefined,
      docxBase64: payload.docx_base64 as string | undefined,
    });
    if (!rawText.trim()) {
      throw new Error('No text could be extracted from this material.');
    }

    // Step 3: chunk + embed.
    const chunks = chunkText(rawText);
    const { embeddings } = await embedTexts(chunks, 'document');
    if (embeddings.length !== chunks.length) {
      throw new Error(
        `embedding count (${embeddings.length}) mismatched chunks (${chunks.length})`,
      );
    }

    // Step 4: insert chunks.
    const chunkRows = chunks.map((content, i) => ({
      material_id: materialId,
      subject_id: subjectId,
      user_id: user.id,
      chunk_index: i,
      content,
      embedding: embeddings[i],
    }));
    if (chunkRows.length > 0) {
      const { error: chunkErr } = await client
        .from('material_chunks')
        .insert(chunkRows);
      if (chunkErr) throw new Error(`chunk insert: ${chunkErr.message}`);
    }

    // Step 5: flip status + stash raw_text for future use.
    await client
      .from('materials')
      .update({
        status: 'ready',
        raw_text: rawText.length > 200000 ? rawText.slice(0, 200000) : rawText,
      })
      .eq('id', materialId);

    return json({
      material_id: materialId,
      chunk_count: chunkRows.length,
      status: 'ready' as const,
    });
  } catch (err) {
    const message = (err as Error).message;
    console.error(err);
    if (materialId) {
      await client
        .from('materials')
        .update({ status: 'failed', error: message })
        .eq('id', materialId);
    }
    return json({
      material_id: materialId,
      chunk_count: 0,
      status: 'failed' as const,
      error: message,
    }, 500);
  }
});

function defaultName(
  kind: MaterialKind,
  payload: { url?: string; content?: string; pdf_base64?: string },
): string {
  switch (kind) {
    case 'url':
      return payload.url ?? 'Saved URL';
    case 'note': {
      const first = (payload.content ?? '').trim().split('\n')[0] ?? '';
      return first.length > 0
        ? (first.length > 60 ? `${first.slice(0, 57)}...` : first)
        : 'Untitled note';
    }
    case 'pdf':
      return 'PDF document';
    case 'doc':
      return 'Word document';
    default:
      return `Untitled ${kind}`;
  }
}

async function extractText(args: {
  client: SupabaseClient;
  userId: string;
  kind: MaterialKind;
  content?: string;
  url?: string;
  pdfBase64?: string;
  docxBase64?: string;
}): Promise<string> {
  if (args.kind === 'url') {
    return await scrapeUrl(args.url ?? '');
  }
  if (args.kind === 'pdf' && args.pdfBase64) {
    return await extractPdfText({
      client: args.client,
      userId: args.userId,
      base64: args.pdfBase64,
    });
  }
  if (args.kind === 'doc' && args.docxBase64) {
    const bytes = base64ToBytes(args.docxBase64);
    return await extractDocxText(bytes);
  }
  // note + (pdf without bytes) + image + (doc without bytes) all expect
  // pre-extracted text. Image ingest flows through vision-ingest.
  return args.content ?? '';
}

function base64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/// Asks Claude to read the PDF and return its markdown-formatted text body.
/// Routed through the AIRouter so cost lands in model_calls. No forced tool
/// — the answer text *is* the deliverable; the system prompt keeps the
/// response focused on transcription only.
async function extractPdfText(args: {
  client: SupabaseClient;
  userId: string;
  base64: string;
}): Promise<string> {
  const SYSTEM = `You extract the full text content from a PDF the learner just uploaded.

Rules:
- Output ONLY the extracted text body, formatted as markdown. No preamble, no commentary, no "Here is the extracted text:" header.
- Preserve structure: headings stay as headings, lists as lists, math in LaTeX, tables as markdown tables.
- For multi-page PDFs, mark page boundaries with markdown headings ("## Page 2", etc.) only when it aids navigation — not on single-page docs.
- For diagrams or images you can't transcribe, leave a one-line inline description in brackets.
- If a page is blank or contains only images you can't read, note it briefly and continue.`;

  const pdfRoute = route({ taskType: 'pdf-extract' });
  const result = await pdfRoute.provider.complete(
    {
      systemPrompt: SYSTEM,
      messages: [
        {
          role: 'user',
          content: [
            { type: 'document', mediaType: 'application/pdf', base64: args.base64 },
            {
              type: 'text',
              text:
                'Extract the full text content of this PDF, preserving structure.',
            },
          ],
        },
      ],
      maxTokens: 8192,
    },
    pdfRoute.model,
  );
  void trackCall({
    client: args.client,
    userId: args.userId,
    taskType: 'pdf-extract',
    observability: result,
  });
  return result.text.trim();
}

async function scrapeUrl(url: string): Promise<string> {
  if (!url) throw new Error('url is required for kind=url');
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new Error('invalid URL');
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new Error('only http(s) URLs are supported');
  }
  const res = await fetch(url, {
    headers: {
      'user-agent':
        'Mozilla/5.0 (compatible; YveBot/1.0; +https://yve.app/bot)',
      accept: 'text/html,*/*',
    },
  });
  if (!res.ok) {
    throw new Error(`fetch failed: ${res.status}`);
  }
  const html = await res.text();
  return stripHtml(html);
}

/// Minimal HTML → plain text. Drops scripts/styles, collapses whitespace.
/// We deliberately avoid a heavyweight DOM parser in the Edge runtime.
function stripHtml(html: string): string {
  return html
    .replace(/<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/gi, ' ')
    .replace(/<style\b[^<]*(?:(?!<\/style>)<[^<]*)*<\/style>/gi, ' ')
    .replace(/<head\b[^<]*(?:(?!<\/head>)<[^<]*)*<\/head>/gi, ' ')
    .replace(/<\/(p|div|section|article|h[1-6]|li|br|tr)>/gi, '\n\n')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/[ \t]+/g, ' ')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'content-type': 'application/json' },
  });
}
