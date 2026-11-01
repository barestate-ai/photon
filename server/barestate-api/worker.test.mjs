// Unit tests for the barestate-api Worker: fake KV binding, fake upstream fetch.
// Run: node --test server/barestate-api/
import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import worker from './worker.mjs';

class FakeKV {
  constructor() { this.map = new Map(); }
  async get(key, type) {
    const v = this.map.get(key);
    if (v === undefined) return null;
    return type === 'json' ? JSON.parse(v) : v;
  }
  async put(key, value) { this.map.set(key, String(value)); }
  async delete(key) { this.map.delete(key); }
}

const day = new Date().toISOString().slice(0, 10);

async function sha256hex(s) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function makeCtx() {
  return { promises: [], waitUntil(p) { this.promises.push(p); } };
}

function makeEnv(kv, over = {}) {
  return {
    STATE: kv,
    META_API_KEY: 'fake-meta-key',
    UPSTREAM_URL: 'https://upstream.test/v1/responses',
    GLOBAL_DAILY_CAP_USD: '10.00',
    DEFAULT_DEVICE_DAILY_CAP_USD: '2.00',
    MAX_BODY_BYTES: '10485760',
    ALLOWED_MODELS: 'muse-spark-1.3',
    ...over,
  };
}

function req(method, path, { headers = {}, body } = {}) {
  return new Request(`https://api.barestate.xyz${path}`, { method, headers, body });
}

let kv, ctx, fetchCalls, fetchImpl;
beforeEach(() => {
  kv = new FakeKV();
  ctx = makeCtx();
  fetchCalls = [];
  fetchImpl = () => { throw new Error('unexpected upstream call'); };
  globalThis.fetch = async (url, init) => {
    fetchCalls.push({ url, init, bodyText: init && init.body ? new TextDecoder().decode(init.body) : null });
    return fetchImpl(url, init);
  };
});

async function registerDevice(name = 'test-mac', ip = '203.0.113.1') {
  const res = await worker.fetch(
    req('POST', '/v1/devices', {
      headers: { 'content-type': 'application/json', 'cf-connecting-ip': ip },
      body: JSON.stringify({ invite_code: 'code-1', device_name: name }),
    }),
    makeEnv(kv), ctx);
  return res;
}

async function museCall(token, bodyObj, envOver = {}) {
  const body = typeof bodyObj === 'string' ? bodyObj : JSON.stringify(bodyObj);
  return worker.fetch(
    req('POST', '/v1/muse/responses', {
      headers: {
        authorization: `Bearer ${token}`,
        'content-type': 'application/json',
        'content-length': String(new TextEncoder().encode(body).byteLength),
      },
      body,
    }),
    makeEnv(kv, envOver), ctx);
}

function upstreamOk(usage = { input_tokens: 1000, output_tokens: 500, input_tokens_details: { cached_tokens: 200 } }) {
  return new Response(JSON.stringify({
    id: 'resp_1', model: 'muse-spark-1.3', output: [{ type: 'message' }], usage,
  }), { status: 200, headers: { 'content-type': 'application/json', 'x-request-id': 'req-abc' } });
}

test('GET /healthz answers 200', async () => {
  const res = await worker.fetch(req('GET', '/healthz'), makeEnv(kv), ctx);
  assert.equal(res.status, 200);
  assert.equal((await res.json()).status, 'ok');
});

test('unknown route answers 404', async () => {
  const res = await worker.fetch(req('GET', '/nope'), makeEnv(kv), ctx);
  assert.equal(res.status, 404);
});

test('device registration with a valid invite returns 201 and stores only the SHA-256', async () => {
  await kv.put('invites', JSON.stringify(['code-1']));
  const res = await registerDevice();
  assert.equal(res.status, 201);
  const { device_token } = await res.json();
  assert.equal(typeof device_token, 'string');
  assert.ok(device_token.length >= 40);
  const hash = await sha256hex(device_token);
  const record = await kv.get(`device/${hash}`, 'json');
  assert.equal(record.revoked, false);
  assert.equal(record.name, 'test-mac');
  assert.equal(record.daily_cap_usd, 2.0);
  assert.ok(record.created_at);
  for (const [k, v] of kv.map) assert.ok(!k.includes(device_token) && !String(v).includes(device_token));
});

test('an unknown invite code gets 403 and creates nothing', async () => {
  await kv.put('invites', JSON.stringify(['code-1']));
  const res = await worker.fetch(
    req('POST', '/v1/devices', {
      headers: { 'content-type': 'application/json', 'cf-connecting-ip': '203.0.113.9' },
      body: JSON.stringify({ invite_code: 'wrong', device_name: 'x' }),
    }),
    makeEnv(kv), ctx);
  assert.equal(res.status, 403);
  assert.equal([...kv.map.keys()].filter((k) => k.startsWith('device/')).length, 0);
});

test('repeated failed registrations are rate limited', async () => {
  await kv.put('invites', JSON.stringify(['code-1']));
  let last;
  for (let i = 0; i < 6; i++) {
    last = await worker.fetch(
      req('POST', '/v1/devices', {
        headers: { 'content-type': 'application/json', 'cf-connecting-ip': '203.0.113.44' },
        body: JSON.stringify({ invite_code: 'wrong', device_name: 'x' }),
      }),
      makeEnv(kv), ctx);
  }
  assert.equal(last.status, 429);
});

test('missing, malformed and unknown tokens get 401 before any upstream call', async () => {
  for (const headers of [
    {},
    { authorization: 'Token abc' },
    { authorization: 'Bearer no-such-token' },
  ]) {
    fetchCalls = [];
    const body = JSON.stringify({ model: 'muse-spark-1.3', input: 'hi' });
    const res = await worker.fetch(
      req('POST', '/v1/muse/responses', { headers: { ...headers, 'content-type': 'application/json' }, body }),
      makeEnv(kv), ctx);
    assert.equal(res.status, 401);
    assert.equal(fetchCalls.length, 0);
  }
});

test('a revoked device gets 401 before any upstream call', async () => {
  await kv.put('invites', JSON.stringify(['code-1']));
  const token = (await (await registerDevice()).json()).device_token;
  const hash = await sha256hex(token);
  await kv.put(`device/${hash}`, JSON.stringify({ created_at: 'x', name: 't', revoked: true, daily_cap_usd: 2 }));
  const res = await museCall(token, { model: 'muse-spark-1.3', input: 'hi' });
  assert.equal(res.status, 401);
  assert.equal(fetchCalls.length, 0);
});

test('a model outside the allowlist gets 400 before any upstream call', async () => {
  await kv.put('invites', JSON.stringify(['code-1']));
  const token = (await (await registerDevice()).json()).device_token;
  const res = await museCall(token, { model: 'muse-wonder-1.0', input: 'hi' });
  assert.equal(res.status, 400);
  assert.equal(fetchCalls.length, 0);
});

test('an oversized body gets 413 before any upstream call', async () => {
  await kv.put('invites', JSON.stringify(['code-1']));
  const token = (await (await registerDevice()).json()).device_token;
  const res = await worker.fetch(
    req('POST', '/v1/muse/responses', {
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json', 'content-length': '20971520' },
      body: '{}',
    }),
    makeEnv(kv), ctx);
  assert.equal(res.status, 413);
  assert.equal(fetchCalls.length, 0);
});

test('a non-JSON body gets 400 before any upstream call', async () => {
  await kv.put('invites', JSON.stringify(['code-1']));
  const token = (await (await registerDevice()).json()).device_token;
  const res = await museCall(token, 'not json {');
  assert.equal(res.status, 400);
  assert.equal(fetchCalls.length, 0);
});

test('a valid call is forwarded unchanged and spend is recorded from usage', async () => {
  await kv.put('invites', JSON.stringify(['code-1']));
  const token = (await (await registerDevice()).json()).device_token;
  const hash = await sha256hex(token);
  fetchImpl = () => upstreamOk();
  const bodyObj = { model: 'muse-spark-1.3', input: 'Say OK', max_output_tokens: 16 };
  const res = await museCall(token, bodyObj);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('x-request-id'), 'req-abc');
  const reply = await res.json();
  assert.equal(reply.model, 'muse-spark-1.3');

  assert.equal(fetchCalls.length, 1);
  const call = fetchCalls[0];
  assert.equal(call.url, 'https://upstream.test/v1/responses');
  assert.equal(call.init.method, 'POST');
  assert.equal(call.init.headers.authorization, 'Bearer fake-meta-key');
  assert.equal(call.bodyText, JSON.stringify(bodyObj));

  assert.equal(ctx.promises.length, 1);
  await ctx.promises[0];
  // ((1000-200)*1.25 + 200*0.15 + 500*4.25) / 1e6 = 0.003155
  const expected = 0.003155;
  const globalUsage = await kv.get(`usage/${day}`, 'json');
  const perDevice = await kv.get(`usage/${day}/${hash.slice(0, 16)}`, 'json');
  assert.equal(globalUsage.usd, expected);
  assert.equal(globalUsage.calls, 1);
  assert.equal(perDevice.usd, expected);
  assert.equal(perDevice.calls, 1);
});

test('upstream 429 and 5xx pass through with no spend recorded', async () => {
  await kv.put('invites', JSON.stringify(['code-1']));
  const token = (await (await registerDevice()).json()).device_token;
  for (const status of [429, 500]) {
    fetchImpl = () => new Response('{"error":"busy"}', {
      status, headers: { 'content-type': 'application/json', 'x-request-id': `r-${status}` },
    });
    const res = await museCall(token, { model: 'muse-spark-1.3', input: 'hi' });
    assert.equal(res.status, status);
    assert.equal(res.headers.get('x-request-id'), `r-${status}`);
    assert.equal(await res.text(), '{"error":"busy"}');
  }
  assert.equal(await kv.get(`usage/${day}`), null);
});

test('an upstream timeout answers 504 with no spend', async () => {
  await kv.put('invites', JSON.stringify(['code-1']));
  const token = (await (await registerDevice()).json()).device_token;
  // What the worker must handle: fetch rejecting with AbortSignal.timeout's error.
  fetchImpl = () => Promise.reject(new DOMException('timed out', 'TimeoutError'));
  const res = await museCall(token, { model: 'muse-spark-1.3', input: 'hi' }, { UPSTREAM_TIMEOUT_MS: '20' });
  assert.equal(res.status, 504);
  assert.equal(await kv.get(`usage/${day}`), null);
});

test('an invites value that is not a JSON list grants nothing', async () => {
  await kv.put('invites', 'code-1'); // a bare string must not substring-match
  const res = await worker.fetch(
    req('POST', '/v1/devices', {
      headers: { 'content-type': 'application/json', 'cf-connecting-ip': '203.0.113.77' },
      body: JSON.stringify({ invite_code: 'code', device_name: 'x' }),
    }),
    makeEnv(kv), ctx);
  assert.equal(res.status, 403);
  assert.equal([...kv.map.keys()].filter((k) => k.startsWith('device/')).length, 0);
});

test('the global daily cap answers 402 before any upstream call', async () => {
  await kv.put('invites', JSON.stringify(['code-1']));
  const token = (await (await registerDevice()).json()).device_token;
  await kv.put(`usage/${day}`, JSON.stringify({ usd: 10.5, calls: 30 }));
  const res = await museCall(token, { model: 'muse-spark-1.3', input: 'hi' });
  assert.equal(res.status, 402);
  const msg = (await res.json()).error.message;
  assert.match(msg, /Barestate Muse daily limit reached/);
  assert.equal(fetchCalls.length, 0);
});

test('the per-device daily cap answers 402 before any upstream call', async () => {
  await kv.put('invites', JSON.stringify(['code-1']));
  const token = (await (await registerDevice()).json()).device_token;
  const hash = await sha256hex(token);
  await kv.put(`device/${hash}`, JSON.stringify({ created_at: 'x', name: 't', revoked: false, daily_cap_usd: 0.000001 }));
  await kv.put(`usage/${day}/${hash.slice(0, 16)}`, JSON.stringify({ usd: 0.003155, calls: 1 }));
  const res = await museCall(token, { model: 'muse-spark-1.3', input: 'hi' });
  assert.equal(res.status, 402);
  assert.match((await res.json()).error.message, /Barestate Muse daily limit reached/);
  assert.equal(fetchCalls.length, 0);
});

test('stream:true gets 400 before any upstream call and records nothing', async () => {
  await kv.put('invites', JSON.stringify(['code-1']));
  const token = (await (await registerDevice()).json()).device_token;
  for (const stream of [true, 'true', 1]) {
    const res = await museCall(token, { model: 'muse-spark-1.3', input: 'hi', stream });
    assert.equal(res.status, 400);
    assert.deepEqual(await res.json(), { error: 'streaming is not supported' });
  }
  assert.equal(fetchCalls.length, 0);
  assert.equal(await kv.get(`usage/${day}`), null);
});

test('stream:false is a normal call', async () => {
  await kv.put('invites', JSON.stringify(['code-1']));
  const token = (await (await registerDevice()).json()).device_token;
  fetchImpl = () => upstreamOk();
  const res = await museCall(token, { model: 'muse-spark-1.3', input: 'hi', stream: false });
  assert.equal(res.status, 200);
  assert.equal(fetchCalls.length, 1);
});

test('an upstream 2xx that is not JSON answers 502 and never passes the body through', async () => {
  await kv.put('invites', JSON.stringify(['code-1']));
  const token = (await (await registerDevice()).json()).device_token;
  fetchImpl = () => new Response('data: {"leak":true}\n\n', {
    status: 200, headers: { 'content-type': 'text/event-stream' },
  });
  const res = await museCall(token, { model: 'muse-spark-1.3', input: 'hi' });
  assert.equal(res.status, 502);
  assert.match((await res.json()).error.message, /unexpected/i);
  assert.equal(await kv.get(`usage/${day}`), null);
});

test('look-alike JSON content types and non-object bodies are refused', async () => {
  await kv.put('invites', JSON.stringify(['code-1']));
  const token = (await (await registerDevice()).json()).device_token;
  for (const ct of ['application/jsonx', 'text/event-stream; profile="application/json"']) {
    fetchImpl = () => new Response('data: {}\n\n', { status: 200, headers: { 'content-type': ct } });
    assert.equal((await museCall(token, { model: 'muse-spark-1.3', input: 'hi' })).status, 502);
  }
  fetchImpl = () => upstreamOk();
  assert.equal((await museCall(token, 'null')).status, 400);
  assert.equal((await museCall(token, '[]')).status, 400);
  assert.equal(fetchCalls.length, 2);
  assert.equal(await kv.get(`usage/${day}`), null);
});
