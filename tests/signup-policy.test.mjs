import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import { mkdtemp, rm, access, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readJson, writeJson } from '../lib/file-state.mjs';
import { hasSignupHistory, takeFreshInbox, prepareInbox, runSignup, preventInstallerAutoDownloads } from '../lib/web-auth.mjs';

test('signup history catches registered, attempted, and completed addresses regardless of case', async () => {
  const root = await mkdtemp(join(tmpdir(), 'wispr-history-'));
  try {
    await writeJson(join(root, 'accounts.json'), [{ email: 'registered@example.com', verified: true }, { email: 'attempted@example.com', verified: false }]);
    await writeJson(join(root, 'completions.json'), [{ email: 'completed@example.com' }]);
    for (const email of ['REGISTERED@example.com', 'attempted@example.com', 'completed@example.com']) assert.equal(await hasSignupHistory(root, email), true);
    assert.equal(await hasSignupHistory(root, 'unused@example.com'), false);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('used prefetch is discarded and successive signups receive distinct unused inboxes', async () => {
  const root = await mkdtemp(join(tmpdir(), 'wispr-fresh-'));
  try {
    await writeJson(join(root, 'accounts.json'), [{ email: 'used@example.com', verified: true }]);
    await writeJson(join(root, 'next-inbox.json'), { email: 'used@example.com', password: 'test', mailToken: 'old' });
    let calls = 0;
    const create = async () => ({ email: 'fresh' + ++calls + '@example.com', password: 'test', mailToken: 'new' });
    const checkpoint = async inbox => writeJson(join(root, 'pending-signup.json'), inbox);
    const first = await takeFreshInbox(root, checkpoint, create);
    await writeJson(join(root, 'accounts.json'), [{ email: 'used@example.com' }, { email: first.email }]);
    const second = await takeFreshInbox(root, checkpoint, create);
    assert.equal(first.email, 'fresh1@example.com');
    assert.equal(second.email, 'fresh2@example.com');
    assert.equal((await readJson(join(root, 'pending-signup.json'))).email, second.email);
    await assert.rejects(access(join(root, 'next-inbox.json')));
    await assert.rejects(access(join(root, 'claimed-inbox.json')));
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('an unused prepared inbox is consumed once without creating another mailbox', async () => {
  const root = await mkdtemp(join(tmpdir(), 'wispr-ready-'));
  try {
    const inbox = { email: 'unused@example.com', password: 'test', mailToken: 'token' };
    await writeJson(join(root, 'next-inbox.json'), inbox);
    const result = await takeFreshInbox(root, async () => {}, async () => { throw new Error('Unexpected mailbox creation'); });
    assert.equal(result.email, inbox.email);
    await assert.rejects(access(join(root, 'next-inbox.json')));
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('background preparation replaces a used address and keeps only one unused inbox ready', async () => {
  const root = await mkdtemp(join(tmpdir(), 'wispr-prefetch-'));
  try {
    await writeJson(join(root, 'accounts.json'), [{ email: 'used@example.com' }]);
    await writeJson(join(root, 'next-inbox.json'), { email: 'used@example.com', password: 'test', mailToken: 'old' });
    let calls = 0;
    const create = async () => { calls++; return { email: 'unused@example.com', password: 'test', mailToken: 'new' }; };
    assert.equal((await prepareInbox(root, create)).email, 'unused@example.com');
    assert.equal((await prepareInbox(root, create)).email, 'unused@example.com');
    assert.equal(calls, 1);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('a registered email is rejected before browser navigation or replacing pending state', async () => {
  const root = await mkdtemp(join(tmpdir(), 'wispr-reject-'));
  try {
    await writeJson(join(root, 'accounts.json'), [{ email: 'used@example.com', verified: true }]);
    await writeJson(join(root, 'pending-signup.json'), { email: 'another@example.com', verified: false });
    const task = { spaceId: 1, name: 'test', page: () => ({ cdp: () => { throw new Error('Browser must not be touched'); } }) };
    assert.equal(await runSignup({ dataDir: root, email: 'used@example.com', password: 'test' }, task), 1);
    assert.equal((await readJson(join(root, 'pending-signup.json'))).email, 'another@example.com');
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('starting from a browser error page clears Wispr authentication before opening the invitation', async () => {
  const root = await mkdtemp(join(tmpdir(), 'wispr-session-'));
  try {
    const calls = [];
    const page = {
      cdp: async (method, args) => calls.push({ method, args }),
      evaluate: async (fn, arg) => vm.runInNewContext(typeof fn === 'string' ? fn : '(' + fn.toString() + ')(__arg)', {
        location: { origin: 'null', href: 'chrome-error://chromewebdata/' }, window: {}, __arg: arg,
        document: { querySelectorAll: () => [], querySelector: () => null, body: { innerText: '' } },
      }),
      goto: async url => { calls.push({ method: 'goto', url }); throw new Error('Fixture stops before network navigation'); },
    };
    const task = { spaceId: 1, name: 'test', page: () => page };
    await runSignup({ dataDir: root, email: 'unused@example.com', password: 'test', mailToken: 'token', referralCode: 'SHUBHAM3680' }, task);
    const clear = calls.findIndex(c => c.method === 'Storage.clearDataForOrigin');
    const navigation = calls.findIndex(c => c.method === 'goto');
    assert.ok(clear >= 0 && navigation > clear);
    assert.equal(calls[clear].args.origin, 'https://wisprflow.ai');
    assert.equal(calls[navigation].url, 'https://wisprflow.ai/r?SHUBHAM3680');
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('a fresh referral change preserves the rejected attempt before opening the new invitation', async () => {
  const root = await mkdtemp(join(tmpdir(), 'wispr-new-referral-'));
  try {
    const previous = { email: 'old@example.com', referralCode: 'OLD123', phase: 'referral_rejected', completed: false };
    await writeJson(join(root, 'pending-signup.json'), previous);
    let openedUrl;
    const page = {
      cdp: async () => {}, evaluate: async () => ({}),
      goto: async url => {
        openedUrl = url;
        throw new Error('Fixture stops before network navigation');
      },
    };
    const task = { spaceId: 1, name: 'test', page: () => page };
    assert.equal(await runSignup({ dataDir: root, fresh: true, email: 'new@example.com', password: 'test', mailToken: 'token', referralCode: 'NEW456' }, task), 1);
    assert.equal(openedUrl, 'https://wisprflow.ai/r?NEW456');
    assert.equal((await readJson(join(root, 'pending-signup.json'))).email, 'new@example.com');
    const archives = await readdir(join(root, 'archived-signups'));
    assert.equal(archives.length, 1);
    assert.deepEqual(await readJson(join(root, 'archived-signups', archives[0])), previous);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('installer guard disables automatic triggers on initial and dynamically added links', () => {
  const elements = [];
  const add = () => {
    const attrs = new Map([['active-download', 'mac_m1'], ['href', 'https://dl.wisprflow.ai/mac-apple/latest']]);
    elements.push({ setAttribute: (k, v) => attrs.set(k, v), getAttribute: k => attrs.get(k), removeAttribute: k => attrs.delete(k), attrs });
  };
  add();
  let changed;
  const document = { querySelectorAll: () => elements.filter(e => e.attrs.has('active-download')) };
  const context = vm.createContext({ window: {}, document, MutationObserver: class { constructor(callback) { changed = callback; } observe() {} } });
  vm.runInContext('(' + preventInstallerAutoDownloads.toString() + ')()', context);
  assert.equal(document.querySelectorAll().length, 0);
  assert.equal(elements[0].attrs.get('href'), 'https://dl.wisprflow.ai/mac-apple/latest');
  add(); changed();
  assert.equal(document.querySelectorAll().length, 0);
  assert.equal(elements[1].attrs.get('data-wispr-download-suppressed'), 'mac_m1');
});
