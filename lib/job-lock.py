#!/usr/bin/env python3
"""Own one job for its lifetime; inherited descriptors permit internal calls."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time
import uuid


def paths(root, name):
    data = Path(root).resolve() / 'data'
    return data, data / f'.{name}.lock', data / ('wispr-run.pid' if name == 'wispr-job' else 'next-inbox.pid')


def held(root, name):
    try:
        fd = int(os.environ['WISPR_JOB_LOCK_FD'])
        data, path, _ = paths(root, name)
        actual, expected = os.fstat(fd), path.stat()
        record = json.loads((data / f'.{name}.owner.json').read_text())
        return (actual.st_dev, actual.st_ino) == (expected.st_dev, expected.st_ino) and record['token'] == os.environ['WISPR_JOB_LOCK_TOKEN'] and record['name'] == name
    except (OSError, ValueError, KeyError, json.JSONDecodeError):
        return False


def process_start(pid):
    try:
        return subprocess.check_output(['ps', '-p', str(pid), '-o', 'lstart='], text=True, stderr=subprocess.DEVNULL).strip()
    except subprocess.CalledProcessError:
        return ''


def same_process(pid, started):
    try:
        return bool(started) and process_start(pid) == started
    except (OSError, subprocess.CalledProcessError):
        return False


def atomic_json(path, value):
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(value, stream)
        stream.write('\n')
    os.replace(temporary, path)


def stop(root, name):
    data, path, pid_path = paths(root, name)
    if not path.exists():
        return 0
    with path.open('a+') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return 0  # Stale metadata is never permission to signal a reused PID.
        except BlockingIOError:
            pass
        try:
            record = json.loads((data / f'.{name}.owner.json').read_text())
        except (OSError, json.JSONDecodeError):
            print(f'Cannot stop {name}: active lock metadata is unreadable.', file=sys.stderr)
            return 1
        owner = record.get('pid')
        child = record.get('childPid')
        if same_process(owner, record.get('started')):
            os.kill(owner, signal.SIGTERM)
        elif same_process(child, record.get('childStarted')):
            os.killpg(child, signal.SIGTERM)
        else:
            print(f'Cannot identify the active {name} process; no unrelated PID was signaled.', file=sys.stderr)
            return 1
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                pid_path.unlink(missing_ok=True)
                return 0
            except BlockingIOError:
                time.sleep(0.1)
        if same_process(child, record.get('childStarted')):
            os.killpg(child, signal.SIGKILL)
        if same_process(owner, record.get('started')):
            os.kill(owner, signal.SIGKILL)
        pid_path.unlink(missing_ok=True)
    return 0


def supervise(root, name, command, ready_fd=None):
    data, lock_path, pid_path = paths(root, name)
    data.mkdir(parents=True, exist_ok=True)
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    child = None
    token = uuid.uuid4().hex
    code = 1
    try:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError(f'{name} is already running. Stop it with ./wispr-cleanup or wait for it to finish.')
        env = os.environ.copy()
        env.update(WISPR_JOB_LOCK_FD=str(lock_fd), WISPR_JOB_LOCK_TOKEN=token)
        interrupted = []

        def forward(signum, _frame):
            if child is None:
                interrupted.append(signum)
                return
            try:
                os.killpg(child.pid, signum)
            except ProcessLookupError:
                pass

        signal.signal(signal.SIGTERM, forward)
        signal.signal(signal.SIGINT, forward)
        record = {'pid': os.getpid(), 'started': process_start(os.getpid()), 'token': token, 'name': name}
        atomic_json(data / f'.{name}.owner.json', record)
        if interrupted:
            raise RuntimeError('Job stopped before launch.')
        child = subprocess.Popen(command, env=env, pass_fds=(lock_fd,), start_new_session=True, cwd=root)
        if interrupted:
            forward(interrupted[-1], None)
        record.update(childPid=child.pid, childStarted=process_start(child.pid))
        atomic_json(data / f'.{name}.owner.json', record)
        pid_path.write_text(str(os.getpid()))

        if ready_fd is not None:
            os.write(ready_fd, (json.dumps({'pid': os.getpid()}) + '\n').encode())
            os.close(ready_fd)
            ready_fd = None
        code = child.wait()
        return code if code >= 0 else 128 - code
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        message = str(error)
        print('ERROR:' + message, file=sys.stderr)
        if ready_fd is not None:
            os.write(ready_fd, (json.dumps({'error': message}) + '\n').encode())
        return 75 if isinstance(error, RuntimeError) else 1
    finally:
        if ready_fd is not None:
            os.close(ready_fd)
        if child is not None:
            if child.poll() is None:
                try:
                    os.killpg(child.pid, signal.SIGTERM)
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
                except ProcessLookupError:
                    pass
            atomic_json(data / f'{name}-status.json', {'exitCode': code if code >= 0 else 128 - code, 'pid': os.getpid(), 'token': token})
            try:
                if pid_path.read_text() == str(os.getpid()):
                    pid_path.unlink()
            except FileNotFoundError:
                pass
        os.close(lock_fd)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--name', default='wispr-job', choices=('wispr-job', 'next-inbox'))
    parser.add_argument('--is-held', action='store_true')
    parser.add_argument('--stop', action='store_true')
    parser.add_argument('--detach', action='store_true')
    parser.add_argument('--ready-fd', type=int)
    parser.add_argument('root')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    root = str(Path(args.root).resolve())
    if args.is_held:
        return 0 if held(root, args.name) else 1
    if args.stop:
        return stop(root, args.name)
    if not args.command:
        parser.error('a command is required')
    if args.detach:
        data, _, _ = paths(root, args.name)
        data.mkdir(parents=True, exist_ok=True)
        read_fd, write_fd = os.pipe()
        log_path = data / ('wispr-run.log' if args.name == 'wispr-job' else 'next-inbox.log')
        with log_path.open('ab') as log:
            proc = subprocess.Popen([sys.executable, __file__, '--name', args.name, '--ready-fd', str(write_fd), root, *args.command],
                                    stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                    pass_fds=(write_fd,), start_new_session=True, cwd=root)
        os.close(write_fd)
        try:
            if not select.select([read_fd], [], [], 15)[0]:
                proc.terminate()
                print('ERROR:Timed out starting the background job.', file=sys.stderr)
                return 1
            result = json.loads(os.read(read_fd, 65536) or b'{}')
        finally:
            os.close(read_fd)
        if result.get('error') or not result.get('pid'):
            print('ERROR:' + result.get('error', 'Background job failed before acquiring its lock.'), file=sys.stderr)
            return 75 if result.get('error', '').endswith('finish.') else 1
        print(f'Started {args.name} in the background (PID {result["pid"]}). Log: {log_path}')
        return 0
    return supervise(root, args.name, args.command, args.ready_fd)


if __name__ == '__main__':
    sys.exit(main())
