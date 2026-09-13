"""Configured native smoke for Git callers of frame-owned Legit panes.

Two real PTY clients exercise production display. The administrative fixture
drives message completion/abort, remote refresh and merge preview, simulating
successful Git commits so this test measures UI branches rather than Git itself.
It never loads product code. A final physical key checks the peer input route.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('native_agent_driver', Path(__file__).with_name('native-agent-test.py'))
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


def main():
    editor, client = (os.environ[k] for k in ('LEM_BIN', 'LEMCLIENT_BIN'))
    with tempfile.TemporaryDirectory(prefix='lem-git-pane-callers-') as temporary:
        root = Path(temporary)
        env = dict(os.environ, TERM='xterm-256color', LEM_YATH_OPENROUTER_MODEL_REFRESH='0',
                   LEM_YATH_CODEX_MODEL_REFRESH='0')
        for key in ('XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME',
                    'XDG_DATA_HOME', 'LEM_HOME', 'WORKDIR', 'PUBLIC_ORG_DIR'):
            path = root / key
            path.mkdir(mode=0o700)
            env[key] = str(path)
        projects = []
        for name in ('left', 'right'):
            project = root / name
            project.mkdir()
            (project / 'file.txt').write_text(name + ' unchanged\n')
            subprocess.run(['git', 'init', '-q', str(project)], env=env, check=True)
            subprocess.run(['git', '-C', str(project), 'add', '.'], env=env, check=True)
            subprocess.run(['git', '-C', str(project), '-c', 'user.name=Fixture',
                            '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture'], env=env, check=True)
            projects.append(project)
        command = [client, '--server-name', 'git-pane-callers']
        terminals = []
        daemon = None
        log = root / 'daemon.log'
        failures = []

        def evaluate(form):
            result = subprocess.run(command + ['--wait-for-server', '20', '--eval', form], cwd=projects[0],
                                    env=env, capture_output=True, text=True, timeout=25)
            assert result.returncode == 0, result.stderr
            return json.loads(result.stdout)['primary']

        def eventually(predicate, description):
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if predicate():
                    return
                time.sleep(0.05)
            raise AssertionError(description)

        def frame(terminal, form):
            return evaluate('(let ((target (find ' + str(terminal.columns)
                            + ' lem-daemon::*daemon-connections* :key (lambda (c) '
                            '(let ((i (lem-daemon::connection-implementation c))) '
                            '(and i (lem-daemon::daemon-implementation-width i))))))) '
                            '(when target (lem-daemon::call-with-client-implementation '
                            '(lem-daemon::connection-implementation target) (lambda () ' + form + '))))')

        def snapshot(terminal):
            return frame(terminal, '(list (sxhash (lem:current-window)) '
                         '(lem:buffer-name (lem:current-buffer)) (lem:position-at-point (lem:current-point)) '
                         '(loop for w in (append (lem:window-list) '
                         '(lem-core::frame-floating-windows (lem:current-frame))) '
                         'when (or (member w (lem:window-list)) (typep w \'lem/legit::peek-window) (typep w \'lem/legit::source-window)) collect '
                         '(list (sxhash w) (lem:buffer-name (lem:window-buffer w)) '
                         '(lem:position-at-point (lem:window-point w)) '
                         '(lem:position-at-point (lem:window-view-point w)))))')

        try:
            with log.open('w') as stream:
                daemon = subprocess.Popen([editor, '--daemon=git-pane-callers'], cwd=projects[0], env=env,
                                          stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
            assert evaluate('(lem-yath:boot-ok-p)') == 'T'
            evaluate('(load ' + helper.quote(Path(__file__).with_name('git-pane-callers-fixture.lisp')) + ')')
            for columns, project in zip((117, 139), projects):
                terminal = helper.Terminal(command, project, env, columns)
                terminals.append(terminal)
                eventually(lambda: frame(terminal, 't') == 'T', 'native frame did not attach')
                frame(terminal, '(lem:switch-to-buffer (lem:find-file-buffer ' + helper.quote(project / 'file.txt') + '))')
            left, right = terminals
            frame(right, '(lem/legit::show-legit-status)')
            before = snapshot(right)
            cases = []
            for kind in ('amend', 'revert', 'cherry'):
                for action in ('continue', 'abort'):
                    for state in ('live', 'closed', 'replacement'):
                        cases.append((f'{kind} {action} {state}',
                                      f'(lem-yath::pane-caller-message-case :{kind} :{action} :{state})'))
            for role in ('peek', 'source'):
                for state in ('live', 'closed', 'replacement'):
                    cases.append((f'remote {role} {state}', f'(lem-yath::pane-caller-remote-case :{role} :{state})'))
            for state in ('live', 'closed', 'replacement'):
                cases.append((f'merge preview {state}', f'(lem-yath::pane-caller-merge-case :{state})'))
            for description, form in cases:
                try:
                    assert frame(left, form) == 'T', description
                    assert snapshot(right) == before, 'peer buffer/point/window/focus changed'
                    print('PASS: ' + description + '; peer context preserved', flush=True)
                except AssertionError as error:
                    failures.append(description)
                    print('FAIL: ' + description + ': ' + str(error), flush=True)
            # Deliberate native input, after all asynchronous redraws and pane
            # replacement, must still go to the right client's source file.
            frame(right, '(lem/legit::legit-quit)')
            right.send(b'\x1a')
            eventually(lambda: frame(right, '(lem-yath::lem-yath-emacs-state-p)') == 'T', 'C-z did not enter Emacs state')
            right.send(b'X')
            eventually(lambda: frame(right, '(not (null (search "X" (lem:buffer-text (lem:current-buffer)))))') == 'T',
                       'next native key missed the peer source buffer')
            assert frame(left, '(search "X" (lem:buffer-text (lem:current-buffer)))') == 'NIL'
            print('PASS: next native key remains in peer source buffer', flush=True)
            for project in projects:
                assert subprocess.check_output(['git', '-C', str(project), 'status', '--porcelain'], env=env) == b''
            print('PASS: fixture Git trees and files remain unchanged', flush=True)
            assert not failures, 'Failed Git pane cases: ' + ', '.join(failures)
        except BaseException:
            print(log.read_text(errors='replace')[-5000:], flush=True)
            raise
        finally:
            for terminal in terminals:
                if terminal.master is not None:
                    terminal.close()
            if daemon is not None and daemon.poll() is None:
                try:
                    subprocess.run(command + ['--stop-server', '--force'], cwd=projects[0], env=env,
                                   capture_output=True, timeout=15)
                except subprocess.TimeoutExpired:
                    pass
                try:
                    daemon.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    daemon.kill()
                    daemon.wait(timeout=10)


if __name__ == '__main__':
    main()
