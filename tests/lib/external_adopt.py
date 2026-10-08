"""Adoption contracts and real worker rounds on a local bare origin."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

os.environ['HERDR_ENV'] = '0'
sys.dont_write_bytecode = True
ROOT = Path(sys.argv[1])
sys.path.insert(0, str(ROOT / 'bin/lib'))
from external_rebuild import ExternalRebuild
from fm_evidence import Store
import hashlib


class AdoptionRounds(ExternalRebuild):
    def setUp(self):
        super().setUp()
        # Undo the fixture's conflicting base; adoption begins on a clean PR.
        self.git('reset', '--hard', 'trunk^')
        self.git('push', '--force', 'origin', 'trunk')
        self.base = self.git('rev-parse', 'HEAD')
        self.git('branch', 'human-feature', self.prev)
        self.git('push', 'origin', 'human-feature')
        self.view = dict(number=9, state='OPEN', isCrossRepository=False,
                         headRefName='human-feature', baseRefName='trunk', title='Human work')
        self.view_path = self.scratch / 'view.json'
        self.write_view()
        self.spec = dict(id='T-223', title='Private adoption', public_title='Continue feature',
                         public_summary='Continue the feature.', depends_on=[], scope=['app'],
                         acceptance=['Preserve human work.'],
                         adopt=dict(pr=9, head=self.prev, base='trunk'))
        self.write_spec()
        gh = Path(self.env['FM_GH'])
        gh.write_text('''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['FM_TEST_GH_LOG'], 'a') as log: log.write(json.dumps(args)+'\\n')
v = json.loads(Path(os.environ['FM_TEST_VIEW']).read_text())
def rev(ref):
    return subprocess.check_output(['git', '--git-dir='+os.environ['FM_TEST_REMOTE'],
                                   'rev-parse', ref], text=True).strip()
if args[:2] == ['pr', 'view']:
    if v.get('fail'): sys.exit(1)
    v['headRefOid'] = rev(v['headRefName'])
    subprocess.check_call(['git', '--git-dir='+os.environ['FM_TEST_REMOTE'],
                           'update-ref', 'refs/pull/9/head', v['headRefOid']])
    v['baseRefOid'] = rev(v['baseRefName'])
    if '--jq' in args: print(v.get(args[args.index('--jq')+1].lstrip('.'), ''))
    else: print(json.dumps(v))
elif args[:2] == ['pr', 'list']:
    if '--json' in args and 'isCrossRepository' in args[args.index('--json')+1]:
        rows = v.get('merged_parents', []) if '--state' in args and args[args.index('--state')+1] == 'merged' else v.get('open_heads', [v])
        print(json.dumps(rows))
    else: print('9')
elif args[:2] == ['pr', 'merge']: pass
elif args[0] == 'api':
    if '/check-runs?' in args[1]:
        print(json.dumps(dict(check_runs=[dict(id=1, name='ci', head_sha=rev(v['headRefName']), status='completed', conclusion='success')])))
    elif '/status?' in args[1]: print(json.dumps(dict(sha=rev(v['headRefName']), statuses=[])))
    else: print(json.dumps(dict(contexts=['ci'], checks=[])))
else: sys.exit(1)
''')
        self.env['FM_TEST_VIEW'] = str(self.view_path)
        adapter = self.engine / 'bin/adapters/mock.sh'
        adapter.write_text('''#!/usr/bin/env python3
import os, sys
from pathlib import Path
Path(os.environ['FM_TEST_PROMPT']).write_text(Path(sys.argv[2]).read_text())
app = Path(sys.argv[3])/'app'
app.write_text(app.read_text()+'worker addition\\n')
with open(sys.argv[4], 'a') as log: log.write('WORKER_COMPLETE:T-223\\n')
''')
        (self.scratch / 'git.jsonl').write_text('')

    def write_view(self):
        self.view_path.write_text(json.dumps(self.view))

    def write_spec(self):
        text = json.dumps(self.spec)
        (self.home / 'tasks/T-223.json').write_text(text)
        Store(self.state, 'app', 'T-223', external=True).append('spec-preflight', 1,
            'reviewer-adopt', self.base, '1. Adoption checked.\nSPEC-OK:T-223',
            spec_sha256=hashlib.sha256(text.encode()).hexdigest(), verdict='SPEC-OK',
            provenance={'level': 'legacy', 'vendor': 'claude'})

    def launch(self, pr=None, project='app'):
        args = [str(self.engine / 'bin/fm-worker.sh'), '--repo', str(self.engine),
                '--project', project, '--task', 'T-223']
        if pr is not None: args += ['--pr', str(pr)]
        result = subprocess.run(args, env=self.env, text=True, capture_output=True,
                                stdin=subprocess.DEVNULL, timeout=120)
        self.output = result.stdout + result.stderr
        return result

    def refusal(self, reason):
        result = self.launch()
        self.assertEqual(result.returncode, 65, self.output)
        self.assertIn(reason, self.output)
        self.assertFalse((self.scratch / 'prompt.md').exists(), self.output)
        calls = [json.loads(line) for line in (self.scratch / 'git.jsonl').read_text().splitlines()]
        self.assertFalse(any('push' in call for call in calls), calls)

    def test_adopt_human_branch_and_title_preserved(self):
        result = self.launch()
        self.assertEqual(result.returncode, 0, self.output)
        head = self.run_ok('git', '--git-dir='+str(self.remote), 'rev-parse', 'human-feature')
        self.assertNotEqual(head, self.prev)
        self.run_ok('git', '--git-dir='+str(self.remote), 'merge-base', '--is-ancestor', self.prev, head)
        self.assertIn('worker addition', self.run_ok('git', '--git-dir='+str(self.remote), 'show', head+':app'))
        calls = [json.loads(line) for line in (self.scratch / 'gh.jsonl').read_text().splitlines()]
        self.assertFalse(any(call[:2] in (['pr', 'create'], ['pr', 'edit']) for call in calls))
        self.assertIn(self.prev, (self.scratch / 'prompt.md').read_text())
        rows = [json.loads(line) for line in (self.state/'events.jsonl').read_text().splitlines()]
        pushed = [r for r in rows if r['type'] == 'commit_pushed']
        self.assertTrue(pushed)
        self.assertTrue(all(r['data']['adopt_pr'] == 9 for r in pushed))
        # Once pinned, private-file edits cannot redirect ownership.
        self.spec['adopt']['pr'] = 10
        (self.home/'tasks/T-223.json').write_text(json.dumps(self.spec))
        env = dict(self.env, FM_EXTERNAL='1', FM_ENGINE_ROOT=str(self.engine),
                   FM_TARGET_ROOT=str(self.home/'repo'), FM_STATE_DIR=str(self.state),
                   FM_TASKS_DIR=str(self.home/'tasks'), FM_DESIGN=str(self.home/'design.md'), FM_BASE='trunk')
        for number, owner in ((9, 'T-223'), (10, '')):
            result = subprocess.run(['python3', str(ROOT/'bin/lib/fm_adopt.py'), 'task-of', '--pr', str(number)],
                                    env=env, capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), owner)


    def test_adopt_closed(self):
        self.view['state'] = 'CLOSED'; self.write_view(); self.refusal('open')

    def test_adopt_fork(self):
        self.view['isCrossRepository'] = True; self.write_view(); self.refusal('fork')

    def test_adopt_retargeted(self):
        self.spec['adopt']['base'] = 'release'; self.write_spec()
        self.refusal('adopted PR base changed from release to trunk')

    def test_adopt_stacked(self):
        self.view['open_heads'] = [dict(number=8, headRefName='trunk', isCrossRepository=False)]
        self.write_view(); self.refusal('stacked on an unmanaged PR #8 or stacking not allowed')

    def test_adopt_wrong_title(self):
        self.view['title'] = 'T-999: other task'; self.write_view(); self.refusal('T-999')

    def test_adopt_wrong_branch(self):
        self.git('push', 'origin', 'human-feature:refs/heads/t-999-x')
        (self.scratch/'git.jsonl').write_text('')
        self.view['headRefName'] = 't-999-x'; self.write_view(); self.refusal('T-999')

    def test_adopt_unsupported_branch(self):
        self.git('push', 'origin', 'human-feature:refs/heads/human+feature')
        (self.scratch/'git.jsonl').write_text('')
        self.view['headRefName'] = 'human+feature'; self.write_view(); self.refusal('branch')

    def test_adopt_unreadable_view(self):
        self.view['fail'] = True; self.write_view(); self.refusal('branch')

    def test_adopt_duplicate(self):
        other = dict(self.spec, id='T-224')
        (self.home/'tasks/T-224.json').write_text(json.dumps(other))
        self.refusal('adopted by two tasks')

    def test_adopt_rewritten_head_even_with_legacy_push(self):
        self.spec['adopt']['head'] = 'a'*40; self.write_spec()
        with (self.state/'events.jsonl').open('a') as out:
            out.write(json.dumps(dict(type='commit_pushed', task='T-223', project='app', data={}))+'\n')
        self.refusal('approved adoption head')

    def test_adopt_pr_mismatch(self):
        result = self.launch(10)
        self.assertEqual(result.returncode, 65, self.output)
        self.assertIn('adopt', self.output)
        self.assertFalse((self.scratch/'prompt.md').exists())

    def test_adopt_self_project_refused_before_adapter_or_push(self):
        # Route through real self storage; setting FM_EXTERNAL alone would be
        # overwritten by fm_storage_init. Preserve the external fixture too.
        config = self.engine / 'config.yaml'
        config.write_text(config.read_text() + '\n  self:\n    repo: .\n'
                          '    github: owner/engine\n    base: main\n    required_check: ci\n')
        tasks = self.engine / 'design/tasks'; tasks.mkdir(parents=True)
        text = json.dumps(self.spec)
        (tasks / 'T-223.json').write_text(text)
        state = self.engine / 'state'
        Store(state, 'self', 'T-223', external=False).append('spec-preflight', 1,
            'reviewer-adopt', self.base, '1. Worker refusal fixture.\nSPEC-OK:T-223',
            spec_sha256=hashlib.sha256(text.encode()).hexdigest(), verdict='SPEC-OK',
            provenance={'level': 'legacy', 'vendor': 'claude'})
        result = self.launch(project='self')
        self.assertEqual(result.returncode, 65, self.output)
        self.assertIn('adopt is only supported for external projects', self.output)
        self.assertFalse((self.scratch / 'prompt.md').exists(), self.output)
        calls = [json.loads(line) for line in (self.scratch / 'git.jsonl').read_text().splitlines()]
        self.assertFalse(any('push' in call for call in calls), calls)

    def test_adopt_scope_covers_human_commits(self):
        self.spec['scope'] = ['other']; self.write_spec(); self.refusal('app')

    def test_adopt_untagged_push_allows_later_rewrite(self):
        result = self.launch()
        self.assertEqual(result.returncode, 0, self.output)
        # Keep only the first, PR-untagged commit_pushed. The later emit may
        # never happen when a launcher dies immediately after its push.
        path = self.state/'events.jsonl'
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        rows = [r for r in rows if r['type'] != 'commit_pushed' or not r.get('pr')]
        self.assertTrue(any(r['type'] == 'commit_pushed' and r['data'].get('adopt_pr') == 9 for r in rows))
        path.write_text(''.join(json.dumps(r)+'\n' for r in rows))
        self.git('fetch', 'origin', 'human-feature')
        self.git('checkout', '-B', 'rebased', 'FETCH_HEAD')
        # A squash onto a changed base stands in for external catch-up. It
        # deliberately removes the originally approved human commit identity.
        content = (self.seed/'app').read_text()
        self.git('checkout', 'trunk')
        (self.seed/'base-new').write_text('base'); self.commit('base advance')
        self.git('push', 'origin', 'trunk')
        self.git('checkout', '-B', 'rebased')
        (self.seed/'app').write_text(content); self.commit('rebuild external PR')
        self.git('push', '--force-with-lease', 'origin', 'HEAD:human-feature')
        # The real autopilot also synchronizes its managed ref and clean tree.
        managed = self.home/'worktrees/T-223'
        self.run_ok('git', '-C', str(managed), 'fetch', 'origin', 'human-feature')
        self.run_ok('git', '-C', str(managed), 'reset', '--keep', 'FETCH_HEAD')
        result = self.launch()
        self.assertEqual(result.returncode, 0, self.output)

    def test_adopt_absent_does_not_precheck_scope(self):
        del self.spec['adopt']; self.spec['scope'] = ['other']; self.write_spec()
        result = self.launch(9)
        self.assertEqual(result.returncode, 0, self.output)
        self.assertTrue((self.scratch/'prompt.md').exists())

    def test_adopt_rebuild_and_next_round(self):
        (self.seed/'base-only').write_text('base move\n'); self.commit('move base')
        self.git('push', 'origin', 'trunk')
        result = self.launch()
        self.assertEqual(result.returncode, 0, self.output)
        calls = [json.loads(line) for line in (self.scratch/'git.jsonl').read_text().splitlines()]
        self.assertTrue(any('--force-with-lease=refs/heads/human-feature:'+self.prev in call for call in calls))
        result = self.launch()
        self.assertEqual(result.returncode, 0, self.output)


class Authority(unittest.TestCase):
    def setUp(self):
        import fm_adopt
        self.adopt = fm_adopt
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = dict(FM_EXTERNAL='1', FM_TASKS_DIR=str(self.root), FM_ENGINE_ROOT=str(ROOT),
                        FM_TARGET_ROOT=str(ROOT), FM_STATE_DIR=str(self.root/'state'),
                        FM_PROJECT='app', FM_BASE='main', FM_BINDING_REPOSITORY='owner/app', FM_DESIGN=str(self.root/'design.md'))
        self.value = dict(pr=9, head='a'*40, base='release')
        gh = patch.object(self.adopt.binding, 'github', return_value=[])
        gh.start(); self.addCleanup(gh.stop)

    def test_adopt_managed_stack_and_effective_base(self):
        spec = dict(id='T-1', adopt=self.value, depends_on=['T-2'])
        (self.root/'T-1.json').write_text(json.dumps(spec))
        (self.root/'T-2.json').write_text(json.dumps(dict(
            id='T-2', adopt=dict(pr=8, head='b'*40, base='main'))))
        parent = dict(number=8, headRefName='release', isCrossRepository=False,
                      baseRefName='main')
        view = dict(state='OPEN', isCrossRepository=False, headRefName='human',
                    headRefOid='a'*40, baseRefName='release', title='Human change')
        policy = dict(stacking='allowed')
        def github(repo, *args):
            return [parent] if args[args.index('--state')+1] == 'merged' or view['baseRefName'] == 'release' else []
        with patch('fm_conventions.read_policy', return_value=policy), \
             patch.object(self.adopt.binding, 'github', side_effect=github), \
             patch.object(self.adopt.binding, 'git', return_value=''):
            # FAIL-FIRST: allowed adopted stack is accepted instead of T-237 refusal.
            self.adopt.check(view, self.value, 'T-1', self.env, self.root, False, [parent])
            self.assertEqual(self.adopt.effective_base(view, self.value, self.env, 'T-1', 'owner/app'), 'release')
            policy['stacking'] = 'hold'
            with self.assertRaisesRegex(ValueError, 'stacked adopted PR requires confirmed stacking policy'):
                self.adopt.effective_base(view, self.value, self.env, 'T-1', 'owner/app')
            with self.assertRaisesRegex(ValueError, 'stacked on an unmanaged PR #8 or stacking not allowed'):
                self.adopt.check(view, self.value, 'T-1', self.env, self.root, False, [parent])
            policy['stacking'] = 'allowed'
            for dependencies in ([], ['T-3']):
                (self.root/'T-1.json').write_text(json.dumps(dict(spec, depends_on=dependencies)))
                with self.assertRaisesRegex(ValueError, 'stacked on an unmanaged PR #8'):
                    self.adopt.check(view, self.value, 'T-1', self.env, self.root, False, [parent])
            (self.root/'T-1.json').write_text(json.dumps(spec))
            (self.root/'T-2.json').unlink()
            with self.assertRaisesRegex(ValueError, 'stacked on an unmanaged PR #8'):
                self.adopt.check(view, self.value, 'T-1', self.env, self.root, False, [parent])
            (self.root/'T-2.json').write_text(json.dumps(dict(id='T-2', adopt=dict(pr=8, head='b'*40, base='main'))))
            view['baseRefName'] = 'main'
            # FAIL-FIRST: a retarget alone is not a verified restack.
            with self.assertRaisesRegex(ValueError, 'parent merged; run bin/lib/fm-restack.sh'):
                self.adopt.effective_base(view, self.value, self.env, 'T-1', 'owner/app')
            state = Path(self.env['FM_STATE_DIR']); state.mkdir()
            event = dict(project='app', task='T-1', type='commit_pushed', data=dict(adopt_pr=9, restacked=True))
            for invalid in (dict(event, project='other'), dict(event, task='T-2'),
                            dict(event, data=dict(adopt_pr=8, restacked=True)), dict(event, data=dict(adopt_pr=9))):
                (state/'events.jsonl').write_text(json.dumps(invalid)+'\n')
                with self.assertRaisesRegex(ValueError, 'parent merged'):
                    self.adopt.effective_base(view, self.value, self.env, 'T-1', 'owner/app')
            (state/'events.jsonl').write_text(json.dumps(event)+'\n')
            self.assertEqual(self.adopt.effective_base(view, self.value, self.env, 'T-1', 'owner/app'), 'main')
            view['baseRefName'] = 'unrelated'
            # REGRESSION: unrelated retargets still require new approval.
            with self.assertRaisesRegex(ValueError, 'adopted PR base changed'):
                self.adopt.effective_base(view, self.value, self.env, 'T-1', 'owner/app')

    def test_adopt_task_grammar_parent(self):
        value = dict(self.value, base='t-002-parent')
        (self.root/'T-1.json').write_text(json.dumps(dict(id='T-1', adopt=value, depends_on=['T-002'])))
        view = dict(state='OPEN', isCrossRepository=False, headRefName='human',
                    headRefOid='a'*40, baseRefName=value['base'], title='Human change')
        parent = dict(number=8, headRefName=value['base'], isCrossRepository=False)
        with patch('fm_conventions.read_policy', return_value=dict(stacking='allowed')), \
             patch.object(self.adopt.binding, 'github', return_value=[parent]), \
             patch.object(self.adopt.binding, 'git', return_value=''):
            # FAIL-FIRST: canonical task grammar remains a managed-parent resolver.
            self.adopt.check(view, value, 'T-1', self.env, self.root, False, [parent])

    def test_adopt_pinned_adoption_never_uses_draft(self):
        (self.root/'T-1.json').write_text(json.dumps(dict(id='T-1', adopt=self.value)))
        # FAIL-FIRST: restack authority needs a pin, even when a draft exists.
        self.assertIsNone(self.adopt.pinned_adoption(self.env, 'T-1'))
        pin = dict(snapshots=dict(spec=dict(text=json.dumps(dict(id='T-1', adopt=self.value)))))
        with patch.object(self.adopt.Pins, 'resolve', return_value=pin):
            self.assertEqual(self.adopt.pinned_adoption(self.env, 'T-1'), self.value)

    def test_adopt_self_does_not_touch_pins(self):
        with patch.object(self.adopt, 'Pins', side_effect=AssertionError('must not build Pins')):
            self.assertIsNone(self.adopt.adoption(dict(FM_EXTERNAL='0'), 'T-1'))
            self.assertIsNone(self.adopt.authorized_spec(dict(FM_EXTERNAL='1'), 'T-1'))

    def test_adopt_missing_and_before_pin(self):
        self.assertIsNone(self.adopt.adoption(self.env, 'T-1'))
        (self.root/'T-1.json').write_text(json.dumps(dict(adopt=self.value)))
        self.assertEqual(self.adopt.adoption(self.env, 'T-1'), self.value)

    def test_adopt_incomplete_pin_environment_does_not_touch_pins(self):
        with patch.object(self.adopt, 'Pins', side_effect=AssertionError('must not build Pins')):
            self.assertIsNone(self.adopt.adoption(
                dict(FM_EXTERNAL='1', FM_TASKS_DIR=str(self.root)), 'T-1'))
            for key in ('FM_ENGINE_ROOT', 'FM_TARGET_ROOT', 'FM_STATE_DIR',
                        'FM_TASKS_DIR', 'FM_DESIGN'):
                for value in (None, ''):
                    with self.subTest(key=key, value=value):
                        env = dict(self.env)
                        if value is None:
                            del env[key]
                        else:
                            env[key] = value
                        self.assertIsNone(self.adopt.authorized_spec(env, 'T-1'))
                        self.assertIsNone(self.adopt.adoption(env, 'T-1'))

    def test_adopt_pin_wins_and_errors_are_isolated(self):
        (self.root/'T-1.json').write_text(json.dumps(dict(adopt=dict(self.value, pr=10))))
        pin = dict(snapshots=dict(spec=dict(text=json.dumps(dict(adopt=self.value)))))
        with patch.object(self.adopt.Pins, 'resolve', return_value=pin):
            self.assertEqual(self.adopt.scan(self.env)[0], {9: 'T-1'})
        empty_pin = dict(snapshots=dict(spec=dict(text='{"id":"T-1"}')))
        with patch.object(self.adopt.Pins, 'resolve', return_value=empty_pin):
            self.assertIsNone(self.adopt.adoption(self.env, 'T-1'))
        (self.root/'T-2.json').write_text('{broken')
        single, duplicates, errors = self.adopt.scan(self.env)
        self.assertEqual(single, {10: 'T-1'}); self.assertIn('T-2', errors)
        with patch.object(self.adopt.Pins, 'resolve', side_effect=ValueError('corrupt pin')):
            single, duplicates, errors = self.adopt.scan(self.env)
            self.assertIn(10, duplicates)
            self.assertIn('adoption unreadable for T-1', self.adopt.duplicate_reason(duplicates[10]))

    def test_prefixed_branch_adoption_preserves_task_ownership(self):
        view = dict(state='OPEN', isCrossRepository=False, headRefName='feature/t-001-x',
                    headRefOid='a'*40, baseRefName='release', title='Public change')
        with patch.object(self.adopt, 'scan', return_value=({}, {}, {})):
            self.adopt.check(view, self.value, 'T-001', self.env, self.root, True, [])
            with self.assertRaisesRegex(ValueError, 'names another task'):
                self.adopt.check(view, self.value, 'T-002', self.env, self.root, True, [])

    def test_adopt_check_self_and_protected_heads(self):
        view = dict(state='OPEN', isCrossRepository=False, headRefName='human',
                    headRefOid='a'*40, baseRefName='release', title='Human change')
        with self.assertRaisesRegex(ValueError, 'external projects'):
            self.adopt.check(view, self.value, 'T-1', dict(FM_EXTERNAL='0'), self.root, False, [])
        for branch in ('release', 'main', 'master'):
            with self.subTest(branch=branch), self.assertRaisesRegex(ValueError, 'protected base'):
                self.adopt.check(dict(view, headRefName=branch), self.value, 'T-1', self.env, self.root, False, [])

    def test_adopt_preflight_validation(self):
        from fm_spec_preflight import prompt
        spec = dict(id='T-1', scope=['app'], acceptance=['Work'], public_title='Improve feature',
                    public_summary='Improve the feature.', adopt=self.value)
        for value in [None, {}, dict(self.value, pr=True), dict(self.value, pr=0),
                      dict(self.value, head='bad'), dict(self.value, extra=1),
                      *[dict(self.value, base=b) for b in ['', '-x', 'a b', 'a..b', 'a~b', 'a^b', 'a:b', 'a\\b']]]:
            with self.subTest(value=value), patch.dict(os.environ, FM_EXTERNAL='1'):
                with self.assertRaisesRegex(ValueError, 'adopt'):
                    prompt('T-1', json.dumps(dict(spec, adopt=value)).encode(), 'main')
        with patch.dict(os.environ, FM_EXTERNAL='0'):
            with self.assertRaisesRegex(ValueError, 'adopt'):
                prompt('T-1', json.dumps(spec).encode(), 'main')


class BaseBinding(AdoptionRounds):
    def binding_env(self):
        return dict(self.env, FM_ENGINE_ROOT=str(self.engine), FM_TARGET_ROOT=str(self.seed),
                    FM_TASKS_DIR=str(self.home/'tasks'), FM_STATE_DIR=str(self.state),
                    FM_DESIGN=str(self.home/'design.md'), FM_EXTERNAL='1',
                    FM_BASE='trunk', FM_BINDING_REPOSITORY='owner/app', FM_EVIDENCE_PROJECT='app')

    def binding(self, mode, *args):
        return subprocess.run(['python3', str(ROOT/'bin/lib/fm_binding.py'), mode,
                               '--task', 'T-223', '--pr', '9', *args],
                              env=self.binding_env(), capture_output=True, text=True, timeout=120)

    def release_base(self):
        self.git('branch', 'release', 'trunk')
        self.git('push', 'origin', 'release')
        self.view['baseRefName'] = 'release'; self.write_view()
        self.spec['adopt']['base'] = 'release'; self.write_spec()

    def test_base_sync_and_unpublished_ref(self):
        self.release_base()
        self.git('checkout', '-b', 'remote-release', 'release')
        (self.seed/'new-base').write_text('new base'); self.commit('advance release')
        remote = self.git('rev-parse', 'HEAD')
        self.git('push', 'origin', 'HEAD:release')
        result = self.binding('base')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'release')
        self.assertEqual(self.git('rev-parse', 'release'), remote)
        self.git('checkout', 'release')
        (self.seed/'unpublished').write_text('private'); self.commit('unpublished')
        result = self.binding('base')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unpublished local commits', result.stderr)

    def test_base_retarget_refuses_every_reader_before_sync(self):
        # REGRESSION: an unrelated base change still refuses every reader.
        self.release_base()
        self.git('push', 'origin', 'trunk:refs/heads/retarget')
        self.view['baseRefName'] = 'retarget'; self.write_view()
        for mode in ('base', 'local-gate-base', 'head', 'checks', 'ready', 'candidate'):
            with self.subTest(mode=mode):
                result = self.binding(mode, '--head', self.prev, '--branch', 'human-feature')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('adopted PR base changed from release to retarget', result.stderr)
        refs = self.git('for-each-ref', '--format=%(refname)', 'refs/heads/retarget')
        self.assertEqual(refs, '')

    def test_base_restack_transition_all_readers(self):
        import contextlib
        import io
        import fm_binding as binding
        import fm_evidence
        from types import SimpleNamespace
        self.release_base()
        self.spec['depends_on'] = ['T-222']; self.write_spec()
        (self.home/'tasks/T-222.json').write_text(json.dumps(dict(self.spec, id='T-222',
            adopt=dict(pr=8, head=self.base, base='trunk'))))
        self.git('push', 'origin', 'trunk:refs/heads/next', ':refs/heads/release')
        self.view.update(baseRefName='next', merged_parents=[dict(number=8, headRefName='release',
                          baseRefName='next', isCrossRepository=False)])
        self.write_view()
        checks = [dict(id=1, name='ci', head_sha=self.prev, status='completed', conclusion='success')]
        source = {k: '' for k in ('spec_sha256', 'contract_sha256', 'conventions_sha256', 'patch', 'files')}
        record = dict(kind='readiness', head=self.prev, pr=9, repository='owner/app',
                      gates=[g['name'] for g in binding.gate_list()['gates']], checks=checks,
                      verdict_signature='verdict', gate_base=self.base, review=dict(binding=source))
        with patch.dict(os.environ, self.binding_env(), clear=True), \
             patch.object(fm_evidence, 'Store', return_value=SimpleNamespace(records=lambda: [record])), \
             patch.object(binding, 'selected_review', return_value=({'signature': 'verdict'}, None)), \
             patch.object(binding, 'source_binding', return_value=source):
            for published in (False, True):
                if published:
                    with (self.state/'events.jsonl').open('a') as out:
                        out.write(json.dumps(dict(type='commit_pushed', project='app', task='T-223',
                                                 data=dict(adopt_pr=9, restacked=True)))+'\n')
                for mode in ('base', 'head', 'candidate', 'required_checks'):
                    with self.subTest(published=published, mode=mode), \
                         patch.object(sys, 'argv', ['binding', mode, '--task', 'T-223', '--pr', '9',
                                                  '--branch', 'human-feature', '--head', self.prev]), \
                         contextlib.redirect_stdout(io.StringIO()) as output:
                        def invoke():
                            if mode == 'required_checks':
                                return binding.required_checks(self.seed, 'owner/app', 9, self.prev, task='T-223')
                            return binding.main()
                        if not published:
                            # FAIL-FIRST: retarget alone cannot authorize any reader.
                            with self.assertRaisesRegex(ValueError, 'parent merged; run bin/lib/fm-restack.sh'): invoke()
                        else:
                            result = invoke()
                            if mode == 'base': self.assertEqual(output.getvalue().strip(), 'next')
                            elif mode == 'head': self.assertEqual(output.getvalue().strip(), self.prev)
                            elif mode == 'candidate': self.assertEqual(json.loads(output.getvalue())['gate_base'], self.base)
                            else: self.assertEqual(result, checks)
            self.assertEqual(self.git('rev-parse', 'next'), self.base)
        calls = [json.loads(line) for line in (self.scratch/'git.jsonl').read_text().splitlines()]
        self.assertFalse(any('fetch' in call and any('refs/heads/release' in arg for arg in call) for call in calls))

    def test_base_required_single_adoption_with_unrelated_open_parent(self):
        # REGRESSION: a later release PR is not the task's managed dependency.
        self.release_base()
        self.view['open_heads'] = [dict(number=8, headRefName='release', isCrossRepository=False)]
        self.write_view()
        result = self.binding('base')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'release')
        result = self.binding('checks', '--head', self.prev)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)[0]['name'], 'ci')

    def test_base_candidate_refuses_moved_gate_base(self):
        import fm_binding as binding
        import fm_evidence
        from types import SimpleNamespace
        self.release_base()
        self.git('checkout', '-b', 'remote-release', 'release')
        (self.seed/'new-base').write_text('moved'); self.commit('base advanced')
        self.git('push', 'origin', 'HEAD:release')
        record = dict(kind='readiness', head=self.prev, pr=9, repository='owner/app',
                      gates=[g['name'] for g in binding.gate_list()['gates']], checks=[{'id': 1}],
                      verdict_signature='verdict', gate_base=self.base)
        with patch.dict(os.environ, self.binding_env(), clear=True), \
             patch.object(sys, 'argv', ['binding', 'candidate', '--task', 'T-223', '--pr', '9', '--head', self.prev]), \
             patch.object(fm_evidence, 'Store', return_value=SimpleNamespace(records=lambda: [record])), \
             patch.object(binding, 'required_checks', return_value=record['checks']), \
             patch.object(binding, 'selected_review', return_value=({'signature': 'verdict'}, None)):
            with self.assertRaisesRegex(ValueError, 'candidate gate base moved; refresh gates'):
                binding.main()
        self.assertEqual(self.git('rev-parse', 'release'), self.git('rev-parse', 'remote-release'))

    def test_base_required_checks_hold_exemption_and_pin(self):
        import fm_binding as binding
        import fm_adopt
        view = dict(self.view, headRefOid=self.prev, baseRefOid='b'*40, baseRefName='release')
        def github(repo, *args):
            if args[:2] == ('pr', 'list'): return []
            if args[0] == 'pr': return view
            if '/check-runs?' in args[1]:
                return dict(check_runs=[dict(id=1, name='ci', head_sha=self.prev,
                                             status='completed', conclusion='success')])
            if '/status?' in args[1]: return dict(sha=self.prev, statuses=[])
            return dict(contexts=['ci'], checks=[])
        pinned = dict(snapshots=dict(spec=dict(text=json.dumps(dict(
            id='T-223', adopt=dict(pr=9, head=self.prev, base='release'))))))
        with patch.dict(os.environ, self.binding_env(), clear=True), \
             patch.object(binding, 'github', side_effect=github), \
             patch.object(binding, 'verified_base', return_value='release'), \
             patch.object(fm_adopt.Pins, 'resolve', return_value=pinned):
            # Mutable draft still says trunk. Only the pin exempts release.
            self.assertEqual(binding.required_checks(self.seed, 'owner/app', 9, self.prev,
                                                      task='T-223')[0]['name'], 'ci')
            with self.assertRaisesRegex(ValueError, 'stacked PR base'):
                binding.required_checks(self.seed, 'owner/app', 9, self.prev)
            view['baseRefName'] = 'other'
            with self.assertRaisesRegex(ValueError, 'adopted PR base changed'):
                binding.required_checks(self.seed, 'owner/app', 9, self.prev, task='T-223')


class AdoptedRestack(BaseBinding):
    def prepare_stack(self, retargeted=False, pinned=True, parent_adopted=True, lost_head=False):
        self.git('checkout', '-b', 'human-parent', 'trunk')
        (self.seed/'parent-file').write_text('parent'); self.commit('parent')
        self.parent_head = self.git('rev-parse', 'HEAD')
        self.git('checkout', '-b', 'human-child')
        (self.seed/'child-file').write_text('child'); self.commit('child')
        self.child_head = self.git('rev-parse', 'HEAD')
        # Replace the inherited fixture's PR 9 lineage only in the temporary bare origin.
        self.git('push', 'origin', 'human-parent', 'human-child', '+human-child:refs/pull/9/head', 'human-parent:refs/pull/8/head')
        self.git('checkout', 'trunk'); self.git('merge', '--squash', 'human-parent'); self.commit('squash parent')
        self.base = self.git('rev-parse', 'HEAD'); self.git('push', 'origin', 'trunk')
        self.target = self.home/'repo'
        self.run_ok('git', 'clone', '--single-branch', '--branch', 'trunk', self.remote.as_uri(), str(self.target))
        self.run_ok('git', '-C', str(self.target), 'remote', 'set-url', 'origin', str(self.remote))
        self.run_ok('git', '-C', str(self.target), 'config', 'user.name', 'Fixture')
        self.run_ok('git', '-C', str(self.target), 'config', 'user.email', 'fixture@example.invalid')
        policy = self.home/'CONVENTIONS.md'
        policy.write_text(policy.read_text().replace('stacking: hold', 'stacking: allowed').replace('delete_branch: false', 'delete_branch: true'))
        self.spec['adopt'] = dict(pr=9, head=self.prev if lost_head else self.child_head, base='human-parent')
        self.spec['depends_on'] = ['T-222']; self.write_spec()
        if parent_adopted:
            (self.home/'tasks/T-222.json').write_text(json.dumps(dict(self.spec, id='T-222', depends_on=[],
                adopt=dict(pr=8, head=self.parent_head, base='trunk'))))
        self.view = dict(baseRefName='trunk' if retargeted else 'human-parent', parent_head=self.parent_head)
        self.write_view()
        Path(self.env['FM_GH']).write_text('''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['FM_TEST_GH_LOG'], 'a') as out: out.write(json.dumps(args)+'\\n')
path = Path(os.environ['FM_TEST_VIEW']); view = json.loads(path.read_text())
def rev(ref):
    return subprocess.check_output(['git', '--git-dir='+os.environ['FM_TEST_REMOTE'], 'rev-parse', ref], text=True).strip()
if args[:2] == ['pr', 'view']:
    if args[2] == '8':
        print(json.dumps(dict(number=8, state='MERGED', headRefName='human-parent', headRefOid=view['parent_head'], baseRefName='trunk', isCrossRepository=False, title='T-222: parent')))
    else:
        child = dict(number=9, state='OPEN', headRefName='human-child', headRefOid=rev('human-child'), baseRefName=view['baseRefName'], baseRefOid=rev(view['baseRefName']), isCrossRepository=False, title='Human change')
        count = view.get('reads', 0) + 1
        view['reads'] = count; path.write_text(json.dumps(view))
        child.update(view.get('identity', {}) if count == 1 else view.get('changed_identity', view.get('identity', {})))
        if child.get('isCrossRepository') == 'missing': child.pop('isCrossRepository')
        fields = args[args.index('--json')+1].split(',')
        print(json.dumps({key: child[key] for key in fields if key in child}))
elif args[:2] == ['pr', 'edit']:
    view['baseRefName'] = args[args.index('--base')+1]; path.write_text(json.dumps(view))
elif args[:2] == ['pr', 'list']:
    print('[]' if '--base' not in args or view['baseRefName'] != args[args.index('--base')+1] else '[{"number":9}]')
elif args[0] == 'api': print('{"protected":false}')
else: sys.exit('unexpected GitHub request')
''')
        env = dict(self.binding_env(), FM_TARGET_ROOT=str(self.target))
        if pinned:
            from fm_spec_pins import Pins
            with patch.dict(os.environ, env, clear=True):
                self.assertIsNotNone(Pins(env, 'T-223').create())
                if parent_adopted: self.assertIsNotNone(Pins(env, 'T-222').create())
        (self.scratch/'git.jsonl').write_text('')

    def restack_command(self):
        return subprocess.run(['bash', str(self.engine/'bin/lib/fm-restack.sh'), '--repo', str(self.engine),
            '--project', 'app', '--pr', '9', '--parent', '8', '--expected-head', self.child_head],
            env=self.env, capture_output=True, text=True, timeout=120)

    def test_restack_identity_refusals_emit_nothing(self):
        # FAIL-FIRST on round-one head: actual wrapper/read path must refuse before publication.
        self.prepare_stack(retargeted=True)
        cases = [dict(isCrossRepository=True), dict(isCrossRepository='missing'),
                 dict(headRefName='t-999-other', title='T-223: child'),
                 dict(headRefName='t-223-child', title='T-999: other'), dict(title=None)]
        for changed in (False, True):
            for identity in cases:
                with self.subTest(changed=changed, identity=identity):
                    self.view.pop('identity', None); self.view.pop('changed_identity', None)
                    self.view['reads'] = 0
                    self.view['changed_identity' if changed else 'identity'] = identity
                    self.write_view()
                    (self.scratch/'git.jsonl').write_text('')
                    result = self.restack_command()
                    self.assertNotEqual(result.returncode, 0, result.stdout+result.stderr)
                    calls = [json.loads(line) for line in (self.scratch/'git.jsonl').read_text().splitlines()]
                    self.assertFalse(any('push' in call for call in calls))
                    if not changed:
                        self.assertFalse(any('rebase' in call or 'update-ref' in call for call in calls))
                    rows = [json.loads(line) for line in (self.state/'events.jsonl').read_text().splitlines()]
                    self.assertFalse(any(row.get('type') == 'commit_pushed' for row in rows))

    def test_restack_without_local_objects_and_ready_move(self):
        # FAIL-FIRST: an adopted child can restack before its first worker round.
        self.prepare_stack(retargeted=True)
        probe = subprocess.run(['git', '-C', str(self.target), 'cat-file', '-e', self.child_head], env=self.env, capture_output=True)
        self.assertNotEqual(probe.returncode, 0, 'fixture must lack the child objects')
        with (self.state/'events.jsonl').open('a') as out:
            out.write(json.dumps(dict(type='merged', project='app', task='T-222', data={}))+'\n')
        ready = lambda: self.run_ok('bash', str(self.engine/'bin/fm-ready.sh'), 'list', '--repo', str(self.engine), '--project', 'app')
        self.assertIn('T-223', ready())
        result = self.restack_command()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual((payload['task'], payload['adopt_pr']), ('T-223', 9))
        remote_head = self.run_ok('git', '--git-dir='+str(self.remote), 'rev-parse', 'human-child')
        self.assertEqual(self.run_ok('git', '--git-dir='+str(self.remote), 'rev-list', '--count', 'trunk..human-child'), '1')
        self.assertEqual(self.run_ok('git', '-C', str(self.target), 'rev-parse', 'human-child'), remote_head)
        calls = [json.loads(line) for line in (self.scratch/'git.jsonl').read_text().splitlines()]
        self.assertTrue(any(any('refs/pull/9/head' in a for a in call) for call in calls))
        self.assertTrue(any(call[-4:] == ['update-ref', 'refs/heads/human-child', self.child_head, ''] for call in calls))
        self.assertTrue((self.state/'runs/.worker-T-223.lock').exists())
        rows = [json.loads(line) for line in (self.state/'events.jsonl').read_text().splitlines()]
        event = next(r for r in rows if r['type'] == 'commit_pushed')
        self.assertEqual((event['actor'], event['task'], event['pr'], event['data']),
                         ('firstmate', 'T-223', 9, dict(restacked=True, adopt_pr=9)))
        self.assertNotIn('T-223', ready(), 'restacked adopted task is in flight, not ready')
        self.assertEqual(self.run_ok('git', '--git-dir='+str(self.remote), 'for-each-ref', '--format=%(refname)', 'refs/heads/human-parent'), '')

    def test_restack_before_retarget_retains_unadopted_parent(self):
        self.prepare_stack(parent_adopted=False)
        result = self.restack_command()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)  # FAIL-FIRST
        self.assertIn('non-task parent deletion', json.loads(result.stdout)['parent_cleanup'])  # REGRESSION
        self.assertEqual(json.loads(self.view_path.read_text())['baseRefName'], 'trunk')
        self.assertEqual(self.run_ok('git', '--git-dir='+str(self.remote), 'rev-parse', 'human-parent'), self.parent_head)

    def test_restack_draft_and_rewritten_head_refused(self):
        self.prepare_stack(pinned=False, lost_head=True)
        result = self.restack_command()
        self.assertEqual(result.returncode, 65)
        self.assertIn('adoption not pinned', result.stderr)  # FAIL-FIRST diagnostic
        from fm_spec_pins import Pins
        env = dict(self.binding_env(), FM_TARGET_ROOT=str(self.target))
        with patch.dict(os.environ, env, clear=True): self.assertIsNotNone(Pins(env, 'T-223').create())
        result = self.restack_command()
        self.assertEqual(result.returncode, 65)
        self.assertIn('approved adoption head is no longer an ancestor', result.stderr)
        calls = [json.loads(line) for line in (self.scratch/'git.jsonl').read_text().splitlines()]
        self.assertFalse(any('push' in call for call in calls))


class AdoptionPilot(Authority):
    def test_pilot_unpinned_adopting_draft_cannot_advance(self):
        import fm_autopilot as autopilot
        state = self.root / 'state'; state.mkdir()
        (self.root / 'T-1.json').write_text(json.dumps(dict(id='T-1', adopt=self.value)))
        ctx = dict(engine=str(ROOT), target=str(self.root), state=str(state), tasks=str(self.root),
                   project='app', base='main', external=True, repository='owner/app', evidence_project='app')
        pilot = autopilot.Pilot(ctx, clock=lambda: 1000)
        pilot.policy_error = None; pilot.policy = dict(autopilot.DEFAULTS)
        pr = dict(number=9, state='open', head=dict(ref='human', sha='a'*40),
                  base=dict(ref='release', sha='b'*40), title='Human work')
        with patch.object(pilot, 'read_head_spec', side_effect=ValueError('committed task spec unavailable at PR head')), \
             patch.object(pilot, 'advance') as advance, patch.object(pilot, 'sync_branch') as sync, \
             patch.object(pilot, 'recheck') as recheck:
            self.assertEqual(pilot.pr_task(pr), 'T-1')
            self.assertEqual(pilot.task(pr), '')
            self.assertIn('no authorized pin', pilot.data['pulls']['9']['reason'])
            pilot.pull(pr, [], [], [], [])
            advance.assert_not_called()
            sync.assert_not_called()
            recheck.assert_not_called()

    def test_pilot_pin_authority_and_no_restack(self):
        import fm_autopilot as autopilot
        state = self.root/'state'; state.mkdir()
        (self.root/'T-1.json').write_text(json.dumps(dict(id='T-1', adopt=dict(self.value, pr=10))))
        ctx = dict(engine=str(ROOT), target=str(self.root), state=str(state), tasks=str(self.root),
                   project='app', base='main', external=True, repository='owner/app', evidence_project='app')
        pilot = autopilot.Pilot(ctx, clock=lambda: 1000)
        pilot.policy_error = None; pilot.policy = dict(autopilot.DEFAULTS)
        pr = dict(number=9, state='open', head=dict(ref='human', sha='a'*40),
                  base=dict(ref='release', sha='b'*40), title='Human work')
        pin = dict(snapshots=dict(spec=dict(text=json.dumps(dict(id='T-1', adopt=self.value)))))
        parent = dict(number=8, head=dict(ref='release'), merged_at='now')
        pilot.observe_pr = lambda *args: None
        pilot.pull = lambda *args: None
        pilot.inspect_policy = lambda: None
        pilot.pages = lambda url: [pr] if url == 'pulls?state=open' else [parent] if 'head=' in url else []
        def api(url):
            if url == 'pulls/9': return pr
            if '/check-runs?' in url: return dict(check_runs=[], total_count=0)
            if '/status?' in url: return dict(statuses=[], sha=pr['head']['sha'])
            return []
        pilot.api = api
        with patch.object(self.adopt.Pins, 'resolve', return_value=pin), \
             patch.object(pilot, 'restack') as restack:
            self.assertEqual(pilot.pr_task(pr), 'T-1')
            pilot.poll()
            restack.assert_not_called()
        self.assertEqual(pilot.data['failures'], 0)
        self.assertFalse(any('restack' in v['line'] for v in pilot.data['wakes'].values()))


class OwnerChecks(AdoptionRounds):
    def owner_command(self, mode, task):
        import shutil
        # Candidate readiness is independent of ownership; use the established
        # evidence fixture while retaining the real adoption resolver.
        self.run_ok('bash', '-c', '. "$1/tests/lib/binding-fixture.sh"; ROOT="$1"; binding_service_fixture "$2"',
                    '_', str(ROOT), str(self.engine))
        if mode == 'merge':
            args = ['bash', str(self.engine/'bin/fm-merge.sh'), '--task', task, '--pr', '9',
                    '--project', 'app', '--expected-head', self.prev]
        else:
            for directory in ('i18n', 'board/public'):
                if not (self.engine/directory).exists():
                    shutil.copytree(ROOT/directory, self.engine/directory)
            details = {lang: dict(title='Continue feature', explanation='Read the change',
                       before='Work in progress', after='Work is ready', outcome='Choice recorded',
                       options={key: dict(description='Review work', pros='Read changes', cons='Takes time')
                                for key in ('A', 'B', 'C')}) for lang in ('en', 'zh-TW')}
            path = self.scratch/'details.json'; path.write_text(json.dumps(details))
            allocated = self.run_ok('bash', str(self.engine/'bin/fm-decide.sh'), '--allocate',
                                    '--project', 'app', '--task', task)
            args = ['bash', str(self.engine/'bin/fm-decide.sh'), '--request', allocated,
                    '--project', 'app', '--task', task, '--kind', 'merge', '--pr', '9',
                    '--expected-head', self.prev, '--details', str(path)]
        return subprocess.run(args, env=self.env, capture_output=True, text=True, timeout=120)

    def test_owner_accepted(self):
        result = self.owner_command(OWNER_MODE, 'T-223')
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)

    def test_owner_other_task_refused(self):
        result = self.owner_command(OWNER_MODE, 'T-224')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("T-223", result.stdout+result.stderr)

    def test_owner_duplicate_refused(self):
        (self.home/'tasks/T-224.json').write_text(json.dumps(dict(self.spec, id='T-224')))
        result = self.owner_command(OWNER_MODE, 'T-223')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('adopted by two tasks', result.stdout+result.stderr)

    def test_owner_corrupt_pin_refused(self):
        pin = self.state/'pins/T-223'; pin.mkdir(parents=True)
        (pin/'1.json').write_text('{broken')
        result = self.owner_command(OWNER_MODE, 'T-223')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('adoption unreadable for T-223', result.stdout+result.stderr)


if __name__ == '__main__':
    group = sys.argv[2] if len(sys.argv) > 2 else 'adoption'
    OWNER_MODE = group
    selected = {'adoption': [(AdoptionRounds, 'test_adopt_'), (Authority, 'test_adopt_'),
                             (BaseBinding, 'test_base_'), (AdoptionPilot, 'test_pilot_')],
                'preflight': [(Authority, 'test_adopt_preflight')],
                'base': [(BaseBinding, 'test_base_required'), (BaseBinding, 'test_base_restack')],
                'restack': [(AdoptedRestack, 'test_restack_')],
                'decide': [(OwnerChecks, 'test_owner_')], 'merge': [(OwnerChecks, 'test_owner_')]}[group]
    suite = unittest.TestSuite()
    for cls, prefix in selected:
        for name in unittest.defaultTestLoader.getTestCaseNames(cls):
            if name.startswith(prefix): suite.addTest(cls(name))
    sys.exit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
