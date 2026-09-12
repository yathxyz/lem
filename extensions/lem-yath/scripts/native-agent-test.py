"""Configured native agent acceptance with real terminal clients and fake providers.

LEM_BIN and LEMCLIENT_BIN must name built configured binaries. Only this test's
Lisp fixture is loaded; product systems and default managers must already exist.
An explicitly labeled LEM_AGENT_ACCEPTANCE_SOURCE_BOOTSTRAP=1 run may use an
external source-bootstrap wrapper as LEM_BIN, but is never configured acceptance.
Python only orchestrates tests. The agent, tools, UI and job supervision are Lisp.

PTY input drives message typing/submission, allow/deny, view closure, interrupt,
resume, proposal acceptance and undo. Administrative eval installs fake providers,
creates sessions, selects views/points, releases a fake stream gate and inspects
state. The driver kills isolated processes and reads temporary effects/journals.
"""

import fcntl
import json
import os
from pathlib import Path
import pty
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time


def quote(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


def process_identity(pid):
    try:
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()
        return None if fields[0] in 'ZX' else fields[19]
    except (FileNotFoundError, ProcessLookupError):
        return None


class Terminal:
    def __init__(self, command, root, env, columns):
        self.columns = columns
        self.master, slave = pty.openpty()
        self.output = bytearray()
        self.lock = threading.Lock()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, columns, 0, 0))
        self.process = subprocess.Popen(command + ['-t'], cwd=root, env=env,
                                        stdin=slave, stdout=slave, stderr=slave,
                                        start_new_session=True)
        os.close(slave)
        self.reader = threading.Thread(target=self.drain, daemon=True)
        self.reader.start()

    def drain(self):
        descriptor = self.master
        try:
            while data := os.read(descriptor, 8192):
                with self.lock:
                    self.output.extend(data)
                    del self.output[:-1024 * 1024]
        except OSError:
            pass

    def saw(self, text):
        with self.lock:
            return text.encode() in self.output

    def send(self, data):
        assert self.process.poll() is None, 'native client exited unexpectedly'
        os.write(self.master, data)

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait(timeout=10)
        if self.master is not None:
            os.close(self.master)
            self.master = None
        self.reader.join(timeout=2)


def main():
    editor, client = os.environ['LEM_BIN'], os.environ['LEMCLIENT_BIN']
    bootstrap = os.environ.get('LEM_AGENT_ACCEPTANCE_SOURCE_BOOTSTRAP') == '1'
    label = 'SOURCE BOOTSTRAP PRECHECK' if bootstrap else 'CONFIGURED NATIVE ACCEPTANCE'
    print(label + ': fake providers only; no credential reads or network calls', flush=True)
    fixture = Path(__file__).with_name('native-agent-fixture.lisp')
    deadline = time.monotonic() + 240
    with tempfile.TemporaryDirectory(prefix='lem-native-agent-') as temporary:
        root = Path(temporary)
        env = dict(os.environ, TERM='xterm-256color',
                   LEM_YATH_OPENROUTER_MODEL_REFRESH='0', LEM_YATH_CODEX_MODEL_REFRESH='0')
        for variable in ('XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME',
                         'XDG_STATE_HOME', 'XDG_DATA_HOME', 'LEM_HOME'):
            path = root / variable
            path.mkdir(mode=0o700)
            env[variable] = str(path)
        project = root / 'project'
        project.mkdir(mode=0o700)
        (project / 'source.txt').write_text('disk original')
        (project / 'once.py').write_text(
            'import pathlib,sys\n'
            'p=pathlib.Path(sys.argv[1]+".effects")\n'
            'with p.open("a") as out: out.write("effect\\n")\n'
            'print("fixture process done")\n')
        (project / 'long.py').write_text(
            'import json,os,pathlib,subprocess,sys,time\n'
            'child=subprocess.Popen([sys.executable,"-c","import time;time.sleep(90)"])\n'
            'pathlib.Path(sys.argv[1]+".pids").write_text(json.dumps([os.getpid(),child.pid]))\n'
            'with open(sys.argv[1]+".effects","a") as out: out.write("effect\\n")\n'
            'print("fixture child running",flush=True)\n'
            'time.sleep(90)\n')
        command = [client, '--server-name', 'native-agent-test']
        terminals, daemons, logs, owned_pids = [], [], [], []
        daemon = None

        def run(*arguments, timeout=15):
            assert time.monotonic() < deadline, 'native acceptance deadline exceeded'
            result = subprocess.run(command + list(arguments), cwd=project, env=env,
                                    capture_output=True, text=True, timeout=timeout)
            assert result.returncode == 0, result.stderr or result.stdout
            return json.loads(result.stdout)['primary'] if result.stdout.strip() else None

        def evaluate(form):
            return run('--eval', form)

        def value(form):
            return json.loads(json.loads(evaluate('(lem-native-agent-fixture::json ' + form + ')')))

        def eventually(predicate, description, timeout=15):
            until = min(deadline, time.monotonic() + timeout)
            while time.monotonic() < until:
                if predicate():
                    return
                time.sleep(0.04)
            raise AssertionError(description)

        def check(condition, description):
            assert condition, description
            print('PASS: ' + description, flush=True)

        def start_daemon():
            log_path = root / f'daemon-{len(daemons)}.log'
            logs.append(log_path)
            with log_path.open('w') as log:
                process = subprocess.Popen([editor, '--daemon=native-agent-test'], cwd=project,
                                           env=env, stdout=log, stderr=subprocess.STDOUT,
                                           start_new_session=True)
            daemons.append(process)
            run('--wait-for-server', '30', '--eval', 't', timeout=35)
            check(evaluate('(and (find-package :lem-agent/ui) '
                           '(boundp (find-symbol "*DEFAULT-MANAGER*" :lem-agent/ui)) '
                           '(not (null (symbol-value (find-symbol "*DEFAULT-MANAGER*" :lem-agent/ui)))))') == 'T',
                  'startup supplies the native agent manager before fixture loading')
            if not bootstrap:
                check(evaluate('(lem-yath:boot-ok-p)') == 'T', 'configured startup has no boot error')
            evaluate('(load ' + quote(fixture) + ')')
            private_directories = value('(lem-native-agent-fixture::journal-directories)')
            check(all(Path(path).resolve().is_relative_to(root) for path in private_directories.values()),
                  'configured managers use the isolated temporary journal namespace')
            evaluate('(lem-native-agent-fixture::install ' + quote(str(project) + '/')
                     + ' ' + quote(sys.executable) + ')')
            return process

        count = '(count-if #\'lem-daemon::connection-implementation lem-daemon::*daemon-connections*)'

        def attach(columns):
            terminal = Terminal(command, project, env, columns)
            terminals.append(terminal)
            eventually(lambda: in_frame(terminal, 't') == 'T', 'terminal frame did not attach')
            return terminal

        def in_frame(terminal, form):
            return evaluate('(let ((old (lem:implementation)) '
                            '(target (find ' + str(terminal.columns) + ' lem-daemon::*daemon-connections* '
                            ':key (lambda (c) (let ((i (lem-daemon::connection-implementation c))) '
                            '(and i (lem-daemon::daemon-implementation-width i))))))) '
                            '(when target (unwind-protect (progn (lem-daemon::activate-implementation '
                            '(lem-daemon::connection-implementation target)) ' + form + ') '
                            '(lem-daemon::activate-implementation old))))')

        def mx(terminal, name):
            terminal.send(b'\x1bx')
            eventually(lambda: in_frame(terminal, '(not (null (lem-core::frame-prompt-active-p '
                                                     '(lem:current-frame))))') == 'T',
                       'M-x did not enter the originating client prompt')
            terminal.send(name.encode() + b'\r')
            eventually(lambda: in_frame(terminal, '(null (lem-core::frame-prompt-active-p '
                                                     '(lem:current-frame)))') == 'T',
                       'M-x command did not finish in the originating client')

        def type_text(terminal, text):
            vi = evaluate('(not (null (find-package :lem-vi-mode/core)))') == 'T'
            terminal.send((b'i' if vi else b'') + text.encode() + (b'\x1b' if vi else b''))
            if vi:
                time.sleep(0.15)  # separate Escape from the following Meta-x prefix

        def new_session():
            identifier = json.loads(evaluate('(lem-native-agent-fixture::new-session)'))
            eventually(lambda: snapshot(identifier)['status'] == 'idle', 'session initialization failed')
            return identifier

        def snapshot(identifier):
            return value('(lem-native-agent-fixture::snapshot ' + quote(identifier) + ')')

        def show(terminal, identifier, kind='transcript'):
            return json.loads(in_frame(terminal, '(lem-native-agent-fixture::show ' + quote(identifier)
                                       + ' :' + kind + ')'))

        def text(buffer):
            return value('(lem:buffer-text (lem:get-buffer ' + quote(buffer) + '))')

        def submit(terminal, identifier, message):
            show(terminal, identifier)
            mx(terminal, 'agent-compose')
            composer = json.loads(in_frame(terminal, '(lem:buffer-name (lem:current-buffer))'))
            type_text(terminal, message)
            eventually(lambda: text(composer) == message, 'native typing did not reach the composer')
            mx(terminal, 'agent-submit')
            eventually(lambda: text(composer) == '', 'durable acceptance did not clear unchanged composer')
            return composer

        def idle(identifier, turns=1):
            eventually(lambda: snapshot(identifier)['status'] == 'idle'
                       and len(snapshot(identifier)['turns']) >= turns
                       and not snapshot(identifier)['queue'], 'agent did not finish its turn')

        def pending(identifier):
            return next((item for item in snapshot(identifier)['decisions'] if item['status'] == 'pending'), None)

        def decision_view(terminal, identifier):
            eventually(lambda: pending(identifier), 'permission was not requested')
            decision = pending(identifier)
            buffer = show(terminal, identifier, 'decisions')
            eventually(lambda: decision['id'] in text(buffer), 'decision view did not render')
            in_frame(terminal, '(lem-native-agent-fixture::point-at-decision ' + quote(buffer)
                     + ' ' + quote(decision['id']) + ')')
            check('run_process' in text(buffer) and 'Arguments:' in text(buffer),
                  'permission view shows the exact native tool and arguments')
            return buffer, decision['id']

        def jobs(identifier):
            return value('(lem-native-agent-fixture::session-jobs ' + quote(identifier) + ')')

        def track_processes(kind):
            path = project / (kind + '.pids')
            pids = []

            def published():
                nonlocal pids
                try:
                    pids = json.loads(path.read_text())
                    return len(pids) == 2
                except (FileNotFoundError, json.JSONDecodeError):
                    return False

            eventually(published, 'managed child fixture did not start')
            identities = [(pid, process_identity(pid)) for pid in pids]
            check(all(identity for _, identity in identities), 'managed parent and child are running')
            owned_pids.extend(identities)
            return identities

        def gone(identities):
            return all(process_identity(pid) != identity for pid, identity in identities)

        try:
            daemon = start_daemon()
            left, right = attach(83), attach(107)
            check(evaluate(count) == '2', 'two real native terminal clients are attached')
            directories = value('(lem-native-agent-fixture::journal-directories)')
            slow, fast = new_session(), new_session()
            submit(left, slow, 'stream:alpha')
            first, second = show(left, slow), show(right, slow)
            check(first != second, 'two native clients have independent views of one session')
            eventually(lambda: 'alpha stream λ' in text(first) and 'alpha stream λ' in text(second),
                       'stream did not reach both transcript buffers')
            eventually(lambda: left.saw('alpha stream') and right.saw('alpha stream'),
                       'stream did not reach both actual terminal displays')
            submit(right, fast, 'complete:independent fast session')
            idle(fast)
            right_buffer = in_frame(right, '(lem:buffer-name (lem:current-buffer))')
            evaluate('(lem-native-agent-fixture::release-stream ' + quote(slow) + ')')
            idle(slow)
            check(in_frame(right, '(lem:buffer-name (lem:current-buffer))') == right_buffer,
                  'stream completion preserves the other client focus and independent session')

            approved = new_session()
            submit(left, approved, 'process:once')
            view1, decision = decision_view(left, approved)
            view2, _ = decision_view(right, approved)
            left.close()
            eventually(lambda: evaluate(count) == '1', 'killed client was not detached')
            mx(right, 'agent-close-view')
            check(pending(approved)['id'] == decision and not (project / 'once.effects').exists(),
                  'client loss and decision-view closure leave permission pending with no effect')
            left = attach(89)
            view1, _ = decision_view(left, approved)
            view2, _ = decision_view(right, approved)
            mx(left, 'agent-allow')
            mx(right, 'agent-allow')  # stale or already resolved is an explicit UI rejection
            idle(approved)
            check((project / 'once.effects').read_text() == 'effect\n' and len(jobs(approved)) == 1,
                  'real native approval commands resolve a shared decision once after reconnect')
            record = json.loads((Path(directories['agents']) / (approved + '.json')).read_text())
            check(any(item.get('answer') == 'allow' for item in record['decisions']),
                  'approval and accepted work are inspectable in the private agent journal')

            denied = new_session()
            submit(right, denied, 'process:deny')
            decision_view(right, denied)
            mx(right, 'agent-deny')
            idle(denied)
            check(not (project / 'deny.effects').exists() and not jobs(denied),
                  'native denial starts no process and creates no effect')

            interrupted = new_session()
            submit(left, interrupted, 'process:long')
            decision_view(left, interrupted)
            mx(left, 'agent-allow')
            identities = track_processes('long')
            submit(right, interrupted, 'complete:queued after interrupt')
            show(left, interrupted)
            mx(left, 'agent-interrupt')
            eventually(lambda: snapshot(interrupted)['status'] == 'interrupted' and gone(identities),
                       'interruption did not stop the managed process and child')
            check(len(snapshot(interrupted)['queue']) == 1,
                  'queued follow-up survives interruption without automatic execution')
            mx(left, 'agent-resume')
            idle(interrupted, 2)
            check(any('queued after interrupt' == message.get('content')
                      for turn in snapshot(interrupted)['turns'] for message in turn['messages']),
                  'native resume deliberately processes the retained follow-up')

            evaluate('(lem-native-agent-fixture::prepare-source)')
            edited = new_session()
            submit(left, edited, 'edit:stale candidate')
            idle(edited)
            results = value('(lem-native-agent-fixture::tool-results ' + quote(edited) + ' "propose_edit")')
            proposal = results[-1]['proposal_id']
            inspection = value('(lem-native-agent-fixture::tool-results ' + quote(edited) + ' "read_file")')[-1]
            check(inspection['source'] == 'buffer' and inspection['modified']
                  and inspection['content'] == 'human unsaved original'
                  and value('(lem:buffer-text (lem-native-agent-fixture::source-buffer))') == 'human unsaved original'
                  and (project / 'source.txt').read_text() == 'disk original',
                  'native read/propose tools use unsaved text and stage without mutating source or disk')
            in_frame(left, '(lem-native-agent-fixture::show-proposal ' + quote(proposal) + ')')
            in_frame(right, '(lem-native-agent-fixture::show-source 5)')
            type_text(right, 'HUMAN')
            eventually(lambda: 'HUMAN' in value('(lem:buffer-text (lem-native-agent-fixture::source-buffer))'),
                       'concurrent native human edit did not arrive')
            human = value('(lem:buffer-text (lem-native-agent-fixture::source-buffer))')
            mx(left, 'proposal-review-accept')
            check(evaluate('(eq :conflict (lem-buffer-proposals:proposal-state '
                           '(lem-buffer-proposals:find-proposal ' + quote(proposal) + ')))') == 'T'
                  and value('(lem:buffer-text (lem-native-agent-fixture::source-buffer))') == human,
                  'native proposal acceptance preserves a concurrent human edit and shows conflict')
            submit(left, edited, 'edit:accepted candidate')
            idle(edited, 2)
            proposal = value('(lem-native-agent-fixture::tool-results ' + quote(edited) + ' "propose_edit")')[-1]['proposal_id']
            in_frame(left, '(lem-native-agent-fixture::show-proposal ' + quote(proposal) + ')')
            mx(left, 'proposal-review-accept')
            check(value('(lem:buffer-text (lem-native-agent-fixture::source-buffer))') == 'accepted candidate',
                  'explicit native proposal acceptance applies the reviewed edit')
            mx(left, 'undo')
            check(value('(lem:buffer-text (lem-native-agent-fixture::source-buffer))') == human
                  and (project / 'source.txt').read_text() == 'disk original',
                  'one native undo restores the unsaved human text without writing disk')

            active, waiting = new_session(), new_session()
            submit(left, active, 'process:crash')
            decision_view(left, active)
            mx(left, 'agent-allow')
            crash_pids = track_processes('crash')
            submit(right, active, 'complete:resumed after daemon crash')
            submit(right, waiting, 'process:restart-pending')
            decision_view(right, waiting)
            pending_id = pending(waiting)['id']
            daemon.kill()
            check(daemon.wait(timeout=10) == -signal.SIGKILL, 'isolated daemon is killed during active work')
            eventually(lambda: gone(crash_pids), 'daemon failure left managed descendants running')
            for terminal in (left, right):
                terminal.process.wait(timeout=10)
            daemon = start_daemon()
            left, right = attach(91), attach(109)
            check(snapshot(active)['status'] == 'interrupted' and len(snapshot(active)['queue']) == 1,
                  'daemon restart retains active session history and queued follow-ups as interrupted')
            check(any(message.get('content', {}).get('outcome') == 'unknown'
                      for turn in snapshot(active)['turns'] for message in turn['messages']
                      if message['role'] == 'tool' and isinstance(message.get('content'), dict)),
                  'recovered active tool explicitly reports an unknown external outcome')
            cancelled = next(item for item in snapshot(waiting)['decisions'] if item['id'] == pending_id)
            check(cancelled['status'] == 'cancelled' and cancelled['reason'] == 'daemon-interrupted',
                  'daemon restart cancels the old pending permission without answering it')
            check((project / 'crash.effects').read_text() == 'effect\n'
                  and not (project / 'restart-pending.effects').exists()
                  and all(item['state'] == 'interrupted' for item in jobs(active)),
                  'restart never replays uncertain processes or pending permissions')
            show(left, active)
            mx(left, 'agent-resume')
            idle(active, 2)
            check((project / 'crash.effects').read_text() == 'effect\n',
                  'native resume after restart runs only the explicit retained follow-up')
            for directory in directories.values():
                records = list(Path(directory).glob('*.json'))
                check(bool(records) and all((path.stat().st_mode & 0o777) == 0o600 for path in records)
                      and all(isinstance(json.loads(path.read_text()), dict) for path in records),
                      'private journals remain parseable after daemon recovery: ' + Path(directory).name)

            # Deliberate session closure and daemon shutdown have distinct meanings.
            show(right, denied)
            mx(right, 'agent-close-session')
            eventually(lambda: snapshot(denied)['status'] == 'closed', 'native close-session did not finish')
            run('--stop-server', '--force')
            check(daemon.wait(timeout=15) == 0, 'agent daemon shuts down cleanly')
            for terminal in (left, right):
                terminal.process.wait(timeout=10)
            daemon = start_daemon()
            left, right = attach(95), attach(113)
            check(snapshot(active)['status'] == 'idle' and snapshot(denied)['status'] == 'closed',
                  'orderly daemon restart preserves idle sessions and explicit human session closure')
            submit(left, active, 'complete:usable after orderly shutdown')
            idle(active, 3)
            check(any(message.get('content') == 'usable after orderly shutdown'
                      for turn in snapshot(active)['turns'] for message in turn['messages']),
                  'a restored idle session accepts native client input after orderly shutdown')
            check((project / 'crash.effects').read_text() == 'effect\n'
                  and not (project / 'restart-pending.effects').exists(),
                  'orderly restart also leaves uncertain and cancelled effects unreplayed')
            run('--stop-server', '--force')
            check(daemon.wait(timeout=15) == 0, 'final native agent daemon shuts down cleanly')
            print(label + ' PASSED', flush=True)
        except BaseException:
            for path in logs:
                print(path.name + ':\n' + path.read_text(errors='replace')[-8000:], flush=True)
            for terminal in terminals:
                with terminal.lock:
                    print(f'PTY {terminal.columns} tail: {bytes(terminal.output[-3000:])!r}', flush=True)
            raise
        finally:
            for terminal in terminals:
                try:
                    terminal.close()
                except OSError:
                    pass
            for process in reversed(daemons):
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=10)
            for pid, identity in owned_pids:
                if identity is not None and process_identity(pid) == identity:
                    os.kill(pid, signal.SIGKILL)


if __name__ == '__main__':
    main()
