export function loadConfig(env = process.env) {
  const token = env.FITFIND_ACCESS_TOKEN ?? '';
  if (!/^[A-Za-z0-9_-]{32,256}$/.test(token)) {
    throw new Error('Set FITFIND_ACCESS_TOKEN to a random 32–256 character token. See README.md.');
  }
  function integer(name, fallback, min, max) {
    const raw = env[name] ?? String(fallback);
    const value = Number(raw);
    if (!/^\d+$/.test(raw) || !Number.isSafeInteger(value) || value < min || value > max) {
      throw new Error(`Invalid ${name}; use an integer between ${min} and ${max}.`);
    }
    return value;
  }
  const model = env.GEMINI_MODEL || 'gemini-2.5-flash';
  if (!/^gemini-[a-zA-Z0-9._-]{1,80}$/.test(model)) throw new Error('Invalid GEMINI_MODEL.');
  return {
    token, model, apiKey: (env.GEMINI_API_KEY ?? '').trim(),
    host: env.HOST || '127.0.0.1', port: integer('PORT', 8787, 1, 65535),
    maxRequests: integer('MAX_REQUESTS_PER_MINUTE', 20, 1, 1000),
    maxConcurrent: integer('MAX_CONCURRENT_ANALYSES', 2, 1, 8),
    maxCalls: integer('MAX_PROVIDER_CALLS_PER_RUN', 50, 1, 10000),
    cacheTtlMs: integer('CACHE_TTL_SECONDS', 300, 0, 3600) * 1000,
    maxBodyBytes: 4_100_000, maxImageBytes: 3_000_000,
    providerTimeoutMs: 45_000, maxOutputTokens: 4096,
  };
}
