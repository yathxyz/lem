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
import sys
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
        last_jobs = {}

        def client_run(*arguments, success=True):
            result = subprocess.run(command + list(arguments), env=env, cwd=root,
                                    capture_output=True, text=True,
                                    timeout=35 if '--wait-for-server' in arguments else 20)
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

        def start_rebase(repo, form):
            identifier = json.loads(in_repo(repo, '(progn ' + form +
                ' (lem-toolkit/jobs:job-id (lem-yath::legit-rebase-session-job '
                '(gethash vcs lem-yath::*legit-rebase-sessions*))))'))
            last_jobs[str(repo)] = identifier
            return identifier

        def job_form(identifier, body):
            return ('(let ((job (lem-toolkit/jobs:find-job ' + quoted(identifier)
                    + ' (lem-yath::ensure-toolkit-job-manager)))) ' + body + ')')

        def job_done(identifier):
            return evaluate(job_form(identifier, '(not (null (lem-toolkit/jobs:job-result job)))')) == 'T'

        def wait_step(repo):
            eventually(lambda: in_repo(repo, '(notany (lambda (job) '
                                       '(null (lem-toolkit/jobs:job-result job))) '
                                       '(lem-yath::legit-rebase-jobs))') == 'T',
                       'managed Git job completes cleanup')

        def begin(repo, revision='HEAD~1'):
            wait_step(repo)
            todo = metadata(repo, 'rebase-merge/git-rebase-todo')
            commit_hash = git_run(repo, 'rev-parse', revision)
            start_rebase(repo, '(lem/porcelain:rebase-interactively vcs :from '
                         + quoted(commit_hash) + ')')
            eventually(lambda: pending(todo), 'native sequence-editor request')
            return todo

        def completed(repo):
            return not metadata(repo, 'rebase-merge').exists()

        def git_process_id(repo):
            # PID discovery belongs only to this external Linux failure fixture.
            # The production job API/journal deliberately stores no signal target.
            queue = [daemon.pid]
            seen = set()
            while queue:
                parent = queue.pop()
                if parent in seen:
                    continue
                seen.add(parent)
                # The manager launches from a controller thread. Linux records
                # those children on that thread, not on the process's main TID.
                children = set()
                for child_list in Path(f'/proc/{parent}/task').glob('*/children'):
                    try:
                        children.update(map(int, child_list.read_text().split()))
                    except FileNotFoundError:
                        pass
                for child in children:
                    try:
                        if (Path(f'/proc/{child}/comm').read_text().strip() == 'git'
                                and Path(f'/proc/{child}/cwd').resolve() == repo.resolve()):
                            return child
                    except FileNotFoundError:
                        continue
                    queue.append(child)
            raise AssertionError('No owned Git process for fixture repository')

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

                delayed = fixture('delayed-hook')
                hook_started = root / 'hook-started'
                hook_release = root / 'hook-release'
                hook = metadata(delayed, 'hooks/pre-rebase')
                hook.write_text('#!' + sys.executable + '\n'
                                'from pathlib import Path\nimport time\n'
                                f'Path({str(hook_started)!r}).write_text("started")\n'
                                f'while not Path({str(hook_release)!r}).exists(): time.sleep(0.05)\n')
                hook.chmod(0o700)
                delayed_hash = git_run(delayed, 'rev-parse', 'HEAD')
                # Invoke the actual upstream command while no todo exists. Its
                # fourth-value protocol must leave opening to the native client.
                started = time.monotonic()
                delayed_job = start_rebase(delayed,
                    '(let ((buffer (lem:make-buffer "rebase-command-fixture"))) '
                    '(lem:switch-to-buffer buffer) '
                    '(setf (lem:buffer-directory buffer) (uiop:getcwd)) '
                    '(lem:insert-string (lem:buffer-point buffer) "commit" '
                    ':commit-hash ' + quoted(delayed_hash) + ') '
                    '(lem:buffer-start (lem:buffer-point buffer)) '
                    '(lem/legit::legit-rebase-interactive))')
                check(time.monotonic() - started < 2,
                      'interactive rebase returns while a pre-rebase hook is blocked')
                eventually(hook_started.exists, 'pre-rebase hook started')
                delayed_todo = metadata(delayed, 'rebase-merge/git-rebase-todo')
                check(not delayed_todo.exists()
                      and evaluate('(null (lem:get-file-buffer ' + quoted(delayed_todo) + '))') == 'T'
                      and evaluate('(+ 20 22)') == '42',
                      'delayed Git startup neither blocks the editor nor pre-opens an empty todo')
                evaluate(job_form(delayed_job,
                    '(let ((buffer (lem-toolkit/jobs-ui:show-job job))) (lem:delete-buffer buffer))'))
                check(not job_done(delayed_job) and not hook_release.exists(),
                      'closing a rebase job inspection buffer leaves Git running')
                evaluate('(progn (lem:switch-to-buffer (lem:get-buffer "rebase-command-fixture")) '
                         '(lem/legit::show-legit-status) (lem/legit::legit-quit))')
                check(not job_done(delayed_job) and not hook_release.exists(),
                      'closing the Legit status view leaves its managed rebase running')
                hook_release.write_text('continue')
                eventually(lambda: pending(delayed_todo), 'delayed native todo request')
                evaluate('(lem:delete-buffer (lem:get-file-buffer ' + quoted(delayed_todo) + '))')
                eventually(lambda: job_done(delayed_job), 'killed request buffer ends Git')
                check(evaluate(job_form(delayed_job,
                    '(let ((result (lem-toolkit/jobs:job-result job))) '
                    '(and (equal "exited" (gethash "state" result)) '
                    '(not (eql 0 (gethash "exit-code" result))) '
                    '(not (lem-yath::legit-rebase-job-success-p result))))')) == 'T',
                      'killing an editable todo records explicit unsuccessful Git exit')
                hook.write_text('#!' + sys.executable + '\n'
                                'import sys\nsys.stderr.write("discarded-prefix\\n" + "x" * 70000 '
                                '+ "\\nfixture hook refused rebase\\n")\n'
                                'sys.exit(73)\n')
                wait_step(delayed)
                refused_job = start_rebase(delayed,
                    '(lem/porcelain:rebase-interactively vcs :from ' + quoted(delayed_hash) + ')')
                eventually(lambda: job_done(refused_job), 'failed pre-rebase hook result')
                check(evaluate(job_form(refused_job,
                    '(let ((result (lem-toolkit/jobs:job-result job))) '
                    '(and (not (lem-yath::legit-rebase-job-success-p result)) '
                    '(<= (gethash "stderr-retained-bytes" result) 65536) '
                    '(> (gethash "stderr-bytes" result) 65536) '
                    '(not (search "discarded-prefix" (gethash "stderr" result))) '
                    '(search "fixture hook refused rebase" (gethash "stderr" result))))')) != 'NIL',
                      'Git startup failure retains bounded diagnostic output in its job')

                first_repo = fixture('concurrent-first')
                second_repo = fixture('concurrent-second')
                first_todo = begin(first_repo, 'HEAD')
                second_todo = begin(second_repo, 'HEAD')
                finish(second_todo, 'lem/legit::rebase-continue')
                eventually(lambda: completed(second_repo) and not pending(second_todo),
                           'selected concurrent rebase continuation')
                check(pending(first_todo) and not job_done(last_jobs[str(first_repo)]),
                      'continuing one repository preserves another repository\'s pending todo and job')
                second_todo = begin(second_repo, 'HEAD')
                finish(second_todo, 'lem/legit::rebase-abort')
                eventually(lambda: completed(second_repo) and not pending(second_todo),
                           'selected concurrent rebase abort')
                check(pending(first_todo) and not job_done(last_jobs[str(first_repo)]),
                      'aborting one repository preserves another repository\'s pending todo and job')
                in_repo(first_repo, '(lem/porcelain:rebase-abort vcs)')
                eventually(lambda: completed(first_repo), 'remaining concurrent rebase abort')

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
                wait_step(repo)
                check(evaluate(job_form(last_jobs[str(repo)],
                    '(lem-yath::legit-rebase-job-success-p (lem-toolkit/jobs:job-result job))')) == 'T',
                      'managed rebase success requires exited state and exit code zero')

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
                wait_step(repo)
                in_repo(repo, '(lem-yath::show-legit-amend-buffer "native edit amend" (uiop:getcwd))')
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
                wait_step(conflict)
                in_repo(conflict, '(lem/porcelain:rebase-continue vcs)')
                message_path = metadata(conflict, 'COMMIT_EDITMSG')
                eventually(lambda: pending(message_path), 'continue after conflict editor callback')
                check(evaluate('(+ 20 22)') == '42',
                      'conflict continuation leaves the editor responsive during Git callbacks')
                finish(message_path, 'lem-yath::lem-yath-legit-commit-continue')
                eventually(lambda: git_run(conflict, 'diff', '--name-only', '--diff-filter=U'),
                           'second reordered commit conflict')
                wait_step(conflict)
                in_repo(conflict, '(lem/porcelain:rebase-skip vcs)')
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
                crashed_job = last_jobs[str(linked)]
                original_head = git_run(linked, 'rev-parse', 'HEAD')
                check(evaluate('(+ 20 22)') == '42' and not job_done(crashed_job),
                      'ordinary client disconnection leaves a pending rebase job running')
                os.kill(daemon.pid, signal.SIGKILL)
                daemon.wait(timeout=15)
                def git_not_running():
                    try:
                        return Path(f'/proc/{git_pid}/stat').read_text().split(') ', 1)[1][0] == 'Z'
                    except FileNotFoundError:
                        return True
                eventually(git_not_running, 'owned Git stops after daemon SIGKILL')
                daemon = subprocess.Popen([editor, f'--daemon={name}'], env=env,
                                          cwd=root, stdout=log, stderr=subprocess.STDOUT,
                                          start_new_session=True)
                client_run('--wait-for-server', '30', '--eval',
                           '(assert (null lem-user::*lem-yath-boot-error*))')
                check(evaluate(job_form(crashed_job,
                    '(equal "interrupted" (gethash "state" (lem-toolkit/jobs:job-result job)))')) == 'T'
                    and git_run(linked, 'rev-parse', 'HEAD') == original_head
                    and not pending(todo),
                      'daemon restart retains interrupted rebase intent without replay or implicit approval')
                if not completed(linked):
                    in_repo(linked, '(lem/porcelain:rebase-abort vcs)')
                    wait_step(linked)
                    eventually(lambda: completed(linked), 'explicit recovery abort')
                client_run('--stop-server', '--force')
                check(daemon.wait(timeout=15) == 0,
                      'deliberate shutdown closes the managed-job daemon cleanly')
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
