import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import { referralDecision, referralBlocked } from '../lib/referral-status.mjs';
import { observeSignupSync } from '../lib/web-auth.mjs';

test('a valid code does not turn an explicit referral rejection into success', () => {
  const status = { referral_code_valid: true, referral_applied: false, was_previously_referred: false, user_exists: true,
    message: 'User exists but does not have a referral record.' };
  assert.equal(referralDecision(status), 'rejected');
  assert.equal(referralBlocked({ requireReferral: true, signupSynced: true, referralStatus: status }), true);
  assert.equal(referralDecision({ referral_code_valid: true }), 'unconfirmed');
  assert.equal(referralBlocked({ requireReferral: true, signupSynced: true, referralStatus: null }), false);
  assert.equal(referralDecision({ referral_code_valid: true, referral_applied: true }), 'associated');
  assert.equal(referralDecision({ referral_code_valid: false, referral_applied: true }), 'rejected');
});

test('only an explicit fresh start with a different code can archive a rejected attempt', () => {
  const state = { phase: 'referral_rejected', referralCode: 'OLD123' };
  assert.equal(referralBlocked(state, { fresh: true, referralCode: 'NEW456' }), false);
  for (const request of [
    { referralCode: 'NEW456' },
    { fresh: true },
    { fresh: true, referralCode: '  old123  ' },
    { fresh: true, referralCode: 'NEW456', resume: true },
  ]) assert.equal(referralBlocked(state, request), true);
  assert.equal(referralBlocked({ phase: 'referral_rejected' }, { fresh: true, referralCode: 'NEW456' }), true);
});

test('request diagnostics survive navigation without retaining passwords, codes, or tokens', async () => {
  const storage = new Map();
  const sessionStorage = { getItem: key => storage.get(key), setItem: (key, value) => storage.set(key, value) };
  const requestBodies = [];
  const responseBodies = [
    { pending_authentication_token: 'PENDING-SECRET' },
    { access_token: 'ACCESS-SECRET', refresh_token: 'REFRESH-SECRET' },
    { referral_status: { referral_code_valid: true, referral_applied: false, user_exists: true } },
  ];
  const fetch = async (_, options) => { requestBodies.push(JSON.parse(options.body)); return Response.json(responseBodies.shift()); };
  const before = { location: { origin: 'https://wisprflow.ai', href: 'https://wisprflow.ai/get-started?referral=TEST' }, fetch };
  const install = window => vm.runInNewContext('(' + observeSignupSync.toString() + ')()', { window, sessionStorage, URL, atob });
  install(before);
  const signup = { email: 'friend@example.com', password: 'PASSWORD-SECRET', captcha_token: 'CAPTCHA-SECRET', redirect_url: 'https://wisprflow.ai/downloads?referral=TEST' };
  await before.fetch('https://api.wisprflow.ai/email/signup-captcha', { body: JSON.stringify(signup) });
  await before.fetch('https://api.wisprflow.ai/email/verify-email-otp', { body: JSON.stringify({ code: '123456', pending_authentication_token: 'PENDING-SECRET', should_complete_signup: true }) });
  const after = { location: { origin: 'https://wisprflow.ai', href: 'https://wisprflow.ai/downloads?referral=TEST' }, fetch };
  install(after);
  const token = 'header.' + Buffer.from(JSON.stringify({ email: 'friend@example.com' })).toString('base64url') + '.SIGNATURE-SECRET';
  await after.fetch('https://api.wisprflow.ai/signup', { body: JSON.stringify({ access_token: token, referral: 'TEST' }) });
  const trace = after.__wisprSignupSync.requestTrace;
  assert.deepEqual(Array.from(trace, row => row.path), ['/email/signup-captcha', '/email/verify-email-otp', '/signup']);
  assert.equal(trace[0].referralCode, 'TEST');
  assert.equal(trace[1].shouldCompleteSignup, true);
  assert.equal(after.__wisprSignupSync.email, 'friend@example.com');
  assert.deepEqual(requestBodies[0], signup); // Diagnostics must not alter vendor payloads.
  assert.equal(/SECRET|123456|friend@example/.test(JSON.stringify(trace)), false);
  assert.equal(/SECRET|123456|friend@example/.test(JSON.stringify([...storage.values()])), false);
});
