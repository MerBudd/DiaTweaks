/**
 * DiaTweaks Protocol Translator
 * Translates between Anthropic Messages API (used by Claude Code / Dia)
 * and OpenAI Chat Completions API (used by OpenAI, Google Gemini, OpenRouter).
 */

function translateAnthropicToOpenAI(anthropicReq, targetModel, provider = 'openai') {
  const isReasoningModel =
    /^o[1-9]/i.test(targetModel) ||
    targetModel.includes('thinking') ||
    targetModel.includes('reasoner') ||
    targetModel.includes('r1') ||
    targetModel.includes('terra') ||
    targetModel.includes('sol');

  const openAIMessages = [];

  // 1. Process System Prompt (Reasoning models prefer/require role: 'developer')
  if (anthropicReq.system) {
    let systemText = '';
    if (typeof anthropicReq.system === 'string') {
      systemText = anthropicReq.system;
    } else if (Array.isArray(anthropicReq.system)) {
      systemText = anthropicReq.system
        .map((part) => (typeof part === 'string' ? part : part.text || ''))
        .filter(Boolean)
        .join('\n\n');
    }
    if (systemText.trim()) {
      openAIMessages.push({
        role: isReasoningModel ? 'developer' : 'system',
        content: systemText,
      });
    }
  }

  // 2. Process Messages
  const messages = anthropicReq.messages || [];
  for (const msg of messages) {
    const role = msg.role === 'assistant' ? 'assistant' : 'user';

    if (typeof msg.content === 'string') {
      openAIMessages.push({
        role,
        content: msg.content,
      });
      continue;
    }

    if (!Array.isArray(msg.content)) {
      continue;
    }

    // Deconstruct complex content blocks
    const textParts = [];
    const toolCalls = [];
    const toolResults = [];

    for (const part of msg.content) {
      if (!part) continue;
      if (part.type === 'text') {
        textParts.push(part.text || '');
      } else if (part.type === 'tool_use') {
        toolCalls.push({
          id: part.id || `call_${Math.random().toString(36).slice(2, 10)}`,
          type: 'function',
          function: {
            name: part.name,
            arguments: typeof part.input === 'string' ? part.input : JSON.stringify(part.input || {}),
          },
        });
      } else if (part.type === 'tool_result') {
        let resultStr = '';
        if (typeof part.content === 'string') {
          resultStr = part.content;
        } else if (Array.isArray(part.content)) {
          resultStr = part.content
            .map((c) => (typeof c === 'string' ? c : c.text || JSON.stringify(c)))
            .join('\n');
        } else if (part.content !== undefined) {
          resultStr = JSON.stringify(part.content);
        }
        toolResults.push({
          role: 'tool',
          tool_call_id: part.tool_use_id,
          content: resultStr || 'Success',
        });
      }
    }

    if (role === 'assistant') {
      const assistantMsg = {
        role: 'assistant',
        content: textParts.join('\n') || (toolCalls.length ? null : ''),
      };
      if (toolCalls.length > 0) {
        assistantMsg.tool_calls = toolCalls;
      }
      openAIMessages.push(assistantMsg);
    } else {
      // User message
      if (toolResults.length > 0) {
        // In OpenAI format, tool results must be separate role: 'tool' messages
        for (const tr of toolResults) {
          openAIMessages.push(tr);
        }
      }
      if (textParts.length > 0) {
        openAIMessages.push({
          role: 'user',
          content: textParts.join('\n'),
        });
      }
    }
  }

  // 3. Process Tools
  // Note: OpenRouter free models (openrouter/free or *:free) do NOT support tool calling.
  // Omitting tools for free models allows them to work as conversational assistants.
  const isFreeModel = targetModel === 'openrouter/free' || targetModel.includes(':free');
  let openAITools = undefined;
  if (Array.isArray(anthropicReq.tools) && anthropicReq.tools.length > 0 && !isFreeModel) {
    openAITools = anthropicReq.tools.map((t) => ({
      type: 'function',
      function: {
        name: t.name,
        description: t.description || '',
        parameters: t.input_schema || { type: 'object', properties: {} },
      },
    }));
  }

  // 4. Assemble OpenAI Payload
  const payload = {
    model: targetModel,
    messages: openAIMessages,
    stream: true,
  };

  // Only pass stream_options for providers that support it (OpenAI and Google Gemini).
  // Many third-party engines routed by OpenRouter reject stream_options with HTTP 400.
  if (provider === 'openai' || provider === 'google') {
    payload.stream_options = { include_usage: true };
  }

  if (openAITools && openAITools.length > 0) {
    payload.tools = openAITools;
  }

  const maxTokens = anthropicReq.max_tokens || 4096;
  if (isReasoningModel) {
    payload.max_completion_tokens = maxTokens;
  } else {
    payload.max_tokens = maxTokens;
  }

  if (anthropicReq.temperature !== undefined && !isReasoningModel) {
    payload.temperature = anthropicReq.temperature;
  }

  return payload;
}

/**
 * Creates a stream transformer that converts OpenAI SSE lines into Anthropic SSE events.
 */
function createOpenAIToAnthropicTransformer({ model, onEvent }) {
  let messageStarted = false;
  let messageStopped = false;
  let textBlockIndex = null;
  let toolBlockIndexMap = new Map(); // toolCallIndex -> blockIndex
  let nextBlockIndex = 0;
  let totalInputTokens = 10;
  let totalOutputTokens = 0;
  const msgId = `msg_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;

  function ensureMessageStart() {
    if (!messageStarted) {
      messageStarted = true;
      onEvent('message_start', {
        type: 'message_start',
        message: {
          id: msgId,
          type: 'message',
          role: 'assistant',
          content: [],
          model: model,
          usage: {
            input_tokens: totalInputTokens,
            output_tokens: 0,
          },
        },
      });
    }
  }

  function handleOpenAIChunk(chunkJson) {
    ensureMessageStart();

    if (chunkJson.usage) {
      if (chunkJson.usage.prompt_tokens) totalInputTokens = chunkJson.usage.prompt_tokens;
      if (chunkJson.usage.completion_tokens) totalOutputTokens = chunkJson.usage.completion_tokens;
    }

    const choices = chunkJson.choices || [];
    if (choices.length === 0) return;

    const choice = choices[0];
    const delta = choice.delta || {};

    // 1. Text Delta
    if (delta.content) {
      if (textBlockIndex === null) {
        textBlockIndex = nextBlockIndex++;
        onEvent('content_block_start', {
          type: 'content_block_start',
          index: textBlockIndex,
          content_block: {
            type: 'text',
            text: '',
          },
        });
      }
      totalOutputTokens++;
      onEvent('content_block_delta', {
        type: 'content_block_delta',
        index: textBlockIndex,
        delta: {
          type: 'text_delta',
          text: delta.content,
        },
      });
    }

    // 2. Tool Calls Delta
    if (Array.isArray(delta.tool_calls)) {
      // Close text block if one was open
      if (textBlockIndex !== null) {
        onEvent('content_block_stop', {
          type: 'content_block_stop',
          index: textBlockIndex,
        });
        textBlockIndex = null;
      }

      for (const tc of delta.tool_calls) {
        const tcIndex = tc.index ?? 0;
        let blockIndex = toolBlockIndexMap.get(tcIndex);

        if (blockIndex === undefined) {
          blockIndex = nextBlockIndex++;
          toolBlockIndexMap.set(tcIndex, blockIndex);
          const toolId = tc.id || `toolu_${Date.now()}_${tcIndex}`;
          const toolName = tc.function?.name || '';

          onEvent('content_block_start', {
            type: 'content_block_start',
            index: blockIndex,
            content_block: {
              type: 'tool_use',
              id: toolId,
              name: toolName,
              input: {},
            },
          });
        }

        if (tc.function?.arguments) {
          totalOutputTokens++;
          onEvent('content_block_delta', {
            type: 'content_block_delta',
            index: blockIndex,
            delta: {
              type: 'input_json_delta',
              partial_json: tc.function.arguments,
            },
          });
        }
      }
    }

    // 3. Finish Reason
    if (choice.finish_reason) {
      // Close active text block
      if (textBlockIndex !== null) {
        onEvent('content_block_stop', {
          type: 'content_block_stop',
          index: textBlockIndex,
        });
        textBlockIndex = null;
      }
      // Close any open tool blocks
      for (const [, bIdx] of toolBlockIndexMap) {
        onEvent('content_block_stop', {
          type: 'content_block_stop',
          index: bIdx,
        });
      }
      toolBlockIndexMap.clear();

      let stopReason = 'end_turn';
      if (choice.finish_reason === 'tool_calls' || choice.finish_reason === 'function_call') {
        stopReason = 'tool_use';
      } else if (choice.finish_reason === 'length') {
        stopReason = 'max_tokens';
      }

      messageStopped = true;
      onEvent('message_delta', {
        type: 'message_delta',
        delta: {
          stop_reason: stopReason,
          stop_sequence: null,
        },
        usage: {
          output_tokens: totalOutputTokens || 1,
        },
      });

      onEvent('message_stop', {
        type: 'message_stop',
      });
    }
  }

  function finish() {
    if (messageStopped) return;
    messageStopped = true;

    ensureMessageStart();
    if (textBlockIndex !== null) {
      onEvent('content_block_stop', {
        type: 'content_block_stop',
        index: textBlockIndex,
      });
      textBlockIndex = null;
    }
    for (const [, bIdx] of toolBlockIndexMap) {
      onEvent('content_block_stop', {
        type: 'content_block_stop',
        index: bIdx,
      });
    }
    toolBlockIndexMap.clear();

    onEvent('message_delta', {
      type: 'message_delta',
      delta: {
        stop_reason: 'end_turn',
        stop_sequence: null,
      },
      usage: {
        output_tokens: totalOutputTokens || 1,
      },
    });

    onEvent('message_stop', {
      type: 'message_stop',
    });
  }

  return {
    handleOpenAIChunk,
    finish,
    isStopped: () => messageStopped,
  };
}

module.exports = {
  translateAnthropicToOpenAI,
  createOpenAIToAnthropicTransformer,
};
