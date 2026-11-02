import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import { readJson, writeJson, withFileLock } from './file-state.mjs';

export const MAILDROP_INBOX_QUERY = 'query Inbox($mailbox: String!) { inbox(mailbox: $mailbox) { id headerfrom subject date } }';
export const MAILDROP_MESSAGE_QUERY = 'query Message($mailbox: String!, $id: String!) { message(mailbox: $mailbox, id: $id) { id headerfrom subject date rcptto data html } }';
const memoryLimits = {};

export function createMaildropInbox() {
  const mailbox = 'flow' + randomUUID().replaceAll('-', '');
  return { mailProvider: 'maildrop', mailbox, email: mailbox + '@maildrop.cc', password: 'FlowTest2026!', inboxCreated: true };
}

// Maildrop recommends mailbox polling at most once every ten seconds.
export async function maildropQuery(query, variables, options = {}) {
  const fetcher = options.fetch ?? fetch, pause = options.sleep ?? sleep, now = options.now ?? Date.now;
  const path = options.dataDir ? options.dataDir + '/maildrop-rate-limits.json' : null;
  const request = async () => {
    for (let attempt = 0; attempt < 4; attempt++) {
      const limits = path ? await readJson(path, {}) : memoryLimits;
      const bucket = options.inbox ? 'inbox:' + variables.mailbox : 'message';
      await pause(Math.max(0, (limits.api ?? 0) - now(), (limits[bucket] ?? 0) - now()));
      const response = await fetcher('https://api.maildrop.cc/graphql', {
        method: 'POST', headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify({ query, variables }), signal: AbortSignal.timeout(15000),
      });
      limits.api = now() + 1000;
      if (options.inbox) limits[bucket] = now() + 10000;
      if (path) await writeJson(path, limits);
      if (response.status === 429 && attempt < 3) {
        const raw = response.headers.get('retry-after');
        const seconds = raw && /^\d+$/.test(raw) ? Number(raw) : raw ? (Date.parse(raw) - now()) / 1000 : 10;
        if (!Number.isFinite(seconds) || seconds > 300) throw new Error('Maildrop rate limited; retry later');
        console.log('RATE_LIMIT:Maildrop cooldown ' + Math.max(10, Math.ceil(seconds)) + 's');
        await response.text();
        await pause(Math.max(10, seconds) * 1000);
        continue;
      }
      if (!response.ok) throw new Error('Maildrop HTTP ' + response.status);
      const result = await response.json();
      if (result.errors?.length) throw new Error('Maildrop GraphQL: ' + result.errors.map(e => e.message).join('; '));
      if (!result.data) throw new Error('Maildrop returned no data');
      return result.data;
    }
  };
  return path ? withFileLock(path + '.lock', request) : request();
}

export function decodeMaildropMessage(message, expectedEmail) {
  const parsed = spawnSync('/usr/bin/python3', [fileURLToPath(new URL('./parse-maildrop-email.py', import.meta.url))], {
    input: JSON.stringify({ ...message, expectedEmail }), encoding: 'utf8', timeout: 5000, maxBuffer: 2 * 1024 * 1024,
  });
  if (parsed.error || parsed.status !== 0) throw new Error('Cannot decode Maildrop verification message');
  return { id: message.id, subject: message.subject, createdAt: message.date, ...JSON.parse(parsed.stdout) };
}

export async function readMaildrop(inbox, path, options = {}) {
  const mailbox = inbox.mailbox || inbox.email.split('@')[0];
  if (path === '/messages') {
    const data = await maildropQuery(MAILDROP_INBOX_QUERY, { mailbox }, { ...options, inbox: true });
    return { 'hydra:member': data.inbox ?? [], 'hydra:totalItems': data.inbox?.length ?? 0 };
  }
  const id = path.slice('/messages/'.length);
  const data = await maildropQuery(MAILDROP_MESSAGE_QUERY, { mailbox, id }, options);
  if (!data.message) throw new Error('Maildrop message expired; refresh the inbox');
  return decodeMaildropMessage(data.message, inbox.email);
}
