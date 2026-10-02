"""Real external cleanup, reconcile and checkpoint entrypoints with local git."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1)).resolve()
sys.path.insert(0, str(ROOT / 'bin/lib'))
from fm_onboard import approve, infer
from external_registry import write_registry


class ExternalEntrypoints(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='external-entrypoints-')
        self.addCleanup(self.tmp.cleanup)
        self.scratch = Path(self.tmp.name).resolve()
        self.engine = self.scratch / 'engine'
        self.engine.mkdir()
        shutil.copytree(ROOT / 'bin', self.engine / 'bin',
                        ignore=shutil.ignore_patterns('__pycache__'))
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('FM_', 'HERDR_', 'GIT_')) and k != 'GH_REPO'}
        self.env.update(FM_HOME=str(self.scratch / 'private'), FM_PROJECT='app',
                        FM_ROOT=str(self.engine), FM_GITHUB_URL=str(self.scratch / 'remotes'),
                        GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
                        PYTHONDONTWRITEBYTECODE='1', FM_HOST='none', HERDR_ENV='0')
        write_registry(self.engine)
        self.home = self.scratch / 'private/projects/app'
        self.home.mkdir(parents=True)
        self.evidence = dict(repository='owner/app', base='trunk', source='github', pulls=[], commits=[],
                             protection={'status': 'unknown'}, repository_info={
                                 'allow_merge_commit': True, 'allow_squash_merge': False,
                                 'allow_rebase_merge': False, 'delete_branch_on_merge': False})
        self.policy(False)
        self.repo = self.home / 'repo'
        self.repo.mkdir()
        self.git(self.repo, 'init', '-q', '-b', 'trunk')
        self.git(self.repo, 'remote', 'add', 'origin', str(self.scratch / 'remotes/owner/app.git'))
        (self.repo / 'content').write_text('preserved\n')
        self.git(self.repo, 'add', 'content')
        self.git(self.repo, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'base')
        self.tree = self.home / 'worktrees/T-051'
        self.tree.parent.mkdir()
        self.git(self.repo, 'worktree', 'add', '-qb', 't-051-work', str(self.tree))
        self.state = self.home / 'state'
        (self.state / 'events.jsonl').write_text('')
        self.calls = self.scratch / 'calls.jsonl'
        gh = self.scratch / 'gh'
        gh.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['FM_TEST_CALLS'], 'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
if sys.argv[1:3] == ['pr','view']:
    state=os.environ.get('FM_TEST_PR_STATE','MERGED')
    if state == 'unreadable': sys.exit(1)
    print(state)
elif sys.argv[1:3] == ['pr','list']:
    result=os.environ.get('FM_TEST_DOWNSTREAM','[]')
    if result == 'unreadable': sys.exit(1)
    print(result)
else: sys.exit(1)
''')
        gh.chmod(0o755)
        self.env.update(FM_GH=str(gh), FM_TEST_CALLS=str(self.calls))

    def policy(self, delete):
        approve(self.home, self.evidence, infer(self.evidence), dict(
            confirmed=True, policy_confirmed=True, captain='captain', intent='Fixture intent',
            product='Fixture product', required_checks=['ci'], contract={'check': 'true'},
            post='local', delete_branch=delete))

    def git(self, directory, *args):
        p = subprocess.run(['git', '-C', str(directory), *args], env=self.env,
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout.strip()

    def entry(self, script, *args):
        return subprocess.run(['bash', str(self.engine / 'bin' / script), '--repo', str(self.engine),
                               '--project', 'app', *args], env=self.env, cwd=self.engine,
                              capture_output=True, text=True, timeout=30)

    def cleanup(self, *args):
        return self.entry('fm-cleanup.sh', '--task', 'T-051', *args)

    def assertRetained(self, result, reason):
        self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
        self.assertIn(reason, result.stderr)
        self.assertEqual((self.tree / 'content').read_text(), 'preserved\n')
        self.assertIn('t-051-work', self.git(self.repo, 'branch', '--list'))

    def test_cleanup_lock_refuses_even_force(self):
        runs = self.state / 'runs'; runs.mkdir()
        with (runs / '.worker-T-051.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            p = self.cleanup('--force')
        self.assertRetained(p, 'task has a live worker; worktree retained')
        self.assertFalse(self.calls.exists(), 'locked task must not query GitHub')

    def test_cleanup_task_idle_refuses_uncertain_attempt(self):
        run = self.state / 'runs/worker-fixture-t051-r1'
        attempt = run / 'attempt'; attempt.mkdir(parents=True)
        (run / 'identity.json').write_text(json.dumps(dict(task='T-051', project='app', role='worker')))
        (run / 'orchestration-result.json').write_text('{}')
        (attempt / 'execution.json').write_text('{"started":false}')
        p = self.cleanup('--force')
        self.assertRetained(p, 'live or uncertain execution')
        self.assertFalse(self.calls.exists())

    def test_cleanup_open_and_unreadable_pr_are_retained(self):
        for state in ('OPEN', 'unreadable'):
            with self.subTest(state=state):
                self.env['FM_TEST_PR_STATE'] = state
                self.assertRetained(self.cleanup(),
                    'external PR is open or its outcome is unknown; worktree retained')
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(len(calls), 2)
        for call in calls:
            self.assertEqual(call[:3], ['pr', 'view', 't-051-work'])
            self.assertEqual(call[call.index('--repo') + 1], 'owner/app')

    def check_deletion(self, delete, downstream, retained):
        self.policy(delete)
        self.env['FM_TEST_DOWNSTREAM'] = downstream
        p = self.cleanup()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertFalse(self.tree.exists())
        self.assertEqual(bool(self.git(self.repo, 'branch', '--list', 't-051-work')), retained)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        for call in calls:
            self.assertEqual(call[call.index('--repo') + 1], 'owner/app')
        downstream_calls = [call for call in calls if call[:2] == ['pr', 'list']]
        self.assertEqual(len(downstream_calls), int(delete))
        if delete:
            self.assertEqual(downstream_calls[0][downstream_calls[0].index('--base')+1], 't-051-work')

    def test_cleanup_retains_branch_by_convention(self):
        self.check_deletion(False, '[]', True)

    def test_cleanup_deletes_branch_only_when_confirmed_and_unused(self):
        self.check_deletion(True, '[]', False)

    def test_cleanup_retains_downstream_base(self):
        self.check_deletion(True, '[{"number":10}]', True)

    def test_cleanup_retains_branch_when_downstream_unknown(self):
        self.check_deletion(True, 'unreadable', True)

    def test_reconcile_lists_only_project_repository(self):
        p = self.entry('fm-reconcile.sh', '--dry-run')
        self.assertEqual(p.returncode, 0, p.stderr)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:2], ['pr', 'list'])
        self.assertEqual(calls[0][calls[0].index('--repo')+1], 'owner/app')
        self.assertTrue(self.tree.exists())

    def test_checkpoint_refuses_staged_nested_private_paths(self):
        before = self.git(self.tree, 'rev-parse', 'HEAD')
        private = self.tree / 'nested/.fm-private'
        private.mkdir(parents=True)
        (private / 'prompt').write_text('private sentinel')
        self.git(self.tree, 'add', '-f', 'nested/.fm-private/prompt')
        p = self.entry('fm-checkpoint.sh', '--task', 'T-051', '--message', 'fixture work')
        self.assertEqual(p.returncode, 65, p.stdout + p.stderr)
        self.assertIn('private artifacts cannot be committed', p.stderr)
        self.assertEqual(self.git(self.tree, 'rev-parse', 'HEAD'), before)
        self.assertFalse(self.calls.exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
