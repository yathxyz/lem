"""Configured native shutdown: final checkpoints, truthful failures, bounded CLI.

Set LEM_BIN/LEMCLIENT_BIN. Only synthetic private files and fake protocol peers
are used; no provider calls or system services. Faults are injected through
administrative eval in each disposable daemon, never into an installed daemon.
"""
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time


def quoted(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


def main():
    root = Path(tempfile.mkdtemp(prefix='lem-shutdown-client-'))
    print('ARTIFACTS: ' + str(root), flush=True)
    env = dict(os.environ, TERM='xterm-256color', LEM_YATH_OPENROUTER_MODEL_REFRESH='0',
               LEM_YATH_CODEX_MODEL_REFRESH='0')
    for key in ('XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME',
                'XDG_STATE_HOME', 'XDG_DATA_HOME', 'LEM_HOME', 'WORKDIR'):
        directory = root / key
        directory.mkdir(mode=0o700)
        env[key] = str(directory)
    editor, client = os.environ['LEM_BIN'], os.environ['LEMCLIENT_BIN']
    processes, checks = [], []
    result = {'editor': editor, 'client': client, 'checks': checks}

    def check(condition, description):
        assert condition, description
        checks.append(description)
        print('PASS: ' + description, flush=True)

    def wait(predicate, description):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(.04)
        raise AssertionError(description)

    def cli(name, *args, success=True):
        value = subprocess.run([client, '-s', name, *args], env=env, cwd=root,
                               capture_output=True, text=True, timeout=32)
        if success:
            assert value.returncode == 0, (name, args, value.stderr)
        return value

    def evaluate(name, form):
        return json.loads(cli(name, '--eval', form).stdout)['primary']

    def start_daemon(name):
        with (root / (name + '.log')).open('w') as log:
            daemon = subprocess.Popen([editor, '--daemon=' + name], cwd=root, env=env,
                                      stdout=log, stderr=subprocess.STDOUT)
        processes.append(daemon)
        cli(name, '--wait-for-server', '15', '--eval', '(lem-yath:boot-ok-p)')
        return daemon

    def start_stop(name):
        process = subprocess.Popen([client, '-s', name, '--stop-server', '--force'],
                                   cwd=root, env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        processes.append(process)
        return process

    def stop_status(process):
        stdout, stderr = process.communicate(timeout=30)
        return process.returncode, stdout, stderr

    def send(peer, message):
        data = json.dumps(dict(version=2, **message)).encode()
        peer.sendall(struct.pack('!I', len(data)) + data)

    def receive(peer):
        def exact(length):
            data = b''
            while len(data) < length:
                part = peer.recv(length - len(data))
                assert part, 'unexpected protocol EOF'
                data += part
            return data
        length, = struct.unpack('!I', exact(4))
        assert length <= 1024 * 1024
        return json.loads(exact(length))

    try:
        daemon = start_daemon('complete')
        text = 'Final unsaved shutdown text. λ\n'
        checkpoint = json.loads(evaluate('complete',
            '(progn (lem-daemon/recovery:disable) '
            '(let ((buffer (lem:make-buffer "*Shutdown fixture*")) '
            '(id (lem-daemon/recovery-store:new-id))) '
            '(setf (lem:buffer-value buffer \'lem-daemon/recovery::recovery-id) id) '
            '(lem:insert-string (lem:buffer-point buffer) ' + quoted(text) + ') '
            '(uiop:native-namestring (merge-pathnames (concatenate \'string id ".json") '
            '(lem-daemon/recovery::recovery-directory)))))'))
        unsaved_file = root / 'unsaved-file.txt'
        unsaved_file.write_text('disk original\n')
        evaluate('complete', '(let ((buffer (lem:find-file-buffer ' + quoted(unsaved_file) + '))) '
                 '(lem:insert-string (lem:buffer-point buffer) "unsaved edit "))')
        marker = root / 'exit-hook-entered'
        late = root / 'late-hook-finished'
        evaluate('complete',
            '(progn (lem:add-hook lem:*exit-editor-hook* (lambda () '
            '(with-open-file (out ' + quoted(marker) + ' :direction :output) (write-line "entered" out)) '
            '(sleep 1.5)) 90000) '
            '(lem:add-hook lem:*exit-editor-hook* (lambda () '
            '(with-open-file (out ' + quoted(late) + ' :direction :output) (write-line "late" out))) -100000))')
        refused = cli('complete', '--stop-server', success=False)
        check(refused.returncode == 2 and not marker.exists() and daemon.poll() is None,
              'modified buffers refuse non-forced shutdown before cleanup starts')
        process = start_stop('complete')
        wait(marker.exists, 'exit hook did not begin')
        check(process.poll() is None, 'shutdown client remains waiting while an exit hook runs')
        status, _, error = stop_status(process)
        check(status == 0 and daemon.wait(timeout=5) == 0 and late.exists(),
              'success follows late exit hooks and the actual daemon exits cleanly: ' + error)
        check(json.loads(Path(checkpoint).read_text())['text'] == text,
              'completed shutdown durably checkpoints exact immediate unsaved text')
        check(unsaved_file.read_text() == 'disk original\n', 'shutdown checkpoints do not save over source files')

        for kind in ('checkpoint', 'draft', 'core', 'jobs', 'teardown'):
            name = 'failure-' + kind
            daemon = start_daemon(name)
            if kind == 'checkpoint':
                blocked = root / 'not-a-directory'
                blocked.write_text('private fixture obstruction')
                evaluate(name, '(progn (lem-daemon/recovery:disable) '
                         '(let ((b (lem:make-buffer "*Checkpoint failure*"))) '
                         '(lem:insert-string (lem:buffer-point b) "retained")) '
                         '(setf lem-user::*old-recovery-directory* lem-daemon/recovery::*directory* '
                         'lem-daemon/recovery::*directory* (pathname ' + quoted(str(blocked) + '/') + ')))')
                restore = '(setf lem-daemon/recovery::*directory* lem-user::*old-recovery-directory*)'
            elif kind == 'draft':
                evaluate(name, '(setf lem-user::*old-close-observer* (fdefinition \'lem-agent/drafts:store-error) '
                         '(fdefinition \'lem-agent/drafts:store-error) '
                         '(lambda (store) (declare (ignore store)) "injected draft failure"))')
                restore = '(setf (fdefinition \'lem-agent/drafts:store-error) lem-user::*old-close-observer*)'
            elif kind == 'core':
                evaluate(name, '(let ((original (fdefinition \'lem-agent:close-manager))) '
                         '(setf lem-user::*old-close-observer* original '
                         '(fdefinition \'lem-agent:close-manager) '
                         '(lambda (&rest args) (let ((receipts (apply original args)) '
                         '(failure (lem-agent::make-receipt))) '
                         '(lem-agent::finish-receipt failure nil '
                         '(make-condition \'simple-error :format-control "injected core journal failure")) '
                         '(append receipts (list failure))))))')
                restore = '(setf (fdefinition \'lem-agent:close-manager) lem-user::*old-close-observer*)'
            elif kind == 'jobs':
                job = json.loads(evaluate(name,
                    '(lem-toolkit/jobs:job-id (lem-toolkit/jobs:start-job (list "true") :owner "shutdown-fixture"))'))
                wait(lambda: evaluate(name, '(not (null (lem-toolkit/jobs:job-result '
                     '(lem-toolkit/jobs:find-job ' + quoted(job) + '))))') == 'T', 'fixture job did not finish')
                evaluate(name, '(let ((original (fdefinition \'lem-toolkit/jobs:job-snapshot))) '
                         '(setf lem-user::*old-close-observer* original '
                         '(fdefinition \'lem-toolkit/jobs:job-snapshot) '
                         '(lambda (&rest args) (let ((snapshot (apply original args))) '
                         '(setf (gethash "journal-error" snapshot) "injected job journal failure") snapshot))))')
                restore = '(setf (fdefinition \'lem-toolkit/jobs:job-snapshot) lem-user::*old-close-observer*)'
            else:
                evaluate(name, '(lem:add-hook lem:*teardown-frame-hook* (lambda (frame) '
                         '(declare (ignore frame)) (lem-daemon:stop-server) '
                         '(error "injected frame teardown failure")))')
            failed = cli(name, '--stop-server', '--force', success=False)
            check(failed.returncode == 2 and 'lemclient:' in failed.stderr,
                  kind + ' cleanup failure returns nonzero without a stopped receipt')
            if kind == 'teardown':
                check(daemon.wait(timeout=5) != 0, 'frame teardown failure reaches the daemon owner')
            else:
                evaluate(name, restore)
                check(evaluate(name, '(and (null lem-yath::*native-agent-manager*) '
                               '(null lem-yath::*native-agent-draft-store*) '
                               '(null lem-toolkit/jobs:*default-manager*))') == 'T',
                      kind + ' failure still attempts all manager cleanup')
                retried = cli(name, '--stop-server', '--force', success=False)
                check(retried.returncode == 2,
                      kind + ' failed durability remains visible after cleanup globals are cleared')
                daemon.kill()
                daemon.wait(timeout=5)

        # Real native CLI against deliberately incomplete protocol peers.
        runtime = Path(env['XDG_RUNTIME_DIR']) / 'lem'
        for kind in ('early-ack', 'pending-eof', 'hello-timeout'):
            endpoint = runtime / (kind + '.sock')
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(str(endpoint))
                os.chmod(endpoint, 0o600)
                listener.listen(1)
                listener.settimeout(5)
                process = start_stop(kind)
                with listener.accept()[0] as peer:
                    peer.settimeout(32)
                    assert receive(peer)['type'] == 'hello'
                    if kind == 'hello-timeout':
                        status, _, error = stop_status(process)
                        check(status == 2 and 'exceeded' in error,
                              'withheld hello is bounded by the native shutdown deadline')
                        check(peer.recv(1) == b'', 'hello timeout closes its connected socket')
                    else:
                        send(peer, {'type': 'hello'})
                        request = receive(peer)
                        assert request['type'] == 'shutdown'
                        send(peer, {'type': 'response', 'id': request['id'],
                                    'status': 'ok' if kind == 'early-ack' else 'pending',
                                    'value': 'stopping'})
                        peer.shutdown(socket.SHUT_RDWR)
                if kind != 'hello-timeout':
                    check(stop_status(process)[0] == 2,
                          kind + ' cannot be mistaken for completed shutdown')
            endpoint.unlink()
        result['passed'] = True
    except BaseException as error:
        result['error'] = str(error)
        raise
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
        (root / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print('RESULT: ' + str(root / 'result.json'), flush=True)


if __name__ == '__main__':
    main()
