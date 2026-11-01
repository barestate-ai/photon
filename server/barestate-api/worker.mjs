// barestate-api: Photon users reach Muse through this Worker without holding the Meta key.
// The Meta key lives only in the META_API_KEY secret; state lives only in the STATE KV
// namespace. Logs carry method, path, status, latency, token-hash prefix, token counts and
// cost — never bodies, images, tokens or the key.

// USD per million tokens for muse-spark-1.3; mirror of
// Sources/BarestateCore/SpendLedger.swift:19-34.
const RATE = { input: 1.25, cached: 0.15, output: 4.25 };

// ponytail: per-isolate best-effort throttle on failed registrations; a distributed limit
// needs Durable Objects if abuse ever appears.
const failures = new Map(); // ip -> ms timestamps of recent failures

function json(status, obj) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

function num(v, d) {
  if (v === undefined || v === null || v === '') return d;
  const n = Number(v);
  return Number.isFinite(n) ? n : d;
}

const micro = (usd) => Math.round(usd * 1e6) / 1e6;

async function sha256hex(text) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function randomToken() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes))
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replaceAll('=', '');
}

async function registerDevice(request, env) {
  const ip = request.headers.get('cf-connecting-ip') || 'unknown';
  const now = Date.now();
  const recent = (failures.get(ip) || []).filter((t) => now - t < 60_000);
  if (recent.length >= 5) {
    return json(429, { error: { message: 'Too many failed attempts. Try again in a minute.' } });
  }
  let body;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: { message: 'A JSON body with invite_code and device_name is required.' } });
  }
  const code = String(body.invite_code || '');
  const name = String(body.device_name || 'device').slice(0, 80);
  let invites = [];
  try {
    const rawInvites = await env.STATE.get('invites', 'json');
    if (Array.isArray(rawInvites)) invites = rawInvites;
  } catch { /* a malformed or unreadable invites key grants nothing */ }
  if (!code || !invites.includes(code)) {
    recent.push(now);
    if (failures.size > 10_000) failures.clear(); // bound the map; the limit stays best-effort
    failures.set(ip, recent);
    return json(403, { error: { message: 'Unknown invite code.' } });
  }
  const token = randomToken(); // shown once; the server keeps only its SHA-256.
  const hash = await sha256hex(token);
  await env.STATE.put(`device/${hash}`, JSON.stringify({
    created_at: new Date().toISOString(),
    name,
    revoked: false,
    daily_cap_usd: num(env.DEFAULT_DEVICE_DAILY_CAP_USD, 2.0),
  }));
  return json(201, { device_token: token });
}

async function museResponses(request, env, ctx, log) {
  const auth = request.headers.get('authorization') || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  if (!token) {
    return json(401, { error: { message: 'A Barestate device token is required (Authorization: Bearer …).' } });
  }
  const hash = await sha256hex(token);
  const device = await env.STATE.get(`device/${hash}`, 'json');
  if (!device || device.revoked) {
    return json(401, { error: { message: 'Unknown or revoked device token.' } });
  }
  log.dev = hash.slice(0, 8);

  const maxBody = num(env.MAX_BODY_BYTES, 10 * 1024 * 1024);
  if (num(request.headers.get('content-length'), 0) > maxBody) {
    return json(413, { error: { message: 'Request body too large (10 MB max).' } });
  }
  const body = await request.arrayBuffer();
  if (body.byteLength > maxBody) {
    return json(413, { error: { message: 'Request body too large (10 MB max).' } });
  }

  let parsed;
  try {
    parsed = JSON.parse(new TextDecoder().decode(body));
  } catch {
    return json(400, { error: { message: 'The body must be a Responses API JSON object.' } });
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return json(400, { error: { message: 'The body must be a Responses API JSON object.' } });
  }
  // Streamed bodies cannot be priced from usage, so they would bypass the daily caps.
  if (parsed.stream) return json(400, { error: 'streaming is not supported' });
  const allowed = (env.ALLOWED_MODELS || 'muse-spark-1.3').split(',');
  if (!allowed.includes(parsed.model)) {
    return json(400, { error: { message: `Model must be one of: ${allowed.join(', ')}.` } });
  }

  const day = new Date().toISOString().slice(0, 10);
  const globalKey = `usage/${day}`;
  const deviceKey = `usage/${day}/${hash.slice(0, 16)}`;
  const globalUsage = (await env.STATE.get(globalKey, 'json')) || { usd: 0, calls: 0 };
  const deviceUsage = (await env.STATE.get(deviceKey, 'json')) || { usd: 0, calls: 0 };
  if (globalUsage.usd >= num(env.GLOBAL_DAILY_CAP_USD, 10.0)) {
    return json(402, { error: { message: 'Barestate Muse daily limit reached for the service. Try again tomorrow, or use your own model key in Settings.' } });
  }
  if (deviceUsage.usd >= num(device.daily_cap_usd, num(env.DEFAULT_DEVICE_DAILY_CAP_USD, 2.0))) {
    return json(402, { error: { message: 'Barestate Muse daily limit reached for this device. Try again tomorrow, or use your own model key in Settings.' } });
  }

  const headers = { authorization: `Bearer ${env.META_API_KEY}`, 'content-type': 'application/json' };
  const accept = request.headers.get('accept');
  if (accept) headers.accept = accept;
  let upstream;
  try {
    upstream = await fetch(env.UPSTREAM_URL || 'https://api.meta.ai/v1/responses', {
      method: 'POST',
      headers,
      body,
      signal: AbortSignal.timeout(num(env.UPSTREAM_TIMEOUT_MS, 60_000)),
    });
  } catch (e) {
    const timedOut = e && (e.name === 'TimeoutError' || e.name === 'AbortError');
    return json(timedOut ? 504 : 502, {
      error: { message: timedOut ? 'Muse did not answer in time. Try again.' : 'Muse could not be reached. Try again.' },
    });
  }

  const outHeaders = new Headers();
  const ct = upstream.headers.get('content-type');
  if (ct) outHeaders.set('content-type', ct);
  const reqId = upstream.headers.get('x-request-id');
  if (reqId) outHeaders.set('x-request-id', reqId);

  if (!upstream.ok) return new Response(upstream.body, { status: upstream.status, headers: outHeaders });
  if ((ct || '').split(';', 1)[0].trim().toLowerCase() !== 'application/json') {
    await upstream.body?.cancel();
    return json(502, { error: { message: 'Muse answered in an unexpected format. Try again.' } });
  }
  const text = await upstream.text();
  try {
    const u = JSON.parse(text).usage || {};
    const input = num(u.input_tokens, 0);
    const output = num(u.output_tokens, 0);
    const cached = num(u.input_tokens_details && u.input_tokens_details.cached_tokens, 0);
    const usd = micro(((input - cached) * RATE.input + cached * RATE.cached + output * RATE.output) / 1e6);
    log.in = input;
    log.out = output;
    log.usd = usd;
    // ponytail: KV read-modify-write is a soft cap — a burst can overshoot a little;
    // Durable Objects would make it exact if the volume ever matters.
    ctx.waitUntil((async () => {
      await env.STATE.put(globalKey, JSON.stringify({ usd: micro(globalUsage.usd + usd), calls: globalUsage.calls + 1 }));
      await env.STATE.put(deviceKey, JSON.stringify({ usd: micro(deviceUsage.usd + usd), calls: deviceUsage.calls + 1 }));
    })());
  } catch { /* usage unreadable; the successful call still goes through */ }
  return new Response(text, { status: upstream.status, headers: outHeaders });
}

export default {
  async fetch(request, env, ctx) {
    const started = Date.now();
    const path = new URL(request.url).pathname;
    const log = { m: request.method, p: path };
    let res;
    try {
      if (request.method === 'GET' && path === '/healthz') {
        res = json(200, { status: 'ok' });
      } else if (request.method === 'POST' && path === '/v1/devices') {
        res = await registerDevice(request, env);
      } else if (request.method === 'POST' && path === '/v1/muse/responses') {
        res = await museResponses(request, env, ctx, log);
      } else {
        res = json(404, { error: { message: 'Not found.' } });
      }
    } catch {
      res = json(500, { error: { message: 'Internal error.' } });
    }
    log.s = res.status;
    log.ms = Date.now() - started;
    console.log(JSON.stringify(log));
    return res;
  },
};
