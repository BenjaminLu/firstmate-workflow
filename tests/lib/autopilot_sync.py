"""Port of PR synchronization: actual REST command and event-writer boundaries."""
import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

os.environ['HERDR_ENV'] = '0'
sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1))
sys.path.insert(0, str(ROOT / 'bin/lib'))
import fm_autopilot as A


def pull(number, branch, title, state='open', merged=None):
    return dict(number=number, head=dict(ref=branch, sha='a'*40), title=title,
                state=state, merged_at=merged, base=dict(ref='main', sha='b'*40))


class SyncTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.engine = self.root / 'engine'; self.engine.mkdir()
        self.home = self.root / 'home'
        (self.engine / 'config.yaml').write_text('default_project: firstmate-workflow\nprojects:\n'
            '  firstmate-workflow:\n    repo: .\n    github: owner/engine\n    base: main\n    required_check: ci\n'
            '  example-app:\n    github: owner/app\n    base: main\n    required_check: ci\n')
        gh = self.root / 'gh'
        gh.write_text('''#!/usr/bin/env python3
import json, pathlib, sys
root = pathlib.Path(__file__).resolve().parent
args = sys.argv[1:]
with (root/'calls').open('a') as out: out.write(json.dumps(args)+'\\n')
assert args[0] == 'api' and '--include' in args, args
repository, endpoint = args[1][6:].split('/', 2)[1:]
value = json.loads((root/(repository+'.json')).read_text())
if value == 'offline': print('unavailable', file=sys.stderr); sys.exit(1)
print('HTTP/2.0 200 OK\\nETag: "fixture"\\n')
if value == 'junk': print('not json'); sys.exit(0)
if endpoint.startswith('pulls?'): answer = value
elif endpoint.startswith('pulls/'):
    bits = endpoint.split('/')
    answer = next(p for p in value if str(p['number']) == bits[1]) if len(bits) == 2 else []
elif 'check-runs' in endpoint: answer = dict(total_count=0, check_runs=[])
elif '/status' in endpoint: answer = dict(sha='a'*40, total_count=0, statuses=[])
else: raise ValueError(endpoint)
print(json.dumps(answer))
''')
        gh.chmod(0o755)
        env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        env.update(FM_HOME=str(self.home), FM_ROOT=str(self.engine), FM_GH=str(gh), HERDR_ENV='0')
        environment = patch.dict(os.environ, env, clear=True); environment.start(); self.addCleanup(environment.stop)

    def pilot(self, project='firstmate-workflow'):
        state = self.engine / 'state' if project == 'firstmate-workflow' else self.home / 'projects' / project / 'state'
        state.mkdir(parents=True, exist_ok=True)
        return A.Pilot(dict(engine=str(self.engine), state=str(state), target=str(self.engine),
            tasks=str(self.engine / 'tasks'), project=project, evidence_project=project,
            external=False, repository='owner/' + ('engine' if project == 'firstmate-workflow' else 'app'), base='main'))

    def response(self, value, repo='engine'):
        (self.root / (repo + '.json')).write_text(json.dumps(value))

    def events(self, pilot):
        path = pilot.state / 'events.jsonl'
        return [json.loads(l) for l in path.read_text().splitlines()] if path.exists() else []

    def test_open_merge_close_logged_once_with_fields_and_actor(self):
        p = self.pilot()
        self.response([pull(8,'t-005-worker','T-005: worker','closed','now'), pull(9,'t-006-review','T-006: reviewer')])
        p.poll(); p.poll()
        rows = self.events(p)
        self.assertEqual([(r['type'], r['task'], r['pr']) for r in rows], [('merged','T-005',8),('pr_opened','T-006',9)])
        self.assertTrue(all(r['actor'] == 'github' and r['summary']['en'] and r['summary']['zh-TW'] for r in rows))
        self.response([pull(9,'t-006-review','T-006: reviewer','closed','now'), pull(10,'t-010-end','T-010: end','closed')])
        p.poll(); p.poll()
        self.assertEqual(sum(r['type']=='merged' and r['pr']==9 for r in self.events(p)), 1)
        self.assertEqual(sum(r['type']=='closed' and r['pr']==10 for r in self.events(p)), 1)
        self.pilot().poll()
        self.assertEqual(len(self.events(p)), 4, 'restart must not replay a terminal or open event')

    def test_failure_or_invalid_response_writes_no_event(self):
        p = self.pilot()
        for value in ('offline', 'junk'):
            self.response(value); p.poll()
            self.assertGreater(p.data['failures'], 0)
            self.assertEqual(self.events(p), [])

    def test_project_pair_keys_and_legacy_default_event(self):
        first, other = self.pilot(), self.pilot('example-app')
        (first.state / 'events.jsonl').write_text('{"type":"pr_opened","task":"T-004","pr":7}\n')
        self.response([pull(7,'t-004-engine','T-004: engine')])
        self.response([pull(7,'t-004-app','T-004: app','closed','now')], 'app')
        first.poll(); other.poll()
        self.assertEqual(len(self.events(first)), 1)
        self.assertEqual(self.events(other)[0]['project'], 'example-app')
        self.assertEqual(self.events(other)[0]['pr'], 7)
        self.response([pull(7,'t-004-app','T-004: app')], 'app')
        other.poll(); other.poll()
        self.assertEqual([r['type'] for r in self.events(other)], ['merged','pr_opened'])
        self.response('offline')
        self.response([pull(10,'t-010-app','T-010: selected')], 'app')
        first.poll(); other.poll()
        self.assertTrue(any(r['pr']==10 for r in self.events(other)))
        self.assertFalse(any(r['pr']==10 for r in self.events(first)))
        (self.root / 'calls').write_text('')
        other.poll()
        calls = (self.root / 'calls').read_text()
        self.assertIn('repos/owner/app/', calls)
        self.assertNotIn('repos/owner/engine/', calls, 'selected supervisor reads only its repository')

    def test_shared_grammar_branch_title_revert_long_number_and_legacy(self):
        p = self.pilot()
        self.response([pull(94,'sk-001-skill-update-firstmate','SK-001: update','closed','now'),
            pull(95,'board-fields','T-116: board'), pull(96,'t-105-revert','T-105: revert'),
            pull(98,'revert-90-t-105','Revert "T-105: sandbox"'), pull(99,'t-1170-other','T-1170: longer'),
            pull(100,'t004-old','other')])
        p.poll()
        self.assertEqual({r['pr']:r.get('task') for r in self.events(p)},
                         {94:'SK-001',95:'T-116',96:'T-105',98:None,99:'T-1170',100:'T-004'})

    def test_no_registry_records_no_project(self):
        (self.engine / 'config.yaml').write_text('vendor: mock\n')
        p = self.pilot(); p.ctx['project'] = ''
        self.response([pull(3,'t-003-old','T-003: old')])
        p.poll()
        self.assertEqual(self.events(p)[0]['task'], 'T-003')
        self.assertNotIn('project', self.events(p)[0])


if __name__ == '__main__': unittest.main()
