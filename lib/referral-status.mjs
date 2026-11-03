import { readFile } from 'node:fs/promises';
import { realpathSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readJson, writeJson } from './file-state.mjs';
import { ensureReferralAssociation } from './referral-apply.mjs';

export function referralDecision(status) {
  if (!status || typeof status !== 'object') return 'unconfirmed';
  if (status.referral_code_valid === false) return 'rejected';
  if (status.referral_applied === true || status.was_previously_referred === true) return 'associated';
  if (status.referral_applied === false) return 'rejected';
  return 'unconfirmed';
}

export function referralBlocked(state, request = {}) {
  const rejected = state?.phase === 'referral_rejected'
    || (state?.requireReferral === true && state.signupSynced === true && referralDecision(state.referralStatus) === 'rejected');
  const previousCode = String(state?.referralCode ?? '').trim().toUpperCase();
  const requestedCode = String(request.referralCode ?? '').trim().toUpperCase();
  const newReferral = request.fresh === true && !request.resume && previousCode && requestedCode && previousCode !== requestedCode;
  return !!rejected && !newReferral;
}

export const REFERRAL_REVIEW_MESSAGE = 'Referral rejected by Wispr. Stop this attempt and ask Wispr support to review the signup/referral record. Changing email or IP is not a verified fix.';

function associatedStatus(state, live) {
  return {
    ...(state.referralStatus ?? { referral_code_valid: true }),
    referral_applied: true,
    message: 'Referral associated through the desktop referral API.',
    ...(live?.referer_name ? { referer_name: live.referer_name } : {}),
  };
}

export async function recheckReferralState(statePath, tokenPath = join(dirname(statePath), 'last-web-token.json')) {
  const state = await readJson(statePath, null);
  if (!state) {
    console.error('ERROR:No saved signup to recheck');
    return 1;
  }
  if (!referralBlocked(state)) {
    console.log('REFERRAL_OK:No referral rejection needs rechecking');
    return 0;
  }
  const session = await readJson(tokenPath, null);
  const accessToken = session?.access_token ?? session?.workosSession?.accessToken;
  if (!accessToken) {
    console.error('ERROR:No saved access token for referral recheck: ' + tokenPath);
    return 1;
  }
  const tokenEmail = session?.user?.email;
  if (tokenEmail && state.email && tokenEmail.toLowerCase() !== state.email.toLowerCase()) {
    console.error('ERROR:Saved token belongs to ' + tokenEmail + ', not ' + state.email);
    return 1;
  }
  let recovery;
  try {
    recovery = await ensureReferralAssociation({ accessToken, referralCode: state.referralCode });
  } catch (error) {
    console.error('ERROR:Referral recheck failed: ' + error.message);
    return 1;
  }
  if (!recovery.associated) {
    console.error('ERROR:Referral association is still missing.');
    console.error('REASON:' + (recovery.status?.message || recovery.error || 'The desktop referral API did not return a referrer.'));
    return 76;
  }
  state.referralAssociated = true;
  state.signupSynced = true;
  state.phase = 'referral_associated';
  state.retryable = false;
  state.referralAppliedVia = 'desktop-api';
  state.referralStatus = associatedStatus(state, recovery.status);
  state.referralRecoveredAt = new Date().toISOString();
  delete state.failureReason;
  await writeJson(statePath, state);

  const accountsPath = join(dirname(statePath), 'accounts.json');
  const accounts = await readJson(accountsPath, []);
  const account = Array.isArray(accounts)
    ? accounts.find(row => row?.email?.toLowerCase() === state.email?.toLowerCase())
    : null;
  if (account) {
    account.referralAssociated = true;
    account.referralStatus = state.referralStatus;
    await writeJson(accountsPath, accounts);
  }
  console.log('REFERRAL_ASSOCIATED:' + (recovery.status?.referer_name || 'true'));
  return 0;
}

let isMain = false;
try { isMain = !!process.argv[1] && realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1]); }
catch { /* Browser script hosts may use a virtual entrypoint. */ }
if (isMain) {
  const recheckIndex = process.argv.indexOf('--recheck');
  if (recheckIndex >= 0) {
    const statePath = process.argv[recheckIndex + 1];
    if (!statePath) {
      console.error('ERROR:Usage: referral-status.mjs --recheck <pending-signup.json> [token.json]');
      process.exitCode = 1;
    } else {
      try {
        process.exitCode = await recheckReferralState(statePath, process.argv[recheckIndex + 2]);
      } catch (error) {
        console.error('ERROR:Cannot recheck referral state: ' + error.message);
        process.exitCode = 1;
      }
    }
  } else {
    try {
      const state = JSON.parse(await readFile(process.argv[2], 'utf8'));
      if (referralBlocked(state, { fresh: process.argv[3] === '--fresh', referralCode: process.argv[4] })) {
        console.error('ERROR:' + REFERRAL_REVIEW_MESSAGE);
        console.error('REASON:' + (state.referralStatus?.message || state.failureReason || 'Referral association rejected'));
        process.exitCode = 76;
      }
    } catch (error) {
      if (error.code !== 'ENOENT') { console.error('ERROR:Cannot read referral state: ' + error.message); process.exitCode = 1; }
    }
  }
}
