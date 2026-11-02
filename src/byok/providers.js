/**
 * DiaTweaks BYOK (Bring Your Own Key) Provider Integrations
 * Supports: Google Gemini, Anthropic, OpenAI, OpenRouter
 */

const https = require('https');
const { URL } = require('url');

const PROVIDERS = {
  google: {
    id: 'google',
    name: 'Google Gemini',
    defaultModel: 'gemini-3.8-flash',
    requiresTranslation: true,
  },
  anthropic: {
    id: 'anthropic',
    name: 'Anthropic',
    defaultModel: 'claude-sonnet-5-5',
    requiresTranslation: false, // native Anthropic Messages API
  },
  openai: {
    id: 'openai',
    name: 'OpenAI',
    defaultModel: 'gpt-6.1-terra',
    requiresTranslation: true,
  },
  openrouter: {
    id: 'openrouter',
    name: 'OpenRouter',
    defaultModel: 'anthropic/claude-sonnet-5-5',
    requiresTranslation: true,
  },
};

function getModelThinkingCapabilities(providerId, modelId, rawModelMeta) {
  if (!modelId) return { supported: false, levels: [] };
  const id = modelId.toLowerCase();

  // 1. Anthropic Claude
  if (providerId === 'anthropic' || id.includes('claude')) {
    const supports = (
      id.includes('3-7') ||
      id.includes('3.7') ||
      id.includes('4-6') ||
      id.includes('4.6') ||
      id.includes('5-5') ||
      id.includes('5.5') ||
      id.includes('5-1') ||
      id.includes('5.1') ||
      id.includes('thinking')
    ) && !id.includes('3-5') && !id.includes('3.5');

    if (!supports) {
      return { supported: false, levels: [] };
    }

    const levels = [
      { id: 'off', label: 'Off', budgetTokens: 0 },
      { id: 'low', label: 'Low', budgetTokens: 2048 },
      { id: 'medium', label: 'Medium', budgetTokens: 8192 },
      { id: 'high', label: 'High', budgetTokens: 16384 },
    ];
    if (id.includes('opus') || id.includes('4-6') || id.includes('5-5')) {
      levels.push({ id: 'max', label: 'Max (64k)', budgetTokens: 64000 });
    }
    return {
      supported: true,
      defaultLevel: 'medium',
      levels,
    };
  }

  // 2. Google Gemini
  if (providerId === 'google' || id.includes('gemini')) {
    const supports = (
      id.includes('3.8') ||
      id.includes('3.1') ||
      id.includes('2.5') ||
      id.includes('4')
    ) && !id.includes('1.5') && !id.includes('1.0');

    if (!supports) {
      return { supported: false, levels: [] };
    }

    return {
      supported: true,
      defaultLevel: 'medium',
      levels: [
        { id: 'off', label: 'Off', budgetTokens: 0 },
        { id: 'low', label: 'Low', budgetTokens: 1024 },
        { id: 'medium', label: 'Medium', budgetTokens: 4096 },
        { id: 'high', label: 'High', budgetTokens: 8192 },
      ],
    };
  }

  // 3. OpenAI
  if (providerId === 'openai' || id.startsWith('o') || id.includes('gpt-6')) {
    const isReasoning = (
      id.startsWith('o1') ||
      id.startsWith('o3') ||
      id.includes('gpt-6') ||
      id.includes('terra') ||
      id.includes('sol')
    );

    if (!isReasoning) {
      return { supported: false, levels: [] };
    }

    const levels = [
      { id: 'low', label: 'Low', reasoningEffort: 'low' },
      { id: 'medium', label: 'Medium', reasoningEffort: 'medium' },
      { id: 'high', label: 'High', reasoningEffort: 'high' },
    ];
    if (id.includes('gpt-6') || id.includes('terra') || id.includes('sol')) {
      levels.unshift({ id: 'off', label: 'Off' });
    }

    return {
      supported: true,
      defaultLevel: 'medium',
      levels,
    };
  }

  // 4. OpenRouter / Generic
  const supportedParams = rawModelMeta?.supported_parameters || [];
  if (supportedParams.includes('reasoning') || id.includes('r1') || id.includes('reasoner') || id.includes('thinking')) {
    return {
      supported: true,
      defaultLevel: 'medium',
      levels: [
        { id: 'low', label: 'Low' },
        { id: 'medium', label: 'Medium' },
        { id: 'high', label: 'High' },
      ],
    };
  }

  return { supported: false, levels: [] };
}

function annotateModel(providerId, model) {
  const thinking = getModelThinkingCapabilities(providerId, model.id, model);
  return {
    ...model,
    thinking,
  };
}

function httpsRequest(targetUrl, options, postData) {
  return new Promise((resolve, reject) => {
    const urlObj = new URL(targetUrl);
    const reqOptions = {
      hostname: urlObj.hostname,
      port: urlObj.port || 443,
      path: urlObj.pathname + urlObj.search,
      method: options.method || 'GET',
      headers: options.headers || {},
      timeout: options.timeout || 30000,
    };

    const req = https.request(reqOptions, (res) => {
      let data = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => {
        data += chunk;
      });
      res.on('end', () => {
        resolve({
          statusCode: res.statusCode,
          headers: res.headers,
          body: data,
        });
      });
    });

    req.on('error', (err) => reject(err));
    req.on('timeout', () => {
      req.destroy();
      reject(new Error('Request timed out'));
    });

    if (postData) {
      req.write(typeof postData === 'string' ? postData : JSON.stringify(postData));
    }
    req.end();
  });
}

/**
 * Validates an API key and fetches the model list for the given provider.
 * Returns { valid: true, models: [{ id, name }], defaultModel } or { valid: false, error: string }
 */
async function validateAndFetchModels(providerId, apiKey) {
  if (!apiKey || typeof apiKey !== 'string' || !apiKey.trim()) {
    return { valid: false, error: 'API key is required' };
  }

  const cleanKey = apiKey.trim();
  const provider = PROVIDERS[providerId];
  if (!provider) {
    return { valid: false, error: `Unknown provider: ${providerId}` };
  }

  try {
    switch (providerId) {
      case 'google':
        return await validateGoogle(cleanKey);
      case 'anthropic':
        return await validateAnthropic(cleanKey);
      case 'openai':
        return await validateOpenAI(cleanKey);
      case 'openrouter':
        return await validateOpenRouter(cleanKey);
      default:
        return { valid: false, error: `Unsupported provider: ${providerId}` };
    }
  } catch (err) {
    return { valid: false, error: err.message || String(err) };
  }
}

async function validateGoogle(apiKey) {
  const url = `https://generativelanguage.googleapis.com/v1beta/models?key=${encodeURIComponent(apiKey)}`;
  const res = await httpsRequest(url, { method: 'GET' });

  if (res.statusCode !== 200) {
    let errorMsg = `Google API returned HTTP ${res.statusCode}`;
    try {
      const errJson = JSON.parse(res.body);
      if (errJson.error && errJson.error.message) {
        errorMsg = errJson.error.message;
      }
    } catch {}
    return { valid: false, error: errorMsg };
  }

  const data = JSON.parse(res.body);
  const rawModels = data.models || [];
  // Filter models that support content generation and are gemini models
  const models = rawModels
    .filter((m) => {
      const name = m.name || '';
      const methods = m.supportedGenerationMethods || [];
      return methods.includes('generateContent') && !name.includes('embedding') && !name.includes('aqa');
    })
    .map((m) => {
      const id = m.name.replace(/^models\//, '');
      return {
        id,
        name: m.displayName || id,
      };
    })
    .sort((a, b) => {
      // Prioritize latest versions (4, 3.8, 3, 2.5) and flash/pro
      const score = (id) => {
        let s = 0;
        if (id.includes('4')) s += 400;
        else if (id.includes('3.8')) s += 380;
        else if (id.includes('3')) s += 300;
        else if (id.includes('2.5')) s += 200;
        else if (id.includes('1.5')) s += 100;

        if (id.includes('flash')) s += 20;
        else if (id.includes('pro')) s += 10;
        return s;
      };
      return score(b.id) - score(a.id);
    });

  if (models.length === 0) {
    models.push(
      { id: 'gemini-3.8-flash', name: 'Gemini 3.8 Flash' },
      { id: 'gemini-3.1-pro-preview', name: 'Gemini 3.1 Pro Preview' },
      { id: 'gemini-2.5-flash', name: 'Gemini 2.5 Flash' },
      { id: 'gemini-2.5-pro', name: 'Gemini 2.5 Pro' }
    );
  }

  return {
    valid: true,
    models: models.map((m) => annotateModel('google', m)),
    defaultModel: models.find((m) => m.id.includes('3.8-flash'))?.id || models.find((m) => m.id.includes('flash'))?.id || models[0].id,
  };
}

async function validateAnthropic(apiKey) {
  // First try GET /v1/models with higher limit to retrieve all active models
  const url = 'https://api.anthropic.com/v1/models?limit=100';
  const res = await httpsRequest(url, {
    method: 'GET',
    headers: {
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
    },
  });

  const fallbackModels = [
    { id: 'claude-sonnet-5-5', name: 'Claude Sonnet 5.5' },
    { id: 'claude-opus-5-5', name: 'Claude Opus 5.5' },
    { id: 'claude-haiku-5-5', name: 'Claude Haiku 5.5' },
    { id: 'claude-fable-5-1', name: 'Claude Fable 5.1' },
    { id: 'claude-3-7-sonnet-20250219', name: 'Claude 3.7 Sonnet' },
    { id: 'claude-3-5-sonnet-20241022', name: 'Claude 3.5 Sonnet' },
  ];

  if (res.statusCode === 200) {
    try {
      const data = JSON.parse(res.body);
      const raw = data.data || [];
      const models = raw
        .map((m) => ({
          id: m.id,
          name: m.display_name || m.id,
        }))
        .sort((a, b) => {
          // Prioritize 5.5 > 5.1 > 3.7 > 3.5, and sonnet > opus > haiku > fable
          const score = (id) => {
            let s = 0;
            if (id.includes('5-5') || id.includes('5.5')) s += 500;
            else if (id.includes('5-1') || id.includes('5.1')) s += 400;
            else if (id.includes('3-7') || id.includes('3.7')) s += 300;
            else if (id.includes('3-5') || id.includes('3.5')) s += 200;

            if (id.includes('sonnet')) s += 30;
            else if (id.includes('opus')) s += 20;
            else if (id.includes('haiku')) s += 10;
            return s;
          };
          const diff = score(b.id) - score(a.id);
          return diff !== 0 ? diff : b.id.localeCompare(a.id);
        });

      const finalModels = (models.length ? models : fallbackModels).map((m) => annotateModel('anthropic', m));
      return {
        valid: true,
        models: finalModels,
        defaultModel: finalModels.find((m) => m.id.includes('sonnet-5-5') || m.id.includes('sonnet'))?.id || finalModels[0]?.id || 'claude-sonnet-5-5',
      };
    } catch {}
  }

  // If models endpoint failed with auth error, fail immediately
  if (res.statusCode === 401 || res.statusCode === 403) {
    let errorMsg = 'Invalid Anthropic API key';
    try {
      const errJson = JSON.parse(res.body);
      if (errJson.error && errJson.error.message) {
        errorMsg = errJson.error.message;
      }
    } catch {}
    return { valid: false, error: errorMsg };
  }

  // Try minimal token count verification as fallback
  const testRes = await httpsRequest(
    'https://api.anthropic.com/v1/messages/count_tokens',
    {
      method: 'POST',
      headers: {
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      },
    },
    {
      model: 'claude-haiku-5-5',
      messages: [{ role: 'user', content: 'test' }],
    }
  );

  if (testRes.statusCode === 200) {
    return {
      valid: true,
      models: fallbackModels.map((m) => annotateModel('anthropic', m)),
      defaultModel: 'claude-sonnet-5-5',
    };
  }

  let errorMsg = `Anthropic API error (${testRes.statusCode})`;
  try {
    const errJson = JSON.parse(testRes.body);
    if (errJson.error && errJson.error.message) {
      errorMsg = errJson.error.message;
    }
  } catch {}
  return { valid: false, error: errorMsg };
}

async function validateOpenAI(apiKey) {
  const url = 'https://api.openai.com/v1/models';
  const res = await httpsRequest(url, {
    method: 'GET',
    headers: {
      Authorization: `Bearer ${apiKey}`,
    },
  });

  if (res.statusCode !== 200) {
    let errorMsg = `OpenAI API returned HTTP ${res.statusCode}`;
    try {
      const errJson = JSON.parse(res.body);
      if (errJson.error && errJson.error.message) {
        errorMsg = errJson.error.message;
      }
    } catch {}
    return { valid: false, error: errorMsg };
  }

  const data = JSON.parse(res.body);
  const raw = data.data || [];
  // Filter for chat completion models across modern GPT-6.x, GPT-6, GPT-5, o-series and legacy
  const models = raw
    .filter((m) => {
      const id = m.id || '';
      return (
        (id.startsWith('gpt-') || /^o[1-9]/i.test(id) || id.startsWith('chatgpt')) &&
        !id.includes('instruct') &&
        !id.includes('realtime') &&
        !id.includes('audio') &&
        !id.includes('tts') &&
        !id.includes('whisper') &&
        !id.includes('dall-e') &&
        !id.includes('embedding') &&
        !id.includes('moderation') &&
        !id.includes('transcription') &&
        !id.includes('search') &&
        !id.includes('similarity') &&
        !id.includes('babbage') &&
        !id.includes('davinci')
      );
    })
    .map((m) => ({
      id: m.id,
      name: m.id,
    }))
    .sort((a, b) => {
      // Prioritize GPT-6.1 (Terra / Sol), GPT-6, GPT-5, o-series, GPT-4o
      const score = (id) => {
        let s = 0;
        if (id.includes('gpt-6.1')) s += 610;
        else if (id.includes('gpt-6')) s += 600;
        else if (id.includes('gpt-5')) s += 500;
        else if (id.includes('o3')) s += 450;
        else if (id.includes('o1')) s += 400;
        else if (id.includes('gpt-4.5')) s += 350;
        else if (id.includes('gpt-4o')) s += 300;

        if (id.includes('terra')) s += 25;
        else if (id.includes('sol')) s += 20;
        return s;
      };
      return score(b.id) - score(a.id);
    });

  if (models.length === 0) {
    models.push(
      { id: 'gpt-6.1-terra', name: 'gpt-6.1-terra' },
      { id: 'gpt-6.1-sol', name: 'gpt-6.1-sol' },
      { id: 'gpt-6', name: 'gpt-6' },
      { id: 'gpt-5', name: 'gpt-5' },
      { id: 'o3-mini', name: 'o3-mini' },
      { id: 'gpt-4o', name: 'gpt-4o' }
    );
  }

  return {
    valid: true,
    models: models.map((m) => annotateModel('openai', m)),
    defaultModel: models.find((m) => m.id.includes('6.1-terra'))?.id || models.find((m) => m.id.startsWith('gpt-6'))?.id || models[0].id,
  };
}

async function validateOpenRouter(apiKey) {
  const url = 'https://openrouter.ai/api/v1/models';
  const res = await httpsRequest(url, {
    method: 'GET',
    headers: {
      Authorization: `Bearer ${apiKey}`,
    },
  });

  if (res.statusCode !== 200) {
    let errorMsg = `OpenRouter API returned HTTP ${res.statusCode}`;
    try {
      const errJson = JSON.parse(res.body);
      if (errJson.error && errJson.error.message) {
        errorMsg = errJson.error.message;
      }
    } catch {}
    return { valid: false, error: errorMsg };
  }

  const data = JSON.parse(res.body);
  const raw = data.data || [];
  
  // Sort OpenRouter models smartly: flagship Anthropic, OpenAI, Google, DeepSeek first
  const getProviderScore = (id) => {
    let s = 0;
    if (id.startsWith('anthropic/')) s += 1000;
    else if (id.startsWith('openai/')) s += 900;
    else if (id.startsWith('google/')) s += 800;
    else if (id.startsWith('deepseek/')) s += 700;
    else if (id.startsWith('meta-llama/') || id.startsWith('meta/')) s += 600;

    if (id.includes('5.5') || id.includes('5-5')) s += 50;
    if (id.includes('6.1') || id.includes('6-1')) s += 50;
    if (id.includes('3.8')) s += 50;
    return s;
  };

  // Strip descriptions to ensure JSON remains compact and parses reliably
  const models = raw
    .map((m) => annotateModel('openrouter', {
      id: m.id,
      name: m.name || m.id,
      supported_parameters: m.supported_parameters,
    }))
    .sort((a, b) => {
      const diff = getProviderScore(b.id) - getProviderScore(a.id);
      if (diff !== 0) return diff;
      return a.name.localeCompare(b.name);
    });

  return {
    valid: true,
    models,
    defaultModel:
      models.find((m) => m.id.includes('claude-sonnet-5-5') || m.id.includes('claude-5-5'))?.id ||
      models.find((m) => m.id.includes('gpt-6.1-terra'))?.id ||
      models[0]?.id ||
      'anthropic/claude-sonnet-5-5',
  };
}

module.exports = {
  PROVIDERS,
  validateAndFetchModels,
  getModelThinkingCapabilities,
  httpsRequest,
};
