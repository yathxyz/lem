"""Hold real polling reads while checking editor responsiveness and stale results.

Requires packaged LEM_BIN and LEMCLIENT_BIN. All files, sockets and injected
functions belong to a private daemon; no installed editor is contacted.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def quote(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


root = Path(tempfile.mkdtemp(prefix='lem-polling-check-'))
print('ARTIFACTS: ' + str(root), flush=True)
env = dict(os.environ, TERM='xterm-256color', LEM_YATH_OPENROUTER_MODEL_REFRESH='0',
           LEM_YATH_CODEX_MODEL_REFRESH='0')
for name in ('HOME', 'XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME',
             'XDG_STATE_HOME', 'XDG_DATA_HOME', 'LEM_HOME'):
    directory = root / name
    directory.mkdir(mode=0o700)
    env[name] = str(directory)
client = [os.environ['LEMCLIENT_BIN'], '-s', 'polling', '--wait-for-server', '15']
fixture = Path(os.environ.get('LEM_POLLING_FIXTURE',
               'extensions/lem-yath/scripts/persistence-polling-fixture.lisp')).resolve()
checks = []


def evaluate(form):
    result = subprocess.run(client + ['--eval', form], env=env, cwd=root,
                            capture_output=True, text=True, timeout=18)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)['primary']


def eventually(form):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        if evaluate(form) == 'T':
            return
        time.sleep(.025)
    raise AssertionError('Did not complete: ' + form)


def check(form, description):
    assert evaluate(form) == 'T', description
    checks.append(description)
    print('PASS: ' + description, flush=True)


def start_case(name, external='EXTERNAL-A\n', normalize_metadata=False):
    path = root / (name + '.txt')
    path.write_text('BASE\n')
    assert evaluate('(lem-yath::poll-test-open ' + quote(path) + ')') == 'T'
    path.write_text(external)
    if normalize_metadata:
        evaluate('(let* ((buffer lem-yath::*poll-test-buffer*) '
                 "(baseline (lem:buffer-value buffer 'lem-yath::lem-yath-file-state-signature)) "
                 '(current (lem-yath::file-state-signature ' + quote(path) + '))) '
                 "(setf (lem:buffer-value buffer 'lem-yath::lem-yath-file-state-signature) "
                 '(append (subseq current 0 6) (list (seventh baseline)))))')
    assert evaluate('(lem-yath::poll-test-start)') == 'T'
    eventually('(lem-yath::poll-test-await)')
    return path


def release():
    evaluate('(lem-yath::poll-test-release)')
    eventually('(lem-yath::poll-test-finished-p)')


def text_is(text):
    return '(string= (lem:buffer-text lem-yath::*poll-test-buffer*) ' + quote(text) + ')'


process = None
try:
    with (root / 'daemon.log').open('w') as log:
        process = subprocess.Popen([os.environ['LEM_BIN'], '--daemon=polling'],
                                   env=env, cwd=root, stdout=log, stderr=subprocess.STDOUT)
    check('(lem-yath:boot-ok-p)', 'configured daemon boots')
    evaluate('(load ' + quote(fixture) + ')')
    eventually('(null lem-yath::*safe-auto-revert-scan*)')

    path = start_case('dirty')
    check('(progn (lem:insert-string (lem:buffer-start-point lem-yath::*poll-test-buffer*) "LOCAL-") '
          '(dotimes (i 10) (setf lem-yath::*last-auto-revert-check-time* nil) '
          '(lem-yath::safe-auto-revert-poll)) '
          '(eq lem-yath::*poll-test-scan* lem-yath::*safe-auto-revert-scan*))',
          'editing remains responsive and repeated polls retain one blocked worker')
    release()
    check('(and ' + text_is('LOCAL-BASE\n') + ' '
          '(lem:buffer-modified-p lem-yath::*poll-test-buffer*) '
          '(not (null (lem:buffer-value lem-yath::*poll-test-buffer* '
          "'lem-yath::lem-yath-file-state-conflict))))",
          'a delayed change reports a conflict without losing intervening local edits')
    assert path.read_text() == 'EXTERNAL-A\n'
    evaluate('(lem-yath::poll-test-cleanup)')

    path = start_case('fresh')
    path.write_text('EXTERNAL-B\n')
    release()
    check(text_is('EXTERNAL-B\n'), 'changed results re-read current disk bytes before reload')
    evaluate('(lem-yath::poll-test-cleanup)')

    start_case('same-metadata', external='EDIT\n', normalize_metadata=True)
    release()
    check(text_is('EDIT\n'), 'periodic current-buffer hashing detects a same-metadata rewrite')
    evaluate('(lem-yath::poll-test-cleanup)')

    path = start_case('baseline')
    evaluate('(lem-core/commands/file:sync-buffer-with-file-content lem-yath::*poll-test-buffer*)')
    path.write_text('EXTERNAL-B\n')
    release()
    check(text_is('EXTERNAL-A\n'), 'a newer reload baseline invalidates the queued result')
    evaluate('(lem-yath::safe-auto-revert-check-all :force t)')
    check(text_is('EXTERNAL-B\n'), 'explicit forced scans still complete synchronously')
    evaluate('(lem-yath::poll-test-cleanup)')

    path = start_case('save')
    # Return disk to the original baseline, then perform a real guarded save.
    path.write_text('BASE\n')
    evaluate('(lem:insert-string (lem:buffer-start-point lem-yath::*poll-test-buffer*) "SAVED-")')
    # The changed timestamp itself requires confirmation. Bind only that prompt
    # in this disposable daemon; the production guard and after-save hooks run.
    evaluate('(sb-ext:without-package-locks (let ((original (symbol-function \'lem:prompt-for-y-or-n-p))) '
             '(unwind-protect (progn (setf (symbol-function \'lem:prompt-for-y-or-n-p) '
             '(lambda (&rest args) (declare (ignore args)) t)) '
             '(lem:save-buffer lem-yath::*poll-test-buffer*)) '
             '(setf (symbol-function \'lem:prompt-for-y-or-n-p) original))))')
    path.write_text('EXTERNAL-B\n')
    release()
    check(text_is('SAVED-BASE\n'), 'a newer saved baseline invalidates the queued result')
    evaluate('(lem-yath::poll-test-cleanup)')

    path = start_case('rename')
    alternate = root / 'alternate.txt'
    alternate.write_text('OTHER\n')
    evaluate('(setf (lem:buffer-filename lem-yath::*poll-test-buffer*) ' + quote(alternate) + ')')
    release()
    check(text_is('BASE\n'), 'renaming the visited path invalidates the queued result')
    evaluate('(lem-yath::poll-test-cleanup)')

    start_case('deleted')
    evaluate('(lem:kill-buffer lem-yath::*poll-test-buffer*)')
    release()
    check('(lem:deleted-buffer-p lem-yath::*poll-test-buffer*)',
          'a queued result ignores a deleted buffer')

    start_case('cancelled')
    check('(progn (load (asdf:system-relative-pathname "lem-yath" "src/persistence.lisp")) '
          '(lem-yath::stop-safe-auto-revert-timer) '
          '(lem-yath::stop-file-notify-service) '
          "(lem:remove-hook lem:*pre-command-hook* 'lem-yath::safe-auto-revert-poll) "
          '(setf lem-yath::*last-auto-revert-check-time* nil) '
          '(lem-yath::safe-auto-revert-poll) '
          '(eq lem-yath::*poll-test-scan* lem-yath::*safe-auto-revert-scan*))',
          'configuration reload cancels without blocking or spawning a second reader')
    release()
    check(text_is('BASE\n'), 'cancelled scan completion leaves the buffer intact')
    evaluate('(setf lem-yath::*poll-test-path* nil lem-yath::*last-auto-revert-check-time* nil)')
    evaluate('(lem-yath::safe-auto-revert-poll)')
    eventually(text_is('EXTERNAL-A\n'))
    check('(null lem-yath::*safe-auto-revert-scan*)', 'polling resumes after cancelled work finishes')
    evaluate('(lem-yath::poll-test-cleanup)')

    # Reinstall the private wrapper overwritten by the reload test. Shutdown
    # must cancel a blocked read without waiting for its test semaphore.
    evaluate('(load ' + quote(fixture) + ')')
    start_case('shutdown')
    result = subprocess.run(client + ['--stop-server', '--force'], env=env, cwd=root,
                            capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, result.stderr
    assert process.wait(timeout=10) == 0
    print('PASS: clean shutdown while a polling reader is blocked', flush=True)
    (root / 'result.json').write_text(json.dumps(dict(checks=checks, shutdown_exit_code=0), indent=2))
finally:
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
