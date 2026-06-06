// POST /vision-ingest
//
// The Scan slice's entry point. The learner takes a photo (or picks from
// gallery), the bytes arrive here, Claude Vision classifies + transcribes +
// suggests next actions, and we persist a fully-formed chat session that
// the Scan Result sheet then resumes the moment the learner picks an action.
//
// Request (one of image_base64 / pdf_base64 / docx_base64 must be present):
//   {
//     image_base64?: string,         // raw base64 (no data: URI prefix)
//     mime_type?: 'image/jpeg' | 'image/png' | 'image/webp' | 'image/gif',
//     pdf_base64?: string,           // raw base64 PDF (up to 32MB, 100 pages)
//     pdf_name?: string,             // optional display name for the PDF
//     docx_base64?: string,          // raw base64 .docx — server extracts text
//     docx_name?: string,            // optional display name for the .docx
//     subject_id?: string,           // optional — file the scan into a subject
//   }
//
// Response:
//   {
//     session_id: string,            // pre-loaded chat the learner resumes
//     material_id: string | null,    // null if no subject_id was passed
//     document_type: DocumentType,
//     one_line_summary: string,
//     extracted_text: string,
//     concept_tags: string[],
//     suggested_actions: VisionAction[],
//     save_to_subject?: string,
//     mode_used: 'open',
//   }
//
// Side effects:
//   1. chat_sessions row created (mode='open', title from one_line_summary).
//   2. Two chat_messages rows: a synthetic user turn carrying the extracted
//      text, then Yve's first response with the action ladder converted into
//      the conversion-engine offer shape (so it shows up as chips in chat).
//   3. If subject_id is set, a materials row (kind='image') is created with
//      the extracted text indexed via Voyage — making the scan re-retrievable
//      from later chats in Materials mode.

import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { extractDocxText } from '../_shared/docx.ts';
import { trackCall } from '../_shared/providers/observability.ts';
import { route } from '../_shared/providers/router.ts';
import type { ProviderContentBlock } from '../_shared/providers/types.ts';
import {
  ANALYZE_SCAN_TOOL,
  VISION_SYSTEM_PROMPT,
  type DocumentType,
  type VisionActionKind,
  type VisionActionMode,
} from '../_shared/vision.ts';
import { chunkText, embedTexts } from '../_shared/voyage.ts';
import { buildLocaleAddendum } from '../_shared/yve_modes.ts';

const CORS_HEADERS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers':
    'authorization, x-client-info, apikey, content-type',
  'access-control-allow-methods': 'POST, OPTIONS',
};

const ALLOWED_MIME: ReadonlySet<string> = new Set<string>([
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/gif',
]);

interface VisionAction {
  label: string;
  kind: VisionActionKind;
  mode: VisionActionMode;
  prompt: string;
}

interface VisionPayload {
  document_type: DocumentType;
  one_line_summary: string;
  extracted_text: string;
  concept_tags?: string[];
  suggested_actions: VisionAction[];
  save_to_subject?: string;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  try {
    const payload = await req.json();
    const imageB64: string = typeof payload.image_base64 === 'string'
      ? payload.image_base64
      : '';
    const pdfB64: string = typeof payload.pdf_base64 === 'string'
      ? payload.pdf_base64
      : '';
    const docxB64: string = typeof payload.docx_base64 === 'string'
      ? payload.docx_base64
      : '';
    const mime: string = ALLOWED_MIME.has(payload.mime_type)
      ? payload.mime_type
      : 'image/jpeg';
    const pdfName: string | undefined =
      typeof payload.pdf_name === 'string' && payload.pdf_name.length > 0
        ? payload.pdf_name
        : undefined;
    const docxName: string | undefined =
      typeof payload.docx_name === 'string' && payload.docx_name.length > 0
        ? payload.docx_name
        : undefined;
    const subjectId: string | undefined =
      typeof payload.subject_id === 'string' && payload.subject_id.length > 0
        ? payload.subject_id
        : undefined;
    // BCP-47 device locale ("es-MX", "fr-FR"…). Drives the language Yve uses
    // in one_line_summary / extracted_text formatting / suggested_actions
    // labels — so a Spanish learner scanning a worksheet sees Spanish chips.
    const locale: string | undefined =
      typeof payload.locale === 'string' && payload.locale.length > 0
        ? payload.locale
        : undefined;

    if (!imageB64 && !pdfB64 && !docxB64) {
      return json(
        { error: 'image_base64, pdf_base64, or docx_base64 is required' },
        400,
      );
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!supabaseUrl || !serviceKey) {
      throw new Error('Server missing SUPABASE env vars.');
    }

    const client = createClient(supabaseUrl, serviceKey, {
      global: {
        headers: { Authorization: req.headers.get('Authorization') ?? '' },
      },
    });
    const {
      data: { user },
    } = await client.auth.getUser();
    if (!user) return json({ error: 'not authenticated' }, 401);

    // 1) Vision call — force the analyze_scan tool. The content array
    //    carries either an image block (photo), a document block (PDF —
    //    Claude reads natively), or pre-extracted text (DOCX — Claude
    //    doesn't have a native .docx block, so we unzip server-side).
    const contentBlocks: ProviderContentBlock[] = [];
    if (pdfB64) {
      contentBlocks.push({
        type: 'document',
        mediaType: 'application/pdf',
        base64: pdfB64,
      });
      contentBlocks.push({
        type: 'text',
        text:
          'Analyze this study material. Call analyze_scan with your classification, transcription, concept tags, and the most useful next-action ladder for this specific document.',
      });
    } else if (docxB64) {
      const docxBytes = _base64ToBytes(docxB64);
      const extractedText = await extractDocxText(docxBytes);
      if (!extractedText.trim()) {
        return json({
          error:
            'I couldn\'t pull any readable text out of that Word document. Try re-saving from Word or copy the body into a Note.',
        }, 422);
      }
      contentBlocks.push({
        type: 'text',
        text:
          `Analyze this Word document the learner just uploaded. Call analyze_scan with your classification, the extracted_text (you may polish formatting — preserve numbered questions, lists, math), concept tags, and the most useful next-action ladder. Document body follows:\n\n${extractedText}`,
      });
    } else {
      contentBlocks.push({
        type: 'image',
        mediaType: mime,
        base64: imageB64,
      });
      contentBlocks.push({
        type: 'text',
        text:
          'Analyze this study material. Call analyze_scan with your classification, transcription, concept tags, and the most useful next-action ladder for this specific document.',
      });
    }

    // PDFs + DOCX benefit from a higher token budget since multi-page
    // extraction can be substantial. Cap at 8K to keep latency bounded.
    const maxTokens = (pdfB64 || docxB64) ? 8192 : 2048;

    const visionRoute = route({ taskType: 'vision' });
    const result = await visionRoute.provider.complete(
      {
        systemPrompt: VISION_SYSTEM_PROMPT + buildLocaleAddendum(locale),
        messages: [{ role: 'user', content: contentBlocks }],
        tools: [{
          name: ANALYZE_SCAN_TOOL.name,
          description: ANALYZE_SCAN_TOOL.description,
          inputSchema: ANALYZE_SCAN_TOOL.input_schema as Record<string, unknown>,
        }],
        forceTool: ANALYZE_SCAN_TOOL.name,
        maxTokens,
      },
      visionRoute.model,
    );
    void trackCall({
      client,
      userId: user.id,
      taskType: 'vision',
      observability: result,
    });

    if (!result.toolUse || result.toolUse.name !== ANALYZE_SCAN_TOOL.name) {
      return json({
        error:
          'Vision call did not return structured output. Try again or describe the document in text.',
      }, 502);
    }

    const vision = result.toolUse.input as VisionPayload;
    if (!vision.extracted_text?.trim()) {
      return json({
        error:
          'I couldn\'t pick up enough text from this image. Try better lighting or a closer shot, or type the question instead.',
      }, 422);
    }

    // 2) Create the chat session pre-loaded with the scan.
    const sessionId = await createScanSession({
      client,
      userId: user.id,
      subjectId,
      vision,
      tokens: { input: result.inputTokens, output: result.outputTokens },
    });

    // 3) Persist the extracted text as a material if filed under a subject.
    //    Done after the session so the learner can immediately resume; the
    //    embed/index step is best-effort and never blocks the response.
    let materialId: string | null = null;
    if (subjectId) {
      try {
        materialId = await persistMaterial({
          client,
          userId: user.id,
          subjectId,
          vision,
          kind: pdfB64 ? 'pdf' : (docxB64 ? 'doc' : 'image'),
          displayName: pdfName ?? docxName,
        });
      } catch (e) {
        console.error('material persist failed', e);
      }
    }

    return json({
      session_id: sessionId,
      material_id: materialId,
      document_type: vision.document_type,
      one_line_summary: vision.one_line_summary,
      extracted_text: vision.extracted_text,
      concept_tags: vision.concept_tags ?? [],
      suggested_actions: vision.suggested_actions ?? [],
      save_to_subject: vision.save_to_subject,
      mode_used: 'open',
    });
  } catch (err) {
    console.error(err);
    return json({ error: (err as Error).message }, 500);
  }
});

async function createScanSession(args: {
  client: SupabaseClient;
  userId: string;
  subjectId?: string;
  vision: VisionPayload;
  tokens: { input: number; output: number };
}): Promise<string> {
  const title = autoTitle(args.vision.one_line_summary);

  const { data: session, error: sErr } = await args.client
    .from('chat_sessions')
    .insert({
      user_id: args.userId,
      subject_id: args.subjectId ?? null,
      title,
      mode: 'open',
    })
    .select('id')
    .single();
  if (sErr || !session) {
    throw new Error(`chat_sessions insert failed: ${sErr?.message}`);
  }
  const sessionId = session.id as string;

  // Convert vision suggested_actions into the conversion-engine offer shape
  // so they render in-chat as follow-up chips after the scan turn.
  const offer = {
    suggestions: args.vision.suggested_actions.map((a) => ({
      label: a.label,
      kind: mapToOfferKind(a.kind),
      payload: a.prompt,
    })),
  };

  // Synthetic user turn — we put the extracted text on the user side so the
  // conversation feels like "I scanned this" → "Here's what I see."
  const userContent =
    `📷 Scanned material\n\n${args.vision.extracted_text}`;

  const yveContent =
    `${args.vision.one_line_summary}${
      args.vision.concept_tags && args.vision.concept_tags.length > 0
        ? `\n\nConcepts covered: ${args.vision.concept_tags.join(', ')}.`
        : ''
    }\n\nWhat would you like to do with this?`;

  const { error: mErr } = await args.client.from('chat_messages').insert([
    {
      session_id: sessionId,
      user_id: args.userId,
      role: 'user',
      content: userContent,
      concept_tags: [],
    },
    {
      session_id: sessionId,
      user_id: args.userId,
      role: 'assistant',
      content: yveContent,
      concept_tags: args.vision.concept_tags ?? [],
      offer,
      confidence_signal: 'unknown',
      save_to_subject: args.vision.save_to_subject ?? null,
      input_tokens: args.tokens.input,
      output_tokens: args.tokens.output,
    },
  ]);
  if (mErr) throw new Error(`chat_messages insert: ${mErr.message}`);

  await args.client
    .from('chat_sessions')
    .update({
      message_count: 2,
      last_message_preview: args.vision.one_line_summary.length > 140
        ? `${args.vision.one_line_summary.slice(0, 137)}...`
        : args.vision.one_line_summary,
      updated_at: new Date().toISOString(),
    })
    .eq('id', sessionId);

  // Concept observations — same write the regular chat path does, so the
  // mastery view picks up the scan immediately.
  if ((args.vision.concept_tags ?? []).length > 0 && args.subjectId) {
    try {
      await args.client.from('concept_observations').insert(
        args.vision.concept_tags!.map((concept) => ({
          user_id: args.userId,
          subject_id: args.subjectId ?? null,
          session_id: sessionId,
          concept,
          confidence_signal: 'unknown',
        })),
      );
    } catch (e) {
      console.error('concept observations failed', e);
    }
  }

  return sessionId;
}

async function persistMaterial(args: {
  client: SupabaseClient;
  userId: string;
  subjectId: string;
  vision: VisionPayload;
  kind: 'image' | 'pdf' | 'doc';
  displayName?: string;
}): Promise<string> {
  const { data: matRow, error: matErr } = await args.client
    .from('materials')
    .insert({
      subject_id: args.subjectId,
      user_id: args.userId,
      kind: args.kind,
      name: args.displayName ?? args.vision.one_line_summary,
      status: 'processing',
      raw_text: args.vision.extracted_text,
    })
    .select('id')
    .single();
  if (matErr || !matRow) {
    throw new Error(`materials insert failed: ${matErr?.message}`);
  }
  const materialId = matRow.id as string;

  try {
    const chunks = chunkText(args.vision.extracted_text);
    if (chunks.length > 0) {
      const { embeddings } = await embedTexts(chunks, 'document');
      const rows = chunks.map((content, i) => ({
        material_id: materialId,
        subject_id: args.subjectId,
        user_id: args.userId,
        chunk_index: i,
        content,
        embedding: embeddings[i],
      }));
      await args.client.from('material_chunks').insert(rows);
    }
    await args.client
      .from('materials')
      .update({ status: 'ready' })
      .eq('id', materialId);
  } catch (e) {
    await args.client
      .from('materials')
      .update({ status: 'failed', error: (e as Error).message })
      .eq('id', materialId);
    throw e;
  }

  return materialId;
}

function autoTitle(summary: string): string {
  const t = summary.trim();
  if (t.length <= 60) return t;
  return `${t.slice(0, 57)}...`;
}

function _base64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/// Vision action kinds map to the conversion-engine OfferKind so the chat
/// surface treats scan-generated chips identically to chat-generated ones.
function mapToOfferKind(kind: VisionActionKind): string {
  switch (kind) {
    case 'solve':
      return 'next';
    case 'explain':
      return 'explain';
    case 'summarize':
      return 'summarize';
    case 'quiz':
      return 'quiz';
    case 'flashcards':
      return 'flashcards';
    case 'transcribe':
      return 'cite';
    case 'save':
      return 'save';
    case 'other':
    default:
      return 'related';
  }
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'content-type': 'application/json' },
  });
}
