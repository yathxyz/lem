"""Real PTY tab ownership and completed daemon shutdown; synthetic buffers only.

Set LEM_BIN and LEMCLIENT_BIN to the matching configured binaries. Optional
LEM_FRAME_OWNER_OVERLAY names a source precheck file; any such run is explicitly
reported as an overlay and is not packaged acceptance. No provider calls.
"""

import fcntl
import json
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import tempfile
import termios
import threading
import time


def quoted(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


def main():
    root = Path(tempfile.mkdtemp(prefix='lem-tab-shutdown-'))
    env = dict(os.environ, TERM='xterm-256color', LEM_YATH_OPENROUTER_MODEL_REFRESH='0',
               LEM_YATH_CODEX_MODEL_REFRESH='0')
    for key in ('XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME',
                'XDG_DATA_HOME', 'LEM_HOME', 'WORKDIR'):
        directory = root / key
        directory.mkdir(mode=0o700)
        env[key] = str(directory)
    editor, client = env['LEM_BIN'], env['LEMCLIENT_BIN']
    command = [client, '-s', 'tab-shutdown']
    processes, masters, checks = [], [], []
    result = dict(editor=editor, client=client, overlay=env.get('LEM_FRAME_OWNER_OVERLAY'),
                  checks=checks)
    print('ARTIFACTS: ' + str(root), flush=True)

    def check(value, description):
        assert value, description
        checks.append(description)
        print('PASS: ' + description, flush=True)

    def evaluate(form):
        value = subprocess.run(command + ['--eval', form], cwd=root, env=env,
                               text=True, capture_output=True, timeout=15)
        assert value.returncode == 0, value.stderr
        return json.loads(value.stdout)['primary']

    def eventually(form):
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            if evaluate('(not (null ' + form + '))') == 'T':
                return
            time.sleep(.05)
        raise AssertionError('Timed out: ' + form)

    def frame_form(symbol, form):
        # Administrative eval itself selects the headless frame. Inspect a
        # client's buffer/point through the daemon's coherent context helper.
        return ('(lem-daemon::call-with-client-implementation '
                '(lem-daemon::connection-implementation ' + symbol + ') (lambda () ' + form + '))')

    def drain(fd, process):
        while process.poll() is None:
            try:
                if select.select([fd], [], [], .1)[0]:
                    if not os.read(fd, 65536):
                        return
            except OSError:
                return

    def attach(name):
        path = root / (name + '.txt')
        path.write_text('synthetic-' + name + '\n')
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 110, 0, 0))
        process = subprocess.Popen(command + ['-t', '-n', str(path)], cwd=root, env=env,
                                   stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        os.close(slave)
        processes.append(process)
        masters.append(master)
        threading.Thread(target=drain, args=(master, process), daemon=True).start()
        symbol = 'lem-user::*tab-' + name + '*'
        eventually('(not (null (setf ' + symbol + ' (find-if (lambda (connection) '
                   '(let* ((impl (lem-daemon::connection-implementation connection)) '
                   '(frame (and impl (lem:get-frame impl)))) '
                   '(and frame (equal ' + quoted(path) + ' '
                   '(lem:buffer-filename (lem:window-buffer (lem:frame-current-window frame))))))) '
                   'lem-daemon::*daemon-connections*))))')
        return master, process, symbol, path

    def enable_tabs(fd, symbol):
        os.write(fd, b'\x18t2')
        eventually('(not (null (gethash (lem-daemon::connection-implementation ' + symbol + ') '
                   'lem/frame-multiplexer::*virtual-frame-map*)))')

    def mux_off(fd):
        os.write(fd, b'\x1bxtoggle-frame-multiplexer\r')
        eventually('(not (lem/frame-multiplexer::enabled-frame-multiplexer-p))')

    try:
        with (root / 'daemon.log').open('w') as log:
            daemon = subprocess.Popen([editor, '--daemon=tab-shutdown'], cwd=root, env=env,
                                      stdout=log, stderr=subprocess.STDOUT)
        processes.append(daemon)
        ready = subprocess.run(command + ['--wait-for-server', '20', '--eval', '(lem-yath:boot-ok-p)'],
                               cwd=root, env=env, text=True, capture_output=True, timeout=25)
        check(ready.returncode == 0 and json.loads(ready.stdout)['primary'] == 'T',
              'configured daemon is ready')
        if result['overlay']:
            evaluate('(load ' + quoted(result['overlay']) + ')')
            print('SOURCE OVERLAY PRECHECK: ' + result['overlay'], flush=True)
        left, left_process, left_symbol, _ = attach('left')
        right, _, right_symbol, right_path = attach('right')
        enable_tabs(left, left_symbol)
        os.write(right, b'\x1a')  # Configured C-z deliberately enters Emacs editing state.
        eventually(frame_form(right_symbol, '(lem-yath::lem-yath-emacs-state-p)'))
        os.write(right, b'PEER')
        peer_current = '(eq (lem:implementation) (lem-daemon::connection-implementation ' + right_symbol + '))'
        eventually(frame_form(right_symbol, '(search "PEER" (lem:buffer-text (lem:current-buffer)))'))
        evaluate(frame_form(right_symbol, '(setf lem-user::*tab-peer-window* (lem:current-window) '
                            'lem-user::*tab-peer-point* (lem:position-at-point (lem:current-point)))'))
        mux_off(right)
        check(evaluate(frame_form(right_symbol,
                       '(and (eq lem-user::*tab-peer-window* (lem:current-window)) '
                       '(= lem-user::*tab-peer-point* (lem:position-at-point (lem:current-point))))')) == 'T',
              'disabling another frame\'s tab header preserves peer selection and cursor')
        os.write(right, b'K')
        eventually(frame_form(right_symbol, '(search "PEERK" (lem:buffer-text (lem:current-buffer)))'))
        check(evaluate(frame_form(right_symbol,
                       '(equal ' + quoted(right_path) + ' (lem:buffer-filename (lem:current-buffer)))')) == 'T',
              'the next real key reaches the peer source buffer')

        enable_tabs(left, left_symbol)
        os.write(left, b'\x18\x03')
        left_process.wait(timeout=10)
        eventually('(null (lem-daemon::connection-implementation ' + left_symbol + '))')
        mux_off(right)
        os.write(right, b'L')
        eventually(frame_form(right_symbol, '(search "PEERKL" (lem:buffer-text (lem:current-buffer)))'))
        check(evaluate(frame_form(right_symbol, peer_current)) == 'T',
              'retired tab ownership is discarded without disturbing the surviving client')

        third, _, third_symbol, _ = attach('third')
        enable_tabs(third, third_symbol)
        os.write(right, b'M')
        eventually(frame_form(right_symbol, '(search "PEERKLM" (lem:buffer-text (lem:current-buffer)))'))
        # Last admin observation selected the headless frame. Deliberately
        # restore the proven peer context before the separate stop request.
        check(evaluate('(progn (lem-daemon::activate-implementation '
                       '(lem-daemon::connection-implementation ' + right_symbol + ')) ' +
                       peer_current + ')') == 'T', 'shutdown begins in the surviving peer frame')
        stopped = subprocess.run(command + ['--stop-server', '--force'], cwd=root, env=env,
                                 text=True, capture_output=True, timeout=32)
        check(stopped.returncode == 0 and daemon.wait(timeout=5) == 0,
              'completed shutdown succeeds with a live tab owner and another client active')
        check(right_path.read_text() == 'synthetic-right\n',
              'shutdown leaves the synthetic source file unsaved')
        result['passed'] = True
    except BaseException as error:
        result['error'] = str(error)
        raise
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
        for fd in masters:
            os.close(fd)
        (root / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print('RESULT: ' + str(root / 'result.json'), flush=True)


if __name__ == '__main__':
    main()
