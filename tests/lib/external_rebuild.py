"""T-223 real external worker fixture; local origin and scripted adapter only."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
root = Path(sys.argv[1])
sys.path.insert(0, str(root / 'bin/lib'))
from fm_evidence import Store
from fm_onboard import approve, infer
from external_registry import write_registry


class ExternalRebuild(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='external-rebuild-')
        self.addCleanup(temporary.cleanup)
        self.scratch = Path(temporary.name).resolve()
        self.engine = self.scratch / 'engine'
        self.engine.mkdir()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('FM_', 'HERDR_', 'GIT_')) and k != 'GH_REPO'}
        self.env.update(FM_HOME=str(self.scratch / 'private'),
            FM_GITHUB_URL=str(self.scratch / 'remotes'), FM_ROOT=str(self.engine),
            FM_PROJECT='app', FM_SESSION_PID=str(os.getpid()), FM_HOST='none',
            FM_GIT_NAME='Fixture', FM_GIT_EMAIL='fixture@example.invalid',
            HERDR_ENV='0', FM_TRANSPORT='direct', PYTHONDONTWRITEBYTECODE='1',
            GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=str(self.scratch / 'gitconfig'))
        (self.scratch / 'gitconfig').write_text('')
        for directory in ('bin', 'skills', '.githooks'):
            shutil.copytree(root / directory, self.engine / directory,
                            ignore=shutil.ignore_patterns('__pycache__'))
        write_registry(self.engine)
        adapter = self.engine / 'bin/adapters/mock.sh'
        adapter.write_text('''#!/usr/bin/env python3
import os, sys
from pathlib import Path
prompt = Path(sys.argv[2]).read_text()
Path(os.environ['FM_TEST_PROMPT']).write_text(prompt)
tree = Path(sys.argv[3])
if '# Your branch was rebuilt' in prompt:
    assert '<<<<<<<' in (tree/'app').read_text(), 'worker received no conflict markers'
    (tree/'app').write_text('base intent and task intent\\n')
    (tree/'.fm-say.md').write_text('Resolved both intentions.\\n')
with open(sys.argv[4], 'a') as log:
    log.write('WORKER_COMPLETE:T-223\\n')
''')
        adapter.chmod(0o755)
        self.run_ok('git', 'init', '-q', '-b', 'main', str(self.engine))
        self.run_ok('git', '-C', str(self.engine), 'add', '.')
        self.run_ok('git', '-C', str(self.engine), '-c', 'user.name=Fixture', '-c',
                    'user.email=fixture@example.invalid', 'commit', '-qm', 'engine')
        self.remote = self.scratch / 'remotes/owner/app.git'
        self.remote.parent.mkdir(parents=True)
        self.run_ok('git', 'init', '-q', '--bare', '-b', 'trunk', str(self.remote))
        self.seed = self.scratch / 'seed'
        self.run_ok('git', 'clone', '-q', str(self.remote), str(self.seed))
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        (self.seed / 'app').write_text('original\n')
        self.commit('initial')
        self.git('checkout', '-b', 't-223-work')
        (self.seed / 'app').write_text('task intent\n')
        self.commit('task')
        self.prev = self.git('rev-parse', 'HEAD')
        self.git('checkout', 'trunk')
        (self.seed / 'app').write_text('base intent\n')
        self.commit('base moved')
        self.base = self.git('rev-parse', 'HEAD')
        self.git('push', '-q', 'origin', 'trunk', 't-223-work',
                 't-223-work:refs/pull/9/head')
        self.run_ok('git', 'config', '--global', 'url.' + str(self.remote) + '.insteadOf',
                    'https://github.com/owner/app.git')
        self.home = self.scratch / 'private/projects/app'
        self.home.mkdir(parents=True)
        self.evidence = dict(repository='owner/app', base='trunk', source='github',
            pulls=[], commits=[], protection={'status': 'unknown'}, repository_info={
                'allow_merge_commit': True, 'allow_squash_merge': False,
                'allow_rebase_merge': False, 'delete_branch_on_merge': False})
        self.policy(True)
        (self.home / 'tasks').mkdir(exist_ok=True)
        spec = json.dumps(dict(id='T-223', title='Private rebuild fixture', depends_on=[],
                              scope=['app'], acceptance=['Keep both intentions.']))
        (self.home / 'tasks/T-223.json').write_text(spec)
        (self.home / 'design.md').write_text('Private design.\n')
        self.state = self.home / 'state'
        Store(self.state, 'app', 'T-223', external=True).append('spec-preflight', 1,
            'reviewer-fixture', 'a' * 40, '1. Fixture acceptance checked.\nSPEC-OK:T-223',
            spec_sha256=hashlib.sha256(spec.encode()).hexdigest(), verdict='SPEC-OK',
            provenance={'level': 'legacy', 'vendor': 'claude'})
        (self.state / 'events.jsonl').write_text(json.dumps(dict(type='greenlit',
            actor='captain', project='app', ts='2026-10-02T00:00:00Z', data={})) + '\n')
        gh = self.scratch / 'gh'
        gh.write_text('''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['FM_TEST_GH_LOG'], 'a') as log:
    log.write(json.dumps(args)+'\\n')
def rev(ref):
    return subprocess.check_output(['git', '--git-dir='+os.environ['FM_TEST_REMOTE'],
                                   'rev-parse', ref], text=True).strip()
if args[:2] == ['pr', 'view']:
    if '--jq' in args and args[args.index('--jq')+1] == '.headRefName':
        print('t-223-work')
    else:
        print(json.dumps(dict(headRefOid=rev('t-223-work'), baseRefOid=rev('trunk'),
            headRefName='t-223-work', baseRefName='trunk', state='OPEN', mergeStateStatus='CLEAN')))
elif args[:2] == ['pr', 'list']: print('9')
elif args and args[0] == 'api' and '--input' in args:
    payload = json.load(sys.stdin)
    with open(os.environ['FM_TEST_PROJECTIONS'], 'a') as log:
        log.write(json.dumps(dict(args=args, payload=payload, remote=rev('t-223-work')))+'\\n')
    print('{"id": 123}')
else: sys.exit(1)
''')
        gh.chmod(0o755)
        # Observe actual git argv without changing the git operation.
        observer = self.scratch / 'observer'
        observer.mkdir()
        real_git = shutil.which('git', path=self.env['PATH'])
        self.assertIsNotNone(real_git)
        (observer / 'git').write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['FM_TEST_GIT_LOG'], 'a') as log:
    log.write(json.dumps(sys.argv[1:])+'\\n')
os.execv(os.environ['FM_TEST_REAL_GIT'], [os.environ['FM_TEST_REAL_GIT'], *sys.argv[1:]])
''')
        (observer / 'git').chmod(0o755)
        self.env.update(FM_GH=str(gh), FM_TEST_GH_LOG=str(self.scratch / 'gh.jsonl'),
            FM_TEST_REMOTE=str(self.remote), FM_TEST_PROMPT=str(self.scratch / 'prompt.md'),
            FM_TEST_PROJECTIONS=str(self.scratch / 'projections.jsonl'),
            FM_TEST_REAL_GIT=real_git, FM_TEST_GIT_LOG=str(self.scratch / 'git.jsonl'),
            PATH=str(observer) + os.pathsep + self.env['PATH'])

    def run_ok(self, *args):
        p = subprocess.run(args, env=self.env, capture_output=True, text=True,
                           stdin=subprocess.DEVNULL, timeout=120)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        return p.stdout.strip()

    def git(self, *args):
        return self.run_ok('git', '-C', str(self.seed), *args)

    def commit(self, message):
        self.git('add', '-A')
        self.git('commit', '-qm', message)

    def policy(self, force, post='local'):
        approve(self.home, self.evidence, infer(self.evidence), dict(confirmed=True,
            policy_confirmed=True, captain='captain', intent='Rebuild task branches',
            product='Fixture', required_checks=['ci'], contract={'check': 'true'},
            post=post, force_with_lease=force))

    def launch(self):
        p = subprocess.run([str(self.engine / 'bin/fm-worker.sh'), '--repo', str(self.engine),
            '--project', 'app', '--task', 'T-223', '--pr', '9'], env=self.env,
            text=True, capture_output=True, stdin=subprocess.DEVNULL, timeout=120)
        self.output = p.stdout + p.stderr
        return p

    def records(self):
        return Store(self.state, 'app', 'T-223', external=True).records()

    def test_real_external_rebuild_keeps_pr_and_private_evidence(self):
        p = self.launch()
        self.assertEqual(p.returncode, 0, self.output)
        head = self.run_ok('git', '--git-dir=' + str(self.remote), 'rev-parse', 't-223-work')
        self.assertEqual(self.run_ok('git', '--git-dir=' + str(self.remote), 'show',
                                    '-s', '--format=%P', head), self.base)
        self.assertEqual(self.run_ok('git', '--git-dir=' + str(self.remote), 'rev-list',
                                    '--count', 'trunk..t-223-work'), '1')
        prompt = (self.scratch / 'prompt.md').read_text()
        rebuilt_prompt = prompt.split('# Your branch was rebuilt', 1)[1].split('# Saving your branch', 1)[0]
        self.assertIn('- `app`', rebuilt_prompt)
        self.assertNotIn('design/tasks/', rebuilt_prompt)
        self.assertIn('Checkout/head SHA: `' + self.prev + '`', prompt)
        calls = [json.loads(line) for line in (self.scratch / 'gh.jsonl').read_text().splitlines()]
        self.assertFalse(any(call[:2] in (['pr', 'create'], ['pr', 'comment'], ['pr', 'close']) for call in calls))
        pushes = [json.loads(line) for line in (self.scratch / 'git.jsonl').read_text().splitlines()]
        self.assertTrue(any('--force-with-lease=refs/heads/t-223-work:' + self.prev in call for call in pushes))
        events = [json.loads(line) for line in (self.state / 'events.jsonl').read_text().splitlines()]
        rebuilt = [e for e in events if e.get('data', {}).get('rebuilt')]
        self.assertEqual(len(rebuilt), 1, rebuilt)
        self.assertEqual(rebuilt[0]['type'], 'commit_pushed')
        self.assertEqual(str(rebuilt[0]['pr']), '9')
        self.assertEqual(rebuilt[0]['data']['rebuilt'], dict(previous_head=self.prev,
            base='trunk', base_head=self.base, head=head, conflicts=['app']))
        for kind in ('pack', 'worker-report'):
            records = [r for r in self.records() if r['kind'] == kind]
            self.assertEqual(len(records), 1, records)
            self.assertEqual(records[0]['head'], self.prev)
        notes = list((self.state / 'notes/T-223').glob('rebuild-*.md'))
        self.assertEqual(len(notes), 1)
        texts = [path.read_text() for path in notes if path.is_file()]
        self.assertTrue(any(self.prev in text and head in text and 'Conflicts handed to the worker: `app`' in text
                            for text in texts), texts)

    def test_projection_occurs_once_after_push_with_pushed_head(self):
        self.policy(True, 'summary')
        p = self.launch()
        self.assertEqual(p.returncode, 0, self.output)
        records = [r for r in self.records() if r['kind'] == 'projection']
        self.assertEqual(len(records), 1, records)
        head = self.run_ok('git', '--git-dir=' + str(self.remote), 'rev-parse', 't-223-work')
        self.assertEqual(records[0]['head'], head)
        self.assertNotEqual(head, self.prev)
        self.assertNotIn('projection head is stale', self.output)
        projections = [json.loads(line) for line in (self.scratch / 'projections.jsonl').read_text().splitlines()]
        self.assertEqual(len(projections), 1, projections)
        self.assertEqual(projections[0]['remote'], head)
        self.assertIn(head, projections[0]['payload']['body'])
        self.assertIn('Checkout/head SHA: `' + self.prev + '`', (self.scratch / 'prompt.md').read_text())
        for kind in ('pack', 'worker-report'):
            self.assertEqual([r['head'] for r in self.records() if r['kind'] == kind], [self.prev])

    def test_false_policy_leaves_origin_unchanged(self):
        self.policy(False)
        self.launch()
        self.assertIn('conventions do not allow force_with_lease', self.output)
        self.assertEqual(self.run_ok('git', '--git-dir=' + str(self.remote), 'rev-parse', 't-223-work'), self.prev)
        self.assertNotIn('# Your branch was rebuilt', (self.scratch / 'prompt.md').read_text())
        self.assertNotIn('--force-with-lease', (self.scratch / 'git.jsonl').read_text())

    def test_missing_policy_field_refuses_at_startup(self):
        conventions = self.home / 'CONVENTIONS.md'
        conventions.write_text('\n'.join(line for line in conventions.read_text().splitlines()
                                        if not line.startswith('force_with_lease:')) + '\n')
        p = self.launch()
        self.assertEqual(p.returncode, 65, self.output)
        self.assertEqual(self.run_ok('git', '--git-dir=' + str(self.remote), 'rev-parse', 't-223-work'), self.prev)
        self.assertFalse((self.scratch / 'prompt.md').exists())



if __name__ == '__main__':
    unittest.main(argv=['external-rebuild'])
