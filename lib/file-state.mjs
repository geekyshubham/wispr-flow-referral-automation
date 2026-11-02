import { readFile, writeFile, rename } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';

export async function readJson(path, fallback = null) {
  try { return JSON.parse(await readFile(path, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return fallback; throw error; }
}

export async function writeJson(path, value) {
  const temp = path + '.' + randomUUID() + '.tmp';
  await writeFile(temp, JSON.stringify(value, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
  await rename(temp, path);
}

export async function withFileLock(path, operation) {
  const child = spawn('/usr/bin/python3', [fileURLToPath(new URL('./hold-file-lock.py', import.meta.url)), path], { stdio: ['pipe', 'pipe', 'pipe'] });
  let errorText = '';
  child.stderr.on('data', chunk => { errorText += chunk; });
  const finished = new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('exit', code => code === 0 ? resolve() : reject(new Error(errorText || 'File lock process exited: ' + code)));
  });
  // Observe rejection immediately even if startup fails before the lock receipt.
  finished.catch(() => {});
  await Promise.race([
    new Promise(resolve => child.stdout.once('data', resolve)),
    finished.then(() => { throw new Error('File lock exited before acquisition'); }),
  ]);
  try { return await operation(); }
  finally { child.stdin.end(); await finished; }
}
