"""Native PTY and SDL acceptance against one configured daemon.

Set LEM_BIN and LEMCLIENT_BIN to the packaged editor/client. Needs Xvfb,
xdotool, xclip, and ImageMagick on PATH; never accesses the live desktop.
Python drives the test; editor, client, and agent/tool runtimes are Common Lisp.
"""

import ctypes
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import socket
import struct
import subprocess
import tempfile
import termios
import threading
import time

binaries = {'editor': os.environ['LEM_BIN'], 'client': os.environ['LEMCLIENT_BIN']}
xserver = shutil.which('Xvfb')
xdotool = shutil.which('xdotool')
magick = shutil.which('magick')
xclip = shutil.which('xclip')
assert all([xserver, xdotool, magick, xclip]), 'Xvfb, xdotool, ImageMagick, and xclip are required'
processes = []
masters = []

def lisp_string(text):
    return '"' + str(text).replace('\\', '\\\\').replace('"', '\\"') + '"'

with tempfile.TemporaryDirectory(prefix='lem-sdl-check-') as temporary:
    root = Path(temporary)
    env = dict(os.environ, TERM='xterm-256color', SDL_VIDEODRIVER='x11')
    for key in ['XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME',
                'XDG_STATE_HOME', 'XDG_DATA_HOME', 'LEM_HOME']:
        path = root / key
        path.mkdir(mode=0o700)
        env[key] = str(path)
    command = [binaries['client'], '--server-name', 'sdl-test']
    document = root / 'shared.lisp'
    document.write_text('(defun shared-example (name)\n  "Persistent buffers across clients."\n  (format nil "Hello, ~a" name))\n\n;; Unicode: 漢字 café\n' + ''.join(f';; Line {i}\n' for i in range(1, 80)))

    def start(args, **kwargs):
        process = subprocess.Popen(args, cwd=root, env=env, **kwargs)
        processes.append(process)
        return process

    def evaluate(form):
        result = subprocess.run(command + ['--wait-for-server', '20', '--eval', form],
                                cwd=root, env=env, text=True, capture_output=True, timeout=30)
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)['primary']

    def eventually(form, expected):
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            if evaluate(form) == expected:
                return
            time.sleep(0.05)
        raise AssertionError((form, evaluate(form), expected))

    def xdo(*args):
        result = subprocess.run([xdotool] + list(map(str, args)), env=env, text=True,
                                capture_output=True, timeout=10)
        assert result.returncode == 0, result.stderr
        return result.stdout.strip()

    def close_window(window):
        # xdotool windowquit asks an EWMH window manager. Xvfb has none, so
        # send the WM_DELETE_WINDOW client message directly to this window.
        class Data(ctypes.Union):
            _fields_ = [('bytes', ctypes.c_char * 20), ('longs', ctypes.c_long * 5)]
        class Message(ctypes.Structure):
            _fields_ = [('type', ctypes.c_int), ('serial', ctypes.c_ulong),
                        ('send_event', ctypes.c_int), ('display', ctypes.c_void_p),
                        ('window', ctypes.c_ulong), ('message_type', ctypes.c_ulong),
                        ('format', ctypes.c_int), ('data', Data)]
        class Event(ctypes.Union):
            _fields_ = [('message', Message), ('padding', ctypes.c_long * 24)]
        xlib = ctypes.CDLL(os.environ.get('LEM_X11_LIBRARY', 'libX11.so.6'))
        xlib.XOpenDisplay.argtypes = [ctypes.c_char_p]
        xlib.XOpenDisplay.restype = ctypes.c_void_p
        xlib.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        xlib.XInternAtom.restype = ctypes.c_ulong
        xlib.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int,
                                   ctypes.c_long, ctypes.POINTER(Event)]
        xlib.XFlush.argtypes = [ctypes.c_void_p]
        xlib.XCloseDisplay.argtypes = [ctypes.c_void_p]
        display = xlib.XOpenDisplay(env['DISPLAY'].encode())
        assert display, 'cannot open the isolated X display'
        try:
            event = Event()
            event.message.type = 33
            event.message.window = int(window)
            event.message.format = 32
            event.message.message_type = xlib.XInternAtom(display, b'WM_PROTOCOLS', 0)
            event.message.data.longs[0] = xlib.XInternAtom(display, b'WM_DELETE_WINDOW', 0)
            assert xlib.XSendEvent(display, int(window), 0, 0, ctypes.byref(event))
            xlib.XFlush(display)
        finally:
            xlib.XCloseDisplay(display)

    def drain(fd):
        try:
            while os.read(fd, 4096):
                pass
        except OSError:
            pass

    def terminal_client(columns):
        master, slave = pty.openpty()
        masters.append(master)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, columns, 0, 0))
        # These clients exercise display lifetime, not a waiting external edit.
        process = start(command + ['-t', '-n', str(document)], stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        threading.Thread(target=drain, args=(master,), daemon=True).start()
        return process, master

    def in_frame(columns, form):
        return evaluate('(let ((old (lem:implementation)) '
                        '(target (find ' + str(columns) + ' lem-daemon::*daemon-connections* '
                        ':key (lambda (c) (let ((i (lem-daemon::connection-implementation c))) '
                        '(and i (lem-daemon::daemon-implementation-width i))))))) '
                        '(unwind-protect (progn (lem-daemon::activate-implementation '
                        '(lem-daemon::connection-implementation target)) ' + form + ') '
                        '(lem-daemon::activate-implementation old)))')

    count = '(count-if #\'lem-daemon::connection-implementation lem-daemon::*daemon-connections*)'
    sizes = '(sort (loop for c in lem-daemon::*daemon-connections* for i = (lem-daemon::connection-implementation c) when i collect (lem-daemon::daemon-implementation-width i)) #\'<)'
    try:
        with (root / 'xserver.log').open('w') as xlog, (root / 'daemon.log').open('w') as dlog:
            readfd, writefd = os.pipe()
            server = start([xserver, '-displayfd', str(writefd), '-screen', '0', '1600x1000x24',
                            '-nolisten', 'tcp', '-noreset'], pass_fds=[writefd], stdout=xlog, stderr=xlog)
            os.close(writefd)
            # Xvfb may write the digits and final newline separately. Closing
            # after a numeric prefix can make its readiness write fail.
            display_bytes = bytearray()
            deadline = time.monotonic() + 10
            try:
                while b'\n' not in display_bytes:
                    remaining = deadline - time.monotonic()
                    assert remaining > 0 and select.select([readfd], [], [], remaining)[0], 'Xvfb did not start'
                    chunk = os.read(readfd, 32)
                    assert chunk, 'Xvfb closed readiness before its complete display number'
                    display_bytes.extend(chunk)
                    assert len(display_bytes) <= 32, 'Oversized Xvfb readiness reply'
            finally:
                os.close(readfd)
            display = display_bytes.decode().strip()
            assert display.isdigit(), display
            env['DISPLAY'] = ':' + display
            daemon = start([binaries['editor'], '--daemon=sdl-test'], stdout=dlog, stderr=dlog)
            assert evaluate('(lem-yath:boot-ok-p)') == 'T'
            bad_env = dict(env, SDL_VIDEODRIVER='lem-invalid-driver')
            bad = subprocess.run(command + ['-c'], cwd=root, env=bad_env,
                                 capture_output=True, text=True, timeout=10)
            assert bad.returncode == 2 and 'Cannot initialize graphical display' in bad.stderr
            assert evaluate(count) == '0'
            print('PASS: display initialization failure exits with a diagnostic', flush=True)

            tty1, fd1 = terminal_client(80)
            tty2, fd2 = terminal_client(100)
            eventually(count, '2')
            assert evaluate(sizes) == '(80 100)'
            assert evaluate('(null (lem-daemon:request-buffer-list))') == 'T'
            os.write(fd1, b'iFIRST\x1b')
            eventually('(not (null (search "FIRST" (lem:buffer-text (lem:get-buffer "shared.lisp")))))', 'T')
            tty1.kill()
            tty1.wait(timeout=10)
            eventually(count, '1')
            os.write(fd2, b'iSECOND\x1b')
            eventually('(not (null (search "SECOND" (lem:buffer-text (lem:get-buffer "shared.lisp")))))', 'T')
            time.sleep(0.3)
            os.write(fd2, b'\x18\x03')
            assert tty2.wait(timeout=10) == 0
            eventually(count, '0')
            print('PASS: two terminal frames share edits and survive peer failure', flush=True)

            # A daemon cursor is transmitted separately from cached text rows.
            # Exercise the configured state hook on a real attached frame.
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
                peer.settimeout(10)
                peer.connect(str(root / 'XDG_RUNTIME_DIR' / 'lem' / 'sdl-test.sock'))

                def read_exact(length):
                    data = b''
                    while len(data) < length:
                        chunk = peer.recv(length - len(data))
                        assert chunk, 'cursor fixture transport closed'
                        data += chunk
                    return data

                def receive_message():
                    length, = struct.unpack('!I', read_exact(4))
                    assert length <= 1024 * 1024
                    return json.loads(read_exact(length))

                def send_message(kind, **fields):
                    data = json.dumps(dict(version=2, type=kind, id='cursor-check',
                                           **fields)).encode()
                    peer.sendall(struct.pack('!I', len(data)) + data)

                def cursor_request(kind, **fields):
                    send_message(kind, **fields)
                    screen = None
                    while True:
                        reply = receive_message()
                        if reply['type'] == 'screen':
                            screen = reply
                        elif reply['type'] == 'response':
                            assert reply['status'] == 'ok', reply
                            return reply.get('value'), screen

                send_message('hello')
                assert receive_message()['type'] == 'hello'
                cursor_request('attach', width=100, height=40)
                cursor_request('eval', form=
                    '(progn (lem:switch-to-buffer (lem:make-buffer "*cursor-wire*")) '
                    '(lem:insert-string (lem:current-point) "CURSORWIRE") '
                    '(lem:buffer-start (lem:current-point)))')
                states = [
                    ("'lem-vi-mode/states:normal", 'box', '#FF0000'),
                    ("'lem-vi-mode/states:insert", 'bar', '#00FF00'),
                    ('lem-yath::*lem-yath-emacs-state*', 'box', '#00FFFF'),
                    ("'lem-vi-mode/states:insert", 'bar', '#00FF00'),
                ]
                for state, shape, color in states:
                    value, screen = cursor_request('eval', form=
                        '(progn (lem:redraw-display :force t) '
                        '(setf (lem-vi-mode/core:current-state) ' + state + ') '
                        '(prog1 (not (lem-core::window-need-to-redraw-p (lem:current-window))) '
                        '(lem:redraw-display)))')
                    assert value['primary'] == 'T', 'cursor state invalidated daemon text rows'
                    assert screen['cursor']['shape'] == shape, screen['cursor']
                    assert screen['cursor']['color'] == color, screen['cursor']
                value, screen = cursor_request('eval', form=
                    "(progn (lem:set-attribute 'lem:cursor :bold t :underline t) "
                    '(lem:redraw-display :force t) '
                    "(setf (lem-vi-mode/core:current-state) 'lem-vi-mode/states:insert) "
                    '(prog1 (lem-core::window-need-to-redraw-p (lem:current-window)) '
                    '(lem:redraw-display)))')
                assert value['primary'] == 'T', 'cleared cursor text styles need a repaint'
                cursor_request('detach')
            eventually(count, '0')
            print('PASS: daemon cursor state updates preserve text caches and publish color/shape', flush=True)

            gui = []
            windows = []
            for index in range(2):
                log = (root / f'gui-{index}.log').open('w')
                process = start(command + ['-c', '-n', str(document)], stdout=log, stderr=log)
                gui.append(process)
                eventually(count, str(index + 1))
                windows.append(xdo('search', '--sync', '--all', '--pid', process.pid, '--name', 'Lem client').splitlines()[0])
                xdo('windowmove', windows[-1], index * 760, 0)
            assert len(set(windows)) == 2, windows
            assert evaluate(sizes) == '(100 100)'
            print('PASS: two native SDL clients attach to independent daemon frames', flush=True)
            xdo('windowfocus', '--sync', windows[0])
            xdo('type', '--clearmodifiers', '--delay', 30, 'iGUIONE')
            xdo('key', 'Escape')
            eventually('(not (null (search "GUIONE" (lem:buffer-text (lem:get-buffer "shared.lisp")))))', 'T')
            xdo('windowfocus', '--sync', windows[1])
            xdo('type', '--clearmodifiers', '--delay', 30, 'iGUITWO')
            xdo('key', 'Escape')
            eventually('(not (null (search "GUITWO" (lem:buffer-text (lem:get-buffer "shared.lisp")))))', 'T')
            print('PASS: both SDL keyboards edit the same persistent buffer', flush=True)
            geometry = dict(line.split('=', 1) for line in xdo('getwindowgeometry', '--shell', windows[0]).splitlines())
            cw, ch = int(geometry['WIDTH']) // 100, int(geometry['HEIGHT']) // 40
            xdo('windowsize', windows[0], cw * 80, ch * 35)
            eventually(sizes, '(80 100)')
            other = root / 'other.txt'
            other.write_text('one\ntwo\nthree\nfour\n')
            in_frame(100, '(lem:find-file ' + lisp_string(other) + ') (lem:redraw-display :force t)')
            xdo('windowfocus', '--sync', windows[0])
            xdo('type', '--clearmodifiers', '--delay', 30, 'iLEFT')
            xdo('windowfocus', '--sync', windows[1])
            xdo('key', 'j')
            deadline = time.monotonic() + 5
            while in_frame(100, '(lem:line-number-at-point (lem:current-point))') != '2':
                assert time.monotonic() < deadline, in_frame(100,
                    '(list (lem:buffer-name (lem:current-buffer)) '
                    '(lem:buffer-text (lem:current-buffer)) '
                    '(lem-vi-mode/core::state-name (lem-vi-mode/core:current-state)) '
                    '(lem:line-number-at-point (lem:current-point)))')
                time.sleep(0.05)
            assert evaluate('(string= (lem:buffer-text (lem:get-buffer "other.txt")) '
                            + lisp_string(other.read_text()) + ')') == 'T'
            xdo('windowfocus', '--sync', windows[0])
            xdo('type', '--clearmodifiers', '--delay', 30, 'CONTINUES')
            eventually('(not (null (search "LEFTCONTINUES" (lem:buffer-text (lem:get-buffer "shared.lisp")))))', 'T')
            xdo('key', 'Escape')
            print('PASS: Vi insert and normal states remain correct across client buffers', flush=True)
            xdo('key', 'g', 'g', 'Home')
            before_operator = evaluate('(lem:buffer-text (lem:get-buffer "shared.lisp"))')
            xdo('key', 'd')
            eventually('(not (null lem-core::*routed-input-session*))', 'T')
            xdo('windowfocus', '--sync', windows[1])
            xdo('key', 'j')
            assert in_frame(100, '(lem:line-number-at-point (lem:current-point))') == '2'
            xdo('windowfocus', '--sync', windows[0])
            xdo('key', 'w')
            deadline = time.monotonic() + 5
            while in_frame(100, '(lem:line-number-at-point (lem:current-point))') != '3':
                assert time.monotonic() < deadline, 'deferred normal-mode movement did not complete'
                time.sleep(0.05)
            assert evaluate('(lem:buffer-text (lem:get-buffer "shared.lisp"))') != before_operator
            print('PASS: a pending Vi operator keeps its client and mode across other client input', flush=True)

            evaluate('(lem:define-command daemon-display-prompt-done () () '
                     '(lem:buffer-start (lem:current-point)))')
            xdo('key', 'alt+x')
            deadline = time.monotonic() + 5
            while in_frame(80, '(not (null (lem-core::frame-prompt-active-p (lem:current-frame))))') != 'T':
                assert time.monotonic() < deadline, 'M-x did not open its client prompt'
                time.sleep(0.05)
            xdo('type', '--clearmodifiers', '--delay', 30, 'daemon-display-prompt-d')
            xdo('key', 'Tab')
            prompt_text = '(lem:get-prompt-input-string (lem/prompt-window:current-prompt-window))'
            deadline = time.monotonic() + 5
            while in_frame(80, prompt_text) != '"daemon-display-prompt-done"':
                assert time.monotonic() < deadline, 'Tab did not complete the M-x command'
                time.sleep(0.05)
            xdo('windowfocus', '--sync', windows[1])
            xdo('key', 'j')
            time.sleep(0.2)
            assert in_frame(100, '(lem:line-number-at-point (lem:current-point))') == '3', \
                'another client moved before the active minibuffer completed'
            assert in_frame(80, prompt_text) == '"daemon-display-prompt-done"', \
                'another client contaminated the active minibuffer'
            xdo('windowfocus', '--sync', windows[0])
            xdo('key', 'Return')
            deadline = time.monotonic() + 5
            while in_frame(100, '(lem:line-number-at-point (lem:current-point))') != '4':
                assert time.monotonic() < deadline, 'minibuffer completion did not release deferred input'
                time.sleep(0.05)
            assert in_frame(80, '(null (lem-core::frame-prompt-active-p (lem:current-frame)))') == 'T'
            for columns in [80, 100]:
                assert in_frame(columns, '(string= "NORMAL" '
                                '(lem-vi-mode/core::state-name (lem-vi-mode/core:current-state)))') == 'T'
            print('PASS: M-x completion keeps its prompt and defers another client until submission', flush=True)

            xdo('key', 'alt+x')
            xdo('type', '--clearmodifiers', '--delay', 30, 'daemon-display-prompt-d')
            xdo('key', 'Tab')
            deadline = time.monotonic() + 5
            while in_frame(80, prompt_text) != '"daemon-display-prompt-done"':
                assert time.monotonic() < deadline, 'the second M-x completion did not finish'
                time.sleep(0.05)
            xdo('windowfocus', '--sync', windows[1])
            xdo('key', 'alt+x')
            time.sleep(0.2)
            assert in_frame(100, '(null (lem/prompt-window:current-prompt-window))') == 'T', \
                'overlapping prompts entered the shared recursive command stack'
            assert in_frame(80, prompt_text) == '"daemon-display-prompt-done"'
            xdo('windowfocus', '--sync', windows[0])
            xdo('key', 'ctrl+g')
            deadline = time.monotonic() + 5
            while in_frame(100, '(not (null (lem-core::frame-prompt-active-p (lem:current-frame))))') != 'T':
                assert time.monotonic() < deadline, 'cancellation did not release the other client prompt'
                time.sleep(0.05)
            xdo('windowfocus', '--sync', windows[1])
            xdo('type', '--clearmodifiers', '--delay', 30, 'daemon-display-prompt-done')
            deadline = time.monotonic() + 5
            while in_frame(100, prompt_text) != '"daemon-display-prompt-done"':
                assert time.monotonic() < deadline, 'the second client prompt lost typed characters'
                time.sleep(0.05)
            xdo('key', 'Return')
            deadline = time.monotonic() + 5
            while in_frame(100, '(null (lem/prompt-window:current-prompt-window))') != 'T':
                assert time.monotonic() < deadline, 'the second client prompt did not complete'
                time.sleep(0.05)
            for columns in [80, 100]:
                assert in_frame(columns, '(and (null (lem/prompt-window:current-prompt-window)) '
                                '(string= "NORMAL" (lem-vi-mode/core::state-name '
                                '(lem-vi-mode/core:current-state))))') == 'T'
            xdo('windowfocus', '--sync', windows[0])
            print('PASS: cancelling M-x releases a second client prompt without losing its input', flush=True)
            in_frame(100, '(lem:find-file ' + lisp_string(document) + ') (lem:redraw-display :force t)')

            clip = start([xclip, '-selection', 'clipboard', '-quiet'], stdin=subprocess.PIPE,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            clip.stdin.write('CLIPBOARD λ'.encode())
            clip.stdin.close()
            time.sleep(0.2)
            xdo('key', 'ctrl+shift+v')
            eventually('(not (null (search "CLIPBOARD λ" (lem:buffer-text (lem:get-buffer "shared.lisp")))))', 'T')
            print('PASS: SDL clipboard paste inserts literal Unicode text', flush=True)
            xdo('mousemove', '--window', windows[0], cw * 10 + 2, ch * 2 + 2)
            xdo('click', 1)
            time.sleep(0.2)
            points = '(loop for c in lem-daemon::*daemon-connections* for i = (lem-daemon::connection-implementation c) when (and i (= 80 (lem-daemon::daemon-implementation-width i))) collect (lem:line-number-at-point (lem:window-point (lem:frame-current-window (lem:get-frame i)))))'
            eventually(points, '(3)')
            print('PASS: SDL resize and mouse coordinates reach the originating frame', flush=True)
            xdo('click', '--repeat', 3, '--delay', 100, 5)
            time.sleep(0.4)
            subprocess.run([magick, 'import', '-display', env['DISPLAY'], '-window', 'root',
                            os.environ.get('LEM_SCREENSHOT', str(root / 'display.png'))], env=env, check=True, timeout=15)
            gui[0].kill()
            gui[0].wait(timeout=10)
            eventually(count, '1')
            terminal, master = terminal_client(90)
            eventually(count, '2')
            os.write(master, b'iTTY\x1b')
            eventually('(not (null (search "TTY" (lem:buffer-text (lem:get-buffer "shared.lisp")))))', 'T')
            xdo('windowfocus', '--sync', windows[1])
            xdo('type', '--clearmodifiers', '--delay', 30, 'iSURVIVED')
            xdo('key', 'Escape')
            eventually('(not (null (search "SURVIVED" (lem:buffer-text (lem:get-buffer "shared.lisp")))))', 'T')
            final_text = evaluate('(lem:buffer-text (lem:get-buffer "shared.lisp"))')
            print('PASS: mixed terminal/SDL clients continue editing after a GUI client crash', flush=True)
            xdo('key', 'ctrl+x', 'ctrl+c')
            assert gui[1].wait(timeout=10) == 0
            eventually(count, '1')
            time.sleep(0.3)
            os.write(master, b'\x18\x03')
            assert terminal.wait(timeout=10) == 0
            eventually(count, '0')
            assert evaluate('(lem:buffer-text (lem:get-buffer "shared.lisp"))') == final_text
            print('PASS: closing the final client preserves modified buffers in the daemon', flush=True)

            log = (root / 'gui-reconnect.log').open('w')
            reconnected = start(command + ['-c', '-n', str(document)], stdout=log, stderr=log)
            eventually(count, '1')
            window = xdo('search', '--sync', '--all', '--pid', reconnected.pid, '--name', 'Lem client').splitlines()[0]
            close_window(window)
            assert reconnected.wait(timeout=10) == 0
            eventually(count, '0')
            print('PASS: graphical window closure releases only its frame', flush=True)

            log = (root / 'gui-malformed.log').open('w')
            malformed = start(command + ['-c', '-n', str(document)], stdout=log, stderr=log)
            eventually(count, '1')
            evaluate('(let ((c (find-if #\'lem-daemon::connection-implementation '
                     'lem-daemon::*daemon-connections*))) '
                     '(lem-daemon::daemon-send c '
                     '(lem-daemon/protocol:make-object "type" "screen" '
                     '"changes" (vector (lem-daemon/protocol:make-object "row" 900)))))')
            assert malformed.wait(timeout=10) == 2
            eventually(count, '0')
            print('PASS: a graphical decoding error exits without entering a debugger', flush=True)

            log = (root / 'gui-daemon-loss.log').open('w')
            lost = start(command + ['-c', '-n', str(document)], stdout=log, stderr=log)
            eventually(count, '1')
            daemon.kill()
            daemon.wait(timeout=10)
            assert lost.wait(timeout=10) == 2
            assert 'Daemon disconnected' in (root / 'gui-daemon-loss.log').read_text()
            print('PASS: daemon death releases the graphical client with an error', flush=True)
    except BaseException:
        for path in root.glob('*.log'):
            print(path.name, path.read_text()[-4000:])
        raise
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.kill()
            process.wait(timeout=10)
        for fd in masters:
            os.close(fd)
