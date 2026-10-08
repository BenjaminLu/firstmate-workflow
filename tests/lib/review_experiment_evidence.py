"""Feature-owned factual evidence admission and immutable transport fixtures."""
import copy
import hashlib
import importlib
import json
import os
import shutil
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(sys.argv.pop()).resolve()
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / 'bin/lib'))
from fm_evidence import Store


def digest(data):
    return hashlib.sha256(data).hexdigest()


class ExperimentFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'user.name', 'fixture')
        self.git('config', 'remote.origin.url', 'https://github.com/fixture/project.git')
        (self.repo / 'reader.py').write_bytes(b'locked reader\n')
        (self.repo/'design/tasks').mkdir(parents=True)
        (self.repo/'design/tasks/T-264.json').write_text(json.dumps(dict(
            id='T-264', scope=['feature'], acceptance=['locked reader assertion', 'locked comparison'])))
        (self.repo/'design/design.md').write_text('Prefeature approved design\n')
        (self.repo/'config.yaml').write_text('project:\n  check: true\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'old')
        self.old = self.git('rev-parse', 'HEAD').decode().strip()
        (self.repo / 'feature').write_text('base')
        self.git('add', '.')
        self.git('commit', '-qm', 'base')
        self.base = self.git('rev-parse', 'HEAD').decode().strip()
        (self.repo / 'feature').write_text('head')
        self.git('add', '.')
        self.git('commit', '-qm', 'head')
        self.head = self.git('rev-parse', 'HEAD').decode().strip()
        self.bundle = self.root / 'bundle'
        self.bundle.mkdir()
        self.manifest = dict(version=1, producer='operator-attested-existing', project='self',
                             task='T-264', repository='fixture/project', head=self.head,
                             base=self.base, bundle_root=str(self.bundle), experiments=[])
        self.manifest['experiments'] = [self.experiment()]
        self.env = patch.dict(os.environ, {'FM_TARGET_ROOT': str(self.repo), 'FM_ROLE': '',
                            'FM_IN_ROUND': '', 'FM_RUN_DIR': '', 'HERDR_ENV': '',
                            'FM_EXTERNAL': '0', 'GH_REPO': 'fixture/project'})
        self.env.start()
        self.addCleanup(self.env.stop)

    def crew_environments(self):
        for marker in ({'FM_ROLE': 'worker'}, {'FM_ROLE': 'reviewer'},
                       {'FM_IN_ROUND': '1'}, {'FM_RUN_DIR': '/private/round'}):
            for host in ('', '1'):
                yield dict(marker, HERDR_ENV=host)

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.repo), *args], check=True,
                              capture_output=True).stdout

    def artifact(self, name, data):
        (self.bundle / name).write_bytes(data)
        return dict(name=name, path=name, sha256=digest(data), media_type='text/plain', truncated=False)

    def experiment(self):
        return dict(id='mutation', classification='current', source_sha=self.head,
                    argv=['producer-that-must-never-start', '--private'],
                    claimed_result=dict(exit_code=1, signal=None, timeout=False),
                    expectation='expected unlocked-reader assertion failure',
                    artifacts=[self.artifact('log', b'ASSERTION FAILED: unlocked reader\n')])

    def historical(self, source=None):
        e = self.experiment()
        e.update(classification='historical', source_sha=source or self.old)
        original = self.artifact('original-reader', b'locked reader\n')
        overlay = self.artifact('unlocked-reader', b'unlocked reader\n')
        probe = self.artifact('probe', b'assert reader_is_locked\n')
        e['artifacts'] += [original, overlay, probe]
        e['historical'] = dict(reviewed_head=self.head, acceptance_index=1,
                              historical_base_sha=e['source_sha'], overlays=[
            dict(target_path='reader.py', operation='replace',
                 input=dict(state='present', artifact=original['name'], sha256=original['sha256']),
                 overlay=dict(artifact=overlay['name'], sha256=overlay['sha256'])),
            dict(target_path='probe.py', operation='add', input=dict(state='absent'),
                 overlay=dict(artifact=probe['name'], sha256=probe['sha256']))])
        return e

    def validate(self, manifest=None):
        value = manifest or self.manifest
        path = self.bundle / 'manifest.json'
        path.write_text(json.dumps(value))
        return self.module.validate_manifest(path, 'self', 'T-264', self.head, self.base,
                                             'fixture/project', 2, self.repo)

    def frozen_contract(self):
        from fm_spec_pins import Pins
        shutil.copytree(ROOT/'bin', self.repo/'bin')
        shutil.copytree(ROOT/'skills', self.repo/'skills')
        os.environ.update(FM_ENGINE_ROOT=str(self.repo), FM_PROJECT='firstmate-workflow',
                          FM_STATE_DIR=str(self.repo/'state'), FM_TASKS_DIR=str(self.repo/'design/tasks'),
                          FM_DESIGN=str(self.repo/'design/design.md'), FM_BASE='main',
                          FM_TASK='T-264', FM_EVIDENCE_PROJECT='self')
        state = self.repo/'state'
        state.mkdir()
        event = dict(type='greenlit', actor='captain', task='T-264',
                     project='firstmate-workflow', ts='2026-10-01T00:00:00Z')
        (state/'events.jsonl').write_text(json.dumps(event)+'\n')
        self.pin = Pins(dict(os.environ), 'T-264').create()
        spec = importlib.util.spec_from_file_location('snapshot_fixture', ROOT/'bin/fm-herdr.py')
        engine = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(engine)
        self.code = engine.snapshot(self.repo)
        self.store = Store(state, 'self', 'T-264')
        return self.store

    def retained(self):
        path = self.bundle/'manifest.json'
        path.write_text(json.dumps(self.manifest))
        return self.module.retain(self.store, argparse.Namespace(file=str(path), head=self.head,
                                  base=self.base, code=str(self.code), round=1))

    def checkout(self, name='checkout'):
        tree = self.root/name
        subprocess.run(['git', 'clone', '-q', '--no-hardlinks', str(self.repo), str(tree)], check=True,
                       capture_output=True)
        subprocess.run(['git', '-C', str(tree), 'remote', 'remove', 'origin'], check=True)
        subprocess.run(['git', '-C', str(tree), 'checkout', '-q', '--detach', self.head], check=True)
        for ref, sha in (('refs/fm/head', self.head), ('refs/fm/base', self.base)):
            subprocess.run(['git', '-C', str(tree), 'update-ref', ref, sha], check=True)
        return tree

class Experiments(ExperimentFixture):
    def setUp(self):
        # Keep the separate API fail-first assertion before the lazy import.
        self.assertTrue(hasattr(Store, 'experiments'), 'Store must collect exact-bound experiments separately')
        self.module = importlib.import_module('fm_experimental_evidence')
        super().setUp()

    def test_real_pin_signed_retention_and_readonly_copies(self):
        self.frozen_contract()
        record = self.retained()
        self.assertEqual(record['actor'], 'firstmate')
        self.assertEqual(record['provenance'], self.module.PROVENANCE)
        self.assertTrue(record['signature'])
        records, unavailable = self.store.experiments(self.head, self.base, self.code)
        self.assertEqual(records, [record])
        self.assertFalse(unavailable)
        tree = self.checkout()
        text, index, count = self.module.attach(self.store, records, [], 'run', tree)
        self.assertEqual(count, 1)
        self.assertIn('Current-head attested experiments', text)
        self.assertIn('"exit_code": 1', text)
        self.assertIn('Execution unverified by stock', text)
        self.assertIn('ASSERTION FAILED', (Path(index).parent/record['experiments'][0]['artifacts'][0]['sha256']).read_text())
        self.assertEqual('', subprocess.check_output(['git', '-C', str(tree), 'status', '--porcelain'], text=True).strip())
        original = self.store.records()[0]
        (self.bundle/'log').write_text('producer changed source')
        self.assertEqual(original, self.store.records()[0])
        self.assertNotIn('operator-attested', self.store.history(True))

    def test_pin_and_snapshot_refusals_before_storage(self):
        self.frozen_contract()
        pinpath = self.repo/'state/pins/T-264/1.json'
        original = pinpath.read_bytes()
        pinpath.unlink()
        with self.assertRaises(ValueError):
            self.retained()
        self.assertFalse(self.store.key_path.exists())
        pinpath.write_bytes(original)
        candidate = json.loads(original)
        candidate['snapshots']['spec']['sha256'] = '0'*64
        pinpath.write_text(json.dumps(candidate))
        with self.assertRaises(ValueError):
            self.retained()
        pinpath.write_bytes(original)
        code = self.code
        self.code = self.repo
        with self.assertRaises(ValueError):
            self.retained()
        alias = self.repo/'state/snapshots/code-alias'
        alias.symlink_to(code, target_is_directory=True)
        self.code = alias
        with self.assertRaises(ValueError):
            self.retained()
        self.code = code
        (code/'bin/lib/fm_evidence.py').write_text('altered inventory')
        with self.assertRaises(ValueError):
            self.retained()
        self.assertFalse(self.store.key_path.exists())

    def test_exact_identity_and_signed_corruption_matrix(self):
        self.frozen_contract()
        record = self.retained()
        path = next(self.store.directory.glob('[0-9]*.json'))
        for field in ('head', 'base', 'patch', 'files', 'project', 'repository',
                      'spec_sha256', 'contract_sha256', 'conventions_sha256', 'engine_sha256'):
            candidate = copy.deepcopy(record)
            candidate['binding'][field] = [] if field == 'files' else 'mismatch'
            candidate['signature'] = self.store.signature(candidate)
            path.write_text(json.dumps(candidate))
            selected, missing = self.store.experiments(self.head, self.base, self.code)
            self.assertEqual(selected, [], field)
            self.assertTrue(missing, field)
        path.write_text(json.dumps(record))
        artifact = record['experiments'][0]['artifacts'][0]
        stored = self.store.directory/artifact['path']
        stored.chmod(0o600)
        stored.write_text('tampered')
        with self.assertRaises(ValueError):
            self.store.experiments(self.head, self.base, self.code)
        stored.unlink()
        selected, missing = self.store.experiments(self.head, self.base, self.code)
        self.assertFalse(selected)
        self.assertIn('missing', missing[0])
        candidate = copy.deepcopy(record)
        candidate['head'] = '0'*40
        path.write_text(json.dumps(candidate))
        with self.assertRaises(ValueError):
            self.store.experiments(self.head, self.base, self.code)

    def test_signed_forged_execution_receipts_rejected(self):
        self.frozen_contract()
        record = self.retained()
        path = next(self.store.directory.glob('[0-9]*.json'))
        for field, value in [('producer', 'authenticated'), ('measured_result', {'exit_code':0}),
                             ('experiment_version', 2), ('provenance', {'level':'stock-captured'})]:
            candidate = copy.deepcopy(record)
            candidate[field] = value
            candidate['signature'] = self.store.signature(candidate)
            path.write_text(json.dumps(candidate))
            with self.assertRaises(ValueError):
                self.store.experiments(self.head, self.base, self.code)

    def test_migration_unchanged_pin_old_new_sessions_and_verdict_authority(self):
        self.frozen_contract()
        pinpath = self.repo/'state/pins/T-264/1.json'
        before = pinpath.read_bytes()
        oldround = self.root/'old-round'
        oldround.mkdir()
        oldsnapshot = oldround/'snapshot'
        shutil.copytree(self.code, oldsnapshot)
        (oldsnapshot/'bin/lib/fm_experimental_evidence.py').unlink()
        (oldround/'prompt.md').write_text('Old reviewer prompt with no experiments\n')
        (oldround/'receipt.json').write_text('{"level":"legacy","review":"old"}')
        oldbytes = {str(p.relative_to(oldround)): p.read_bytes() for p in oldround.rglob('*') if p.is_file()}
        # Coexisting old/new disposable roots are separate; no running sessions.
        oldtree = self.checkout('old-checkout')
        oldprompt = oldround/'prompt.md'
        record = self.retained()
        newtree = self.checkout('new-checkout')
        records, _ = self.store.experiments(self.head, self.base, self.code)
        text, index, _ = self.module.attach(self.store, records, [], 'run', newtree)
        self.assertIn(str(newtree), text)
        self.assertNotIn(str(oldtree), text)
        self.assertFalse(list((oldtree/'.git').glob('.fm-review-experiments-*')))
        self.assertEqual(oldbytes, {str(p.relative_to(oldround)): p.read_bytes() for p in oldround.rglob('*') if p.is_file()})
        self.assertNotIn('experimental', oldprompt.read_text())
        self.assertEqual(before, pinpath.read_bytes(), 'additive evidence must not repin approved inputs')
        verdict = self.store.append('verdict', 1, 'reviewer', self.head, 'APPROVE:T-264',
                                    verdict='APPROVE', base=self.base, patch=record['binding']['patch'],
                                    binding=record['binding'], provenance={'level':'legacy'})
        self.assertEqual(self.store.verdicts(), [verdict])
        self.assertEqual('legacy', verdict['provenance']['level'])
        oldcopy = Path(index).read_bytes()
        # An old-current record selects only its exact old reviewed head, even
        # when the newer change has the same patch id (empty commit).
        self.git('commit', '-q', '--allow-empty', '-m', 'new review identity')
        newhead = self.git('rev-parse', 'HEAD').decode().strip()
        selected, missing = self.store.experiments(newhead, self.base, self.code)
        self.assertFalse(selected)
        self.assertTrue(missing)
        self.assertEqual(record, self.store.records()[0])
        self.assertEqual(oldcopy, Path(index).read_bytes())

    def test_historical_migration_preserves_negative_and_locked_comparison(self):
        self.frozen_contract()
        negative = self.historical()
        comparison = copy.deepcopy(negative)
        comparison['id'] = 'locked-comparison'
        comparison['claimed_result']['exit_code'] = 0
        comparison['expectation'] = 'locked reader assertion passes in declared historical comparison'
        comparison['artifacts'] = [dict(a) for a in comparison['artifacts']]
        comparison['artifacts'][2] = self.artifact('locked-reader', b'locked comparison overlay\n')
        comparison['historical']['overlays'][0]['overlay'] = dict(artifact='locked-reader', sha256=digest(b'locked comparison overlay\n'))
        self.manifest['experiments'] = [negative, comparison]
        record = self.retained()
        records, _ = self.store.experiments(self.head, self.base, self.code)
        text, index, _ = self.module.attach(self.store, records, [], 'run', self.checkout())
        current, historical = text.split('## Historical negative/control evidence', 1)
        self.assertNotIn('locked-comparison', current)
        self.assertIn('locked-comparison', historical)
        self.assertIn('"exit_code": 1', historical)
        self.assertIn(self.old, historical)
        self.assertIn('not stock approval proof', historical)
        self.assertEqual(record['experiments'][0]['source_sha'], self.old)
        self.assertEqual(record['experiments'][0]['historical']['historical_base_sha'], self.old)
        self.assertIn(b'assert reader_is_locked\n', [(Path(index).parent/a['sha256']).read_bytes()
                      for a in record['experiments'][0]['artifacts']])

    def test_changed_frozen_engine_and_authorized_pin_exclude_old_receipts(self):
        from fm_spec_pins import Pins
        self.frozen_contract()
        record = self.retained()
        old_manifest = (self.code/'manifest.json').read_bytes()
        source = self.repo/'bin/lib/fm_evidence.py'
        source.write_bytes(source.read_bytes()+b'\n# new frozen engine revision\n')
        spec = importlib.util.spec_from_file_location('new_snapshot_fixture', ROOT/'bin/fm-herdr.py')
        engine = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(engine)
        newcode = engine.snapshot(self.repo)
        selected, unavailable = self.store.experiments(self.head, self.base, newcode)
        self.assertFalse(selected)
        self.assertTrue(unavailable)
        self.assertEqual(old_manifest, (self.code/'manifest.json').read_bytes())
        self.assertEqual(record, self.store.records()[0])
        task = self.repo/'design/tasks/T-264.json'
        value = json.loads(task.read_text())
        value['acceptance'].append('new authorized acceptance input')
        task.write_text(json.dumps(value))
        decision = 'fixture-repin'
        answer = dict(id=decision, task='T-264', project='firstmate-workflow', chosen='A',
                      kind='choice', ts='2026-10-02T00:00:00Z')
        decisions = self.repo/'state/decisions'
        decisions.mkdir()
        (decisions/(decision+'.json')).write_text(json.dumps(answer))
        event = dict(type='decision_made', actor='captain', task='T-264', project='firstmate-workflow',
                     ts=answer['ts'], data=dict(decision=decision, chosen='A'))
        with (self.repo/'state/events.jsonl').open('a') as output:
            output.write(json.dumps(event)+'\n')
        before = (self.repo/'state/pins/T-264/1.json').read_bytes()
        Pins(dict(os.environ), 'T-264').create(decision=decision)
        selected, unavailable = self.store.experiments(self.head, self.base, self.code)
        self.assertFalse(selected)
        self.assertTrue(unavailable)
        self.assertEqual(before, (self.repo/'state/pins/T-264/1.json').read_bytes())
        self.assertEqual(record, self.store.records()[0])

    def test_small_large_context_and_rebuilt_copy_paths(self):
        import fm_review_context as context
        self.frozen_contract()
        self.retained()
        work = self.root/'work'
        work.mkdir()
        for name in context.PARTS:
            (work/(name+'.md')).write_text('complete criteria\n' if name == 'intro' else '')
        (work/'pins.json').write_text(json.dumps(dict(head=self.head, base=self.base,
               patch=self.store.records()[0]['binding']['patch'], files=['feature'])))
        tree = self.checkout()
        context.prepare_experiments(work, 'run', str(tree), self.head, self.base, str(self.code))
        context.compose(work, 'run', str(tree))
        first = json.loads((work/'experiment-status.json').read_text())['index']
        self.assertIn(str(Path(first).parent), (work/'prompt.md').read_text())
        self.assertFalse((work/'evidence-path.txt').exists())
        # Both refresh paths use this same reconstruction, independently of an
        # old archive. Exercise a new root and a destroyed/recreated same root.
        for name in ('retry-checkout', 'retry-checkout'):
            refresh = self.root/name
            if refresh.exists():
                shutil.rmtree(refresh)
            refresh = self.checkout(name)
            context.prepare_experiments(work, 'run', str(refresh), self.head, self.base, str(self.code))
            context.compose(work, 'run', str(refresh))
            fresh = json.loads((work/'experiment-status.json').read_text())['index']
            self.assertTrue(Path(fresh).is_file())
            self.assertNotIn(first, (work/'prompt.md').read_text())
            self.assertIn(str(Path(fresh).parent), (work/'prompt.md').read_text())
        (work/'diff.md').write_text('large diff\n' * 100000)
        context.compose(work, 'run', str(refresh))
        self.assertIn('complete criteria', (work/'prompt.md').read_text())
        self.assertIn(str(Path(fresh).parent), (work/'prompt.md').read_text())
        self.assertTrue((work/'evidence-path.txt').exists())
        text, index, _ = self.module.attach(self.store, self.store.experiments(self.head, self.base, self.code)[0], [], 'diff', '')
        self.assertEqual(index, '')
        self.assertIn('files inaccessible', text)
        self.assertNotIn('readonly_path', text)

    def test_summary_privacy_and_precise_unsigned_migration(self):
        from fm_evidence import summary
        self.frozen_contract()
        self.manifest['experiments'][0]['expectation'] = 'PRIVATE-ARTIFACT-SENTINEL'
        record = self.retained()
        projection = json.dumps(summary(self.store))
        for secret in ('PRIVATE-ARTIFACT-SENTINEL', record['signature'], 'producer-that-must-never-start',
                       record['experiments'][0]['artifacts'][0]['sha256']):
            self.assertNotIn(secret, projection)
        self.assertIn('"provenance_level": "unverified"', projection)
        for number, kind in enumerate(('brief', 'pack', 'worker-report', 'ask', 'verdict'), 10):
            value = dict(project='self', task='T-264', kind=kind, actor='fixture', round=1,
                         head=self.head, text='legacy', provenance={'level':'legacy'})
            path = self.store.directory/(f'{number:08d}-legacy.json')
            path.write_text(json.dumps(value))
            self.assertIn(value, self.store.records())
        for kind in ('readiness', 'experimental-evidence', 'projection', 'external-verdict', 'spec-preflight'):
            value['kind'] = kind
            path.write_text(json.dumps(value))
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                self.store.records()

    def adapter_fixture(self):
        self.frozen_contract()
        self.retained()
        tree = self.checkout()
        records, _ = self.store.experiments(self.head, self.base, self.code)
        _, index, _ = self.module.attach(self.store, records, [], 'run', tree)
        tools = tree/'.git/fixture-cli'
        tools.mkdir()
        vendor = tools/'codex'
        artifact = Path(index).parent/records[0]['experiments'][0]['artifacts'][0]['sha256']
        probe = '''#!/usr/bin/env python3
import json, pathlib, sys
root = pathlib.Path.cwd()
(root/'model-entered').write_text('CLI entered')
artifact = pathlib.Path(ARTIFACT)
assert artifact.read_bytes() == b'ASSERTION FAILED: unlocked reader\\n'
denied = []
for action in (lambda: artifact.chmod(0o600), lambda: artifact.write_text('altered'), lambda: artifact.unlink(),
               lambda: pathlib.Path(KEY).read_bytes(), lambda: pathlib.Path(PRIVATE).read_bytes(),
               lambda: pathlib.Path(PARENT).read_bytes()):
    try:
        action()
    except OSError:
        denied.append(True)
    else:
        raise AssertionError('real OS confinement permitted private read or metadata write')
(root/'model-started.json').write_text(json.dumps({'denied':len(denied),'artifact_read':True}))
sys.stdin.read()
for event in [{'type':'turn.started'}, {'type':'item.completed','item':{'type':'agent_message',
               'text':'APPROVE:T-264\\nREVIEWER_COMPLETE:T-264'}}, {'type':'turn.completed','usage':{}}]:
    print(json.dumps(event))
'''
        parent = self.root/'parent-secret'
        parent.write_text('ungranted parent sentinel')
        private = self.store.state/'private-session'
        private.write_text('private session sentinel')
        for placeholder, value in (('ARTIFACT', str(artifact)), ('KEY', str(self.store.key_path)),
                                   ('PRIVATE', str(private)), ('PARENT', str(parent))):
            probe = probe.replace(placeholder, repr(value))
        vendor.write_text(probe)
        vendor.chmod(0o755)
        policy = subprocess.check_output(['bash', '-c',
            '. "$1/bin/fm-config.sh"; fm_policy reviewer "" "$2"', 'fixture', str(self.code),
            str(self.repo/'config.yaml')], text=True)
        document = json.loads(policy)
        document['vendors']['codex']['login'] = {}
        policyfile = self.root/'policy.json'
        policyfile.write_text(json.dumps(document))
        prompt = self.root/'prompt.md'
        prompt.write_text('Judge the factual declared experiments independently.')
        attempt = self.root/'adapter-attempt'
        attempt.mkdir()
        env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_', 'GIT_', 'CODEX_', 'CMUX_', 'TMUX'))}
        env.update(PATH=str(tools)+os.pathsep+os.environ['PATH'], HOME=str(self.root), TMPDIR=str(self.root),
                   FM_CONTEXT_READY='1', FM_RUN_REVIEW='1', FM_ROLE='reviewer', FM_TASK='T-264',
                   FM_ACTOR='reviewer-fixture-t264-r1', FM_ATTEMPT_DIR=str(attempt),
                   FM_REVIEW_CHECKOUT=str(tree), FM_REVIEW_HEAD=self.head, FM_REVIEW_BASE=self.base,
                   FM_REVIEW_PATCH=records[0]['binding']['patch'], FM_POLICY=str(policyfile),
                   FM_REVIEW_EXPERIMENT_INDEX=index, FM_MODEL='fixture-model',
                   FM_ENGINE_ROOT=str(self.repo), FM_TRANSPORT='direct')
        spec = importlib.util.spec_from_file_location('adapter_managed', self.code/'bin/fm-herdr.py')
        engine = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(engine)
        adapter = self.code/'bin/adapters/codex.sh'
        (attempt/'invocation.json').write_text(json.dumps(dict(adapter=str(adapter),
            actor=env['FM_ACTOR'], role='reviewer', task='T-264', review=engine.review_context(env))))
        def run(**extra):
            return subprocess.run(['bash', str(adapter), 'run', str(prompt), str(tree), str(self.root/'adapter.log')],
                                  env=dict(env, **extra), capture_output=True, text=True, timeout=120)
        return run, tree, policyfile, document, env

    def test_actual_codex_adapter_real_os_reads_and_refuses_metadata_writes(self):
        run, tree, _, _, _ = self.adapter_fixture()
        tool = 'sandbox-exec' if sys.platform == 'darwin' else 'bwrap'
        self.assertTrue(shutil.which(tool, path=os.defpath), 'real OS confinement is required, not a shape-only substitute')
        result = run()
        self.assertEqual(result.returncode, 0, result.stderr + (self.root/'adapter.log').read_text())
        observed = json.loads((tree/'model-started.json').read_text())
        self.assertEqual(observed, dict(denied=6, artifact_read=True))
        self.assertEqual(self.module.PROVENANCE, self.store.records()[0]['provenance'])
        self.assertEqual(1, self.store.records()[0]['experiments'][0]['claimed_result']['exit_code'])

    def test_actual_adapter_unsupported_policy_marker_and_missing_verifier_refuse_model(self):
        run, tree, policyfile, document, env = self.adapter_fixture()
        cases = [dict(FM_ROUND_UNSANDBOXED='1'), dict(FM_REVIEW_EXPERIMENT_INDEX=str(self.root/'index.json')),
                 dict(FM_SANDBOX_TOOL='/bin/echo'), dict(FM_SANDBOX_OS='unsupported')]
        for extra in cases:
            result = run(**extra)
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertFalse((tree/'model-entered').exists())
            self.assertFalse((tree/'model-started.json').exists())
        for value in ({'role':'worker'}, {'write':['{root}','{tmp}','/private']}):
            policyfile.write_text(json.dumps(dict(document, **value)))
            self.assertNotEqual(run().returncode, 0)
            self.assertFalse((tree/'model-entered').exists())
            self.assertFalse((tree/'model-started.json').exists())
        policyfile.write_text(json.dumps(document))
        module = self.code/'bin/lib/fm_review_context.py'
        module.unlink()
        self.assertNotEqual(run().returncode, 0)
        self.assertFalse((tree/'model-entered').exists())
        self.assertFalse((tree/'model-started.json').exists())

    def test_actual_adapter_final_launch_and_policy_tampering_refuse_before_cli(self):
        run, tree, _, _, _ = self.adapter_fixture()
        library = self.code/'bin/adapters/_lib.sh'
        original = library.read_text()
        start = original.index('fm_adapter_confine() {')
        end = original.index('\n}\n', start) + 3
        preserved = original[start:end].replace('fm_adapter_confine() {', 'fixture_original_confine() {', 1)
        # Controlled fixture perturbation happens after the actual stock adapter
        # derives its private policy, at the final confinement boundary.
        for mutation in ('FM_LAUNCH[1]=plain', 'FM_LAUNCH[0]=/bin/echo',
                         'FM_LAUNCH+=(--write=/private)', 'printf "{}" > "$FM_POLICY"'):
            library.write_text(original+'\n'+preserved+'\nfm_adapter_confine() {\n'
                               'fixture_original_confine "$@"\n'+mutation+'\n}\n')
            result = run()
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertFalse((tree/'model-entered').exists(), mutation)
        library.write_text(original)

    def test_final_policy_and_actual_launch_vector_matrix(self):
        import fm_review_context as context
        self.frozen_contract()
        self.retained()
        tree = self.checkout()
        records, _ = self.store.experiments(self.head, self.base, self.code)
        _, index, _ = self.module.attach(self.store, records, [], 'run', tree)
        tmp = self.root/'round-tmp'
        ctl = self.root/'round-ctl'
        tmp.mkdir(); ctl.mkdir()
        policy = ctl/'review-policy.json'
        data = json.dumps(dict(role='reviewer', write=['{root}','{tmp}'], review_git_readonly=True)).encode()
        policy.write_bytes(data)
        args = argparse.Namespace(policy=str(policy), policy_sha256=digest(data),
                outer_os='darwin' if sys.platform == 'darwin' else 'linux', unsandboxed='',
                tree=str(tree), tmp=str(tmp), ctl=str(ctl), index=index,
                launch=[str(ROOT/'bin/fm-sandbox.sh'), 'run', '--policy='+str(policy),
                        '--root='+str(tree), '--tmp='+str(tmp), '--vendor=codex',
                        '--ctl='+str(ctl), '--started='+str(ctl/'started'), '--'])
        # An injected tool lookup here is only a verifier unit fixture. The
        # actual-adapter test above separately requires real OS execution.
        with patch.object(context.shutil, 'which', return_value='/usr/bin/fixture-sandbox'):
            context.verify_effective_experiment_policy(args)
            for field, value in [('unsandboxed', '1'), ('outer_os', 'none'), ('policy_sha256', '0'*64),
                                 ('index', str(self.root/'index.json'))]:
                modified = copy.deepcopy(args)
                setattr(modified, field, value)
                with self.subTest(field=field), self.assertRaises(ValueError):
                    context.verify_effective_experiment_policy(modified)
            for variant in (['/bin/echo', *args.launch[1:]], [args.launch[0], 'plain', *args.launch[2:]],
                            [*args.launch[:-1], '--write=/private', '--'],
                            [*args.launch[:-1], '--root='+str(self.repo), '--']):
                modified = copy.deepcopy(args)
                modified.launch = variant
                with self.assertRaises(ValueError):
                    context.verify_effective_experiment_policy(modified)
            policy.write_text('{}')
            with self.assertRaises(ValueError):
                context.verify_effective_experiment_policy(args)

    def test_external_whole_body_projection_privacy_with_private_signed_verdict(self):
        from fm_evidence import retain_verdict, summary
        self.frozen_contract()
        record = self.retained()
        run = self.root/'verdict-run'
        run.mkdir()
        private = 'PRIVATE-ARTIFACT-SENTINEL argv /private/artifact\nAPPROVE:T-264'
        (run/'identity.json').write_text(json.dumps(dict(project='self', task='T-264', role='reviewer', round=1)))
        (run/'evidence-binding.json').write_text(json.dumps(record['binding']))
        (run/'final.txt').write_text(private)
        with patch.dict(os.environ, FM_ACTOR='reviewer-fixture'):
            verdict = retain_verdict(self.store, argparse.Namespace(run=str(run), head=self.head,
                base=self.base, patch=record['binding']['patch'], round=1, vendor='legacy',
                code=str(self.code), attempt='fixture', file=str(run/'final.txt')))
        self.assertEqual(verdict['text'], private)
        self.assertEqual(verdict['verdict'], 'APPROVE')
        self.assertTrue(verdict['signature'])
        script = (ROOT/'bin/fm-review.sh').read_text()
        start = script.index('if [ -n "$PR" ] && [ "$projection" = comments ]; then')
        end = script.index('if [ "$FM_EXTERNAL" = 1 ] && [ -n "$PR" ] && [ "$projection" != comments ]; then', start)
        block = script[start:end]
        for policy in ('fm', 'external', 'both'):
            projection = self.root/'projection'
            events = self.root/'events'
            env = dict(os.environ, FM_EXTERNAL='1', experiment_count='1', project_review=policy,
                       PR='9', projection='comments', TASK='T-264', R_HEAD=self.head,
                       decided='APPROVE', evidence_ref='experiment-review-T-264-1', verdict=private,
                       OUTPUT=str(projection), EVENTS=str(events))
            result = subprocess.run(['bash', '-c',
                'fm_comment_projection() { printf "%s" "$3" > "$OUTPUT"; };\n'
                'emit() { printf "%s\\n" "$*" >> "$EVENTS"; };\n'+block],
                env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(self.head, projection.read_text())
            for output in (projection.read_text(), json.dumps(summary(self.store)), events.read_text() if events.exists() else ''):
                self.assertNotIn('PRIVATE-ARTIFACT-SENTINEL', output)
                self.assertNotIn(record['signature'], output)
                self.assertNotIn('/private/artifact', output)
        # No-experiment projection retains its historical body behavior.
        env['experiment_count'] = '0'; env['project_review'] = 'fm'
        subprocess.run(['bash', '-c', 'fm_comment_projection() { printf "%s" "$3" > "$OUTPUT"; };\n'+block],
                       env=env, check=True)
        self.assertIn('PRIVATE-ARTIFACT-SENTINEL', projection.read_text())

    def test_claimed_failure_never_executes(self):
        with patch('subprocess.run', side_effect=AssertionError('producer execution')):
            result, blobs = self.validate()
        self.assertEqual(result['experiments'][0]['claimed_result']['exit_code'], 1)
        self.assertEqual(blobs[digest(b'ASSERTION FAILED: unlocked reader\n')], b'ASSERTION FAILED: unlocked reader\n')

    def test_current_source_must_equal_head(self):
        self.manifest['experiments'][0]['source_sha'] = self.old
        with self.assertRaises(ValueError):
            self.validate()

    def test_historical_boundary_ancestors_and_full_associations(self):
        for source in (self.old, self.base):
            self.manifest['experiments'] = [self.historical(source)]
            value, blobs = self.validate()
            self.assertEqual(value['experiments'][0]['source_sha'], source)
            self.assertEqual(value['experiments'][0]['claimed_result']['exit_code'], 1)
            self.assertIn(b'locked reader\n', blobs.values())
            self.assertIn(b'unlocked reader\n', blobs.values())

    def test_historical_descriptor_negative_matrix(self):
        self.manifest['experiments'] = [self.historical()]
        cases = []
        for index in (0, 3, True):
            cases.append(('index', lambda e, n=index: e['historical'].update(acceptance_index=n)))
        cases.extend([
            ('missing-input', lambda e: e['historical']['overlays'][0].pop('input')),
            ('missing-input-hash', lambda e: e['historical']['overlays'][0]['input'].pop('sha256')),
            ('wrong-input-hash', lambda e: e['historical']['overlays'][0]['input'].update(sha256='0'*64)),
            ('wrong-source-blob', lambda e: e['historical']['overlays'][0]['input'].update(
                artifact='unlocked-reader', sha256=digest(b'unlocked reader\n'))),
            ('missing-overlay', lambda e: e['historical']['overlays'][0].pop('overlay')),
            ('missing-overlay-artifact', lambda e: e['artifacts'].pop(2)),
            ('same-input-overlay', lambda e: e['historical']['overlays'][0].update(
                overlay=dict(artifact='original-reader', sha256=digest(b'locked reader\n')))),
            ('cross-experiment', lambda e: e['historical']['overlays'][0]['overlay'].update(artifact='other')),
            ('wrong-overlay-hash', lambda e: e['historical']['overlays'][0]['overlay'].update(sha256='0'*64)),
            ('traversal', lambda e: e['historical']['overlays'][0].update(target_path='../reader.py')),
            ('duplicate', lambda e: e['historical']['overlays'].append(copy.deepcopy(e['historical']['overlays'][0]))),
            ('present-add', lambda e: e['historical']['overlays'][1].update(input=dict(state='present'))),
            ('existing-add', lambda e: e['historical']['overlays'][1].update(target_path='reader.py')),
            ('unknown', lambda e: e['historical'].update(approval=True)),
            ('ancestor-head-only', lambda e: e.update(source_sha=self.head) or e['historical'].update(historical_base_sha=self.head)),
            ('missing-object', lambda e: e.update(source_sha='0'*40) or e['historical'].update(historical_base_sha='0'*40)),
        ])
        unrelated = self.git('commit-tree', self.git('rev-parse', 'HEAD^{tree}').decode().strip(),
                             '-m', 'unrelated history').decode().strip()
        cases.append(('nonancestor', lambda e: e.update(source_sha=unrelated)
                      or e['historical'].update(historical_base_sha=unrelated)))
        original = copy.deepcopy(self.manifest)
        for name, mutate in cases:
            with self.subTest(name=name):
                candidate = copy.deepcopy(original)
                mutate(candidate['experiments'][0])
                with self.assertRaises(ValueError):
                    self.validate(candidate)
        other = self.experiment()
        other['id'] = 'other-experiment'
        other['artifacts'] = [self.artifact('other', b'cross-experiment overlay\n')]
        candidate = copy.deepcopy(original)
        candidate['experiments'].append(other)
        candidate['experiments'][0]['historical']['overlays'][0]['overlay'] = dict(
            artifact='other', sha256=digest(b'cross-experiment overlay\n'))
        with self.assertRaises(ValueError):
            self.validate(candidate)

    def test_versions_producers_and_forged_receipts(self):
        for key, value in [('version', 2), ('producer', 'stock-captured'), ('signature', '0'*64),
                           ('measured_result', {}), ('signed_record', {})]:
            candidate = copy.deepcopy(self.manifest)
            candidate[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.validate(candidate)

    def test_artifact_safety_and_limits(self):
        original = copy.deepcopy(self.manifest)
        for path in ('../outside', '/etc/passwd', './log', 'a/../log', 'a\\log'):
            candidate = copy.deepcopy(original)
            candidate['experiments'][0]['artifacts'][0]['path'] = path
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.validate(candidate)
        (self.bundle / 'log').unlink()
        (self.bundle / 'log').symlink_to(self.repo / 'reader.py')
        with self.assertRaises((OSError, ValueError)):
            self.validate()
        (self.bundle / 'log').unlink()
        self.manifest['experiments'][0]['artifacts'] = [self.artifact('log', b'x' * (256*1024+1))]
        with self.assertRaises(ValueError):
            self.validate()
        self.manifest['experiments'][0]['artifacts'] = [self.artifact('a'+str(i), b'x' * (256*1024)) for i in range(9)]
        with self.assertRaises(ValueError):
            self.validate()
        self.manifest['experiments'][0]['artifacts'] = [self.artifact('a'+str(i), b'x') for i in range(17)]
        with self.assertRaises(ValueError):
            self.validate()

    def test_manifest_count_nonregular_and_changed_read(self):
        valid = self.bundle/'manifest.json'
        valid.write_bytes(b' ' * (64*1024) + json.dumps(self.manifest).encode())
        with self.assertRaises(ValueError):
            self.module.validate_manifest(valid, 'self', 'T-264', self.head, self.base,
                                          'fixture/project', 2, self.repo)
        candidate = copy.deepcopy(self.manifest)
        candidate['experiments'] *= 17
        with self.assertRaises(ValueError):
            self.validate(candidate)
        (self.bundle/'log').unlink()
        os.mkfifo(self.bundle/'log')
        with self.assertRaises(ValueError):
            self.validate()
        (self.bundle/'log').unlink()
        (self.bundle/'log').write_bytes(b'ASSERTION FAILED: unlocked reader\n')
        real_fstat = os.fstat
        calls = []
        def changed(fd):
            if calls:
                (self.bundle/'log').write_bytes(b'bytes changed during read')
            calls.append(fd)
            return real_fstat(fd)
        with patch.object(self.module.os, 'fstat', side_effect=changed), self.assertRaises(ValueError):
            self.module.regular_bytes(self.bundle, 'log', 256*1024)

    def test_import_local_git_allowlist_never_producer_or_helpers(self):
        self.frozen_contract()
        # A hostile helper configuration and declared command never execute.
        sentinel = self.root/'forbidden-execution'
        helper = self.root/'forbidden-helper'
        helper.write_text('#!/bin/sh\ntouch '+str(sentinel)+'\n')
        helper.chmod(0o755)
        self.git('config', 'core.fsmonitor', str(helper))
        self.git('config', 'credential.helper', str(helper))
        self.manifest['experiments'][0]['argv'] = [str(helper), 'login', 'fetch', 'model']
        real_run = subprocess.run
        commands = []
        def observed(argv, **kwargs):
            commands.append((argv, kwargs))
            self.assertEqual(Path(argv[0]).name, 'git')
            self.assertLessEqual(kwargs['timeout'], 120)
            self.assertEqual(kwargs['env']['GIT_CONFIG_GLOBAL'], os.devnull)
            return real_run(argv, **kwargs)
        with patch.object(self.module.subprocess, 'run', side_effect=observed):
            record = self.retained()
        self.assertTrue(commands)
        self.assertFalse(sentinel.exists())
        self.assertEqual(record['experiments'][0]['argv'][0], str(helper))
        for argv, _ in commands:
            self.assertFalse(set(('fetch','clone','push','ls-remote','login','model')) & set(argv))
        for env in self.crew_environments():
            with patch.dict(os.environ, env), patch.object(self.module.subprocess, 'run', side_effect=AssertionError('binding started')):
                with self.assertRaises(ValueError):
                    self.retained()

    def test_cli_fixed_actor_and_early_wrapper_python_admission(self):
        self.frozen_contract()
        self.manifest['project'] = 'firstmate-workflow'
        path = self.bundle/'manifest.json'
        path.write_text(json.dumps(self.manifest))
        args = ['experiment-retain', '--task', 'T-264', '--head', self.head, '--base', self.base,
                '--code', str(self.code), '--file', str(path), '--actor', 'forged-actor']
        wrapper = ['bash', str(self.code/'bin/lib/fm-evidence.sh'), *args,
                   '--repo', str(self.repo), '--project', 'firstmate-workflow']
        python = [sys.executable, str(self.code/'bin/lib/fm_evidence.py'), *args,
                  '--state', str(self.root/'refused-state'), '--project', 'firstmate-workflow']
        for env in self.crew_environments():
            for command in (wrapper, python):
                result = subprocess.run(command, env=dict(os.environ, **env), capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('outside-round operator', result.stderr)
                self.assertFalse((self.root/'refused-state').exists())
                self.assertFalse(self.store.key_path.exists())
        result = subprocess.run(wrapper, env=dict(os.environ, HERDR_ENV='1'), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        retained = Store(self.store.state, 'firstmate-workflow', 'T-264').records()[0]
        self.assertEqual(retained['actor'], 'firstmate')
        self.assertNotIn('measured_result', retained)
        result = subprocess.run(python, env=dict(os.environ, HERDR_ENV='1'), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        direct = Store(self.root/'refused-state', 'firstmate-workflow', 'T-264').records()[0]
        self.assertEqual(direct['actor'], 'firstmate')

    def test_actual_prepare_hook_refuses_fallback_and_hatch_before_model(self):
        source = (ROOT/'bin/fm-review.sh').read_text()
        start = source.index('prepare_review_attempt() {')
        end = source.index('\n}\n', start)+3
        block = source[start:end]
        capture = self.root/'attempt-called'
        prelude = ('emit() { printf "%s\\n" "$*"; };\n'
                   'rebuild_checkout() { touch "$CAPTURE"; };\n'
                   'context_checkout_matches() { return 0; };\n'
                   'restore_context_evidence() { return 0; };\n')
        env = dict(os.environ, REVIEW_MODE='run', experiment_count='1', unsandboxed='0',
                   checkout_attempted='1', CAPTURE=str(capture))
        result = subprocess.run(['bash', '-c', prelude+block+'prepare_review_attempt claude'],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 70)
        self.assertFalse(capture.exists())
        self.assertIn('no model called', result.stdout)
        self.assertIn('未呼叫模型', result.stdout)
        env['unsandboxed'] = '1'
        result = subprocess.run(['bash', '-c', prelude+block+'prepare_review_attempt codex'],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 70)
        self.assertFalse(capture.exists())
        env['experiment_count'] = '0'
        result = subprocess.run(['bash', '-c', prelude+block+'prepare_review_attempt claude'],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_actual_refresh_function_rebuilds_uncapped_and_archived_evidence(self):
        import fm_review_context as context
        self.frozen_contract()
        self.retained()
        tree = self.checkout()
        work = self.root/'review-work'
        work.mkdir()
        for name in context.PARTS:
            (work/(name+'.md')).write_text('complete standing criteria\n' if name == 'history' else '')
        (work/'pins.json').write_text(json.dumps(dict(head=self.head, base=self.base,
               patch=self.store.records()[0]['binding']['patch'], files=['feature'])))
        source = (ROOT/'bin/fm-review.sh').read_text()
        start = source.index('restore_context_evidence() {')
        end = source.index('\nif ! context_checkout_matches;', start)
        block = source[start:end]
        env = dict(os.environ, work=str(work), REVIEW_MODE='run', CHECKOUT=str(tree),
                   R_HEAD=self.head, R_BASE=self.base, FM_CODE_ROOT=str(self.code), REPO=str(self.repo), CREW_DATA='{}')
        old = None
        for oversized in (False, True):
            if oversized:
                (work/'diff.md').write_text('large inline patch\n'*70000)
            result = subprocess.run(['bash', '-c', 'fm_evidence_project() { echo self; };\n'+block+
                '\nrestore_context_evidence'], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            fresh = json.loads((work/'experiment-status.json').read_text())['index']
            self.assertTrue(Path(fresh).is_file())
            self.assertIn(str(Path(fresh).parent), (work/'prompt.md').read_text())
            if old:
                self.assertNotIn(str(Path(old).parent), (work/'prompt.md').read_text())
            old = fresh
            self.assertIn('complete standing criteria', (work/'prompt.md').read_text())
            # Model a stock refresh by deleting only this disposable checkout.
            shutil.rmtree(tree)
            tree = self.checkout()
        self.assertTrue((work/'evidence-path.txt').is_file())

    def test_no_experiment_refresh_preserves_original_prompt_and_archive(self):
        import fm_review_context as context
        self.frozen_contract()
        tree = self.checkout()
        work = self.root/'ordinary-review-work'
        work.mkdir()
        for name in context.PARTS:
            (work/(name+'.md')).write_text('complete standing criteria\n' if name == 'history' else '')
        (work/'pins.json').write_text(json.dumps(dict(head=self.head, base=self.base, patch='', files=[])))
        source = (ROOT/'bin/fm-review.sh').read_text()
        block = source[source.index('restore_context_evidence() {'):source.index('\nif ! context_checkout_matches;')]
        env = dict(os.environ, work=str(work), REVIEW_MODE='run', CHECKOUT=str(tree),
                   R_HEAD=self.head, R_BASE=self.base, FM_CODE_ROOT=str(self.code), REPO=str(self.repo), CREW_DATA='{}')
        for oversized in (False, True):
            if oversized:
                (work/'diff.md').write_text('large inline patch\n'*70000)
            context.prepare_experiments(work, 'run', str(tree), self.head, self.base, str(self.code))
            context.compose(work, 'run', str(tree))
            prompt = (work/'prompt.md').read_bytes()
            archive = (work/'evidence-path.txt').read_bytes() if oversized else None
            shutil.rmtree(tree)
            tree = self.checkout()
            result = subprocess.run(['bash', '-c', 'fm_evidence_project() { echo self; };\n'+block+
                '\nrestore_context_evidence'], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((work/'prompt.md').read_bytes(), prompt)
            self.assertFalse(json.loads((work/'experiment-status.json').read_text())['requires_context_refresh'])
            if archive:
                self.assertEqual((work/'evidence-path.txt').read_bytes(), archive)
                self.assertEqual((Path(archive.decode().strip())/'history.md').read_bytes(), (work/'history.md').read_bytes())
        # A stale record has no attachments but must still regenerate diagnostics.
        self.retained()
        context.prepare_experiments(work, 'run', str(tree), self.base, self.base, str(self.code))
        status = json.loads((work/'experiment-status.json').read_text())
        self.assertEqual(status['experiment_count'], 0)
        self.assertTrue(status['requires_context_refresh'])

    def test_truncated_outputs_cannot_prove_omitted_assertion(self):
        self.frozen_contract()
        self.manifest['experiments'][0]['artifacts'][0]['truncated'] = True
        record = self.retained()
        text, _, _ = self.module.attach(self.store, [record], [], 'diff', '')
        self.assertIn('truncated output cannot establish an omitted required assertion', text)
        self.assertIn('"exit_code": 1', text)
        self.assertNotIn('measured_result', text)

    def test_sparse_ordinary_consumers_without_experiment_module(self):
        # Keep the actual board fixture's exact sparse inventory unchanged.
        sparse = self.root/'sparse'
        library = sparse/'bin/lib'
        library.mkdir(parents=True)
        names = ('fm-task-grammar.sh', 'fm_gates.json', 'fm_binding.py', 'fm_evidence.py',
                 'fm_spec_preflight.py', 'fm_ste.py', 'fm_lifeline.py', 'fm-lifeline.sh',
                 'fm_project_paths.py', 'fm_registry.py', 'fm_config_values.py',
                 'fm_config_tasks.py', 'fm_config_runtime.py')
        for name in names:
            shutil.copy2(ROOT/'bin/lib'/name, library/name)
        shutil.copy2(ROOT/'bin/fm-herdr.py', sparse/'bin/fm-herdr.py')
        self.assertFalse((library/'fm_experimental_evidence.py').exists())
        code = '''import sys
from pathlib import Path
sys.dont_write_bytecode=True
sys.path.insert(0, sys.argv[1])
from fm_evidence import Store, summary, protocol
store=Store(sys.argv[2], 'self', 'T-264')
store.append('worker-report', 1, 'worker', 'a'*40, 'PRIVATE WORKER REASONING')
store.append('verdict', 1, 'reviewer', 'a'*40, 'APPROVE:T-264', verdict='APPROVE', provenance={'level':'legacy'})
store.append('readiness', 1, 'firstmate', 'a'*40, '', gates=[], checks=[])
assert 'PRIVATE WORKER REASONING' not in store.history(True)
assert store.experiments('a'*40, 'b'*40, '.') == ([], [])
assert len(summary(store)) == 3
assert protocol(store.verdicts(), 'T-264') == []
assert 'fm_experimental_evidence' not in sys.modules
'''
        result = subprocess.run([sys.executable, '-c', code, str(library), str(sparse/'state')],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        # Full-library binding/pin consumers also work with the feature absent.
        self.frozen_contract()
        (self.code/'bin/lib/fm_experimental_evidence.py').unlink()
        command = [sys.executable, str(self.code/'bin/lib/fm_evidence.py'), 'pin', '--state', str(self.store.state),
                   '--project', 'self', '--task', 'T-264', '--head', self.head, '--base', self.base,
                   '--patch', self.module.LocalGit().bytes(self.repo, 'diff-tree', '-r', '--name-only', self.base, self.head).decode().strip()]
        from fm_binding import change
        command[-1] = change(self.repo, self.head, self.base)['patch']
        run = self.root/'ordinary-pin-run'
        run.mkdir()
        result = subprocess.run([*command, '--run', str(run), '--code', str(self.code)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((run/'evidence-binding.json').is_file())

    def test_hosted_operator_and_shared_digest_copies(self):
        self.frozen_contract()
        with patch.dict(os.environ, HERDR_ENV='1'):
            first = self.retained()
            second_experiment = copy.deepcopy(self.manifest['experiments'][0])
            second_experiment['id'] = 'shared-output'
            self.manifest['experiments'].append(second_experiment)
            second = self.retained()
        records, unavailable = self.store.experiments(self.head, self.base, self.code)
        self.assertEqual(records, [first, second])
        self.assertFalse(unavailable)
        text, index, count = self.module.attach(self.store, records, [], 'run', self.checkout())
        self.assertEqual(count, 3)
        directory = Path(index).parent
        sha = first['experiments'][0]['artifacts'][0]['sha256']
        self.assertEqual((directory/sha).read_bytes(), b'ASSERTION FAILED: unlocked reader\n')
        self.assertEqual(text.count('"readonly_path": "'+str(directory/sha)+'"'), 3)
        self.assertEqual((directory/sha).stat().st_mode & 0o777, 0o400)

    def test_existing_attachment_digest_corruption_and_symlink_refuse(self):
        self.frozen_contract()
        record = self.retained()
        sha = record['experiments'][0]['artifacts'][0]['sha256']
        tree = self.checkout()
        real_mkdtemp = self.module.tempfile.mkdtemp
        for symlink in (False, True):
            def prepopulated(*args, **kwargs):
                directory = Path(real_mkdtemp(*args, **kwargs))
                if symlink:
                    (directory/sha).symlink_to(self.bundle/'log')
                else:
                    (directory/sha).write_bytes(b'corrupted existing digest')
                    (directory/sha).chmod(0o400)
                return str(directory)
            with patch.object(self.module.tempfile, 'mkdtemp', side_effect=prepopulated):
                with self.assertRaises((ValueError, OSError)):
                    self.module.attach(self.store, [record], [], 'run', tree)

    def test_admission_before_any_io_or_subprocess(self):
        for env in self.crew_environments():
            with patch.dict(os.environ, env), patch('subprocess.run', side_effect=AssertionError('Git started')):
                with self.assertRaises(ValueError):
                    self.module.admit_operator()
                store = Store(self.root/'denied-state', 'self', 'T-264')
                args = argparse.Namespace(file='/missing/manifest.json', head=self.head,
                                          base=self.base, code='/missing/code', round=1)
                with patch.object(self.module, 'regular_bytes', side_effect=AssertionError('file read started')):
                    with self.assertRaises(ValueError):
                        self.module.retain(store, args)
                self.assertFalse(store.state.exists())
                self.assertFalse(store.key_path.exists())

    def test_unsigned_allowlist_and_history_unchanged(self):
        store = Store(self.root/'state', 'self', 'T-264')
        store.append('worker-report', 1, 'worker', self.head, 'PRIVATE WORKER REASONING')
        self.assertNotIn('PRIVATE WORKER REASONING', store.history(True))
        store.directory.mkdir(exist_ok=True)
        unsigned = dict(project='self', task='T-264', kind='experimental-evidence')
        (store.directory/'99999999-unsigned.json').write_text(json.dumps(unsigned))
        with self.assertRaises(ValueError):
            store.records()


class StockRetentionCLI(ExperimentFixture):
    """Reach the real command on old runtimes without any new API prerequisite."""
    def test_stock_cli_retains_signed_exact_bound_declared_bytes(self):
        self.frozen_contract()
        self.manifest['project'] = 'firstmate-workflow'
        manifest = self.bundle/'manifest.json'
        manifest.write_text(json.dumps(self.manifest))
        command = ['bash', str(self.code/'bin/lib/fm-evidence.sh'), 'experiment-retain',
                   '--project', 'firstmate-workflow', '--repo', str(self.repo),
                   '--task', 'T-264', '--head', self.head, '--base', self.base,
                   '--code', str(self.code), '--file', str(manifest)]
        result = subprocess.run(command, env=dict(os.environ, HERDR_ENV='1'),
                                capture_output=True, text=True)
        # On the prefeature runtime this fails on unsupported CLI behavior,
        # before any feature-only record helper is imported or called.
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        store = Store(self.store.state, 'firstmate-workflow', 'T-264')
        records = store.records()
        self.assertEqual(len(records), 1)
        record = records[0]
        self.assertEqual(record['signature'], store.signature(record))
        self.assertEqual(record['kind'], 'experimental-evidence')
        self.assertEqual(record['actor'], 'firstmate')
        self.assertEqual(record['head'], self.head)
        self.assertEqual(record['binding']['base'], self.base)
        self.assertEqual(record['provenance'], dict(level='operator-attested-existing',
                                                  execution='unverified-by-stock'))
        experiment = record['experiments'][0]
        self.assertEqual(experiment['source_sha'], self.head)
        self.assertEqual(experiment['claimed_result']['exit_code'], 1)
        self.assertNotIn('measured_result', record)
        self.assertNotIn('measured_result', experiment)
        module = importlib.import_module('fm_experimental_evidence')
        selected, unavailable = store.experiments(self.head, self.base, self.code)
        self.assertEqual(selected, [record])
        self.assertFalse(unavailable)
        tree = self.checkout('cli-checkout')
        _, index, count = module.attach(store, selected, [], 'run', tree)
        self.assertEqual(count, 1)
        artifact = experiment['artifacts'][0]
        data = (Path(index).parent/artifact['sha256']).read_bytes()
        self.assertEqual(data, b'ASSERTION FAILED: unlocked reader\n')
        self.assertEqual(digest(data), artifact['sha256'])


class NamedResult(unittest.TextTestResult):
    """Stock scanner lines reflect unittest outcomes, never inferred log text."""
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.identities = {}

    def report(self, test, outcome):
        identity = test.id()
        occurrence = self.identities.get(identity, 0) + 1
        self.identities[identity] = occurrence
        if occurrence > 1:
            identity += ' [occurrence=' + str(occurrence) + ']'
        self.stream.writeln('    ' + identity + ' ' + outcome)
        self.stream.flush()

    def addSuccess(self, test):
        super().addSuccess(test)
        self.report(test, 'ok')

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self.report(test, 'FAIL')

    def addError(self, test, err):
        super().addError(test, err)
        self.report(test, 'ERROR')

    def addSubTest(self, test, subtest, err):
        super().addSubTest(test, subtest, err)
        outcome = ('ok' if err is None else
                   'FAIL' if issubclass(err[0], test.failureException) else 'ERROR')
        self.report(subtest, outcome)

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        self.report(test, 'SKIP')

    def addExpectedFailure(self, test, err):
        super().addExpectedFailure(test, err)
        self.report(test, 'EXPECTED_FAILURE')

    def addUnexpectedSuccess(self, test):
        super().addUnexpectedSuccess(test)
        self.report(test, 'UNEXPECTED_SUCCESS')


if __name__ == '__main__':
    unittest.main(testRunner=unittest.TextTestRunner(resultclass=NamedResult, verbosity=0))
