"""T-274: the flaky-test ledger, bin/lib/fm_flaky.py, driven as firstmate
drives it: one process per command against a fixture root and FM_HOME.

Usage: flaky_ledger.py <repo root> <test name>. tests/flaky-ledger.test.sh
runs each test as its own named assertion. Fixtures: tests/fixtures/flaky-ledger/.
"""
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
ROOT = Path(sys.argv.pop(1)).resolve()
HELPER = ROOT/'bin/lib/fm_flaky.py'
FIXTURES = ROOT/'tests/fixtures/flaky-ledger'
REPO = 'BenjaminLu/firstmate-workflow'
DETAIL = ['--repo', REPO, '--file', 'tests/e2e/board-task-detail.spec.ts',
          '--title', 'external review locations and minute refresh stay private',
          '--error', 'locator.click timeout: element is not visible']
GAME = ['--repo', REPO, '--file', 'tests/e2e/game.spec.ts',
        '--title', 'voyage is one live stage, persists its size, and Esc Esc unloads it',
        '--error', 'expect toHaveCount timeout']


def failure(run, at, attempt=1, pr=254, head='c0e9d5ac', job=None):
    return ['--pr', str(pr), '--head', head, '--run', str(run), '--job', str(job or run + 1),
            '--attempt', str(attempt), '--at', at]


def tree(path):
    """Every file under path with its digest: 'writes nothing' is checkable."""
    return {str(p.relative_to(path)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(Path(path).rglob('*')) if p.is_file()}


class Ledger(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()/'engine'
        self.home = Path(temp.name).resolve()/'home'
        (self.root/'state').mkdir(parents=True); self.home.mkdir()
        shutil.copy(FIXTURES/'self-config.yaml', self.root/'config.yaml')
        self.ledger = self.root/'state/flaky-ledger.json'
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        self.env.update(FM_ROOT=str(self.root), FM_HOME=str(self.home), HERDR_ENV='0')

    def fm(self, *args, code=0):
        result = subprocess.run([sys.executable, str(HELPER), *args], env=self.env,
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, code, result.stderr)
        return result

    def hit(self, signature, *failure_args, project=()):
        return json.loads(self.fm('hit', *project, *signature, *failure_args).stdout)

    def read(self, path=None):
        return json.loads((path or self.ledger).read_text())

    def entry(self, title):
        return next(e for e in self.read()['signatures'] if e['title'] == title)

    def test_first_hit_records_ci_time(self):
        out = self.hit(DETAIL, *failure(37914100220, '2026-01-02T03:04:05Z'))
        self.assertEqual(out['cycle_hits'], 1)
        [entry] = self.read()['signatures']
        self.assertEqual(entry['first_seen'], '2026-01-02T03:04:05Z')
        self.assertEqual(entry['repository'], REPO)
        self.assertEqual(entry['project'], 'firstmate-workflow')
        self.assertEqual(entry['investigation']['status'], 'none')
        self.assertEqual(entry['hits'], [{'pr': 254, 'head': 'c0e9d5ac', 'run': 37914100220, 'job': 37914100221,
                                          'attempt': 1, 'at': '2026-01-02T03:04:05Z', 'rerun': False}])

    def test_line_number_and_locale_join_one_signature(self):
        first = list(DETAIL); first[3] += ':127'; first[5] += ' (en)'
        second = list(DETAIL); second[3] += ':143'; second[5] += ' (zh-TW)'
        self.hit(first, *failure(100, '2026-10-09T09:57:35Z'))
        out = self.hit(second, *failure(200, '2026-10-09T13:59:31Z', pr=250, head='f850ca5e'))
        self.assertEqual(out['cycle_hits'], 2)
        self.assertTrue(out['investigation_due'])
        [entry] = self.read()['signatures']
        self.assertEqual(entry['file'], 'tests/e2e/board-task-detail.spec.ts')
        self.assertEqual(entry['title'], 'external review locations and minute refresh stay private')

    def test_same_failure_is_one_hit_and_rerun_sets_only_its_flag(self):
        self.hit(DETAIL, *failure(100, '2026-10-09T09:57:35Z'))
        out = self.hit(DETAIL, *failure(100, '2026-10-09T09:57:35Z'))
        self.assertEqual(out['cycle_hits'], 1)
        before = self.read()['signatures'][0]['hits']
        self.assertEqual(len(before), 1); self.assertFalse(before[0]['rerun'])
        out = self.hit(DETAIL, *failure(100, '2026-10-09T09:57:35Z'), '--rerun')
        self.assertEqual(out['cycle_hits'], 1)
        after = self.read()['signatures'][0]['hits']
        self.assertEqual(after, [dict(before[0], rerun=True)])

    def test_later_attempt_is_a_second_hit(self):
        self.hit(DETAIL, *failure(100, '2026-10-09T09:57:35Z', attempt=1))
        out = self.hit(DETAIL, *failure(100, '2026-10-09T10:20:00Z', attempt=2))
        self.assertEqual(out['cycle_hits'], 2)
        self.assertEqual([h['attempt'] for h in self.read()['signatures'][0]['hits']], [1, 2])

    def test_other_owner_same_repository_name_is_another_flake(self):
        other = list(DETAIL); other[1] = 'someone-else/firstmate-workflow'
        self.hit(DETAIL, *failure(100, '2026-10-09T09:57:35Z'))
        out = self.hit(other, *failure(200, '2026-10-09T13:59:31Z'))
        self.assertEqual(out['cycle_hits'], 1)
        entries = self.read()['signatures']
        self.assertEqual(sorted(e['repository'] for e in entries), sorted([REPO, 'someone-else/firstmate-workflow']))
        self.assertEqual([len(e['hits']) for e in entries], [1, 1])

    def test_investigate_refuses_while_open_and_while_fix_task(self):
        self.hit(DETAIL, *failure(100, '2026-10-09T09:57:35Z'))
        self.fm('investigate', *DETAIL, '--owner', 'firstmate')
        before = self.ledger.read_bytes()
        refused = self.fm('investigate', *DETAIL, '--owner', 'researcher', code=65)
        self.assertIn('open', refused.stderr)
        self.assertEqual(self.ledger.read_bytes(), before)
        self.fm('link', *DETAIL, '--task', 'T-275')
        before = self.ledger.read_bytes()
        refused = self.fm('investigate', *DETAIL, '--owner', 'researcher', code=65)
        self.assertIn('fix-task', refused.stderr)
        self.assertEqual(self.ledger.read_bytes(), before)

    def test_link_and_fixed_persist_task_pr_and_commit(self):
        self.hit(DETAIL, *failure(100, '2026-10-09T09:57:35Z'))
        self.fm('investigate', *DETAIL, '--owner', 'firstmate')
        self.fm('link', *DETAIL, '--task', 'T-274')
        self.assertEqual(self.read()['signatures'][0]['investigation']['task'], 'T-274')
        self.assertEqual(self.read()['signatures'][0]['investigation']['status'], 'fix-task')
        self.fm('fixed', *DETAIL, '--pr', '260', '--commit', 'abc1234def', '--at', '2026-10-10T00:00:00Z')
        self.assertEqual(self.read()['signatures'][0]['investigation'], {
            'status': 'fixed', 'owner': 'firstmate', 'task': 'T-274', 'merged_pr': 260,
            'merge_commit': 'abc1234def', 'fixed_at': '2026-10-10T00:00:00Z'})

    def test_show_prints_every_signature_with_count_and_status(self):
        self.hit(DETAIL, *failure(100, '2026-10-09T09:57:35Z'))
        self.hit(DETAIL, *failure(200, '2026-10-09T13:59:31Z'))
        self.hit(GAME, *failure(300, '2026-10-09T10:13:07Z'))
        self.fm('investigate', *GAME, '--owner', 'firstmate')
        lines = self.fm('show').stdout.splitlines()
        self.assertEqual(len(lines), 2)
        detail = next(l for l in lines if 'board-task-detail' in l).split('\t')
        game = next(l for l in lines if 'game.spec' in l).split('\t')
        self.assertIn('cycle_hits=2', detail); self.assertIn('status=none', detail); self.assertIn('investigate=due', detail)
        self.assertIn('cycle_hits=1', game); self.assertIn('status=open', game)

    def test_fixture_with_active_investigation_counts_and_refuses(self):
        shutil.copy(FIXTURES/'active-investigation.json', self.ledger)
        show = self.fm('show').stdout
        self.assertRegex(show, r'board-task-detail.*\tcycle_hits=2\thits=2\tstatus=open\towner=firstmate')
        self.assertRegex(show, r'game\.spec.*\tcycle_hits=1\thits=1\tstatus=none')
        # Pre-existing hits count toward the second-hit rule.
        out = self.hit(GAME, *failure(400, '2026-10-09T15:00:00Z'))
        self.assertEqual(out['cycle_hits'], 2); self.assertTrue(out['investigation_due'])
        out = self.hit(DETAIL, *failure(500, '2026-10-09T14:34:47Z', pr=257, head='0a827688'))
        self.assertEqual(out['cycle_hits'], 3); self.assertFalse(out['investigation_due'])
        before = self.ledger.read_bytes()
        self.fm('investigate', *DETAIL, '--owner', 'researcher', code=65)
        self.assertEqual(self.ledger.read_bytes(), before)

    def test_external_project_uses_its_private_root(self):
        shutil.copy(FIXTURES/'external-config.yaml', self.root/'config.yaml')
        beta = ['--repo', 'example/beta', '--file', 'tests/a.test.ts', '--title', 'a', '--error', 'timeout']
        self.hit(beta, *failure(100, '2026-10-09T09:57:35Z'), project=('--project', 'beta'))
        private = self.home/'projects/beta/state/flaky-ledger.json'
        self.assertEqual(self.read(private)['signatures'][0]['project'], 'beta')
        self.assertFalse(self.ledger.exists())
        self.assertIn('example/beta', self.fm('show', '--project', 'beta').stdout)
        self.assertEqual(self.fm('show').stdout.strip(), 'no flaky signatures')

    def test_unresolvable_external_project_writes_nothing(self):
        shutil.copy(FIXTURES/'external-config.yaml', self.root/'config.yaml')
        before = (tree(self.root), tree(self.home))
        for command in (['hit', *DETAIL, *failure(100, '2026-10-09T09:57:35Z')],
                        ['investigate', *DETAIL, '--owner', 'firstmate'], ['show']):
            self.fm(command[0], '--project', 'ghost', *command[1:], code=65)
        self.assertEqual((tree(self.root), tree(self.home)), before)
        # A registry that cannot route a named project never falls back to the engine.
        (self.root/'config.yaml').write_text('default_project: firstmate-workflow\n')
        before = (tree(self.root), tree(self.home))
        self.fm('hit', '--project', 'beta', *DETAIL, *failure(100, '2026-10-09T09:57:35Z'), code=65)
        self.assertEqual((tree(self.root), tree(self.home)), before)
        self.assertFalse(self.ledger.exists())
        self.assertFalse((self.home/'projects').exists())

    def test_unknown_fields_survive_a_rewrite(self):
        shutil.copy(FIXTURES/'active-investigation.json', self.ledger)
        self.hit(DETAIL, *failure(500, '2026-10-09T14:34:47Z'))
        self.fm('link', *DETAIL, '--task', 'T-274')
        ledger = self.read(); entry = self.entry('external review locations and minute refresh stay private')
        self.assertEqual(ledger['x_ledger_note'], 'kept by every rewrite')
        self.assertEqual(entry['x_entry_note'], 'kept on the entry')
        self.assertEqual(entry['hits'][0]['x_hit_note'], 'kept on the hit')
        self.assertEqual(entry['investigation']['x_investigation_note'], 'kept on the investigation')

    def fixed_signature(self):
        self.hit(DETAIL, *failure(100, '2026-10-09T09:57:35Z'))
        self.hit(DETAIL, *failure(200, '2026-10-09T13:59:31Z'))
        self.fm('investigate', *DETAIL, '--owner', 'firstmate')
        self.fm('link', *DETAIL, '--task', 'T-274')
        self.fm('fixed', *DETAIL, '--pr', '260', '--commit', 'abc1234', '--at', '2026-10-10T00:00:00Z')

    def test_hits_after_a_fix_start_a_new_cycle(self):
        self.fixed_signature()
        self.assertIn('cycle_hits=0\thits=2\tstatus=fixed', self.fm('show').stdout)
        out = self.hit(DETAIL, *failure(300, '2026-10-11T00:00:00Z'))
        self.assertEqual(out['cycle_hits'], 1); self.assertFalse(out['investigation_due'])
        self.assertEqual(self.read()['signatures'][0]['investigation']['status'], 'fixed')
        # A new process that knows only the file counts the cycle from fixed_at.
        out = self.hit(DETAIL, *failure(400, '2026-10-12T00:00:00Z'))
        self.assertEqual(out['cycle_hits'], 2); self.assertTrue(out['investigation_due'])
        self.assertIn('cycle_hits=2\thits=4\tstatus=fixed', self.fm('show').stdout)

    def test_same_post_fix_hit_twice_counts_once(self):
        self.fixed_signature()
        self.hit(DETAIL, *failure(300, '2026-10-11T00:00:00Z'))
        out = self.hit(DETAIL, *failure(300, '2026-10-11T00:00:00Z'), '--rerun')
        self.assertEqual(out['cycle_hits'], 1)
        self.assertIn('cycle_hits=1\thits=3', self.fm('show').stdout)

    def test_investigate_from_fixed_keeps_history(self):
        self.fixed_signature()
        self.hit(DETAIL, *failure(300, '2026-10-11T00:00:00Z'))
        self.fm('investigate', *DETAIL, '--owner', 'researcher')
        entry = self.read()['signatures'][0]
        self.assertEqual(entry['investigation']['status'], 'open')
        self.assertEqual(entry['investigation']['owner'], 'researcher')
        self.assertIsNone(entry['investigation']['task'])
        self.assertEqual(entry['history'], [{'status': 'fixed', 'owner': 'firstmate', 'task': 'T-274', 'merged_pr': 260,
                                             'merge_commit': 'abc1234', 'fixed_at': '2026-10-10T00:00:00Z'}])
        # The cycle still starts at the last fix while the new one is open.
        self.assertIn('cycle_hits=1\thits=3\tstatus=open', self.fm('show').stdout)

    def test_fixed_without_fixed_at_is_refused(self):
        shutil.copy(FIXTURES/'fixed-without-fixed-at.json', self.ledger)
        before = self.ledger.read_bytes()
        broken = ['--repo', REPO, '--file', 'tests/e2e/board.spec.ts',
                  '--title', 'a fix recorded without its merge time', '--error', 'expect toBeVisible timeout']
        for command in (['hit', *broken, *failure(900, '2026-10-12T00:00:00Z')], ['show'],
                        ['investigate', *broken, '--owner', 'firstmate']):
            refused = self.fm(*command, code=65)
            self.assertIn('a fix recorded without its merge time', refused.stderr)
            self.assertEqual(self.ledger.read_bytes(), before)


if __name__ == '__main__':
    name = sys.argv.pop(1)
    unittest.main(argv=[sys.argv[0], 'Ledger.' + name], verbosity=0)
