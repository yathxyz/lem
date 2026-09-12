"""Native Lisp agent/file acceptance; Python drives isolated external fixtures only."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
SERVER = ROOT / 'extensions/agent/tests/editor-tools-server.lisp'


def quote(text):
    return '"' + str(text).replace('\\', '\\\\').replace('"', '\\"') + '"'


def eventually(predicate):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError('Native agent fixture did not reach expected state')


def check(value, description):
    assert value, description
    print('PASS: ' + description, flush=True)


def main():
    client = os.environ['LEMCLIENT_BIN']
    sbcl = os.environ.get('LEM_TEST_SBCL', 'sbcl')
    with tempfile.TemporaryDirectory(prefix='lem-agent-file-native-') as temporary:
        root = Path(temporary)
        project = root / 'project'
        project.mkdir()
        env = os.environ.copy()
        for key in ('XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME',
                    'XDG_STATE_HOME', 'XDG_CACHE_HOME', 'LEM_HOME'):
            path = root / key
            path.mkdir(mode=0o700)
            env[key] = str(path)
        env.update(LEM_AGENT_FILE_TEST_ROOT=str(project) + '/',
                   LEM_AGENT_FILE_TEST_JOURNAL=str(root / 'journal') + '/',
                   ASDF_OUTPUT_TRANSLATIONS=f'(:output-translations (t "{root}/fasls/") :ignore-inherited-configuration)')
        command = [client, '--server-name', 'agent-files-test']
        server = [sbcl, '--dynamic-space-size', '4GiB', '--noinform', '--no-sysinit',
                  '--no-userinit', '--disable-debugger', '--script', str(SERVER)]
        daemon = None
        log_path = root / 'daemon.log'
        with log_path.open('w') as log:
            try:
                subprocess.run(server, env=dict(env, LEM_AGENT_FILE_WARMUP='1'), cwd=ROOT,
                               stdout=log, stderr=log, check=True, timeout=180)
                daemon = subprocess.Popen(server, env=env, cwd=project, stdout=log, stderr=log)

                def run(*args):
                    result = subprocess.run(command + list(args), env=env, cwd=project,
                                            capture_output=True, text=True, timeout=35)
                    assert result.returncode == 0, result.stderr
                    return result

                def evaluate(form):
                    return json.loads(run('--eval', form).stdout)['primary']

                def value(form):
                    return json.loads(json.loads(evaluate('(with-output-to-string (out) (yason:encode '
                                                          + form + ' out))')))

                run('--wait-for-server', '30', '--eval', 't')
                eventually(lambda: evaluate('(not (null lem-user::*file-tools-session*))') == 'T')
                turns = 0

                def tool(name, arguments):
                    nonlocal turns
                    turns += 1
                    calls = [{'id': f'call-{turns}', 'name': name, 'arguments': arguments}]
                    evaluate('(progn (setf lem-user::*file-tools-calls* '
                             '(coerce (yason:parse ' + quote(json.dumps(calls)) + ') \'vector)) '
                             '(lem-agent:submit-message lem-user::*file-tools-session* "fixture"))')
                    def ready():
                        snapshot = value('(lem-agent:session-snapshot lem-user::*file-tools-session*)')
                        return snapshot['status'] == 'idle' and len(snapshot['turns']) >= turns and not snapshot['active_turn']
                    eventually(ready)
                    snapshot = value('(lem-agent:session-snapshot lem-user::*file-tools-session*)')
                    return next(message['content'] for message in snapshot['turns'][-1]['messages']
                                if message['role'] == 'tool')

                path = project / 'source.txt'
                path.write_text('disk original')
                evaluate('(let ((buffer (lem:find-file-buffer ' + quote(path) + '))) '
                         '(lem:erase-buffer buffer) (lem:insert-string (lem:buffer-point buffer) "human unsaved"))')
                inspection = tool('read_file', {'path': 'source.txt'})
                check(inspection['source'] == 'buffer' and inspection['content'] == 'human unsaved',
                      'real agent worker inspects the live unsaved buffer through editor dispatch')
                result = tool('propose_edit', dict(path='source.txt', revision=inspection['revision'],
                                                   original=inspection['content'], replacement='reviewed text'))
                identifier = result['proposal_id']
                check(value('(lem:buffer-text (lem:get-file-buffer ' + quote(path) + '))') == 'human unsaved'
                      and path.read_text() == 'disk original',
                      'native tool result stages a shared proposal without changing buffer or disk')
                evaluate('(lem:delete-buffer (lem-buffer-proposals:proposal-review-buffer '
                         '(lem-buffer-proposals:find-proposal ' + quote(identifier) + ')))')
                check(evaluate('(eq :pending (lem-buffer-proposals:proposal-state '
                               '(lem-buffer-proposals:find-proposal ' + quote(identifier) + ')))') == 'T',
                      'closing a proposal view preserves its human decision')
                evaluate('(lem-buffer-proposals:apply-proposal (lem-buffer-proposals:find-proposal '
                         + quote(identifier) + ') :expected-revision ' + str(result['revision'])
                         + ' :expected-generation ' + str(result['generation']) + ')')
                check(value('(lem:buffer-text (lem:get-file-buffer ' + quote(path) + '))') == 'reviewed text'
                      and path.read_text() == 'disk original',
                      'explicit human acceptance changes only the live buffer')
                stale = tool('read_file', {'path': 'source.txt'})
                evaluate('(lem:insert-string (lem:buffer-end-point (lem:get-file-buffer ' + quote(path) + ')) "!")')
                refused = tool('propose_edit', dict(path='source.txt', revision=stale['revision'],
                                                    original=stale['content'], replacement='stale'))
                check('error' in refused and value('(lem:buffer-text (lem:get-file-buffer '
                                                  + quote(path) + '))') == 'reviewed text!',
                      'intervening human edits produce an explicit tool failure with no mutation')
                check('error' in tool('read_file', {'path': '../outside'}),
                      'root escape remains a recorded tool failure in the real agent loop')
                run('--stop-server', '--force')
                check(daemon.wait(timeout=15) == 0, 'source daemon and native file tools stop cleanly')
            except BaseException:
                print(log_path.read_text(), flush=True)
                raise
            finally:
                if daemon and daemon.poll() is None:
                    daemon.kill()
                    daemon.wait(timeout=15)


if __name__ == '__main__':
    main()
