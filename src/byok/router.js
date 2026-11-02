/**
 * DiaTweaks BYOK Request Router
 * Intercepts LLM_REQUEST payloads from Dia's agent harness and routes them
 * to the user's chosen BYOK provider with custom API keys and models.
 */

const fs = require('fs');
const path = require('path');
const https = require('https');
const os = require('os');
const { URL } = require('url');
const { translateAnthropicToOpenAI, createOpenAIToAnthropicTransformer } = require('./translator');

function getConfigPath() {
  const home = os.homedir();
  return path.join(home, 'Library/Application Support/DiaPatches/byok.json');
}

function loadConfig() {
  try {
    const p = getConfigPath();
    if (fs.existsSync(p)) {
      const content = fs.readFileSync(p, 'utf8');
      return JSON.parse(content);
    }
  } catch (err) {
    // ignore
  }
  return {
    enabled: false,
    provider: 'anthropic',
    apiKey: '',
    model: '',
    useForBriefs: false,
  };
}

function isBriefOrSummaryAgent(agentSpec) {
  if (!agentSpec) return false;
  const s = agentSpec.toLowerCase();
  return s.includes('brief') || s.includes('summary') || s.startsWith('clia-brief');
}

/**
 * Checks if a given request should be routed to BYOK.
 */
function shouldRouteRequest(agentSpec, config = null) {
  const cfg = config || loadConfig();
  if (!cfg.enabled || !cfg.apiKey) {
    return false;
  }

  // If model picker explicitly set the active model to Dia's default included model
  if (cfg.activeIsDiaDefault || cfg.activeModel === 'claude-opus-4-6-dia' || cfg.activeModel === 'dia-default') {
    return false;
  }

  const isBrief = isBriefOrSummaryAgent(agentSpec);
  if (isBrief) {
    return !!cfg.useForBriefs;
  }

  return true;
}

/**
 * Executes a streaming LLM request using BYOK.
 * Calls onChunk({ data, done, statusCode, headers })
 */
async function executeByokRequest(llmRequestPayload, agentSpec, onChunk) {
  const config = loadConfig();
  const provider = config.provider || 'anthropic';
  const apiKey = config.apiKey;
  const model = config.activeModel || config.model;
  const thinking = config.activeThinking || (config.activeThinkingLevel ? { level: config.activeThinkingLevel } : null);

  if (!apiKey) {
    throw new Error('BYOK is enabled but no API key is configured');
  }

  let bodyObj = null;
  try {
    bodyObj = typeof llmRequestPayload.body === 'string'
      ? JSON.parse(llmRequestPayload.body)
      : llmRequestPayload.body;
  } catch (e) {
    throw new Error(`Invalid LLM request body JSON: ${e.message}`);
  }

  // Handle countTokens endpoint
  if (llmRequestPayload.endpoint === 'countTokens' || llmRequestPayload.endpoint === 'count-tokens') {
    return handleCountTokens(bodyObj, onChunk);
  }

  if (provider === 'anthropic') {
    return await executeAnthropicNative(bodyObj, apiKey, model, thinking, onChunk);
  } else if (provider === 'google') {
    return await executeGoogleOpenAI(bodyObj, apiKey, model, thinking, onChunk);
  } else if (provider === 'openai') {
    return await executeOpenAI(bodyObj, apiKey, model, thinking, onChunk);
  } else if (provider === 'openrouter') {
    return await executeOpenRouter(bodyObj, apiKey, model, thinking, onChunk);
  } else {
    throw new Error(`Unsupported BYOK provider: ${provider}`);
  }
}

function handleCountTokens(bodyObj, onChunk) {
  // Approximate or count tokens
  let tokenCount = 100;
  try {
    const text = JSON.stringify(bodyObj);
    tokenCount = Math.max(10, Math.ceil(text.length / 4));
  } catch {}
  const resBody = JSON.stringify({ input_tokens: tokenCount });
  onChunk({
    statusCode: 200,
    headers: { 'content-type': 'application/json' },
    data: resBody,
    done: true,
  });
}

function formatUpstreamError(statusCode, errorBody, model) {
  let message = `Upstream error HTTP ${statusCode}`;
  try {
    const json = JSON.parse(errorBody);
    if (json.error) {
      if (typeof json.error === 'string') {
        message = json.error;
      } else if (json.error.message) {
        message = json.error.message;
      }
    } else if (json.message) {
      message = json.message;
    }
  } catch {}

  let advice = '';
  const lower = message.toLowerCase();
  if (
    lower.includes('spend cap') ||
    lower.includes('spending cap') ||
    lower.includes('quota') ||
    lower.includes('resource_exhausted')
  ) {
    advice =
      '\n\n💡 **Troubleshooting Tip**: Your Google Cloud / Google AI Studio project has hit its configured spend cap or quota metric. Go to [Google AI Studio](https://aistudio.google.com) > **Spend** tab to increase your monthly spend cap, or link a billing account with sufficient quota.';
  } else if (
    lower.includes('tool') ||
    lower.includes('function') ||
    statusCode === 404
  ) {
    advice = `\n\n💡 **Troubleshooting Tip**: The selected model (\`${model}\`) does not support function/tool calling required by browser agents. Try switching to a tool-capable model (such as Claude Sonnet 5.5, GPT-6.1 Terra, or Gemini 3.8 Flash).`;
  }

  return `⚠️ **BYOK Provider Error (${statusCode})**\n\n${message}${advice}`;
}

function streamErrorMessage(onChunk, model, statusCode, errorBody) {
  const errText = formatUpstreamError(statusCode, errorBody, model);
  console.error(`[DiaTweaks BYOK Error] ${statusCode}: ${errorBody}`);

  const msgId = `msg_err_${Date.now()}`;
  const sseText =
    `event: message_start\ndata: ${JSON.stringify({ type: 'message_start', message: { id: msgId, type: 'message', role: 'assistant', content: [], model, usage: { input_tokens: 1, output_tokens: 1 } } })}\n\n` +
    `event: content_block_start\ndata: ${JSON.stringify({ type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } })}\n\n` +
    `event: content_block_delta\ndata: ${JSON.stringify({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: errText } })}\n\n` +
    `event: content_block_stop\ndata: ${JSON.stringify({ type: 'content_block_stop', index: 0 })}\n\n` +
    `event: message_delta\ndata: ${JSON.stringify({ type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 20 } })}\n\n` +
    `event: message_stop\ndata: ${JSON.stringify({ type: 'message_stop' })}\n\n`;

  // Return status 200 with the formatted message so Dia renders it in chat instead of throwing a generic crash screen
  onChunk({
    statusCode: 200,
    headers: { 'content-type': 'text/event-stream' },
    data: sseText,
    done: true,
  });
}

function executeAnthropicNative(bodyObj, apiKey, targetModel, thinking, onChunk) {
  const model = targetModel || 'claude-sonnet-5-5';
  return new Promise((resolve, reject) => {
    const reqBody = { ...bodyObj };
    if (targetModel) {
      reqBody.model = targetModel;
    }

    if (thinking && thinking.level) {
      if (thinking.level === 'off') {
        reqBody.thinking = { type: 'disabled' };
      } else if (thinking.level === 'adaptive') {
        reqBody.thinking = { type: 'adaptive' };
      } else {
        const budget = thinking.budgetTokens || (
          thinking.level === 'low' ? 2048 :
          thinking.level === 'high' ? 16384 :
          thinking.level === 'max' ? 64000 : 8192
        );
        reqBody.thinking = {
          type: 'enabled',
          budget_tokens: budget,
        };
        if (reqBody.max_tokens && reqBody.max_tokens <= budget) {
          reqBody.max_tokens = budget + 4096;
        }
      }
    }

    reqBody.stream = true;

    const postData = JSON.stringify(reqBody);
    const urlObj = new URL('https://api.anthropic.com/v1/messages');

    let headerSent = false;
    let completed = false;
    let sseBuffer = '';
    let stopTimer = null;
    let res = null;

    const finishStream = () => {
      if (completed) return;
      completed = true;
      if (stopTimer) {
        clearTimeout(stopTimer);
        stopTimer = null;
      }
      onChunk({
        done: true,
      });
      try {
        if (res) res.destroy();
      } catch {}
      try {
        req.destroy();
      } catch {}
      resolve();
    };

    const req = https.request(
      {
        hostname: urlObj.hostname,
        port: 443,
        path: urlObj.pathname,
        method: 'POST',
        headers: {
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
          'content-type': 'application/json',
          'content-length': Buffer.byteLength(postData),
        },
      },
      (response) => {
        res = response;
        if (res.statusCode !== 200) {
          let errorBody = '';
          res.on('data', (d) => (errorBody += d));
          res.on('end', () => {
            streamErrorMessage(onChunk, model, res.statusCode, errorBody);
            resolve();
          });
          return;
        }

        res.setEncoding('utf8');
        res.on('data', (chunk) => {
          if (completed) return;

          if (!headerSent) {
            headerSent = true;
            onChunk({
              statusCode: res.statusCode,
              headers: { 'content-type': 'text/event-stream' },
              data: chunk,
              done: false,
            });
          } else {
            onChunk({
              data: chunk,
              done: false,
            });
          }

          sseBuffer += chunk;
          const lines = sseBuffer.split('\n');
          sseBuffer = lines.pop() || '';

          for (const line of lines) {
            const trimmed = line.trim();
            if (trimmed.startsWith('data:')) {
              try {
                const payloadStr = trimmed.slice(trimmed.indexOf(':') + 1).trim();
                const data = JSON.parse(payloadStr);
                if (data.type === 'message_stop' || data.type === 'error') {
                  finishStream();
                  return;
                }
                if (data.type === 'message_delta' && !stopTimer) {
                  stopTimer = setTimeout(() => {
                    finishStream();
                  }, 500);
                }
              } catch (e) {
                // ignore
              }
            }
          }
        });

        res.on('end', () => {
          finishStream();
        });

        res.on('error', (err) => {
          if (completed) return;
          reject(err);
        });
      }
    );

    req.on('error', (err) => {
      if (completed) return;
      reject(err);
    });
    req.write(postData);
    req.end();
  });
}

function executeGoogleOpenAI(bodyObj, apiKey, targetModel, thinking, onChunk) {
  const model = targetModel || 'gemini-3.8-flash';
  const openAIPayload = translateAnthropicToOpenAI(bodyObj, model, 'google');
  if (thinking && thinking.level && thinking.level !== 'off') {
    openAIPayload.reasoning_effort = thinking.level;
  }
  const url = 'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions';
  const headers = {
    Authorization: `Bearer ${apiKey}`,
    'Content-Type': 'application/json',
  };

  return streamOpenAICompatible(url, headers, openAIPayload, model, onChunk);
}

function executeOpenAI(bodyObj, apiKey, targetModel, thinking, onChunk) {
  const model = targetModel || 'gpt-6.1-terra';
  const openAIPayload = translateAnthropicToOpenAI(bodyObj, model, 'openai');
  if (thinking && thinking.level && thinking.level !== 'off') {
    openAIPayload.reasoning_effort = thinking.level;
  }
  const url = 'https://api.openai.com/v1/chat/completions';
  const headers = {
    Authorization: `Bearer ${apiKey}`,
    'Content-Type': 'application/json',
  };

  return streamOpenAICompatible(url, headers, openAIPayload, model, onChunk);
}

function executeOpenRouter(bodyObj, apiKey, targetModel, thinking, onChunk) {
  const model = targetModel || 'anthropic/claude-sonnet-5-5';
  const openAIPayload = translateAnthropicToOpenAI(bodyObj, model, 'openrouter');
  if (thinking && thinking.level && thinking.level !== 'off') {
    openAIPayload.reasoning_effort = thinking.level;
  }
  const url = 'https://openrouter.ai/api/v1/chat/completions';
  const headers = {
    Authorization: `Bearer ${apiKey}`,
    'Content-Type': 'application/json',
    'HTTP-Referer': 'https://diabrowser.com',
    'X-Title': 'Dia BYOK',
  };

  return streamOpenAICompatible(url, headers, openAIPayload, model, onChunk);
}

function streamOpenAICompatible(targetUrl, headers, payload, model, onChunk) {
  return new Promise((resolve, reject) => {
    const postData = JSON.stringify(payload);
    const urlObj = new URL(targetUrl);

    let headerSent = false;
    let sseBuffer = '';
    let completed = false;
    let doneTimer = null;
    let res = null;

    const sendAnthropicEvent = (eventType, dataObj) => {
      const sseText = `event: ${eventType}\ndata: ${JSON.stringify(dataObj)}\n\n`;
      if (!headerSent) {
        headerSent = true;
        onChunk({
          statusCode: 200,
          headers: { 'content-type': 'text/event-stream' },
          data: sseText,
          done: false,
        });
      } else {
        onChunk({
          data: sseText,
          done: false,
        });
      }
    };

    const transformer = createOpenAIToAnthropicTransformer({
      model,
      onEvent: sendAnthropicEvent,
    });

    const finishStream = () => {
      if (completed) return;
      completed = true;
      if (doneTimer) {
        clearTimeout(doneTimer);
        doneTimer = null;
      }
      transformer.finish();
      onChunk({
        done: true,
      });
      try {
        if (res) res.destroy();
      } catch {}
      try {
        req.destroy();
      } catch {}
      resolve();
    };

    const req = https.request(
      {
        hostname: urlObj.hostname,
        port: 443,
        path: urlObj.pathname + urlObj.search,
        method: 'POST',
        headers: {
          ...headers,
          'content-length': Buffer.byteLength(postData),
        },
      },
      (response) => {
        res = response;
        if (res.statusCode !== 200) {
          let errorBody = '';
          res.on('data', (d) => (errorBody += d));
          res.on('end', () => {
            streamErrorMessage(onChunk, model, res.statusCode, errorBody);
            resolve();
          });
          return;
        }

        res.setEncoding('utf8');
        res.on('data', (chunk) => {
          if (completed) return;

          sseBuffer += chunk;
          const lines = sseBuffer.split('\n');
          sseBuffer = lines.pop() || ''; // keep trailing incomplete line

          for (const line of lines) {
            const trimmed = line.trim();
            if (!trimmed || trimmed.startsWith(':')) continue;
            if (trimmed === 'data: [DONE]' || trimmed === 'data:[DONE]') {
              finishStream();
              return;
            }
            if (trimmed.startsWith('data:')) {
              try {
                const payloadStr = trimmed.slice(trimmed.indexOf(':') + 1).trim();
                const json = JSON.parse(payloadStr);
                transformer.handleOpenAIChunk(json);
                if (transformer.isStopped && transformer.isStopped() && !doneTimer) {
                  doneTimer = setTimeout(() => {
                    finishStream();
                  }, 500);
                }
              } catch (e) {
                // ignore malformed delta
              }
            }
          }
        });

        res.on('end', () => {
          finishStream();
        });

        res.on('error', (err) => {
          if (completed) return;
          reject(err);
        });
      }
    );

    req.on('error', (err) => {
      if (completed) return;
      reject(err);
    });

    req.write(postData);
    req.end();
  });
}

module.exports = {
  loadConfig,
  getConfigPath,
  shouldRouteRequest,
  executeByokRequest,
  isBriefOrSummaryAgent,
  executeAnthropicNative,
  streamOpenAICompatible,
};
