"""T-305 real external worker rounds that decide their door; local origin and
a scripted adapter only. Each test names the suite assertion it proves."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
os.environ['HERDR_ENV'] = '0'   # no real Herdr notice from a card this suite raises
root = Path(sys.argv[1])
sys.path.insert(0, str(root / 'bin/lib'))
from fm_onboard import approve, infer

TWO = dict(kind='two-way', reason='A revert of the merge undoes it.')
CONFIG = '''vendor: mock
concurrency: 3
door:
  base:
    - ".github/**"
    - "**/migrations/**"
    - "*.sql"
projects:
  app:
    github: owner/app
    base: trunk
    required_check: ci
'''


class DoorProjects(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='door-projects-')
        self.addCleanup(temporary.cleanup)
        self.scratch = Path(temporary.name).resolve()
        self.engine = self.scratch / 'engine'
        self.engine.mkdir()
        empty_home = self.scratch / 'empty-home'
        empty_home.mkdir()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('FM_', 'HERDR_', 'GIT_')) and k != 'GH_REPO'}
        self.env.update(HOME=str(empty_home), FM_HOME=str(self.scratch / 'private'),
                        FM_GITHUB_URL=str(self.scratch / 'remotes'), FM_ROOT=str(self.engine),
                        FM_PROJECT='app', FM_SESSION_PID=str(os.getpid()), FM_HOST='none',
                        FM_GIT_NAME='Fixture', FM_GIT_EMAIL='fixture@example.invalid',
                        HERDR_ENV='0', FM_TRANSPORT='direct', PYTHONDONTWRITEBYTECODE='1',
                        GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=str(self.scratch / 'gitconfig'),
                        FM_TEST_PROMPT=str(self.scratch / 'prompt.md'),
                        FM_TEST_MODE=str(self.scratch / 'mode'))
        (self.scratch / 'gitconfig').write_text('')
        for directory in ('bin', 'skills', '.githooks', 'i18n'):
            shutil.copytree(root / directory, self.engine / directory,
                            ignore=shutil.ignore_patterns('__pycache__'))
        (self.engine / 'config.yaml').write_text(CONFIG)
        adapter = self.engine / 'bin/adapters/mock.sh'
        adapter.write_text('''#!/usr/bin/env python3
import os, sys
from pathlib import Path
Path(os.environ['FM_TEST_PROMPT']).write_text(Path(sys.argv[2]).read_text())
tree = Path(sys.argv[3])
mode = Path(os.environ['FM_TEST_MODE']).read_text()
path = dict(build='src/feature', base='db/migrations/001.sql', odd='tools/new.sh')[mode]
(tree / path).parent.mkdir(parents=True, exist_ok=True)
(tree / path).write_text('round work\\n')
with open(sys.argv[4], 'a') as log:
    log.write('WORKER_COMPLETE:T-305\\n')
''')
        adapter.chmod(0o755)
        self.run_ok('git', 'init', '-q', '-b', 'main', str(self.engine))
        self.run_ok('git', '-C', str(self.engine), 'add', '.')
        self.run_ok('git', '-C', str(self.engine), '-c', 'user.name=Fixture', '-c',
                    'user.email=fixture@example.invalid', 'commit', '-qm', 'engine')
        self.remote = self.scratch / 'remotes/owner/app.git'
        self.remote.parent.mkdir(parents=True)
        self.run_ok('git', 'init', '-q', '--bare', '-b', 'trunk', str(self.remote))
        seed = self.scratch / 'seed'
        self.run_ok('git', 'clone', '-q', str(self.remote), str(seed))
        for path in ('src/base', 'db/schema'):
            (seed / path).parent.mkdir(parents=True, exist_ok=True)
            (seed / path).write_text('base\n')
        self.run_ok('git', '-C', str(seed), 'add', '-A')
        self.run_ok('git', '-C', str(seed), '-c', 'user.name=Fixture', '-c',
                    'user.email=fixture@example.invalid', 'commit', '-qm', 'base')
        self.run_ok('git', '-C', str(seed), 'push', '-q', 'origin', 'trunk')
        self.home = self.scratch / 'private/projects/app'
        self.home.mkdir(parents=True)
        evidence = dict(repository='owner/app', base='trunk', source='github', pulls=[], commits=[],
                        protection={'status': 'unknown'}, repository_info={
                            'allow_merge_commit': True, 'allow_squash_merge': False,
                            'allow_rebase_merge': False, 'delete_branch_on_merge': False})
        approve(self.home, evidence, infer(evidence), dict(confirmed=True, policy_confirmed=True,
                captain='captain', intent='Decide doors', product='Fixture', required_checks=['ci'],
                contract={'check': 'true'}, post='local'))
        (self.home / 'tasks').mkdir(exist_ok=True)
        (self.home / 'design.md').write_text('Private design.\n')
        self.state = self.home / 'state'
        self.state.mkdir(exist_ok=True)
        (self.state / 'events.jsonl').write_text(json.dumps(dict(
            type='greenlit', actor='captain', project='app', ts='2026-10-13T00:00:00Z', data={})) + '\n')
        gh = self.scratch / 'gh'
        gh.write_text('''#!/usr/bin/env python3
import sys
if sys.argv[1:3] == ['pr', 'create']: print('https://example.invalid/owner/app/pull/9')
elif sys.argv[1:3] == ['pr', 'list']: print('null')
else: sys.exit(1)
''')
        gh.chmod(0o755)
        self.env['FM_GH'] = str(gh)

    def run_ok(self, *args, **kwargs):
        p = subprocess.run(args, env=self.env, capture_output=True, text=True,
                           stdin=subprocess.DEVNULL, timeout=120, **kwargs)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        return p.stdout.strip()

    def spec(self, door):
        spec = dict(id='T-305', title='Private door fixture', depends_on=[], scope=['src/**', 'db/**', 'tools/**'],
                    acceptance=['Keep the door.'], public_title='Keep the door')
        if door is not None:
            spec['door'] = door
        (self.home / 'tasks/T-305.json').write_text(json.dumps(spec))

    def door(self, *args):
        return subprocess.run([sys.executable, str(self.engine / 'bin/lib/fm_door.py'), *args], env=self.env,
                              capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120)

    def answer(self, ident, task, chosen='A'):
        (self.state / 'decisions').mkdir(exist_ok=True)
        (self.state / 'decisions' / (ident + '.json')).write_text(json.dumps(dict(
            id=ident, task=task, project='app', kind='choice', chosen=chosen, ts='2026-10-13T01:00:00Z')))

    def decide(self, *args):
        return subprocess.run([str(self.engine / 'bin/fm-decide.sh'), '--repo', str(self.engine), *args],
                              env=self.env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120)

    def approve_list(self, globs):
        """The list goes in only through an answered card: propose, request, A, apply."""
        allocated = self.decide('--allocate', '--task', 'T-305', '--project', 'app')
        self.assertEqual(allocated.returncode, 0, allocated.stderr)
        ident = allocated.stdout.strip()
        p = self.door('propose-list', '--state', str(self.state), '--project', 'app', '--task', 'T-305',
                      '--id', ident, '--globs', json.dumps(globs), '--config', str(self.engine / 'config.yaml'))
        self.assertEqual(p.returncode, 0, p.stderr)
        details = json.loads(p.stdout)
        self.assertIn('src/keys/**', details['en']['after'])
        # the proposal is a card fm-decide accepts, not text that only looks like one
        built = self.scratch / 'list-details.json'
        built.write_text(p.stdout)
        requested = self.decide('--request', ident, '--task', 'T-305', '--project', 'app',
                                '--purpose', 'decision', '--details', str(built))
        self.assertEqual(requested.returncode, 0, requested.stdout + requested.stderr)
        self.assertTrue((self.state / 'pending' / (ident + '.json')).is_file(), 'the list card is pending')
        refused = self.door('apply-list', '--state', str(self.state), '--project', 'app', '--id', ident,
                            '--config', str(self.engine / 'config.yaml'))
        self.assertEqual(refused.returncode, 65, 'a list without a captain A is not written')
        self.assertNotIn('sensitive', (self.engine / 'config.yaml').read_text())
        self.answer(ident, 'T-305')
        (self.state / 'pending' / (ident + '.json')).unlink()
        p = self.door('apply-list', '--state', str(self.state), '--project', 'app', '--id', ident,
                      '--config', str(self.engine / 'config.yaml'))
        self.assertEqual(p.returncode, 0, p.stderr)

    def launch(self, mode='build'):
        Path(self.env['FM_TEST_MODE']).write_text(mode)
        prompt = Path(self.env['FM_TEST_PROMPT'])
        if prompt.exists():
            prompt.unlink()
        p = subprocess.run([str(self.engine / 'bin/fm-worker.sh'), '--repo', str(self.engine),
                            '--project', 'app', '--task', 'T-305'], env=self.env,
                           text=True, capture_output=True, stdin=subprocess.DEVNULL, timeout=300)
        self.output = p.stdout + p.stderr
        return p

    def pin(self):
        return json.loads((self.state / 'pins/T-305/1.json').read_text())

    def card(self, stop_file):
        ident = json.loads((self.state / 'door-stops/T-305' / stop_file).read_text())['card']
        pending = json.loads((self.state / 'pending' / (ident + '.json')).read_text())
        return ident, pending['details']

    def remote_has(self, path):
        refs = self.run_ok('git', '--git-dir=' + str(self.remote), 'for-each-ref', '--format=%(refname)', 'refs/heads/')
        branch = next((ref for ref in refs.split() if ref != 'refs/heads/trunk'), None)
        if not branch:
            return False
        return subprocess.run(['git', '--git-dir=' + str(self.remote), 'cat-file', '-e', branch + ':' + path],
                              env=self.env, capture_output=True).returncode == 0

    # door: external two-way builds first
    def test_external_two_way_builds_first(self):
        self.approve_list(['src/keys/**'])
        self.spec(TWO)
        p = self.launch()
        self.assertEqual(p.returncode, 0, self.output)
        pin = self.pin()
        self.assertEqual(pin['door'], dict(TWO, forced_by=None))
        self.assertEqual(pin['door_lists']['project'], ['src/keys/**'])
        self.assertEqual(pin['door_lists']['base'], ['.github/**', '**/migrations/**', '*.sql'])
        prompt = Path(self.env['FM_TEST_PROMPT']).read_text()
        self.assertIn('Pin v1 names a two-way door: A revert of the merge undoes it.', prompt)
        self.assertIn('This task takes the two-way path', prompt)
        self.assertNotIn('# Read first, then ask or plan', prompt)
        self.assertIn('The project keeps its own reviewers, CI and branch rules as they are.', prompt)
        self.assertTrue(self.remote_has('src/feature'), self.output)
        self.assertFalse((self.state / 'door-stops').exists(), 'a two-way round inside its lists writes no stop')

    # door: no list asks the captain
    def test_no_list_asks_the_captain(self):
        self.spec(TWO)
        p = self.launch()
        self.assertEqual(p.returncode, 65, self.output)
        self.assertFalse(Path(self.env['FM_TEST_PROMPT']).exists(), 'no round starts without a list')
        self.assertEqual(self.pin()['door_ask']['signal'], 'no-list')
        self.assertIn('Project app has no approved sensitive list.', self.output)
        ident, details = self.card('1.pin.json')
        self.assertIn('Project app has no approved sensitive list.', details['en']['why'][0]['text'])
        self.assertIn('專案 app 沒有核准的敏感清單。', details['zh-TW']['why'][0]['text'])
        self.assertEqual(details['en']['options']['A']['description'], 'Take the one-way path.')
        self.assertEqual(details['en']['options']['B']['description'], 'Revise the spec.')
        # the card is raised once
        again = self.door('card', '--state', str(self.state), '--task', 'T-305', '--project', 'app',
                          '--repo', str(self.engine))
        self.assertEqual((again.returncode, again.stdout.strip()), (0, ident), again.stderr)
        self.assertEqual(len(list((self.state / 'pending').glob('*.json'))), 1)
        # A takes the one-way path; the next round starts on it
        self.answer(ident, 'T-305')
        p = self.launch()
        self.assertEqual(p.returncode, 0, self.output)
        prompt = Path(self.env['FM_TEST_PROMPT']).read_text()
        self.assertIn('This task takes the one-way path', prompt)

    def test_hand_edited_list_counts_as_no_list(self):
        config = self.engine / 'config.yaml'
        status = lambda: json.loads(self.door('list-status', '--state', str(self.state), '--project', 'app',
                                              '--config', str(config)).stdout)
        self.assertEqual(status()['why'], 'missing')
        config.write_text(config.read_text() + '    door:\n      sensitive:\n        - "src/keys/**"\n')
        self.assertEqual((status()['sensitive'], status()['why']), (None, 'edited'), 'a hand-written list')
        config.write_text(CONFIG)
        self.approve_list(['src/keys/**'])
        self.assertEqual(status()['sensitive'], ['src/keys/**'])
        config.write_text(config.read_text().replace('src/keys/**', 'src/**'))
        self.assertEqual((status()['sensitive'], status()['why']), (None, 'edited'), 'a hand-edited list')
        import fm_door
        _, _, ask = fm_door.for_pin(dict(door=TWO, scope=['src/**']), config.read_text(), 'app',
                                    self.state, external=True)
        self.assertEqual(ask['signal'], 'edited-list')
        self.assertIn('is not the list the captain approved', ask['en'])

    # door: missing door asks the captain (the external half)
    def test_missing_door_asks_the_captain(self):
        self.approve_list(['src/keys/**'])
        self.spec(None)
        self.assertEqual(self.launch().returncode, 65, self.output)
        self.assertEqual(self.pin()['door_ask']['signal'], 'no-door')
        _, details = self.card('1.pin.json')
        self.assertIn('The spec names no door.', details['en']['why'][0]['text'])
        self.assertIn('spec 沒寫 door。', details['zh-TW']['why'][0]['text'])

    # door: unclassified path asks the captain
    def test_unclassified_path_asks_the_captain(self):
        self.approve_list(['src/keys/**'])
        self.spec(TWO)
        p = self.launch('odd')
        self.assertEqual(p.returncode, 0, self.output)
        self.assertTrue(self.remote_has('tools/new.sh'), 'the round that found the path is published')
        stop = json.loads((self.state / 'door-stops/T-305/1.json').read_text())
        self.assertEqual((stop['signal'], stop['path']), ('new-top', 'tools'))
        _, details = self.card('1.json')
        self.assertIn('The diff adds `tools`, a new top-level path that no list can classify.',
                      details['en']['why'][0]['text'])
        self.assertIn('diff 新增了 `tools`', details['zh-TW']['why'][0]['text'])
        self.assertNotEqual(details['en']['options']['A']['description'], 'Take the one-way path.',
                            'a stop found in a round offers no other path')
        held = self.door('stopped', '--state', str(self.state), '--task', 'T-305')
        self.assertEqual(held.returncode, 3, 'no further round starts on the pin')

    # door: base list applies to every project
    def test_base_list_applies_to_an_external_project(self):
        self.approve_list(['src/keys/**'])
        self.spec(TWO)
        self.assertEqual(self.launch('base').returncode, 0, self.output)
        stop = json.loads((self.state / 'door-stops/T-305/1.json').read_text())
        self.assertEqual((stop['signal'], stop['forced_by']), ('sensitive', 'db/migrations/001.sql'))
        self.assertIn('(`**/migrations/**`)', stop['en'])
        # a project cannot remove the base list: the registry refuses the key
        config = self.engine / 'config.yaml'
        config.write_text(config.read_text().replace('    door:\n', '    door:\n      base:\n        - "none"\n', 1))
        p = subprocess.run(['bash', '-c', '. "$1/bin/fm-config.sh"; fm_project_get app github "$1/config.yaml"',
                            '_', str(self.engine)], env=self.env, capture_output=True, text=True, timeout=60)
        self.assertNotEqual(p.returncode, 0, p.stdout)
        self.assertIn('no project can remove the engine door.base list', p.stderr)

    # an engine with no config.yaml pins an external task as before T-305
    def test_missing_engine_config_pins_as_before(self):
        from fm_spec_pins import Pins
        self.spec(TWO)
        (self.engine / 'config.yaml').unlink()
        target = self.scratch / 'target'
        self.run_ok('git', 'clone', '-q', '-b', 'trunk', str(self.remote), str(target))
        pins = Pins(dict(FM_ENGINE_ROOT=str(self.engine), FM_TARGET_ROOT=str(target), FM_STATE_DIR=str(self.state),
                         FM_EXTERNAL='1', FM_PROJECT='app', FM_BASE='trunk', FM_TASKS_DIR=str(self.home / 'tasks'),
                         FM_DESIGN=str(self.home / 'design.md')), 'T-305')
        pin = pins.create()
        self.assertEqual(pin['version'], 1)
        self.assertFalse({'door', 'door_lists', 'door_ask'} & set(pin), 'no door fields without an engine config')
        # nor does applying an answered list crash on a missing config: it refuses by name
        self.door('propose-list', '--state', str(self.state), '--project', 'app', '--task', 'T-305',
                  '--id', 'D-app-T305-91', '--globs', json.dumps(['src/keys/**']))
        self.answer('D-app-T305-91', 'T-305')
        p = self.door('apply-list', '--state', str(self.state), '--project', 'app', '--id', 'D-app-T305-91',
                      '--config', str(self.engine / 'config.yaml'))
        self.assertEqual(p.returncode, 65, p.stderr)
        self.assertIn('config.yaml has no projects: block', p.stderr)
        self.assertNotIn('Traceback', p.stderr)


    # a pin written before T-305 keeps its path (T-185: the old record format runs)
    def test_old_external_pin_keeps_one_way(self):
        from fm_spec_pins import Pins
        self.spec(TWO)
        config = self.engine / 'config.yaml'
        config.write_text(CONFIG.replace('door:\n  base:\n    - ".github/**"\n    - "**/migrations/**"\n'
                                         '    - "*.sql"\n', ''))
        self.assertNotIn('door:', config.read_text())
        target = self.scratch / 'target'
        self.run_ok('git', 'clone', '-q', '-b', 'trunk', str(self.remote), str(target))
        pin = Pins(dict(FM_ENGINE_ROOT=str(self.engine), FM_TARGET_ROOT=str(target), FM_STATE_DIR=str(self.state),
                        FM_EXTERNAL='1', FM_PROJECT='app', FM_BASE='trunk', FM_TASKS_DIR=str(self.home / 'tasks'),
                        FM_DESIGN=str(self.home / 'design.md')), 'T-305').create()
        self.assertFalse({'door_lists', 'door_ask'} & set(pin), 'the pin has the format from before T-305')
        config.write_text(CONFIG)
        p = self.launch()
        self.assertEqual(p.returncode, 0, self.output)
        self.assertEqual(self.pin()['version'], 1, 'the launcher keeps the old pin')
        self.assertNotIn('door_lists', self.pin())
        prompt = Path(self.env['FM_TEST_PROMPT']).read_text()
        # the prompt from before T-305: no door section, the external first round reads and plans
        self.assertNotIn('two-way path', prompt)
        self.assertNotIn('\n# The door\n', prompt)
        self.assertIn('# Read first, then ask or plan', prompt)
        self.assertFalse((self.state / 'door-stops').exists(), 'no stop on an old pin')
        self.assertFalse((self.state / 'pending').exists(), 'no card on an old pin')
        gate = subprocess.run([sys.executable, str(self.engine / 'bin/lib/fm_door.py'), 'gate', '--repo', str(target),
                               '--base', 'trunk', '--head', 'trunk'], input=json.dumps(self.pin()), env=self.env,
                              capture_output=True, text=True, timeout=120)
        self.assertEqual(gate.returncode, 0, gate.stderr)
        self.assertEqual((json.loads(gate.stdout)['kind'], json.loads(gate.stdout)['reason']),
                         ('one-way', 'An external project keeps the one-way path.'))

if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0], '-v', *sys.argv[2:]])
