const REFERRAL_API = 'https://api.wisprflow.ai/api/v1/referral/';

export function hasReferral(status) {
  return typeof status?.referer_name === 'string' && status.referer_name.trim().length > 0;
}

async function responseBody(response) {
  try { return await response.json(); } catch { return null; }
}

export async function fetchReferralStatus({ accessToken, fetch: fetcher = fetch, timeout = 15000 } = {}) {
  if (!accessToken) throw new Error('No access token for referral status');
  const response = await fetcher(REFERRAL_API, {
    method: 'GET',
    headers: { Authorization: accessToken, 'Content-Type': 'application/json' },
    signal: AbortSignal.timeout(timeout),
  });
  return { ok: response.ok, status: response.status, body: await responseBody(response) };
}

export async function applyReferralCode({
  accessToken, referralCode, dubClickId = null, checkCredits = false, fetch: fetcher = fetch, timeout = 15000,
} = {}) {
  if (!accessToken) throw new Error('No access token for referral apply');
  if (!referralCode) throw new Error('No referral code for referral apply');
  const response = await fetcher(REFERRAL_API + 'apply', {
    method: 'POST',
    headers: { Authorization: accessToken, 'Content-Type': 'application/json' },
    body: JSON.stringify({ dub_click_id: dubClickId, referrer_code: referralCode, check_credits: !!checkCredits }),
    signal: AbortSignal.timeout(timeout),
  });
  return { ok: response.ok, status: response.status, body: await responseBody(response) };
}

// The website completes email signup before it submits /signup, so its referral
// response can say user_exists for a brand-new account. The desktop client uses
// this authenticated endpoint instead; always verify by reading the profile back.
export async function ensureReferralAssociation({
  accessToken, referralCode, dubClickId = null, checkCredits = false, fetch: fetcher = fetch, timeout = 15000,
} = {}) {
  const before = await fetchReferralStatus({ accessToken, fetch: fetcher, timeout });
  if (hasReferral(before.body)) {
    return { associated: true, applied: false, status: before.body, http: before.status };
  }
  const applied = await applyReferralCode({
    accessToken, referralCode, dubClickId, checkCredits, fetch: fetcher, timeout,
  });
  const after = await fetchReferralStatus({ accessToken, fetch: fetcher, timeout });
  return {
    associated: hasReferral(after.body),
    applied: applied.ok,
    applyHttp: applied.status,
    applyBody: applied.body,
    status: after.body,
    http: after.status,
  };
}
