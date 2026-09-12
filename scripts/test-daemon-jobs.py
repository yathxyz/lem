#!/usr/bin/env python3
"""External crash/client driver. All jobs, supervision and journaling are Common Lisp."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('daemon_test', ROOT / 'scripts/test-daemon-recovery.py')
daemon_test = importlib.util.module_from_spec(spec)
spec.loader.exec_module(daemon_test)
Client = daemon_test.Client
lisp_string = daemon_test.lisp_string


def process_running(pid):
    try:
        text = Path(f'/proc/{pid}/stat').read_text()
    except FileNotFoundError:
        return False
    return text[text.rfind(')') + 2] not in 'ZX'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--sbcl', default='sbcl')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='lem-jobs-crash-') as temporary:
        directory = Path(temporary)
        env = os.environ.copy()
        env['LEM_TOOLKIT_SBCL'] = args.sbcl
        for key in ('XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'LEM_HOME'):
            path = directory / key.lower()
            path.mkdir(mode=0o700)
            env[key] = str(path)
        endpoint = Path(env['XDG_RUNTIME_DIR']) / 'lem/recovery-test.sock'
        journal = Path(env['XDG_STATE_HOME']) / 'lem/recovery/jobs-test/jobs'
        child_pid = directory / 'child.pid'
        effects = directory / 'effects.txt'
        process = None
        client = None
        logs = []
        try:
            def start():
                log_path = directory / f'daemon-{len(logs)}.log'
                logs.append(log_path)
                with log_path.open('w') as output:
                    child = subprocess.Popen([args.sbcl, '--noinform', '--disable-debugger', '--script',
                                              str(ROOT / 'scripts/jobs-test-server.lisp')],
                                             env=env, cwd=directory, stdout=output, stderr=output)
                return child, daemon_test.wait_client(child, endpoint, log_path)

            process, client = start()
            # The shell is explicitly requested by argv solely as a child-spawning fixture.
            script = f"echo effect >> {effects}; sleep 30 & echo $! > {child_pid}; kill -STOP 0; wait"
            form = ('(progn (defparameter lem-user::*managed-test-job* '
                    '(lem-toolkit/jobs:start-job (list "/run/current-system/sw/bin/bash" "-c" '
                    + lisp_string(script) + ') :owner "daemon-test" :timeout 60)) '
                    '(lem-toolkit/jobs:job-id lem-user::*managed-test-job*))')
            job_id = json.loads(client.evaluate(form))
            deadline = time.monotonic() + 10
            while not child_pid.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            assert child_pid.exists()
            pid = int(child_pid.read_text())
            assert process_running(pid)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                stat = Path(f'/proc/{pid}/stat').read_text()
                if stat[stat.rfind(')') + 2] == 'T':
                    break
                time.sleep(0.02)
            else:
                raise AssertionError('fixture must stop the whole target group before daemon recovery')
            started = time.monotonic()
            assert client.evaluate('(+ 20 22)') == '42'
            assert time.monotonic() - started < 3
            assert client.evaluate('(progn (lem-toolkit/jobs-ui:show-job lem-user::*managed-test-job*) t)') == 'T'
            assert client.evaluate('(progn (lem:delete-buffer (lem:get-buffer '
                                   + lisp_string(f'*Job {job_id}*') + ')) t)') == 'T'
            assert process_running(pid)
            client.close()
            client = Client(endpoint)
            assert client.evaluate('(string= "running" (lem-daemon/recovery-store:field '
                                   '(lem-toolkit/jobs:job-snapshot lem-user::*managed-test-job*) "state"))') == 'T'
            print('PASS: editor responds during a hanging job; closing its buffer/client preserves the job')
            process.send_signal(signal.SIGKILL)
            assert process.wait(timeout=10) == -signal.SIGKILL
            client.close()
            client = None
            deadline = time.monotonic() + 10
            while process_running(pid) and time.monotonic() < deadline:
                time.sleep(0.02)
            assert not process_running(pid), 'daemon death must close control and clean the owned group'
            print('PASS: daemon SIGKILL causes the Lisp guardian to clean even a stopped child process group')
            record = json.loads((journal / f'{job_id}.json').read_text())
            assert record['state'] == 'running'
            assert 'pid' not in record
            inspection = subprocess.run(
                [args.sbcl, '--noinform', '--no-sysinit', '--no-userinit', '--disable-debugger',
                 '--load', str(ROOT / 'scripts/recovery-source.lisp'),
                 '--eval', '(load-recovery-system "lem-toolkit/jobs")',
                 '--eval', '(assert (null (find-package :lem)))',
                 '--eval', '(multiple-value-bind (records failures) '
                 '(lem-toolkit/jobs:inspect-job-journal :name "jobs-test") '
                 '(assert (null failures)) (assert (= 1 (length records))) '
                 '(assert (string= "running" (lem-daemon/recovery-store:field (first records) "state"))))',
                 '--eval', '(sb-ext:exit :code 0)'],
                env=env, cwd=directory, capture_output=True, text=True, timeout=60)
            assert inspection.returncode == 0, inspection.stdout + inspection.stderr
            assert json.loads((journal / f'{job_id}.json').read_text()) == record
            print('PASS: standalone Lisp journal inspection needs no editor and does not reconcile or write')
            process, client = start()
            form = ('(let ((job (lem-toolkit/jobs:find-job ' + lisp_string(job_id) + '))) '
                    '(and job (string= "interrupted" (lem-daemon/recovery-store:field '
                    '(lem-toolkit/jobs:job-result job) "state")) (null (lem-toolkit/jobs:cancel-job job))))')
            assert client.evaluate(form) == 'T'
            assert effects.read_text().splitlines() == ['effect']
            print('PASS: restart marks the prior job interrupted without replaying effects or signalling a stored PID')
            for log in logs:
                assert f'Recovery source lem-toolkit/jobs-ui: {ROOT}/extensions/toolkit/' in log.read_text()
            client.request('shutdown', force=True)
            assert process.wait(timeout=10) == 0
            print('PASS: source identities verified; job manager and daemon shut down cleanly')
        finally:
            if client:
                client.close()
            if process and process.poll() is None:
                process.kill()
                process.wait(timeout=10)


if __name__ == '__main__':
    main()
