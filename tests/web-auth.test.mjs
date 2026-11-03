import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import { mailRequest, verificationLink, verificationCode, workosSession, refreshWorkosSession, isWisprVerification, observeSignupSync, dismissPrivacy, submit, authToken } from '../lib/web-auth.mjs';

test('auth lookup tolerates browser error pages and only reads storage on Wispr', async () => {
  const run = (fn, key, context) => vm.runInNewContext('(' + fn.toString() + ')(__key)', { ...context, __key: key });
  for (const origin of ['null', 'chrome-error://chromewebdata', 'https://example.com']) {
    const page = { evaluate: (fn, key) => run(fn, key, { location: { origin } }) };
    assert.equal(await authToken(page, 'test@example.com'), null);
  }
  const legacy = JSON.stringify({ user: { email: 'test@example.com' }, access_token: 'test', expires_at: Date.now() / 1000 + 3600 });
  assert.equal(await authToken({ evaluate: (fn, key) => run(fn, key, {
    location: { origin: 'https://wisprflow.ai' }, document: { cookie: '' }, localStorage: { getItem: () => legacy },
  }) }, 'test@example.com'), legacy);
});

test('auth lookup recovers Supabase cookie sessions when localStorage is stale', async () => {
  const token = claims => 'header.' + Buffer.from(JSON.stringify(claims)).toString('base64url') + '.signature';
  const claims = { email: 'test@example.com', exp: Math.floor(Date.now() / 1000) + 3600, sub: 'supabase-user', iss: 'https://example.supabase.co/auth/v1' };
  const cookie = `access_token=${encodeURIComponent(token(claims))}; refresh_token=refresh123`;
  const stored = await authToken({ evaluate: fn => vm.runInNewContext('(' + fn.toString() + ')(__key)', {
    location: { origin: 'https://wisprflow.ai' }, document: { cookie }, localStorage: { getItem: () => null }, __key: 'key',
  }) }, 'test@example.com');
  const session = JSON.parse(stored);
  assert.equal(session.provider, 'supabase');
  assert.equal(session.access_token, token(claims));
  assert.equal(session.user.id, 'supabase-user');
  assert.equal(session.user.email, 'test@example.com');
});

test('mail.tm retries the same request after Retry-After, with paced requests', async () => {
  const pauses = [];
  const requests = [];
  const result = await mailRequest('/accounts', { method: 'POST', body: { address: 'test@example.com' } }, {
    sleep: async ms => pauses.push(ms),
    fetch: async (url, options) => {
      requests.push([url, options.method, options.body]);
      return requests.length === 1
        ? new Response('', { status: 429, headers: { 'Retry-After': '45' } })
        : Response.json({ id: 'same-inbox' });
    },
  });
  assert.deepEqual(result, { id: 'same-inbox' });
  assert.deepEqual(requests[0], requests[1]);
  assert.deepEqual(pauses, [1000, 20000, 20000, 5000, 1000]);
});

test('persistent 429 is bounded; other failures are not retried', async () => {
  let calls = 0;
  const deps = { sleep: async () => {}, fetch: async () => { calls++; return new Response('limited', { status: 429, headers: { 'Retry-After': '1' } }); } };
  await assert.rejects(mailRequest('/accounts', {}, deps), /HTTP 429/);
  assert.equal(calls, 4);
  calls = 0;
  deps.fetch = async () => { calls++; return new Response('invalid credentials', { status: 401 }); };
  await assert.rejects(mailRequest('/token', {}, deps), /HTTP 401/);
  assert.equal(calls, 1);
});

test('verification links accept HTML arrays and decode HTML query separators', () => {
  assert.equal(verificationLink({ html: ['<a href="https://auth.wisprflow.com/auth/v1/verify?token=abc&amp;type=signup">verify</a>'] }), 'https://auth.wisprflow.com/auth/v1/verify?token=abc&type=signup');
  assert.equal(verificationLink({ text: 'unrelated message' }), undefined);
});

test('current Wispr code emails work alongside legacy verification links', () => {
  assert.equal(verificationCode({ text: 'Enter the code below in your open browser window.\n\n123456\nThis code expires in 15 minutes.' }), '123456');
  assert.equal(verificationCode({ html: ['<p>Verify your email</p>', '<strong>654321</strong>'] }), '654321');
  assert.equal(verificationCode({ text: 'No verification code here' }), undefined);
});

test('server RateLimit-Policy paces reads and account creation in separate buckets', async () => {
  let clock = Date.now();
  const pauses = [];
  const deps = {
    now: () => clock,
    sleep: async ms => { pauses.push(ms); clock += ms; },
    fetch: async (_, options) => Response.json({}, { headers: { 'RateLimit-Policy': options.method === 'POST' ? '1; w=60' : '30; w=60' } }),
  };
  await mailRequest('/domains', {}, deps);
  await mailRequest('/messages', {}, deps);
  assert.deepEqual(pauses, [1000, 2000]);
  pauses.length = 0;
  await mailRequest('/accounts', { method: 'POST' }, deps);
  await mailRequest('/token', { method: 'POST' }, deps);
  await mailRequest('/accounts', { method: 'POST' }, deps);
  assert.deepEqual(pauses, [1000, 1000, 20000, 20000, 19000]);
});

test('WorkOS uses the Wispr external user id and rejects a different account or expired session', () => {
  const token = claims => 'header.' + Buffer.from(JSON.stringify(claims)).toString('base64url') + '.signature';
  const claims = { email: 'test@example.com', exp: Math.floor(Date.now() / 1000) + 3600, sub: 'workos-user', 'urn:wispr:user_external_id': 'wispr-user' };
  assert.equal(workosSession(token(claims), 'refresh', claims.email).user.id, 'wispr-user');
  assert.equal(workosSession(token(claims), 'refresh', 'someone-else@example.com'), null);
  assert.equal(workosSession(token({ ...claims, exp: 0 }), 'refresh', claims.email), null);
});

test('verification only consumes messages for this inbox from Wispr domains', () => {
  const message = { from: { address: 'no-reply@auth.wisprflow.com' }, to: [{ address: 'test@example.com' }], subject: 'Verify your email address' };
  assert.equal(isWisprVerification(message, 'test@example.com'), true);
  assert.equal(isWisprVerification({ ...message, from: {address:'support@wispr.ai'} }, 'test@example.com'), true);
  assert.equal(isWisprVerification({ ...message, from: { address: 'fake@wisprflow.com.attacker.example' } }, 'test@example.com'), false);
  assert.equal(isWisprVerification(message, 'someone-else@example.com'), false);
});

test('expired WorkOS sessions refresh with rotation and preserve account identity', async () => {
  const token = id => 'header.' + Buffer.from(JSON.stringify({ email: 'test@example.com', 'urn:wispr:user_external_id': id, exp: Math.floor(Date.now() / 1000) + 3600, client_id: 'public-client' })).toString('base64url') + '.signature';
  const session = { provider: 'workos', client_id: 'public-client', refresh_token: 'old-refresh', user: { email: 'test@example.com', id: 'wispr-user' } };
  const refreshed = await refreshWorkosSession(session, async (url, options) => {
    assert.equal(url, 'https://api.workos.com/user_management/authenticate');
    assert.deepEqual(JSON.parse(options.body), { grant_type: 'refresh_token', client_id: 'public-client', refresh_token: 'old-refresh' });
    return Response.json({ access_token: token('wispr-user'), refresh_token: 'rotated-refresh' });
  });
  assert.equal(refreshed.refresh_token, 'rotated-refresh');
  await assert.rejects(refreshWorkosSession(session, async () => Response.json({ access_token: token('different-user'), refresh_token: 'new' })), /changed account/);
  await assert.rejects(refreshWorkosSession(session, async () => new Response('', { status: 401 })), /HTTP 401/);
});

test('signup observer preserves the response and captures only the requested referral result', async () => {
  const result = { referral_code_valid: true, referral_applied: true };
  const window = { location: { origin: 'https://wisprflow.ai', href: 'https://wisprflow.ai/downloads' }, fetch: async () => Response.json({ referral_status: result }) };
  const context = vm.createContext({ window, URL, atob });
  vm.runInContext('(' + observeSignupSync.toString() + ')()', context);
  const response = await window.fetch('https://api.wisprflow.ai/signup', { body: JSON.stringify({ referral: 'SHUBHAM3680' }) });
  assert.deepEqual(await response.json(), { referral_status: result });
  assert.equal(window.__wisprSignupSync.referralCode, 'SHUBHAM3680');
  assert.equal(window.__wisprSignupSync.referralStatus.referral_applied, true);
  assert.equal('access_token' in window.__wisprSignupSync, false);
});

test('privacy dismissal uses accessible refs so shadow-DOM banners are handled', async () => {
  const clicked = [];
  const page = {
    snapshot: async () => 'dialog "Privacy Settings"\n  button "Deny" [ref=58, loc=css:button[aria-label="Deny"]]',
    click: async selector => clicked.push(selector),
    evaluate: async () => { throw new Error('Plain document selectors cannot find this shadow DOM'); },
  };
  assert.equal(await dismissPrivacy(page), true);
  assert.deepEqual(clicked, ['@58']);
});

test('a late consent overlay is dismissed before retrying an intercepted submit', async () => {
  let snapshots = 0, submits = 0;
  const clicks = [];
  const page = {
    snapshot: async () => ++snapshots === 1 ? 'root' : 'button "Deny" [ref=58]',
    click: async selector => {
      clicks.push(selector);
      if (selector !== '@58' && ++submits === 1) throw new Error('usercentrics-cmp-ui intercepts pointer events');
    },
  };
  await submit(page);
  assert.equal(submits, 2);
  assert.equal(clicks[1], '@58');
});
