"""Exercise fm-run.sh's project merge turns with fixture-local endpoints."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv.pop(1))


class RunProjectTurns(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.engine = self.root / 'engine'
        self.home = self.root / 'home'
        shutil.copytree(ROOT / 'bin', self.engine / 'bin')
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        self.env.update(FM_HOME=str(self.home), FM_ROOT=str(self.engine), HERDR_ENV='0',
                        PATH=str(self.engine / 'bin') + os.pathsep + self.env['PATH'])
        (self.engine / 'config.yaml').write_text('default_project: alpha\nprojects:\n'
            '  alpha:\n    github: owner/alpha\n    base: main\n    required_check: ci\n'
            '  beta:\n    github: owner/beta\n    base: main\n    required_check: ci\n')
        for project in ('alpha', 'beta'):
            base = self.home / 'projects' / project
            (base / 'repo/.git').mkdir(parents=True)
            (base / 'repo/base').write_text('old\n')
            (base / 'tasks').mkdir()
            (base / 'state/decisions').mkdir(parents=True)
            self.open_pr(project, 'T-012')
        self.script('git', '''#!/usr/bin/env bash
[ "$1" = -C ] || exit 1
root="$2"; shift 2
case "$1 $2" in
  'rev-parse --show-toplevel') printf '%s\\n' "$root" ;;
  'rev-parse main^{commit}') cat "$root/base" ;;
  'remote get-url') printf 'https://github.com/owner/%s.git\\n' "$(basename "$(dirname "$root")")" ;;
  'branch --list') echo "${3%\\*}fixture" ;;
  *) exit 1 ;;
esac
''')
        # Keep production storage and merge-turn wiring; head authority is a fixture.
        with (self.engine / 'bin/fm-config.sh').open('a') as out:
            out.write('\nfm_binding() { echo fixture-head; }\n')
        for name in ('fm-dispatch.sh', 'fm-sync-prs.sh'):
            self.script(name, '#!/usr/bin/env bash\nexit 0\n')
        self.script('fm-gate.sh', '''#!/usr/bin/env bash
if [ -f "$FM_HOME/move-base" ]; then echo new > "$FM_TARGET_ROOT/base"; fi
exit 0
''')
        self.script('fm-decide.sh', '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args=sys.argv[1:]
def arg(key): return args[args.index(key)+1]
project=arg('--project'); task=arg('--task')
state=Path(os.environ['FM_STATE_DIR'])
assert state == Path(os.environ['FM_HOME'])/'projects'/project/'state'
card='D-'+project+'-'+task.replace('-', '')+'-1'
if '--allocate' in args: print(card)
else:
    assert arg('--expected-head') == 'fixture-head'
    (state/'pending').mkdir(exist_ok=True)
    (state/'pending'/(card+'.json')).write_text(json.dumps(dict(
        id=card, kind='merge', project=project, task=task)))
''')

    def script(self, name, body):
        path = self.engine / 'bin' / name
        path.write_text(body); path.chmod(0o755)

    def state(self, project):
        return self.home / 'projects' / project / 'state'

    def open_pr(self, project, task):
        (self.state(project) / 'events.jsonl').write_text(json.dumps(
            dict(type='pr_opened', project=project, task=task, pr=12)) + '\n')

    def run_turn(self, project):
        out = subprocess.run(['bash', str(self.engine / 'bin/fm-run.sh'), 'once',
            '--repo', str(self.engine), '--project', project], env=self.env,
            capture_output=True, text=True, timeout=30)
        self.assertEqual(0, out.returncode, out.stderr)
        return out.stdout

    def cards(self, project):
        return list((self.state(project) / 'pending').glob('*.json'))

    def test_run_holds_only_its_project_until_merge_outcome(self):
        self.assertIn('asking the captain', self.run_turn('alpha'))
        self.assertIn('asking the captain', self.run_turn('beta'))
        self.assertEqual(1, len(self.cards('beta')))
        self.open_pr('alpha', 'T-013')
        self.assertIn('pending merge', self.run_turn('alpha'))
        self.assertEqual(1, len(self.cards('alpha')))
        card = self.cards('alpha')[0]
        value = json.loads(card.read_text()); card.unlink()
        answer = self.state('alpha') / 'decisions' / card.name
        answer.write_text(json.dumps(dict(value, chosen='A')))
        self.assertIn('running merge', self.run_turn('alpha'))
        self.assertEqual([], self.cards('alpha'))
        answer.write_text(json.dumps(dict(value, chosen='A', merged=dict(ok=True))))
        self.assertIn('asking the captain', self.run_turn('alpha'))
        self.assertEqual(1, len(self.cards('alpha')))

    def test_run_captures_base_before_gating_and_refuses_moved_base(self):
        (self.home / 'move-base').touch()
        self.assertIn('regate on the new base', self.run_turn('beta'))
        self.assertEqual([], self.cards('beta'))


unittest.main()
