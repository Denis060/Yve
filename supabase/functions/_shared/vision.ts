// Vision analysis tool schema + per-document-type framing for scans.
//
// The scan flow forces Claude to call analyze_scan exactly once. The schema
// gives us strict, structured output for the Scan Result sheet: classification,
// extracted text (markdown-preserved), concept tags, and a ranked action
// ladder Yve generates per scan rather than picking from a fixed menu.

export type DocumentType =
  | 'worksheet'
  | 'textbook'
  | 'slide'
  | 'handwritten'
  | 'equation'
  | 'article'
  | 'screenshot'
  | 'photo'
  | 'other';

export type VisionActionKind =
  | 'solve'
  | 'explain'
  | 'summarize'
  | 'quiz'
  | 'flashcards'
  | 'transcribe'
  | 'save'
  | 'other';

export type VisionActionMode =
  | 'assignment'
  | 'learn'
  | 'practice'
  | 'write'
  | 'materials'
  | 'open';

export const VISION_SYSTEM_PROMPT = `You are Yve's scan-analysis lens — the first impression of a learner's study material.

The learner just shared a document — either a photo they took (many are tired, working late, holding their phone in one hand) or a PDF they're studying from. Your job is to be instantly useful:

1. Identify what the document is in plain language ("I see your algebra worksheet — three problems on linear equations" / "I see chapter 7 of your pathophysiology textbook — covers heart failure mechanisms").
2. Transcribe the text content carefully and preserve structure: numbered questions stay numbered, math goes in LaTeX, lists stay as lists, headings as headings. For multi-page PDFs, transcribe everything but use markdown headings to mark page boundaries when they aid navigation ("## Page 2", etc.). If the source uses tables, render markdown tables. If the source has diagrams you can't transcribe, describe them briefly inline ("[diagram: parallelogram with sides labeled a, b, c]").
3. Tag the concept(s) covered with specific names (e.g. "linear equations", "Frank-Starling mechanism" — not "math" or "biology").
4. Propose 2–4 actions the learner most likely wants next, ranked. Each action label must reference the actual content ("Solve problem 3", "Summarize chapter 7" — not "Solve it"). Each action carries a short prompt the chat will send if the learner taps it.

Default ranked action ladders, by document type:
- worksheet / equation → Solve all, Explain the concept, Quiz me, Save
- textbook / article → Summarize, Explain key concepts, Quiz me, Save
- slide → Summarize, Make flashcards, Save
- handwritten → Transcribe (clean copy), Quiz me, Save
- screenshot → Summarize the passage, Explain it, Save

If the document obviously belongs to a known subject (nursing, anatomy, calculus, Spanish, etc.), populate save_to_subject with the obvious bucket. Otherwise omit it.

Be warm and concrete. Your one_line_summary is what the learner sees first — make it specific to *this* document, not a template.`;

export const ANALYZE_SCAN_TOOL = {
  name: 'analyze_scan',
  description:
    'Yve\'s structured analysis of the scanned document. Always call this exactly once.',
  input_schema: {
    type: 'object',
    properties: {
      document_type: {
        type: 'string',
        enum: [
          'worksheet',
          'textbook',
          'slide',
          'handwritten',
          'equation',
          'article',
          'screenshot',
          'photo',
          'other',
        ],
      },
      one_line_summary: {
        type: 'string',
        description:
          'Warm, specific "I see your..." summary referencing the actual content.',
      },
      extracted_text: {
        type: 'string',
        description:
          'Full transcription as markdown. Preserve numbered questions, LaTeX math, lists, tables, headings. Describe non-transcribable visual elements inline in brackets.',
      },
      concept_tags: {
        type: 'array',
        items: { type: 'string' },
        description:
          'Specific concept names the learner could drill (1–4 typical).',
      },
      suggested_actions: {
        type: 'array',
        minItems: 1,
        maxItems: 4,
        items: {
          type: 'object',
          properties: {
            label: {
              type: 'string',
              description:
                'Short, action-oriented chip text referencing this document\'s actual content.',
            },
            kind: {
              type: 'string',
              enum: [
                'solve',
                'explain',
                'summarize',
                'quiz',
                'flashcards',
                'transcribe',
                'save',
                'other',
              ],
            },
            mode: {
              type: 'string',
              enum: [
                'assignment',
                'learn',
                'practice',
                'write',
                'materials',
                'open',
              ],
              description:
                'Which Yve mode the chat should open in when the learner taps this action.',
            },
            prompt: {
              type: 'string',
              description:
                'The message sent to Yve when the learner taps the action. Should be short (≤ 30 words) because the chat already has the scanned text in its history.',
            },
          },
          required: ['label', 'kind', 'mode', 'prompt'],
        },
      },
      save_to_subject: {
        type: 'string',
        description:
          'Optional suggested subject name the document belongs to (e.g. "Nursing 201"). Omit if not obvious.',
      },
    },
    required: [
      'document_type',
      'one_line_summary',
      'extracted_text',
      'suggested_actions',
    ],
  },
} as const;

/// The default vision model. Haiku is fast enough that the learner feels the
/// scan land in seconds; the downstream chat still uses Sonnet via yve-chat
/// where reasoning quality matters more.
export const DEFAULT_VISION_MODEL = 'claude-haiku-4-5-20251001';
