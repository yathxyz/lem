"""Configured native agent acceptance with real terminal clients and fake providers.

LEM_BIN and LEMCLIENT_BIN must name built configured binaries. Only this test's
Lisp fixture is loaded; product systems and default managers must already exist.
An explicitly labeled LEM_AGENT_ACCEPTANCE_SOURCE_BOOTSTRAP=1 run may use an
external source-bootstrap wrapper as LEM_BIN, but is never configured acceptance.
Python only orchestrates tests. The agent, tools, UI and job supervision are Lisp.

PTY input drives message typing/submission, allow/deny, view closure, interrupt,
resume, proposal acceptance/undo, historical restage ID prompts, and confirmed
session-journal deletion, plus draft checkpoint/inspection/restore/submission
and confirmed discard. Administrative eval installs fake providers, creates
sessions and scratch regions, selects views/points, releases a fake stream gate,
injects one edit during a prompt, and inspects state. The driver kills isolated
processes and reads temporary effects/journals. A fourth startup deliberately
encounters a corrupt synthetic draft journal to test the configured failure path.
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

        def start_daemon(drafts_available=True):
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
            check(evaluate('(not (null (and (find-package :lem-agent/edit-recovery) '
                           '(find-package :lem-agent/retention-ui))))') == 'T',
                  'configured image preloads candidate recovery and session journal UIs')
            check(evaluate('lem-agent/ui:*require-durable-drafts*') == 'T',
                  'configured startup requires durable drafts without a transient composer fallback')
            if drafts_available:
                check(evaluate('(and (lem-agent/drafts:store-open-p lem-agent/ui:*default-draft-store*) '
                               '(eq lem-agent/ui:*default-draft-store* lem-yath::*native-agent-draft-store*))') == 'T',
                      'configured startup supplies the shared open draft store')
            else:
                check(evaluate('(and (lem-yath::native-agent-ready-p) '
                               '(lem-toolkit/jobs:job-manager-ready-p lem-toolkit/jobs:*default-manager*) '
                               '(null lem-agent/ui:*default-draft-store*) '
                               '(null lem-yath::*native-agent-draft-store*) '
                               '(stringp lem-yath::*native-agent-draft-recovery-error*))') == 'T',
                      'corrupt draft startup keeps core and jobs ready while draft admission remains unavailable')
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

        def prompt_label(terminal):
            return json.loads(in_frame(terminal, '(lem-native-agent-fixture::prompt-label)'))

        def wait_prompt(terminal, prefix):
            eventually(lambda: prompt_label(terminal).startswith(prefix),
                       'expected originating-client prompt: ' + prefix)

        def prompted_mx(terminal, name, prefix):
            terminal.send(b'\x1bx')
            wait_prompt(terminal, 'Command:')
            terminal.send(name.encode() + b'\r')
            wait_prompt(terminal, prefix)

        def finish_prompt(terminal, answer, line=False):
            terminal.send(answer.encode() + (b'\r' if line else b''))
            eventually(lambda: not prompt_label(terminal), 'native command prompt did not finish')

        def current_buffer(terminal):
            return json.loads(in_frame(terminal, '(lem:buffer-name (lem:current-buffer))'))

        def wait_view(terminal, marker):
            eventually(lambda: marker in text(current_buffer(terminal)),
                       'native view did not render: ' + marker)
            return current_buffer(terminal)

        def type_text(terminal, text):
            vi = evaluate('(not (null (find-package :lem-vi-mode/core)))') == 'T'
            terminal.send((b'i' if vi else b'') + text.encode() + (b'\x1b' if vi else b''))
            if vi:
                time.sleep(0.15)  # separate Escape from the following Meta-x prefix

        def new_session(retained_turns=None):
            argument = '' if retained_turns is None else ' ' + str(retained_turns)
            identifier = json.loads(evaluate('(lem-native-agent-fixture::new-session' + argument + ')'))
            eventually(lambda: evaluate('(lem-native-agent-fixture::session-initialized-p '
                                         + quote(identifier) + ')') == 'T'
                       and snapshot(identifier)['status'] == 'idle', 'durable session initialization failed')
            return identifier

        def snapshot(identifier):
            return value('(lem-native-agent-fixture::snapshot ' + quote(identifier) + ')')

        def show(terminal, identifier, kind='transcript'):
            return json.loads(in_frame(terminal, '(lem-native-agent-fixture::show ' + quote(identifier)
                                       + ' :' + kind + ')'))

        def text(buffer):
            return value('(lem:buffer-text (lem:get-buffer ' + quote(buffer) + '))')

        def retained(identifier):
            return value('(lem-native-agent-fixture::retained-reviews ' + quote(identifier) + ')')

        def draft(identifier):
            return value('(lem-native-agent-fixture::draft ' + quote(identifier) + ')')

        def select_row(terminal, buffer, identifier):
            in_frame(terminal, '(lem-native-agent-fixture::point-at-text ' + quote(buffer)
                     + ' ' + quote(identifier) + ')')

        def restage_prompts(terminal, identifier, review_id, change=None):
            prompted_mx(terminal, 'agent-restage-retained-review', 'Historical session ID:')
            if change is not None:
                # Administrative race only; both ID choices still arrive via PTY.
                evaluate('(lem-native-agent-fixture::edit-recovery-region-during-prompt '
                         + quote(change) + ')')
            terminal.send(identifier.encode() + b'\r')
            wait_prompt(terminal, 'Historical review ID:')
            finish_prompt(terminal, review_id, line=True)

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

            candidate = new_session(retained_turns=1)
            submit(left, candidate, 'edit:replacement retained beyond transcript')
            idle(candidate)
            historical = retained(candidate)[-1]
            historical_id, origin_turn = historical['id'], historical['turn_id']
            old_proposal = historical['result']['proposal_id']
            check(historical['arguments']['original'] == human,
                  'native propose_edit records exact original and replacement for historical review')
            submit(left, candidate, 'complete:evict candidate origin from transcript')
            eventually(lambda: snapshot(candidate)['omitted_turns'] > 0
                       and all(turn['id'] != origin_turn for turn in snapshot(candidate)['turns'])
                       and snapshot(candidate)['status'] == 'idle',
                       'one-turn context did not evict the candidate origin')
            check(retained(candidate)[-1] == historical,
                  'retained candidate survives native transcript trimming without mutation')

            draft_session = new_session()
            show(left, draft_session)
            mx(left, 'agent-compose')
            draft_composer = current_buffer(left)
            draft_message = 'complete:deliberately recovered draft'
            type_text(left, draft_message)
            eventually(lambda: text(draft_composer) == draft_message,
                       'native unsent draft typing did not reach the composer')
            mx(left, 'agent-checkpoint-draft')
            saved_draft = value('(lem-native-agent-fixture::composer-draft ' + quote(draft_composer) + ')')
            draft_id = saved_draft['id']
            eventually(lambda: draft(draft_id) == saved_draft,
                       'explicit native checkpoint did not durably store the exact unsent draft')
            draft_path = Path(directories['drafts']) / (draft_id + '.json')
            check(json.loads(draft_path.read_text()) == saved_draft
                  and not snapshot(draft_session)['turns'] and not snapshot(draft_session)['queue'],
                  'native checkpoint stores exact draft text, point and session without submitting a message')

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

            check(draft(draft_id) == saved_draft and not snapshot(draft_session)['turns']
                  and not snapshot(draft_session)['queue'] and snapshot(draft_session)['status'] == 'idle',
                  'daemon restart restores the exact unsent draft without automatic submission')
            draft_files_before = value('(lem-native-agent-fixture::editor-file-identities)')
            mx(left, 'agent-draft-list')
            draft_list = wait_view(left, draft_id)
            select_row(left, draft_list, draft_id)
            left.send(b'i')
            draft_view = wait_view(left, 'Complete draft text:')
            eventually(lambda: left.saw('Durable agent drafts') and left.saw('Complete draft text:'),
                       'draft list and inspection did not reach the actual native terminal')
            check(draft_message in text(draft_view) and draft_session in text(draft_view)
                  and evaluate('(lem:buffer-read-only-p (lem:get-buffer ' + quote(draft_view) + '))') == 'T'
                  and value('(lem-native-agent-fixture::editor-file-identities)') == draft_files_before
                  and not snapshot(draft_session)['turns'],
                  'native draft inspection shows complete text and exact session without file activation or submission')
            left.send(b'\r')
            eventually(lambda: current_buffer(left) != draft_view
                       and text(current_buffer(left)) == draft_message,
                       'native Return did not restore the exact draft composer')
            restored_composer = current_buffer(left)
            check(in_frame(left, '(null (lem:buffer-filename (lem:current-buffer)))') == 'T'
                  and json.loads(in_frame(left, '(lem-agent:session-id '
                                              '(lem:buffer-value (lem:current-buffer) '
                                              '\'lem-agent/ui::agent-session))')) == draft_session
                  and int(in_frame(left, '(1- (lem:position-at-point (lem:current-point)))')) == saved_draft['point']
                  and not snapshot(draft_session)['turns'],
                  'native draft restore creates an unnamed composer with the original session and point, still unsent')
            left.send(b'\x03\x03')
            eventually(lambda: text(restored_composer) == '',
                       'deliberate C-c C-c did not durably accept and clear the recovered draft')
            idle(draft_session)
            eventually(lambda: draft(draft_id)['text'] == ''
                       and draft(draft_id)['attempt']['status'] == 'accepted',
                       'accepted draft marker and newer cleared checkpoint did not become durable')
            accepted_draft = draft(draft_id)
            check(accepted_draft['attempt']['revision'] == saved_draft['revision']
                  and accepted_draft['revision'] > saved_draft['revision']
                  and len(snapshot(draft_session)['turns']) == 1
                  and sum(message['role'] == 'user' and message['content'] == draft_message
                          for turn in snapshot(draft_session)['turns'] for message in turn['messages']) == 1,
                  'explicit native draft submission runs once and distinguishes accepted text from the newer cleared revision')
            mx(left, 'agent-close-view')
            eventually(lambda: evaluate('(lem-native-agent-fixture::draft-retired-p '
                                         + quote(draft_id) + ')') == 'T',
                       'closed draft composer did not release its exact claim and pending checkpoints')
            mx(left, 'agent-draft-list')
            draft_list = wait_view(left, draft_id)
            select_row(left, draft_list, draft_id)
            left.send(b'i')
            wait_view(left, 'Submission attempt:')
            left.send(b'd')
            wait_prompt(left, 'Discard 0 characters from draft ' + draft_id)
            finish_prompt(left, 'n')
            check(draft(draft_id) is not None and draft_path.exists(),
                  'native draft discard cancellation preserves the accepted submission evidence')
            left.send(b'd')
            wait_prompt(left, 'Discard 0 characters from draft ' + draft_id)
            finish_prompt(left, 'y')
            eventually(lambda: draft(draft_id) is None and not draft_path.exists(),
                       'confirmed native draft discard did not remove the exact checkpoint')
            check(len(snapshot(draft_session)['turns']) == 1,
                  'confirmed native draft discard removes metadata without undoing or repeating its accepted message')

            recovered_historical = retained(candidate)[-1]
            if recovered_historical != historical:
                print('Historical candidate JSON mismatch: ' + json.dumps(
                    {'before': historical, 'after': recovered_historical}), flush=True)
            check(recovered_historical == historical,
                  'daemon restart preserves the exact retained candidate JSON, including false and null values')
            check(all(turn['id'] != origin_turn for turn in snapshot(candidate)['turns']),
                  'daemon restart keeps the historical candidate origin trimmed from the transcript')
            check(evaluate('(null (lem-buffer-proposals:find-proposal '
                           + quote(old_proposal) + '))') == 'T',
                  'daemon restart does not revive the historical candidate\'s old proposal')
            files_before_history = value('(lem-native-agent-fixture::editor-file-identities)')
            proposal_count = value('(length (lem-buffer-proposals:list-proposals))')
            show(left, candidate)
            mx(left, 'agent-retained-reviews')
            historical_list = wait_view(left, historical_id)
            select_row(left, historical_list, historical_id)
            left.send(b'\r')
            historical_view = wait_view(left, 'Original (JSON string):')
            eventually(lambda: left.saw('Historical agent edit candidates'),
                       'historical recovery view did not reach the actual native terminal')
            check('Current applicability and prior application are UNKNOWN' in text(historical_view)
                  and historical['arguments']['replacement'] in text(historical_view)
                  and evaluate('(lem:buffer-read-only-p (lem:get-buffer '
                               + quote(historical_view) + '))') == 'T'
                  and value('(lem-native-agent-fixture::editor-file-identities)') == files_before_history
                  and value('(length (lem-buffer-proposals:list-proposals))') == proposal_count,
                  'native historical list and Return inspection stay read-only, with no file activation or automatic proposal')

            stale_source = json.loads(in_frame(left, '(lem-native-agent-fixture::prepare-recovery-region '
                                               + quote(historical['arguments']['original']) + ')'))
            restage_prompts(left, candidate, historical_id, change=stale_source)
            check('HUMAN changed during prompt' in text(stale_source)
                  and value('(length (lem-buffer-proposals:list-proposals))') == proposal_count,
                  'native restage prompts refuse an administratively injected concurrent source edit and clean the capture')
            fresh_source = json.loads(in_frame(left, '(lem-native-agent-fixture::prepare-recovery-region '
                                               + quote(historical['arguments']['original']) + ')'))
            restage_prompts(left, candidate, historical_id)
            restaged_view = wait_view(left, 'Captured revision:')
            eventually(lambda: left.saw('Captured revision:'),
                       'fresh proposal review did not reach the actual native terminal')
            new_proposal = json.loads(in_frame(left, '(lem-buffer-proposals:proposal-id '
                                              '(lem:buffer-value (lem:current-buffer) '
                                              '\'lem-buffer-proposals::proposal))'))
            check(new_proposal != old_proposal and 'State: pending' in text(restaged_view)
                  and text(fresh_source) == historical['arguments']['original']
                  and (project / 'source.txt').read_text() == 'disk original',
                  'actual restage ID prompts create a fresh pending proposal without applying or saving text')
            mx(left, 'proposal-review-accept')
            check(text(fresh_source) == historical['arguments']['replacement']
                  and 'HUMAN changed during prompt' in text(stale_source)
                  and (project / 'source.txt').read_text() == 'disk original',
                  'separate native proposal acceptance applies only the explicitly selected recovery region')

            loaded_before = value('(lem-native-agent-fixture::loaded-session-ids)')
            right_focus = current_buffer(right)
            mx(left, 'agent-journals')
            inventory = wait_view(left, 'Stored agent sessions')
            eventually(lambda: fast in text(inventory), 'native journal inventory did not list the selected session')
            select_row(left, inventory, fast)
            left.send(b'\r')
            journal_view = wait_view(left, 'Exact stored fingerprint:')
            eventually(lambda: left.saw('Stored agent sessions') and left.saw('Stored session ' + fast),
                       'journal inventory and inspection did not reach the actual native terminal')
            check('Stored session ' + fast in text(journal_view)
                  and value('(lem-native-agent-fixture::loaded-session-ids)') == loaded_before
                  and value('(lem-native-agent-fixture::editor-file-identities)') == files_before_history,
                  'native journal inventory and Return inspection neither activate sessions nor visit editor files')
            left.send(b'x')
            wait_prompt(left, 'Permanently close session ' + fast)
            finish_prompt(left, 'y')
            eventually(lambda: snapshot(fast)['status'] == 'closed'
                       and 'Stored status: closed' in text(journal_view)
                       and evaluate('(null (lem:buffer-value (lem:get-buffer ' + quote(journal_view)
                                    + ') \'lem-agent/retention-ui::pending))') == 'T',
                       'native confirmed journal close did not finish and refresh')
            closed_generation = snapshot(fast)['generation']
            mx(left, 'agent-journal-refresh')
            eventually(lambda: evaluate('(null (lem:buffer-value (lem:get-buffer ' + quote(journal_view)
                                         + ') \'lem-agent/retention-ui::pending))') == 'T',
                       'closed journal inspection did not finish')
            check(snapshot(fast)['generation'] == closed_generation
                  and evaluate('(not (bt2:thread-alive-p (lem-agent::session-thread '
                               '(lem-native-agent-fixture::session ' + quote(fast) + '))))') == 'T',
                  'refreshing the closed journal does not recreate or resume its stopped actor')
            journal_path = Path(directories['agents']) / (fast + '.json')
            left.send(b'd')
            wait_prompt(left, 'Discard ALL stored history for ' + fast)
            finish_prompt(left, 'n')
            check(journal_path.exists() and fast in value('(lem-native-agent-fixture::loaded-session-ids)'),
                  'native journal discard cancellation preserves the selected history')
            left.send(b'd')
            wait_prompt(left, 'Discard ALL stored history for ' + fast)
            finish_prompt(left, 'y')
            eventually(lambda: 'durably discarded' in text(journal_view) and not journal_path.exists(),
                       'native confirmed journal deletion did not become durable')
            check(value('(lem-native-agent-fixture::loaded-session-ids)')
                  == [identifier for identifier in loaded_before if identifier != fast]
                  and current_buffer(right) == right_focus
                  and text(fresh_source) == historical['arguments']['replacement'],
                  'confirmed native journal deletion removes only the selected session and preserves other client focus and source buffers')
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
            check(retained(candidate)[-1] == historical
                  and fast not in value('(lem-native-agent-fixture::loaded-session-ids)')
                  and not journal_path.exists(),
                  'orderly restart preserves retained candidates and keeps explicitly deleted session history absent')
            check(draft(draft_id) is None and not draft_path.exists()
                  and len(snapshot(draft_session)['turns']) == 1,
                  'orderly restart keeps the discarded draft absent and its accepted message present exactly once')
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
            for terminal in (left, right):
                terminal.process.wait(timeout=10)

            # This is an owned synthetic journal, created only while the daemon
            # is stopped. No user file or existing recovery evidence is changed.
            corrupt_path = Path(directories['drafts']) / ('f' * 32 + '.json')
            check(not corrupt_path.exists(), 'synthetic corrupt draft fixture has a fresh exact identity')
            corrupt_bytes = b'{"version":1,"native_fixture":"deliberately truncated draft"'
            with corrupt_path.open('xb') as out:
                out.write(corrupt_bytes)
                out.flush()
                os.fsync(out.fileno())
            corrupt_path.chmod(0o600)
            daemon = start_daemon(drafts_available=False)
            left = attach(117)
            transcript = show(left, draft_session)
            wait_view(left, draft_session)
            composer_count = value('(hash-table-count lem-agent/ui::*composers*)')
            mx(left, 'agent-compose')
            eventually(lambda: left.saw('Durable agent drafts are unavailable'),
                       'degraded startup did not explain the native composer refusal')
            check(current_buffer(left) == transcript
                  and value('(hash-table-count lem-agent/ui::*composers*)') == composer_count
                  and len(snapshot(draft_session)['turns']) == 1,
                  'native composer creation refuses unavailable draft storage without a buffer or automatic message')
            mx(left, 'lem-yath-agent-recovery-report')
            report = wait_view(left, 'Draft recovery: unavailable')
            eventually(lambda: left.saw('Draft recovery: unavailable'),
                       'degraded recovery report did not reach the actual native terminal')
            check('Agent core: ready' in text(report)
                  and 'Draft recovery unavailable (' in text(report)
                  and str(corrupt_path.parent) in text(report)
                  and corrupt_path.read_bytes() == corrupt_bytes,
                  'native recovery report explains degraded draft storage and preserves the corrupt journal byte for byte')
            run('--stop-server', '--force')
            check(daemon.wait(timeout=15) == 0, 'degraded native agent daemon shuts down cleanly')
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
