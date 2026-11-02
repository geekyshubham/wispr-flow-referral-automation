import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { readJson, writeJson, withFileLock } from '../lib/file-state.mjs';

const moduleUrl = new URL('../lib/file-state.mjs', import.meta.url).href;
function child(code) {
  const process = spawn(globalThis.process.execPath, ['--input-type=module', '-e', code]);
  let errors = '';
  process.stderr.on('data', data => { errors += data; });
  const done = new Promise((resolve, reject) => process.once('exit', code => code === 0 ? resolve() : reject(new Error(errors || `exit ${code}`))));
  return { process, done };
}

test('concurrent processes serialize state changes without lost writes', async () => {
  const root = await mkdtemp(join(tmpdir(), 'wispr-state-'));
  try {
    const path = join(root, 'counter.json');
    await writeJson(path, { count: 0 });
    await Promise.all(Array.from({ length: 4 }, () => child(`
      import { readJson, writeJson, withFileLock } from ${JSON.stringify(moduleUrl)};
      for(let i=0;i<5;i++) await withFileLock(${JSON.stringify(path + '.lock')}, async()=>{
        const value=await readJson(${JSON.stringify(path)});
        await new Promise(resolve=>setTimeout(resolve,2));
        await writeJson(${JSON.stringify(path)},{count:value.count+1});
      });
    `).done));
    assert.equal((await readJson(path)).count, 20);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('a crashed owner releases its kernel lock automatically', async () => {
  const root = await mkdtemp(join(tmpdir(), 'wispr-crash-'));
  const path = join(root, 'lock');
  try {
    const worker = child(`import {withFileLock} from ${JSON.stringify(moduleUrl)}; await withFileLock(${JSON.stringify(path)},async()=>{console.log('ready');await new Promise(()=>{});});`);
    worker.done.catch(() => {});
    await new Promise(resolve => worker.process.stdout.once('data', resolve));
    worker.process.kill('SIGKILL');
    let acquired = false;
    await withFileLock(path, async () => { acquired = true; });
    assert.equal(acquired, true);
  } finally { await rm(root, { recursive: true, force: true }); }
});
