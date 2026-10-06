#!/usr/bin/env bash
# Feature-owned tests; representative REST payloads:
# tests/lib/onboarding/repository.json
# tests/lib/onboarding/pulls.json
# tests/lib/onboarding/reviews.json
# tests/lib/onboarding/status.json
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
python3 - "$ROOT" <<'PY'
import base64
import copy
import importlib.util
import json
import os
import subprocess
from pathlib import Path
import sys
import tempfile
import unittest
sys.dont_write_bytecode = True
root = Path(sys.argv[1]); sys.path.insert(0, str(root / 'bin/lib'))
from fm_onboard import inspect_remote, infer, questions, render, approve, edit, drift, inspect_local, design_seed
from fm_conventions import read_policy, validate
fixtures = root / 'tests/lib/onboarding'
def payload(name): return json.loads((fixtures / (name + '.json')).read_text())
class Onboarding(unittest.TestCase):
    def setUp(self):
        self.calls = []
        def gh(endpoint):
            self.calls.append(endpoint)
            if endpoint == 'repos/consenlabs/tokenlon-mm-agent': return payload('repository')
            if '/protection' in endpoint: raise ValueError('HTTP 404')
            if '/pulls?' in endpoint: return payload('pulls')
            if endpoint.endswith('/reviews?per_page=100'): return payload('reviews')
            if endpoint.endswith('/pulls/164'): return dict(payload('pulls')[0], merged_by={'login':'maintainer','type':'User'}, comments=3, review_comments=2)
            if endpoint.endswith('/status?per_page=100'): return payload('status')
            if '/check-runs?' in endpoint: return {'check_runs': []}
            if endpoint.endswith('/languages'): return {'TypeScript': 100}
            if '/contents/' in endpoint: return {'encoding':'base64','content':base64.b64encode(b'# Repository policy\n').decode()}
            if '/comments?' in endpoint: return [{'body':'Please review / 請審查','user':{'login':'maintainer','type':'User'}}]
            raise AssertionError(endpoint)
        self.e = inspect_remote('consenlabs/tokenlon-mm-agent', gh)
        self.p = infer(self.e)
    def answers(self):
        return dict(captain='captain', intent='Adopt for agent work', product='Maintain agent',
                    confirmed=True, required_checks=['continuous-integration/drone/pr'],
                    policy_confirmed=True, contract={'setup':'npm ci','check':'npm test'},
                    land='card', review='external', post='local')
    def test_inspection_and_three_questions(self):
        self.assertEqual(self.e['protection']['status'], 'unknown')
        self.assertEqual(self.p['merge_method'], 'squash')
        self.assertEqual(self.p['review'], 'external')
        self.assertEqual(self.p['reviewers'], ['BB8-im','R2D2-im'])
        self.assertEqual(self.p['observed_statuses'], ['continuous-integration/drone/pr'])
        self.assertEqual(self.p['stacked_bases'], ['feature-parent'])
        self.assertEqual(self.p['authors'],{'author':'User'})
        self.assertEqual(self.p['mergers'],{'maintainer':'User'})
        self.assertEqual(self.p['reviewer_types']['BB8-im'],'Bot')
        self.assertEqual(self.p['comment_volume']['164']['comments'],3)
        self.assertIn('zh',self.p['conversation_languages'])
        self.assertEqual(len(questions(self.e, self.p)), 3)
        self.assertTrue(all(q['evidence'] and q['recommendation'] for q in questions(self.e,self.p)))
        self.assertTrue(all(x.startswith('repos/consenlabs/tokenlon-mm-agent') for x in self.calls))
        self.assertEqual(self.e['pulls'][0]['detail']['merged_by']['login'], 'maintainer')
    def test_missing_permission_fields_require_explicit_policy(self):
        e=copy.deepcopy(self.e)
        e['repository_info']={'full_name':e['repository'],'default_branch':e['base']}
        p=infer(e)
        for key in ('available_merge_methods','merge_method','delete_branch','required_checks'):
            self.assertEqual(p[key], 'unknown', key)
        self.assertEqual(p['visibility'],'unknown')
        e['pulls'][0]['detail']={'status':'unknown','reason':'HTTP 404'}
        self.assertEqual(infer(e)['merged_by']['164'],'unknown')
        self.assertEqual(infer(e)['comment_volume']['164']['comments'],'unknown')
        self.assertIn('unknown', questions(e,p)[2]['recommendation'])
        with tempfile.TemporaryDirectory() as t:
            with self.assertRaises(ValueError): approve(Path(t),e,p,self.answers())
            answers=dict(self.answers(),available_merge_methods=['merge'],merge_method='merge',delete_branch=False)
            approve(Path(t),e,p,answers)
            with self.assertRaises(ValueError): edit(Path(t),{'available_merge_methods':[]},'captain','invalid')
            with self.assertRaises(ValueError): edit(Path(t),{'merge_method':'squash'},'captain','disabled')
        e['repository_info'].update(allow_squash_merge=False,allow_merge_commit=False,allow_rebase_merge=False)
        with tempfile.TemporaryDirectory() as t:
            with self.assertRaises(ValueError): approve(Path(t),e,infer(e),dict(self.answers(),merge_method='squash',delete_branch=False))

    def test_confirmation_write_edit_drift(self):
        with tempfile.TemporaryDirectory() as t:
            home=Path(t)
            p=approve(home,self.e,self.p,self.answers())
            self.assertEqual((home/'design.md').read_text(), design_seed(home.name, p, self.answers()['contract']))
            (home/'design.md').write_text('firstmate edit\n')
            approve(home,self.e,self.p,self.answers())
            self.assertEqual((home/'design.md').read_text(), 'firstmate edit\n')
            path=home/'CONVENTIONS.md'
            self.assertEqual(read_policy(path)['land'],'card')
            self.assertIn('unknown',path.read_text())
            self.assertTrue((home/'state/config.yaml').exists())
            before=path.read_text()
            diff=edit(home, {'post':'comments'}, 'captain','Use public comments')
            self.assertIn('+post: comments',diff)
            self.assertEqual(read_policy(path)['post'],'comments')
            changed=copy.deepcopy(self.e)
            changed['protection']={'status':'known','value':{'required_pull_request_reviews':{'required_approving_review_count':2}}}
            text=drift(home,changed)
            self.assertIn('required_approving_review_count',text)
            self.assertEqual(read_policy(path)['post'],'comments')
            self.assertEqual(drift(home,changed),'')  # debounce identical proposal
            self.assertEqual((home/'design.md').read_text(), 'firstmate edit\n')
    def test_design_without_setup(self):
        with tempfile.TemporaryDirectory() as t:
            home=Path(t)
            answers=dict(self.answers(), contract={'check':'npm test'})
            p=approve(home,self.e,self.p,answers)
            text=(home/'design.md').read_text()
            self.assertEqual(text, design_seed(home.name, p, answers['contract']))
            self.assertNotIn('- Setup:', text)
            self.assertIn('- Check: npm test\n- Required checks: continuous-integration/drone/pr\n', text)
            self.assertEqual(design_seed(home.name, p, {'check':'npm test','setup':''}), text)
    def test_design_symlink_refused(self):
        for dangling in (False, True):
            with self.subTest(dangling=dangling), tempfile.TemporaryDirectory() as t:
                home=Path(t)/'project'
                home.mkdir()
                target=Path(t)/'target.md'
                if not dangling:
                    target.write_text('untouched\n')
                (home/'design.md').symlink_to(target)
                with self.assertRaisesRegex(ValueError, 'refusing symlink:'):
                    approve(home,self.e,self.p,self.answers())
                self.assertTrue((home/'design.md').is_symlink())
                if dangling:
                    self.assertFalse(target.exists())
                else:
                    self.assertEqual(target.read_text(), 'untouched\n')
    def test_fail_closed_policy(self):
        with tempfile.TemporaryDirectory() as t:
            home=Path(t)
            with self.assertRaises(ValueError): approve(home,self.e,self.p,dict(self.answers(),confirmed=False))
            p=approve(home,self.e,self.p,self.answers())
            for key,value in [('land','auto'),('merge_method','octopus'),('policy_confirmed',False),('required_checks',[])]:
                bad=dict(p); bad[key]=value
                with self.assertRaises(ValueError): validate(bad)
            with self.assertRaises(ValueError): read_policy(home/'missing.md')
            with self.assertRaises(ValueError): edit(home,{'repository':'other/repo'},'captain','wrong binding')
    def test_owned_schedule_and_status_evidence(self):
        import fm_conventions_watch as watcher
        from fm_project_checks import status_runs
        runs=status_runs(payload('status'), 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
        self.assertEqual(runs[0]['name'],'continuous-integration/drone/pr')
        self.assertEqual(runs[0]['status'],'completed')
        self.assertEqual(status_runs(payload('status'),'wrong-head'),[])
        with tempfile.TemporaryDirectory() as t:
            home=Path(t)
            approve(home,self.e,self.p,self.answers())
            changed=copy.deepcopy(self.e)
            changed['repository_info']['delete_branch_on_merge']=True
            calls=[]; wakes=[]
            from unittest.mock import patch
            with patch.dict(os.environ,{'FM_PROJECT':'app'}), patch.object(watcher,'registry_value',return_value=str(home)), patch.object(watcher,'project_names',return_value=['app']):
                def inspect(repo): calls.append(repo); return changed
                watcher.tick(root,clock=lambda:100,inspect=inspect,wake=lambda *x:wakes.append(x))
                watcher.tick(root,clock=lambda:101,inspect=inspect,wake=lambda *x:wakes.append(x))
                self.assertEqual(len(calls),1)
                self.assertEqual(len(wakes),1)
                self.assertIn('zh-TW',wakes[0][4]['summary'])
                self.assertFalse(read_policy(home/'CONVENTIONS.md')['delete_branch'])
    def test_empty_local_has_no_invented_contract_or_history(self):
        with tempfile.TemporaryDirectory() as t:
            e=inspect_local(Path(t)); p=infer(e)
            self.assertEqual(e['commits'],[])
            self.assertEqual(e['pulls'],[])
            self.assertEqual(e['remote'],'')
            self.assertEqual(len(questions(e,p)),3)
            self.assertNotIn('product',p)
            with self.assertRaises(ValueError): approve(Path(t)/'private',e,p,self.answers())
    def test_empty_initialized_repository_has_no_invented_history(self):
        with tempfile.TemporaryDirectory() as t:
            target = Path(t) / 'fresh'
            subprocess.run(['git', 'init', '-q', '-b', 'main', str(target)], check=True)
            e = inspect_local(target); p = infer(e)
            self.assertEqual(e['base'], 'main')
            self.assertEqual(e['commits'], [])
            self.assertEqual(e['pulls'], [])
            self.assertEqual(e['remote'], '')
            self.assertEqual(len(questions(e, p)), 3)
            self.assertNotIn('product', p)
            with self.assertRaises(ValueError):
                approve(Path(t) / 'private', e, p, self.answers())
            self.assertNotEqual(subprocess.run(
                ['git', '-C', str(target), 'rev-parse', '--verify', 'HEAD'],
                capture_output=True).returncode, 0)
            self.assertEqual(subprocess.check_output(
                ['git', '-C', str(target), 'remote'], text=True), '')
unittest.main(argv=['onboarding'],verbosity=2)
PY
assert_eq 0 "$?" "private onboarding infers evidence, bounds questions, confirms policy, edits and proposes drift"
finish
