#!/usr/bin/env python3
"""Bounded standalone journal inspection; local synthetic records, no editor/user init."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--sbcl', default='sbcl')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='lem-job-cli-') as temporary:
        directory = Path(temporary)
        for number in range(1, 68):
            identity = f'{number:032x}'
            record = {'version': 1, 'id': identity, 'owner': 'cli-fixture',
                      'argv': ['/fixture/never-executed'], 'directory': '/', 'state': 'exited',
                      'reason': None, 'exit-code': 0, 'started': 1, 'finished': 2,
                      'daemon-failure-policy': 'terminate-on-disconnect; never-replay',
                      'timeout-ms': 1000, 'output-limit': 1, 'stdout-hex': '', 'stderr-hex': '',
                      'stdout-bytes': 0, 'stderr-bytes': 0, 'stdout-retained-bytes': 0,
                      'stderr-retained-bytes': 0, 'journal-error': None}
            path = directory / f'{identity}.json'
            path.write_text(json.dumps(record))
            path.chmod(0o600)
        (directory / 'manual-notes.json').write_text('unmanaged')
        command = [args.sbcl, '--noinform', '--disable-debugger', '--script',
                   str(ROOT / 'scripts/lem-recovery.lisp'), '--jobs', str(directory)]

        def run(*options, code=0):
            result = subprocess.run(command + list(options), cwd=directory, env=os.environ,
                                    capture_output=True, text=True, timeout=45)
            assert result.returncode == code, result.stderr
            assert f'Recovery source lem-daemon/recovery-cli: {ROOT}/' in result.stderr
            return json.loads(result.stdout) if result.stdout else None

        first = run()
        assert len(first['records']) == 64 and not first['errors']
        assert first['page'] == {'total': 67, 'ignored-names': 1,
                                 'reserved-without-journal': 0, 'next-after': f'{64:032x}', 'truncated': True}
        second = run('--after', first['page']['next-after'], '--limit', '4')
        assert [record['id'] for record in second['records']] == [f'{n:032x}' for n in range(65, 68)]
        assert second['page']['next-after'] is None and second['page']['truncated'] is False
        print('PASS: default64 page and explicit cursor expose all67 records without editor initialization')
        (directory / f'{1:032x}.json').write_text('{malformed-private-text')
        malformed = run('--limit', '2', code=1)
        assert len(malformed['records']) == 1 and len(malformed['errors']) == 1
        assert 'malformed-private-text' not in json.dumps(malformed)
        assert malformed['page']['next-after'] == f'{2:032x}'
        print('PASS: malformed records occupy their page position and emit bounded content-free diagnostics')
        for options in [('--limit', '0'), ('--limit', '65'), ('--after', '../escape'),
                        ('--limit', '2', '--limit', '3'), ('--after',)]:
            run(*options, code=2)
        print('PASS: invalid, duplicate and incomplete pagination options are refused')


if __name__ == '__main__':
    main()
