"""Test proposal acceptance in the configured native daemon without providers.

Python is the external process test driver; all proposal/tool runtime is Lisp.
"""

import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile


def lisp_string(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


def main():
    editor = os.environ['LEM_BIN']
    client = os.environ['LEMCLIENT_BIN']
    fixture = Path(__file__).with_suffix('.lisp')
    with tempfile.TemporaryDirectory(prefix='lem-buffer-proposals-') as temporary:
        root = Path(temporary)
        env = dict(os.environ, TERM='xterm-256color')
        for variable in ['XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME',
                         'XDG_STATE_HOME', 'XDG_DATA_HOME', 'LEM_HOME']:
            path = root / variable
            path.mkdir(mode=0o700)
            env[variable] = str(path)
        command = [client, '--server-name', 'proposals']
        daemon = None

        def run(*arguments):
            result = subprocess.run(command + list(arguments), cwd=root, env=env,
                                    capture_output=True, text=True, timeout=35)
            if result.returncode:
                raise AssertionError(result.stderr or result.stdout)
            return json.loads(result.stdout) if result.stdout.strip() else None

        log_path = root / 'daemon.log'
        try:
            with log_path.open('w') as log:
                daemon = subprocess.Popen([editor, '--daemon=proposals'], cwd=root,
                                          env=env, stdout=log, stderr=subprocess.STDOUT,
                                          start_new_session=True)
                run('--wait-for-server', '30', '--eval',
                    '(assert (null lem-user::*lem-yath-boot-error*))')
                run('--eval', '(load ' + lisp_string(fixture) + ')')
                result = run('--eval', '(with-output-to-string (*standard-output*) '
                             '(assert (lem-yath::run-buffer-proposal-acceptance-tests)))')
                print(result['primary'], flush=True)
                assert result['primary'].count('PASS:') == 12, result
                print('PASS: configured proposal and rewrite acceptance assertions', flush=True)
                run('--stop-server', '--force')
                assert daemon.wait(timeout=10) == 0
        finally:
            if daemon is not None and daemon.poll() is None:
                os.killpg(daemon.pid, signal.SIGKILL)
                daemon.wait(timeout=5)
            print(log_path.read_text(errors='replace'), flush=True)


if __name__ == '__main__':
    main()
