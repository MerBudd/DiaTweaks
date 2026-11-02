#!/usr/bin/env node
/**
 * CLI validation and model fetch tool for DiaTweaks BYOK
 * Usage: node verify.js <provider> <apiKey>
 */

const { validateAndFetchModels } = require('./providers');

async function main() {
  const provider = process.argv[2];
  const apiKey = process.argv[3];

  if (!provider || !apiKey) {
    const errJson = JSON.stringify({
      valid: false,
      error: 'Usage: node verify.js <provider> <apiKey>',
    });
    process.stdout.write(errJson + '\n', () => {
      process.exit(1);
    });
    return;
  }

  const result = await validateAndFetchModels(provider, apiKey);
  const jsonStr = JSON.stringify(result);
  
  // Guarantee full flush to stdout pipe before exiting process
  process.stdout.write(jsonStr + '\n', () => {
    process.exit(result.valid ? 0 : 1);
  });
}

main().catch((err) => {
  const errJson = JSON.stringify({
    valid: false,
    error: err.message || String(err),
  });
  process.stdout.write(errJson + '\n', () => {
    process.exit(1);
  });
});
