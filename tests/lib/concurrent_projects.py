"""Behavioral coverage of the shared capacity and merge-turn coordinator."""
import importlib.util
import json
import concurrent.futures
import shutil
import signal
import select
import subprocess
import os
import re
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1))
spec = importlib.util.spec_from_file_location('concurrent', ROOT / 'bin/lib/fm_concurrent.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ConcurrentProjects(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.routes = [dict(name=n, state=str(self.root / n)) for n in ('alpha', 'beta')]

    def write(self, project, path, value):
        module.managed.save(self.root / project / path, value)

    def live(self, project, task='T-012'):
        self.write(project, 'runs/worker/identity.json', dict(project=project, task=task, role='worker'))
        self.write(project, 'runs/worker/process.json', dict(pid=os.getpid(), token='concurrent_projects.py'))

    def test_shared_task_ids_count_twice_and_completed_round_releases_slot(self):
        self.live('alpha'); self.live('beta')
        self.assertEqual(2, len(module.live_rounds(self.routes)))
        self.write('alpha', 'runs/worker/orchestration-result.json', dict(status='done'))
        self.assertEqual(['beta'], [r['project'] for r in module.live_rounds(self.routes)])

    def test_historical_events_and_open_prs_do_not_consume_capacity(self):
        self.write('alpha', 'events.jsonl', dict(type='dispatched', task='T-012'))
        self.assertEqual([], module.live_rounds(self.routes))

    def test_owned_launcher_record_releases_capacity_on_keeper_exit(self):
        life = module.managed.lifeline()
        record = self.root / 'launcher.lock'
        child = life.start([sys.executable, '-c', 'import time; time.sleep(120)'],
                           owner=os.getpid(), owner_record=record,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            self.write('alpha', 'runs/worker/identity.json',
                       dict(project='alpha', task='T-012', role='worker'))
            self.write('alpha', 'runs/worker/process.json', dict(owner_record=str(record)))
            self.assertEqual(1, len(module.live_rounds(self.routes)))
        finally:
            child.terminate(); child.wait(timeout=10)
        self.assertEqual([], module.live_rounds(self.routes))

    def test_fair_fill_uses_fewer_live_rounds_and_name_tie_break(self):
        queues = {'alpha': ['T-012', 'T-013'], 'beta': ['T-012', 'T-013']}
        self.assertEqual([('alpha', 'T-012'), ('beta', 'T-012'), ('alpha', 'T-013')],
                         module.fair_fill(queues, [], 3))
        self.live('alpha')
        self.assertEqual([('beta', 'T-012')], module.fair_fill(queues, module.live_rounds(self.routes), 2))

    def test_pending_and_answered_merge_hold_only_their_project(self):
        card = dict(id='D-alpha-T012-1', project='alpha', kind='merge', task='T-012')
        self.write('alpha', 'pending/card.json', card)
        self.assertIn('pending', module.merge_blocker(self.root / 'alpha', 'alpha'))
        self.assertEqual('', module.merge_blocker(self.root / 'beta', 'beta'))
        (self.root / 'alpha/pending/card.json').unlink()
        self.write('alpha', 'decisions/card.json', dict(card, chosen='A'))
        self.assertIn('running', module.merge_blocker(self.root / 'alpha', 'alpha'))
        self.write('alpha', 'decisions/card.json', dict(card, chosen='A', merge='merged'))
        self.assertEqual('', module.merge_blocker(self.root / 'alpha', 'alpha'))
        self.write('alpha', 'decisions/card.json', dict(card, chosen='A', merge='failed'))
        self.assertEqual('', module.merge_blocker(self.root / 'alpha', 'alpha'))
        for ok in (True, False):
            self.write('alpha', 'decisions/card.json', dict(card, chosen='A', merged=dict(ok=ok)))
            self.assertEqual('', module.merge_blocker(self.root / 'alpha', 'alpha'))
        self.write('alpha', 'decisions/card.json', dict(card, chosen='A', merge='running', merged=dict(ok=True)))
        self.assertIn('running', module.merge_blocker(self.root / 'alpha', 'alpha'))
        for choice in ('B', 'C'):
            self.write('alpha', 'decisions/card.json', dict(card, chosen=choice))
            self.assertEqual('', module.merge_blocker(self.root / 'alpha', 'alpha'))

    def test_merge_outcome_matches_board_reader_for_every_accepted_form(self):
        # Execute the board's actual expression: Python cannot import TypeScript.
        source = (ROOT / 'board/server.ts').read_text()
        expression = re.search(r'const mergeOf = .*?=>\s*(.*?);', source, re.S).group(1)
        records = [None, {}, {'merged': None}]
        records += [dict(merge=modern, merged=dict(ok=legacy))
                    for modern in (None, 'running', 'merged', 'failed', 'unknown')
                    for legacy in (True, False, None, 0, 1, 'true', 'false')]
        out = subprocess.run(['bun', '-e', 'const mergeOf = d => ' + expression + ';'
            + 'console.log(JSON.stringify(' + json.dumps(records) + '.map(mergeOf)))'],
            capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(out.stdout),
                         [module.merge_records.merge_outcome(r) for r in records])

    def test_greenlight_and_dependencies_are_project_local(self):
        events = [dict(type='greenlit', project='alpha'), dict(type='merged', task='T-001', project='alpha')]
        self.assertEqual([], module.project_events(events, 'beta', 'alpha'))
        self.assertEqual(events, module.project_events(events, 'alpha', 'alpha'))
        self.assertEqual([dict(type='greenlit')], module.project_events([dict(type='greenlit')], 'alpha', 'alpha'))


class RegisteredDispatch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.engine = self.base / 'engine'
        shutil.copytree(ROOT / 'bin', self.engine / 'bin')
        self.home = self.base / 'home'
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        self.env.update(FM_HOME=str(self.home), FM_ROOT=str(self.engine), FM_SESSION_PID=str(os.getpid()),
                        HERDR_ENV='0', FM_TRANSPORT='direct')
        self.env['PATH'] = str(self.engine / 'bin') + os.pathsep + self.env['PATH']
        (self.engine / 'config.yaml').write_text("default_project: alpha\nconcurrency: 3\nprojects:\n"
            "  alpha:\n    github: owner/alpha\n    base: main\n    required_check: ci\n"
            "  beta:\n    github: owner/beta\n    base: main\n    required_check: ci\n")
        for name in ('alpha', 'beta'):
            root = self.home / 'projects' / name
            (root / 'repo/.git').mkdir(parents=True)
            (root / 'tasks').mkdir()
            (root / 'state/decisions').mkdir(parents=True)
            (root / 'state/events.jsonl').write_text(json.dumps(dict(type='greenlit', project=name)) + '\n')
            for task in ('T-012', 'T-013', 'T-014'):
                (root / 'tasks' / (task + '.json')).write_text(json.dumps(dict(id=task, depends_on=[])))
        self.script('git', r'''#!/usr/bin/env bash
[ "$1" = -C ] || exit 1
root="$2"; shift 2
case "$1 $2" in
  'rev-parse --show-toplevel') printf '%s\n' "$root" ;;
  'remote get-url') printf 'https://github.com/owner/%s.git\n' "$(basename "$(dirname "$root")")" ;;
  *) exit 1 ;;
esac
''')
        self.script('fm-project.sh', r'''#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/verification.log"
[ ! -f "$FM_HOME/refuse-$2" ]
''')
        self.script('fm-worker.sh', r'''#!/usr/bin/env bash
exec python3 -c 'import time; time.sleep(120)'
''')
        self.addCleanup(self.stop_workers)
        for name in ('alpha', 'beta'):
            for task in ('T-012', 'T-013', 'T-014'):
                self.clear(name, task)

    def script(self, name, text):
        path = self.engine / 'bin' / name
        path.write_text(text); path.chmod(0o755)

    def state(self, name):
        return self.home / 'projects' / name / 'state'

    def clear(self, name, task):
        card = 'D-' + name + '-' + task.replace('-', '') + '-1'
        out = subprocess.run(['bash', str(self.engine / 'bin/fm-ready.sh'), 'judged', '--repo', str(self.engine),
                              '--project', name, '--task', task, '--decision', card], env=self.env,
                             capture_output=True, text=True)
        self.assertEqual(0, out.returncode, out.stderr)
        (self.state(name) / 'decisions' / (card + '.json')).write_text(json.dumps(
            dict(id=card, project=name, kind='choice', chosen='A', task=task)))

    def dispatch(self, *args):
        return subprocess.run([sys.executable, str(self.engine / 'bin/lib/fm_concurrent.py'),
                               'dispatch', '--repo', str(self.engine), *args], env=self.env,
                              capture_output=True, text=True, timeout=40)

    def receipts(self):
        return [json.loads(p.read_text()) for name in ('alpha', 'beta')
                for p in (self.state(name) / 'dispatch').glob('*.json')]

    def stop_workers(self):
        for receipt in self.receipts():
            try: os.kill(receipt['keeper'], signal.SIGTERM)
            except ProcessLookupError: pass
        for receipt in self.receipts():
            self.wait_keeper(receipt)

    def wait_keeper(self, receipt):
        life = module.managed.lifeline()
        try: watcher = life.ProcessExit(receipt['keeper'])
        except life.OwnerGone: return
        try: self.assertTrue(select.select([watcher], [], [], 10)[0], 'owned keeper must end')
        finally: watcher.close()

    def test_parallel_dispatch_never_exceeds_global_capacity(self):
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            outputs = list(pool.map(lambda _: self.dispatch(), range(2)))
        for out in outputs:
            self.assertEqual(0, out.returncode, out.stderr)
        receipts = self.receipts()
        self.assertEqual(3, len(receipts))
        self.assertEqual({'alpha', 'beta'}, {r['project'] for r in receipts})
        self.assertEqual(2, sum(r['task'] == 'T-012' for r in receipts))
        self.assertEqual(3, sum(len(o.stdout.splitlines()) for o in outputs
                                if 'nothing is ready' not in o.stdout))

    def test_project_greenlight_verification_and_clearance_do_not_cross(self):
        # Same id and card choice in alpha do not clear beta's task.
        for card in (self.state('beta') / 'decisions').glob('*.json'): card.unlink()
        out = self.dispatch('--project', 'beta', '--dry-run')
        self.assertEqual(0, out.returncode, out.stderr)
        self.assertNotIn('T-012', out.stdout)
        (self.state('beta') / 'events.jsonl').write_text(json.dumps(dict(type='greenlit', project='alpha')) + '\n')
        out = self.dispatch('--project', 'beta', '--task', 'T-012', '--dry-run')
        self.assertNotEqual(0, out.returncode)
        self.assertIn('no greenlit event', out.stderr)
        (self.home / 'refuse-beta').touch()
        out = self.dispatch('--project', 'beta')
        self.assertNotEqual(0, out.returncode)
        self.assertEqual([], self.receipts())
        self.assertIn('verify beta', (self.home / 'verification.log').read_text())

    def test_freed_slot_goes_to_project_with_fewer_live_runs(self):
        first = self.dispatch('--project', 'alpha', '--limit', '2')
        self.assertEqual(0, first.returncode, first.stderr)
        receipt = self.receipts()[0]
        os.kill(receipt['keeper'], signal.SIGTERM)
        self.wait_keeper(receipt)
        out = self.dispatch('--limit', '2')
        self.assertEqual(0, out.returncode, out.stderr)
        self.assertEqual(1, sum(r['project'] == 'beta' for r in self.receipts()))
        self.assertFalse((self.engine / 'state/events.jsonl').exists())
        status = subprocess.run([sys.executable, str(self.engine / 'bin/fm-herdr.py'),
                                 'session', 'status', str(self.engine)],
                                env=dict(self.env, FM_PROJECT='alpha'), capture_output=True, text=True)
        self.assertEqual(0, status.returncode, status.stderr)
        grouped = json.loads(status.stdout)['live_by_project']
        self.assertEqual(1, len(grouped['alpha']))
        self.assertEqual(1, len(grouped['beta']))
        self.assertNotIn('state', grouped['beta'][0])



class MergeTurns(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'bin').mkdir()
        git = self.root / 'bin/git'
        git.write_text('#!/usr/bin/env bash\ncat "$2/base"\n'); git.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root / 'bin') + os.pathsep + os.environ['PATH'])
        (self.root / 'base').write_text('old\n')
        self.child = self.root / 'request.py'
        self.child.write_text("import json,sys\nfrom pathlib import Path\ns=Path(sys.argv[1]); "
            "(s/'pending').mkdir(parents=True,exist_ok=True); "
            "(s/'pending/card.json').write_text(json.dumps(dict(kind='merge',project=sys.argv[2],id='card'))); "
            "print('requested')\n")

    def request(self, project):
        return subprocess.run([sys.executable, str(ROOT / 'bin/lib/fm_concurrent.py'), 'merge-turn',
            '--state', str(self.root / project), '--project', project, '--target', str(self.root),
            '--base', 'main', '--expected-base', 'old', '--task', 'T-012', '--',
            sys.executable, str(self.child), str(self.root / project), project],
            env=self.env, capture_output=True, text=True, timeout=15)

    def test_parallel_requests_take_only_one_turn_in_each_project(self):
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            outputs = list(pool.map(self.request, ['alpha', 'alpha']))
        self.assertEqual(1, sum(o.stdout.strip() == 'requested' for o in outputs))
        self.assertTrue(any('pending merge' in o.stdout for o in outputs))
        other = self.request('beta')
        self.assertEqual('requested', other.stdout.strip(), other.stderr)

    def test_changed_base_requires_regating_before_request(self):
        (self.root / 'base').write_text('new\n')
        out = self.request('alpha')
        self.assertEqual(0, out.returncode, out.stderr)
        self.assertIn('regate on the new base', out.stdout)
        self.assertFalse((self.root / 'alpha/pending/card.json').exists())


unittest.main()
