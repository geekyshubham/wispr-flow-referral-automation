import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { ensureReferralAssociation, hasReferral } from '../lib/referral-apply.mjs';
import { recheckReferralState } from '../lib/referral-status.mjs';

test('an existing referrer is accepted without sending an apply request', async () => {
  const calls = [];
  const result = await ensureReferralAssociation({
    accessToken: 'token',
    referralCode: 'ATHARVA656',
    fetch: async (url, options) => {
      calls.push({ url, method: options.method, authorization: options.headers.Authorization });
      return Response.json({ referral_code: 'ALEX204840', referer_name: 'Atharva', referrals: [] });
    },
  });
  assert.equal(result.associated, true);
  assert.equal(result.applied, false);
  assert.deepEqual(calls.map(call => call.method), ['GET']);
  assert.equal(calls[0].authorization, 'token');
  assert.equal(hasReferral({ referer_name: '  ' }), false);
});

test('the desktop apply payload is sent before the profile is checked again', async () => {
  const calls = [];
  let statusCalls = 0;
  const result = await ensureReferralAssociation({
    accessToken: 'token',
    referralCode: 'ATHARVA656',
    fetch: async (url, options) => {
      calls.push({ url, method: options.method, headers: options.headers, body: options.body });
      if (options.method === 'GET') {
        statusCalls++;
        return Response.json(statusCalls === 1
          ? { referral_code: 'ALEX204840', referer_name: null, referrals: [] }
          : { referral_code: 'ALEX204840', referer_name: 'Atharva', referrals: [] });
      }
      return Response.json({ message: 'No comments.' });
    },
  });
  assert.equal(result.associated, true);
  assert.equal(result.applied, true);
  assert.equal(statusCalls, 2);
  const apply = calls.find(call => call.method === 'POST');
  assert.equal(apply.url, 'https://api.wisprflow.ai/api/v1/referral/apply');
  assert.equal(apply.headers.Authorization, 'token');
  assert.deepEqual(JSON.parse(apply.body), {
    dub_click_id: null,
    referrer_code: 'ATHARVA656',
    check_credits: false,
  });
});

test('a rejected apply is not treated as associated', async () => {
  let statusCalls = 0;
  const result = await ensureReferralAssociation({
    accessToken: 'token',
    referralCode: 'ATHARVA656',
    fetch: async (url, options) => {
      if (options.method === 'GET') {
        statusCalls++;
        return Response.json({ referer_name: null });
      }
      return new Response('', { status: 401 });
    },
  });
  assert.equal(result.associated, false);
  assert.equal(result.applied, false);
  assert.equal(result.applyHttp, 401);
  assert.equal(statusCalls, 2);
});

test('a saved rejection is repaired from the live profile and accounts file', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'wispr-recheck-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const statePath = join(directory, 'pending-signup.json');
  const tokenPath = join(directory, 'last-web-token.json');
  const email = 'flow@example.com';
  await writeFile(statePath, JSON.stringify({
    email,
    referralCode: 'ATHARVA656',
    requireReferral: true,
    signupSynced: true,
    phase: 'referral_rejected',
    failureReason: 'User exists but does not have a referral record.',
    referralStatus: { referral_code_valid: true, referral_applied: false },
  }));
  await writeFile(join(directory, 'accounts.json'), JSON.stringify([{ email, verified: true }]));
  await writeFile(tokenPath, JSON.stringify({ access_token: 'token', user: { email } }));
  const originalFetch = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, options) => {
    calls.push(options.method);
    return Response.json({ referral_code: 'ALEX204840', referer_name: 'Atharva', referrals: [] });
  };
  t.after(() => { globalThis.fetch = originalFetch; });
  const output = t.mock.method(console, 'log', () => {});

  assert.equal(await recheckReferralState(statePath, tokenPath), 0);
  assert.deepEqual(calls, ['GET']);
  assert.equal(output.mock.calls.at(-1).arguments[0], 'REFERRAL_ASSOCIATED:Atharva');

  const state = JSON.parse(await readFile(statePath, 'utf8'));
  assert.equal(state.phase, 'referral_associated');
  assert.equal(state.referralAssociated, true);
  assert.equal(state.retryable, false);
  assert.equal(state.referralAppliedVia, 'desktop-api');
  assert.equal(state.referralStatus.referer_name, 'Atharva');
  assert.equal(state.failureReason, undefined);
  const accounts = JSON.parse(await readFile(join(directory, 'accounts.json'), 'utf8'));
  assert.equal(accounts[0].referralAssociated, true);
  assert.equal(accounts[0].referralStatus.referer_name, 'Atharva');
});

test('a recheck refuses a token that belongs to a different account', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'wispr-recheck-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const statePath = join(directory, 'pending-signup.json');
  const tokenPath = join(directory, 'last-web-token.json');
  await writeFile(statePath, JSON.stringify({
    email: 'flow@example.com',
    referralCode: 'ATHARVA656',
    requireReferral: true,
    signupSynced: true,
    phase: 'referral_rejected',
    referralStatus: { referral_code_valid: true, referral_applied: false },
  }));
  await writeFile(tokenPath, JSON.stringify({ access_token: 'token', user: { email: 'other@example.com' } }));
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => { throw new Error('fetch must not be called'); };
  t.after(() => { globalThis.fetch = originalFetch; });
  t.mock.method(console, 'error', () => {});

  assert.equal(await recheckReferralState(statePath, tokenPath), 1);
  const state = JSON.parse(await readFile(statePath, 'utf8'));
  assert.equal(state.phase, 'referral_rejected');
  assert.equal(state.referralAssociated, undefined);
});
