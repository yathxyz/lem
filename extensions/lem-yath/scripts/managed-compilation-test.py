"""Exercise configured Lisp-managed compilation with native daemon clients.

Python drives test processes only; compilation supervision and UI are Lisp.
"""
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import tempfile
import time


def quoted(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


def check(condition, description):
    if not condition:
        raise AssertionError(description)
    print('PASS: ' + description, flush=True)


def eventually(predicate, description, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError('Timed out: ' + description)


def alive(pid):
    try:
        return Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[0] != 'Z'
    except FileNotFoundError:
        return False


def main():
    editor, client = os.environ['LEM_BIN'], os.environ['LEMCLIENT_BIN']
    fixture = Path(__file__).with_suffix('.lisp')
    with tempfile.TemporaryDirectory(prefix='lem-managed-compilation-') as temporary:
        root = Path(temporary)
        env = dict(os.environ, TERM='xterm-256color', LEM_COMPILATION_PRIVATE='private-environment-value')
        for variable in ('XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME',
                         'XDG_STATE_HOME', 'XDG_DATA_HOME', 'LEM_HOME'):
            path = root / variable
            path.mkdir(mode=0o700)
            env[variable] = str(path)
        command = [client, '--server-name', 'compilation']
        (root / 'sample.c').write_text('first\nsecond line\nthird\n')
        daemon = None
        log_path = root / 'daemon.log'

        def evaluate(form):
            r = subprocess.run(command + ['--eval', form], cwd=root, env=env,
                               capture_output=True, text=True, timeout=10)
            if r.returncode:
                raise AssertionError(r.stderr or r.stdout)
            return json.loads(r.stdout)['primary']

        def snapshot():
            printed = evaluate('(yason:with-output-to-string* () '
                               '(yason:encode (lem-yath::managed-compilation-test-snapshot)))')
            return json.loads(json.loads(printed, strict=False))

        def start(script):
            return evaluate('(lem-yath::managed-compilation-test-start ' + quoted(script)
                            + ' ' + quoted(str(root) + '/') + ')').strip('"')

        def finished():
            s = snapshot()
            return s if s['state'] in ('finished', 'failed', 'interrupted') else None

        def launch(log):
            process = subprocess.Popen([editor, '--daemon=compilation'], cwd=root, env=env,
                                       stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                ready = subprocess.run(command + ['--wait-for-server', '40', '--eval',
                                                 '(assert (null lem-user::*lem-yath-boot-error*))'],
                                       cwd=root, env=env, capture_output=True, text=True, timeout=45)
                if ready.returncode:
                    raise AssertionError(ready.stderr)
                evaluate('(load ' + quoted(fixture) + ')')
                return process
            except BaseException:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
                raise

        def child_pid(path):
            try:
                text = path.read_text().strip()
                return int(text) if text.isdecimal() else None
            except FileNotFoundError:
                return None

        try:
            with log_path.open('w') as log:
                daemon = launch(log)
                start("printf '\\033[31msample.c:2:3: error: split'; sleep .1; "
                      "printf ' colour\\033[0m\\n'; printf 'héλlo\\n'; "
                      "test \"$LEM_COMPILATION_PRIVATE\" = private-environment-value || exit 41; "
                      "test \"$(cat)\" = '' || exit 42; printf 'stdin-eof\\n'; exit 7")
                s = eventually(finished, 'diagnostic compilation')
                check(s['state'] == 'failed' and s['job']['state'] == 'exited'
                      and s['job']['exit-code'] == 7, 'nonzero shell status remains an explicit failed compilation')
                check(s['diagnostics'] == 1 and 'héλlo' in s['text'] and 'stdin-eof' in s['text']
                      and '\x1b' not in s['text'], 'ANSI, UTF-8, captured environment, EOF stdin and diagnostics work')
                check(evaluate('(lem-yath::managed-compilation-test-static)') == 'T',
                      'native manager, default command, read-only log and stable point are configured')
                check(evaluate('(lem-yath::managed-compilation-test-navigation)') == 'T',
                      'compilation navigation retains the log and visits exact source coordinates')

                # Command text and environment pass privately; only deliberate output is retained.
                start("test \"$LEM_COMPILATION_PRIVATE\" = private-environment-value || exit 41\n"
                      "printf 'multiline-ok\\n'\n# private-command-sentinel")
                s = eventually(finished, 'multiline command')
                check(s['state'] == 'finished' and 'multiline-ok' in s['text'],
                      'private multiline shell commands retain their exit status')
                journals = list((root / 'XDG_STATE_HOME').rglob('jobs/*.json'))
                serialized = ''.join(p.read_text() for p in journals)
                check('private-command-sentinel' not in serialized and 'private-environment-value' not in serialized,
                      'durable job records exclude private command input and environment')
                evaluate('(progn (sb-posix:setenv "LEM_COMPILATION_PRIVATE" "changed" 1) '
                         '(lem-yath::lem-yath-recompile) '
                         '(setf lem-yath::*managed-compilation-test-session* lem-yath::*compilation-session*))')
                s = eventually(finished, 'recompile with captured environment')
                check(s['state'] == 'finished' and 'multiline-ok' in s['text'],
                      'recompile retains the original command, directory and environment')

                child_file = root / 'child.pid'
                start('sleep 90 & child=$!; printf "%s" "$child" > ' + shlex.quote(str(child_file)) + '; wait')
                child = eventually(lambda: child_pid(child_file), 'child process')
                check(evaluate('(lem-yath::managed-compilation-test-kill-view)') == 'T' and alive(child),
                      'killing the compilation view preserves the managed job')
                check(evaluate('(+ 20 22)') == '42', 'a running tool leaves the editor responsive')
                evaluate('(lem-yath::lem-yath-interrupt-compilation)')
                s = eventually(finished, 'cancelled job without a view')
                eventually(lambda: not alive(child), 'cancelled child cleanup')
                check(s['state'] == 'interrupted' and s['job']['state'] == 'cancelled',
                      'explicit cancellation cleans children and records status after view closure')

                evaluate('(setf lem-yath::*managed-compilation-test-limit* 65536)')
                start('yes noisy-output')
                s = eventually(finished, 'bounded output')
                check(s['state'] == 'failed' and 'output exceeded 65536 bytes' in s['text']
                      and s['text-length'] < 70000, 'noisy compilation has bounded output and is cancelled')

                start("printf '\\303'; sleep .1")
                s = eventually(finished, 'incomplete UTF-8')
                check(s['state'] == 'failed' and 'UTF-8' in s['text'],
                      'incomplete UTF-8 fails explicitly after terminal process cleanup')

                child_file.unlink()
                job_id = start('sleep 90 & child=$!; printf "%s" "$child" > '
                               + shlex.quote(str(child_file)) + '; wait')
                child = eventually(lambda: child_pid(child_file), 'crash child')
                daemon.kill()
                daemon.wait(timeout=10)
                eventually(lambda: not alive(child), 'daemon crash child cleanup')
                recover = os.environ.get('LEM_RECOVER_BIN')
                if recover:
                    directory = root / 'XDG_STATE_HOME' / 'lem' / 'recovery' / 'compilation' / 'jobs'
                    r = subprocess.run([recover, '--jobs', str(directory)], env=env,
                                       capture_output=True, text=True, timeout=10)
                    check(r.returncode == 0 and job_id in r.stdout,
                          'standalone recovery inspects job records while the daemon is down')
                daemon = launch(log)
                state = evaluate('(gethash "state" (lem-toolkit/jobs:job-snapshot '
                                 '(lem-toolkit/jobs:find-job ' + quoted(job_id) + ')))')
                check(state == '"interrupted"' and not alive(child),
                      'restart reconciles the old compilation as interrupted without replay')
                result = subprocess.run(command + ['--stop-server', '--force'], env=env,
                                        capture_output=True, text=True, timeout=10)
                check(result.returncode == 0 and daemon.wait(timeout=15) == 0,
                      'configured daemon shuts down its job manager cleanly')
        finally:
            if daemon is not None and daemon.poll() is None:
                os.killpg(daemon.pid, signal.SIGKILL)
                daemon.wait(timeout=5)
            print(log_path.read_text(errors='replace'), flush=True)


if __name__ == '__main__':
    main()
