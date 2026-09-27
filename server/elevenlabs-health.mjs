export const ELEVENLABS_REALTIME_TOKEN_URL = 'https://api.elevenlabs.io/v1/single-use-token/realtime_scribe';

export function elevenLabsConfiguredHealth({ enabled = false, apiKey = '' } = {}) {
  const configured = typeof apiKey === 'string' && apiKey.length > 0;
  if (!enabled) {
    return { enabled: false, configured, reachable: null, authenticated: null, authorized: null, status: 'disabled' };
  }
  if (!configured) {
    return { enabled: true, configured: false, reachable: null, authenticated: false, authorized: false, status: 'missing_key' };
  }
  return { enabled: true, configured: true, reachable: null, authenticated: null, authorized: null, status: 'unchecked' };
}

export async function checkElevenLabsHealth({
  enabled = false,
  apiKey = '',
  fetchImpl = globalThis.fetch,
  endpoint = ELEVENLABS_REALTIME_TOKEN_URL,
  timeoutMs = 3000,
} = {}) {
  const configuredState = elevenLabsConfiguredHealth({ enabled, apiKey });
  if (configuredState.status !== 'unchecked') return configuredState;
  if (typeof fetchImpl !== 'function') {
    return { enabled: true, configured: true, reachable: false, authenticated: null, authorized: null, status: 'unavailable' };
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchImpl(endpoint, {
      method: 'POST',
      headers: { 'xi-api-key': apiKey },
      signal: controller.signal,
    });

    if (response.status === 200) {
      let body = null;
      try { body = await response.json(); } catch { /* handled below */ }
      const validToken = typeof body?.token === 'string' && body.token.length > 0;
      return {
        enabled: true,
        configured: true,
        reachable: true,
        authenticated: validToken,
        authorized: validToken,
        status: validToken ? 'ready' : 'unexpected_response',
      };
    }

    if (response.status === 401) {
      return { enabled: true, configured: true, reachable: true, authenticated: false, authorized: false, status: 'invalid_key' };
    }
    if (response.status === 403) {
      // A 403 can be caused by scope restrictions or an IP allowlist. Do not
      // mislabel it as an invalid key; the credential simply cannot use realtime Scribe here.
      return { enabled: true, configured: true, reachable: true, authenticated: null, authorized: false, status: 'forbidden' };
    }
    if (response.status === 429) {
      return { enabled: true, configured: true, reachable: true, authenticated: null, authorized: null, status: 'rate_limited' };
    }

    return {
      enabled: true,
      configured: true,
      reachable: true,
      authenticated: null,
      authorized: null,
      status: 'http_error',
      httpStatus: response.status,
    };
  } catch (error) {
    const aborted = controller.signal.aborted || error?.name === 'AbortError' || error?.name === 'TimeoutError';
    return {
      enabled: true,
      configured: true,
      reachable: false,
      authenticated: null,
      authorized: null,
      status: aborted ? 'timeout' : 'unavailable',
    };
  } finally {
    clearTimeout(timer);
  }
}
