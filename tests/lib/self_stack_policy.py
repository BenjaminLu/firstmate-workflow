"""T-278: the self-stack-policy runtime file, its only writer, and self restacks.

Disposable self engines; GitHub is a stub or a patched reader. Nothing here
starts a background process or reaches the network.
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
from unittest.mock import patch

# Never notify a live Herdr from a fixture that raises cards.
os.environ['HERDR_ENV'] = '0'

sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1)).resolve()
sys.path.insert(0, str(ROOT / 'bin/lib'))
import fm_stack  # noqa: E402

A, B, C, D = (letter * 40 for letter in 'abcd')
DECISION = 'D-firstmate-workflow-T278-9'
SENTINEL = 'EXTERNAL-SENTINEL-T278-do-not-copy'
CLEAN = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
CLEAN.update(PYTHONDONTWRITEBYTECODE='1', HERDR_ENV='0', FM_TRANSPORT='direct')
VALID = dict(version=1, stacking='allowed', force_with_lease=True, captain_authorization=DECISION)
INVALID = {
    'unknown key': dict(VALID, extra=1),
    'missing key': {k: v for k, v in VALID.items() if k != 'force_with_lease'},
    'boolean version': dict(VALID, version=True),
    'other version': dict(VALID, version=2),
    'stacking type': dict(VALID, stacking='yes'),
    'lease type': dict(VALID, force_with_lease='true'),
    'authorization type': dict(VALID, captain_authorization=9),
}


def payload_bytes(record=None):
    return (json.dumps(record or VALID, indent=2) + '\n').encode()


class Engine:
    def __init__(self, tmp, name='engine'):
        self.root = Path(tmp) / name
        (self.root / 'design/tasks').mkdir(parents=True)
        (self.root / 'state').mkdir()
        (self.root / 'bin').mkdir()
        for script in ('fm-config.sh', 'fm-emit.sh', 'fm-herdr.py'):
            shutil.copy(ROOT / 'bin' / script, self.root / 'bin' / script)
        shutil.copytree(ROOT / 'bin/lib', self.root / 'bin/lib', ignore=shutil.ignore_patterns('__pycache__'))
        (self.root / 'config.yaml').write_text('project:\n  check: true\n')
        (self.root / 'design/design.md').write_text('# design\n')
        for task, depends in (('T-901', []), ('T-902', ['T-901'])):
            (self.root / 'design/tasks' / (task + '.json')).write_text(json.dumps(dict(
                id=task, depends_on=depends, scope=['src/' + task + '/**'], acceptance=['x'])) + '\n')
        env = dict(CLEAN, GIT_AUTHOR_DATE='2026-10-03T00:00:00Z', GIT_COMMITTER_DATE='2026-10-03T00:00:00Z')
        for args in (('init', '-q', '-b', 'main'), ('config', 'maintenance.auto', 'false'),
                     ('config', 'gc.auto', '0'), ('add', 'config.yaml', 'design'),
                     ('-c', 'user.email=a@b.c', '-c', 'user.name=t', 'commit', '-qm', 'base')):
            subprocess.run(['git', '-C', str(self.root), *args], check=True, capture_output=True, env=env, timeout=60)
        for task in ('T-901', 'T-902'):
            self.event(type='greenlit', actor='captain', task=task)
        self.gh_calls = self.root / 'ghcalls'
        stub = self.root / 'gh'
        stub.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "' + str(self.gh_calls) + '"\n'
                        'case "$1 $2" in\n'
                        '  "pr list") printf \'[{"number":1,"headRefName":"t-901-parent","headRefOid":"' + A +
                        '","isCrossRepository":false,"baseRefName":"main"}]\\n\' ;;\n'
                        '  "pr view") printf \'{"state":"OPEN","headRefName":"t-902-child","headRefOid":"' + C +
                        '","baseRefName":"t-901-parent","baseRefOid":"' + A + '"}\\n\' ;;\n'
                        '  *) echo "unexpected GitHub call: $*" >&2; exit 1 ;;\nesac\n')
        stub.chmod(0o755)

    @property
    def state(self):
        return self.root / 'state'

    @property
    def policy_path(self):
        return self.state / 'autopilot/self-stack-policy.json'

    def event(self, **row):
        row.setdefault('ts', '2026-10-03T00:00:00Z')
        with (self.state / 'events.jsonl').open('a') as out:
            out.write(json.dumps(row) + '\n')

    def write_policy(self, record=None, raw=None):
        self.policy_path.parent.mkdir(parents=True, exist_ok=True)
        self.policy_path.write_bytes(raw if raw is not None else payload_bytes(record))

    def card(self, payload, *, chosen='A', task='T-278', project=None, actor='captain', event=True,
             digest=None, decision=DECISION):
        details = {'en': {'title': 'Turn on self stacking', 'options': {'A': {'description':
                   'Write stacking allowed, force_with_lease true; payload SHA-256 ' +
                   (digest or hashlib.sha256(payload).hexdigest())}}},
                   'zh-TW': {'title': '開啟自身堆疊'}}
        answer = dict(id=decision, chosen=chosen, kind='choice', task=task, details=details,
                      ts='2026-10-04T00:00:00Z')
        if project:
            answer['project'] = project
        (self.state / 'decisions').mkdir(exist_ok=True)
        (self.state / 'decisions' / (decision + '.json')).write_text(json.dumps(answer) + '\n')
        if event:
            self.event(type='decision_made', actor=actor, task=task, ts='2026-10-04T00:00:01Z',
                       data=dict(decision=decision, chosen=chosen))

    def env(self, **extra):
        return dict(CLEAN, FM_ROOT=str(self.root), GH_REPO='fixture/project', FM_GH=str(self.root / 'gh'), **extra)

    def shell(self, script, **extra):
        return subprocess.run(['bash', '-c', '. "$1/bin/fm-config.sh"; fm_storage_init "$1" || exit 65; '
                               '. "$1/bin/lib/fm-stack.sh"; ' + script, '_', str(self.root)],
                              env=self.env(**extra), capture_output=True, text=True, stdin=subprocess.DEVNULL,
                              timeout=120)

    def fields(self):
        out = self.shell('fm_stack_policy stacking; fm_stack_policy force_with_lease')
        return out.stdout.split()

    def helper(self, payload, decision=DECISION, **extra):
        path = self.root / 'payload.json'
        path.write_bytes(payload)
        return subprocess.run([sys.executable, str(self.root / 'bin/lib/fm_stack.py'), 'self-policy',
                               '--decision', decision, '--payload', str(path)],
                              env=dict(self.env(**extra), FM_STATE_DIR=extra.get('FM_STATE_DIR', str(self.state))),
                              capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120)

    def pilot(self):
        import fm_autopilot
        ctx = dict(engine=str(self.root), state=str(self.state), target=str(self.root), project='',
                   evidence_project='self', repository='fixture/project', base='main', external=False,
                   tasks=str(self.root / 'design/tasks'))
        with patch.dict(os.environ, self.env()):
            pilot = fm_autopilot.Pilot(ctx)
        pilot.task = lambda pr: 'T-902'
        pilot.round_live = lambda task: False
        pilot.busy = lambda task: False
        pilot.calls = []
        pilot.probe = lambda argv: pilot.calls.append(argv) or (0, '', '')
        return pilot

    def pin_env(self):
        return dict(CLEAN, FM_ENGINE_ROOT=str(self.root), FM_TARGET_ROOT=str(self.root),
                    FM_STATE_DIR=str(self.state), FM_TASKS_DIR=str(self.root / 'design/tasks'),
                    FM_DESIGN=str(self.root / 'design/design.md'))


def attention(pilot):
    return [wake for wake in pilot.data['wakes'].values()
            if wake['line'].startswith('Self stack policy invalid')]


def held(pilot):
    return [wake for wake in pilot.data['wakes'].values()
            if wake['line'] == 'Merged stack base needs confirmed restack policy']


CHILD = dict(number=2, head=dict(sha=B, ref='t-902-child'), base=dict(ref='t-901-parent'))
PARENT = dict(number=1, merged_at='2026-10-04T00:00:00Z', head=dict(ref='t-901-parent'))


class Case(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.tmp = tmp.name
        self.engine = Engine(self.tmp)


class PolicyFile(Case):
    # (e) FAIL-FIRST: the base has no policy file; stacking is always held.
    def test_valid_file_sets_both_shell_fields(self):
        self.engine.write_policy()
        self.assertEqual(['allowed', 'true'], self.engine.fields())

    def test_valid_file_reaches_select_and_restack_actions(self):
        self.engine.write_policy()
        out = self.engine.shell('fm_stack select --task T-902')
        self.assertEqual(0, out.returncode, out.stderr)
        self.assertEqual(dict(name='t-901-parent', head=A, pr=1), json.loads(out.stdout))
        out = self.engine.shell('fm_stack restack --pr 2 --parent 1 --expected-head ' + B)
        self.assertNotIn('restack requires confirmed stacking', out.stderr)
        self.assertEqual(67, out.returncode, out.stderr)  # the restack path ran and read GitHub

    def test_valid_file_reaches_the_autopilot(self):
        self.engine.write_policy()
        pilot = self.engine.pilot()
        self.assertEqual(('allowed', True), (pilot.policy['stacking'], pilot.policy['force_with_lease']))

    def test_invalid_variants_hold_and_raise_bilingual_attention_once(self):
        variants = dict(INVALID, **{'not json': None, 'symlink': 'link'})
        for name, record in variants.items():
            with self.subTest(variant=name), tempfile.TemporaryDirectory() as tmp:
                engine = Engine(tmp)
                if record == 'link':
                    target = engine.root / 'elsewhere.json'
                    target.write_bytes(payload_bytes())
                    engine.policy_path.parent.mkdir(parents=True)
                    engine.policy_path.symlink_to(target)
                elif record is None:
                    engine.write_policy(raw=b'{not json')
                else:
                    engine.write_policy(record)
                self.assertEqual(['hold', 'false'], engine.fields())
                pilot = engine.pilot()
                self.assertEqual(('hold', False), (pilot.policy['stacking'], pilot.policy['force_with_lease']))
                first = attention(pilot)
                self.assertTrue(first, name)
                pilot.reload_policy(); pilot.reload_policy()
                self.assertEqual(len(first), len(attention(pilot)), 'one attention per distinct problem')
                self.assertEqual(len(first), len({wake['line'] for wake in first}))
                for wake in first:
                    self.assertTrue(wake['summary']['en'] and wake['summary']['zh-TW'])
                    self.assertIn('自身堆疊政策無效', wake['summary']['zh-TW'])

    def test_absent_file_keeps_hold_everywhere(self):
        # REGRESSION: today's behaviour without the file.
        self.assertEqual(['hold', 'false'], self.engine.fields())
        pilot = self.engine.pilot()
        self.assertEqual(('hold', False), (pilot.policy['stacking'], pilot.policy['force_with_lease']))
        self.assertNotEqual(0, self.engine.shell('fm_stack select --task T-902').returncode)
        pilot.restack(CHILD, PARENT)
        self.assertEqual(1, len(held(pilot)))
        self.assertEqual([], pilot.calls)

    def test_other_self_values_unchanged_with_file_present(self):
        # REGRESSION: merge, cleanup and binding keep today's self values.
        self.engine.write_policy()
        out = self.engine.shell('fm_stack_policy delete_branch; fm_stack_policy merge_method; fm_stack_policy land')
        self.assertEqual(['true', 'squash', 'card'], out.stdout.split())
        import fm_binding
        with patch.dict(os.environ, self.engine.env()):
            self.assertEqual('fm', fm_binding.review_policy())

    def test_pin_created_with_file_equals_pin_without(self):
        from fm_spec_pins import Pins
        twin = Path(self.tmp) / 'twin'
        shutil.copytree(self.engine.root, twin, symlinks=True, ignore=shutil.ignore_patterns('*.lock'))
        other = Engine.__new__(Engine)
        other.root = twin
        other.write_policy()
        first = Pins(self.engine.pin_env(), 'T-901').create()
        second = Pins(other.pin_env(), 'T-901').create()
        self.assertEqual(json.dumps(first, sort_keys=True), json.dumps(second, sort_keys=True))


class Writer(Case):
    # (f) FAIL-FIRST: the base has no self-policy helper.
    def test_answered_card_writes_exact_bytes_once(self):
        payload = payload_bytes()
        self.engine.card(payload)
        out = self.engine.helper(payload)
        self.assertEqual(0, out.returncode, out.stderr)
        self.assertEqual(payload, self.engine.policy_path.read_bytes())
        before = self.engine.policy_path.stat()
        out = self.engine.helper(payload)
        self.assertEqual(0, out.returncode, out.stderr)
        after = self.engine.policy_path.stat()
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))
        self.assertEqual([], [p.name for p in self.engine.policy_path.parent.iterdir()
                              if p.name != 'self-stack-policy.json' and p.name.startswith('.self-stack')])
        self.assertEqual(['allowed', 'true'], self.engine.fields())

    def refused(self, out, engine=None):
        engine = engine or self.engine
        self.assertEqual(65, out.returncode, out.stdout + out.stderr)
        self.assertFalse(engine.policy_path.exists() or engine.policy_path.is_symlink())

    def test_every_refusal_writes_nothing(self):
        payload = payload_bytes()
        cases = {
            'invalid schema': lambda e: (e.card(payload_bytes(dict(VALID, extra=1))), payload_bytes(dict(VALID, extra=1))),
            'authorization mismatch': lambda e: (e.card(payload_bytes(dict(VALID, captain_authorization='D-other'))),
                                                 payload_bytes(dict(VALID, captain_authorization='D-other'))),
            'no answer': lambda e: (None, payload),
            'chosen B': lambda e: (e.card(payload, chosen='B'), payload),
            'other task': lambda e: (e.card(payload, task='T-277'), payload),
            'other project': lambda e: (e.card(payload, project='other-project'), payload),
            'not the captain': lambda e: (e.card(payload, actor='firstmate'), payload),
            'no decision event': lambda e: (e.card(payload, event=False), payload),
            'details lack digest': lambda e: (e.card(payload, digest='0' * 64), payload),
        }
        for name, setup in cases.items():
            with self.subTest(case=name), tempfile.TemporaryDirectory() as tmp:
                engine = Engine(tmp)
                _, body = setup(engine)
                self.refused(engine.helper(body), engine)

    def test_symlinked_destination_is_refused(self):
        payload = payload_bytes()
        self.engine.card(payload)
        target = Path(self.tmp) / 'outside'
        target.mkdir()
        (self.engine.state / 'autopilot').symlink_to(target, target_is_directory=True)
        out = self.engine.helper(payload)
        self.assertEqual(65, out.returncode, out.stderr)
        self.assertEqual([], list(target.iterdir()))

    def test_external_refusal_and_no_sentinel_anywhere(self):
        payload = payload_bytes()
        self.engine.card(payload)
        external = Path(self.tmp) / 'private-home/projects/beta/state'
        (external / 'decisions').mkdir(parents=True)
        (external / 'events.jsonl').write_text(json.dumps(dict(type='greenlit', note=SENTINEL)) + '\n')
        (external / 'decisions' / (DECISION + '.json')).write_text(json.dumps(dict(id=DECISION, note=SENTINEL)))
        out = self.engine.helper(payload, FM_EXTERNAL='1', FM_STATE_DIR=str(external))
        self.assertEqual(65, out.returncode, out.stderr)
        self.assertNotIn(SENTINEL, out.stdout + out.stderr)
        self.assertFalse((external / 'autopilot').exists())
        out = self.engine.helper(payload)
        self.assertEqual(0, out.returncode, out.stderr)
        self.assertNotIn(SENTINEL, out.stdout + out.stderr + self.engine.policy_path.read_text())


class Restack(Case):
    # (g) FAIL-FIRST: the base holds a self child's restack whatever the file says.
    def test_self_child_restacks_through_entrypoint_under_policy(self):
        self.engine.write_policy()
        (self.engine.state / 'runs').mkdir()
        out = subprocess.run(['bash', str(self.engine.root / 'bin/lib/fm-restack.sh'), '--repo', str(self.engine.root),
                              '--pr', '2', '--parent', '1', '--expected-head', B],
                             env=self.engine.env(), capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120)
        self.assertNotIn('confirmed stacking and force-with-lease policy', out.stderr)
        self.assertEqual(67, out.returncode, out.stderr)
        self.assertIn('pr view 2', self.engine.gh_calls.read_text())

    def test_autopilot_restacks_self_child_after_parent_merges(self):
        self.engine.write_policy()
        pilot = self.engine.pilot()
        pilot.restack(CHILD, PARENT)
        self.assertEqual([], held(pilot))
        self.assertEqual(1, len(pilot.calls))
        self.assertIn('lib/fm-restack.sh', pilot.calls[0][0])
        self.assertEqual('done', pilot.data['restacks']['2']['outcome'])


def restacked(policy, parent_base, tmp):
    """Run fm_stack.restack for a non-adopted child with GitHub and git patched."""
    child = dict(state='OPEN', headRefName='t-902-child', baseRefName='t-901-parent',
                 headRefOid=B, baseRefOid=A, isCrossRepository=False)
    parent = dict(state='MERGED', headRefName='t-901-parent', headRefOid=A, baseRefName=parent_base,
                  isCrossRepository=False)
    final = dict(child, headRefOid=C, baseRefName=parent_base, baseRefOid=D)
    def git(root, *args):
        if args == ('rev-parse', 'refs/heads/t-902-child'): return B
        if args == ('merge-base', A, B): return A
        if args == ('rev-parse', 'HEAD'): return C
        return ''
    def github(repository, *args):
        if args[:3] == ('pr', 'view', '1'): return parent
        return {'protected': False}
    run = subprocess.run
    def rebase(argv, **kwargs):
        if argv[0] != 'git': return run(argv, **kwargs)
        return subprocess.CompletedProcess(argv, 0, '', '')
    import fm_adopt
    with patch.object(fm_stack, 'adopted_child', return_value=(None, None)), \
         patch.object(fm_adopt, 'scan', return_value=({}, {}, {})), \
         patch.object(fm_stack, 'remote_head', side_effect=[child, child, final]), \
         patch.object(fm_stack, 'github', side_effect=github), \
         patch.object(fm_stack, 'fetch_ref', side_effect=[D, A]), \
         patch.object(fm_stack, 'git', side_effect=git), \
         patch.object(fm_stack, 'command') as command, \
         patch.object(fm_stack.subprocess, 'run', side_effect=rebase):
        result = fm_stack.restack('/repo', 'fixture/project', 2, 1, B, policy, tmp)
    return result, command


class Transitions(Case):
    """Records and tasks already in flight across activation, change and removal."""

    def policy(self):
        return fm_stack.self_policy({'stacking': 'hold', 'base': 'main'}, self.engine.state)

    def test_allowed_to_hold_makes_no_new_stack_and_holds_restack(self):
        self.engine.write_policy()
        self.assertEqual(0, self.engine.shell('fm_stack select --task T-902').returncode)
        self.engine.write_policy(dict(VALID, stacking='hold', force_with_lease=False))
        out = self.engine.shell('fm_stack select --task T-902')
        self.assertEqual(65, out.returncode)
        pilot = self.engine.pilot()
        pilot.restack(CHILD, PARENT)
        self.assertEqual(1, len(held(pilot)))
        self.assertEqual([], pilot.calls)

    def test_allowed_to_invalid_holds_with_one_attention(self):
        self.engine.write_policy()
        self.engine.write_policy(dict(VALID, version=2))
        self.assertEqual(65, self.engine.shell('fm_stack select --task T-902').returncode)
        pilot = self.engine.pilot()
        pilot.restack(CHILD, PARENT)
        self.assertEqual(1, len(held(pilot)))
        self.assertEqual(1, len(attention(pilot)))

    def snapshot(self):
        files = {}
        for folder in ('pins', 'decisions', 'dispatch', 'ready'):
            for path in sorted((self.engine.state / folder).rglob('*')):
                if path.is_file():
                    files[str(path.relative_to(self.engine.state))] = path.read_bytes()
        refs = subprocess.run(['git', '-C', str(self.engine.root), 'for-each-ref', '--format=%(refname) %(objectname)'],
                              capture_output=True, text=True, check=True).stdout
        log = subprocess.run(['git', '-C', str(self.engine.root), 'log', '--format=%H', '--all'],
                             capture_output=True, text=True, check=True).stdout
        return files, refs, log

    def test_activation_change_and_removal_rewrite_no_record(self):
        from fm_spec_pins import Pins
        self.assertIsNotNone(Pins(self.engine.pin_env(), 'T-901').create())
        (self.engine.state / 'dispatch').mkdir()
        (self.engine.state / 'dispatch/T-902.json').write_text(json.dumps(
            dict(project='', task='T-902', owner=1, keeper=2)))
        payload = payload_bytes()
        self.engine.card(payload)
        before = self.snapshot()
        self.assertEqual(0, self.engine.helper(payload).returncode)
        self.engine.fields(); self.engine.shell('fm_stack select --task T-902')
        self.assertEqual(before, self.snapshot(), 'activation rewrites nothing')
        self.engine.write_policy(dict(VALID, stacking='hold'))
        self.engine.fields()
        self.assertEqual(before, self.snapshot(), 'a change rewrites nothing')
        self.engine.policy_path.unlink()
        self.assertEqual(['hold', 'false'], self.engine.fields())
        self.assertEqual(before, self.snapshot(), 'removal rewrites nothing')
        calls = self.engine.gh_calls.read_text() if self.engine.gh_calls.exists() else ''
        self.assertNotIn('pr edit', calls, 'no pull request base changes')

    def test_pre_activation_one_level_child_restacks_onto_main(self):
        self.engine.write_policy()
        result, command = restacked(self.policy(), 'main', self.tmp)
        self.assertEqual('main', result['base'])
        self.assertEqual(['--base', 'main'], command.call_args[0][0][-2:])

    def test_pre_activation_two_level_child_restacks_onto_middle_branch(self):
        self.engine.write_policy()
        result, command = restacked(self.policy(), 't-900-middle', self.tmp)
        self.assertEqual('t-900-middle', result['base'])
        self.assertEqual(['--base', 't-900-middle'], command.call_args[0][0][-2:])


if __name__ == '__main__':
    unittest.main(verbosity=2)
