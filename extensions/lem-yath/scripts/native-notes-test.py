#!/usr/bin/env python3
"""Configured notes acceptance with two real native terminal clients.

LEM_BIN/LEMCLIENT_BIN must be configured binaries with notes already preloaded.
Only native-notes-fixture.lisp is loaded. PTYs drive notes commands, captures,
file prompts, typing, undo, save, checkpoints, and recovery. Administrative eval
only installs deterministic test clocks, observes state, selects buffers/points,
changes the temporary environment, and installs recovery file-hook guards.
All notes and journals belong to a temporary tree. HOME is never changed.
"""

import datetime
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


_helper_spec = importlib.util.spec_from_file_location(
    'native_agent_terminal_helpers', Path(__file__).with_name('native-agent-test.py'))
_helpers = importlib.util.module_from_spec(_helper_spec)
_helper_spec.loader.exec_module(_helpers)
Terminal, quote = _helpers.Terminal, _helpers.quote


def decode_value(primary):
    return json.loads(json.loads(primary))


def main():
    editor, client = os.environ['LEM_BIN'], os.environ['LEMCLIENT_BIN']
    assert os.environ.get('LEM_NOTES_ACCEPTANCE_SOURCE_BOOTSTRAP') != '1', \
        'this gate requires the configured image; source overlays are not acceptance'
    print('CONFIGURED NATIVE NOTES ACCEPTANCE: temporary fixtures; no remote access', flush=True)
    print('Editor: ' + str(Path(editor).resolve()), flush=True)
    print('Client: ' + str(Path(client).resolve()), flush=True)
    fixture = Path(__file__).resolve().with_name('native-notes-fixture.lisp')
    deadline = time.monotonic() + 300
    checks = 0

    with tempfile.TemporaryDirectory(prefix='lem-native-notes-') as temporary:
        root = Path(temporary)
        env = dict(os.environ, TERM='xterm-256color', TZ='UTC',
                   LEM_YATH_OPENROUTER_MODEL_REFRESH='0', LEM_YATH_CODEX_MODEL_REFRESH='0')
        for variable in ('XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME',
                         'XDG_STATE_HOME', 'XDG_DATA_HOME', 'LEM_HOME'):
            directory = root / variable
            directory.mkdir(mode=0o700)
            env[variable] = str(directory)
        work, public = root / 'work', root / 'public'
        alternate, alternate_public = root / 'alternate', root / 'alternate-public'
        for directory in (work, public, alternate, alternate_public):
            (directory / 'roam' / 'journal').mkdir(parents=True, mode=0o700)
        env['WORKDIR'], env['PUBLIC_ORG_DIR'] = str(work), str(public)
        original_home = env.get('HOME')
        actual_today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
        org_path = work / 'roam' / (actual_today + '.org')
        ordinary_path, identity_path = work / 'ordinary.md', work / 'identity.md'
        sentinels = {
            org_path: b'#+title: Native Org sentinel\n%%(diary-anniversary 1 1 2000)\n* Original Org\n',
            ordinary_path: b'# Ordinary Markdown\n\nOriginal ordinary Markdown.\n',
            identity_path: b'---\nlem:\n  profile: lsm/1\n  document-id: native-id-fixture\n---\n\n# Identity heading\n\nOriginal identity body.\n',
            root / 'unrelated.txt': b'Original unrelated fixture.\n',
        }
        for path, content in sentinels.items():
            path.write_bytes(content)
        daily_path = work / 'roam' / '2026-09-14.md'
        journal_path = work / 'roam' / 'journal' / '20260914.md'
        private_capture, public_capture = work / 'inbox.md', public / 'inbox.md'
        command = [client, '--server-name', 'native-notes-test']
        server_name = 'native-notes-test'
        terminals, daemons, logs = [], [], []

        def check(condition, description):
            nonlocal checks
            assert condition, description
            checks += 1
            print('PASS: ' + description, flush=True)

        def run(*arguments, timeout=15):
            assert time.monotonic() < deadline, 'native notes acceptance deadline exceeded'
            result = subprocess.run(command + list(arguments), cwd=root, env=env,
                                    capture_output=True, text=True, timeout=timeout)
            assert result.returncode == 0, result.stderr or result.stdout
            return json.loads(result.stdout)['primary'] if result.stdout.strip() else None

        def evaluate(form):
            return run('--eval', form)

        def value(form):
            return decode_value(evaluate('(lem-native-notes-fixture::json ' + form + ')'))

        def eventually(predicate, description, timeout=15):
            until = min(deadline, time.monotonic() + timeout)
            while time.monotonic() < until:
                if predicate():
                    return
                time.sleep(0.04)
            raise AssertionError(description)

        def in_frame(terminal, form):
            return evaluate('(let ((old (lem:implementation)) '
                            '(target (find ' + str(terminal.columns) + ' lem-daemon::*daemon-connections* '
                            ':key (lambda (c) (let ((i (lem-daemon::connection-implementation c))) '
                            '(and i (lem-daemon::daemon-implementation-width i))))))) '
                            '(when target (unwind-protect (progn (lem-daemon::activate-implementation '
                            '(lem-daemon::connection-implementation target)) ' + form + ') '
                            '(lem-daemon::activate-implementation old))))')

        def frame_value(terminal, form):
            return decode_value(in_frame(terminal, '(lem-native-notes-fixture::json ' + form + ')'))

        def state(terminal):
            return frame_value(terminal, '(lem-native-notes-fixture::state)')

        def prompt(terminal):
            return json.loads(in_frame(terminal, '(lem-native-notes-fixture::prompt-label)'))

        def wait_prompt(terminal, prefix):
            eventually(lambda: prompt(terminal).startswith(prefix),
                       'expected native prompt: ' + prefix)

        def mx(terminal, name):
            terminal.send(b'\x1bx')
            wait_prompt(terminal, 'Command:')
            terminal.send(name.encode() + b'\r')
            eventually(lambda: not prompt(terminal), 'native command did not finish: ' + name)

        def prompted_mx(terminal, name, prefix):
            terminal.send(b'\x1bx')
            wait_prompt(terminal, 'Command:')
            terminal.send(name.encode() + b'\r')
            wait_prompt(terminal, prefix)

        def answer(terminal, text, next_prompt=None, clear=False):
            terminal.send((b'\x01\x0b' if clear else b'') + text.encode() + b'\r')
            if next_prompt:
                wait_prompt(terminal, next_prompt)
            else:
                eventually(lambda: not prompt(terminal), 'native prompt did not finish')

        def show(terminal, name, end=False):
            in_frame(terminal, '(lem-native-notes-fixture::show-buffer ' + quote(name)
                     + (' :end t)' if end else ')'))

        def type_text(terminal, text):
            terminal.send(b'i' + text.encode() + b'\x1b')
            time.sleep(0.15)  # Disambiguate Escape from the next Meta-x prefix.

        def visit(terminal, path):
            prompted_mx(terminal, 'find-file', 'Find File:')
            answer(terminal, str(path), clear=True)
            eventually(lambda: state(terminal)['filename'] == str(path), 'native file visit failed')

        def capture(terminal, key, title, path):
            prompted_mx(terminal, 'structured-notes-lsm-capture', 'LSM capture key (i/t/r/p):')
            answer(terminal, key, 'LSM capture title:')
            answer(terminal, title)
            eventually(lambda: state(terminal)['filename'] == str(path)
                       and title in state(terminal)['text'], 'native capture did not reach its explicit destination')
            return state(terminal)

        def attach(columns, cwd=None, client_env=None):
            terminal = Terminal(command, cwd or root, client_env or env, columns)
            terminals.append(terminal)
            eventually(lambda: in_frame(terminal, 't') == 'T', 'native terminal frame did not attach')
            return terminal

        def intact():
            return all(path.read_bytes() == content for path, content in sentinels.items())

        def no_alternate_notes():
            return not any(path.is_file() for directory in (alternate, alternate_public)
                           for path in directory.rglob('*'))

        def start_daemon(ready=True):
            path = root / ('daemon-' + str(len(daemons)) + '.log')
            logs.append(path)
            with path.open('w') as output:
                process = subprocess.Popen([editor, '--daemon=' + server_name], cwd=root, env=env,
                                           stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            daemons.append(process)
            run('--wait-for-server', '30', '--eval', 't', timeout=35)
            check(evaluate('(not (null (and '
                           '(find-package :lem-structured-notes/lem-adapter) '
                           '(asdf:find-system "lem-structured-notes" nil) '
                           '(asdf:find-system "lem-structured-notes/lem-notes-adapter" nil) '
                           '(member "lem-structured-notes/lem-notes-adapter" (asdf:already-loaded-systems) :test #\'string=) '
                           '(not (intersection (list "lem-structured-notes/caldav-xml" "lem-structured-notes/caldav-http") '
                           '(asdf:already-loaded-systems) :test #\'string=)))))') == 'T',
                  'configured image already contains notes systems without the notes XML/HTTP layers')
            check(evaluate('(and (lem-yath:boot-ok-p) (lem-yath::native-agent-ready-p) '
                           '(lem-toolkit/jobs:job-manager-ready-p lem-toolkit/jobs:*default-manager*))') == 'T',
                  'configured startup keeps editing, native agent core, and jobs ready')
            expected = '(and lem-yath::*native-notes-workspaces* (null lem-yath::*native-notes-setup-error*))' if ready else \
                '(and (null lem-yath::*native-notes-workspaces*) (stringp lem-yath::*native-notes-setup-error*))'
            check(evaluate('(not (null ' + expected + '))') == 'T',
                  'notes startup reports ' + ('ready' if ready else 'unavailable') + ' before fixture loading')
            evaluate('(load ' + quote(fixture) + ')')
            evaluate('(lem-native-notes-fixture::install)')
            directory = json.loads(evaluate('(uiop:native-namestring (lem-daemon/recovery::recovery-directory))'))
            assert Path(directory).resolve().is_relative_to(root), 'recovery escaped temporary fixture tree'
            return process, Path(directory)

        def stop_daemon(process):
            run('--stop-server', '--force')
            check(process.wait(timeout=15) == 0, 'isolated configured notes daemon stops cleanly')

        try:
            daemon, recovery_directory = start_daemon()
            left = attach(96, work)
            client_env = dict(env, WORKDIR=str(alternate), PUBLIC_ORG_DIR=str(alternate_public))
            right = attach(112, alternate, client_env)
            roots = value('(lem-native-notes-fixture::roots)')
            check(Path(roots['work']) == work and Path(roots['public']) == public and roots['host_identity'],
                  'both native clients use the startup-pinned private and public roots')
            routes = value('(lem-native-notes-fixture::org-routes)')
            expected_routes = {'n r d t': 'LEM-YATH-DAILIES-TODAY', 'n r d d': 'LEM-YATH-DAILIES-DATE',
                               'n j j': 'LEM-YATH-JOURNAL-NEW-ENTRY', 'o': 'LEM-YATH-CAPTURE'}
            check(len(routes) == 8 and all(row['command'] == expected_routes[row['keys']] for row in routes),
                  'existing normal and visual Org leader routes retain their original owners')
            mx(left, 'lem-yath-notes-status')
            eventually(lambda: 'Structured notes: ready' in state(left)['text'] and left.saw('Structured notes: ready'),
                       'ready notes status did not reach the actual native terminal')
            check(True, 'native notes status displays configured readiness')

            mx(left, 'structured-notes-lsm-open-today')
            eventually(lambda: state(left)['filename'] == str(daily_path), 'native today command did not open its note')
            daily = state(left)
            check(daily['modified'] and 'profile: lsm/1' in daily['text'] and not daily_path.exists(),
                  'native today creates a canonical LSM buffer without writing a file')
            show(left, daily['name'], end=True)
            type_text(left, 'DAILY HUMAN λ')
            eventually(lambda: 'DAILY HUMAN λ' in state(left)['text'], 'native daily typing was lost')
            daily = state(left)
            evaluate('(lem-native-notes-fixture::change-environment ' + quote(alternate) + ' ' + quote(alternate_public) + ')')
            mx(right, 'structured-notes-lsm-open-today')
            eventually(lambda: state(right)['identity'] == daily['identity'], 'second client did not reuse the live daily')
            check(state(right)['text'] == daily['text'] and state(right)['tick'] == daily['tick']
                  and state(left)['name'] == daily['name'],
                  'native today reuse shares the same buffer and preserves human text without a new edit')

            mx(right, 'structured-notes-lsm-journal-entry')
            eventually(lambda: state(right)['filename'] == str(journal_path), 'native journal command missed its destination')
            journal = state(right)
            show(right, journal['name'], end=True)
            type_text(right, 'JOURNAL HUMAN λ')
            eventually(lambda: 'JOURNAL HUMAN λ' in state(right)['text'], 'native journal typing was lost')
            before_append = state(right)
            evaluate('(incf lem-native-notes-fixture::*time* 60)')
            mx(right, 'structured-notes-lsm-journal-entry')
            eventually(lambda: state(right)['text'] != before_append['text'], 'second journal entry was not appended')
            mx(right, 'undo')
            eventually(lambda: state(right)['text'] == before_append['text'], 'one undo did not remove exactly the journal append')
            check(not journal_path.exists() and state(right)['modified'] and 'JOURNAL HUMAN λ' in state(right)['text'],
                  'native journal append is one undo unit and retains earlier unsaved human text')

            private = capture(right, 'i', 'Native private capture', private_capture)
            check(private['modified'] and not private_capture.exists() and state(left)['name'] == daily['name'],
                  'actual private capture prompts create unsaved text without changing the other client view')
            published = capture(right, 'p', 'Native public capture', public_capture)
            check(published['modified'] and not public_capture.exists(),
                  'actual public capture prompts use the explicit public root and leave the edit unsaved')
            check(value('(lem-native-notes-fixture::roots)') == roots and no_alternate_notes(),
                  'alternate client cwd and changed daemon environment cannot redirect notes authority')
            evaluate('(lem-native-notes-fixture::restore-environment)')

            visit(right, identity_path)
            in_frame(right, '(lem-native-notes-fixture::point-at "Identity heading")')
            before_id = state(right)
            mx(right, 'structured-notes-lsm-assign-id')
            eventually(lambda: ':::{lem-node}' in state(right)['text'] and right.saw('LSM node ID:'),
                       'native heading ID command did not assign an ID')
            after_id = state(right)
            identifier = frame_value(right, '(lem-native-notes-fixture::current-node-id)')
            mx(right, 'structured-notes-lsm-assign-id')
            check(state(right)['text'] == after_id['text'] and state(right)['tick'] == after_id['tick']
                  and frame_value(right, '(lem-native-notes-fixture::current-node-id)') == identifier,
                  'native heading ID assignment is unsaved and repeated assignment preserves the existing ID')
            mx(right, 'undo')
            eventually(lambda: state(right)['text'] == before_id['text'], 'ID assignment was not one undo unit')
            check(identity_path.read_bytes() == sentinels[identity_path], 'one native undo restores exact ID source without saving')
            visit(right, ordinary_path)
            ordinary = state(right)
            mx(right, 'structured-notes-lsm-assign-id')
            eventually(lambda: right.saw('LSM provider requires an explicit lsm/1 profile'),
                       'ordinary Markdown refusal was not visible in the native client')
            check(state(right)['text'] == ordinary['text'] and state(right)['tick'] == ordinary['tick'],
                  'ordinary Markdown refuses LSM mutation without conversion')
            right.send(b' nrdt')
            eventually(lambda: state(right)['filename'] == str(org_path), 'the original native Org daily leader did not dispatch')
            check(state(right)['text'].encode() == sentinels[org_path] and intact(),
                  'the original Org daily leader still opens Org and all sentinel files remain exact')

            mx(right, 'structured-notes-lsm-open-today')
            eventually(lambda: state(right)['identity'] == daily['identity'], 'daily buffer was replaced')
            right.close()
            right = attach(114, alternate, client_env)
            mx(right, 'structured-notes-lsm-open-today')
            eventually(lambda: state(right)['identity'] == daily['identity'], 'client reconnect lost its live daily')
            check(state(right)['text'] == daily['text'] and not daily_path.exists(),
                  'native client death and reattachment preserve the daemon-owned unsaved note')

            show(left, daily['name'])
            mx(left, 'save-current-buffer')
            eventually(lambda: daily_path.exists() and not state(left)['modified'], 'explicit native save did not finish')
            saved_daily = daily_path.read_bytes()
            check(saved_daily == state(left)['text'].encode() and b'DAILY HUMAN' in saved_daily,
                  'only an explicit native save publishes the synthetic daily note with its human text')
            show(left, daily['name'], end=True)
            type_text(left, ' UNSAVED RECOVERY λ')
            eventually(lambda: 'UNSAVED RECOVERY λ' in state(left)['text'], 'pre-crash native edit was lost')
            recovery_text = state(left)['text']
            mx(left, 'recovery-checkpoint')
            records = [json.loads(path.read_text()) for path in recovery_directory.glob('*.json')]
            record = next(item for item in records if item['filename'] == str(daily_path) and item['text'] == recovery_text)
            check(daily_path.read_bytes() == saved_daily and record['text'] != saved_daily.decode(),
                  'native explicit checkpoint durably retains the exact unsaved note separately from its saved file')
            os.killpg(daemon.pid, signal.SIGKILL)
            check(daemon.wait(timeout=10) == -signal.SIGKILL, 'the isolated daemon is actually killed after the checkpoint')
            left.close()
            right.close()
            check(intact() and daily_path.read_bytes() == saved_daily
                  and not any(path.exists() for path in (journal_path, private_capture, public_capture)),
                  'daemon death leaves original files exact and never publishes unsaved journal or capture edits')

            daemon, _ = start_daemon()
            restart_files = value('(lem-native-notes-fixture::file-identities)')
            check(not any(Path(name).is_relative_to(work) or Path(name).is_relative_to(public)
                          for name in restart_files),
                  'configured restart does not automatically reopen source files or replay notes operations')
            evaluate('(lem-native-notes-fixture::guard-file-hooks)')
            left, right = attach(101), attach(119, alternate, client_env)
            mx(left, 'recovery-list')
            eventually(lambda: record['id'] in state(left)['text'] and left.saw(record['id']),
                       'native recovery list did not present the exact checkpoint')
            check(True, 'native recovery-list presents the historical note for explicit selection')
            prompted_mx(left, 'recovery-restore', 'Recovery ID:')
            answer(left, record['id'])
            eventually(lambda: state(left)['text'] == recovery_text, 'native recovery restore did not reproduce checkpoint text')
            recovered = state(left)
            origin = frame_value(left, '(lem-native-notes-fixture::recovery-origin)')
            check(recovered['filename'] is None and recovered['modified']
                  and origin == {'id': record['id'], 'filename': str(daily_path), 'status': 'UNCHANGED'}
                  and value('lem-native-notes-fixture::*file-hook-calls*') == 0,
                  'native recovery restores exact unnamed unsaved text without file hooks or file association')
            mx(left, 'structured-notes-lsm-assign-id')
            eventually(lambda: left.saw('recovered unnamed text'),
                       'recovered notes authority refusal did not reach the native terminal')
            check(state(left)['text'] == recovered['text'] and state(left)['tick'] == recovered['tick']
                  and state(left)['filename'] is None
                  and value('(lem-native-notes-fixture::file-identities)') == restart_files
                  and value('lem-native-notes-fixture::*file-hook-calls*') == 0,
                  'recovered unnamed text refuses notes mutation until explicit association without reopening or rebasing')
            show(left, recovered['name'], end=True)
            type_text(left, ' RECOVERY HUMAN')
            eventually(lambda: state(left)['text'].endswith(' RECOVERY HUMAN'), 'recovered plain text could not be edited')
            check(intact() and daily_path.read_bytes() == saved_daily,
                  'human editing of recovered text remains unsaved and preserves all original file bytes')
            stop_daemon(daemon)
            left.close()
            right.close()

            missing = root / 'missing-workspace'
            env['WORKDIR'] = str(missing)
            server_name = 'native-notes-missing'
            command = [client, '--server-name', server_name]
            daemon, _ = start_daemon(ready=False)
            left = attach(125, alternate)
            mx(left, 'lem-yath-notes-status')
            eventually(lambda: 'Structured notes: unavailable' in state(left)['text']
                       and left.saw('Structured notes: unavailable'), 'degraded native notes status was not displayed')
            check('Notes workspace setup unavailable' in state(left)['text'] and not missing.exists(),
                  'missing WORKDIR produces a visible unavailable notes status without creating a directory')
            in_frame(left, '(lem-native-notes-fixture::new-scratch)')
            type_text(left, 'EDITING STILL READY')
            eventually(lambda: state(left)['text'] == 'EDITING STILL READY', 'degraded startup blocked native editing')
            scratch = state(left)
            mx(left, 'structured-notes-lsm-open-today')
            eventually(lambda: left.saw('Notes workspace is unavailable'), 'missing-workspace command refusal was not visible')
            check(state(left)['identity'] == scratch['identity'] and state(left)['text'] == scratch['text']
                  and not missing.exists() and intact() and env.get('HOME') == original_home
                  and evaluate('(and (lem-yath::native-agent-ready-p) '
                               '(lem-toolkit/jobs:job-manager-ready-p lem-toolkit/jobs:*default-manager*))') == 'T',
                  'unavailable notes refuse mutation while native editing, agent core, and jobs remain ready')
            stop_daemon(daemon)
            print(f'CONFIGURED NATIVE NOTES ACCEPTANCE PASSED: {checks} checks', flush=True)
        except BaseException:
            for path in logs:
                print(path.name + ':\n' + path.read_text(errors='replace')[-8000:], flush=True)
            for terminal in terminals:
                with terminal.lock:
                    print(f'PTY {terminal.columns} tail: {bytes(terminal.output[-4000:])!r}', flush=True)
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


def self_test():
    assert Terminal is _helpers.Terminal
    for value in ({'text': 'fixture λ', 'point': 3}, [], None):
        assert decode_value(json.dumps(json.dumps(value))) == value
    assert quote('a"b\\c') == '"a\\"b\\\\c"'
    print('PASS: Python syntax/helper smoke; no native acceptance run')


if __name__ == '__main__':
    if sys.argv[1:] == ['--self-test']:
        self_test()
    else:
        assert not sys.argv[1:], 'use environment LEM_BIN/LEMCLIENT_BIN, or --self-test'
        main()
