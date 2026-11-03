import { mkdir, unlink, rename } from 'node:fs/promises';
import { setTimeout as sleep } from 'node:timers/promises';
import { appendFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { readJson, writeJson, withFileLock } from './file-state.mjs';
import { createMaildropInbox, readMaildrop } from './maildrop.mjs';
import { referralDecision, referralBlocked, REFERRAL_REVIEW_MESSAGE } from './referral-status.mjs';
import { ensureReferralAssociation } from './referral-apply.mjs';
export { readJson, writeJson } from './file-state.mjs';

export const AUTH_KEY = 'sb-dodjkfqhwrzqjwkfnthl-auth-token';
let progressFile;
export const log = (stage, message) => {
  const line = `${stage}:${message}`;
  console.log(line);
  if (progressFile) appendFileSync(progressFile, new Date().toISOString() + ' ' + line + '\n', { mode: 0o600 });
};
let rateLimitFile;
const mailLimits = {};

// Pace every request, and honor the server's cooldown instead of making new inboxes.
export async function mailRequest(path, options = {}, deps = {}) {
  if (rateLimitFile) return withFileLock(rateLimitFile + '.lock', () => mailRequestUnlocked(path, options, deps));
  return mailRequestUnlocked(path, options, deps);
}

async function mailRequestUnlocked(path, options = {}, deps = {}) {
  const fetcher = deps.fetch ?? fetch;
  const pause = deps.sleep ?? sleep;
  const now = deps.now ?? Date.now;
  const bucket = (options.method ?? 'GET') === 'GET' ? 'GET' : `${options.method}:${path}`;
  for (let attempt = 0; attempt < 4; attempt++) {
    const limits = rateLimitFile ? await readJson(rateLimitFile, {}) : mailLimits;
    let delay = Math.max(1000, (limits[bucket] ?? 0) - now());
    if (delay > 3000) log('RATE_LIMIT', `mail.tm ${bucket}: waiting ${Math.ceil(delay / 1000)}s before request`);
    while (delay > 0) { await pause(Math.min(delay, 20000)); delay -= 20000; }
    const response = await fetcher('https://api.mail.tm' + path, {
      method: options.method ?? 'GET',
      headers: { 'Content-Type': 'application/json', ...(options.token ? { Authorization: 'Bearer ' + options.token } : {}) },
      ...(options.body ? { body: JSON.stringify(options.body) } : {}),
      signal: AbortSignal.timeout(15000),
    });
    const policy = response.headers.get('ratelimit-policy')?.match(/(\d+)\s*;\s*w=(\d+)/);
    if (policy && Number(policy[1]) > 0) {
      limits[bucket] = now() + Math.ceil(Number(policy[2]) * 1000 / Number(policy[1]));
      if (rateLimitFile) await writeJson(rateLimitFile, limits);
    }
    if (response.status === 429 && attempt < 3) {
      const retry = response.headers.get('retry-after');
      const seconds = retry && /^\d+(\.\d+)?$/.test(retry) ? Number(retry)
        : retry ? Math.max(1, (Date.parse(retry) - Date.now()) / 1000) : 60;
      if (!Number.isFinite(seconds) || seconds > 300) throw new Error('mail.tm rate limited; retry later: ' + retry);
      log('RATE_LIMIT', `mail.tm ${options.method ?? 'GET'} ${path}: waiting ${Math.ceil(seconds)}s (retry ${attempt + 1}/3)`);
      await response.text();
      for (let remaining = Math.ceil(seconds); remaining > 0; remaining -= 20) {
        await pause(Math.min(remaining, 20) * 1000);
        if (remaining > 20) log('RATE_LIMIT', `cooldown: ${remaining - 20}s remaining`);
      }
      continue;
    }
    if (!response.ok) {
      const error = new Error(`mail.tm ${options.method ?? 'GET'} ${path}: HTTP ${response.status} ${await response.text()}`);
      error.status = response.status;
      throw error;
    }
    return response.json();
  }
}

export async function pageState(page) {
  return page.evaluate(() => {
    const visible = e => !!e?.getClientRects().length && getComputedStyle(e).visibility !== 'hidden';
    return {
      url: location.href,
      password: [...document.querySelectorAll('input[type="password"]')].some(visible),
      name: [...document.querySelectorAll('input[name="Full-name"]')].some(visible),
      checkEmail: /check your (email|inbox)|verify your email|enter.{0,40}code/i.test(document.body?.innerText ?? ''),
      turnstile: document.querySelector('[name="cf-turnstile-response"]')?.value.length ?? null,
      captcha: [...document.querySelectorAll('iframe[src*="hcaptcha"]')].some(visible),
      captchaSolved: !!document.querySelector('[name="h-captcha-response"]')?.value,
      errors: [...document.querySelectorAll('[role="alert"], .error-message, .w-form-fail')].filter(visible).map(e => e.innerText).join('; '),
    };
  });
}

async function fill(page, selector, value) {
  try { await page.fill(selector, value); }
  catch (error) {
    // Some ego versions report a visibility error after the input was filled.
    if (!await page.evaluate(({ selector, value }) => {
      const [css, nth] = selector.split(' >> nth=');
      const fields = [...document.querySelectorAll(css)];
      return (nth === undefined ? fields : [fields[Number(nth)]]).some(e => e?.value === value);
    }, { selector, value })) throw error;
  }
}

export async function dismissPrivacy(page) {
  const snapshot = await page.snapshot({ scope: 'full_page' });
  const deny = snapshot.match(/button "Deny" \[ref=(\d+)/)?.[1];
  if (!deny) return false;
  await page.click('@' + deny, { label: 'dismiss privacy dialog' });
  return true;
}

async function clickWithPrivacy(page, selector, label) {
  await dismissPrivacy(page);
  try { return await page.click(selector, { label }); }
  catch (error) {
    if (!/usercentrics|intercepts pointer events/i.test(error.message) || !await dismissPrivacy(page)) throw error;
    return page.click(selector, { label });
  }
}

export async function submit(page) {
  await clickWithPrivacy(page, '#email-form input[type="submit"], #email-form button[type="submit"]', 'continue account form');
}

export async function enterEmail(page, email) {
  await dismissPrivacy(page);
  await fill(page, '#email-form input[name="email"]', email);
  log('STAGE', 'Waiting for email verification widget');
  await page.waitForFunction(() => {
    const token = document.querySelector('[name="cf-turnstile-response"]');
    return !token || token.value.length > 0;
  }, undefined, { timeout: 20000 });
  await submit(page);
  await page.waitForSelector('input[type="password"]', { state: 'visible', timeout: 15000 });
  log('STAGE', 'Password form ready');
}

export async function enterPassword(page, password) {
  await fill(page, 'input[name="Password"]', password);
  if ((await pageState(page)).name) await fill(page, 'input[name="Full-name"]', 'Alex Rivera');
}

export async function captchaReady(page) {
  await dismissPrivacy(page);
  const state = await pageState(page);
  if (!state.captcha || state.captchaSolved) return true;
  const snap = await page.snapshot({ scope: 'full_page' });
  const checkbox = snap.match(/checkbox .*?\[ref=(\d+)/)?.[1];
  if (checkbox) await page.click('@' + checkbox, { label: 'check human verification' });
  try {
    await page.waitForFunction(() => !!document.querySelector('[name="h-captcha-response"]')?.value, undefined, { timeout: 8000 });
    return true;
  } catch { return false; }
}

export async function authToken(page, email) {
  const stored = await page.evaluate(key => {
    if (location.origin !== 'https://wisprflow.ai') return {};
    const cookies = {};
    for (const part of document.cookie.split(/;\s*/)) {
      const i = part.indexOf('='), name = part.slice(0, i);
      if (['access_token', 'refresh_token'].includes(name)) cookies[name] = decodeURIComponent(part.slice(i + 1));
    }
    return { legacy: localStorage.getItem(key), access: cookies.access_token, refresh: cookies.refresh_token };
  }, AUTH_KEY);
  const workos = workosSession(stored.access, stored.refresh, email);
  if (workos) return JSON.stringify(workos);
  let legacy = null;
  try { legacy = JSON.parse(stored.legacy); } catch {}
  if (legacy?.user?.email?.toLowerCase() === email.toLowerCase() && legacy.access_token && legacy.expires_at * 1000 > Date.now() + 60000) return stored.legacy;
  // Older accounts use Supabase cookies. The token cookie can outlive the
  // localStorage copy, so recover the session from the signed JWT claims.
  try {
    const claims = JSON.parse(Buffer.from(stored.access.split('.')[1], 'base64url').toString());
    if (claims.email?.toLowerCase() === email.toLowerCase() && Number.isFinite(claims.exp) && claims.exp * 1000 > Date.now() + 60000) {
      return JSON.stringify({
        provider: 'supabase',
        access_token: stored.access,
        refresh_token: legacy?.refresh_token || stored.refresh || null,
        expires_at: claims.exp,
        token_type: 'bearer',
        user: { id: claims.sub, email: claims.email },
      });
    }
  } catch {}
  return null;
}

export function workosSession(access, refresh, email) {
  if (!access || !refresh) return null;
  try {
    const claims = JSON.parse(Buffer.from(access.split('.')[1], 'base64url').toString());
    if (claims.email?.toLowerCase() !== email.toLowerCase() || !claims['urn:wispr:user_external_id'] || !Number.isFinite(claims.exp) || claims.exp * 1000 <= Date.now() + 60000) return null;
    return { provider: 'workos', access_token: access, refresh_token: refresh, expires_at: claims.exp,
      token_type: 'bearer', user: { id: claims['urn:wispr:user_external_id'], email: claims.email }, client_id: claims.client_id };
  } catch { return null; }
}

export async function refreshWorkosSession(session, fetcher = fetch) {
  if (session.provider !== 'workos' || !session.refresh_token || !session.client_id) throw new Error('No refreshable WorkOS session');
  const response = await fetcher('https://api.workos.com/user_management/authenticate', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ grant_type: 'refresh_token', client_id: session.client_id, refresh_token: session.refresh_token }),
    signal: AbortSignal.timeout(15000),
  });
  if (!response.ok) throw new Error('WorkOS refresh failed: HTTP ' + response.status);
  const result = await response.json();
  const updated = workosSession(result.access_token, result.refresh_token, session.user.email);
  if (!updated || updated.user.id !== session.user.id) throw new Error('Refreshed session changed account identity');
  return updated;
}

async function clearOtherWisprSession(page, email) {
  if (await authToken(page, email)) return false;
  let removed = await page.evaluate(key => {
    let removed = false;
    for (const item of [key, 'email', 'user_id', 'signin_provider', 'last_authed_provider']) {
      if (localStorage.getItem(item)) removed = true;
      localStorage.removeItem(item);
    }
    return removed;
  }, AUTH_KEY);
  const { cookies } = await page.cdp('Network.getCookies', { urls: ['https://wisprflow.ai'] });
  for (const cookie of cookies.filter(c => ['access_token', 'refresh_token'].includes(c.name))) {
    await page.cdp('Network.deleteCookies', { name: cookie.name, domain: cookie.domain, path: cookie.path });
    removed = true;
  }
  if (removed) {
    log('STAGE', 'Cleared the previous Wispr web sign-in (only Wispr auth cookies and identity keys)');
    await page.reload();
  }
  return removed;
}

export function verificationLink(message) {
  const html = Array.isArray(message.html) ? message.html.join('\n') : message.html || message.text || '';
  const urls = [...html.matchAll(/https:\/\/auth\.wisprflow\.com\/[^"'\s<>]+/g)].map(m => m[0].replace(/&amp;/g, '&'));
  return urls.find(url => url.includes('verify'));
}

export function verificationCode(message) {
  const text = message.text || (Array.isArray(message.html) ? message.html.join('\n') : message.html || '').replace(/<[^>]*>/g, ' ');
  return text.match(/\b\d{6}\b/)?.[0];
}

export function isWisprVerification(message, email) {
  const sender = message.from?.address?.toLowerCase() ?? '';
  const domain = sender.split('@')[1] ?? '';
  const trusted = ['wispr.ai', 'wisprflow.ai', 'wisprflow.com'].some(d => domain === d || domain.endsWith('.' + d));
  return trusted && message.to?.some(to => to.address?.toLowerCase() === email.toLowerCase())
    && /verif|confirm.*email/i.test(message.subject ?? '');
}

async function enterVerificationCode(page, code) {
  await dismissPrivacy(page);
  const inputs = await page.evaluate(() => [...document.querySelectorAll('input')].map((e, index) => ({
    index, type: e.type, visible: !!e.getClientRects().length,
  })).filter(e => e.visible && ['text', 'tel', 'number'].includes(e.type)));
  if (inputs.length !== 1 && inputs.length !== code.length) throw new Error('Cannot identify the email code fields');
  for (let i = 0; i < inputs.length; i++) {
    await fill(page, 'input >> nth=' + inputs[i].index, inputs.length === 1 ? code : code[i]);
  }
  if (await page.evaluate(() => !!document.querySelector('a[aria-label="Verify"]')?.getClientRects().length)) {
    await clickWithPrivacy(page, 'a[aria-label="Verify"]', 'verify email code');
  }
}

async function saveAccount(config, verified) {
  const path = config.dataDir + '/accounts.json';
  const accounts = await readJson(path, []);
  let account = accounts.find(a => a.email === config.email);
  if (!account) { account = { index: config.index ?? 1, email: config.email, password: config.password, referralCode: config.referralCode, createdAt: new Date().toISOString() }; accounts.push(account); }
  account.verified = verified;
  if (typeof config.referralAssociated === 'boolean') account.referralAssociated = config.referralAssociated;
  if (config.referralStatus) account.referralStatus = config.referralStatus;
  if (config.referralAppliedVia) account.referralAppliedVia = config.referralAppliedVia;
  if (config.referralRecoveredAt) account.referralRecoveredAt = config.referralRecoveredAt;
  await writeJson(path, accounts);
}

export async function hasSignupHistory(dataDir, email) {
  const normalized = String(email).trim().toLowerCase();
  const records = [...await readJson(dataDir + '/accounts.json', []), ...await readJson(dataDir + '/completions.json', [])];
  return records.some(record => String(record.email ?? '').trim().toLowerCase() === normalized);
}

// Wispr's downloads page schedules navigation through these marked anchors.
// Remove only its auto-download marker; preserve the ordinary manual links.
export function preventInstallerAutoDownloads() {
  if (window.__wisprInstallerGuard) return;
  window.__wisprInstallerGuard = true;
  const suppress = () => {
    for (const element of document.querySelectorAll('[active-download]')) {
      element.setAttribute('data-wispr-download-suppressed', element.getAttribute('active-download'));
      element.removeAttribute('active-download');
    }
  };
  new MutationObserver(suppress).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['active-download'] });
  suppress();
}

export async function installPageGuards(page) {
  const source = `if (location.origin === 'https://wisprflow.ai') { (${preventInstallerAutoDownloads.toString()})(); (${observeSignupSync.toString()})(); }`;
  await page.cdp('Page.addScriptToEvaluateOnNewDocument', { source });
  await page.evaluate(source);
}

// Observe the site's own signup response; do not race it with desktop API calls.
export function observeSignupSync() {
  if (window.location.origin !== 'https://wisprflow.ai' || window.__wisprSignupObserver) return;
  window.__wisprSignupObserver = true;
  const traceKey = 'wispr-test-signup-trace';
  let trace = [];
  try { trace = JSON.parse(sessionStorage.getItem(traceKey) || '[]'); } catch {}
  if (!Array.isArray(trace)) trace = [];
  window.__wisprSignupTrace = trace;
  const original = window.fetch;
  window.fetch = async function(input, options) {
    let requestUrl, request = {};
    try {
      requestUrl = new URL(typeof input === 'string' ? input : input.url, window.location.href);
      request = JSON.parse(options?.body || '{}');
    } catch {}
    const observed = requestUrl?.origin === 'https://api.wisprflow.ai'
      && ['/user_status', '/email/signup-captcha', '/email/verify-email-otp', '/email/resend-verification-email', '/email/resend-verification-email-captcha', '/signup'].includes(requestUrl.pathname);
    let event;
    if (observed) {
      let redirectReferral = null;
      try { redirectReferral = new URL(request.redirect_url).searchParams.get('referral'); } catch {}
      event = { path: requestUrl.pathname, startedAt: new Date().toISOString(),
        referralCode: request.referral || redirectReferral,
        ...(typeof request.should_complete_signup === 'boolean' ? { shouldCompleteSignup: request.should_complete_signup } : {}) };
    }
    const response = await original.call(this, input, options);
    try {
      if (event) {
        event.http = response.status;
        event.finishedAt = new Date().toISOString();
        trace.push(event);
        if (trace.length > 32) trace.shift();
        try { sessionStorage.setItem(traceKey, JSON.stringify(trace)); } catch {}
      }
      if (requestUrl?.origin === 'https://api.wisprflow.ai' && requestUrl.pathname === '/signup') {
        const body = await response.clone().json();
        let email = null;
        try { email = JSON.parse(atob(request.access_token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))).email; } catch {}
        window.__wisprSignupSync = { status: response.status, referralCode: request.referral,
          email, referralStatus: body.referral_status ?? null, requestTrace: trace.slice() };
      }
    } catch { /* Preserve the site's fetch behavior even if its response changes. */ }
    return response;
  };
}

export function inboxProvider(inbox) {
  return inbox.mailProvider || (String(inbox.email).toLowerCase().endsWith('@maildrop.cc') ? 'maildrop' : 'mail.tm');
}

async function createInbox(checkpoint, provider = 'maildrop') {
  if (provider === 'maildrop') {
    const inbox = createMaildropInbox();
    if (checkpoint) await checkpoint(inbox);
    return inbox;
  }
  if (provider !== 'mail.tm') throw new Error('Unknown mail provider: ' + provider);
  const domains = await mailRequest('/domains');
  const domain = domains['hydra:member'].find(d => d.isActive && !d.isPrivate)?.domain;
  if (!domain) throw new Error('mail.tm returned no active public domain');
  const inbox = { mailProvider: 'mail.tm', email: 'flow' + randomUUID().replaceAll('-', '') + '@' + domain, password: 'FlowTest2026!' };
  if (checkpoint) await checkpoint({ ...inbox, inboxCreated: false });
  return completeInbox(inbox, checkpoint);
}

async function completeInbox(inbox, checkpoint) {
  if (inboxProvider(inbox) === 'maildrop') return { ...inbox, mailProvider: 'maildrop', mailbox: inbox.mailbox || inbox.email.split('@')[0], inboxCreated: true };
  if (inbox.mailToken) return { ...inbox, inboxCreated: true };
  if (!inbox.inboxCreated) {
    try {
      inbox.mailToken = (await mailRequest('/token', { method: 'POST', body: { address: inbox.email, password: inbox.password } })).token;
      if (inbox.mailToken) return { ...inbox, inboxCreated: true };
    } catch (error) { if (error.status !== 401) throw error; }
    await mailRequest('/accounts', { method: 'POST', body: { address: inbox.email, password: inbox.password } });
    inbox.inboxCreated = true;
    if (checkpoint) await checkpoint(inbox);
  }
  inbox.mailToken = (await mailRequest('/token', { method: 'POST', body: { address: inbox.email, password: inbox.password } })).token;
  if (!inbox.mailToken) throw new Error('mail.tm did not return an inbox token');
  return inbox;
}

export async function prepareInbox(dataDir, create = createInbox, provider) {
  await mkdir(dataDir, { recursive: true });
  rateLimitFile = dataDir + '/mail-rate-limits.json';
  progressFile = dataDir + '/signup-progress.log';
  return withFileLock(dataDir + '/inbox.lock', async () => {
    const readyPath = dataDir + '/next-inbox.json';
    const pendingPath = dataDir + '/preparing-inbox.json';
    let inbox;
    for (const path of [readyPath, pendingPath]) {
      const candidate = await readJson(path);
      if (!candidate) continue;
      if ((provider && inboxProvider(candidate) !== provider) || await hasSignupHistory(dataDir, candidate.email)) {
        log('STALE_INBOX', 'Discarding a used mailbox or one from a different provider: ' + candidate.email);
        await unlink(path);
      } else { inbox = candidate; break; }
    }
    if (!inbox) inbox = await create(value => writeJson(pendingPath, value), provider);
    if (await hasSignupHistory(dataDir, inbox.email)) throw new Error('Refusing to prepare a previously used signup email');
    inbox = await completeInbox(inbox, value => writeJson(pendingPath, value));
    await writeJson(readyPath, inbox);
    await unlink(pendingPath).catch(error => { if (error.code !== 'ENOENT') throw error; });
    log('NEXT_INBOX', inbox.email);
    return inbox;
  });
}

export async function takeFreshInbox(dataDir, checkpoint, create = createInbox, provider) {
  return withFileLock(dataDir + '/inbox.lock', async () => {
    const readyPath = dataDir + '/next-inbox.json';
    const claimedPath = dataDir + '/claimed-inbox.json';
    let inbox;
    for (const path of [claimedPath, readyPath]) {
      const candidate = await readJson(path);
      if (!candidate) continue;
      if ((provider && inboxProvider(candidate) !== provider) || await hasSignupHistory(dataDir, candidate.email)) {
        log('STALE_INBOX', 'Discarding a used mailbox or one from a different provider: ' + candidate.email);
        await unlink(path);
        continue;
      }
      if (path === readyPath) await rename(readyPath, claimedPath);
      inbox = candidate;
      break;
    }
    if (!inbox) inbox = await create(checkpoint, provider);
    if (await hasSignupHistory(dataDir, inbox.email)) throw new Error('Refusing to reuse an email for a new signup');
    await checkpoint(inbox);
    await unlink(claimedPath).catch(error => { if (error.code !== 'ENOENT') throw error; });
    return inbox;
  });
}

export async function runSignup(config, task) {
  await mkdir(config.dataDir, { recursive: true });
  rateLimitFile = config.dataDir + '/mail-rate-limits.json';
  progressFile = config.dataDir + '/signup-progress.log';
  const pendingPath = config.dataDir + '/pending-signup.json';
  const saved = await readJson(pendingPath);
  if (referralBlocked(saved, config)) {
    log('ERROR', REFERRAL_REVIEW_MESSAGE);
    return 76;
  }
  const page = task.page('p1');
  config.taskSpaceId = task.spaceId;
  config.taskSpace = task.name;
  config.completed = false;
  const finish = async () => {
    const token = await authToken(page, config.email);
    if (!token) throw new Error('The authenticated session does not match the new email');
    const session = JSON.parse(token);
    await saveAccount(config, true);
    config.verified = true;
    await writeJson(config.dataDir + '/last-web-token.json', session);
    await writeJson(pendingPath, config);
    if (config.requireReferral) {
      log('STAGE', 'Waiting for the website to confirm signup and referral status');
      let sync = null;
      let websiteReferralStatus = null;
      let websiteDecision = null;
      let syncError = null;
      try {
        try { await page.waitForFunction(() => !!window.__wisprSignupSync, undefined, { timeout: 20000 }); }
        catch (error) {
          if (!config.resume || !String(await page.url()).includes('/downloads')) throw error;
          await page.reload();
          await page.waitForFunction(() => !!window.__wisprSignupSync, undefined, { timeout: 20000 });
        }
        sync = await page.evaluate(() => window.__wisprSignupSync);
        if (sync.status !== 200 || sync.referralCode !== config.referralCode || !sync.email || sync.email.toLowerCase() !== config.email.toLowerCase()) {
          throw new Error('Website signup/referral response does not match the requested account/code');
        }
        websiteReferralStatus = sync.referralStatus;
        websiteDecision = referralDecision(websiteReferralStatus);
        config.signupSynced = true;
        config.referralStatus = websiteReferralStatus;
        config.referralAssociated = websiteDecision === 'associated';
        config.phase = websiteDecision === 'rejected' ? 'referral_rejected' : websiteDecision === 'associated' ? 'referral_associated' : 'referral_unconfirmed';
        config.retryable = websiteDecision !== 'rejected';
        if (websiteDecision === 'rejected') config.failureReason = websiteReferralStatus?.message || 'Referral rejected';
        log('REFERRAL', JSON.stringify(websiteReferralStatus));
      } catch (error) {
        syncError = error.message;
        log('REFERRAL_SYNC', 'Website signup response unavailable: ' + error.message);
        if (!config.phase) config.phase = 'referral_unconfirmed';
        config.retryable = true;
      }
      let recovery = null;
      if (!config.referralAssociated) {
        log('STAGE', 'Applying referral through the desktop API');
        try {
          recovery = await ensureReferralAssociation({
            accessToken: session.access_token,
            referralCode: config.referralCode,
          });
          if (recovery.associated) {
            config.referralAssociated = true;
            config.signupSynced = true;
            config.phase = 'referral_associated';
            config.retryable = false;
            config.referralAppliedVia = 'desktop-api';
            config.referralStatus = {
              ...(websiteReferralStatus ?? { referral_code_valid: true }),
              referral_applied: true,
              ...(recovery.status?.referer_name ? { referer_name: recovery.status.referer_name } : {}),
              message: 'Referral associated through the desktop referral API.',
            };
            delete config.failureReason;
            log('REFERRAL_APPLY', JSON.stringify(recovery.status));
          } else {
            log('REFERRAL_APPLY', 'Desktop API did not confirm an association: ' + JSON.stringify(recovery.status ?? recovery));
          }
        } catch (error) {
          recovery = { associated: false, error: error.message };
          log('REFERRAL_APPLY', 'Desktop API failed: ' + error.message);
        }
      }
      const finalDecision = config.referralStatus ? referralDecision(config.referralStatus) : 'unconfirmed';
      await writeJson(config.dataDir + '/referral-diagnostic.json', {
        capturedAt: new Date().toISOString(), email: config.email, referralCode: config.referralCode,
        http: sync?.status ?? null,
        decision: websiteDecision,
        referralStatus: websiteReferralStatus,
        requestTrace: sync?.requestTrace || [],
        syncError,
        desktopRecovery: recovery ? {
          associated: recovery.associated,
          applied: recovery.applied,
          applyHttp: recovery.applyHttp,
          applyBody: recovery.applyBody,
          status: recovery.status,
          error: recovery.error,
        } : null,
        finalDecision,
        limit: 'The server response alone does not identify why the account was classified as existing. IP attribution and a server ordering defect are unproven; preserve both website and desktop results for Wispr support.',
      });
      await writeJson(pendingPath, config);
      await saveAccount(config, true);
      if (!config.referralAssociated) {
        log('ERROR', 'Wispr did not apply the referral: ' + (config.referralStatus?.message || syncError || 'association unconfirmed'));
        log('NEXT', finalDecision === 'rejected' ? REFERRAL_REVIEW_MESSAGE : 'Referral is unconfirmed. Preserve this account for investigation.');
        return finalDecision === 'rejected' ? 76 : 1;
      }
      log('REFERRAL_ASSOCIATED', JSON.stringify(config.referralStatus));
    }
    log('VERIFIED', 'true');
    return 0;
  };
  const pause = async reason => {
    await saveAccount(config, false);
    await writeJson(pendingPath, config);
    log('HANDOFF', `${reason}. Complete it in ego lite, then run: ./wispr-resume ${task.spaceId}`);
    await task.handOff();
    return 75;
  };
  try {
    if (!config.resume && config.email && await hasSignupHistory(config.dataDir, config.email)) {
      log('ERROR', 'This email was already assigned to a signup. Start with a fresh mailbox.');
      return 1;
    }
    if (config.fresh && !config.resume) {
      const previous = await readJson(pendingPath);
      if (previous && !previous.completed) {
        await mkdir(config.dataDir + '/archived-signups', { recursive: true, mode: 0o700 });
        await writeJson(config.dataDir + '/archived-signups/' + Date.now() + '-' + randomUUID() + '.json', previous);
        log('NEW_SIGNUP', 'Previous attempt archived; using a new, unused mailbox.');
      }
    }
    if (!config.email) {
      log('STAGE', 'Preparing ' + (config.mailProvider || 'maildrop') + ' inbox');
      Object.assign(config, await takeFreshInbox(config.dataDir, value => { Object.assign(config, value); return writeJson(pendingPath, config); }, undefined, config.mailProvider || 'maildrop'));
    }
    config.mailProvider = inboxProvider(config);
    await installPageGuards(page);
    log(config.resume ? 'VERIFY_RESUME' : 'NEW_SIGNUP', config.email);
    log('EMAIL', config.email);
    if (config.resume && await authToken(page, config.email)) return await finish();
    if (config.resume && config.verified) {
      throw new Error('This account is already registered. Use login/desktop continuation; a new signup requires a fresh email.');
    }
    if (!config.mailToken) Object.assign(config, await completeInbox(config, value => writeJson(pendingPath, { ...config, ...value })));
    if (config.mailProvider === 'mail.tm' && !config.mailToken) throw new Error('mail.tm did not return an inbox token');
    await writeJson(pendingPath, config);
    await saveAccount(config, false);
    const initial = await pageState(page);
    if (config.resume && (config.signupSubmittedAt || config.otpRequestedAt) && !initial.checkEmail) {
      throw new Error('The submitted signup verification page is unavailable. Use --fresh for a new signup instead of registering this email again.');
    }
    if (!config.resume || (!initial.password && !initial.checkEmail)) {
      // Reset before opening the invitation: an old login can otherwise redirect
      // straight to downloads and submit /signup for the previous account.
      await page.cdp('Storage.clearDataForOrigin', { origin: 'https://wisprflow.ai', storageTypes: 'cookies,local_storage' });
      await page.evaluate(() => {
        if (location.origin !== 'https://wisprflow.ai') return;
        sessionStorage.removeItem('wispr-test-signup-trace');
        window.__wisprSignupTrace?.splice(0);
      });
      log('STAGE', 'Previous Wispr web session cleared before opening a new signup');
      log('STAGE', 'Opening referral signup');
      const signupUrl = 'https://wisprflow.ai/r?' + encodeURIComponent(config.referralCode);
      await page.goto(signupUrl);
    }
    let state = await pageState(page);
    if (!state.password && !state.checkEmail) {
      try { await enterEmail(page, config.email); }
      catch (error) {
        state = await pageState(page);
        if (state.turnstile === 0) return await pause('Cloudflare verification needs attention');
        throw error;
      }
    }
    state = await pageState(page);
    if (state.password && !state.checkEmail) {
      await enterPassword(page, config.password);
      if (!await captchaReady(page)) return await pause('hCaptcha needs a human');
      config.signupSubmittedAt = Date.now();
      await writeJson(pendingPath, config);
      await submit(page);
      config.otpRequestedAt = Date.now();
      await writeJson(pendingPath, config);
      await page.waitForFunction(() => /check your (email|inbox)|verify your email|enter.{0,40}code/i.test(document.body?.innerText ?? ''), undefined, { timeout: 15000 });
    }
    log('STAGE', 'Signup submitted; waiting for verification email');
    let link, code;
    let waitStarted = Date.now();
    const waitSeconds = config.mailWaitSeconds || (config.mailProvider === 'maildrop' ? 960 : 120);
    let deadline = waitStarted + waitSeconds * 1000;
    let resent = false;
    const inboxRequest = async path => {
      if (config.mailProvider === 'maildrop') return readMaildrop(config, path, { dataDir: config.dataDir });
      try { return await mailRequest(path, { token: config.mailToken }); }
      catch (error) {
        if (error.status !== 401) throw error;
        config.mailToken = (await mailRequest('/token', { method: 'POST', body: { address: config.email, password: config.password } })).token;
        await writeJson(pendingPath, config);
        return mailRequest(path, { token: config.mailToken });
      }
    };
    while (Date.now() < deadline && !link && !code) {
      const inbox = await inboxRequest('/messages');
      log('INBOX', `${config.mailProvider}: ${inbox['hydra:member']?.length ?? 0} messages; elapsed ${Math.floor((Date.now() - waitStarted) / 1000)}s/${waitSeconds}s`);
      let expired = false;
      for (const message of (inbox['hydra:member'] ?? []).slice(0, 5)) {
        const body = await inboxRequest('/messages/' + message.id);
        if (!isWisprVerification(body, config.email)) continue;
        const received = Date.parse(body.sentAt || body.createdAt);
        if (Number.isFinite(received) && (received < Date.now() - 14 * 60000 || received < (config.otpRequestedAt ?? 0) - 10000)) { expired = true; continue; }
        link = verificationLink(body);
        code = verificationCode(body);
        if (link || code) break;
      }
      if (!link && !code && expired && !resent) {
        log('STAGE', 'Verification email expired; requesting one new code');
        await page.click('text="Resend code"', { label: 'request fresh verification code' });
        config.otpRequestedAt = Date.now();
        await writeJson(pendingPath, config);
        resent = true;
        waitStarted = Date.now();
        deadline = waitStarted + Math.max(90000, waitSeconds * 1000);
      }
      if (!link && !code) { log('STAGE', 'Waiting for ' + config.mailProvider + ' verification message'); await sleep(config.mailProvider === 'maildrop' ? 10000 : 5000); }
    }
    if (!link && !code) throw new Error('No verification email within ' + waitSeconds + 's; inbox saved for ./wispr-resume');
    if (link) await page.goto(link);
    else {
      log('STAGE', 'Entering email verification code');
      await enterVerificationCode(page, code);
    }
    await page.waitForFunction(({ key, email }) => {
      if (localStorage.getItem('email')?.toLowerCase() === email.toLowerCase() && /(?:^|; )access_token=/.test(document.cookie)) return true;
      try { return JSON.parse(localStorage.getItem(key))?.user?.email?.toLowerCase() === email.toLowerCase(); } catch { return false; }
    }, { key: AUTH_KEY, email: config.email }, { timeout: 20000 });
    return await finish();
  } catch (error) {
    if (/intercepts pointer events/i.test(error.message) && !config.otpRequestedAt) delete config.signupSubmittedAt;
    log('ERROR', error.message);
    log('STATE', JSON.stringify(await pageState(page).catch(() => ({}))));
    log('VERIFIED', String(!!config.verified));
    // Errors preserve agent control; only a real human challenge hands it back.
    await writeJson(pendingPath, config);
    log('RESUME', `Inbox/page saved. Retry the same signup: ./wispr-resume ${task.spaceId}`);
    return 1;
  }
}

export async function login(page, email, password) {
  await installPageGuards(page);
  if (await authToken(page, email)) return await authToken(page, email);
  await page.goto('https://wisprflow.ai/login');
  if (await clearOtherWisprSession(page, email)) await page.goto('https://wisprflow.ai/login');
  await enterEmail(page, email);
  await enterPassword(page, password);
  if (!await captchaReady(page)) throw new Error('Login hCaptcha requires a human');
  await submit(page);
  await page.waitForFunction(({ key, email }) => {
    if (localStorage.getItem('email')?.toLowerCase() === email.toLowerCase() && /(?:^|; )access_token=/.test(document.cookie)) return true;
    try { return JSON.parse(localStorage.getItem(key))?.user?.email?.toLowerCase() === email.toLowerCase(); }
    catch { return false; }
  }, { key: AUTH_KEY, email }, { timeout: 20000 });
  return authToken(page, email);
}
