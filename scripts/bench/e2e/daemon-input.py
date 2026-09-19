"""Measure a private configured daemon's input-to-screen protocol path.

Run with LEM_BIN=/absolute/path/to/configured/lem and --output results.json.
The probe types alternating x/Backspace keys at 25 ms intervals into a shared
1000-line buffer, drains every client's output, and waits for each screen to
contain the resulting text. Timing runs from socket write to decoding that
screen; it excludes SDL/terminal rendering and physical input/presentation.
CPU, Lisp allocation and GC CPU cover warmup plus measured keys and idle time.
GC CPU is not a wall-clock pause measurement. All configuration, files and
sockets are private; the daemon log and fixture remain under the printed path.
--load optionally installs a Lisp experiment only in this disposable daemon.
--resources adds per-input server counters for attribution. These cover receipt
through screen construction, before encoding/queueing/writing; the added metadata,
allocations and locks affect timing, so use separate uninstrumented comparisons.
"""
import argparse
import json
import os
import select
import socket
import statistics
import struct
import subprocess
import tempfile
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--clients', type=int, default=1)
parser.add_argument('--count', type=int, default=200)
parser.add_argument('--output', required=True)
parser.add_argument('--warmup', type=int, default=20)
parser.add_argument('--pace', type=float, default=0.025)
parser.add_argument('--load')
parser.add_argument('--resources', action='store_true',
                    help='include instrumented server receive-to-screen counters')
args = parser.parse_args()
if not 1 <= args.clients <= 16:
    parser.error('--clients must be between 1 and 16')
if args.count <= 0 or args.count % 2 or args.warmup < 0 or args.warmup % 2:
    parser.error('--count must be positive and even; --warmup must be nonnegative and even')
if args.pace < 0:
    parser.error('--pace must be nonnegative')
if args.load:
    args.load = str(Path(args.load).resolve(strict=True))
editor = os.environ['LEM_BIN']
root = Path(tempfile.mkdtemp(prefix='lem-wire-bench-'))
print('ARTIFACTS: ' + str(root), flush=True)
env = dict(os.environ, TERM='xterm-256color',
           LEM_YATH_OPENROUTER_MODEL_REFRESH='0', LEM_YATH_CODEX_MODEL_REFRESH='0')
for key in ('HOME', 'XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME', 'XDG_DATA_HOME', 'LEM_HOME'):
    directory = root / key
    directory.mkdir(mode=0o700)
    env[key] = str(directory)
document = root / 'bench.txt'
document.write_text('BENCH_TARGET\n' + ''.join(
    f'Line {i}: repeatable editor text.\n' for i in range(1000)))
peers = []
rows = {}
serial = 0

def send(peer, kind, **fields):
    global serial
    serial += 1
    msg = dict(version=2, type=kind, id=str(serial), **fields)
    data = json.dumps(msg).encode()
    frame = struct.pack('!I', len(data)) + data
    sent_at = time.perf_counter_ns()
    peer.sendall(frame)
    return str(serial), sent_at

def exact(peer, n):
    data = b''
    while len(data) < n:
        part = peer.recv(n - len(data))
        if not part:
            raise RuntimeError('Unexpected EOF')
        data += part
    return data

def receive(peer):
    n, = struct.unpack('!I', exact(peer, 4))
    assert n <= 1048576
    msg = json.loads(exact(peer, n))
    if msg['type'] == 'screen':
        if msg.get('full'):
            rows[peer] = [r['text'] for r in msg['rows']]
        else:
            for change in msg['changes']:
                rows[peer][change['row']] = change['text']
    return msg

def poll(timeout):
    ready, _, _ = select.select(peers, [], [], timeout)
    for peer in ready:
        yield peer, receive(peer)

def request(peer, kind, **fields):
    ident, _ = send(peer, kind, **fields)
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        for origin, msg in poll(1):
            if origin is peer and msg.get('id') == ident and msg['type'] == 'response':
                if msg.get('status') == 'pending':
                    continue
                assert msg.get('status') == 'ok', msg
                return msg.get('value')
    raise TimeoutError(kind)

def evaluate(peer, form):
    return request(peer, 'eval', form=form)['primary']

def quote(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


process = None
try:
    with (root / 'daemon.log').open('w') as log:
        process = subprocess.Popen([editor, '--daemon=bench'], env=env, cwd=root,
                                   stdout=log, stderr=subprocess.STDOUT)
    endpoint = root / 'XDG_RUNTIME_DIR' / 'lem' / 'bench.sock'
    deadline = time.monotonic() + 20
    while not endpoint.exists():
        assert process.poll() is None, (root / 'daemon.log').read_text()
        if time.monotonic() > deadline:
            raise TimeoutError('startup')
        time.sleep(0.025)
    for index in range(args.clients):
        peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        peer.settimeout(10)
        peer.connect(str(endpoint))
        peers.append(peer)
        send(peer, 'hello', capabilities=[])
        assert receive(peer)['type'] == 'hello'
        request(peer, 'attach', width=100, height=40)
        assert evaluate(peer, '(lem-yath:boot-ok-p)') == 'T'
        evaluate(peer, '(progn (lem:switch-to-buffer (lem:find-file-buffer '
                 + quote(document) + ')) (lem:buffer-start (lem:current-point)) '
                 '(lem-vi-mode/commands:vi-insert) (lem:redraw-display :force t))')
    if args.load:
        evaluate(peers[0], '(load ' + quote(args.load) + ')')
    if args.resources:
        resource_source = Path(__file__).with_name('daemon-input-resources.lisp').resolve()
        evaluate(peers[0], '(load ' + quote(resource_source) + ')')
        evaluate(peers[0], '(lem-bench/daemon-input-resources:start)')
    time.sleep(0.1)
    while list(poll(0)):
        pass
    resources = ('(list (get-internal-run-time) (sb-ext:get-bytes-consed) '
                 'sb-ext:*gc-run-time* internal-time-units-per-second)')
    start_resources = evaluate(peers[0], resources)
    records = []
    for index in range(args.count + args.warmup):
        inserted = index % 2 == 0
        ident, start = send(peers[0], 'input', sym='x' if inserted else 'Backspace')
        reached = {}
        server_resources = None
        accepted = False
        deadline = time.monotonic() + 10
        while len(reached) < len(peers) or not accepted:
            if time.monotonic() > deadline:
                raise TimeoutError(f'Input {index}: {len(reached)}/{len(peers)} clients updated')
            for peer, msg in poll(1):
                now = time.perf_counter_ns()
                if peer is peers[0] and msg.get('id') == ident:
                    assert msg.get('status') == 'ok', msg
                    accepted = True
                if msg['type'] == 'screen' and peer not in reached:
                    line = next((r for r in rows[peer] if 'BENCH_TARGET' in r), '')
                    if line and ('xBENCH_TARGET' in line) == inserted:
                        reached[peer] = (now - start) / 1000000.0
                        if args.resources and peer is peers[0]:
                            server_resources = msg['benchmark']
                            assert server_resources['input-id'] == ident
                            assert server_resources['units-per-second'] > 0
                            for counter in ('wall', 'cpu', 'gc-cpu', 'consed'):
                                assert (server_resources['screen-' + counter]
                                        >= server_resources['received-' + counter])
        if index >= args.warmup:
            record = dict(active_ms=reached[peers[0]], all_ms=max(reached.values()))
            if args.resources:
                assert server_resources is not None
                record['server'] = server_resources
            records.append(record)
        time.sleep(args.pace)
    stop_resources = evaluate(peers[0], resources)
    assert evaluate(peers[0], '(string= (lem:buffer-text (lem:current-buffer)) '
                    '(uiop:read-file-string ' + quote(document) + '))') == 'T'
    start_counters = list(map(int, start_resources.strip('()').split()))
    stop_counters = list(map(int, stop_resources.strip('()').split()))
    assert start_counters[3] == stop_counters[3]
    units = start_counters[3]
    result = dict(
        editor=editor, clients=args.clients, root=str(root), samples=records,
        warmup=args.warmup, pace_seconds=args.pace, loaded_source=args.load,
        server_resources=args.resources,
        resource_keys=args.count + args.warmup,
        process_cpu_ms=1000 * (stop_counters[0] - start_counters[0]) / units,
        lisp_bytes=stop_counters[1] - start_counters[1],
        gc_cpu_ms=1000 * (stop_counters[2] - start_counters[2]) / units)
    for key in ('active_ms', 'all_ms'):
        values = sorted(r[key] for r in records)
        result[key] = dict(p50=statistics.median(values),
                           p95=values[int(0.95 * (len(values) - 1))], maximum=max(values))
    Path(args.output).write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'samples'}), flush=True)
    request(peers[0], 'shutdown', force=True)
    process.wait(timeout=20)
finally:
    for peer in peers:
        peer.close()
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
