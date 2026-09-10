#!/usr/bin/env python3
"""External test driver only. Daemon, snapshots and restoration all run in Lisp."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import socket
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
VERSION = int(re.search(r'\(defconstant \+protocol-version\+ (\d+)\)',
                        (ROOT / 'frontends/daemon/protocol.lisp').read_text()).group(1))


def lisp_string(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


class Client:
    def __init__(self, endpoint):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(10)
        try:
            self.sock.connect(str(endpoint))
            self.send({'type': 'hello', 'capabilities': ['eval']})
            assert self.receive()['type'] == 'hello'
        except BaseException:
            self.sock.close()
            raise
        self.id = 0

    def close(self):
        self.sock.close()

    def send(self, data):
        data['version'] = VERSION
        wire = json.dumps(data).encode()
        self.sock.sendall(struct.pack('>I', len(wire)) + wire)

    def read(self, count):
        result = bytearray()
        while len(result) < count:
            data = self.sock.recv(count - len(result))
            if not data:
                raise EOFError('daemon closed connection')
            result.extend(data)
        return result

    def receive(self):
        size, = struct.unpack('>I', self.read(4))
        assert size <= 1024 * 1024
        return json.loads(self.read(size))

    def request(self, kind, **fields):
        self.id += 1
        self.send({'id': str(self.id), 'type': kind, **fields})
        while True:
            reply = self.receive()
            if reply.get('id') == str(self.id):
                assert reply['status'] == 'ok', reply
                return reply['value']

    def evaluate(self, form):
        return self.request('eval', form=form)['primary']


def wait_client(process, endpoint, log):
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError(f'daemon exited {process.returncode}: {log.read_text()[-6000:]}')
        try:
            return Client(endpoint)
        except (FileNotFoundError, ConnectionRefusedError):
            time.sleep(0.05)
    raise AssertionError(f'daemon readiness timed out: {log.read_text()[-6000:]}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--sbcl', default='sbcl')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='lem-recovery-crash-') as temporary:
        directory = Path(temporary)
        env = os.environ.copy()
        for key in ('XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'LEM_HOME'):
            path = directory / key.lower()
            path.mkdir(mode=0o700)
            env[key] = str(path)
        endpoint = Path(env['XDG_RUNTIME_DIR']) / 'lem/recovery-test.sock'
        records = Path(env['XDG_STATE_HOME']) / 'lem/recovery/recovery-test'
        source = directory / 'source.txt'
        source.write_text('original')
        process = None
        client = None
        logs = []
        try:
            def start():
                log_path = directory / f'daemon-{len(logs)}.log'
                logs.append(log_path)
                with log_path.open('w') as output:
                    child = subprocess.Popen([args.sbcl, '--noinform', '--disable-debugger',
                                              '--script', str(ROOT / 'scripts/recovery-test-server.lisp')],
                                             env=env, cwd=directory, stdout=output, stderr=output)
                return child, wait_client(child, endpoint, log_path)

            process, client = start()
            result = client.evaluate(
                '(progn (defparameter lem-user::*recovery-file* (lem:find-file-buffer ' + lisp_string(source) + ')) '
                '(lem:insert-string (lem:buffer-end-point lem-user::*recovery-file*) " unsaved λ") '
                '(defparameter lem-user::*recovery-scratch* (lem:make-buffer "crash scratch")) '
                '(lem:insert-string (lem:buffer-point lem-user::*recovery-scratch*) "scratch 界") t)')
            assert result == 'T'
            # Exercise the automatic idle checkpoint, not an explicit test-only snapshot.
            deadline = time.monotonic() + 10
            saved = []
            while time.monotonic() < deadline:
                saved = [json.loads(path.read_text()) for path in records.glob('*.json')]
                if any(r['text'] == 'original unsaved λ' for r in saved) and any(r['text'] == 'scratch 界' for r in saved):
                    break
                time.sleep(0.05)
            else:
                raise AssertionError('automatic checkpoints did not contain edited file and scratch')
            file_id = next(r['id'] for r in saved if r['filename'] == str(source))
            scratch_id = next(r['id'] for r in saved if r['name'] == 'crash scratch')
            assert source.read_text() == 'original'
            process.send_signal(signal.SIGKILL)
            assert process.wait(timeout=10) == -signal.SIGKILL
            client.close()
            client = None
            print('PASS: modified file and scratch checkpointed automatically before daemon SIGKILL')
            source.write_text('external change')
            # Independently inspect/export with no live daemon or Lem user init.
            inspector = [args.sbcl, '--noinform', '--disable-debugger', '--script',
                         str(ROOT / 'scripts/lem-recovery.lisp'), str(records)]
            checked = subprocess.run(inspector, env=env, cwd=directory, text=True,
                                     capture_output=True, timeout=30)
            assert checked.returncode == 0, checked.stderr
            listing = json.loads(checked.stdout)
            assert not listing['errors']
            assert {r['id'] for r in listing['records']} >= {file_id, scratch_id}
            exported = subprocess.run(inspector + [file_id], env=env, cwd=directory, text=True,
                                      capture_output=True, timeout=30)
            assert exported.returncode == 0, exported.stderr
            assert exported.stdout == 'original unsaved λ'
            print('PASS: standalone Lisp inspector/export works while the daemon is dead')
            process, client = start()
            assert client.evaluate('(null (lem:get-buffer "crash scratch"))') == 'T', 'restore must be explicit'
            for record_id, expected_text, expected_status in (
                (file_id, 'original unsaved λ', ':CONFLICT'), (scratch_id, 'scratch 界', ':SCRATCH')):
                form = ('(multiple-value-bind (buffer status) (lem-daemon/recovery:restore-checkpoint '
                        + lisp_string(record_id) + ') (and (eq status ' + expected_status + ') '
                        '(null (lem:buffer-filename buffer)) (lem:buffer-modified-p buffer) '
                        '(string= (lem:buffer-text buffer) ' + lisp_string(expected_text) + ')))')
                assert client.evaluate(form) == 'T'
            assert source.read_text() == 'external change'
            assert client.evaluate('(+ 20 22)') == '42'
            print('PASS: restarted daemon restores separate unsaved buffers and reports disk conflict')
            for log in logs:
                assert f'Recovery source lem/core: {ROOT}/' in log.read_text()
            client.request('shutdown', force=True)
            assert process.wait(timeout=10) == 0
            print('PASS: test source identities verified and restarted daemon shuts down cleanly')
        finally:
            if client:
                client.close()
            if process and process.poll() is None:
                process.kill()
                process.wait(timeout=10)


if __name__ == '__main__':
    main()
