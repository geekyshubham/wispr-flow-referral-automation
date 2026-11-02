import { readFile } from 'node:fs/promises';
import { realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

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

let isMain = false;
try { isMain = !!process.argv[1] && realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1]); }
catch { /* Browser script hosts may use a virtual entrypoint. */ }
if (isMain) {
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
