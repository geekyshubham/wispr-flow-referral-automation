"""Verify storage patching retains ASAR payload layout and integrity metadata."""
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('runtime', Path(__file__).resolve().parents[1] / 'lib/prepare-isolated-runtime.py')
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class RuntimeTests(unittest.TestCase):
    def test_explicit_profile_guard(self):
        patch = next(p for p in runtime.CONFIG['patches'] if p['name'] == 'isolated_support_root_and_electron_logs')
        self.assertLessEqual(len(patch['new'].encode()), len(patch['old'].encode()))
        # Evaluate only the replacement expression with mocked Electron APIs.
        script = r'''
import assert from 'node:assert/strict';
import vm from 'node:vm';
const replacement = JSON.parse(process.argv[1]);
function probe(argv, value, activePath) {
  const calls = [];
  const app = {
    commandLine: { getSwitchValue: () => value },
    getPath: () => activePath,
    exit: code => calls.push(['exit', code]),
    setAppLogsPath: path => calls.push(['logs', path]),
  };
  const context = { f: '/test/profile/logs', process: { argv }, require: () => ({ app }) };
  vm.runInNewContext(replacement, context);
  return { calls, value: context.g };
}
for (const [argv, value, activePath] of [
  [['app'], '', '/personal'],
  [['app', '--user-data-dir='], '', '/personal'],
  [['app'], '/personal', '/personal'], // A native default is not an explicit argument.
  [['app', '--user-data-dir=/test/profile'], '/test/profile', '/personal'],
]) {
  assert.deepEqual(probe(argv, value, activePath).calls, [['exit', 78]]);
}
for (const argv of [['app', '--user-data-dir=/test/profile'], ['app', '--user-data-dir', '/test/profile']]) {
  const result = probe(argv, '/test/profile', '/test/profile');
  assert.equal(result.value, '/test/profile');
  assert.deepEqual(result.calls, [['logs', '/test/profile/logs']]);
}
'''
        subprocess.run(['node', '--input-type=module', '-e', script, json.dumps(patch['new'])], check=True)

    def test_patch_preserves_other_payloads_and_checks_hashes(self):
        main = b'const storage="personal-directory",logs="personal-logs";'
        config = {'main_sha256': hashlib.sha256(main).hexdigest(), 'patches': [
            {'name': 'storage', 'old': '"personal-directory"', 'new': '"isolated-data"'},
            {'name': 'logs', 'old': '"personal-logs"', 'new': '"test-logs"'},
        ]}
        entry = {'size': len(main), 'offset': '0', 'integrity': {
            'algorithm': 'SHA256', 'hash': hashlib.sha256(main).hexdigest(), 'blockSize': 16,
            'blocks': [hashlib.sha256(main[i:i+16]).hexdigest() for i in range(0, len(main), 16)]}}
        header = {'files': {'.webpack': {'files': {'main': {'files': {'index.js': entry}}}}}}
        raw = json.dumps(header, separators=(',', ':')).encode()
        padded = (len(raw) + 3) // 4 * 4
        archive = struct.pack('<IIII', 4, 8+padded, 4+padded, len(raw)) + raw + b'\0'*(padded-len(raw)) + main + b'UNRELATED-PAYLOAD'
        with tempfile.TemporaryDirectory() as directory:
            asar, info = Path(directory, 'app.asar'), Path(directory, 'Info.plist')
            asar.write_bytes(archive)
            info.write_bytes(plistlib.dumps({'ElectronAsarIntegrity': {'Resources/app.asar': {'hash': hashlib.sha256(raw).hexdigest()}}}))
            runtime.patch_archive(asar, info, config)
            self.assertEqual(asar.stat().st_size, len(archive))
            self.assertTrue(asar.read_bytes().endswith(b'UNRELATED-PAYLOAD'))
            runtime.verify_archive(asar, info, config)
            with self.assertRaisesRegex(RuntimeError, 'Unsupported Wispr'):
                runtime.patch_archive(asar, info, config)
            with asar.open('r+b') as stream:
                stream.seek(runtime.read_main(asar)[3])
                stream.write(b'!')
            with self.assertRaisesRegex(RuntimeError, 'integrity mismatch'):
                runtime.verify_archive(asar, info, config)


class RuntimeUpgradeTests(unittest.TestCase):
    """Exercise upgrade transactions using tiny synthetic apps and mocked signing."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / 'original/Wispr Flow.app'
        self.destination = self.root / 'Applications/Wispr Flow.app'
        self.manifest = self.root / 'runtime.json'
        main = b'const storage="personal-directory";'
        entry = {'size': len(main), 'offset': '0', 'integrity': {
            'algorithm': 'SHA256', 'hash': hashlib.sha256(main).hexdigest(), 'blockSize': 16,
            'blocks': [hashlib.sha256(main[i:i+16]).hexdigest() for i in range(0, len(main), 16)]}}
        header = {'files': {'.webpack': {'files': {'main': {'files': {'index.js': entry}}}}}}
        raw = json.dumps(header, separators=(',', ':')).encode()
        padded = (len(raw) + 3) // 4 * 4
        asar = self.source / 'Contents/Resources/app.asar'
        asar.parent.mkdir(parents=True)
        asar.write_bytes(struct.pack('<IIII', 4, 8+padded, 4+padded, len(raw)) + raw + b'\0'*(padded-len(raw)) + main)
        info = self.source / 'Contents/Info.plist'
        info.write_bytes(plistlib.dumps({'ElectronAsarIntegrity': {'Resources/app.asar': {'hash': hashlib.sha256(raw).hexdigest()}}}))
        framework = self.source / 'Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework'
        framework.parent.mkdir(parents=True)
        framework.write_bytes(b'unchanged nested framework and fuses')
        self.config = {'original_app': str(self.source), 'original_asar_sha256': runtime.digest(asar),
                       'original_info_plist_sha256': runtime.digest(info), 'main_sha256': hashlib.sha256(main).hexdigest(),
                       'patches': [{'name': 'storage', 'old': '"personal-directory"', 'new': '"isolated-data"'}]}
        self.calls = []

        def fake_run(argv, **kwargs):
            self.calls.append(argv)
            if argv[0] == 'cp':
                shutil.copytree(argv[-2], argv[-1])
            return subprocess.CompletedProcess(argv, 0)

        patches = [mock.patch.multiple(runtime, CONFIG=self.config, RUNTIME=self.destination, MANIFEST=self.manifest),
                   mock.patch.object(runtime.subprocess, 'check_output', return_value=''),
                   mock.patch.object(runtime.subprocess, 'run', side_effect=fake_run)]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def own_copy(self, current=False):
        self.destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(self.source, self.destination)
        config = {**self.config, 'patches': [{'name': 'storage', 'old': '"personal-directory"',
                                            'new': '"isolated-data"' if current else '"old-patch"'}]}
        runtime.patch_archive(self.destination / 'Contents/Resources/app.asar', self.destination / 'Contents/Info.plist', config)
        state = {'app': str(self.destination), 'asar': runtime.digest(self.destination / 'Contents/Resources/app.asar'),
                 'info': runtime.digest(self.destination / 'Contents/Info.plist'), 'signed': True}
        self.manifest.write_text(json.dumps(state))
        return state

    def test_foreign_app_is_never_overwritten(self):
        shutil.copytree(self.source, self.destination)
        before = runtime.digest(self.destination / 'Contents/Resources/app.asar')
        with self.assertRaisesRegex(RuntimeError, 'unowned or changed'):
            runtime.prepare(build=True)
        self.assertEqual(runtime.digest(self.destination / 'Contents/Resources/app.asar'), before)
        self.assertEqual(self.calls, [])

    def test_owned_old_copy_is_signed_in_staging_then_replaced(self):
        old = self.own_copy()
        runtime.prepare(build=True)
        state = json.loads(self.manifest.read_text())
        self.assertTrue(state['signed'])
        self.assertNotEqual(state['asar'], old['asar'])
        runtime.verify_archive(self.destination / 'Contents/Resources/app.asar', self.destination / 'Contents/Info.plist', self.config)
        self.assertEqual(runtime.digest(self.source / 'Contents/Resources/app.asar'), self.config['original_asar_sha256'])
        signing = next(argv for argv in self.calls if argv[:2] == ['codesign', '--force'])
        self.assertNotEqual(signing[-1], str(self.destination))
        self.assertEqual(list(self.destination.parent.glob('runtime-stage-*')), [])

    def test_prepare_upgrade_does_not_inherit_old_signed_state(self):
        self.own_copy()
        runtime.prepare(build=False)
        self.assertFalse(json.loads(self.manifest.read_text())['signed'])
        self.assertFalse(any(argv[0] == 'codesign' for argv in self.calls))

    def test_prepare_preserves_identical_current_signed_copy(self):
        self.own_copy(current=True)
        before = self.manifest.read_bytes()
        runtime.prepare(build=False)
        self.assertEqual(self.manifest.read_bytes(), before)
        self.assertFalse(any(argv[0] == 'cp' for argv in self.calls))

    def test_failed_verification_or_manifest_write_restores_owned_copy(self):
        old = self.own_copy()
        before = self.manifest.read_bytes()
        for target in ('verify_nested', 'write_manifest'):
            with self.subTest(target=target), mock.patch.object(runtime, target, side_effect=RuntimeError('injected failure')):
                with self.assertRaisesRegex(RuntimeError, 'injected failure'):
                    runtime.prepare(build=True)
            self.assertEqual(runtime.digest(self.destination / 'Contents/Resources/app.asar'), old['asar'])
            self.assertEqual(self.manifest.read_bytes(), before)
            self.assertEqual(list(self.destination.parent.glob('runtime-stage-*')), [])

    def test_failed_staged_sign_leaves_owned_app_unchanged(self):
        old = self.own_copy()
        before = self.manifest.read_bytes()
        normal_run = runtime.subprocess.run

        def fail_sign(argv, **kwargs):
            if argv[:2] == ['codesign', '--force']:
                raise subprocess.CalledProcessError(1, argv)
            return normal_run(argv, **kwargs)

        with mock.patch.object(runtime.subprocess, 'run', side_effect=fail_sign):
            with self.assertRaises(subprocess.CalledProcessError):
                runtime.prepare(build=True)
        self.assertEqual(runtime.digest(self.destination / 'Contents/Resources/app.asar'), old['asar'])
        self.assertEqual(self.manifest.read_bytes(), before)
        self.assertEqual(list(self.destination.parent.glob('runtime-stage-*')), [])

    def test_running_clone_blocks_preparation(self):
        with mock.patch.object(runtime.subprocess, 'check_output', return_value=str(self.destination / 'Contents/MacOS/Wispr Flow') + ' --user-data-dir=/test/profile\n'):
            with self.assertRaisesRegex(RuntimeError, 'isolated app is running'):
                runtime.prepare(build=True)
        self.assertFalse(self.destination.parent.exists())
        self.assertEqual(self.calls, [])


if __name__ == '__main__':
    unittest.main()
