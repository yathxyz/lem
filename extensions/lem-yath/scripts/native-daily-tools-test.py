"""Native project, Bash terminal and self-connected Lisp REPL acceptance.

Only temporary projects and private daemon state are used. Real PTY keys drive
commands; administrative eval selects fixture buffers and observes state.
Python is an external test driver, not part of the editor or Lisp tool runtime.
"""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

spec = importlib.util.spec_from_file_location('native_agent_driver', Path(__file__).with_name('native-agent-test.py'))
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
quote, Terminal = helper.quote, helper.Terminal


def main():
    editor, client, bash = (os.environ[k] for k in ('LEM_BIN', 'LEMCLIENT_BIN', 'LEM_TEST_BASH'))
    with tempfile.TemporaryDirectory(prefix='lem-native-daily-tools-') as temporary:
        root = Path(temporary)
        env = dict(os.environ, TERM='xterm-256color', LEM_YATH_OPENROUTER_MODEL_REFRESH='0',
                   LEM_YATH_CODEX_MODEL_REFRESH='0')
        for key in ('XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME',
                    'XDG_DATA_HOME', 'LEM_HOME', 'WORKDIR', 'PUBLIC_ORG_DIR'):
            path = root / key
            path.mkdir(mode=0o700)
            env[key] = str(path)
        project = root / 'project with spaces;literal'
        project.mkdir()
        subprocess.run(['git', 'init', '-q', str(project)], env=env, check=True)
        source, target = project / 'source.lisp', project / 'target.txt'
        source.write_text('(values :native-daily-tools)\n')
        target.write_text('project target\n')
        subprocess.run(['git', '-C', str(project), 'add', '.'], env=env, check=True)
        shell = root / 'private-shell'
        shell.write_text('#!' + bash + '\nexec ' + bash + ' --noprofile --norc -i\n')
        shell.chmod(0o700)
        env['SHELL'] = str(shell)
        pidfile = root / 'shell.pid'
        command = [client, '--server-name', 'native-daily-tools']
        terminals, daemon = [], None
        shell_identity = None
        log = root / 'daemon.log'

        def evaluate(form):
            result = subprocess.run(command + ['--wait-for-server', '20', '--eval', form],
                                    cwd=project, env=env, capture_output=True, text=True, timeout=30)
            assert result.returncode == 0, result.stderr
            return json.loads(result.stdout)['primary']

        def eventually(predicate, description, timeout=15):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if predicate():
                    return
                time.sleep(0.05)
            raise AssertionError(description)

        def check(condition, description):
            assert condition, description
            print('PASS: ' + description, flush=True)

        def frame(terminal, form):
            return evaluate('(let ((old (lem:implementation)) (target (find ' + str(terminal.columns)
                            + ' lem-daemon::*daemon-connections* :key (lambda (c) '
                            '(let ((i (lem-daemon::connection-implementation c))) '
                            '(and i (lem-daemon::daemon-implementation-width i))))))) '
                            '(when target (unwind-protect (progn (lem-daemon::activate-implementation '
                            '(lem-daemon::connection-implementation target)) ' + form + ') '
                            '(lem-daemon::activate-implementation old))))')

        def attach(columns):
            terminal = Terminal(command, project, env, columns)
            terminals.append(terminal)
            eventually(lambda: frame(terminal, 't') == 'T', 'native terminal did not attach')
            return terminal

        def prompt(terminal):
            return frame(terminal, '(not (null (lem-core::frame-prompt-active-p (lem:current-frame))))') == 'T'

        def mx(terminal, name, answer=None):
            terminal.send(b'\x1bx')
            eventually(lambda: prompt(terminal), 'M-x did not prompt')
            terminal.send(name.encode() + b'\r')
            if answer is not None:
                eventually(lambda: terminal.saw('Project file'), 'project file prompt did not render')
                terminal.send(answer.encode() + b'\r')
            eventually(lambda: not prompt(terminal), 'M-x did not finish: ' + name)

        try:
            with log.open('w') as stream:
                daemon = subprocess.Popen([editor, '--daemon=native-daily-tools'], cwd=project, env=env,
                                          stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
            check(evaluate('(lem-yath:boot-ok-p)') == 'T', 'configured daemon starts with private roots')
            left, right = attach(111), attach(133)
            for terminal in (left, right):
                frame(terminal, '(lem:switch-to-buffer (lem:find-file-buffer ' + quote(source) + '))')
            mx(left, 'lem-yath-project-find-file', 'target.txt')
            check(json.loads(frame(left, '(lem:buffer-filename (lem:current-buffer))')) == str(target)
                  and json.loads(frame(right, '(lem:buffer-filename (lem:current-buffer))')) == str(source),
                  'native project picker visits its file and preserves the other client')
            mx(left, 'vterm')
            eventually(lambda: frame(left, '(eq (lem:buffer-major-mode (lem:current-buffer)) '
                                           '\'lem-terminal/terminal-mode::terminal-mode)') == 'T',
                       'vterm did not open a terminal buffer')
            terminal_name = json.loads(frame(left, '(lem:buffer-name (lem:current-buffer))'))
            left.send(('printf "%s\\n" "$$" > ' + str(pidfile) + '\r').encode())
            eventually(lambda: pidfile.exists() and pidfile.read_text().strip().isdigit(),
                       'Bash did not receive terminal input')
            shell_identity = helper.process_identity(int(pidfile.read_text()))
            assert shell_identity is not None, 'Bash process exited before readiness'
            left.send(b'printf "NATIVE-SHELL:%s\\n" "$PWD"\r')
            eventually(lambda: left.saw('NATIVE-SHELL:' + str(project)), 'Bash output did not render')
            check(True, 'native terminal runs Bash in the literal project directory')
            mx(right, 'start-lisp-repl')
            eventually(lambda: frame(right, '(eq (lem:buffer-major-mode (lem:current-buffer)) '
                                            '\'lem-lisp-mode/internal::lisp-repl-mode)') == 'T',
                       'self-connected Lisp REPL did not open')
            # Emacs state makes literal REPL input independent of prior Vi state.
            right.send(b'\x1a')
            eventually(lambda: frame(right, '(lem-yath::lem-yath-emacs-state-p)') == 'T',
                       'native C-z did not enter Emacs state for REPL input')
            right.send(b'(defparameter cl-user::*native-daily-counter* 41)\r')
            eventually(lambda: evaluate('(and (boundp \'cl-user::*native-daily-counter*) '
                                        '(= 41 cl-user::*native-daily-counter*))') == 'T',
                       'REPL input was not evaluated in the persistent Lisp image')
            eventually(lambda: evaluate('(null lem-lisp-mode/internal::*repl-evaluating*)') == 'T',
                       'REPL response did not finish and publish its next prompt')
            check(frame(right, '(lem:end-buffer-p (lem:current-point))') == 'T',
                  'completed REPL response leaves its client at the next input prompt')
            check(True, 'native Lisp REPL evaluates in the daemon image')
            left.close()
            check(evaluate('(= 41 cl-user::*native-daily-counter*)') == 'T'
                  and helper.process_identity(int(pidfile.read_text())) is not None,
                  'closing a client retains shell process and Lisp state')
            right.send(b'(incf cl-user::*native-daily-counter*)\r')
            eventually(lambda: evaluate('(= 42 cl-user::*native-daily-counter*)') == 'T',
                       'surviving REPL client did not accept next input')
            right.close()
            eventually(lambda: evaluate('(zerop (count-if #\'lem-daemon::connection-implementation '
                                        'lem-daemon::*daemon-connections*))') == 'T', 'clients did not detach')
            fresh = attach(155)
            frame(fresh, '(lem:switch-to-buffer (lem:get-buffer ' + quote(terminal_name) + '))')
            fresh.send(b'printf "REATTACHED-%s\\n" SHELL\r')
            eventually(lambda: fresh.saw('REATTACHED-SHELL'), 'reattached shell did not render')
            check(evaluate('(= 42 cl-user::*native-daily-counter*)') == 'T',
                  'last-client detach and reconnect retain terminal buffer and Lisp state')
            fresh.send(b'exit\r')
            eventually(lambda: helper.process_identity(int(pidfile.read_text())) is None,
                       'explicit shell exit did not terminate its process')
            check(evaluate('(lem-yath:boot-ok-p)') == 'T', 'shell exit leaves the editor available')
            check(source.read_text() == '(values :native-daily-tools)\n' and target.read_text() == 'project target\n',
                  'daily workflows leave project fixture files unchanged')
        except BaseException:
            print(log.read_text(errors='replace')[-12000:], flush=True)
            for terminal in terminals:
                with terminal.lock:
                    print(bytes(terminal.output[-5000:]).decode(errors='replace'), flush=True)
            raise
        finally:
            for terminal in terminals:
                if terminal.master is not None:
                    terminal.close()
            if daemon is not None and daemon.poll() is None:
                subprocess.run(command + ['--stop-server'], cwd=project, env=env,
                               capture_output=True, timeout=15)
                try:
                    daemon.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    daemon.kill()
                    daemon.wait(timeout=10)
            if pidfile.exists():
                pid = int(pidfile.read_text())
                if shell_identity is not None and helper.process_identity(pid) == shell_identity:
                    os.kill(pid, signal.SIGKILL)


if __name__ == '__main__':
    main()
