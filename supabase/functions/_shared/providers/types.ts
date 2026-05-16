// Provider-agnostic interfaces for Yve's AI routing layer.
//
// Today only ClaudeProvider implements AiProvider, but the surface is
// designed so adding OpenAI or Gemini is a single file plus router rules.
// The conversational spine stays on Claude — see the README and the
// AIRouter task→model matrix for what each task currently routes to.

export type ProviderName = 'anthropic' | 'openai' | 'google';

export type TaskType =
  | 'chat'              // yve-chat streaming answer (forced tool follow-up)
  | 'chat-metadata'     // post-stream metadata extraction
  | 'vision'            // image / PDF / DOCX classification + OCR
  | 'pdf-extract'       // text-only extraction from a PDF
  | 'polish'            // Write-mode structured rewrite
  | 'recap'             // yve-recap structured weekly summary
  | 'infer-profile';    // chat-history → adaptation observations

export type QualityLevel = 'budget' | 'standard' | 'premium';

export interface ProviderMessage {
  role: 'user' | 'assistant';
  // String for plain text; array for multimodal turns (image/PDF + text).
  // Providers translate this to their native content-block shape.
  content: string | ProviderContentBlock[];
}

export type ProviderContentBlock =
  | { type: 'text'; text: string }
  | { type: 'image'; mediaType: string; base64: string }
  | { type: 'document'; mediaType: string; base64: string };

export interface ProviderTool {
  name: string;
  description: string;
  // JSON Schema shape; providers translate to their own tool format.
  inputSchema: Record<string, unknown>;
}

export interface ProviderRequest {
  systemPrompt: string;
  messages: ProviderMessage[];
  maxTokens?: number;
  tools?: ProviderTool[];
  /** Force a specific tool to be invoked. Provider-specific reliability. */
  forceTool?: string;
}

export interface CallObservability {
  providerUsed: ProviderName;
  modelUsed: string;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  latencyMs: number;
  estimatedCostUsd: number;
}

export interface ProviderResult extends CallObservability {
  text: string;
  toolUse: { name: string; input: Record<string, unknown> } | null;
}

export type ProviderStreamEvent =
  | { kind: 'text'; delta: string }
  | { kind: 'done'; observability: CallObservability }
  | { kind: 'error'; message: string; observability?: CallObservability };

export interface AiProvider {
  readonly name: ProviderName;
  complete(req: ProviderRequest, model: string): Promise<ProviderResult>;
  stream(req: ProviderRequest, model: string): AsyncGenerator<ProviderStreamEvent>;
}
