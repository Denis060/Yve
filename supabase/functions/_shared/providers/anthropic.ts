// Anthropic Claude provider. The only AiProvider implementation today —
// future OpenAI / Gemini providers slot in beside this file under the
// same interface.

import { estimateCostUsd } from './pricing.ts';
import type {
  AiProvider,
  CallObservability,
  ProviderMessage,
  ProviderName,
  ProviderRequest,
  ProviderResult,
  ProviderStreamEvent,
  ProviderTool,
} from './types.ts';

const ANTHROPIC_URL = 'https://api.anthropic.com/v1/messages';

export class ClaudeProvider implements AiProvider {
  readonly name: ProviderName = 'anthropic';

  async complete(req: ProviderRequest, model: string): Promise<ProviderResult> {
    const apiKey = Deno.env.get('ANTHROPIC_API_KEY');
    if (!apiKey) throw new Error('ANTHROPIC_API_KEY is not set');

    const body = this._buildBody(req, model, false);
    const started = Date.now();
    const res = await fetch(ANTHROPIC_URL, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify(body),
    });

    if (!res.ok) {
      const err = await res.text();
      throw new Error(`Anthropic ${res.status}: ${err}`);
    }

    const data = await res.json();
    const latencyMs = Date.now() - started;

    const blocks: Array<Record<string, unknown>> = data.content ?? [];
    const text = blocks
      .filter((b) => b.type === 'text')
      .map((b) => b.text as string)
      .join('\n');
    const toolBlock = blocks.find((b) => b.type === 'tool_use');
    const toolUse = toolBlock
      ? {
          name: toolBlock.name as string,
          input: toolBlock.input as Record<string, unknown>,
        }
      : null;

    const inputTokens = (data.usage?.input_tokens as number) ?? 0;
    const outputTokens = (data.usage?.output_tokens as number) ?? 0;
    const cacheReadTokens =
      (data.usage?.cache_read_input_tokens as number) ?? 0;

    return {
      text,
      toolUse,
      providerUsed: this.name,
      modelUsed: model,
      inputTokens,
      outputTokens,
      cacheReadTokens,
      latencyMs,
      estimatedCostUsd: estimateCostUsd(
        model,
        inputTokens,
        outputTokens,
        cacheReadTokens,
      ),
    };
  }

  async *stream(
    req: ProviderRequest,
    model: string,
  ): AsyncGenerator<ProviderStreamEvent> {
    const apiKey = Deno.env.get('ANTHROPIC_API_KEY');
    if (!apiKey) {
      yield {
        kind: 'error',
        message: 'ANTHROPIC_API_KEY is not set',
      };
      return;
    }

    const body = this._buildBody(req, model, true);
    const started = Date.now();
    const res = await fetch(ANTHROPIC_URL, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify(body),
    });

    if (!res.ok || !res.body) {
      const errBody = res.body ? await res.text() : `HTTP ${res.status}`;
      yield { kind: 'error', message: `Anthropic ${res.status}: ${errBody}` };
      return;
    }

    const decoder = new TextDecoder();
    const reader = res.body.getReader();
    let buffer = '';

    let inputTokens = 0;
    let outputTokens = 0;
    let cacheReadTokens = 0;

    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });

        let sep: number;
        while ((sep = buffer.indexOf('\n\n')) !== -1) {
          const block = buffer.slice(0, sep);
          buffer = buffer.slice(sep + 2);
          for (const line of block.split('\n')) {
            if (!line.startsWith('data: ')) continue;
            const payload = line.slice(6).trim();
            if (!payload || payload === '[DONE]') continue;
            let evt: Record<string, unknown>;
            try {
              evt = JSON.parse(payload);
            } catch {
              continue;
            }
            const type = evt.type as string;
            if (type === 'content_block_delta') {
              const delta = (evt.delta ?? {}) as Record<string, unknown>;
              if (
                delta.type === 'text_delta' &&
                typeof delta.text === 'string'
              ) {
                yield { kind: 'text', delta: delta.text };
              }
            } else if (type === 'message_start') {
              const usage =
                ((evt.message as Record<string, unknown>)?.usage ?? {}) as Record<
                  string,
                  unknown
                >;
              inputTokens = (usage.input_tokens as number) ?? 0;
              cacheReadTokens =
                (usage.cache_read_input_tokens as number) ?? 0;
            } else if (type === 'message_delta') {
              const usage = (evt.usage ?? {}) as Record<string, unknown>;
              outputTokens = (usage.output_tokens as number) ?? outputTokens;
            }
          }
        }
      }
    } catch (e) {
      yield { kind: 'error', message: (e as Error).message };
      return;
    } finally {
      try {
        reader.releaseLock();
      } catch {
        // ignore
      }
    }

    const observability: CallObservability = {
      providerUsed: this.name,
      modelUsed: model,
      inputTokens,
      outputTokens,
      cacheReadTokens,
      latencyMs: Date.now() - started,
      estimatedCostUsd: estimateCostUsd(
        model,
        inputTokens,
        outputTokens,
        cacheReadTokens,
      ),
    };
    yield { kind: 'done', observability };
  }

  private _buildBody(
    req: ProviderRequest,
    model: string,
    streaming: boolean,
  ): Record<string, unknown> {
    // System prompt as a plain string — equivalent to the array-with-text-
    // block form but without cache_control. cache_control on a sub-1024-
    // token prompt has been observed to hang on Anthropic's edge in some
    // regions; the simpler string form sidesteps that and we'd want to
    // re-enable caching deliberately once prompts cross the threshold.
    const body: Record<string, unknown> = {
      model,
      max_tokens: req.maxTokens ?? 2048,
      system: req.systemPrompt,
      messages: req.messages.map(this._toAnthropicMessage),
    };
    if (streaming) body.stream = true;
    if (req.tools && req.tools.length > 0) {
      body.tools = req.tools.map((t: ProviderTool) => ({
        name: t.name,
        description: t.description,
        input_schema: t.inputSchema,
      }));
      if (req.forceTool) {
        body.tool_choice = { type: 'tool', name: req.forceTool };
      }
    }
    return body;
  }

  private _toAnthropicMessage(m: ProviderMessage): Record<string, unknown> {
    if (typeof m.content === 'string') {
      return { role: m.role, content: m.content };
    }
    return {
      role: m.role,
      content: m.content.map((b) => {
        switch (b.type) {
          case 'text':
            return { type: 'text', text: b.text };
          case 'image':
            return {
              type: 'image',
              source: {
                type: 'base64',
                media_type: b.mediaType,
                data: b.base64,
              },
            };
          case 'document':
            return {
              type: 'document',
              source: {
                type: 'base64',
                media_type: b.mediaType,
                data: b.base64,
              },
            };
        }
      }),
    };
  }
}
