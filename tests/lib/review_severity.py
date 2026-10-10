"""T-276 change 1: review findings say whether they block approval.

Severity parsing, the three protocol errors for marked verdicts, gate 6, the
follow-ups command, the fix-brief deferral and the autopilot's protocol-first
check and follow-ups wake. No network and no background processes.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

os.environ['HERDR_ENV'] = '0'
sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1))
sys.path.insert(0, str(ROOT / 'bin/lib'))
sys.path.insert(0, str(ROOT / 'tests/lib'))
import fm_evidence as E
from fm_context_pack import coverage
import fm_autopilot as A
from autopilot_branch_fixture import BranchFixture

T = 'T-X'
CLOSE = 'CRITERIA-COMPLETE:T-X\n'
TEXT = 'file: src/a:1\nchange: replace x with y\nfixes: test_a\nfail-first: test_a fails on the old code\n'


def fix(number):
    return f'```text fix-{number}\n{TEXT}```\n'


def verdict(text, decided, marked=True, **extra):
    record = dict(kind='verdict', verdict=decided, text=text + CLOSE + f'{decided}:{T}\n', fix_protocol=1, **extra)
    if marked:
        record['severity_protocol'] = 1
    return record


class Severity(unittest.TestCase):
    def test_tag_cases(self):
        cases = {'1. open helper': 'must-fix', 'open [must-fix] helper': 'must-fix',
                 'open [follow-up]: rename the helper': 'follow-up',
                 'REGRESSION:T-9 [follow-up] the lock is never released': 'follow-up',
                 'REGRESSION:T-9 [must-fix] the lock is never released': 'must-fix',
                 '**open [follow-up]** rename': 'follow-up',
                 'open helper\n   [follow-up] on a later line does not count': 'must-fix',
                 'open [follow-up] [must-fix] both': 'must-fix', '': 'must-fix'}
        for body, expected in cases.items():
            with self.subTest(body=body):
                self.assertEqual(E.severity(body), expected)

    def test_criteria_still_returns_the_tag(self):
        text = '1. open [follow-up]: rename the helper\n' + fix(1) + CLOSE
        self.assertEqual(E.criteria(text, T)[0][1].splitlines()[0], 'open [follow-up]: rename the helper')


class Protocol(unittest.TestCase):
    def test_marked_reject_with_only_open_follow_ups_fails_protocol(self):
        # Fail-first: main accepts a REJECT whose open items are all follow-ups.
        record = verdict('1. open [follow-up]: rename\n' + fix(1) + '2. done [must-fix] lock\n', 'REJECT')
        self.assertIn('REJECT has no open must-fix item', E.protocol([record], T))
        record = verdict('1. open [follow-up]: rename\n' + fix(1) + '2. open lock\n' + fix(2), 'REJECT')
        self.assertEqual(E.protocol([record], T), [], 'an untagged open item is must-fix')

    def test_two_tags_on_one_line_fail_protocol_for_a_marked_record(self):
        # Fail-first: main has no such rule.
        text = '1. open [must-fix] [follow-up] lock\n' + fix(1)
        self.assertIn('item 1 has two severity tags', E.protocol([verdict(text, 'REJECT')], T))
        self.assertEqual(E.protocol([verdict(text, 'REJECT', marked=False)], T), [],
                         'an unmarked record keeps the old rules')

    def test_marked_approve_whose_list_leaves_must_fix_open_fails(self):
        first = verdict('1. open lock\n' + fix(1) + '2. open [follow-up] rename\n' + fix(2), 'REJECT')
        approve = verdict('1. open lock\n2. open [follow-up] rename\n', 'APPROVE')
        self.assertEqual(E.protocol([first, approve], T), ['APPROVE leaves must-fix item 1 open'])
        fine = verdict('1. done lock\n2. open [follow-up] rename\n', 'APPROVE')
        self.assertEqual(E.protocol([first, fine], T), [], 'open follow-ups do not block an approval')
        self.assertEqual(E.protocol([first, verdict('', 'APPROVE')], T)[:1], [],
                         'a marked APPROVE without its own list stays valid')

    def test_unmarked_approve_with_open_items_still_passes(self):
        first = verdict('1. open lock\n' + fix(1), 'REJECT', marked=False)
        approve = verdict('1. open lock\n', 'APPROVE', marked=False)
        self.assertEqual(E.protocol([first, approve], T), [])


class Stored(unittest.TestCase):
    """Real signed records, the protocol, gate and follow-ups commands."""
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.repo = self.tmp / 'repo'

        def git(*args):
            return subprocess.check_output(['git', '-C', str(self.repo), *args], text=True).strip()
        self.repo.mkdir()
        git('init', '-q', '-b', 'main'); git('config', 'user.name', 'F'); git('config', 'user.email', 'f@e.invalid')
        (self.repo / 'design/tasks').mkdir(parents=True)
        (self.repo / f'design/tasks/{T}.json').write_text(json.dumps(dict(id=T, scope=['*'])))
        (self.repo / 'config.yaml').write_text('project:\n  check: true\n')
        (self.repo / 'feature').write_text('old\n')
        git('add', '.'); git('commit', '-qm', 'base')
        self.base = git('rev-parse', 'HEAD')
        (self.repo / 'feature').write_text('new\n')
        git('commit', '-qam', 'feature')
        self.head = git('rev-parse', 'HEAD')
        self.env = dict(os.environ, FM_EXTERNAL='0', FM_STATE_DIR=str(self.repo / 'state'),
                        FM_TARGET_ROOT=str(self.repo), FM_TASKS_DIR=str(self.repo / 'design/tasks'))
        self.state = self.repo / 'state'
        with patch.dict(os.environ, self.env):
            from fm_binding import source_binding
            self.binding = source_binding(T, self.head, self.base, ROOT)
        self.store = E.Store(self.state, 'self', T)

    def append(self, round_number, text, decided, marked=True):
        fields = dict(verdict=decided, base=self.base, patch=self.binding['patch'], binding=self.binding,
                      provenance={'level': 'legacy'}, fix_protocol=1)
        if marked:
            fields['severity_protocol'] = 1
        return self.store.append('verdict', round_number, 'reviewer-ada-tx-r1', self.head,
                                 text + CLOSE + f'{decided}:{T}\n', **fields)

    def cli(self, command, *extra):
        return subprocess.run([sys.executable, str(ROOT / 'bin/lib/fm_evidence.py'), command,
                               '--state', str(self.state), '--project', 'self', '--task', T, *extra],
                              capture_output=True, text=True, env=self.env)

    def gate(self):
        return self.cli('gate', '--head', self.head, '--base', self.base, '--patch', self.binding['patch'],
                        '--code', str(ROOT))

    def test_marked_approve_leaving_must_fix_open_fails_gate_and_protocol(self):
        # Fail-first: main's gate 6 and protocol accept this approval.
        self.append(1, '1. open lock\n' + fix(1) + '2. open [follow-up] rename\n' + fix(2), 'REJECT')
        self.append(2, '1. open lock\n2. open [follow-up] rename\n', 'APPROVE')
        protocol, gate = self.cli('protocol'), self.gate()
        self.assertEqual(protocol.returncode, 1, protocol.stderr)
        self.assertIn('APPROVE leaves must-fix item 1 open', protocol.stderr)
        self.assertEqual(gate.returncode, 1, gate.stderr)
        self.assertIn('APPROVE leaves must-fix item 1 open', gate.stderr)

    def test_marked_approve_with_only_follow_ups_passes_protocol_and_gate(self):
        self.append(1, '1. open lock\n' + fix(1) + '2. open [follow-up] rename\n' + fix(2), 'REJECT')
        self.append(2, '1. done lock\n2. open [follow-up] rename\n', 'APPROVE')
        self.assertEqual(self.cli('protocol').returncode, 0)
        gate = self.gate()
        self.assertEqual(gate.returncode, 0, gate.stderr)

    def test_follow_ups_command_with_and_without_the_approvals_own_list(self):
        self.append(1, '1. open lock\n' + fix(1) + '2. open [follow-up] rename\n' + fix(2)
                    + '3. open [follow-up] docs\n' + fix(3), 'REJECT')
        self.append(2, 'Looks right.\n', 'APPROVE')
        self.assertEqual(json.loads(self.cli('follow-ups').stdout),
                         [dict(number=2, line='open [follow-up] rename'), dict(number=3, line='open [follow-up] docs')])
        self.append(3, '1. done lock\n2. done [follow-up] rename\n3. open [follow-up] docs\n', 'APPROVE')
        self.assertEqual(json.loads(self.cli('follow-ups').stdout), [dict(number=3, line='open [follow-up] docs')])
        self.append(4, '1. done lock\n2. done rename\n3. open lock again\n' + fix(3), 'REJECT')
        self.assertEqual(json.loads(self.cli('follow-ups').stdout), [], 'a latest REJECT has no follow-ups')

    def test_fixes_brief_defers_follow_ups_and_passes_the_coverage_check(self):
        text = ('1. open lock\n' + fix(1) + '2. open [follow-up] rename\n' + fix(2)
                + '3. open [follow-up] ask\n   DECISION:T-X rename or keep?\n')
        record = self.store.append('verdict', 1, 'reviewer-ada-tx-r1', self.head, text + CLOSE + 'REJECT:T-X\n',
                                   verdict='REJECT', provenance={'level': 'legacy'}, fix_protocol=1,
                                   severity_protocol=1, fix_checks=dict(version=1, status='complete',
                                                                        reason=None, items={}))
        path, decision = E.fixes_brief(self.store, 2, self.head)
        self.assertFalse(decision, 'a follow-up question does not hold the must-fix work')
        draft = path.read_text()
        self.assertIn('1. fix: open lock\n', draft)
        self.assertIn('2. deferred: follow-up, not needed for approval: open [follow-up] rename\n\n```text fix-2',
                      draft)
        self.assertIn('3. deferred: follow-up, not needed for approval: open [follow-up] ask\n'
                      '   proposed captain question: rename or keep?\n', draft)
        report = coverage('reject', {}, draft, dict(findings=[(1, ''), (2, ''), (3, '')]), self.tmp, [])
        self.assertEqual(report['gaps'], [])
        self.assertTrue(record['signature'])

    def test_retained_verdicts_carry_the_severity_field(self):
        run = self.tmp / 'run'; (run / 'pinned').mkdir(parents=True)
        (run / 'evidence-binding.json').write_text(json.dumps(dict(head=self.head, base=self.base, patch='p')))
        (run / 'identity.json').write_text(json.dumps(dict(project='self', task=T, role='reviewer', round=1)))
        (run / 'pinned/spec.json').write_text(json.dumps(dict(id=T, scope=['*'])))
        (run / 'answer.txt').write_text('1. open lock\n' + fix(1) + CLOSE + 'REJECT:T-X\n')
        args = SimpleNamespace(run=str(run), round=1, vendor='custom', file=str(run / 'answer.txt'),
                               head=self.head, base=self.base, patch='p', attempt='a1')
        with patch.dict(os.environ, dict(self.env, FM_ACTOR='reviewer-ada-tx-r1')):
            record = E.retain_verdict(self.store, args)
        self.assertEqual(record['severity_protocol'], 1)


HEAD = 'a' * 40
PR = dict(number=12, title='T-001: fixture', state='open', head=dict(ref='t-001-fixture', sha=HEAD),
          base=dict(ref='main', sha='b' * 40), mergeable=True, mergeable_state='clean', draft=False)
CHECKS = [dict(id=1, name='ci', head_sha=HEAD, status='completed', conclusion='success')]


class Autopilot(BranchFixture, unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.state = self.root / 'state'; self.state.mkdir()
        (self.root / 'tasks').mkdir()
        self.ctx = dict(engine=str(self.root), state=str(self.state), target=str(self.root),
                        project='alpha', evidence_project='alpha', repository='owner/alpha',
                        base='main', external=False, tasks=str(self.root / 'tasks'))
        self.calls = []
        self.branch_setup()
        self.pilot = A.Pilot(self.ctx)
        self.pilot.api = lambda endpoint: dict(contexts=['ci'], checks=[])
        self.pilot.start_job = lambda kind, task, pr, argv, **extra: self.calls.append((kind, argv))
        self.pilot.authoritative_head = lambda task, pr: pr['head']['sha']
        self.pilot.command = lambda argv, **kwargs: 'b' * 40 + '\n' if argv[0] == 'git' else ''
        self.pilot.probe = self.branch_probe
        self.pilot.task = lambda pr: 'T-001'
        self.pilot.emit = lambda *a, **kw: None
        self.pilot.busy = lambda task: False

    def approve(self, text, round_number=1, marked=True):
        fields = dict(verdict='APPROVE', provenance={'level': 'legacy'}, fix_protocol=1)
        if marked:
            fields['severity_protocol'] = 1
        return E.Store(str(self.state), 'alpha', 'T-001').append(
            'verdict', round_number, 'reviewer-ada-t001-r1', HEAD,
            text + 'CRITERIA-COMPLETE:T-001\nAPPROVE:T-001\n', **fields)

    def test_marked_approval_runs_the_protocol_check_before_the_gate_in_round_one(self):
        # Fail-first: main runs the gate first before round three.
        self.approve('1. done lock\n')
        self.pilot.advance(PR, CHECKS, [])
        self.assertEqual([kind for kind, _ in self.calls], ['protocol'])
        self.assertIn('check', self.calls[0][1])

    def test_unmarked_approval_still_runs_the_gate_first(self):
        self.approve('1. done lock\n', marked=False)
        self.pilot.advance(PR, CHECKS, [])
        self.assertEqual([kind for kind, _ in self.calls], ['gate'])

    def test_marked_approval_with_follow_ups_wakes_once_per_head_in_both_languages(self):
        # Fail-first: main raises no follow-ups wake.
        self.approve('1. done lock\n2. open [follow-up] rename\n3. open [follow-up] docs\n')
        self.pilot.advance(PR, CHECKS, [])
        self.pilot.data['advanced'] = {}
        self.pilot.advance(PR, CHECKS, [])
        wakes = [w['summary'] for w in self.pilot.data['wakes'].values()]
        self.assertEqual(wakes, [{'en': 'T-001 approved with 2 open follow-ups; propose follow-up tasks on a card',
                                  'zh-TW': 'T-001 已核准，但仍有 2 個後續項目；請在決策卡上提出後續任務'}])
        self.assertEqual([kind for kind, _ in self.calls], ['protocol', 'protocol'],
                         'the follow-ups never hold the merge path')

    def test_a_failed_protocol_check_for_a_marked_approval_wakes_and_launches_no_review(self):
        self.pilot.job_completed(dict(kind='protocol', task='T-001', pr=PR, base='b' * 40, round=1, code=3,
                                      output=''))
        self.assertEqual(self.calls, [])
        self.assertIn('protocol violation in round 1', str(self.pilot.data['wakes']))


if __name__ == '__main__':
    unittest.main()
