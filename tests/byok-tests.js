const assert = require('assert');
const https = require('https');
const EventEmitter = require('events');
const { translateAnthropicToOpenAI, createOpenAIToAnthropicTransformer } = require('../src/byok/translator');
const { shouldRouteRequest, isBriefOrSummaryAgent, streamOpenAICompatible, executeAnthropicNative } = require('../src/byok/router');
const { validateAndFetchModels } = require('../src/byok/providers');

console.log('Testing BYOK components...');

// 1. Test isBriefOrSummaryAgent
assert.strictEqual(isBriefOrSummaryAgent('default'), false);
assert.strictEqual(isBriefOrSummaryAgent('clia-brief'), true);
assert.strictEqual(isBriefOrSummaryAgent('clia-brief-sonnet'), true);
assert.strictEqual(isBriefOrSummaryAgent('clia-brief-haiku'), true);
assert.strictEqual(isBriefOrSummaryAgent('clia-brief-luna'), true);
assert.strictEqual(isBriefOrSummaryAgent('mission-summary'), true);
assert.strictEqual(isBriefOrSummaryAgent('desk-greeting'), false);
console.log('✓ isBriefOrSummaryAgent passed');

// 2. Test shouldRouteRequest
const configDisabled = { enabled: false, apiKey: 'sk-123', useForBriefs: false };
const configChatOnly = { enabled: true, apiKey: 'sk-123', useForBriefs: false };
const configWithBriefs = { enabled: true, apiKey: 'sk-123', useForBriefs: true };

assert.strictEqual(shouldRouteRequest('default', configDisabled), false);
assert.strictEqual(shouldRouteRequest('default', configChatOnly), true);
assert.strictEqual(shouldRouteRequest('clia-brief', configChatOnly), false);
assert.strictEqual(shouldRouteRequest('clia-brief', configWithBriefs), true);
console.log('✓ shouldRouteRequest passed');

// 3. Test translateAnthropicToOpenAI
const anthropicReq = {
  model: 'claude-opus-4-6[1m]',
  max_tokens: 4096,
  system: [{ type: 'text', text: 'You are an AI assistant.' }],
  messages: [
    { role: 'user', content: 'What tabs are open?' },
    {
      role: 'assistant',
      content: [
        { type: 'text', text: 'Let me check.' },
        { type: 'tool_use', id: 'call_1', name: 'read_tabs', input: { window: 0 } },
      ],
    },
    {
      role: 'user',
      content: [
        { type: 'tool_result', tool_use_id: 'call_1', content: 'Tab 1: GitHub, Tab 2: Dia' },
      ],
    },
  ],
  tools: [
    {
      name: 'read_tabs',
      description: 'Reads open browser tabs',
      input_schema: {
        type: 'object',
        properties: { window: { type: 'number' } },
      },
    },
  ],
};

const openAIReq = translateAnthropicToOpenAI(anthropicReq, 'gpt-4o');
assert.strictEqual(openAIReq.model, 'gpt-4o');
assert.strictEqual(openAIReq.stream, true);
assert.strictEqual(openAIReq.messages.length, 4);
assert.strictEqual(openAIReq.messages[0].role, 'system');
assert.strictEqual(openAIReq.messages[0].content, 'You are an AI assistant.');
assert.strictEqual(openAIReq.messages[1].role, 'user');
assert.strictEqual(openAIReq.messages[1].content, 'What tabs are open?');
assert.strictEqual(openAIReq.messages[2].role, 'assistant');
assert.strictEqual(openAIReq.messages[2].tool_calls.length, 1);
assert.strictEqual(openAIReq.messages[2].tool_calls[0].id, 'call_1');
assert.strictEqual(openAIReq.messages[2].tool_calls[0].function.name, 'read_tabs');
assert.strictEqual(openAIReq.messages[3].role, 'tool');
assert.strictEqual(openAIReq.messages[3].tool_call_id, 'call_1');
assert.strictEqual(openAIReq.messages[3].content, 'Tab 1: GitHub, Tab 2: Dia');
assert.strictEqual(openAIReq.tools.length, 1);
assert.strictEqual(openAIReq.tools[0].type, 'function');
assert.strictEqual(openAIReq.tools[0].function.name, 'read_tabs');
console.log('✓ translateAnthropicToOpenAI passed');

// 4. Test createOpenAIToAnthropicTransformer for text streaming
const events = [];
const transformer = createOpenAIToAnthropicTransformer({
  model: 'gpt-4o',
  onEvent: (type, data) => events.push({ type, data }),
});

transformer.handleOpenAIChunk({
  choices: [{ delta: { content: 'Hello' }, finish_reason: null }],
});
transformer.handleOpenAIChunk({
  choices: [{ delta: { content: ' world!' }, finish_reason: null }],
});
transformer.handleOpenAIChunk({
  choices: [{ delta: {}, finish_reason: 'stop' }],
});

assert.strictEqual(events[0].type, 'message_start');
assert.strictEqual(events[1].type, 'content_block_start');
assert.strictEqual(events[1].data.content_block.type, 'text');
assert.strictEqual(events[2].type, 'content_block_delta');
assert.strictEqual(events[2].data.delta.text, 'Hello');
assert.strictEqual(events[3].type, 'content_block_delta');
assert.strictEqual(events[3].data.delta.text, ' world!');
assert.strictEqual(events[4].type, 'content_block_stop');
assert.strictEqual(events[5].type, 'message_delta');
assert.strictEqual(events[5].data.delta.stop_reason, 'end_turn');
assert.strictEqual(events[6].type, 'message_stop');
console.log('✓ createOpenAIToAnthropicTransformer text streaming passed');

// 5. Test createOpenAIToAnthropicTransformer for tool streaming
const toolEvents = [];
const toolTransformer = createOpenAIToAnthropicTransformer({
  model: 'gemini-2.5-flash',
  onEvent: (type, data) => toolEvents.push({ type, data }),
});

toolTransformer.handleOpenAIChunk({
  choices: [
    {
      delta: {
        tool_calls: [
          {
            index: 0,
            id: 'call_search',
            type: 'function',
            function: { name: 'search_web', arguments: '{"q":' },
          },
        ],
      },
      finish_reason: null,
    },
  ],
});
toolTransformer.handleOpenAIChunk({
  choices: [
    {
      delta: {
        tool_calls: [
          {
            index: 0,
            function: { arguments: '"dia browser"}' },
          },
        ],
      },
      finish_reason: null,
    },
  ],
});
toolTransformer.handleOpenAIChunk({
  choices: [{ delta: {}, finish_reason: 'tool_calls' }],
});

assert.strictEqual(toolEvents[0].type, 'message_start');
assert.strictEqual(toolEvents[1].type, 'content_block_start');
assert.strictEqual(toolEvents[1].data.content_block.type, 'tool_use');
assert.strictEqual(toolEvents[1].data.content_block.id, 'call_search');
assert.strictEqual(toolEvents[1].data.content_block.name, 'search_web');
assert.strictEqual(toolEvents[2].type, 'content_block_delta');
assert.strictEqual(toolEvents[2].data.delta.partial_json, '{"q":');
assert.strictEqual(toolEvents[3].type, 'content_block_delta');
assert.strictEqual(toolEvents[3].data.delta.partial_json, '"dia browser"}');
assert.strictEqual(toolEvents[4].type, 'content_block_stop');
assert.strictEqual(toolEvents[5].type, 'message_delta');
assert.strictEqual(toolEvents[5].data.delta.stop_reason, 'tool_use');
assert.strictEqual(toolEvents[6].type, 'message_stop');
console.log('✓ createOpenAIToAnthropicTransformer tool call streaming passed');

// 6. Test Reasoning Model Translation (GPT-6.1 Terra)
const reasoningReq = {
  model: 'claude-opus-5-5',
  max_tokens: 8192,
  temperature: 0.7,
  system: 'Think carefully before answering.',
  messages: [{ role: 'user', content: 'Prove P != NP.' }],
};
const translatedReasoning = translateAnthropicToOpenAI(reasoningReq, 'gpt-6.1-terra');
assert.strictEqual(translatedReasoning.model, 'gpt-6.1-terra');
assert.strictEqual(translatedReasoning.messages[0].role, 'developer');
assert.strictEqual(translatedReasoning.messages[0].content, 'Think carefully before answering.');
assert.strictEqual(translatedReasoning.max_completion_tokens, 8192);
assert.strictEqual(translatedReasoning.max_tokens, undefined);
assert.strictEqual(translatedReasoning.temperature, undefined);
assert.deepStrictEqual(translatedReasoning.stream_options, { include_usage: true });
console.log('✓ translateAnthropicToOpenAI reasoning model (GPT-6.1 Terra) passed');

// 7. Test transformer finish() deduplication
const finishEvents = [];
const dedupeTransformer = createOpenAIToAnthropicTransformer({
  model: 'gpt-6.1-terra',
  onEvent: (type, data) => finishEvents.push({ type, data }),
});
dedupeTransformer.handleOpenAIChunk({
  choices: [{ delta: { content: 'Done' }, finish_reason: 'stop' }],
});
const countStopBefore = finishEvents.filter((e) => e.type === 'message_stop').length;
dedupeTransformer.finish();
const countStopAfter = finishEvents.filter((e) => e.type === 'message_stop').length;
assert.strictEqual(countStopBefore, 1);
assert.strictEqual(countStopAfter, 1, 'finish() should not emit duplicate message_stop');
console.log('✓ transformer finish() deduplication passed');

// 8. Test Free Models on OpenRouter (openrouter/free)
const freeModelReq = {
  model: 'claude-sonnet-5-5',
  max_tokens: 4096,
  messages: [{ role: 'user', content: 'hi' }],
  tools: [{ name: 'read_tabs', description: 'test', input_schema: {} }],
};
const translatedFree = translateAnthropicToOpenAI(freeModelReq, 'openrouter/free', 'openrouter');
assert.strictEqual(translatedFree.model, 'openrouter/free');
assert.strictEqual(translatedFree.tools, undefined, 'Free models should not have tools attached');
assert.strictEqual(translatedFree.stream_options, undefined, 'OpenRouter models should not inject stream_options');
console.log('✓ openrouter/free tool stripping and stream_options check passed');

// 9. Test getModelThinkingCapabilities
const { getModelThinkingCapabilities } = require('../src/byok/providers');
const sonnet55Caps = getModelThinkingCapabilities('anthropic', 'claude-sonnet-5-5');
assert.strictEqual(sonnet55Caps.supported, true);
assert.ok(sonnet55Caps.levels.some((l) => l.id === 'low' && l.budgetTokens === 2048));
assert.ok(sonnet55Caps.levels.some((l) => l.id === 'medium' && l.budgetTokens === 8192));
assert.ok(sonnet55Caps.levels.some((l) => l.id === 'high' && l.budgetTokens === 16384));

const sonnet35Caps = getModelThinkingCapabilities('anthropic', 'claude-3-5-sonnet-20241022');
assert.strictEqual(sonnet35Caps.supported, false);
assert.strictEqual(sonnet35Caps.levels.length, 0);

const geminiCaps = getModelThinkingCapabilities('google', 'gemini-3.8-flash');
assert.strictEqual(geminiCaps.supported, true);
assert.ok(geminiCaps.levels.some((l) => l.id === 'low' && l.budgetTokens === 1024));

const gpt4oCaps = getModelThinkingCapabilities('openai', 'gpt-4o');
assert.strictEqual(gpt4oCaps.supported, false);

const gpt6Caps = getModelThinkingCapabilities('openai', 'gpt-6.1-terra');
assert.strictEqual(gpt6Caps.supported, true);
assert.ok(gpt6Caps.levels.some((l) => l.id === 'low' && l.reasoningEffort === 'low'));
console.log('✓ getModelThinkingCapabilities dynamic checking passed');

// 10. Test transformer.isStopped()
const stopTransformer = createOpenAIToAnthropicTransformer({
  model: 'gemini-3.8-flash',
  onEvent: () => {},
});
assert.strictEqual(stopTransformer.isStopped(), false);
stopTransformer.handleOpenAIChunk({
  choices: [{ delta: { content: 'hello' } }],
});
assert.strictEqual(stopTransformer.isStopped(), false);
stopTransformer.handleOpenAIChunk({
  choices: [{ delta: {}, finish_reason: 'stop' }],
});
assert.strictEqual(stopTransformer.isStopped(), true);
console.log('✓ transformer.isStopped() passed');

// 11. Test streamOpenAICompatible fast finish on [DONE] without waiting for socket end
(async () => {
  const origRequest = https.request;
  try {
    let reqDestroyed = false;
    let resDestroyed = false;
    https.request = (opts, cb) => {
      const mockReq = new EventEmitter();
      mockReq.write = () => {};
      mockReq.end = () => {
        const mockRes = new EventEmitter();
        mockRes.statusCode = 200;
        mockRes.setEncoding = () => {};
        mockRes.destroy = () => { resDestroyed = true; };
        cb(mockRes);

        mockRes.emit('data', 'data: {"choices":[{"delta":{"content":"Hi"}}]}\n\n');
        mockRes.emit('data', 'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n');
        mockRes.emit('data', 'data: [DONE]\n\n');
        // NOTE: Intentionally do not emit 'end' to simulate keep-alive connection!
      };
      mockReq.destroy = () => { reqDestroyed = true; };
      return mockReq;
    };

    const chunks = [];
    await streamOpenAICompatible(
      'https://example.com/v1/chat/completions',
      {},
      { model: 'gemini-3.8-flash' },
      'gemini-3.8-flash',
      (chunk) => chunks.push(chunk)
    );

    assert.ok(chunks.some((c) => c.done === true), 'Stream should finish with done: true immediately upon [DONE]');
    assert.strictEqual(reqDestroyed, true, 'Request should be destroyed upon stream finish');
    assert.strictEqual(resDestroyed, true, 'Response should be destroyed upon stream finish');
    console.log('✓ streamOpenAICompatible fast finish on [DONE] passed');
  } finally {
    https.request = origRequest;
  }

  // 12. Test executeAnthropicNative fast finish on message_stop without waiting for socket end
  const origRequest2 = https.request;
  try {
    let reqDestroyed = false;
    let resDestroyed = false;
    https.request = (opts, cb) => {
      const mockReq = new EventEmitter();
      mockReq.write = () => {};
      mockReq.end = () => {
        const mockRes = new EventEmitter();
        mockRes.statusCode = 200;
        mockRes.setEncoding = () => {};
        mockRes.destroy = () => { resDestroyed = true; };
        cb(mockRes);

        mockRes.emit('data', 'event: message_start\ndata: {"type":"message_start"}\n\n');
        mockRes.emit('data', 'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}\n\n');
        mockRes.emit('data', 'event: message_stop\ndata: {"type":"message_stop"}\n\n');
        // Intentionally no 'end' event emitted
      };
      mockReq.destroy = () => { reqDestroyed = true; };
      return mockReq;
    };

    const chunks = [];
    await executeAnthropicNative(
      { messages: [] },
      'test-key',
      'claude-sonnet-5-5',
      null,
      (chunk) => chunks.push(chunk)
    );

    assert.ok(chunks.some((c) => c.done === true), 'Stream should finish with done: true immediately upon message_stop');
    assert.strictEqual(reqDestroyed, true, 'Request should be destroyed upon message_stop');
    assert.strictEqual(resDestroyed, true, 'Response should be destroyed upon message_stop');
    console.log('✓ executeAnthropicNative fast finish on message_stop passed');
  } finally {
    https.request = origRequest2;
  }

  // 13. Test fallback timeout if terminal event is missing
  const origRequest3 = https.request;
  try {
    https.request = (opts, cb) => {
      const mockReq = new EventEmitter();
      mockReq.write = () => {};
      mockReq.end = () => {
        const mockRes = new EventEmitter();
        mockRes.statusCode = 200;
        mockRes.setEncoding = () => {};
        mockRes.destroy = () => {};
        cb(mockRes);

        mockRes.emit('data', 'data: {"choices":[{"delta":{"content":"Hi"}}]}\n\n');
        mockRes.emit('data', 'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n');
        // No [DONE] emitted!
      };
      mockReq.destroy = () => {};
      return mockReq;
    };

    const chunks = [];
    await streamOpenAICompatible(
      'https://example.com/v1/chat/completions',
      {},
      { model: 'gemini-3.8-flash' },
      'gemini-3.8-flash',
      (chunk) => chunks.push(chunk)
    );

    assert.ok(chunks.some((c) => c.done === true), 'Stream should finish via fallback timer');
    console.log('✓ fallback timer on missing [DONE] passed');
  } finally {
    https.request = origRequest3;
  }

  console.log('All BYOK unit tests passed!');
})();
