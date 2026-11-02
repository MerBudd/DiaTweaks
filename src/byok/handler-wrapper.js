#!/usr/bin/env node
/**
 * DiaTweaks BYOK Handler Wrapper
 * Transparently wraps Dia's native `handler` binary to intercept LLM_REQUEST
 * and route completions to the user's custom model API key and provider.
 */

const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const readline = require('readline');
const { shouldRouteRequest, executeByokRequest } = require('./router');

// Path to original unpatched handler
const realHandlerPath = path.join(__dirname, 'handler.real');

if (!fs.existsSync(realHandlerPath)) {
  console.error(`[DiaTweaks BYOK] Missing real handler binary at: ${realHandlerPath}`);
  process.exit(1);
}

// Spawn the real handler process
const child = spawn(realHandlerPath, process.argv.slice(2), {
  stdio: ['pipe', 'pipe', 'inherit'],
  env: process.env,
});

let currentAgentSpec = 'default';

// 1. Intercept stdin from agent-server -> handler.real
const stdinRl = readline.createInterface({
  input: process.stdin,
  output: child.stdin,
  terminal: false,
});

stdinRl.on('line', (line) => {
  try {
    const msg = JSON.parse(line);
    if (msg.agent_spec) {
      currentAgentSpec = msg.agent_spec;
    }
  } catch (e) {
    // not JSON or fragment
  }
  child.stdin.write(line + '\n');
});

// 2. Intercept stdout from handler.real -> agent-server
const stdoutRl = readline.createInterface({
  input: child.stdout,
  terminal: false,
});

stdoutRl.on('line', async (line) => {
  let parsed = null;
  try {
    parsed = JSON.parse(line);
  } catch (e) {
    // Not valid JSON, pass through verbatim
    process.stdout.write(line + '\n');
    return;
  }

  // Check if this is an LLM_REQUEST from Claude Code
  if (parsed && parsed.type === 'LLM_REQUEST') {
    const route = shouldRouteRequest(currentAgentSpec);

    if (route) {
      // Intercepted! Handle with BYOK
      handleByokLlmRequest(parsed, currentAgentSpec);
      return;
    }
  }

  // Pass through all other messages untouched
  process.stdout.write(line + '\n');
});

async function handleByokLlmRequest(requestMsg, agentSpec) {
  const msgId = requestMsg.msg;
  const payload = requestMsg.payload;

  try {
    await executeByokRequest(payload, agentSpec, (chunk) => {
      // Construct ACK response expected by handler's EMr loop
      const ackMsg = {
        type: 'ACK',
        msg: msgId,
        success: true,
        payload: {
          status_code: chunk.statusCode !== undefined ? chunk.statusCode : 200,
          headers: chunk.headers || { 'content-type': 'text/event-stream' },
          data: chunk.data || '',
          done: !!chunk.done,
        },
      };

      try {
        child.stdin.write(JSON.stringify(ackMsg) + '\n');
      } catch (err) {
        // stdin write failed
      }
    });
  } catch (err) {
    // Send error ACK so handler does not hang
    const errorAck = {
      type: 'ACK',
      msg: msgId,
      success: false,
      payload: {
        error: `BYOK request failed: ${err.message}`,
      },
    };
    try {
      child.stdin.write(JSON.stringify(errorAck) + '\n');
    } catch {}
  }
}

child.on('exit', (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
  } else {
    process.exit(code ?? 0);
  }
});

process.on('SIGINT', () => child.kill('SIGINT'));
process.on('SIGTERM', () => child.kill('SIGTERM'));
