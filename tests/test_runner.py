"""Local regression checks: no network, audio, or desktop app is used."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


class RunnerTests(unittest.TestCase):
    def fixture(self, directory, real_cleanup=False):
        root = Path(directory)
        (root / 'lib').mkdir()
        (root / 'data').mkdir()
        (root / 'bin').mkdir()
        for name in ('wispr-run', 'wispr-test', 'wispr-resume', 'wispr-next-inbox'):
            shutil.copy(ROOT / name, root / name)
        for name in ('job-lock.py', 'start-detached.py'):
            shutil.copy(ROOT / 'lib' / name, root / 'lib' / name)
        (root / 'lib/env.sh').write_text('')
        (root / 'lib/prepare-isolated-runtime.py').write_text('print("/mock/isolated.app")\n')
        (root / 'lib/check-network.py').write_text('raise SystemExit(0)\n')
        for name in ('referral-status.mjs', 'referral-apply.mjs', 'file-state.mjs'):
            shutil.copy(ROOT / 'lib' / name, root / 'lib' / name)
        for name in ('cleanup-all.sh', 'restore-audio.sh', 'resume-main-wispr.sh', 'close-ego-wispr-spaces.sh'):
            (root / 'lib' / name).write_text('#!/bin/bash\nexit 0\n')
        if real_cleanup:
            shutil.copy(ROOT / 'lib/cleanup-all.sh', root / 'lib/cleanup-all.sh')
        (root / 'lib/kill-isolated-wispr.py').write_text('raise SystemExit(0)\n')
        self.script(root / 'bin/ego-browser', '#!/bin/bash\ncat >/dev/null\nexit 0\n')
        return root

    def script(self, path, text):
        path.write_text(text)
        path.chmod(0o755)

    def env(self, root, **extra):
        env = {key: value for key, value in os.environ.items() if key not in ('WISPR_JOB_LOCK_FD', 'WISPR_JOB_LOCK_TOKEN', 'WISPR_RUN_TOKEN', 'REMAINING_ACCOUNTS', 'WISPR_BATCH_DICTATION')}
        env.update(PATH=str(root / 'bin') + os.pathsep + env['PATH'], FOREGROUND='1', **extra)
        return env

    def invoke(self, root, name, *args, **extra):
        return subprocess.run(['bash', str(root / name), *args], env=self.env(root, **extra), text=True, capture_output=True, timeout=15)

    def pending(self, root, **extra):
        pending = dict(email='one@example.com', password='test-password', targetWords=500,
                       remainingAccounts=2, referralCode='TEST', verified=True,
                       completed=False, skipDictation=False, taskSpaceId=7)
        pending.update(extra)
        (root / 'data/pending-signup.json').write_text(json.dumps(pending))
        return pending

    def wait_for(self, predicate):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.02)
        self.fail('timed out waiting for local test process')

    def browser_stub(self, root):
        # Execute the real wrapper's JS against local state-only browser stubs.
        (root / 'lib/web-auth.mjs').write_text('''
import { readFile, writeFile, appendFile } from 'node:fs/promises';
export async function readJson(path) {
  try { return JSON.parse(await readFile(path, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}
export async function runSignup(config) {
  const path = config.dataDir + '/pending-signup.json';
  const counts = config.dataDir + '/signups';
  await appendFile(counts, 'signup\\n');
  const count = (await readFile(counts, 'utf8')).trim().split('\\n').length;
  await writeFile(path, JSON.stringify({ ...config, email: 'test' + count + '@example.com', password: 'test', verified: true, completed: false, taskSpaceId: 7 }));
  return 0;
}
''')
        self.script(root / 'bin/ego-browser', '''#!/usr/bin/env python3
import os, subprocess, sys, tempfile
prefix = "globalThis.taskSpace=async () => ({spaceId:7,name:'wispr-signup'});globalThis.listTaskSpaces=async () => [];\\n"
fd, path = tempfile.mkstemp(suffix='.mjs')
try:
    with os.fdopen(fd, 'w') as stream:
        stream.write(prefix + sys.stdin.read())
    sys.exit(subprocess.call(['node', path]))
finally:
    os.unlink(path)
''')

    def test_server_stats_reads_native_workos_and_legacy_sessions(self):
        spec = importlib.util.spec_from_file_location('stats', ROOT / 'lib/fetch-server-stats.py')
        stats = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(stats)
        self.assertEqual(stats.access_token_from_session({'authProviderId': 'workos', 'workosSession': {'accessToken': 'workos-access'}}), 'workos-access')
        self.assertEqual(stats.access_token_from_session({'sb-dodjkfqhwrzqjwkfnthl-auth-token': '{"access_token":"legacy-access"}'}), 'legacy-access')

    def test_referral_threshold_warning(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(directory)
            self.script(root / 'wispr-test', '#!/bin/bash\nexit 1\n')
            low = self.invoke(root, 'wispr-run', '--accounts', '1', '--words', '500', '--foreground')
            self.assertIn('2,000 server-confirmed words', low.stderr + low.stdout)
            self.assertIn('will not credit', low.stderr + low.stdout)
            high = self.invoke(root, 'wispr-run', '--accounts', '1', '--words', '2100', '--foreground')
            self.assertNotIn('will not credit', high.stderr + high.stdout)

    def test_signup_failure_is_not_retried(self):
        for status in (1, 75):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                root = self.fixture(directory)
                self.script(root / 'wispr-test', f'#!/bin/bash\necho attempted >> "{root}/attempts"\nexit {status}\n')
                result = self.invoke(root, 'wispr-run', '--accounts', '2', '--words', '500', '--foreground')
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                self.assertEqual((root / 'attempts').read_text().splitlines(), ['attempted'])
                self.assertIn('no new accounts', result.stdout)

    def test_explicit_fresh_signup_does_not_resume_the_saved_email(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(directory)
            self.browser_stub(root)
            previous = self.pending(root, remainingAccounts=1)
            result = self.invoke(root, 'wispr-test', '1', '--no-dictation', '--fresh')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            current = json.loads((root / 'data/pending-signup.json').read_text())
            self.assertNotEqual(current['email'], previous['email'])
            self.assertTrue(current['fresh'])

    def test_dns_failure_preserves_pending_state_before_starting_browser(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(directory)
            self.browser_stub(root)
            before = self.pending(root)
            (root / 'lib/check-network.py').write_text('raise SystemExit(69)\n')
            result = self.invoke(root, 'wispr-test', '1', '--no-dictation', '--fresh')
            self.assertEqual(result.returncode, 69, result.stdout + result.stderr)
            self.assertFalse((root / 'data/signups').exists())
            self.assertEqual(json.loads((root / 'data/pending-signup.json').read_text()), before)

    def test_dns_check_uses_the_selected_provider_and_reports_resolver_failures(self):
        spec = importlib.util.spec_from_file_location('network', ROOT / 'lib/check-network.py')
        network = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(network)
        for provider, host in [('maildrop', 'api.maildrop.cc'), ('mail.tm', 'api.mail.tm')]:
            with mock.patch.object(network.socket, 'getaddrinfo', return_value=[]) as lookup:
                self.assertEqual(network.check(provider), 0)
                self.assertEqual([call.args[0] for call in lookup.call_args_list], ['wisprflow.ai', 'api.wisprflow.ai', host])
        with mock.patch.object(network.socket, 'getaddrinfo', side_effect=network.socket.gaierror('resolver failed')), mock.patch('sys.stderr'):
            self.assertEqual(network.check(), 69)

    def test_failed_dictation_keeps_the_account_profile_and_remaining_batch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(directory, real_cleanup=True)
            profile = root / 'profiles/one'
            profile.mkdir(parents=True)
            (profile / 'history-marker').write_text('resume me')
            self.pending(root)
            self.script(root / 'wispr-test', '#!/bin/bash\nexit 0\n')
            self.script(root / 'wispr-complete-flow', '#!/bin/bash\nexit 9\n')
            result = self.invoke(root, 'wispr-run', '--accounts', '2', '--words', '500', '--foreground')
            self.assertEqual(result.returncode, 9, result.stdout + result.stderr)
            self.assertTrue((profile / 'history-marker').exists())
            self.assertEqual(json.loads((root / 'data/pending-signup.json').read_text())['remainingAccounts'], 2)
            self.assertIn('kept', result.stdout)

    def test_stale_cleanup_has_no_side_effects(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(directory, real_cleanup=True)
            (root / 'data/wispr-run-token').write_text('new-run')
            self.script(root / 'lib/restore-audio.sh', f'#!/bin/bash\ntouch "{root}/mutated"\n')
            (root / 'lib/kill-isolated-wispr.py').write_text(f'from pathlib import Path\nPath({str(root / "mutated")!r}).touch()\n')
            result = subprocess.run(['bash', str(root / 'lib/cleanup-all.sh')], env=self.env(root, WISPR_RUN_TOKEN='old-run'), text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0)
            self.assertFalse((root / 'mutated').exists())
            self.assertEqual((root / 'data/wispr-run-token').read_text(), 'new-run')

    def test_multiple_iterations_checkpoint_each_finished_account(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(directory)
            self.script(root / 'wispr-test', f'''#!/usr/bin/env python3
import json, os
from pathlib import Path
root=Path({str(root)!r})
path=root/'attempts'
n=int(path.read_text())+1 if path.exists() else 1
path.write_text(str(n))
(root/'data/pending-signup.json').write_text(json.dumps(dict(email=f'account{{n}}@example.com',password='test',verified=True,completed=False,targetWords=500,remainingAccounts=int(os.environ['REMAINING_ACCOUNTS']),referralCode='TEST',skipDictation=False)))
''')
            self.script(root / 'wispr-complete-flow', f'#!/bin/bash\necho "$1" >> "{root}/completed"\n')
            result = self.invoke(root, 'wispr-run', '--accounts', '3', '--words', '500', '--foreground')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((root / 'completed').read_text().splitlines(), ['account1@example.com', 'account2@example.com', 'account3@example.com'])
            pending = json.loads((root / 'data/pending-signup.json').read_text())
            self.assertTrue(pending['completed'])
            self.assertEqual(pending['remainingAccounts'], 0)

    def test_resume_does_not_repeat_a_completed_account(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(directory)
            self.pending(root, completed=True, remainingAccounts=0)
            self.script(root / 'wispr-complete-flow', f'#!/bin/bash\ntouch "{root}/repeated"\n')
            result = self.invoke(root, 'wispr-resume')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((root / 'repeated').exists())

    def test_signup_only_batch_and_resume_continue_without_dictation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(directory)
            self.browser_stub(root)
            self.script(root / 'wispr-complete-flow', f'#!/bin/bash\ntouch "{root}/dictated"\n')
            result = self.invoke(root, 'wispr-test', '3', '--no-dictation')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((root / 'data/signups').read_text().splitlines(), ['signup'] * 3)
            self.assertFalse((root / 'dictated').exists())
            self.pending(root, completed=True, remainingAccounts=2, skipDictation=True)
            result = self.invoke(root, 'wispr-resume')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((root / 'data/signups').read_text().splitlines(), ['signup'] * 5)
            self.assertFalse((root / 'dictated').exists())
            self.assertEqual(json.loads((root / 'data/pending-signup.json').read_text())['remainingAccounts'], 0)

    def test_fresh_start_does_not_overwrite_a_partially_finished_batch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(directory)
            self.browser_stub(root)
            before = self.pending(root, completed=True, remainingAccounts=2)
            result = self.invoke(root, 'wispr-test', '1', '--no-dictation')
            self.assertEqual(result.returncode, 75, result.stdout + result.stderr)
            self.assertFalse((root / 'data/signups').exists())
            self.assertEqual(json.loads((root / 'data/pending-signup.json').read_text()), before)

    def test_failed_resume_preserves_batch_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(directory)
            before = self.pending(root)
            self.script(root / 'wispr-complete-flow', '#!/bin/bash\nexit 9\n')
            result = self.invoke(root, 'wispr-resume')
            self.assertEqual(result.returncode, 9, result.stdout + result.stderr)
            self.assertEqual(json.loads((root / 'data/pending-signup.json').read_text()), before)

    def test_rejected_referral_cannot_resume_or_cycle_into_a_new_signup(self):
        for command, args in [('wispr-resume', []), ('wispr-test', ['1', '--no-dictation', '--fresh'])]:
            with self.subTest(command=command), tempfile.TemporaryDirectory() as directory:
                root = self.fixture(directory)
                self.browser_stub(root)
                self.script(root / 'wispr-complete-flow', f'#!/bin/bash\ntouch "{root}/dictated"\n')
                before = self.pending(root, requireReferral=True, signupSynced=True, referralAssociated=False,
                                      referralStatus={'referral_code_valid': True, 'referral_applied': False, 'user_exists': True})
                result = self.invoke(root, command, *args, REFERRAL_CODE='TEST')
                self.assertEqual(result.returncode, 76, result.stdout + result.stderr)
                self.assertFalse((root / 'data/signups').exists())
                self.assertFalse((root / 'dictated').exists())
                self.assertEqual(json.loads((root / 'data/pending-signup.json').read_text()), before)

    def test_fresh_start_with_new_referral_passes_the_wrapper_guard(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(directory)
            self.browser_stub(root)
            self.pending(root, phase='referral_rejected')
            result = self.invoke(root, 'wispr-test', '1', '--no-dictation', '--fresh', REFERRAL_CODE='NEW456')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            current = json.loads((root / 'data/pending-signup.json').read_text())
            self.assertEqual(current['referralCode'], 'NEW456')
            self.assertNotEqual(current['email'], 'one@example.com')

    def test_signup_handoff_keeps_signup_only_mode_and_remaining_count(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(directory)
            self.script(root / 'bin/ego-browser', '''#!/usr/bin/env python3
import json,re,sys
from pathlib import Path
config=json.loads(re.search(r'const config = (.*);',sys.stdin.read()).group(1))
config.update(email='test@example.com', password='test', verified=False, taskSpaceId=7)
Path(config['dataDir'],'pending-signup.json').write_text(json.dumps(config))
sys.exit(75)
''')
            result = self.invoke(root, 'wispr-test', '3', '--no-dictation')
            self.assertEqual(result.returncode, 75, result.stdout + result.stderr)
            pending = json.loads((root / 'data/pending-signup.json').read_text())
            self.assertTrue(pending['skipDictation'])
            self.assertEqual(pending['remainingAccounts'], 3)
            (root / 'data/pending-signup.json').unlink()
            result = self.invoke(root, 'wispr-test', '1', '--no-dictation', WISPR_BATCH_DICTATION='1', REMAINING_ACCOUNTS='3')
            self.assertEqual(result.returncode, 75, result.stdout + result.stderr)
            self.assertFalse(json.loads((root / 'data/pending-signup.json').read_text())['skipDictation'])

    def test_lifetime_lock_is_inherited_and_rejects_concurrent_start(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(directory)
            hold = root / 'hold.sh'
            self.script(hold, f'''#!/bin/bash
python3 "{root}/lib/job-lock.py" --is-held "{root}" || exit 97
touch "{root}/ready"
while [ ! -f "{root}/release" ]; do sleep 0.02; done
exit 7
''')
            helper = [sys.executable, str(root / 'lib/job-lock.py')]
            first = subprocess.Popen([*helper, str(root), str(hold)], env=self.env(root), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.wait_for(lambda: (root / 'ready').exists())
                other = subprocess.run([*helper, str(root), '/usr/bin/true'], env=self.env(root), text=True, capture_output=True, timeout=5)
                self.assertEqual(other.returncode, 75, other.stdout + other.stderr)
                (root / 'release').touch()
                stdout, stderr = first.communicate(timeout=5)
                self.assertEqual(first.returncode, 7, stdout + stderr)
                self.assertFalse((root / 'data/wispr-run.pid').exists())
                self.assertEqual(json.loads((root / 'data/wispr-job-status.json').read_text())['exitCode'], 7)
            finally:
                if first.poll() is None:
                    subprocess.run([*helper, '--stop', str(root)], env=self.env(root), capture_output=True, timeout=15)
                    first.communicate(timeout=5)

    def test_stale_prefetch_pid_does_not_block_a_new_worker(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(directory)
            (root / 'data/next-inbox.pid').write_text(str(os.getpid()))
            result = subprocess.run([sys.executable, str(root / 'lib/job-lock.py'), '--name', 'next-inbox', str(root), '/usr/bin/true'], env=self.env(root), text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((root / 'data/next-inbox.pid').exists())

    def test_detached_start_acquires_lock_before_reporting_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(directory)
            self.script(root / 'hold.sh', f'#!/bin/bash\ntouch "{root}/ready"\nwhile true; do sleep 1; done\n')
            helper = [sys.executable, str(root / 'lib/job-lock.py')]
            args = [*helper, '--detach', str(root), str(root / 'hold.sh')]
            first = subprocess.run(args, env=self.env(root), text=True, capture_output=True, timeout=5)
            try:
                self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
                self.wait_for(lambda: (root / 'ready').exists())
                second = subprocess.run(args, env=self.env(root), text=True, capture_output=True, timeout=5)
                self.assertEqual(second.returncode, 75, second.stdout + second.stderr)
            finally:
                stopped = subprocess.run([*helper, '--stop', str(root)], env=self.env(root), text=True, capture_output=True, timeout=15)
                self.assertEqual(stopped.returncode, 0, stopped.stdout + stopped.stderr)

    def test_detached_exec_failure_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(directory)
            result = subprocess.run([sys.executable, str(root / 'lib/job-lock.py'), '--detach', str(root), '/no/such/test-program'], env=self.env(root), text=True, capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('Started', result.stdout)


if __name__ == '__main__':
    unittest.main()
