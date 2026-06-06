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
    const rawMessage = (err as Error).message;
    console.error('[ingest-material] failed:', rawMessage);
    const { code, message } = humanizeIngestError(rawMessage);
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
      // Both fields so the client can branch on `code` and display
      // `error`. The detail field stays available for any future need.
      error: message,
      code,
    }, 500);
  }
});

/// Map known internal error shapes to short, calm user-facing messages.
/// Everything unrecognized falls back to the generic line so we never
/// leak provider responses or stack traces to the UI.
///
/// Returns a tuple [code, message] — code is wire-stable so the client
/// can branch on it (e.g. show "Try a different link" button); message
/// is the user-visible copy.
function humanizeIngestError(raw: string): { code: string; message: string } {
  // URL pipeline — typed by fetchUrlAndExtract().
  switch (raw) {
    case 'url_invalid':
      return {
        code: 'url_invalid',
        message: "That doesn't look like a valid web address.",
      };
    case 'url_unsupported_scheme':
      return {
        code: 'url_unsupported_scheme',
        message: 'Yve can only read http or https links.',
      };
    case 'url_timeout':
      return {
        code: 'url_timeout',
        message: 'That page took too long to respond. Try again, or try a different link.',
      };
    case 'url_blocked':
      return {
        code: 'url_blocked',
        message: 'This site blocks automated reading. Try copy-pasting the text into a note instead.',
      };
    case 'url_not_found':
      return {
        code: 'url_not_found',
        message: "Yve couldn't find that page. Double-check the URL.",
      };
    case 'url_server_error':
      return {
        code: 'url_server_error',
        message: 'That site is having trouble right now. Try again in a few minutes.',
      };
    case 'url_unreachable':
      return {
        code: 'url_unreachable',
        message: "Yve couldn't reach that page. Check the link or try again.",
      };
    case 'url_too_large':
      return {
        code: 'url_too_large',
        message: "That file is too large for Yve to read in one go (over 32 MB). For textbook-sized PDFs, try linking to a single chapter or section instead.",
      };
    case 'url_unsupported_content_type':
      return {
        code: 'url_unsupported_content_type',
        message: "That link isn't a readable page or PDF. Try sharing the article URL directly.",
      };
    case 'url_empty_or_jsrendered':
      return {
        code: 'url_empty_or_jsrendered',
        message: "Yve couldn't find readable text on that page — it may need JavaScript or a login.",
      };
    case 'pdf_extract_failed':
      return {
        code: 'pdf_extract_failed',
        message: "Yve couldn't read that PDF. It may be scanned images instead of text.",
      };
  }

  if (raw.startsWith('voyage_rate_limited')) {
    return {
      code: 'embed_rate_limited',
      message: 'Yve is processing a lot right now and hit a temporary cap. Try again in about a minute.',
    };
  }
  if (raw.startsWith('Voyage error')) {
    return {
      code: 'embed_failed',
      message: "Couldn't finish indexing that material right now. Try again in a minute.",
    };
  }
  if (raw.toLowerCase().includes('subject_id')) {
    return {
      code: 'subject_required',
      message: 'No subject selected for this material.',
    };
  }
  if (raw.toLowerCase().includes('kind')) {
    return {
      code: 'unsupported_kind',
      message: "That kind of material isn't supported.",
    };
  }
  return {
    code: 'ingest_failed',
    message: "Yve couldn't add that material. Try again in a moment.",
  };
}

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
    return await fetchUrlAndExtract({
      client: args.client,
      userId: args.userId,
      url: args.url ?? '',
    });
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

// ─────────────────────────────────────────────────────────────────────
// URL ingestion
// ─────────────────────────────────────────────────────────────────────
//
// Error contract:
//   Throws Error with `message` set to one of the typed codes below.
//   humanizeIngestError() (top of file) maps each to a calm UX message.
//
//     url_invalid                  malformed URL
//     url_unsupported_scheme       not http(s)
//     url_timeout                  fetch took >30s
//     url_blocked                  401/403 — site refuses bots
//     url_not_found                404
//     url_server_error             5xx from origin
//     url_too_large                response >20MB
//     url_unsupported_content_type not html / text / pdf
//     pdf_extract_failed           Claude couldn't read the PDF
//     embed_rate_limited           Voyage 429 (thrown from voyage.ts)
//     embed_failed                 other Voyage errors
//
// Structured per-stage logging: every step writes `[ingest-material]
// stage=X url=Y ...` so failures are greppable without sprinkling
// try/catch debug everywhere.

const FETCH_TIMEOUT_MS = 30_000;
// 32 MB matches Claude's PDF processing cap. HTML pages this big are
// pathological — but we honor the same ceiling so the UX behavior
// stays uniform across content types.
const MAX_BODY_BYTES = 32 * 1024 * 1024;

async function fetchUrlAndExtract(args: {
  client: SupabaseClient;
  userId: string;
  url: string;
}): Promise<string> {
  if (!args.url) throw new Error('url_invalid');

  let parsed: URL;
  try {
    parsed = new URL(args.url);
  } catch {
    throw new Error('url_invalid');
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new Error('url_unsupported_scheme');
  }

  const stage = (s: string, extra: Record<string, unknown> = {}) => {
    console.log(`[ingest-material] stage=${s} url=${args.url}`, extra);
  };
  stage('fetch_start');

  let res: Response;
  try {
    res = await fetch(args.url, {
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
      redirect: 'follow',
      headers: {
        // Pose as a generic browser. Sites that hard-block bots will
        // still 403 us — that's the typed url_blocked path. Anything
        // we can do beyond this requires real headless infra.
        'user-agent':
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 ' +
          '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        accept:
          'text/html,application/pdf,application/xhtml+xml,text/plain,*/*;q=0.8',
        'accept-language': 'en-US,en;q=0.9',
      },
    });
  } catch (e) {
    const msg = (e as Error).message.toLowerCase();
    if (msg.includes('timeout') || msg.includes('signal timed out')) {
      stage('fetch_timeout');
      throw new Error('url_timeout');
    }
    stage('fetch_throw', { err: msg.slice(0, 200) });
    throw new Error('url_unreachable');
  }

  stage('fetch_response', {
    status: res.status,
    contentType: res.headers.get('content-type'),
    contentLength: res.headers.get('content-length'),
  });

  if (res.status === 401 || res.status === 403) {
    throw new Error('url_blocked');
  }
  if (res.status === 404) {
    throw new Error('url_not_found');
  }
  if (res.status >= 500) {
    throw new Error('url_server_error');
  }
  if (!res.ok) {
    throw new Error('url_unreachable');
  }

  const rawContentType = (res.headers.get('content-type') ?? '').toLowerCase();
  const contentType = rawContentType.split(';')[0].trim(); // strip charset
  const looksLikePdf =
    contentType === 'application/pdf' ||
    parsed.pathname.toLowerCase().endsWith('.pdf');

  // PDF route — download bytes, hand to Claude PDF extractor.
  if (looksLikePdf) {
    stage('pdf_download');
    const buf = await readBoundedBody(res, MAX_BODY_BYTES);
    if (buf === null) throw new Error('url_too_large');
    stage('pdf_extract_start', { bytes: buf.byteLength });
    try {
      const text = await extractPdfText({
        client: args.client,
        userId: args.userId,
        base64: bytesToBase64(buf),
      });
      stage('pdf_extract_ok', { chars: text.length });
      return text;
    } catch (e) {
      stage('pdf_extract_throw', {
        err: (e as Error).message.slice(0, 200),
      });
      throw new Error('pdf_extract_failed');
    }
  }

  // HTML / text route. application/json and other structured types
  // don't make sense as study material — surface a typed message
  // instead of cramming them through the HTML stripper.
  const isTextual =
    contentType.startsWith('text/') ||
    contentType === 'application/xhtml+xml' ||
    contentType === 'application/xml' ||
    contentType === '';
  if (!isTextual) {
    stage('content_type_rejected', { contentType });
    throw new Error('url_unsupported_content_type');
  }

  stage('html_read');
  const text = await res.text();
  if (text.length > MAX_BODY_BYTES) throw new Error('url_too_large');
  const extracted = stripHtml(text);
  stage('html_extracted', { rawChars: text.length, cleanChars: extracted.length });
  if (extracted.trim().length < 40) {
    // Strong signal we got blocked by a JS-rendered or auth-gated
    // page that returned an empty shell.
    throw new Error('url_empty_or_jsrendered');
  }
  return extracted;
}

/// Read a response body up to [maxBytes]. Returns null if the body is
/// larger than the cap (the stream is canceled to avoid downloading
/// the rest).
async function readBoundedBody(
  res: Response,
  maxBytes: number,
): Promise<Uint8Array | null> {
  // Trust content-length if present + within bound.
  const cl = parseInt(res.headers.get('content-length') ?? '0', 10);
  if (cl > maxBytes) {
    try { await res.body?.cancel(); } catch (_) {/* */}
    return null;
  }
  const ab = await res.arrayBuffer();
  if (ab.byteLength > maxBytes) return null;
  return new Uint8Array(ab);
}

function bytesToBase64(bytes: Uint8Array): string {
  // btoa works on binary strings up to ~1 MB cleanly; for larger
  // payloads we chunk to avoid the call-stack limits.
  const chunk = 0x8000;
  let bin = '';
  for (let i = 0; i < bytes.length; i += chunk) {
    bin += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(bin);
}

/// Minimal HTML → plain text. Drops scripts/styles, collapses
/// whitespace. We deliberately avoid a heavyweight DOM parser in the
/// Edge runtime — but we DO preserve LaTeX delimiters (`$...$` and
/// `$$...$$`) literally so equations survive the strip and render
/// later via the math-aware markdown widget.
function stripHtml(html: string): string {
  return html
    .replace(/<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/gi, ' ')
    .replace(/<style\b[^<]*(?:(?!<\/style>)<[^<]*)*<\/style>/gi, ' ')
    .replace(/<head\b[^<]*(?:(?!<\/head>)<[^<]*)*<\/head>/gi, ' ')
    .replace(/<noscript\b[^<]*(?:(?!<\/noscript>)<[^<]*)*<\/noscript>/gi, ' ')
    // MathML — turn each <math> block into a placeholder. Some sites
    // expose equations as MathML; rendering them properly needs a
    // dedicated path, but at least we keep their alt text rather than
    // dumping the raw XML.
    .replace(
      /<math\b[^>]*>([\s\S]*?)<\/math>/gi,
      (_m, inner) => ` $$${(inner as string).replace(/<[^>]+>/g, ' ').trim()}$$ `,
    )
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
