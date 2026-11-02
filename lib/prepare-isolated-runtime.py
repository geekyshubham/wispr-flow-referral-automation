#!/usr/bin/env python3
"""Build/check a version-pinned local app copy whose databases/logs honor userData.

--prepare patches an unsigned local copy for review. --build signs that copy.
The installed app, personal data, HOME and Electron fuses are never changed.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT / 'lib/runtime-patches.json').read_text())
RUNTIME = Path.home() / 'Applications/Wispr Flow.app'
MANIFEST = ROOT / 'data/runtime/runtime.json'


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def read_main(asar):
    with Path(asar).open('rb') as stream:
        prefix = stream.read(16)
        _, header_size, _, json_size = struct.unpack('<IIII', prefix)
        raw_header = stream.read(json_size)
        header = json.loads(raw_header)
        entry = header['files']['.webpack']['files']['main']['files']['index.js']
        offset = 8 + header_size + int(entry['offset'])
        stream.seek(offset)
        main = stream.read(entry['size'])
    return header, raw_header, entry, offset, main


def patch_archive(asar, info_path, config=CONFIG):
    header, raw_header, entry, offset, main = read_main(asar)
    if hashlib.sha256(main).hexdigest() != config['main_sha256']:
        raise RuntimeError('Unsupported Wispr main bundle; refusing to patch')
    for patch in config['patches']:
        old, new = patch['old'].encode(), patch['new'].encode()
        if main.count(old) != 1 or len(new) > len(old):
            raise RuntimeError('Storage patch does not match exactly: ' + patch['name'])
        main = main.replace(old, new.ljust(len(old), b' '), 1)
    integrity = entry['integrity']
    integrity['hash'] = hashlib.sha256(main).hexdigest()
    size = integrity['blockSize']
    integrity['blocks'] = [hashlib.sha256(main[i:i + size]).hexdigest() for i in range(0, len(main), size)]
    new_header = json.dumps(header, separators=(',', ':'), ensure_ascii=False).encode()
    if len(new_header) != len(raw_header):
        raise RuntimeError('ASAR header length changed; refusing to shift archive data')
    with Path(asar).open('r+b') as stream:
        stream.seek(16)
        stream.write(new_header)
        stream.seek(offset)
        stream.write(main)
    with Path(info_path).open('rb') as stream:
        info = plistlib.load(stream)
    info['ElectronAsarIntegrity']['Resources/app.asar']['hash'] = hashlib.sha256(new_header).hexdigest()
    with Path(info_path).open('wb') as stream:
        plistlib.dump(info, stream, sort_keys=False)
    verify_archive(asar, info_path, config)


def verify_archive(asar, info_path, config=CONFIG):
    _, raw_header, entry, _, main = read_main(asar)
    integrity = entry['integrity']
    if hashlib.sha256(main).hexdigest() != integrity['hash']:
        raise RuntimeError('Patched ASAR main integrity mismatch')
    size = integrity['blockSize']
    if integrity['blocks'] != [hashlib.sha256(main[i:i + size]).hexdigest() for i in range(0, len(main), size)]:
        raise RuntimeError('Patched ASAR block integrity mismatch')
    for patch in config['patches']:
        if patch['old'].encode() in main or main.count(patch['new'].encode()) != 1:
            raise RuntimeError('Isolation patch verification failed: ' + patch['name'])
    with Path(info_path).open('rb') as stream:
        info = plistlib.load(stream)
    if info['ElectronAsarIntegrity']['Resources/app.asar']['hash'] != hashlib.sha256(raw_header).hexdigest():
        raise RuntimeError('Patched ASAR plist integrity mismatch')


def ensure_not_running():
    prefix = str(RUNTIME / 'Contents') + '/'
    commands = subprocess.check_output(['ps', '-ax', '-ww', '-o', 'command='], text=True)
    if any(command.strip().removeprefix('nohup ').startswith(prefix) for command in commands.splitlines()):
        raise RuntimeError('The isolated app is running. Stop it before preparing or replacing its runtime.')


def owned_state():
    if RUNTIME.is_symlink():
        raise RuntimeError('Refusing to replace a linked app at ' + str(RUNTIME))
    if not RUNTIME.exists():
        return None
    try:
        state = json.loads(MANIFEST.read_text())
        matches = (state.get('app') == str(RUNTIME)
                   and digest(RUNTIME / 'Contents/Resources/app.asar') == state.get('asar')
                   and digest(RUNTIME / 'Contents/Info.plist') == state.get('info'))
    except (OSError, ValueError, TypeError, AttributeError):
        matches = False
    if not matches:
        raise RuntimeError('Refusing to replace an unowned or changed app at ' + str(RUNTIME))
    return state


def write_manifest(state):
    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', prefix='.runtime-', suffix='.json',
                                         dir=MANIFEST.parent, delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(state, stream, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, MANIFEST)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def verify_nested(original, copied):
    framework = Path('Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework')
    if digest(original / framework) != digest(copied / framework):
        raise RuntimeError('Copied Electron framework differs; refusing to use changed fuses/nested code')


def prepare(build=False):
    original = Path(CONFIG['original_app'])
    source_asar = original / 'Contents/Resources/app.asar'
    source_info = original / 'Contents/Info.plist'
    if digest(source_asar) != CONFIG['original_asar_sha256'] or digest(source_info) != CONFIG['original_info_plist_sha256']:
        raise RuntimeError('Installed Wispr version changed. Its storage isolation patch must be reviewed before running.')
    if RUNTIME.resolve() == original.resolve():
        raise RuntimeError('The isolated runtime must not resolve to the installed app')
    ensure_not_running()
    previous = owned_state()
    if previous is not None and not build:
        try:
            verify_archive(RUNTIME / 'Contents/Resources/app.asar', RUNTIME / 'Contents/Info.plist', CONFIG)
        except RuntimeError:
            pass  # An owned old patch is upgraded from a fresh source copy below.
        else:
            verify_nested(original, RUNTIME)
            if previous.get('signed'):
                subprocess.run(['codesign', '--verify', '--deep', '--strict', str(RUNTIME)], check=True)
            return RUNTIME  # Retain signed state only for this byte-identical existing app.
    RUNTIME.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='runtime-stage-', dir=RUNTIME.parent))
    staged, backup = staging / RUNTIME.name, staging / 'previous.app'
    installed = False
    keep_backup = False
    try:
        print('Cloning the app with copy-on-write; original files are unchanged.', file=sys.stderr)
        subprocess.run(['cp', '-cR', str(original), str(staged)], check=True)
        patch_archive(staged / 'Contents/Resources/app.asar', staged / 'Contents/Info.plist', CONFIG)
        if build:
            print('Signing only the local test copy (ad hoc, no outer Hardened Runtime; nested signatures/fuses retained).', file=sys.stderr)
            subprocess.run(['codesign', '--force', '--sign', '-', '--options', '0',
                            '--preserve-metadata=identifier,entitlements', '--timestamp=none', str(staged)], check=True)
            subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staged)], check=True)
        verify_archive(staged / 'Contents/Resources/app.asar', staged / 'Contents/Info.plist', CONFIG)
        verify_nested(original, staged)
        if digest(source_asar) != CONFIG['original_asar_sha256'] or digest(source_info) != CONFIG['original_info_plist_sha256']:
            raise RuntimeError('Original app changed during preparation')
        state = {'app': str(RUNTIME), 'sourceAsar': CONFIG['original_asar_sha256'],
                 'asar': digest(staged / 'Contents/Resources/app.asar'),
                 'info': digest(staged / 'Contents/Info.plist'), 'signed': build,
                 'outerHardenedRuntime': False, 'nestedFrameworkUnchanged': True}
        ensure_not_running()
        if owned_state() != previous:
            raise RuntimeError('Runtime ownership changed during preparation; nothing was replaced')
        if previous is not None:
            RUNTIME.rename(backup)
        staged.rename(RUNTIME)
        installed = True
        write_manifest(state)
        return RUNTIME
    except BaseException:
        try:
            if installed:
                ensure_not_running()
                RUNTIME.rename(staged)
            if backup.exists():
                backup.rename(RUNTIME)
        except (OSError, RuntimeError) as error:
            keep_backup = True
            raise RuntimeError('Runtime upgrade rollback failed; owned recovery copy kept at ' + str(staging)) from error
        raise
    finally:
        if not keep_backup:
            shutil.rmtree(staging)


def check():
    if not MANIFEST.exists():
        raise RuntimeError('Isolated test runtime is not built. Review/build with: python3 lib/prepare-isolated-runtime.py --build')
    state = owned_state()
    if state is None:
        raise RuntimeError('The isolated runtime is missing; rebuild its approved local copy')
    if state.get('app') != str(RUNTIME):
        raise RuntimeError('Isolated runtime location changed; rebuild the approved local test copy')
    if not state.get('signed'):
        raise RuntimeError('The isolated test copy is prepared but unsigned. Build it before desktop validation.')
    if digest(Path(CONFIG['original_app']) / 'Contents/Resources/app.asar') != CONFIG['original_asar_sha256']:
        raise RuntimeError('Installed Wispr changed; rebuild/review the isolated runtime first')
    if digest(RUNTIME / 'Contents/Resources/app.asar') != state['asar'] or digest(RUNTIME / 'Contents/Info.plist') != state['info']:
        raise RuntimeError('Isolated runtime changed; refusing to launch it')
    verify_archive(RUNTIME / 'Contents/Resources/app.asar', RUNTIME / 'Contents/Info.plist')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(RUNTIME)], check=True)
    return RUNTIME


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare', action='store_true')
    parser.add_argument('--build', action='store_true')
    args = parser.parse_args()
    lock_path = ROOT / 'data/runtime-build.lock'
    lock_path.parent.mkdir(exist_ok=True)
    try:
        with lock_path.open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            print(prepare(args.build) if args.prepare or args.build else check())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print('ERROR:' + str(error), file=sys.stderr)
        sys.exit(1)
