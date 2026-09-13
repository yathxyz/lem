"""Native terminal/SDL external-edit contract, with only synthetic files.

Set LEM_BIN and LEMCLIENT_BIN to the configured editor/client under test, and
LEM_TEST_X11 to libX11.so.6. Xvfb and xdotool must be on PATH.
Python is the test driver; both interactive clients run in Lisp.
No product source is injected. Logs and results stay in a private temporary dir.
"""
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import shutil
import struct
import subprocess
import tempfile
import termios
import threading
import time


def quoted(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


def read_display_number(descriptor, seconds=10):
    deadline = time.monotonic() + seconds
    line = bytearray()
    while b'\n' not in line:
        remaining = deadline - time.monotonic()
        assert remaining > 0 and select.select([descriptor], [], [], remaining)[0], \
            'Xvfb display number handshake timed out'
        chunk = os.read(descriptor, 100 - len(line))
        assert chunk, 'Xvfb closed its display number pipe before the newline'
        line.extend(chunk)
        assert len(line) < 100, 'Xvfb display number exceeded its bound'
    assert line.endswith(b'\n') and line[:-1].isdigit(), 'Invalid Xvfb display number'
    return ':' + line[:-1].decode('ascii')


def main():
    editor, client = os.environ['LEM_BIN'], os.environ['LEMCLIENT_BIN']
    xvfb, xdotool = (shutil.which(name) for name in ('Xvfb', 'xdotool'))
    assert xvfb and xdotool, 'Xvfb and xdotool are required'
    root = Path(tempfile.mkdtemp(prefix='lem-visible-edit-'))
    print('ARTIFACTS: ' + str(root), flush=True)
    env = dict(os.environ, TERM='xterm-256color', SDL_VIDEODRIVER='x11',
               LEM_YATH_OPENROUTER_MODEL_REFRESH='0', LEM_YATH_CODEX_MODEL_REFRESH='0',
               GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
    for key in ('XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME',
                'XDG_STATE_HOME', 'XDG_DATA_HOME', 'LEM_HOME', 'WORKDIR'):
        directory = root / key
        directory.mkdir(mode=0o700)
        env[key] = str(directory)
    command = [client, '--server-name', 'visible-edit']
    processes, terminals, checks = [], [], []
    result = {'editor': editor, 'client': client,
              'client_sha256': hashlib.sha256(Path(client).read_bytes()).hexdigest(),
              'checks': checks}

    def run(args, timeout=20):
        value = subprocess.run(args, cwd=root, env=env, text=True,
                               capture_output=True, timeout=timeout)
        assert value.returncode == 0, (args, value.stdout, value.stderr)
        return value.stdout.strip()

    def start(args, name, **kwargs):
        with (root / (name + '.log')).open('wb') as log:
            process = subprocess.Popen(args, cwd=root, env=env, stdout=log,
                                       stderr=subprocess.STDOUT, **kwargs)
        processes.append(process)
        return process

    def evaluate(form):
        return json.loads(run(command + ['--eval', form]))['primary']

    def wait(predicate, description, seconds=15):
        until = time.monotonic() + seconds
        while time.monotonic() < until:
            if predicate():
                return
            time.sleep(.04)
        raise AssertionError(description)

    def check(condition, description):
        assert condition, description
        checks.append(description)
        print('PASS: ' + description, flush=True)

    def buffer_form(path, form):
        return '(let ((buffer (lem:get-buffer ' + quoted(path.name) + '))) (and buffer ' + form + '))'

    def attached():
        return evaluate('(count-if #\'lem-daemon::connection-implementation lem-daemon::*daemon-connections*)')

    def waiting(path):
        return evaluate(buffer_form(path, '(not (null (lem-daemon::request-buffer-list buffer)))')) == 'T'

    def text(path):
        # The eval envelope's primary value is a printed Lisp string: literal
        # newlines are legal inside it, unlike a JSON string's representation.
        return json.loads(evaluate(buffer_form(path, '(lem:buffer-text buffer)')), strict=False)

    def xdo(*args):
        return run([xdotool] + list(map(str, args)))

    def window_close(window):
        # Xvfb has no window manager to implement xdotool's _NET_CLOSE_WINDOW.
        # Deliver the same WM_DELETE_WINDOW message as a real close button.
        class Message(ctypes.Structure):
            _fields_ = [('type', ctypes.c_int), ('serial', ctypes.c_ulong),
                        ('send_event', ctypes.c_int), ('display', ctypes.c_void_p),
                        ('window', ctypes.c_ulong), ('message_type', ctypes.c_ulong),
                        ('format', ctypes.c_int), ('data', ctypes.c_long * 5)]

        class Event(ctypes.Union):
            _fields_ = [('message', Message), ('padding', ctypes.c_long * 24)]

        xlib = ctypes.CDLL(os.environ['LEM_TEST_X11'])
        xlib.XOpenDisplay.argtypes = [ctypes.c_char_p]
        xlib.XOpenDisplay.restype = ctypes.c_void_p
        xlib.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        xlib.XInternAtom.restype = ctypes.c_ulong
        xlib.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int,
                                   ctypes.c_long, ctypes.POINTER(Event)]
        xlib.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
        xlib.XCloseDisplay.argtypes = [ctypes.c_void_p]
        display = xlib.XOpenDisplay(env['DISPLAY'].encode())
        assert display, 'private X display is unavailable'
        try:
            event = Event()
            event.message = Message(33, 0, 1, display, int(window),
                                    xlib.XInternAtom(display, b'WM_PROTOCOLS', 0), 32,
                                    (ctypes.c_long * 5)(
                                        xlib.XInternAtom(display, b'WM_DELETE_WINDOW', 0), 0, 0, 0, 0))
            assert xlib.XSendEvent(display, int(window), 0, 0, ctypes.byref(event)), 'close event failed'
            xlib.XSync(display, 0)
        finally:
            xlib.XCloseDisplay(display)

    class View:
        def __init__(self, mode, name, files=(), no_wait=False):
            self.mode, self.master, self.reader, self.window = mode, None, None, None
            args = command + [mode] + (['-n'] if no_wait else []) + list(map(str, files))
            if mode == '-t':
                self.master, slave = pty.openpty()
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 90, 0, 0))
                try:
                    self.process = subprocess.Popen(args, cwd=root, env=env, stdin=slave,
                                                    stdout=slave, stderr=slave, start_new_session=True)
                finally:
                    os.close(slave)
                processes.append(self.process)

                def drain():
                    with (root / (name + '.log')).open('wb') as log:
                        try:
                            while chunk := os.read(self.master, 65536):
                                log.write(chunk)
                        except OSError:
                            pass
                self.reader = threading.Thread(target=drain, daemon=True)
                self.reader.start()
                terminals.append(self)
            else:
                self.process = start(args, name)
            wait(lambda: attached() == '1', name + ' did not attach')
            if files:
                wait(lambda: evaluate(buffer_form(files[0], 't')) == 'T', name + ' did not visit')
            if mode == '-c':
                self.find_window()

        def find_window(self):
            # SDL's X11 backend can replace its initial window while creating
            # the renderer. Discover only after attachment, and refresh before
            # each action instead of retaining the first startup window ID.
            assert self.process.poll() is None, 'SDL client exited before its window action'
            windows = xdo('search', '--sync', '--onlyvisible', '--all',
                          '--pid', self.process.pid, '--name', '^Lem client$').splitlines()
            assert len(windows) == 1, 'Expected one visible window owned by the SDL client'
            self.window = windows[0]
            return self.window

        def keys(self, terminal, *graphical):
            if self.mode == '-t':
                os.write(self.master, terminal)
            else:
                xdo('windowfocus', '--sync', self.find_window())
                xdo('key', '--clearmodifiers', *graphical)

        def insert(self, value):
            # The configured acceptance image uses vi normal state for files.
            self.keys(b'i', 'i')
            if self.mode == '-t':
                os.write(self.master, value.encode())
            else:
                xdo('type', '--clearmodifiers', '--delay', 1, value)
            self.keys(b'\x1b', 'Escape')
            time.sleep(.15)  # disambiguate terminal Escape from a Meta prefix

        def exit(self, status):
            check(self.process.wait(timeout=15) == status,
                  self.mode + ' returns status ' + str(status))
            wait(lambda: attached() == '0', 'closed frame was not removed')

        def detach(self):
            self.keys(b'\x18\x03', 'ctrl+x', 'ctrl+c')

    try:
        readfd, writefd = os.pipe()
        try:
            start([xvfb, '-displayfd', str(writefd), '-screen', '0', '1400x1000x24',
                   '-nolisten', 'tcp', '-noreset'], 'xserver', pass_fds=[writefd])
        finally:
            os.close(writefd)
        try:
            # Xvfb may write the digits and newline separately. Closing after
            # an arbitrary first read can make its final write fail with EPIPE.
            env['DISPLAY'] = read_display_number(readfd)
        finally:
            os.close(readfd)
        daemon = start([editor, '--daemon=visible-edit'], 'daemon')
        run(command + ['--wait-for-server', '45', '--eval', 't'], timeout=50)
        check(evaluate('(lem-yath:boot-ok-p)') == 'T', 'configured daemon is ready')
        for mode in ('-t', '-c'):
            label = mode[1:]
            paths = [root / (label + '-' + name + '.txt')
                     for name in ('first', 'second', 'done', 'abort', 'detach', 'nowait')]
            for path in paths:
                path.write_text('original\n')
            first, second, done, abort, detach, nowait = paths
            view = View(mode, label + '-multi', [first, second])
            check(waiting(first) and waiting(second), mode + ' files create a real waiting edit request')
            view.insert('saved-one ')
            wait(lambda: 'saved-one' in text(first), 'first native insertion did not arrive')
            view.keys(b'\x03\x03', 'ctrl+c', 'ctrl+c')
            wait(lambda: not waiting(first), 'first edit did not finish')
            check(view.process.poll() is None and waiting(second), mode + ' waits for every file')
            view.insert('saved-two ')
            wait(lambda: 'saved-two' in text(second), 'second native insertion did not arrive')
            view.keys(b'\x03\x03', 'ctrl+c', 'ctrl+c')
            view.exit(0)
            check('saved-one' in first.read_text() and 'saved-two' in second.read_text(),
                  mode + ' native save-and-done saves both files')
            for path, keys, code in ((done, (b'\x18#', 'ctrl+x', 'numbersign'), 0),
                                     (abort, (b'\x03\x0b', 'ctrl+c', 'ctrl+k'), 1)):
                view = View(mode, path.stem, [path])
                check(waiting(path), mode + ' ' + path.stem + ' is pending')
                view.insert('retained ')
                wait(lambda: 'retained' in text(path), 'unsaved insertion did not arrive')
                view.keys(*keys)
                view.exit(code)
                check(path.read_text() == 'original\n' and 'retained' in text(path),
                      mode + ' ' + path.stem + ' retains unsaved text without saving')
            view = View(mode, label + '-detach', [detach])
            check(waiting(detach), mode + ' early detach starts with an unfinished edit')
            view.detach()
            view.exit(1)
            wait(lambda: not waiting(detach), 'disconnected request was not cancelled')
            if mode == '-c':
                view = View(mode, 'c-window-close', [detach])
                check(waiting(detach), 'SDL window close starts with an unfinished edit')
                window_close(view.find_window())
                view.exit(1)
                wait(lambda: not waiting(detach), 'window-closed request was not cancelled')
            view = View(mode, label + '-persistent')
            check(view.process.poll() is None, mode + ' no-file attachment stays alive')
            view.detach()
            view.exit(0)
            view = View(mode, label + '-nowait', [nowait], no_wait=True)
            check(not waiting(nowait) and view.process.poll() is None,
                  mode + ' -n opens without edit mode and remains attached')
            if mode == '-c':
                window_close(view.find_window())
            else:
                view.detach()
            view.exit(0)
        # Unexpected transport loss must not look like successful completion.
        for mode in ('-t', '-c'):
            if daemon.poll() is not None:
                daemon = start([editor, '--daemon=visible-edit'], 'daemon-restarted')
                run(command + ['--wait-for-server', '45', '--eval', 't'], timeout=50)
            lost = root / (mode[1:] + '-disconnect.txt')
            lost.write_text('original\n')
            view = View(mode, mode[1:] + '-disconnect', [lost])
            check(waiting(lost), mode + ' disconnect test has an unfinished external edit')
            daemon.kill()
            daemon.wait(timeout=10)
            check(view.process.wait(timeout=15) == 2,
                  mode + ' daemon death returns client transport-error status 2')
        result['passed'] = True
    except BaseException as error:
        result['error'] = str(error)
        raise
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.kill()
            process.wait(timeout=10)
        for view in terminals:
            os.close(view.master)
            view.reader.join(timeout=2)
        (root / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print('RESULT: ' + str(root / 'result.json'), flush=True)


if __name__ == '__main__':
    main()
