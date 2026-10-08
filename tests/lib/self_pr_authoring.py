"""Feature assertions for authored self publication; suites run only in gates."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1))
sys.path.insert(0, str(ROOT / 'bin/lib'))
import fm_self_pr as pr


class Rendering(unittest.TestCase):
    def setUp(self):
        self.spec = dict(id='T-259', title='A deliberately long descriptive task title ' * 5,
                         acceptance=['Explain approved intent without asserting success.'])
        self.sources = {k: dict(sha256=hashlib.sha256(k.encode()).hexdigest(), absent=False)
                        for k in ('spec', 'design', 'contract', 'conventions')}
        self.draft = dict(schema=1, task='T-259', sources=self.sources,
                          subject='Show authored intent in self pull requests', size='complex',
                          problem='The old body hides the approved purpose.',
                          expected_result='Readers can assess the proposed result.',
                          approach='Render authored context beside observed scope.',
                          intent_notes=[dict(index=0, note='Explain the publication purpose.')],
                          door=dict(kind='two-way', reason='Rendering can be reverted.'),
                          rollback=dict(trigger='Incorrect metadata', action='Restore the prior renderer',
                                        owner='not-recorded', limits='Existing metadata is preserved.'))
        self.envelope = dict(schema=1, project='firstmate-workflow', task='T-259',
                             mode='pin-backed', pin=dict(version=2, sha256='f'*64),
                             sources=self.sources, draft=self.draft, dispatch_reference=None)

    def render(self, **kwargs):
        return pr.render(self.envelope, self.spec, 'a'*40, ['bin/renderer.py'],
                         repository='fixture/project', created_at='2026-10-08T00:00:00Z', **kwargs)

    def test_authored_subject_and_meaningful_exact_head_body(self):
        result = self.render()
        self.assertEqual(result['title'], 'T-259: Show authored intent in self pull requests')
        for text in ('Problem and result', 'Approach and scope', 'Approved intent and evidence',
                     'Decision, migration and rollback', 'bin/renderer.py', 'a'*40,
                     'Required CI: pending', 'Review: pending', 'six gates: pending',
                     'Local validation: not recorded', 'Proposed approach', 'Expected result'):
            self.assertIn(text, result['body'])
        self.assertNotIn(self.spec['title'], result['body'])
        self.assertIn('https://github.com/fixture/project/commit/'+'a'*40, result['body'])

    def test_small_unknown_repository_and_absent_reversibility(self):
        self.draft['size'] = 'small'
        self.draft.pop('door'); self.draft.pop('rollback')
        result = pr.render(self.envelope, self.spec, 'a'*40, [], repository='')
        self.assertIn(self.draft['problem'], result['body'])
        self.assertIn('Door: not recorded', result['body'])
        self.assertIn('Rollback: not recorded', result['body'])
        self.assertIn('current evidence unavailable', result['body'])
        self.assertNotIn('https://', result['body'])

    def test_existing_approved_reversibility_is_reused_without_schema_changes(self):
        self.draft.pop('door'); self.draft.pop('rollback')
        self.spec['door'] = dict(kind='two-way', reason='Existing approved reversibility.')
        self.spec['rollback'] = dict(trigger='Existing trigger', action='Existing action')
        before = copy.deepcopy(self.spec)
        result = self.render()
        self.assertIn('Door: two-way', result['body'])
        self.assertIn('Existing approved reversibility.', result['body'])
        self.assertIn('owner: not recorded', result['body'])
        self.assertEqual(self.spec, before)
        self.assertIn('Approved task: T-259.', result['body'])

    def test_subject_and_intent_refusal_classes(self):
        for subject in ('Update task', 'Update T-259', 'Show state/private', 'Show x\nsecret',
                        'Show x\x01', 'Show '+ 'x'*70, 'T-259: Show context', 'Show'):
            draft = copy.deepcopy(self.draft); draft['subject'] = subject
            with self.subTest(subject=subject), self.assertRaises(ValueError):
                pr.validate(draft, self.spec, self.sources)
        self.draft['intent_notes'][0]['index'] = 1
        with self.assertRaisesRegex(ValueError, 'intent index'):
            pr.validate(self.draft, self.spec, self.sources)

    def test_source_mismatch_and_first_dispatch_has_no_pin_digest(self):
        self.assertEqual(pr.validate(self.draft, self.spec, self.sources), self.draft)
        self.draft['sources']['spec']['sha256'] = '0'*64
        with self.assertRaisesRegex(ValueError, 'source digest'):
            pr.validate(self.draft, self.spec, {**self.sources, 'spec':dict(sha256='1'*64, absent=False)})

    def test_questions_consume_only_bounded_purpose(self):
        for purpose in ('scope', 'acceptance', 'implementation'):
            result = self.render(question=purpose)
            self.assertEqual(result['title'], 'T-259: Ask about authored intent in self pull requests')
            self.assertIn(purpose+' clarification', result['body'])
            self.assertNotIn('bin/renderer.py', result['body'])
        with self.assertRaises(ValueError): self.render(question='/private/secret')

    def test_unsealed_legacy_has_no_pin_or_readiness_claim(self):
        self.envelope.pop('pin'); self.envelope['mode'] = 'unsealed-legacy'
        self.envelope['pin_unavailable_reason'] = 'required design absent'
        result = self.render()
        self.assertIn('unsealed legacy', result['body'])
        self.assertIn('scope gate not authorized', result['body'])
        self.assertIn('publication pin unavailable', result['body'])
        self.assertNotIn('f'*64, result['body'])

    def test_quoted_markdown_is_data_and_no_shell_execution(self):
        self.draft['problem'] = 'A `quoted` table | cell with $(printf example) & shell metacharacters.'
        result = self.render()
        self.assertIn('$(printf example)', result['body'])

    def test_trusted_repository_and_degraded_origin_identity(self):
        self.assertEqual(pr.repository_identity('owner/repo'), 'owner/repo')
        for origin in ('https://github.com/owner/repo.git', 'git@github.com:owner/repo.git',
                       'ssh://git@github.com/owner/repo.git'):
            self.assertEqual(pr.repository_identity('', origin), 'owner/repo')
        for origin in ('/private/local.git', 'https://example.invalid/owner/repo', 'unknown'):
            self.assertEqual(pr.repository_identity('', origin), '')
        self.assertEqual(pr.repository_identity('registered/self', '/private/local.git'), 'registered/self')

    def test_full_pin_digest_includes_all_stock_fields(self):
        pin = dict(schema=1, version=2, source='repin', arbitrary='繁體')
        expected = hashlib.sha256(json.dumps(pin, sort_keys=True, separators=(',', ':'),
                                             ensure_ascii=False).encode()).hexdigest()
        self.assertEqual(pr.pin_digest(pin), expected)
        self.assertNotEqual(pr.pin_digest({**pin, 'source':'dispatch'}), expected)


class StockPublication(unittest.TestCase):
    """Real stock authority/worker, disposable repo, mocked GitHub account."""
    def setUp(self):
        import os
        import shutil
        import subprocess
        import tempfile
        self.subprocess = subprocess
        self.temporary = tempfile.TemporaryDirectory(prefix='self-pr-authoring-')
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name).resolve()
        self.repo = self.home/'repo'; self.repo.mkdir()
        self.env = {k:v for k,v in os.environ.items()
                    if not k.startswith(('FM_', 'HERDR_', 'GIT_', 'XDG_')) and k != 'GH_REPO'}
        self.env.update(HERDR_ENV='0', FM_TRANSPORT='direct', FM_ROOT=str(self.repo),
                        FM_HOST='none', FM_GIT_NAME='Fixture', FM_GIT_EMAIL='fixture@example.invalid',
                        GIT_CONFIG_GLOBAL=str(self.home/'gitconfig'), GIT_CONFIG_NOSYSTEM='1',
                        PYTHONDONTWRITEBYTECODE='1', FM_SEEN=str(self.home),
                        FM_SESSION_PID=str(os.getpid()))
        (self.home/'gitconfig').write_text('')
        for directory in ('bin', 'skills'):
            shutil.copytree(ROOT/directory, self.repo/directory,
                            ignore=shutil.ignore_patterns('__pycache__'))
        self.run_ok('git', 'init', '-q', '--bare', '-b', 'main', str(self.home/'remote.git'))
        self.run_ok('git', 'init', '-q', '-b', 'main', str(self.repo))
        self.git('config', 'user.name', 'Fixture'); self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'commit.gpgSign', 'false')
        (self.repo/'design/tasks').mkdir(parents=True)
        self.spec = dict(id='T-259', title='Self-project pull requests explain approved intent and observed scope with honest evidence and recorded reversibility',
                         scope=['src/**'], acceptance=['Publish meaningful authored context.'])
        (self.repo/'design/tasks/T-259.json').write_text(json.dumps(self.spec)+'\n')
        (self.repo/'design/design.md').write_text('## 6. Gates\nApproved fixture.\n## 8. Board\n')
        (self.repo/'config.yaml').write_text('vendor: mock\nproject:\n  check: true\n')
        (self.repo/'.gitignore').write_text('state/\n')
        self.git('add', '-A'); self.git('commit', '-qm', 'approved sources')
        self.git('remote', 'add', 'origin', str(self.home/'remote.git'))
        self.git('push', '-q', '-u', 'origin', 'main')
        self.state = self.repo/'state'; self.state.mkdir()
        self.evidence_project = 'self'
        approval = dict(type='greenlit', task='T-259', actor='captain', ts='2026-10-03T00:00:00Z')
        (self.state/'events.jsonl').write_text(json.dumps(approval)+'\n')
        self.seed_preflight(); self.author()
        adapter = self.repo/'bin/adapters/mock.sh'
        adapter.write_text('#!/usr/bin/env bash\n[ "$1" = run ] || exit 64\n'
                           'touch "$FM_SEEN/adapter-started"\nmkdir -p "$3/src"\n'
                           'printf "implemented\\n" > "$3/src/result"\n')
        adapter.chmod(0o755)
        gh = self.home/'gh'
        gh.write_text('#!'+sys.executable+'\n'+'''import json, os, sys
from pathlib import Path
home=Path(os.environ['FM_SEEN']); args=sys.argv[1:]
with (home/'ghcalls').open('a') as out: out.write(json.dumps(args)+'\\n')
if args[:2] == ['pr','list']: print('null')
elif args[:2] == ['pr','create']:
 title=args[args.index('--title')+1]
 body=(Path(args[args.index('--body-file')+1]).read_text() if '--body-file' in args
       else args[args.index('--body')+1])
 (home/'published.json').write_text(json.dumps(dict(title=title, body=body, args=args)))
 print('https://example.invalid/pull/42')
elif args[:2] == ['pr','view']:
 import subprocess
 repo=os.environ['FM_ROOT']
 def git(*a): return subprocess.check_output(['git','-C',repo,*a],text=True).strip()
 branch=git('for-each-ref','--format=%(refname:short)','refs/heads/t-259-*')
 if '--jq' in args and args[args.index('--json')+1]=='headRefName': print(branch)
 else: print(json.dumps(dict(title='Human title', body='Human body', headRefName=branch,
                            headRefOid=git('rev-parse',branch), baseRefOid=git('rev-parse','main'),
                            baseRefName='main', state='OPEN', isDraft=False, comments=[])))
else: print('[]')
''')
        gh.chmod(0o755); self.env['FM_GH'] = str(gh)
        if os.environ.get('FM_SELF_PR_BASE_PROOF') == '1':
            helper = self.repo/'bin/lib/fm_self_pr.py'
            text = helper.read_text()
            start = "    if not re.fullmatch(r'[0-9a-f]{40,64}', head):"
            old = "    return dict(title=spec['id']+': '+spec['title'], body='Dispatched by firstmate for '+spec['id']+'. Acceptance is in design/tasks/'+spec['id']+'.json.')\n"
            self.assertIn(start, text); helper.write_text(text.replace(start, old+start, 1))
        self.pin_env = dict(self.env, FM_ENGINE_ROOT=str(self.repo), FM_TARGET_ROOT=str(self.repo),
                            FM_STATE_DIR=str(self.state), FM_TASKS_DIR=str(self.repo/'design/tasks'),
                            FM_DESIGN=str(self.repo/'design/design.md'), FM_BASE='main', FM_EXTERNAL='0')

    def run_ok(self, *args):
        result = self.subprocess.run(args, cwd=self.repo, env=self.env,
                                     capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        return result.stdout.strip()

    def git(self, *args): return self.run_ok('git', '-C', str(self.repo), *args)

    def seed_preflight(self):
        from fm_evidence import Store
        data = (self.repo/'design/tasks/T-259.json').read_bytes()
        Store(self.state, self.evidence_project, 'T-259').append(
            'spec-preflight', 1, 'reviewer-fixture', 'a'*40,
            '1. Fixture checked.\nSPEC-OK:T-259', spec_sha256=hashlib.sha256(data).hexdigest(),
            verdict='SPEC-OK', provenance=dict(level='legacy', vendor='claude'))

    def author(self):
        env = dict(self.env, FM_ENGINE_ROOT=str(self.repo), FM_TARGET_ROOT=str(self.repo),
                   FM_STATE_DIR=str(self.state), FM_TASKS_DIR=str(self.repo/'design/tasks'),
                   FM_DESIGN=str(self.repo/'design/design.md'), FM_BASE='main', FM_EXTERNAL='0')
        from unittest.mock import patch
        with patch.dict('os.environ', env, clear=True):
            pins, _, snapshots, approval, _ = pr.authority('T-259', self.evidence_project, prospective=True)
            self.draft = dict(schema=1, task='T-259', sources=pr.source_digests(snapshots),
                              subject='Show authored intent and honest evidence in self pull requests', size='complex',
                              problem='Self PR titles copy descriptive task titles and bodies omit useful context.',
                              expected_result='Readers can assess approved intent, observed scope and pending evidence.',
                              approach='Bind authored prose to approved sources and render exact-head context.',
                              intent_notes=[dict(index=0, note='Explain meaningful publication intent.')],
                              door=dict(kind='two-way', reason='Publication rendering can be reverted.'),
                              rollback=dict(trigger='Incorrect publication prose', action='Restore the prior renderer',
                                            owner='not-recorded', limits='Existing PR metadata stays unchanged.'))
            pr.validate(self.draft, json.loads(snapshots['spec']['text']), self.draft['sources'], approval)
            pr.save(pr.state_path(pins.state, 'pr-authoring/T-259.json'), self.draft)

    def worker(self, *args):
        return self.subprocess.run(['bash', str(self.repo/'bin/fm-worker.sh'), '--task', 'T-259', *args],
                                   cwd=self.repo, env=self.env, capture_output=True, text=True, timeout=60)

    def publication(self): return json.loads((self.home/'published.json').read_text())

    def assert_metadata(self, metadata):
        self.assertEqual(metadata['title'], 'T-259: '+self.draft['subject'])
        for text in (self.draft['problem'], self.draft['expected_result'], 'src/result',
                     'Required CI: pending', 'Review: pending', 'six gates: pending',
                     'Local validation: not recorded', 'Proposed approach'):
            self.assertIn(text, metadata['body'])
        self.assertNotIn(str(self.state), metadata['body']); self.assertNotIn(str(self.repo), metadata['body'])

    def assert_refused(self):
        result = self.worker()
        self.assertEqual(result.returncode, 65, result.stdout+result.stderr)
        self.assertFalse((self.home/'adapter-started').exists())
        self.assertFalse((self.home/'published.json').exists())
        self.assertEqual(self.git('ls-remote', '--heads', 'origin', 't-259-*'), '')
        return result

    def pin_create(self):
        result = self.subprocess.run([sys.executable, str(self.repo/'bin/lib/fm_spec_pins.py'),
                                      'create', '--task', 'T-259', '--require-preflight', 'self'],
                                     cwd=self.repo, env=self.pin_env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_first_dispatch_seals_after_stock_pin_and_publishes_exact_preview(self):
        self.assertNotIn('pin', self.draft)
        result = self.worker(); self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        metadata = self.publication(); self.assert_metadata(metadata)
        pin = json.loads((self.state/'pins/T-259/1.json').read_text())
        sealed = json.loads((self.state/'pr-authoring/envelopes/T-259.json').read_text())
        self.assertEqual(sealed['pin'], dict(version=1))
        self.assertEqual(sealed['pin_sha256'], pr.pin_digest(pin))
        self.assertEqual(sealed['sources'], pr.source_digests(pin['snapshots']))
        process = json.loads(next((self.state/'runs').glob('worker-*/process.json')).read_text())
        copied = Path(process['snapshot'])/'bin/lib/fm_self_pr.py'
        self.assertTrue(copied.is_file())
        self.assertNotEqual(copied, self.repo/'bin/lib/fm_self_pr.py')
        self.assertEqual(copied.read_bytes(), (self.repo/'bin/lib/fm_self_pr.py').read_bytes())
        branch = self.git('for-each-ref', '--format=%(refname:short)', 'refs/heads/t-259-*')
        head = self.git('rev-parse', branch); self.assertIn(head, metadata['body'])
        self.assertEqual(self.git('log', '-1', '--format=%s', branch), 'T-259: '+self.spec['title'])
        preview = json.loads((self.state/('pr-authoring/previews/T-259-'+head+'.json')).read_text())
        self.assertEqual(preview, {k:metadata[k] for k in ('title','body')})
        self.assertIn('--body-file', metadata['args'])
        self.assertFalse(Path(metadata['args'][metadata['args'].index('--body-file')+1]).exists())

    def test_registered_self_repository_supplies_head_links(self):
        (self.repo/'config.yaml').write_text('vendor: mock\ndefault_project: firstmate-workflow\n'
            'projects:\n  firstmate-workflow:\n    repo: .\n    github: fixture/project\n'
            '    base: main\n    required_check: ci\n    design: design/design.md\n'
            '    tasks: design/tasks\n    project:\n      check: true\n')
        self.git('add', 'config.yaml'); self.git('commit', '-qm', 'registered self sources')
        self.git('push', '-q', 'origin', 'main')
        self.evidence_project = 'firstmate-workflow'; self.seed_preflight(); self.author()
        result = self.worker(); self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertIn('https://github.com/fixture/project/commit/', self.publication()['body'])

    def test_pre_registry_canonical_origin_links_without_network(self):
        self.git('config', 'url.'+str(self.home/'remote.git')+'.insteadOf', 'https://github.com/fixture/project.git')
        self.git('remote', 'set-url', 'origin', 'https://github.com/fixture/project.git')
        result = self.worker(); self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertIn('https://github.com/fixture/project/commit/', self.publication()['body'])
        self.assertNotIn(str(self.home/'remote.git'), self.publication()['body'])

    def test_local_bare_origin_omits_unknown_links(self):
        result = self.worker(); self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertIn('current evidence unavailable', self.publication()['body'])
        self.assertNotIn('https://github.com/', self.publication()['body'])
        self.assertNotIn(str(self.home/'remote.git'), self.publication()['body'])

    def test_shared_seed_uses_final_committed_stock_contract_bytes(self):
        config = self.repo/'config.yaml'
        config.write_text(config.read_text()+'models:\n  mock: final-fixture-model\n')
        self.git('add', 'config.yaml'); self.git('commit', '-qm', 'final fixture contract')
        self.git('push', '-q', 'origin', 'main')
        result = self.subprocess.run([sys.executable, str(ROOT/'tests/lib/self_pr_authoring.py'),
                                      str(ROOT), '--seed', 'T-259', 'self'],
                                     env=self.pin_env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        draft = json.loads((self.state/'pr-authoring/T-259.json').read_text())
        self.assertEqual(draft['sources']['contract']['sha256'], hashlib.sha256(config.read_bytes()).hexdigest())
        pin = self.pin_create()
        result = self.subprocess.run([sys.executable, str(self.repo/'bin/lib/fm_self_pr.py'),
                                      'seal', '--task', 'T-259'], env=self.pin_env,
                                     capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        envelope = json.loads(result.stdout)
        self.assertEqual(envelope['sources'], pr.source_digests(pin['snapshots']))
        self.assertEqual(envelope['pin_sha256'], pr.pin_digest(pin))

    def test_existing_pin_needs_no_repin_for_prose(self):
        self.pin_create(); original = (self.state/'pins/T-259/1.json').read_bytes()
        result = self.worker(); self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assert_metadata(self.publication())
        self.assertEqual((self.state/'pins/T-259/1.json').read_bytes(), original)
        self.assertFalse((self.state/'pins/T-259/2.json').exists())

    def test_missing_authoring_refuses_without_adapter_or_push(self):
        (self.state/'pr-authoring/T-259.json').unlink()
        self.assertIn('authoring-required', self.assert_refused().stderr)

    def test_stale_source_refuses_without_adapter_or_push(self):
        self.draft['sources']['spec']['sha256'] = '0'*64
        (self.state/'pr-authoring/T-259.json').write_text(json.dumps(self.draft))
        self.assertIn('source digest mismatch', self.assert_refused().stderr)

    def test_bad_dispatch_reference_and_missing_prose_refuse(self):
        self.draft['dispatch_reference'] = 'wrong-decision'
        (self.state/'pr-authoring/T-259.json').write_text(json.dumps(self.draft))
        self.assertIn('dispatch reference', self.assert_refused().stderr)

    def test_missing_meaningful_prose_refuses(self):
        self.draft.pop('problem')
        (self.state/'pr-authoring/T-259.json').write_text(json.dumps(self.draft))
        self.assertIn('meaningful authored prose', self.assert_refused().stderr)

    def test_stale_preflight_refuses_before_adapter(self):
        self.spec['acceptance'].append('New approved purpose needs preflight.')
        (self.repo/'design/tasks/T-259.json').write_text(json.dumps(self.spec)+'\n')
        self.git('add', 'design/tasks/T-259.json'); self.git('commit', '-qm', 'new approved source')
        self.git('push', '-q', 'origin', 'main')
        self.assertIn('no SPEC-OK', self.assert_refused().stderr)

    def test_symlink_draft_refuses(self):
        path = self.state/'pr-authoring/T-259.json'
        outside = self.home/'outside.json'; outside.write_bytes(path.read_bytes())
        path.unlink(); path.symlink_to(outside)
        self.assertIn('symlink', self.assert_refused().stderr)

    def test_corrupt_existing_pin_cannot_use_legacy_publication(self):
        (self.state/'pins/T-259').mkdir(parents=True)
        (self.state/'pins/T-259/1.json').write_text('{broken')
        self.assert_refused()

    def test_invalid_preflight_refuses_before_dispatch(self):
        import shutil
        shutil.rmtree(self.state/'evidence'); self.assert_refused()

    def test_sealed_pin_digest_refusal_is_distinct_from_missing_authoring(self):
        self.pin_create()
        result = self.subprocess.run([sys.executable, str(self.repo/'bin/lib/fm_self_pr.py'),
                                      'seal', '--task', 'T-259'], env=self.pin_env,
                                     capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        path = self.state/'pr-authoring/envelopes/T-259.json'; envelope = json.loads(path.read_text())
        envelope['pin_sha256'] = '0'*64; path.write_text(json.dumps(envelope))
        result = self.subprocess.run([sys.executable, str(self.repo/'bin/lib/fm_self_pr.py'),
                                      'render', '--task', 'T-259', '--head', 'a'*40],
                                     env=self.pin_env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 65); self.assertIn('sealed publication digest', result.stderr)
        self.assertNotIn('authoring-required', result.stderr)

    def test_preview_is_bound_to_supplied_pr_head_and_old_hashes_without_network_write(self):
        self.pin_create()
        helper = str(self.repo/'bin/lib/fm_self_pr.py')
        sealed = self.subprocess.run([sys.executable, helper, 'seal', '--task', 'T-259'],
                                     env=self.pin_env, capture_output=True, text=True)
        self.assertEqual(sealed.returncode, 0, sealed.stderr)
        title_hash = hashlib.sha256(b'Human title').hexdigest()
        body_hash = hashlib.sha256(b'Human body').hexdigest()
        result = self.subprocess.run([sys.executable, helper, 'preview', '--task', 'T-259',
                                      '--repository', 'fixture/project', '--head', 'a'*40, '--pr', '42',
                                      '--old-title-sha256', title_hash, '--old-body-sha256', body_hash],
                                     env=self.pin_env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        preview = json.loads(result.stdout)
        self.assertEqual(preview['old_title_sha256'], title_hash)
        self.assertEqual(preview['old_body_sha256'], body_hash)
        self.assertEqual(preview['head'], 'a'*40); self.assertEqual(preview['pr'], 42)
        self.assertEqual(preview['proposed']['title'], 'T-259: '+self.draft['subject'])
        self.assertFalse((self.home/'ghcalls').exists())
        self.assertFalse((self.state/'pr-authoring/previews').exists())

    def test_existing_self_metadata_preserved_without_draft(self):
        (self.repo/'config.yaml').write_text('vendor: mock\nproject:\n  check: true\ndefault_project: self\nprojects:\n  self:\n    repo: .\n    github: fixture/project\n    base: main\n    design: design/design.md\n    tasks: design/tasks\n    project:\n      check: true\n')
        self.git('add', 'config.yaml'); self.git('commit', '-qm', 'registered self fixture')
        self.git('push', '-q', 'origin', 'main'); self.author()
        result = self.worker(); self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        (self.state/'pr-authoring/T-259.json').unlink(); (self.home/'published.json').unlink()
        (self.repo/'bin/adapters/mock.sh').write_text('#!/usr/bin/env bash\n[ "$1" = run ] || exit 64\n'
                                                   'mkdir -p "$3/src"\necho second > "$3/src/second"\n')
        # Stock binding fetches canonical GitHub refs; supply those exact refs
        # through the disposable remote, retaining real fetch/head validation.
        branch = self.git('for-each-ref', '--format=%(refname:short)', 'refs/heads/t-259-*')
        self.git('push', '-q', 'origin', branch+':refs/pull/42/head')
        import shutil
        real_git = shutil.which('git', path=self.env['PATH'])
        tools = self.home/'tools'; tools.mkdir()
        wrapper = tools/'git'
        wrapper.write_text('#!'+sys.executable+'\n'+
                          'import os, sys\nargs=sys.argv[1:]\n'+
                          'args=[('+repr(str(self.home/'remote.git'))+
                          ' if a == "https://github.com/fixture/project.git" else a) for a in args]\n'+
                          'os.execv('+repr(real_git)+', ["git", *args])\n')
        wrapper.chmod(0o755)
        self.env['PATH'] = str(tools)+':'+self.env['PATH']
        result = self.worker('--pr', '42'); self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        calls = [json.loads(line) for line in (self.home/'ghcalls').read_text().splitlines()]
        self.assertEqual(sum(call[:2] == ['pr','create'] for call in calls), 1)
        self.assertFalse(any(call[:2] == ['pr','edit'] for call in calls))
        self.assertFalse((self.home/'published.json').exists())

    def test_question_metadata_omits_worker_paths_but_keeps_question_lifecycle(self):
        import shlex
        private = '/private/worker-secret API_TOKEN=never-publish'
        adapter = self.repo/'bin/adapters/mock.sh'
        adapter.write_text('#!/usr/bin/env bash\n[ "$1" = run ] || exit 64\n'
                           'printf "%s\\n" "ASK-PASS-CRITERIA:T-259" '+shlex.quote(private)+
                           ' > "$3/.fm-say.md"\n')
        result = self.worker(); self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        metadata = self.publication()
        self.assertEqual(metadata['title'], 'T-259: Ask about '+self.draft['subject'].split(' ',1)[1])
        self.assertIn('acceptance clarification', metadata['body']); self.assertNotIn(private, metadata['body'])
        self.assertNotIn('API_TOKEN', metadata['title']); self.assertIn('--draft', metadata['args'])
        question = self.state/'worktrees/T-259/design/questions/T-259.md'
        self.assertIn(private, question.read_text())

    def test_scope_question_metadata_omits_worker_paths_but_keeps_question_lifecycle(self):
        import shlex
        private = '/private/worker-secret API_TOKEN=never-publish'
        adapter = self.repo/'bin/adapters/mock.sh'
        adapter.write_text('#!/usr/bin/env bash\n[ "$1" = run ] || exit 64\n'
                           'printf "%s\\n" "SCOPE-BLOCKED:T-259" '+shlex.quote(private)+
                           ' > "$3/.fm-say.md"\n')
        result = self.worker(); self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        metadata = self.publication()
        self.assertEqual(metadata['title'], 'T-259: Ask about '+self.draft['subject'].split(' ',1)[1])
        self.assertIn('scope clarification', metadata['body']); self.assertNotIn(private, metadata['body'])
        self.assertNotIn('API_TOKEN', metadata['title']); self.assertIn('--draft', metadata['args'])
        question = self.state/'worktrees/T-259/design/questions/T-259.md'
        self.assertIn(private, question.read_text())

    def missing_source(self, source):
        if source == 'contract':
            (self.repo/'config.yaml').write_text('vendor: mock\n'); self.git('add', 'config.yaml')
        else: self.git('rm', 'design/design.md')
        self.git('commit', '-qm', 'approved legacy missing '+source)
        self.git('push', '-q', 'origin', 'main'); self.author()

    def test_missing_contract_actual_publication_is_unsealed(self):
        self.missing_source('contract'); self.check_unsealed('contract')

    def test_missing_design_actual_publication_is_unsealed(self):
        self.missing_source('design'); self.check_unsealed('design')

    def check_unsealed(self, source):
        result = self.worker(); self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        metadata = self.publication(); self.assert_metadata(metadata)
        for text in ('unsealed legacy','publication pin unavailable','scope gate not authorized'):
            self.assertIn(text, metadata['body'])
        self.assertIn('no pin; gate 3 (scope) will refuse', result.stderr)
        self.assertFalse((self.state/'pins/T-259/1.json').exists())
        envelope = json.loads((self.state/'pr-authoring/envelopes/T-259.json').read_text())
        self.assertEqual(envelope['mode'], 'unsealed-legacy'); self.assertNotIn('pin', envelope)
        self.assertNotIn('pin_sha256', envelope)
        self.assertTrue(envelope['sources'][source]['absent'])
        if source == 'design': self.assertIsNone(envelope['sources']['design']['sha256'])
        check = self.subprocess.run([sys.executable, str(self.repo/'bin/lib/fm_spec_pins.py'),
                                     'scope', '--task', 'T-259', '--head', 'HEAD', '--base', 'main'],
                                    env=self.pin_env, capture_output=True, text=True)
        self.assertEqual(check.returncode, 65, check.stdout+check.stderr)

    def test_unexpected_creation_failure_does_not_gain_legacy_mode(self):
        self.spec['scope'] = []
        (self.repo/'design/tasks/T-259.json').write_text(json.dumps(self.spec)+'\n')
        self.git('add', 'design/tasks/T-259.json'); self.git('commit', '-qm', 'invalid fixture scope')
        self.git('push', '-q', 'origin', 'main'); self.seed_preflight(); self.assert_refused()

    def test_retained_old_frozen_code_keeps_prior_output_and_bytes(self):
        old = self.subprocess.run(['git', '-C', str(ROOT), 'show',
                                  'feb2d6af2470f787939feac923afcc7308f1cce8:bin/fm-worker.sh'],
                                 capture_output=True, check=True).stdout
        path = self.repo/'bin/fm-worker.sh'; path.write_bytes(old)
        before = hashlib.sha256(path.read_bytes()).hexdigest()
        result = self.worker(); self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        metadata = self.publication()
        self.assertEqual(metadata['title'], 'T-259: '+self.spec['title'])
        self.assertEqual(metadata['body'], 'Dispatched by firstmate for T-259. Acceptance is in design/tasks/T-259.json.')
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), before)
        updated = StockPublication(methodName='runTest')
        updated.setUp(); self.addCleanup(updated.doCleanups)
        result = updated.worker()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        updated.assert_metadata(updated.publication())
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), before)
        # Updated snapshot comparison is the separate first-dispatch content
        # assertion. Both run full retained harness and helper APIs.

    def test_controlled_old_render_proof_keeps_complete_helper_api(self):
        path = self.repo/'bin/lib/fm_self_pr.py'; text = path.read_text()
        needle = "    if not re.fullmatch(r'[0-9a-f]{40,64}', head):"
        old_render = "    return dict(title=spec['id']+': '+spec['title'], body='Dispatched by firstmate for '+spec['id']+'. Acceptance is in design/tasks/'+spec['id']+'.json.')\n"
        self.assertIn(needle, text); path.write_text(text.replace(needle, old_render+needle, 1))
        before = path.read_bytes()
        result = self.worker(); self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        with self.assertRaisesRegex(AssertionError, 'T-259:'): self.assert_metadata(self.publication())
        self.assertEqual(path.read_bytes(), before)
        self.assertIn('def seal(', path.read_text()); self.assertIn('def validate(', path.read_text())


if '--seed' not in sys.argv:
    saved_argv = sys.argv[:]
    try:
        sys.argv = [saved_argv[0], str(ROOT)]
        herdr_spec = importlib.util.spec_from_file_location('t259_herdr_fixture', ROOT/'tests/lib/herdr.py')
        herdr_fixture = importlib.util.module_from_spec(herdr_spec)
        herdr_spec.loader.exec_module(herdr_fixture)
    finally:
        sys.argv = saved_argv

    class EntrypointsAuthoring(herdr_fixture.EntrypointsFixture):
        def test_final_fixture_draft_matches_stock_sealed_sources_and_publication(self):
            result = self.invoke('fm-worker.sh', ['--task', 'T-035'], HERDR_ENV='0')
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            state = self.repo/'state'
            draft = json.loads((state/'pr-authoring/T-035.json').read_text())
            envelope = json.loads((state/'pr-authoring/envelopes/T-035.json').read_text())
            pin = json.loads((state/'pins/T-035/1.json').read_text())
            self.assertEqual(draft['sources'], pr.source_digests(pin['snapshots']))
            self.assertEqual(envelope['pin_sha256'], pr.pin_digest(pin))
            preview = json.loads(next((state/'pr-authoring/previews').glob('T-035-*.json')).read_text())
            self.assertEqual(preview['title'], 'T-035: '+draft['subject'])
            self.assertIn('work.txt', preview['body'])

        def test_api_billing_mutation_matches_final_approved_contract(self):
            self.env['CODEX_API_KEY'] = 'fm-suite-key'
            with (self.repo/'config.yaml').open('a') as config:
                config.write('billing:\n  codex: api-key\n')
            self.seed_self_authoring()
            self.test_final_fixture_draft_matches_stock_sealed_sources_and_publication()
            pin = json.loads((self.repo/'state/pins/T-035/1.json').read_text())
            self.assertEqual(pin['snapshots']['contract']['sha256'],
                             hashlib.sha256((self.repo/'config.yaml').read_bytes()).hexdigest())
            preview = next((self.repo/'state/pr-authoring/previews').glob('*.json')).read_text()
            self.assertNotIn('fm-suite-key', preview); self.assertNotIn('billing:', preview)

        def assert_no_model_start(self):
            result = self.invoke('fm-worker.sh', ['--task', 'T-035'], HERDR_ENV='0')
            self.assertEqual(result.returncode, 65, result.stdout+result.stderr)
            self.assertFalse(list((self.repo/'state/worktrees').glob('**/work.txt')))
            self.assertFalse(list((self.repo/'state/runs').glob('*/codex-*')))
            self.assertFalse((self.repo/'state/pr-authoring/previews').exists())

        def test_removed_draft_is_not_repaired_at_invoke(self):
            path = self.repo/'state/pr-authoring/T-035.json'; path.unlink()
            self.assert_no_model_start(); self.assertFalse(path.exists())

        def test_stale_billing_draft_is_not_repaired_at_invoke(self):
            with (self.repo/'config.yaml').open('a') as config:
                config.write('billing:\n  codex: api-key\n')
            self.assert_no_model_start()


def seed_fixture(task, evidence_project):
    """Explicit disposable-fixture authoring, never called at invoke time."""
    import os
    from fm_spec_pins import Pins
    pins = Pins(os.environ, task)
    event_path = pins.state / 'events.jsonl'
    event_path.parent.mkdir(parents=True, exist_ok=True)
    if pins.approval(None) is None:
        with event_path.open('a') as out:
            out.write(json.dumps(dict(type='greenlit', actor='captain', task=task,
                                      project=pins.project, ts='2026-10-03T00:00:00Z'))+'\n')
    pin = pins.resolve(if_present=True)
    if pin: snapshots = pin['snapshots']
    else:
        try: _, _, snapshots, _ = pins.collect()
        except (ValueError, OSError):
            _, _, snapshots, _, _ = pr.authority(task, evidence_project)
    spec = json.loads(snapshots['spec']['text'])
    draft = dict(schema=1, task=task, sources=pr.source_digests(snapshots),
                 subject='Show the approved fixture result', size='small',
                 problem='The fixture needs an observable approved result.',
                 expected_result='The assigned fixture behavior is observable.',
                 approach='Implement the approved fixture behavior within its scope.',
                 intent_notes=[dict(index=0, note='Exercise the approved fixture purpose.')])
    # Some historical replay fixtures deliberately have no acceptance lines.
    # Their real dispatched task is T-Z, whose own acceptance remains present.
    pr.validate(draft, spec, draft['sources'], pins.approval(None))
    pr.save(pr.state_path(pins.state, 'pr-authoring/'+task+'.json'), draft)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--seed': seed_fixture(sys.argv[2], sys.argv[3])
    else: unittest.main(verbosity=2)
