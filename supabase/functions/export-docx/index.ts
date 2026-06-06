// POST /export-docx
//
// Turns a Yve markdown response into a real Microsoft Word `.docx`
// document with native OMML (Office Math Markup Language) equations
// — the same format Word produces when you build equations in its own
// equation editor. The output equations are vector-scaled, clickable
// (Word's equation editor opens on double-click), and survive
// round-tripping through Word, Google Docs, and Pages.
//
// Architecture:
//
//   Markdown + LaTeX
//        ↓ parse markdown (marked) into a token stream
//        ↓ for each text run, split on $...$ / $$...$$ delimiters
//        ↓ convert each LaTeX fragment → docx-lib Math object tree
//             via a focused MathML walker (LaTeX → MathML via temml,
//             MathML → docx Math via our convertMmlNode helper)
//        ↓ assemble Paragraph / TextRun / Math / Heading via docx lib
//        ↓ Packer.toBuffer → .docx bytes
//
// Why not just embed an OMML XML string? Because the `docx` library
// serializes its own Math objects to compliant OMML inside the right
// namespace; if we tried to inject raw OMML XML strings we'd lose
// the library's escaping and namespace handling and Word would refuse
// to open the document.
//
// Why not Pandoc? Pandoc is the gold standard but it's a Haskell
// binary, not deployable to Deno Edge Functions in a reasonable
// bundle size. WebAssembly builds exist but are 15-20MB.
//
// Request:  { markdown: string, title?: string }
// Response: 200 with application/vnd.openxmlformats-officedocument.wordprocessingml.document
// Errors:
//   400  malformed request
//   401  not authenticated
//   500  conversion failure (returns JSON with `detail` for debugging)

import {
  AlignmentType,
  Document,
  HeadingLevel,
  LevelFormat,
  Math,
  MathFraction,
  MathRadical,
  MathRun,
  MathSubScript,
  MathSubSuperScript,
  MathSuperScript,
  Packer,
  Paragraph,
  TextRun,
  // deno-lint-ignore no-explicit-any
} from 'https://esm.sh/docx@8.5.0';
import { marked, type Token } from 'https://esm.sh/marked@12.0.0';
import temml from 'https://esm.sh/temml@0.10.29';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { DOMParser, Element } from 'https://esm.sh/@xmldom/xmldom@0.8.10';

// ─────────────────────────────────────────────────────────────────────
// HTTP boilerplate
// ─────────────────────────────────────────────────────────────────────

const CORS_HEADERS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers':
    'authorization, x-client-info, apikey, content-type',
  'access-control-allow-methods': 'POST, OPTIONS',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);

  // Light auth check — the function shouldn't render docs for unauthed users
  // (it'd let anyone spam Anthropic-content exports). We don't actually
  // need the user_id for anything beyond presence.
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceKey) return json({ error: 'server not configured' }, 500);
  const authHeader = req.headers.get('Authorization') ?? '';
  const userClient = createClient(supabaseUrl, serviceKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: { user }, error: userErr } = await userClient.auth.getUser();
  if (userErr || !user) return json({ error: 'not authenticated' }, 401);

  let body: { markdown?: string; title?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: 'invalid JSON body' }, 400);
  }
  const markdown = (body.markdown ?? '').trim();
  if (!markdown) return json({ error: 'markdown is required' }, 400);
  const title = body.title?.trim() || 'Yve';

  // ── Build the document ──────────────────────────────────────────
  try {
    const doc = buildDocument(markdown, title);
    const buffer = await Packer.toBuffer(doc);
    return new Response(buffer, {
      status: 200,
      headers: {
        ...CORS_HEADERS,
        'content-type':
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'content-disposition': `attachment; filename="${title}.docx"`,
      },
    });
  } catch (e) {
    console.error('[export-docx] build failed:', e);
    return json({
      error: 'document build failed',
      detail: (e as Error).message,
    }, 500);
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'content-type': 'application/json' },
  });
}

// ─────────────────────────────────────────────────────────────────────
// Markdown → docx body
// ─────────────────────────────────────────────────────────────────────

function buildDocument(markdown: string, title: string): Document {
  const tokens = marked.lexer(markdown) as Token[];
  const children: Paragraph[] = [];
  for (const tok of tokens) {
    const para = tokenToParagraphs(tok);
    if (para) children.push(...para);
  }

  return new Document({
    title,
    creator: 'Yve',
    description: 'Exported from Yve',
    styles: {
      default: {
        document: {
          run: { font: 'Calibri', size: 22 }, // 22 half-points = 11pt
        },
      },
    },
    numbering: {
      config: [
        {
          reference: 'yve-bullet',
          levels: [
            {
              level: 0,
              format: LevelFormat.BULLET,
              text: '•',
              alignment: AlignmentType.LEFT,
              style: { paragraph: { indent: { left: 720, hanging: 360 } } },
            },
          ],
        },
        {
          reference: 'yve-ordered',
          levels: [
            {
              level: 0,
              format: LevelFormat.DECIMAL,
              text: '%1.',
              alignment: AlignmentType.LEFT,
              style: { paragraph: { indent: { left: 720, hanging: 360 } } },
            },
          ],
        },
      ],
    },
    sections: [{ children }],
  });
}

function tokenToParagraphs(tok: Token): Paragraph[] | null {
  switch (tok.type) {
    case 'heading': {
      const level = (tok as { depth: number }).depth;
      const text = (tok as { text: string }).text;
      const heading =
        level === 1 ? HeadingLevel.HEADING_1 :
        level === 2 ? HeadingLevel.HEADING_2 :
        level === 3 ? HeadingLevel.HEADING_3 :
        HeadingLevel.HEADING_4;
      return [new Paragraph({ heading, children: inlineRuns(text) })];
    }
    case 'paragraph': {
      const text = (tok as { text: string }).text;
      return [new Paragraph({ children: inlineRuns(text) })];
    }
    case 'list': {
      const list = tok as { ordered: boolean; items: { text: string }[] };
      return list.items.map((item) =>
        new Paragraph({
          children: inlineRuns(item.text),
          numbering: {
            reference: list.ordered ? 'yve-ordered' : 'yve-bullet',
            level: 0,
          },
        })
      );
    }
    case 'blockquote': {
      const text = (tok as { text: string }).text;
      return [new Paragraph({
        children: inlineRuns(text),
        indent: { left: 360 },
      })];
    }
    case 'code': {
      // Code fences. Single paragraph in Consolas; preserve newlines as
      // line breaks within the paragraph for compactness.
      const code = (tok as { text: string }).text;
      const lines = code.split('\n');
      const runs: TextRun[] = [];
      lines.forEach((line, i) => {
        runs.push(new TextRun({ text: line, font: 'Consolas', size: 20 }));
        if (i < lines.length - 1) runs.push(new TextRun({ break: 1 }));
      });
      return [new Paragraph({ children: runs })];
    }
    case 'space':
    case 'hr':
    case 'html':
      return null;
    default:
      // Unrecognized tokens fall through as plain text so nothing gets lost.
      const raw = (tok as { raw?: string }).raw ?? '';
      if (!raw.trim()) return null;
      return [new Paragraph({ children: inlineRuns(raw) })];
  }
}

// ─────────────────────────────────────────────────────────────────────
// Inline content: split text on math delimiters, then render
// ─────────────────────────────────────────────────────────────────────

type InlineChild = TextRun | Math;

function inlineRuns(input: string): InlineChild[] {
  // Walk the string, peeling off $$...$$, $...$, and plain text. We do
  // this manually rather than via regex.split() so we keep delimiter
  // boundaries clean even when math contains backslashes / braces.
  const out: InlineChild[] = [];
  let i = 0;
  const n = input.length;
  let buf = '';

  const flushText = () => {
    if (!buf) return;
    // Strip simple markdown markers we want to preserve as formatting.
    pushFormattedText(out, buf);
    buf = '';
  };

  while (i < n) {
    // Display math $$...$$
    if (input[i] === '$' && input[i + 1] === '$') {
      const end = input.indexOf('$$', i + 2);
      if (end !== -1) {
        flushText();
        const latex = input.slice(i + 2, end);
        const math = latexToMath(latex);
        if (math) out.push(math);
        i = end + 2;
        continue;
      }
    }
    // Inline math $...$  (guarded so we don't eat currency)
    if (
      input[i] === '$' &&
      /[^\d\s]/.test(input[i + 1] ?? '') &&
      input.indexOf('$', i + 1) !== -1
    ) {
      const end = input.indexOf('$', i + 1);
      if (end !== -1) {
        // Reject if there's a newline in the segment — likely not math
        const seg = input.slice(i + 1, end);
        if (!seg.includes('\n')) {
          flushText();
          const math = latexToMath(seg);
          if (math) out.push(math);
          i = end + 1;
          continue;
        }
      }
    }
    buf += input[i];
    i++;
  }
  flushText();
  return out;
}

/// Apply minimal markdown inline formatting (bold, italic, inline code)
/// to a text segment and push as one or more TextRun.
function pushFormattedText(out: InlineChild[], text: string): void {
  // Cheap pass-through tokeniser for **bold**, *italic*, `code`.
  const re = /(\*\*[^*]+\*\*|\*[^*]+\*|`[^`]+`)/g;
  let last = 0;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) {
    if (m.index > last) {
      out.push(new TextRun({ text: text.slice(last, m.index) }));
    }
    const seg = m[0];
    if (seg.startsWith('**')) {
      out.push(new TextRun({ text: seg.slice(2, -2), bold: true }));
    } else if (seg.startsWith('*')) {
      out.push(new TextRun({ text: seg.slice(1, -1), italics: true }));
    } else if (seg.startsWith('`')) {
      out.push(new TextRun({ text: seg.slice(1, -1), font: 'Consolas' }));
    }
    last = m.index + seg.length;
  }
  if (last < text.length) {
    out.push(new TextRun({ text: text.slice(last) }));
  }
}

// ─────────────────────────────────────────────────────────────────────
// LaTeX → docx Math
// ─────────────────────────────────────────────────────────────────────

/// Convert one LaTeX fragment to a docx-lib Math object. Returns null
/// if conversion fails — caller should fall back to plain text in that
/// case rather than abort the export.
function latexToMath(latex: string): Math | null {
  try {
    // temml gives us KaTeX-style MathML output. We parse it and walk
    // the tree, mapping each MathML node onto the corresponding docx
    // Math primitive. Anything we don't recognize falls back to a
    // MathRun with the element's text content — better than nothing.
    const mathml = temml.renderToString(latex.trim(), {
      throwOnError: false,
      displayMode: false,
    });
    const doc = new DOMParser().parseFromString(mathml, 'text/xml');
    const root = doc.documentElement;
    if (!root) return null;
    const children = walkMmlChildren(root);
    if (!children.length) return null;
    return new Math({ children });
  } catch (e) {
    console.error('[export-docx] latexToMath failed:', latex, e);
    return null;
  }
}

// Math primitive types accepted by the docx library's Math constructor.
// deno-lint-ignore no-explicit-any
type MathChild = any;

function walkMmlChildren(node: Element): MathChild[] {
  const out: MathChild[] = [];
  for (let i = 0; i < node.childNodes.length; i++) {
    const child = node.childNodes[i] as Element;
    const converted = convertMmlNode(child);
    if (Array.isArray(converted)) out.push(...converted);
    else if (converted) out.push(converted);
  }
  return out;
}

/// Map a MathML element to a docx-lib Math primitive (or array of
/// primitives, or null to skip). Handles the scoped vocabulary:
/// fractions, exponents, subscripts, radicals, n-ary operators,
/// matrices, parentheses, and identifiers/numbers/operators.
function convertMmlNode(node: Element): MathChild | MathChild[] | null {
  if (!node) return null;

  // Text node (xmldom maps these to nodeType 3)
  if (node.nodeType === 3) {
    const text = (node.nodeValue ?? '').trim();
    return text ? new MathRun(text) : null;
  }

  // Skip non-element nodes (comments, processing instructions).
  if (node.nodeType !== 1) return null;

  const tag = (node.tagName || '').toLowerCase().replace(/^.*:/, '');

  switch (tag) {
    // Identifiers, numbers, operators → plain math text runs.
    case 'mi':
    case 'mn':
    case 'mo':
    case 'mtext': {
      const text = elementText(node);
      return text ? new MathRun(text) : null;
    }

    // Containers — just unwrap.
    case 'mrow':
    case 'math':
    case 'mstyle':
    case 'semantics':
    case 'mpadded':
    case 'mphantom':
      return walkMmlChildren(node);

    // Fraction: <mfrac><num/><den/></mfrac>
    case 'mfrac': {
      const kids = elementChildren(node);
      if (kids.length < 2) return walkMmlChildren(node);
      return new MathFraction({
        numerator: walkMmlChildren(kids[0]),
        denominator: walkMmlChildren(kids[1]),
      });
    }

    // Superscript: <msup><base/><exp/></msup>
    case 'msup': {
      const kids = elementChildren(node);
      if (kids.length < 2) return walkMmlChildren(node);
      return new MathSuperScript({
        children: walkMmlChildren(kids[0]),
        superScript: walkMmlChildren(kids[1]),
      });
    }

    // Subscript: <msub><base/><sub/></msub>
    case 'msub': {
      const kids = elementChildren(node);
      if (kids.length < 2) return walkMmlChildren(node);
      return new MathSubScript({
        children: walkMmlChildren(kids[0]),
        subScript: walkMmlChildren(kids[1]),
      });
    }

    // Combined sub+sup: <msubsup><base/><sub/><sup/></msubsup>
    case 'msubsup': {
      const kids = elementChildren(node);
      if (kids.length < 3) return walkMmlChildren(node);
      return new MathSubSuperScript({
        children: walkMmlChildren(kids[0]),
        subScript: walkMmlChildren(kids[1]),
        superScript: walkMmlChildren(kids[2]),
      });
    }

    // Radical (root): <msqrt>x</msqrt> or <mroot><x/><n/></mroot>
    case 'msqrt':
      return new MathRadical({ children: walkMmlChildren(node) });
    case 'mroot': {
      const kids = elementChildren(node);
      if (kids.length < 2) {
        return new MathRadical({ children: walkMmlChildren(node) });
      }
      return new MathRadical({
        children: walkMmlChildren(kids[0]),
        degree: walkMmlChildren(kids[1]),
      });
    }

    // Over/under (rarely produced by our LaTeX subset but handle anyway).
    case 'mover':
    case 'munder':
    case 'munderover':
      return walkMmlChildren(node);

    // Tables (matrices, systems, cases).
    case 'mtable':
    case 'mtr':
    case 'mtd':
      // docx-lib doesn't expose MathMatrix in v8.x cleanly; flatten to
      // a row of runs separated by visible breaks. Not perfect but
      // legible in Word — the equation editor can still parse it.
      return flattenTable(node);

    // Fenced expression like (...) — docx's MathBracket exists; if not
    // available we just include the children inline with the explicit
    // open/close characters from the element's attributes.
    case 'mfenced': {
      const open = node.getAttribute('open') || '(';
      const close = node.getAttribute('close') || ')';
      const inner = walkMmlChildren(node);
      return [
        new MathRun(open),
        ...inner,
        new MathRun(close),
      ];
    }

    // Unknown / unhandled: fall through to children so we don't lose
    // the math entirely.
    default:
      return walkMmlChildren(node);
  }
}

function elementChildren(node: Element): Element[] {
  const out: Element[] = [];
  for (let i = 0; i < node.childNodes.length; i++) {
    const c = node.childNodes[i] as Element;
    if (c.nodeType === 1) out.push(c);
  }
  return out;
}

function elementText(node: Element): string {
  let s = '';
  for (let i = 0; i < node.childNodes.length; i++) {
    const c = node.childNodes[i];
    if (c.nodeType === 3) s += c.nodeValue ?? '';
    else if (c.nodeType === 1) s += elementText(c as Element);
  }
  return s.trim();
}

/// Flatten a MathML table into a sequence of math runs separated by
/// line break / column separator so Word at least renders something
/// readable. Real matrix support is a v2 polish item.
function flattenTable(node: Element): MathChild[] {
  const out: MathChild[] = [];
  const rows = elementChildren(node).filter(
    (e) => e.tagName?.toLowerCase().replace(/^.*:/, '') === 'mtr',
  );
  rows.forEach((row, rowIdx) => {
    const cells = elementChildren(row).filter(
      (e) => e.tagName?.toLowerCase().replace(/^.*:/, '') === 'mtd',
    );
    cells.forEach((cell, cellIdx) => {
      out.push(...walkMmlChildren(cell));
      if (cellIdx < cells.length - 1) out.push(new MathRun(' \\quad '));
    });
    if (rowIdx < rows.length - 1) out.push(new MathRun(' ; '));
  });
  return out;
}
