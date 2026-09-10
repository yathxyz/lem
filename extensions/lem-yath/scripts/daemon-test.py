"""Exercise the packaged configuration and native client without a terminal server.

Python is only the external test driver; editor, client, and tools run in Lisp.
Every process and file created here belongs to a private temporary directory.
"""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time


def lisp_string(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


def check(condition, message):
    if not condition:
        raise AssertionError(message)
    print(f"PASS: {message}", flush=True)


def main():
    editor = os.environ['LEM_BIN']
    client = os.environ['LEMCLIENT_BIN']
    recovery_client = os.environ['LEM_RECOVER_BIN']
    processes = []
    with tempfile.TemporaryDirectory(prefix='lem-configured-daemon-') as temporary:
        root = Path(temporary)
        env = dict(os.environ)
        for variable, directory in [('XDG_RUNTIME_DIR', 'runtime'),
                                    ('XDG_CONFIG_HOME', 'config'),
                                    ('XDG_CACHE_HOME', 'cache'),
                                    ('XDG_STATE_HOME', 'state'),
                                    ('XDG_DATA_HOME', 'data'),
                                    ('LEM_HOME', 'lem')]:
            path = root / directory
            path.mkdir(mode=0o700)
            env[variable] = str(path)
        env['TERM'] = 'xterm-256color'
        env['SHELL'] = shutil.which('bash') or '/bin/sh'
        env['GIT_EDITOR'] = 'obsolete-editor-must-be-replaced'
        name = 'configured-test'
        command = [client, '--server-name', name]
        log_path = root / 'daemon.log'

        def start(args, **kwargs):
            process = subprocess.Popen(args, cwd=root, env=env, **kwargs)
            processes.append(process)
            return process

        def run(*args, success=True):
            result = subprocess.run(command + list(args), cwd=root, env=env,
                                    capture_output=True, text=True, timeout=15)
            if success and result.returncode:
                raise AssertionError(f"Client failed: {result.stderr}")
            return result

        def evaluate(form):
            return json.loads(run('--eval', form).stdout)['primary']

        def eventually(form, expected='T'):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if evaluate(form) == expected:
                    return
                time.sleep(0.05)
            raise AssertionError(f"Timed out waiting for {form}")

        try:
            with log_path.open('w') as log:
                # Start the readiness client first to exercise the startup race.
                ready = start(command + ['--wait-for-server', '30', '--eval',
                                         '(and (null lem-user::*lem-yath-boot-error*) '
                                         '(lem-yath:boot-ok-p))'],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                time.sleep(0.15)
                daemon = start([editor, f'--daemon={name}'], stdout=log,
                               stderr=subprocess.STDOUT)
                stdout, stderr = ready.communicate(timeout=45)
                check(ready.returncode == 0 and json.loads(stdout)['primary'] == 'T',
                      f'configured daemon completes initialization: {stderr.strip()}')
                check(evaluate('(string= lem-daemon::*daemon-name* '
                               + lisp_string(name) + ')') == 'T',
                      'the configured editor retains its daemon name')
                check(evaluate("(lem:mode-active-p (lem:current-buffer) 'lem-yath::org-mode)")
                      == 'T', 'scratch starts in Org mode')

                child_command = shlex.join([client, '--server-name', name])
                check(evaluate('(string= (uiop:getenv "GIT_EDITOR") '
                               + lisp_string(child_command) + ')') == 'T',
                      'child Git edits use the packaged native client and selected daemon')

                document = root / 'file with spaces.txt'
                document.write_text('first\nsecond\nthird\n')
                run('--no-wait', '+2:2', str(document))
                check(evaluate('(list (lem:line-number-at-point (lem:current-point)) '
                               '(lem:point-charpos (lem:current-point)))') == '(2 2)',
                      'native file visits preserve line and column')
                evaluate('(defparameter lem-user::*daemon-test-persistent* 73)')
                check(evaluate('lem-user::*daemon-test-persistent*') == '73',
                      'Lisp state survives separate client connections')

                control = root / 'private-controls' / 'action'
                target = root / 'unrelated.txt'
                target.write_text('preserve')
                control.parent.mkdir()
                control.symlink_to(target)
                evaluate('(lem-yath::write-private-control-file '
                         + lisp_string(control) + ' "continue")')
                check(control.read_text() == 'continue' and not control.is_symlink()
                      and target.read_text() == 'preserve'
                      and control.stat().st_mode & 0o777 == 0o600
                      and control.parent.stat().st_mode & 0o777 == 0o700,
                      'private control writes replace links without changing their target')
                linked_directory = root / 'linked-controls'
                linked_directory.symlink_to(control.parent, target_is_directory=True)
                check(run('--eval', '(lem-yath::write-private-control-file '
                          + lisp_string(linked_directory / 'action') + ' "bad")',
                          success=False).returncode != 0
                      and control.read_text() == 'continue',
                      'private control writes reject a symlinked directory')
                evaluate('(let ((lem-shell-mode:*default-shell-command* '
                         '(list (uiop:getenv "SHELL") "-c" '
                         + lisp_string("printf 'SHELL=%s\\n' \"$((19+23))\"; sleep 3")
                         + '))) (defparameter lem-user::*daemon-test-shell* '
                         '(lem-shell-mode::run-shell-internal)))')
                eventually('(not (null (search "SHELL=42" '
                           '(lem:buffer-text lem-user::*daemon-test-shell*))))')
                check(evaluate('(lem-process:process-alive-p '
                               '(lem-shell-mode::buffer-process lem-user::*daemon-test-shell*))')
                      == 'T', 'shell output and process survive the launching client disconnect')
                evaluate('(lem:delete-buffer lem-user::*daemon-test-shell*)')

                evaluate('(lem-lisp-mode/internal::start-lisp-repl t)')
                evaluate('(lem-lisp-mode/internal::repl-eval (lem:current-point) '
                         + lisp_string('(format t "REPL=~d~%" (+ 19 23))') + ')')
                eventually('(not (null (search "REPL=42" '
                           '(lem:buffer-text (lem:get-buffer "*lisp-repl*")))))')
                check(evaluate('(not lem-lisp-mode/internal::*repl-evaluating*)') == 'T',
                      'the self-connected Lisp REPL completes work across client connections')

                edit = root / 'COMMIT_EDITMSG'
                edit.write_text('draft')
                waiting = start(shlex.split(child_command) + [str(edit)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                eventually('(= 1 (length (lem-daemon:request-buffer-list)))')
                evaluate('(progn (lem:buffer-end (lem:current-point)) '
                         '(lem:insert-string (lem:current-point) "-saved") '
                         '(lem-yath::lem-yath-legit-commit-continue))')
                waiting.communicate(timeout=10)
                check(waiting.returncode == 0 and edit.read_text() == 'draft-saved',
                      'configured Git continuation saves and releases a blocking client')

                waiting = start(command + [str(edit)], stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE)
                eventually('(= 1 (length (lem-daemon:request-buffer-list)))')
                evaluate('(lem-yath::lem-yath-legit-commit-abort)')
                waiting.communicate(timeout=10)
                check(waiting.returncode != 0 and daemon.poll() is None,
                      'aborting an edit releases the client and keeps the daemon alive')

                waiting = start(command + [str(document)], stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE)
                eventually('(= 1 (length (lem-daemon:request-buffer-list)))')
                waiting.kill()
                waiting.communicate(timeout=10)
                eventually("(notany (lambda (r) (eq :visit (lem-daemon::daemon-request-kind r))) "
                           "lem-daemon::*daemon-requests*)")
                check(evaluate('(string= (lem:buffer-text (lem:current-buffer)) '
                               + lisp_string(document.read_text()) + ')') == 'T',
                      'a killed client leaves its shared buffer intact')

                recovered = root / 'recovered.txt'
                recovered.write_text('original')
                run('--no-wait', str(recovered))
                evaluate('(lem:insert-string (lem:buffer-end-point (lem:current-buffer)) "-unsaved")')
                evaluate('(lem-daemon/recovery:checkpoint-now)')
                recovery_directory = root / 'state' / 'lem' / 'recovery' / name
                records = [json.loads(path.read_text()) for path in recovery_directory.glob('*.json')]
                record = next(item for item in records if item['filename'] == str(recovered))
                check(record['text'] == 'original-unsaved'
                      and recovery_directory.stat().st_mode & 0o777 == 0o700,
                      'configured recovery stores unsaved text under the named private directory')
                daemon.kill()
                daemon.wait(timeout=10)
                inspected = subprocess.run([recovery_client, str(recovery_directory)],
                                           env=env, capture_output=True, text=True, timeout=10)
                exported = subprocess.run([recovery_client, str(recovery_directory), record['id']],
                                          env=env, capture_output=True, text=True, timeout=10)
                check(inspected.returncode == 0
                      and record['id'] in [item['id'] for item in json.loads(inspected.stdout)['records']]
                      and exported.returncode == 0 and exported.stdout == 'original-unsaved',
                      'packaged Lisp inspector lists and exports recovery while the daemon is dead')
                recovered.write_text('externally changed')
                daemon = start([editor, f'--daemon={name}'], stdout=log,
                               stderr=subprocess.STDOUT)
                ready_result = run('--wait-for-server', '30', '--eval',
                                   '(lem-yath:boot-ok-p)')
                check(json.loads(ready_result.stdout)['primary'] == 'T',
                      'a restarted daemon reclaims its stale socket and initializes')
                check(evaluate('(multiple-value-bind (buffer status) '
                               '(lem-daemon/recovery:restore-checkpoint '
                               + lisp_string(record['id']) + ') '
                               '(and (eq status :conflict) (null (lem:buffer-filename buffer)) '
                               '(lem:buffer-modified-p buffer) '
                               '(string= "original-unsaved" (lem:buffer-text buffer))))') == 'T'
                      and recovered.read_text() == 'externally changed',
                      'daemon crash recovery preserves unsaved text and conflicting disk edits')
                run('--stop-server', '--force')
                check(daemon.wait(timeout=15) == 0, 'deliberate shutdown exits cleanly')
                check(not list((root / 'runtime').rglob('*.sock')),
                      'clean shutdown removes the socket')

                failed = start([editor, f'--daemon={name}', '--eval',
                                '(error "expected configured startup failure")'],
                               stdout=log, stderr=subprocess.STDOUT)
                check(failed.wait(timeout=30) != 0,
                      'configured initialization failure exits unsuccessfully')
                check(not list((root / 'runtime').rglob('*.sock')),
                      'failed startup removes the socket')
                check(run('--eval', 't', success=False).returncode != 0,
                      'failed startup cannot answer a readiness probe')
        except BaseException:
            print(log_path.read_text(errors='replace')[-16000:], flush=True)
            raise
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=10)


if __name__ == '__main__':
    main()
