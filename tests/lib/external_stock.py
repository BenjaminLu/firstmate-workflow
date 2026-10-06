"""Stock external launch integration; no model, board, browser or network."""
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
root = Path(sys.argv[1])
sys.path.insert(0, str(root / 'bin/lib'))
from fm_lifeline import Doorbell, ProcessExit, start
from fm_onboard import approve, infer
from external_registry import write_registry


def run(argv, env, **kwargs):
    result = subprocess.run(argv, env=env, text=True, capture_output=True,
                            stdin=subprocess.DEVNULL, timeout=120, **kwargs)
    if result.returncode:
        raise AssertionError(f'{argv}: {result.returncode}\n{result.stdout}\n{result.stderr}')
    return result.stdout.strip()


def scenario(stop_owner=False, public_title=None):
    with tempfile.TemporaryDirectory(prefix='external-stock-') as tmp:
        scratch = Path(tmp)
        engine = scratch / 'engine'
        engine.mkdir()
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(('FM_', 'HERDR_', 'GIT_')) and k != 'GH_REPO'}
        env.update(FM_HOME=str(scratch / 'private'), FM_GITHUB_URL=str(scratch / 'remotes'),
                   FM_ROOT=str(engine), FM_PROJECT='app', FM_SESSION_PID=str(os.getpid()),
                   FM_GIT_NAME='Fixture', FM_GIT_EMAIL='fixture@example.invalid',
                   FM_HOST='none', HERDR_ENV='0', FM_MIRROR_INTERVAL='1',
                   GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
                   PYTHONDONTWRITEBYTECODE='1')
        owner = None
        for directory in ('bin', 'skills', '.githooks'):
            shutil.copytree(root / directory, engine / directory,
                            ignore=shutil.ignore_patterns('__pycache__'))
        shutil.copy(root / '.gitignore', engine / '.gitignore')
        # This adapter blocks on a FIFO, not a pid/file polling loop. The
        # launcher and lifeline remain the shipped implementations.
        adapter = engine / 'bin/adapters/mock.sh'
        adapter.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
with open(os.environ['FM_TEST_READY'], 'w') as ready:
    ready.write(json.dumps(dict(pid=os.getpid(), run=os.environ['FM_RUN_DIR']))+'\\n')
with open(os.environ['FM_TEST_RELEASE']) as release:
    release.readline()
tree=Path(sys.argv[3])
(tree/'implementation').write_text('target work\\n')
with open(sys.argv[4], 'a') as log:
    log.write('WORKER_COMPLETE:T-051\\n')
''')
        adapter.chmod(0o755)
        write_registry(engine)
        run(['git', 'init', '-q', '-b', 'main', str(engine)], env)
        run(['git', '-C', str(engine), 'add', 'bin', 'skills', '.githooks', '.gitignore', 'config.yaml'], env)
        run(['git', '-C', str(engine), '-c', 'user.name=Fixture', '-c',
             'user.email=fixture@example.invalid', 'commit', '-qm', 'engine'], env)
        remote = scratch / 'remotes/owner/app.git'
        remote.parent.mkdir(parents=True)
        run(['git', 'init', '-q', '--bare', '-b', 'trunk', str(remote)], env)
        seed = scratch / 'seed'
        run(['git', 'clone', '-q', str(remote), str(seed)], env)
        (seed / 'base-content').write_text('base\n')
        run(['git', '-C', str(seed), 'add', 'base-content'], env)
        run(['git', '-C', str(seed), '-c', 'user.name=Fixture', '-c',
             'user.email=fixture@example.invalid', 'commit', '-qm', 'base'], env)
        run(['git', '-C', str(seed), 'push', '-q', 'origin', 'trunk'], env)
        home = scratch / 'private/projects/app'
        home.mkdir(parents=True)
        evidence = dict(repository='owner/app', base='trunk', source='github', pulls=[], commits=[],
                        protection={'status': 'unknown'}, repository_info={
                            'allow_merge_commit': True, 'allow_squash_merge': False,
                            'allow_rebase_merge': False, 'delete_branch_on_merge': False})
        approve(home, evidence, infer(evidence), dict(confirmed=True, policy_confirmed=True,
                captain='captain', intent='Private acceptance sentinel', product='Private product sentinel',
                required_checks=['ci'], contract={'check': 'true'}, post='local'))
        (home / 'tasks').mkdir(exist_ok=True)
        (home / 'tasks/T-051.json').write_text(json.dumps(dict(id='T-051',
            title='Private title sentinel', depends_on=[], scope=['implementation'],
            acceptance=['Private acceptance sentinel'])))
        if public_title is not None:
            spec_path = home / 'tasks/T-051.json'
            spec = json.loads(spec_path.read_text())
            spec.update(public_title=public_title, public_summary='The fixture widget uses blue.')
            spec_path.write_text(json.dumps(spec))
        (home / 'design.md').write_text('Private design sentinel\n')
        state = home / 'state'
        # Shared helper resolves the external Store layout under private state.
        # Dependency: tests/lib/spec-preflight.sh
        run(['bash', '-c',
             '. "$1/tests/lib/spec-preflight.sh"; ROOT="$1"; '
             'seed_spec_preflight "$2" T-051 "$3/tasks/T-051.json" app "$3/state"',
             'seed-preflight', str(root), str(engine), str(home)], env)
        (state / 'events.jsonl').write_text(json.dumps(dict(type='greenlit', actor='captain',
            project='app', ts='2026-10-02T00:00:00Z', data={}))+'\n')
        gh = scratch / 'gh'
        gh.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
with open(os.environ['FM_TEST_GH_LOG'],'a') as log: log.write(json.dumps(sys.argv[1:])+'\\n')
if sys.argv[1:3]==['pr','create']: print('https://example.invalid/owner/app/pull/9')
elif sys.argv[1:3]==['pr','list']: print('null')
else: sys.exit(1)
''')
        gh.chmod(0o755)
        env.update(FM_GH=str(gh), FM_TEST_GH_LOG=str(scratch / 'gh.jsonl'))
        # Observe the real receipt's publication boundary, then delegate to mv.
        # A direct write to the public path leaves no observation and fails.
        observer = scratch / 'observer'
        observer.mkdir()
        real_mv = shutil.which('mv', path=env['PATH'])
        assert real_mv, 'fixture needs mv'
        receipt_observed = scratch / 'receipt-observed.json'
        env.update(FM_TEST_REAL_MV=real_mv,
                   FM_TEST_RECEIPT=str(state / 'dispatch/T-051.json'),
                   FM_TEST_RECEIPT_OBSERVED=str(receipt_observed))
        (observer / 'mv').write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
destination = Path(os.environ['FM_TEST_RECEIPT'])
if len(sys.argv) == 3 and Path(sys.argv[2]) == destination:
    source = Path(sys.argv[1])
    assert source != destination and source.parent == destination.parent
    assert not destination.exists(), 'receipt visible before rename'
    payload = json.loads(source.read_text())
    assert set(payload) == {'project', 'task', 'owner', 'keeper'}
    Path(os.environ['FM_TEST_RECEIPT_OBSERVED']).write_text(json.dumps(payload))
os.execv(os.environ['FM_TEST_REAL_MV'], [os.environ['FM_TEST_REAL_MV'], *sys.argv[1:]])
""")
        (observer / 'mv').chmod(0o755)
        env['PATH'] = str(observer) + os.pathsep + env['PATH']
        ready = scratch / 'ready.fifo'
        release = scratch / 'release.fifo'
        for fifo in (ready, release): os.mkfifo(fifo)
        env.update(FM_TEST_READY=str(ready), FM_TEST_RELEASE=str(release))
        ready_fd = os.open(ready, os.O_RDWR | os.O_NONBLOCK)
        release_fd = os.open(release, os.O_RDWR | os.O_NONBLOCK)
        # A dedicated owner also bounds failed assertions before a receipt is
        # available: ending it cannot leave a worker using a removed fixture.
        owner = start([sys.executable, '-c', 'import sys; sys.stdin.read()'], owner=os.getpid(),
                      stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                      name='external-stock-owner')
        env['FM_SESSION_PID'] = str(owner.pid)
        # Doorbell routing is resolved from this exact project context.
        previous = dict(os.environ)
        os.environ.clear(); os.environ.update(env)
        worker_exit = None
        try:
            with Doorbell(engine) as bell:
                command = [str(engine / 'bin/fm-dispatch.sh'), '--repo', str(engine),
                           '--project', 'app', '--task', 'T-051']
                # The dispatcher itself runs under a keeper, as stock session
                # dispatch does. Its exit must not end the session-owned worker.
                def dispatch():
                    log_path = scratch / 'dispatcher.log'
                    with log_path.open('w') as log:
                        process = start(command, owner=int(env['FM_SESSION_PID']),
                                        env=env, stdout=log, stderr=log)
                        try:
                            status = process.wait(timeout=120)
                        finally:
                            if process.poll() is None:
                                process.terminate(); process.wait(timeout=15)
                    output = log_path.read_text()
                    assert status == 0, output
                    return output
                out = dispatch()
                assert 'T-051' in out, out
                launch = json.loads((state / 'dispatch/T-051.json').read_text())
                assert json.loads(receipt_observed.read_text()) == launch, 'receipt was not renamed whole'
                assert launch['project'] == 'app' and launch['task'] == 'T-051', launch
                assert launch['owner'] == int(env['FM_SESSION_PID']), launch
                assert set(launch) == {'project', 'task', 'owner', 'keeper'}, launch
                assert isinstance(launch['keeper'], int) and launch['keeper'] > 0, launch
                assert list((state / 'dispatch').glob('T-051.*.json')) == [], 'partial receipt left behind'
                worker_exit = ProcessExit(launch['keeper'])
                assert select.select([ready_fd], [], [], 90)[0], (state / 'dispatch/T-051.log').read_text()
                receipt = json.loads(os.read(ready_fd, 65536))
                run_dir = Path(receipt['run'])
                assert run_dir.is_relative_to(state / 'runs'), run_dir
                identity = json.loads((run_dir / 'identity.json').read_text())
                assert (identity['project'], identity['task'], identity['role']) == ('app', 'T-051', 'worker')
                assert not select.select([worker_exit], [], [], 0)[0], 'worker died with dispatcher'
                duplicate = dispatch()
                assert 'T-051' not in duplicate.splitlines(), duplicate
                assert len(list((state / 'runs').glob('*/identity.json'))) == 1, 'duplicate worker allocated'
                assert json.loads((state / 'dispatch/T-051.json').read_text()) == launch, 'duplicate replaced receipt'
                cleanup = subprocess.run([str(engine / 'bin/fm-cleanup.sh'), '--repo', str(engine),
                    '--project', 'app', '--task', 'T-051', '--force'], env=env,
                    capture_output=True, text=True, timeout=30)
                assert cleanup.returncode == 65, cleanup.stdout + cleanup.stderr
                assert 'task has a live worker; worktree retained' in cleanup.stderr, cleanup.stderr
                assert (home / 'worktrees/T-051/base-content').exists()
                if stop_owner:
                    owner.stdin.close()
                    owner.wait(timeout=15)
                    assert select.select([worker_exit], [], [], 30)[0], 'worker outlived its owner'
                    assert (home / 'worktrees/T-051/base-content').read_text() == 'base\n'
                    assert not (home / 'worktrees/T-051/implementation').exists()
                    return
                os.write(release_fd, b'complete\n')
                assert bell.wait(120), 'worker completion was not pushed'
                assert select.select([worker_exit], [], [], 30)[0], 'worker did not finish'
                events = [json.loads(line) for line in (state / 'events.jsonl').read_text().splitlines()]
                assert events[-1]['type'] == 'agent_finished', events[-1]
                assert events[-1]['actor'] == identity['actor']
                target = home / 'worktrees/T-051'
                assert run(['git', '-C', str(remote), 'show', 't-051-work:implementation'], env) == 'target work'
                paths = run(['git', '-C', str(remote), 'ls-tree', '-r', '--name-only', 't-051-work'], env)
                assert paths.splitlines() == ['base-content', 'implementation'], paths
                message = run(['git', '-C', str(target), 'log', '-1', '--format=%s'], env)
                if public_title is None:
                    assert message == 'T-051: project work', message
                else:
                    assert message == 'T-051: ' + public_title, message
                calls = [json.loads(line) for line in (scratch / 'gh.jsonl').read_text().splitlines()]
                create = next(call for call in calls if call[:2] == ['pr', 'create'])
                assert create[create.index('--repo')+1] == 'owner/app'
                assert create[create.index('--base')+1] == 'trunk'
                assert 'Private' not in json.dumps(create), create
                assert not (engine / 'state/worktrees/T-051').exists()
                assert not (engine / 'state/runs').exists()
                if public_title is not None:
                    assert create[create.index('--title')+1] == 'T-051: ' + public_title
                    assert create[create.index('--body')+1] == (
                        'The fixture widget uses blue.\n\n'
                        'Captain acceptance and evidence are retained privately.')
                    assert run(['git', '-C', str(engine), 'status', '--porcelain'], env) == ''
                    found = subprocess.run(['git', '-C', str(engine), 'grep', '-F', public_title],
                                           env=env, text=True, capture_output=True)
                    assert found.returncode == 1, found.stdout + found.stderr
                    # Public prose may persist only in private runtime records,
                    # the external commit objects and the PR stub's argv record.
                    for path in scratch.rglob('*'):
                        if not path.is_file() or path.is_symlink():
                            continue
                        if path.is_relative_to(scratch / 'private') or path == scratch / 'gh.jsonl':
                            continue
                        if path.is_relative_to(remote / 'objects'):
                            continue
                        assert public_title.encode() not in path.read_bytes(), str(path)

        finally:
            # On assertion failure the real worker is released and allowed to
            # finish before fixture removal; owner EOF is the final backstop.
            os.write(release_fd, b'complete\n')
            if worker_exit is not None:
                select.select([worker_exit], [], [], 120)
            if owner is not None and owner.poll() is None:
                owner.stdin.close()
                owner.wait(timeout=15)
            if worker_exit is not None:
                assert select.select([worker_exit], [], [], 30)[0], 'worker not reaped before fixture removal'
                worker_exit.close()
            os.close(ready_fd); os.close(release_fd)
            os.environ.clear(); os.environ.update(previous)


if __name__ == '__main__':
    scenario()
    scenario(stop_owner=True)
