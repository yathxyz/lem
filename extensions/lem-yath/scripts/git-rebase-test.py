"""Run real Git rebases through a configured native Lisp daemon and client.

Python only drives the isolated acceptance fixtures. Git editor control and
rebase commands run in Lisp, without generated scripts or a terminal server.
"""

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time


def quoted(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


def eventually(predicate, description):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError(f'Timed out: {description}')


def check(condition, description):
    if not condition:
        raise AssertionError(description)
    print(f'PASS: {description}', flush=True)


def main():
    editor = os.environ['LEM_BIN']
    client = os.environ['LEMCLIENT_BIN']
    git = os.environ.get('GIT_BIN', shutil.which('git'))
    with tempfile.TemporaryDirectory(prefix='lem-native-rebase-') as temporary:
        root = Path(temporary)
        env = dict(os.environ)
        for variable in ['XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME',
                         'XDG_STATE_HOME', 'XDG_DATA_HOME', 'LEM_HOME']:
            path = root / variable
            path.mkdir(mode=0o700)
            env[variable] = str(path)
        env.update(TERM='xterm-256color', GIT_CONFIG_NOSYSTEM='1',
                   GIT_CONFIG_GLOBAL='/dev/null')
        name = 'native-rebase'
        command = [client, '--server-name', name]

        def client_run(*arguments, success=True):
            result = subprocess.run(command + list(arguments), env=env, cwd=root,
                                    capture_output=True, text=True, timeout=20)
            if success and result.returncode:
                raise AssertionError(result.stderr)
            return result

        def evaluate(form):
            return json.loads(client_run('--eval', form).stdout)['primary']

        def in_repo(repo, form):
            return evaluate('(uiop:with-current-directory (' + quoted(str(repo) + '/')
                            + ') (let ((vcs (lem/porcelain/git::git-project-p))) '
                            + form + '))')

        def git_run(repo, *arguments):
            return subprocess.run([git, '-C', str(repo), *arguments], env=env,
                                  check=True, capture_output=True, text=True,
                                  timeout=15).stdout.strip()

        def commit(repo, message, text, filename='document.txt'):
            (repo / filename).write_text(text)
            git_run(repo, 'add', filename)
            git_run(repo, 'commit', '-m', message)

        def fixture(name):
            repo = root / name
            repo.mkdir()
            git_run(repo, 'init', '-b', 'main')
            git_run(repo, 'config', 'user.name', 'Native Rebase Test')
            git_run(repo, 'config', 'user.email', 'native-rebase@example.invalid')
            commit(repo, 'base', 'base\n')
            commit(repo, 'second', 'base\nsecond\n')
            commit(repo, 'third', 'base\nsecond\nthird\n')
            return repo

        def metadata(repo, name):
            return Path(git_run(repo, 'rev-parse', '--path-format=absolute',
                                '--git-path', name))

        def pending(path):
            return evaluate('(let ((buffer (lem:get-file-buffer ' + quoted(path)
                            + '))) (and buffer '
                            '(not (null (lem-daemon:request-buffer-list buffer)))))') == 'T'

        def replace_buffer(path, text):
            evaluate('(let ((buffer (lem:get-file-buffer ' + quoted(path)
                     + '))) (lem:erase-buffer buffer) '
                     '(lem:insert-string (lem:buffer-point buffer) ' + quoted(text) + '))')

        def finish(path, command='lem-daemon:daemon-edit-save-and-done'):
            evaluate('(progn (lem:switch-to-buffer (lem:get-file-buffer ' + quoted(path)
                     + ')) (' + command + '))')

        def begin(repo, revision='HEAD~1'):
            todo = metadata(repo, 'rebase-merge/git-rebase-todo')
            commit_hash = git_run(repo, 'rev-parse', revision)
            in_repo(repo, '(lem/porcelain:rebase-interactively vcs :from '
                    + quoted(commit_hash) + ')')
            eventually(lambda: pending(todo), 'native sequence-editor request')
            return todo

        def completed(repo):
            return not metadata(repo, 'rebase-merge').exists()

        def git_process_id(repo):
            return int(in_repo(repo, '(uiop:process-info-pid '
                               '(lem-yath::legit-rebase-session-process '
                               '(gethash vcs lem-yath::*legit-rebase-sessions*)))'))

        def reword(repo, todo, message, direct=False):
            text = todo.read_text().replace('pick ', 'reword ', 1)
            replace_buffer(todo, text)
            if direct:
                finish(todo)
            else:
                in_repo(repo, '(lem/porcelain:rebase-continue vcs)')
            message_path = metadata(repo, 'COMMIT_EDITMSG')
            eventually(lambda: pending(message_path), 'native reword editor callback')
            replace_buffer(message_path, message + '\n')
            finish(message_path, 'lem-yath::lem-yath-legit-commit-continue')
            eventually(lambda: completed(repo), 'completed reword')

        daemon = None
        try:
            with (root / 'daemon.log').open('w') as log:
                daemon = subprocess.Popen([editor, f'--daemon={name}'], env=env,
                                          cwd=root, stdout=log, stderr=subprocess.STDOUT,
                                          start_new_session=True)
                client_run('--wait-for-server', '30', '--eval',
                           '(assert (null lem-user::*lem-yath-boot-error*))')
                repo = fixture("repo ' $(touch escaped);safe")
                todo = begin(repo)
                text = todo.read_text().replace('pick ', 'reword ', 1)
                first, remainder = text.split('\n', 1)
                replace_buffer(todo, first + '\n' + remainder.replace('pick ', 'fixup ', 1))
                in_repo(repo, '(lem/porcelain:rebase-continue vcs)')
                message_path = metadata(repo, 'COMMIT_EDITMSG')
                eventually(lambda: pending(message_path), 'reword/fixup editor callback')
                replace_buffer(message_path, 'native reword and fixup\n')
                finish(message_path, 'lem-yath::lem-yath-legit-commit-continue')
                eventually(lambda: completed(repo), 'completed reword/fixup')
                check(git_run(repo, 'rev-list', '--count', 'HEAD') == '2'
                      and git_run(repo, 'log', '-1', '--format=%s') == 'native reword and fixup'
                      and git_run(repo, 'status', '--porcelain') == '',
                      'native todo and commit callbacks complete reword/fixup cleanly')

                reword(repo, begin(repo, 'HEAD'), 'repeated native reword', direct=True)
                reword(repo, begin(repo, 'HEAD'), 'third native reword', direct=True)
                check(git_run(repo, 'log', '-1', '--format=%s') == 'third native reword',
                      'retained native todo buffers allow consecutive rebases')
                check(not (root / 'escaped').exists(),
                      'repository metacharacters remain literal path data')

                original = git_run(repo, 'rev-parse', 'HEAD')
                todo = begin(repo, 'HEAD')
                in_repo(repo, '(lem/porcelain:rebase-abort vcs)')
                eventually(lambda: completed(repo), 'aborted sequence editor')
                check(git_run(repo, 'rev-parse', 'HEAD') == original,
                      'aborting native sequence editing preserves the original history')

                todo = begin(repo, 'HEAD')
                replace_buffer(todo, todo.read_text().replace('pick ', 'edit ', 1))
                finish(todo)
                eventually(lambda: metadata(repo, 'rebase-merge/stopped-sha').exists(),
                           'Git edit stop')
                (repo / 'document.txt').write_text('base\nsecond\nthird\namended\n')
                git_run(repo, 'add', 'document.txt')
                in_repo(repo, '(lem-yath::release-finished-legit-rebase-session vcs :wait t) '
                        '(lem-yath::show-legit-amend-buffer "native edit amend" (uiop:getcwd))')
                evaluate('(lem-yath::legit-amend-continue)')
                in_repo(repo, '(lem/porcelain:rebase-continue vcs)')
                eventually(lambda: completed(repo), 'continued edit/amend')
                check(git_run(repo, 'log', '-1', '--format=%s') == 'native edit amend'
                      and 'amended' in (repo / 'document.txt').read_text(),
                      'native edit stops retain the configured amend workflow')

                linked = root / "linked ' $(touch linked-escaped);safe"
                git_run(repo, 'worktree', 'add', '-b', 'linked', str(linked))
                todo = begin(linked, 'HEAD')
                check(in_repo(linked, '(uiop:pathname-equal (lem:buffer-directory (lem:get-file-buffer '
                              + quoted(todo) + ')) (uiop:getcwd))') == 'T',
                      'linked-worktree todo buffers retain the selected worktree directory')
                reword(linked, todo, 'linked native reword')
                check(git_run(linked, 'log', '-1', '--format=%s') == 'linked native reword'
                      and git_run(repo, 'log', '-1', '--format=%s') == 'native edit amend',
                      'native rebase resolves linked-worktree metadata independently')

                conflict = fixture('conflict')
                todo = begin(conflict)
                lines = todo.read_text().splitlines(True)
                lines[0], lines[1] = lines[1], lines[0]
                replace_buffer(todo, ''.join(lines))
                finish(todo)
                eventually(lambda: git_run(conflict, 'diff', '--name-only', '--diff-filter=U'),
                           'reordered commit conflict')
                (conflict / 'document.txt').write_text('base\nsecond\nthird\n')
                git_run(conflict, 'add', 'document.txt')
                in_repo(conflict, '(lem-yath::release-finished-legit-rebase-session vcs :wait t) '
                        '(lem/porcelain:rebase-continue vcs)')
                message_path = metadata(conflict, 'COMMIT_EDITMSG')
                eventually(lambda: pending(message_path), 'continue after conflict editor callback')
                check(evaluate('(+ 20 22)') == '42',
                      'conflict continuation leaves the editor responsive during Git callbacks')
                finish(message_path, 'lem-yath::lem-yath-legit-commit-continue')
                eventually(lambda: git_run(conflict, 'diff', '--name-only', '--diff-filter=U'),
                           'second reordered commit conflict')
                in_repo(conflict, '(lem-yath::release-finished-legit-rebase-session vcs :wait t) '
                        '(lem/porcelain:rebase-skip vcs)')
                eventually(lambda: completed(conflict), 'skipped conflicting commit')
                check(git_run(conflict, 'status', '--porcelain') == '',
                      'native asynchronous skip completes a conflicted rebase cleanly')

                todo = begin(linked, 'HEAD')
                git_pid = git_process_id(linked)
                child = git_pid
                # This fixture has no hooks: Git's only descendant is its
                # sequence editor (possibly beneath Git's command shell).
                while True:
                    children = Path(f'/proc/{child}/task/{child}/children').read_text().split()
                    if not children:
                        break
                    check(len(children) == 1, 'sequence editor has one isolated child process')
                    child = int(children[0])
                check(child != git_pid, 'native sequence editor is a separate Lisp process')
                os.kill(child, signal.SIGKILL)
                eventually(lambda: completed(linked) and not pending(todo),
                           'killed sequence editor releases Git')
                check(evaluate('(+ 20 22)') == '42',
                      'a killed native sequence editor aborts Git and leaves Lem usable')

                todo = begin(linked, 'HEAD')
                git_pid = git_process_id(linked)
                client_run('--stop-server', '--force')
                daemon.wait(timeout=15)
                eventually(lambda: not Path(f'/proc/{git_pid}').exists(),
                           'Git reaped after daemon stop')
                check(completed(linked),
                      'stopping the daemon releases a pending native sequence editor')
                check(not list(Path(env['LEM_HOME']).rglob('*rebase*editor*.sh')),
                      'rebase requires no generated shell editor')
        except Exception:
            print((root / 'daemon.log').read_text(), flush=True)
            raise
        finally:
            if daemon and daemon.poll() is None:
                client_run('--stop-server', '--force', success=False)
                try:
                    daemon.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(daemon.pid, signal.SIGTERM)
                    daemon.wait(timeout=5)


if __name__ == '__main__':
    main()
