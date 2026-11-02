import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createMaildropInbox, maildropQuery, readMaildrop, decodeMaildropMessage } from '../lib/maildrop.mjs';
import { verificationCode, isWisprVerification } from '../lib/web-auth.mjs';

test('Maildrop addresses are fresh and need no mailbox account or token', () => {
  const first = createMaildropInbox(), second = createMaildropInbox();
  assert.notEqual(first.email, second.email);
  assert.equal(first.email, first.mailbox + '@maildrop.cc');
  assert.equal(first.mailProvider, 'maildrop');
  assert.equal(first.mailToken, undefined);
});

test('Maildrop lists at ten-second intervals and fetches full message data separately', async () => {
  const root = await mkdtemp(join(tmpdir(), 'maildrop-query-'));
  try {
    let clock = Date.now();
    const pauses = [], calls = [];
    const options = { dataDir: root, now: () => clock, sleep: async ms => { pauses.push(ms); clock += ms; }, fetch: async (url, request) => {
      assert.equal(url, 'https://api.maildrop.cc/graphql');
      assert.equal(request.headers.Authorization, undefined);
      const body = JSON.parse(request.body); calls.push(body);
      if (body.query.includes('query Inbox')) return Response.json({ data: { inbox: [{ id: 'message-1' }] } });
      assert.match(body.query, /data html/);
      return Response.json({ data: { message: { id: 'message-1', headerfrom: 'Wispr <support@wispr.ai>', subject: 'Verify your email', date: new Date(clock).toISOString(), data: 'Verification code: 123456', rcptto: ['fresh@maildrop.cc'] } } });
    } };
    const inbox = { email: 'fresh@maildrop.cc', mailbox: 'fresh' };
    await readMaildrop(inbox, '/messages', options);
    await readMaildrop(inbox, '/messages', options);
    assert.deepEqual(pauses, [0, 10000]);
    const message = await readMaildrop(inbox, '/messages/message-1', options);
    assert.deepEqual(calls[2].variables, { mailbox: 'fresh', id: 'message-1' });
    assert.equal(verificationCode(message), '123456');
    assert.equal(isWisprVerification(message, inbox.email), true);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('Maildrop MIME decoding reads encoded bodies and ignores numeric CSS', () => {
  const raw = 'From: Wispr <support@wispr.ai>\r\nTo: fresh@maildrop.cc\r\nDate: Mon, 02 Nov 2026 19:00:00 +0000\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n' + Buffer.from('<style>color:#111111</style><p>Verify your email</p><div>654321</div>').toString('base64');
  const message = decodeMaildropMessage({ id: 'id', subject: 'Verify your email', headerfrom: 'Wispr <support@wispr.ai>', date: '2026-11-02T19:15:00Z', data: raw }, 'fresh@maildrop.cc');
  assert.equal(verificationCode(message), '654321');
  assert.equal(message.sentAt, '2026-11-02T19:00:00+00:00');
  assert.equal(isWisprVerification(message, 'fresh@maildrop.cc'), true);
});

test('Maildrop rate limits back off and GraphQL errors never look like an empty inbox', async () => {
  const root = await mkdtemp(join(tmpdir(), 'maildrop-limit-'));
  try {
    let calls = 0, clock = Date.now();
    const pauses = [];
    const options = { dataDir: root, now: () => clock, sleep: async ms => { pauses.push(ms); clock += ms; }, fetch: async () => ++calls === 1 ? new Response('', { status: 429, headers: { 'Retry-After': '15' } }) : Response.json({ errors: [{ message: 'Service unavailable' }] }) };
    await assert.rejects(maildropQuery('query { status }', {}, options), /Service unavailable/);
    assert.ok(pauses.includes(15000));
    assert.equal(calls, 2);
  } finally { await rm(root, { recursive: true, force: true }); }
});
