"""Focused configured Legit acceptance in two native SDL frames.

LEM_BIN/LEMCLIENT_BIN name built products. Xvfb and xdotool must be on PATH.
Only synthetic repositories are used. X keyboard input drives human commands;
administrative eval inspects frame state and schedules a background refresh.
No product Lisp is loaded or replaced by this driver.
"""
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import tempfile
import time


def quoted(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


def main():
    editor, client = os.environ['LEM_BIN'], os.environ['LEMCLIENT_BIN']
    xvfb, xdotool, git = (shutil.which(name) for name in ('Xvfb', 'xdotool', 'git'))
    assert all((xvfb, xdotool, git)), 'Xvfb, xdotool and Git are required'
    deadline = time.monotonic() + 120
    with tempfile.TemporaryDirectory(prefix='lem-legit-frames-') as temporary:
        root = Path(temporary)
        env = dict(os.environ, SDL_VIDEODRIVER='x11', TERM='xterm-256color',
                   LEM_YATH_OPENROUTER_MODEL_REFRESH='0', LEM_YATH_CODEX_MODEL_REFRESH='0',
                   GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
        for key in ('XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME',
                    'XDG_STATE_HOME', 'XDG_DATA_HOME', 'LEM_HOME'):
            directory = root / key
            directory.mkdir(mode=0o700)
            env[key] = str(directory)
        command = [client, '--server-name', 'legit-frames']
        processes, logs = [], []

        def run(args, timeout=15):
            assert time.monotonic() < deadline, 'native frame acceptance deadline'
            result = subprocess.run(args, cwd=root, env=env, text=True,
                                    capture_output=True, timeout=timeout)
            assert result.returncode == 0, (args, result.stdout, result.stderr)
            return result.stdout.strip()

        def start(args, name, **kwargs):
            path = root / (name + '.log')
            logs.append(path)
            with path.open('w') as log:
                process = subprocess.Popen(args, cwd=root, env=env, stdout=log,
                                           stderr=subprocess.STDOUT, **kwargs)
            processes.append(process)
            return process

        def evaluate(form):
            return json.loads(run(command + ['--eval', form]))['primary']

        def in_frame(columns, form):
            return evaluate('(let ((old (lem:implementation)) (target '
                            '(find ' + str(columns) + ' lem-daemon::*daemon-connections* '
                            ':key (lambda (c) (let ((i (lem-daemon::connection-implementation c))) '
                            '(and i (lem-daemon::daemon-implementation-width i))))))) '
                            '(when target (unwind-protect (progn '
                            '(lem-daemon::activate-implementation (lem-daemon::connection-implementation target)) '
                            + form + ') (lem-daemon::activate-implementation old))))')

        def wait(predicate, description):
            until = min(deadline, time.monotonic() + 15)
            while time.monotonic() < until:
                if predicate():
                    return
                time.sleep(.04)
            raise AssertionError(description)

        def check(condition, description, detail=None):
            assert condition, (description, detail)
            print('PASS: ' + description, flush=True)

        def xdo(*args):
            return run([xdotool] + list(map(str, args)))

        def key(window, *keys):
            xdo('windowfocus', '--sync', window)
            xdo('key', '--clearmodifiers', *keys)

        def mx(window, columns, name):
            key(window, 'alt+x')
            wait(lambda: in_frame(columns, '(not (null (lem-core::frame-prompt-active-p (lem:current-frame))))') == 'T',
                 'M-x did not enter its SDL frame')
            xdo('type', '--clearmodifiers', '--delay', 1, name)
            key(window, 'Return')
            wait(lambda: in_frame(columns, '(null (lem-core::frame-prompt-active-p (lem:current-frame)))') == 'T',
                 'SDL command did not finish')

        def snapshot(columns):
            form = '''(with-output-to-string (out)
              (yason:encode
               (lem-agent:json-object
                "buffer" (lem:buffer-name (lem:current-buffer))
                "point" (lem:position-at-point (lem:current-point))
                "window" (sxhash (lem:current-window))
                "selection" (when (lem:buffer-mark-p (lem:current-buffer))
                  (vector (lem:position-at-point (lem:region-beginning (lem:current-buffer)))
                          (lem:position-at-point (lem:region-end (lem:current-buffer)))))
                "panes" (coerce
                  (loop for window in (lem-core::frame-floating-windows (lem:current-frame))
                        when (or (typep window 'lem/legit::peek-window)
                                 (typep window 'lem/legit::source-window))
                        collect (vector (type-of window) (lem:buffer-name (lem:window-buffer window))
                                        (uiop:native-namestring (lem:buffer-directory (lem:window-buffer window)))
                                        (lem:buffer-text (lem:window-buffer window))
                                        (lem:position-at-point (lem:window-point window))
                                        (lem:position-at-point (lem:window-view-point window)))) 'vector)) out))'''
            # TYPE-OF is encoded as text explicitly, not a Yason symbol.
            form = form.replace('(type-of window)', '(string (type-of window))')
            return json.loads(json.loads(in_frame(columns, form)))

        def repository(name):
            repo = root / name
            repo.mkdir()
            run([git, '-C', str(repo), 'init', '-b', name])
            run([git, '-C', str(repo), 'config', 'user.name', 'Native Frame Fixture'])
            run([git, '-C', str(repo), 'config', 'user.email', 'frames@example.invalid'])
            path = repo / (name + '.txt')
            path.write_text(name + ' original\nsecond\nthird\n')
            run([git, '-C', str(repo), 'add', '.'])
            run([git, '-C', str(repo), 'commit', '-m', name + ' base'])
            path.write_text(name + ' changed\nsecond\nthird\n')
            return repo, path

        try:
            left_repo, left_file = repository('left-project')
            right_repo, right_file = repository('right-project')
            readfd, writefd = os.pipe()
            start([xvfb, '-displayfd', str(writefd), '-screen', '0', '1800x1100x24',
                   '-nolisten', 'tcp', '-noreset'], 'xserver', pass_fds=[writefd])
            os.close(writefd)
            assert select.select([readfd], [], [], 10)[0], 'Xvfb did not start'
            env['DISPLAY'] = ':' + os.read(readfd, 100).decode().strip()
            os.close(readfd)
            daemon = start([editor, '--daemon=legit-frames'], 'daemon')
            run(command + ['--wait-for-server', '30', '--eval', 't'], timeout=35)
            check(evaluate('(lem-yath:boot-ok-p)') == 'T', 'configured daemon starts without a boot error')
            windows = []
            for index, path in enumerate((left_file, right_file)):
                process = start(command + ['-c', str(path)], 'sdl-' + str(index))
                window = xdo('search', '--sync', '--all', '--pid', process.pid,
                             '--name', 'Lem client').splitlines()[0]
                windows.append(window)
                xdo('windowmove', window, index * 900, 0)
                if index == 0:
                    geometry = dict(line.split('=', 1) for line in xdo('getwindowgeometry', '--shell', window).splitlines())
                    xdo('windowsize', window, int(geometry['WIDTH']) // 100 * 80, int(geometry['HEIGHT']))
                    wait(lambda: in_frame(80, 't') == 'T', 'first SDL resize was not routed')
            wait(lambda: in_frame(100, 't') == 'T', 'second SDL frame did not attach')
            check(len(set(windows)) == 2, 'two independent native SDL frames attach')
            mx(windows[0], 80, 'legit-status')
            wait(lambda: len(snapshot(80)['panes']) == 2, 'left status did not open both panes')
            left_before = snapshot(80)
            mx(windows[1], 100, 'legit-status')
            right = snapshot(100)
            left = snapshot(80)
            check(len(left['panes']) == 2 and len(right['panes']) == 2,
                  'both SDL frames retain their own Legit status and diff panes', {'left': left, 'right': right})
            check(left == left_before, 'opening the second repository preserves the first frame exactly',
                  {'before': left_before, 'after': left})
            check(any('left-project changed' in pane[3] for pane in left['panes'])
                  and any('right-project changed' in pane[3] for pane in right['panes']),
                  'each native frame displays its own repository diff')
            in_frame(80, '(defparameter lem-user::*native-foreign-pane* (lem/legit::peek-window))')
            refusal = in_frame(100, '(handler-case (progn (lem:delete-window lem-user::*native-foreign-pane*) nil) '
                               '(error (condition) (princ-to-string condition)))')
            check('Cannot delete a window outside the current frame' in refusal and snapshot(80) == left,
                  'a stale foreign pane reference is rejected before freeing its native backend view')
            # Administrative selection setup, followed by a queued product
            # refresh in A while B remains the active native client.
            in_frame(100, '(lem:set-cursor-mark (lem:current-point) '
                     '(lem:character-offset (lem:copy-point (lem:current-point) :temporary) 4))')
            right_before = snapshot(100)
            check(right_before['selection'] and right_before['selection'][0] != right_before['selection'][1],
                  'the peer has a nonempty selection before background refresh')
            in_frame(80, '(let ((owner (lem:implementation))) '
                     '(lem:send-event (lambda () '
                     '(lem-daemon::call-with-client-implementation owner '
                     '(lambda () (lem/legit:legit-refresh) (lem:redraw-display :force t))))))')
            wait(lambda: snapshot(80)['window'] != left['window'], 'background refresh did not replace its own panes')
            check(snapshot(100) == right_before,
                  'background refresh preserves the peer buffer, point, selection and panes exactly')
            mx(windows[0], 80, 'legit-quit')
            wait(lambda: not snapshot(80)['panes'], 'left pane closure did not finish')
            check(snapshot(100) == right_before, 'closing one native Legit view preserves the peer frame exactly')
            # A raw navigation key proves the next event remains in B's peek
            # mode and advances a meaningful status row, not A's source file.
            in_frame(100, '(lem:buffer-mark-cancel (lem:current-buffer))')
            point_before = snapshot(100)['point']
            key(windows[1], 'n')
            wait(lambda: snapshot(100)['point'] != point_before, 'peer next key did not advance its own status row')
            check(snapshot(80)['buffer'] == left_file.name
                  and in_frame(80, '(string= (lem:buffer-text (lem:current-buffer)) '
                               + quoted(left_file.read_text()) + ')') == 'T'
                  and left_file.read_text() == 'left-project changed\nsecond\nthird\n',
                  'the peer next typed key stays in its Legit context and leaves the closed frame source unchanged')
            mx(windows[1], 100, 'legit-refresh')
            key(windows[1], 's')
            wait(lambda: run([git, '-C', str(right_repo), 'diff', '--cached', '--name-only']) == right_file.name,
                 'native stage key did not affect the selected right repository')
            check(not run([git, '-C', str(left_repo), 'diff', '--cached', '--name-only']),
                  'native staging affects only the selected frame repository')
            mx(windows[0], 80, 'legit-status')
            wait(lambda: len(snapshot(80)['panes']) == 2, 'left view did not reopen')
            left_before = snapshot(80)
            in_frame(100, '(defparameter lem-user::*native-retired-pane-buffers* '
                     '(mapcar #\'cdr (lem/legit::pane-context-buffers (lem/legit::current-pane-context))))')
            # Kill the exact second SDL client while it still owns panes.
            right_process = processes[-1]
            right_process.kill()
            right_process.wait(timeout=10)
            wait(lambda: in_frame(100, 't') == 'NIL', 'killed SDL frame did not detach')
            wait(lambda: evaluate('(every #\'lem:deleted-buffer-p lem-user::*native-retired-pane-buffers*)') == 'T',
                 'detached native frame did not dispose its private view buffers')
            check(snapshot(80) == left_before, 'SDL client loss preserves the surviving Legit view exactly')
            point_before = snapshot(80)['point']
            key(windows[0], 'n')
            wait(lambda: snapshot(80)['point'] != point_before, 'survivor next key did not stay in its own peek mode')
            check(right_file.read_text() == 'right-project changed\nsecond\nthird\n'
                  and evaluate('(string= (lem:buffer-text (lem:get-file-buffer ' + quoted(right_file)
                               + ')) ' + quoted(right_file.read_text()) + ')') == 'T',
                  'peer failure reclaims private views while preserving shared source buffers and subsequent native navigation')
            run(command + ['--stop-server', '--force'])
            check(daemon.wait(timeout=15) == 0, 'focused native daemon shuts down cleanly')
        except BaseException:
            for path in logs:
                print(path.name + ':\n' + path.read_text(errors='replace')[-4000:], flush=True)
            raise
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=10)


if __name__ == '__main__':
    main()
