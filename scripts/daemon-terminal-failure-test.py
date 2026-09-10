"""Check native terminal cleanup with a private peer that stays connected.

Set LEMCLIENT_BIN to a built native client. The Python driver supplies protocol
messages and PTY input; the terminal and transport runtime remain Common Lisp.
"""

import fcntl
import json
import os
from pathlib import Path
import pty
import select
import socket
import struct
import subprocess
import tempfile
import termios
import threading
import time


def receive(peer):
    def exact(length):
        result = b''
        while len(result) < length:
            part = peer.recv(length - len(result))
            if not part:
                raise EOFError('client closed before its attachment request')
            result += part
        return result
    return json.loads(exact(struct.unpack('>I', exact(4))[0]))


def send(peer, message):
    encoded = json.dumps(message).encode()
    peer.sendall(struct.pack('>I', len(encoded)) + encoded)


def check_failure(kind):
    with tempfile.TemporaryDirectory(prefix='lem-terminal-reader-') as temporary:
        root = Path(temporary)
        (root / 'lem').mkdir(mode=0o700)
        endpoint = root / 'lem' / 'terminal-test.sock'
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(endpoint))
        endpoint.chmod(0o600)
        listener.listen(1)
        listener.settimeout(5)
        master, slave = pty.openpty()
        before = termios.tcgetattr(slave)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
        output = bytearray()
        finished = threading.Event()

        def drain():
            while not finished.is_set():
                try:
                    if select.select([master], [], [], 0.1)[0]:
                        output.extend(os.read(master, 4096))
                except OSError:
                    return

        reader = threading.Thread(target=drain, daemon=True)
        reader.start()
        arguments = [os.environ['LEMCLIENT_BIN'], '--server-name', 'terminal-test', '-t']
        if kind == 'invalid-file-argument':
            arguments.append('+3')
        env = dict(os.environ, XDG_RUNTIME_DIR=temporary, TERM='xterm-256color')
        process = subprocess.Popen(arguments, env=env, cwd=root,
                                   stdin=slave, stdout=slave, stderr=slave)
        peer = None
        try:
            peer, _ = listener.accept()
            peer.settimeout(5)
            assert receive(peer)['type'] == 'hello'
            send(peer, {'version': 2, 'type': 'hello'})
            assert receive(peer)['type'] == 'attach'
            if kind != 'invalid-file-argument':
                send(peer, {'version': 2, 'type': 'screen', 'full': True,
                            'rows': [{'text': ' ' * 80, 'runs': []} for _ in range(24)],
                            'foreground': '#FFFFFF', 'background': '#000000',
                            'mouse': False, 'escape-delay': 50,
                            'cursor': {'x': 0, 'y': 0, 'shape': 'box', 'color': '#FFFFFF'}})
                time.sleep(0.2)
            if kind == 'input-decode-error':
                # A truncated multibyte sequence fails on the input/UI thread
                # after its byte timeout, while the screen reader is blocked.
                os.write(master, b'\xc2')
            elif kind == 'normal-close':
                send(peer, {'version': 2, 'type': 'close', 'reason': 'test'})
            elif kind == 'daemon-loss':
                peer.close()
                peer = None
            status = process.wait(timeout=5)
            time.sleep(0.1)
            expected = 0 if kind == 'normal-close' else 2
            assert status == expected, (kind, status, output.decode(errors='replace'))
            if expected == 2:
                assert b'lemclient:' in output, (kind, output.decode(errors='replace'))
            if kind == 'daemon-loss':
                assert b'Daemon disconnected' in output
            assert termios.tcgetattr(slave) == before, f'{kind}: terminal modes were not restored'
            print(f'PASS: {kind} exits {expected} and restores terminal modes', flush=True)
        except BaseException:
            print(f'{kind} terminal output: {output.decode(errors="replace")}', flush=True)
            raise
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
            if peer is not None:
                peer.close()
            listener.close()
            finished.set()
            reader.join(timeout=1)
            os.close(slave)
            os.close(master)


for scenario in ['input-decode-error', 'invalid-file-argument', 'daemon-loss', 'normal-close']:
    check_failure(scenario)
