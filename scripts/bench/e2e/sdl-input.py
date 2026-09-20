"""Synthetic X11 or pipe/SDL input -> matching SDL presentation acknowledgement.

Run inside nix develop with LEM_BIN pointing to a configured daemon package.
The client loads this checkout through Qlot. Xvfb, HOME, configuration, socket
and document are private. No real desktop or source fixture is written.
Client-local timing starts at send-input entry and ends immediately after
SDL_RenderPresent returns. Submission timing also includes X11/SDL event
handling and acknowledgement transport. The sdl input method uses a private
pipe and native SDL3 events on an offscreen SDL2-compat renderer, excluding X11 delivery.
Neither endpoint measures GPU completion or physical monitor latency.
Client counters span initial fixture presentation through the last measured
presentation, including setup, warmup and instrumentation. Server counters span
resource evaluations before warmup and after the final pacing interval. GC CPU
is not a wall pause. Results are written only after full text/byte checks and clean exits.
"""
import argparse
import ctypes
import ctypes.util
import hashlib
import json
import math
import os
from pathlib import Path
import select
import shlex
import shutil
import socket
import statistics
import struct
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--count', type=int, default=200)
parser.add_argument('--warmup', type=int, default=20)
parser.add_argument('--pace', type=float, default=0.025)
parser.add_argument('--fixture', type=Path)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--input-method', choices=('x11', 'sdl'), default='x11')
parser.add_argument('--renderer', choices=('software', 'opengl'))
parser.add_argument('--client-sdl-source', type=Path,
                    help='Load an alternate client SDL source file for a controlled comparison')
args = parser.parse_args()
if args.count <= 0 or args.count % 2 or args.warmup < 0 or args.warmup % 2 or not math.isfinite(args.pace) or args.pace < 0:
    parser.error('count must be positive/even, warmup nonnegative/even, pace nonnegative')
if args.output.exists() or not args.output.parent.is_dir():
    parser.error('output must be a new file in an existing directory')
repo = Path(__file__).resolve().parents[3]
fixture = args.fixture.resolve(strict=True) if args.fixture else None
original = fixture.read_bytes() if fixture else b''.join(
    f'Line {i}: repeatable editor text.\n'.encode() for i in range(1000))
try:
    text = original.decode('utf-8')
except UnicodeDecodeError:
    parser.error('fixture must be UTF-8 text')
if '\r' in text:
    parser.error('fixture must use UTF-8 and LF line endings')
document_bytes = b'BENCH_TARGET\n' + original
editor = str(Path(os.environ['LEM_BIN']).absolute())
editor_resolved = str(Path(editor).resolve(strict=True))
revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip()
client_source = (args.client_sdl_source or repo / 'frontends/daemon/sdl-client.lisp').resolve(strict=True)
source_sha256 = hashlib.sha256(client_source.read_bytes()).hexdigest()
for command in ('sbcl',) + (('Xvfb', 'xdotool') if args.input_method == 'x11' else ('pkg-config',)):
    assert shutil.which(command), f'{command} is required; use nix develop'
if args.input_method == 'x11':
    xlib = ctypes.CDLL(os.environ.get('LEM_X11_LIBRARY') or ctypes.util.find_library('X11'))
    xtest = ctypes.CDLL(os.environ.get('LEM_XTEST_LIBRARY') or ctypes.util.find_library('Xtst'))
    xlib.XOpenDisplay.argtypes = [ctypes.c_char_p]
    xlib.XOpenDisplay.restype = ctypes.c_void_p
    xlib.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    xlib.XKeysymToKeycode.restype = ctypes.c_ubyte
    xlib.XFlush.argtypes = [ctypes.c_void_p]
    xlib.XCloseDisplay.argtypes = [ctypes.c_void_p]
    xtest.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
    xtest.XTestFakeKeyEvent.restype = ctypes.c_int
root = Path(tempfile.mkdtemp(prefix='lem-sdl-input-', dir='/tmp'))
print('ARTIFACTS: ' + str(root), flush=True)
env = dict(os.environ, TERM='xterm-256color',
           SDL_VIDEODRIVER='x11' if args.input_method == 'x11' else 'offscreen',
           LEM_YATH_OPENROUTER_MODEL_REFRESH='0', LEM_YATH_CODEX_MODEL_REFRESH='0')
if args.renderer:
    env['SDL_RENDER_DRIVER'] = args.renderer
for key in ('LEM_SDL_INPUT_FD', 'LEM_SDL_INPUT_LIBRARY'):
    env.pop(key, None)
env.pop('LEM_SDL_SOURCE', None)
if args.client_sdl_source:
    env['LEM_SDL_SOURCE'] = str(client_source)
for key in ('HOME', 'XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME',
            'XDG_STATE_HOME', 'XDG_DATA_HOME', 'LEM_HOME'):
    directory = root / key
    directory.mkdir(mode=0o700)
    env[key] = str(directory)
document = root / 'bench.txt'
document.write_bytes(document_bytes)
processes, descriptors, logs = [], [], []
peer = display = None
serial = 0
ack_buffer = bytearray()

def start(command, name, **kwargs):
    log = (root / (name + '.log')).open('wb')
    logs.append(log)
    process = subprocess.Popen(command, env=env, cwd=repo, stdout=log,
                               stderr=subprocess.STDOUT, **kwargs)
    processes.append(process)
    return process

def line(fd, buffer, timeout):
    deadline = time.monotonic() + timeout
    while b'\n' not in buffer:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
            raise TimeoutError(f'No reply; inspect {root}')
        chunk = os.read(fd, 65536)
        assert chunk, f'Unexpected pipe EOF; inspect {root}'
        buffer.extend(chunk)
        assert len(buffer) <= 1048576, 'Oversized pipe reply'
    value, _, rest = buffer.partition(b'\n')
    buffer[:] = rest
    return value

def exact(n):
    data = b''
    while len(data) < n:
        part = peer.recv(n - len(data))
        assert part, 'Unexpected daemon EOF'
        data += part
    return data

def request(kind, **fields):
    global serial
    serial += 1
    data = json.dumps(dict(version=2, type=kind, id=str(serial), **fields)).encode()
    peer.sendall(struct.pack('!I', len(data)) + data)
    while True:
        size, = struct.unpack('!I', exact(4))
        assert size <= 1048576
        msg = json.loads(exact(size))
        if kind == 'hello' and msg['type'] == 'hello':
            return msg
        if msg.get('id') == str(serial) and msg['type'] == 'response':
            if msg.get('status') == 'pending':
                continue
            assert msg.get('status') == 'ok', msg
            return msg.get('value')

def quote(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'

def evaluate(form, gui=False):
    if gui:
        form = ('(let ((clients (remove-if-not #\'lem-daemon::connection-implementation '
                'lem-daemon::*daemon-connections*))) (assert (= 1 (length clients))) '
                '(lem-daemon::activate-implementation '
                '(lem-daemon::connection-implementation (first clients))) ' + form + ')')
    return request('eval', form=form)['primary']

resources = ('(list (get-internal-run-time) (sb-ext:get-bytes-consed) '
             'sb-ext:*gc-run-time* internal-time-units-per-second)')
try:
    if args.input_method == 'x11':
        readfd, writefd = os.pipe()
        descriptors.extend((readfd, writefd))
        xserver = start(['Xvfb', '-displayfd', str(writefd), '-screen', '0',
                         '1600x1000x24', '-nolisten', 'tcp', '-noreset'],
                        'xserver', pass_fds=(writefd,))
        os.close(writefd)
        descriptors.remove(writefd)
        number = line(readfd, bytearray(), 10).decode()
        assert number.isdigit()
        env['DISPLAY'] = ':' + number
    else:
        helper = root / 'sdl-input-events.so'
        flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', 'sdl3'], text=True))
        subprocess.run(shlex.split(os.environ.get('CC', 'cc')) +
                       ['-shared', '-fPIC', '-Wall', '-Wextra', '-Werror',
                        str(Path(__file__).with_name('sdl-input-events.c')), '-o', str(helper)] + flags,
                       check=True, env=env)
        inputfd, commandfd = os.pipe()
        descriptors.extend((inputfd, commandfd))
        env.update(LEM_SDL_INPUT_FD=str(inputfd), LEM_SDL_INPUT_LIBRARY=str(helper))
    daemon = start([editor, '--daemon=sdl-input-bench'], 'daemon')
    endpoint = root / 'XDG_RUNTIME_DIR/lem/sdl-input-bench.sock'
    deadline = time.monotonic() + 30
    while not endpoint.exists():
        assert daemon.poll() is None, f'Daemon failed; inspect {root}'
        if time.monotonic() > deadline:
            raise TimeoutError('daemon startup')
        time.sleep(0.025)
    peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    peer.settimeout(20)
    peer.connect(str(endpoint))
    request('hello', capabilities=[])
    assert evaluate('(lem-yath:boot-ok-p)') == 'T'
    ackfd, writefd = os.pipe()
    descriptors.extend((ackfd, writefd))
    env.update(LEM_SDL_ACK_FD=str(writefd), LEM_SDL_DOCUMENT=str(document), LEM_SDL_REPO=str(repo))
    client = start(['sbcl', '--noinform', '--no-sysinit', '--no-userinit',
                    '--load', str(repo / '.qlot/setup.lisp'), '--script',
                    str(Path(__file__).with_name('sdl-input-client.lisp'))],
                   'client', pass_fds=(writefd,) + ((inputfd,) if args.input_method == 'sdl' else ()))
    os.close(writefd)
    descriptors.remove(writefd)
    if args.input_method == 'sdl':
        os.close(inputfd)
        descriptors.remove(inputfd)
    initial = json.loads(line(ackfd, ack_buffer, 120))
    assert initial['sequence'] == 0 and not initial['inserted']
    if args.renderer:
        assert initial['renderer']['name'] == args.renderer, initial['renderer']
    assert evaluate('(progn (assert (eq (lem:current-buffer) (lem:get-file-buffer '
                    + quote(document) + '))) (lem:buffer-start (lem:current-point)) '
                    '(lem-vi-mode/commands:vi-insert) (lem:redraw-display :force t) t)', gui=True) == 'T'
    if args.input_method == 'x11':
        windows = subprocess.check_output(['xdotool', 'search', '--name', '^Lem client$'],
                                          env=env, text=True, timeout=10).split()
        assert len(windows) == 1
        subprocess.run(['xdotool', 'windowfocus', '--sync', windows[0]], env=env, check=True, timeout=10)
        display = xlib.XOpenDisplay(env['DISPLAY'].encode())
        assert display
        keycodes = [xlib.XKeysymToKeycode(display, symbol) for symbol in (ord('x'), 0xff08)]
        assert all(keycodes)
    time.sleep(0.2)
    start_resources = evaluate(resources, gui=True)
    records = []
    for index in range(args.count + args.warmup):
        submitted = time.perf_counter_ns()
        if args.input_method == 'x11':
            keycode = keycodes[index % 2]
            assert xtest.XTestFakeKeyEvent(display, keycode, 1, 0)
            assert xtest.XTestFakeKeyEvent(display, keycode, 0, 0)
            xlib.XFlush(display)
        else:
            assert os.write(commandfd, b'x' if index % 2 == 0 else b'\b') == 1
        reply = json.loads(line(ackfd, ack_buffer, 10))
        acknowledged = time.perf_counter_ns()
        assert reply['sequence'] == index + 1
        assert bool(reply['inserted']) == (index % 2 == 0)
        if index >= args.warmup:
            records.append(dict(submission_ack_ms=(acknowledged-submitted)/1000000,
                                client_send_to_present_ms=reply['client_send_to_present_ms']))
        time.sleep(args.pace)
    stop_resources = evaluate(resources, gui=True)
    assert evaluate('(string= (lem:buffer-text (lem:current-buffer)) '
                    '(uiop:read-file-string ' + quote(document) + '))', gui=True) == 'T'
    assert evaluate('(progn (lem:save-buffer (lem:current-buffer)) '
                    '(not (lem:buffer-modified-p (lem:current-buffer))))', gui=True) == 'T'
    assert document.read_bytes() == document_bytes
    if fixture:
        assert fixture.read_bytes() == original
    assert hashlib.sha256(client_source.read_bytes()).hexdigest() == source_sha256
    result = dict(input_method=args.input_method,
                  native_event_api='SDL3 through SDL2-compat' if args.input_method == 'sdl' else None,
                  renderer_requested=args.renderer,
                  renderer=initial['renderer'],
                  graphics_environment={key: env.get(key) for key in
                                        ('SDL_RENDER_DRIVER', 'SDL_RENDER_BATCHING', 'EGL_PLATFORM',
                                         '__EGL_VENDOR_LIBRARY_FILENAMES')},
                  probe_sha256={name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
                                for name in ('sdl-input.py', 'sdl-input-client.lisp', 'sdl-input-events.c')},
                  editor=editor, editor_resolved=editor_resolved, client_source=str(repo),
                  client_revision=revision, client_sdl_source=str(client_source), client_sdl_sha256=source_sha256,
                  client_runtime="source-loaded SBCL after full GC", root=str(root), samples=records,
                  warmup=args.warmup, pace_seconds=args.pace, fixture_source=str(fixture) if fixture else None,
                  fixture_bytes=len(document_bytes), fixture_sha256=hashlib.sha256(document_bytes).hexdigest())
    first, last = [list(map(int, value.strip('()').split())) for value in (start_resources, stop_resources)]
    assert first[3] == last[3] == initial['units'] == reply['units']
    for name, start_counters, end_counters in (
            ('server', first, last), ('client', [initial[k] for k in ('cpu', 'bytes', 'gc')],
             [reply[k] for k in ('cpu', 'bytes', 'gc')])):
        result[name] = dict(cpu_ms=1000*(end_counters[0]-start_counters[0])/first[3],
                            lisp_bytes=end_counters[1]-start_counters[1],
                            gc_cpu_ms=1000*(end_counters[2]-start_counters[2])/first[3])
    for name in ('submission_ack_ms', 'client_send_to_present_ms'):
        values = sorted(record[name] for record in records)
        result[name] = dict(p50=statistics.median(values), p95=values[int(.95*(len(values)-1))], maximum=max(values))
    if args.input_method == 'sdl':
        os.close(commandfd)
        descriptors.remove(commandfd)
    assert evaluate('(lem-if:close-frontend (lem:implementation))', gui=True) == 'T'
    assert client.wait(timeout=20) == 0, f'Client exit failed; inspect {root}'
    request('shutdown', force=True)
    assert daemon.wait(timeout=20) == 0
    result.update(daemon_exit_code=0, client_exit_code=0)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: value for key, value in result.items() if key != 'samples'}), flush=True)
finally:
    if display:
        xlib.XCloseDisplay(display)
    if peer:
        peer.close()
    for fd in descriptors:
        os.close(fd)
    for process in reversed(processes):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    for log in logs:
        log.close()
