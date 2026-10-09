"""T-272: a rejecting reviewer attaches a fix to every open finding.

Parsing, the protocol rules, the read-only patch check, the brief draft, the
two-person reviewer rotation and both autopilot REJECT paths. No network and
no background processes; every repository is a temporary fixture.
"""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
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
_spec = importlib.util.spec_from_file_location('managed_herdr', ROOT / 'bin/fm-herdr.py')
H = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(H)

T = 'T-X'
CLOSE = 'CRITERIA-COMPLETE:T-X\nREJECT:T-X\n'
PATCH = '--- a/src/a\n+++ b/src/a\n@@ -1 +1 @@\n-x\n+y\n'
STALE = '--- a/src/a\n+++ b/src/a\n@@ -1 +1 @@\n-nope\n+y\n'
OUTSIDE = '--- a/docs/b\n+++ b/docs/b\n@@ -1 +1 @@\n-d\n+e\n'
TEXT = 'file: src/a:1\nchange: replace x with y\nfixes: test_a\nfail-first: test_a fails on the old code\n'


def block(kind, number, body):
    return f'```{kind} fix-{number}\n{body}```\n'


def old_criteria(text, task):
    """criteria() exactly as it was before T-272, for the equivalence proof."""
    lines = list(E.unquoted(text))
    ends = [n for n, line in enumerate(lines) if line.strip() == 'CRITERIA-COMPLETE:' + task]
    if not ends:
        return []
    items = []
    blank = False
    label = False
    for line in lines[:ends[-1]]:
        match = re.match(r'^\s*(\d+)[.)]\s+(.+)', line)
        if match:
            if int(match[1]) == 1 and (blank or label):
                items = []
            items.append((int(match[1]), [match[2]]))
        elif not line.strip():
            if items:
                items[-1][1].append('')
            blank = True
            continue
        elif items:
            boundary = re.match(r'^\s{0,3}(?:#{1,6}\s|(?:[-*_]\s*){3,}$)', line)
            if boundary or (blank and not line[0].isspace()):
                items = []
            else:
                items[-1][1].append(line)
        blank = False
        label = not match and not line[0].isspace()
    return [(number, '\n'.join(body).rstrip()) for number, body in items]


def repository(root):
    """A target repository whose head has src/a=x and docs/b=d."""
    root.mkdir(parents=True)
    run = lambda *a: subprocess.run(['git', '-C', str(root), *a], check=True, capture_output=True, text=True).stdout
    run('init', '-q', '-b', 'main')
    run('config', 'user.email', 'a@b.c'); run('config', 'user.name', 't')
    (root / 'src').mkdir(); (root / 'docs').mkdir()
    (root / 'src/a').write_text('x\n'); (root / 'docs/b').write_text('d\n')
    run('add', '-A'); run('commit', '-qm', 'base')
    return run('rev-parse', 'HEAD').strip()


def repository_state(root):
    run = lambda *a: subprocess.run(['git', '-C', str(root), *a], check=True, capture_output=True, text=True).stdout
    index = hashlib.sha256((root / '.git/index').read_bytes()).hexdigest()
    return index, run('for-each-ref'), run('rev-parse', 'HEAD'), run('status', '--porcelain', '--ignored')


class Parsing(unittest.TestCase):
    def test_only_the_final_list_between_first_item_and_marker_counts(self):
        text = ('Example:\n' + block('diff', 1, 'quoted example\n') + '> ```diff fix-1\n> quoted\n> ```\n'
                'Earlier list:\n1. open old\n' + block('text', 1, 'file: old\n') + '\n'
                'Final list:\n1. open helper is wrong\n' + block('diff', 1, PATCH)
                + '2. done empty case\n' + CLOSE + block('text', 2, 'after the marker\n'))
        found = E.fixes(text, T)
        self.assertEqual(set(found), {1, 2})
        self.assertEqual((found[1]['kind'], found[1]['content'], found[1]['errors']), ('patch', PATCH, []))
        self.assertEqual((found[2]['kind'], found[2]['open'], found[2]['errors']), (None, False, []))

    def test_a_fenced_marker_does_not_end_the_list(self):
        text = '1. open helper\n' + block('text', 1, TEXT + 'CRITERIA-COMPLETE:T-X\n') + CLOSE
        found = E.fixes(text, T)
        self.assertEqual(found[1]['kind'], 'text')
        self.assertIn('CRITERIA-COMPLETE:T-X', found[1]['content'])
        self.assertEqual(found[1]['errors'], [])

    def test_an_unknown_item_number_is_named(self):
        found = E.fixes('1. open helper\n' + block('diff', 1, PATCH) + block('diff', 7, PATCH) + CLOSE, T)
        self.assertEqual(found[7]['errors'], ['item 7: a fix-7 block or DECISION names no open item of this standing list'])

    def test_decision_lines_and_kinds(self):
        text = '1. open conflict\n   DECISION:T-X Which wins, spec or code?\n2. open text\n' + block('text', 2, TEXT) + CLOSE
        found = E.fixes(text, T)
        self.assertEqual((found[1]['kind'], found[1]['content']), ('decision', 'Which wins, spec or code?'))
        self.assertEqual(found[2]['kind'], 'text')

    def test_fixes_writes_nothing_to_standard_output(self):
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            E.fixes('1. open a\n' + block('diff', 1, PATCH) + CLOSE, T)
            E.fixes('1. open a\n' + CLOSE, T)
        self.assertEqual(said.getvalue(), '')

    def test_criteria_selects_the_same_standing_list_as_before(self):
        texts = ['1. open a\n2. open b\n' + CLOSE,
                 '1. old\n\n1. new\n  wrapped\n' + CLOSE,
                 'Label\n1. a\n2. b\nOther label\n1. c\n' + CLOSE,
                 '1. a\n## heading\n1. b\n' + CLOSE,
                 '1. a\n---\n2. b\n' + CLOSE,
                 '> 1. quoted\n```\n1. fenced\nCRITERIA-COMPLETE:T-X\n```\n1. real\n' + CLOSE,
                 '1. a\n' + block('diff', 1, PATCH) + '2. b\n   DECISION:T-X q\n' + CLOSE,
                 '1. no marker\n', 'REJECT:T-X\n', '1. a\n1. a\n3. c\n' + CLOSE,
                 '1. a\n\nprose\n2. b\n' + CLOSE]
        for text in texts:
            with self.subTest(text=text):
                self.assertEqual(E.criteria(text, T), old_criteria(text, T))


def rejection(text, fix_protocol=1, **extra):
    record = dict(kind='verdict', verdict='REJECT', text=text, **extra)
    if fix_protocol is not None:
        record['fix_protocol'] = fix_protocol
    return record


class Protocol(unittest.TestCase):
    def errors(self, text, **extra):
        return E.protocol([rejection(text, **extra)], T)

    def test_an_open_item_without_a_proposal_fails_and_its_counterpart_passes(self):
        self.assertEqual(self.errors('1. open helper\n' + CLOSE), ['open item 1 has no fix proposal or DECISION'])
        self.assertEqual(self.errors('1. helper is wrong\n' + CLOSE), ['open item 1 has no fix proposal or DECISION'],
                         'an unmarked first-round finding is open')
        self.assertEqual(self.errors('1. open helper\n' + block('diff', 1, PATCH) + CLOSE), [])
        self.assertEqual(self.errors('1. helper is wrong\n' + block('text', 1, TEXT) + CLOSE), [])

    def test_each_exactly_one_error_names_its_item(self):
        cases = {
            'two fix blocks': ('1. open a\n' + block('diff', 1, PATCH) + block('text', 1, TEXT),
                               'item 1 has more than one fix block'),
            'block and decision': ('1. open a\n   DECISION:T-X q\n' + block('diff', 1, PATCH),
                                   'item 1 has both a fix block and a DECISION line'),
            'two identical decisions': ('1. open a\n   DECISION:T-X same?\n   DECISION:T-X same?\n',
                                        'item 1 has more than one DECISION line'),
            'empty patch': ('1. open a\n' + block('diff', 1, ''),
                            'item 1 fix patch is empty or not a unified diff with a/ and b/ paths'),
            'patch without a/ b/ paths': ('1. open a\n' + block('diff', 1, '--- src/a\n+++ src/a\n@@ -1 +1 @@\n-x\n+y\n'),
                                          'item 1 fix patch is empty or not a unified diff with a/ and b/ paths'),
            'text missing a label': ('1. open a\n' + block('text', 1, TEXT.replace('fixes: test_a\n', '')),
                                     'item 1 text fix has no non-empty fixes: line'),
            'text with an empty label': ('1. open a\n' + block('text', 1, TEXT.replace('fail-first: test_a fails on the old code', 'fail-first:')),
                                         'item 1 text fix has no non-empty fail-first: line'),
            'block for a done item': ('1. done a\n' + block('diff', 1, PATCH),
                                      'item 1: a fix-1 block or DECISION names no open item of this standing list'),
            'decision in a done item': ('1. done a\n   DECISION:T-X q\n',
                                        'item 1: a fix-1 block or DECISION names no open item of this standing list'),
            'unknown item': ('1. open a\n' + block('diff', 1, PATCH) + block('diff', 2, PATCH),
                             'item 2: a fix-2 block or DECISION names no open item of this standing list'),
        }
        for name, (text, error) in cases.items():
            with self.subTest(case=name):
                self.assertIn(error, self.errors(text + CLOSE))

    def test_unindented_or_foreign_decisions_do_not_count(self):
        for line in ('DECISION:T-X q', '   DECISION:T-Y q', '   DECISION:T-X ', '   DECISION:T-XY q'):
            with self.subTest(line=line):
                self.assertEqual(self.errors('1. open a\n' + line + '\n' + CLOSE),
                                 ['open item 1 has no fix proposal or DECISION'])

    def test_later_lists_judge_only_open_and_labelled_items(self):
        first = rejection('1. open a\n2. open b\n' + block('diff', 1, PATCH) + block('text', 2, TEXT) + CLOSE)
        second = rejection('1. done a\n2. open b\n3. NEW-GROUND:T-X c\n' + CLOSE)
        self.assertEqual(E.protocol([first, second], T),
                         ['open item 2 has no fix proposal or DECISION', 'open item 3 has no fix proposal or DECISION'])
        fixed = rejection('1. done a\n2. open b\n' + block('text', 2, TEXT)
                          + '3. REGRESSION:T-X c\n   DECISION:T-X keep c?\n' + CLOSE)
        self.assertEqual(E.protocol([first, fixed], T), [])

    def test_legacy_rejections_keep_the_old_rules(self):
        self.assertEqual(self.errors('1. open helper\n' + CLOSE, fix_protocol=None), [])
        self.assertEqual(E.protocol([rejection('1. open a\n' + CLOSE, fix_protocol=None),
                                     rejection('1. open a\n' + CLOSE)], T),
                         ['open item 1 has no fix proposal or DECISION'])

    def test_a_valid_rejection_keeps_its_standing_list_syntax_valid(self):
        first = rejection('1. open a\n' + block('diff', 1, PATCH) + CLOSE)
        second = rejection('1. done a\n2. open REGRESSION:T-X b\n' + block('text', 2, TEXT) + CLOSE)
        self.assertEqual(E.protocol([first, second], T), [])

    def test_protocol_errors_carry_no_proposal_text(self):
        errors = self.errors('1. open a\n' + block('text', 1, 'SECRET_PROPOSAL\n') + '   DECISION:T-X SECRET_QUESTION\n' + CLOSE)
        self.assertTrue(errors)
        self.assertNotIn('SECRET', '; '.join(errors))


class Stored(unittest.TestCase):
    """Real local records, the protocol CLI and the draft writer."""
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.state = self.tmp / 'state'
        self.store = E.Store(self.state, 'self', T)
        self.head = 'a' * 40

    def reject(self, text, round_number=1, head=None, actor='reviewer-ada-tx-r1', legacy=False, **extra):
        fields = dict(verdict='REJECT', provenance={'level': 'legacy'}, reviewer=dict(name=actor.split('-')[1]))
        if not legacy:
            fields.update(fix_protocol=1, fix_checks=extra.pop('fix_checks', dict(
                version=1, status='complete', reason=None, items={})))
        fields.update(extra)
        return self.store.append('verdict', round_number, actor, head or self.head, text, **fields)

    def cli(self, *args):
        return subprocess.run([sys.executable, str(ROOT / 'bin/lib/fm_evidence.py'), *args,
                               '--state', str(self.state), '--project', 'self', '--task', T],
                              capture_output=True, text=True, env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1'))

    def test_signature_judges_the_triggering_rejection_despite_a_later_valid_one(self):
        bad = self.reject('1. open a\n' + CLOSE)
        self.reject('1. open a\n' + block('diff', 1, PATCH) + CLOSE, round_number=2)
        self.assertEqual(self.cli('protocol').returncode, 0, 'without --signature the latest list is judged, as before')
        bound = self.cli('protocol', '--signature', bad['signature'])
        self.assertIn('open item 1 has no fix proposal or DECISION', bound.stderr)
        self.assertNotEqual(bound.returncode, 0)
        self.assertNotEqual(self.cli('protocol', '--signature', 'f' * 64).returncode, 0)

    def mixed(self, **extra):
        text = ('1. done old finding\n2. open helper is wrong\n' + block('diff', 2, PATCH)
                + '3. open spec conflict\n   DECISION:T-X Which wins?\n4. open describe the change\n'
                + block('text', 4, TEXT) + CLOSE)
        checks = dict(version=1, status='complete', reason=None, items={
            '2': dict(kind='patch', apply='does-not-apply', message='error: patch failed: src/a:1', outside_scope=['src/a']),
            '3': dict(kind='decision', apply='not-a-patch', message=None, outside_scope=[])})
        return text, self.reject(text, fix_checks=extra.pop('fix_checks', checks), **extra)

    def test_draft_lines_proposals_checks_and_source(self):
        text, record = self.mixed()
        path, decision = E.fixes_brief(self.store, 2, self.head)
        self.assertTrue(decision)
        self.assertEqual(path, self.state / 'briefs' / f'T-X-r2-{self.head[:12]}-{record["signature"][:8]}-review-fixes.md')
        draft = path.read_text()
        self.assertIn('1. deferred: done in the reviewed round; keep as is\n', draft)
        self.assertIn('2. fix: open helper is wrong\n\n```diff fix-2\n' + PATCH + '```\n', draft)
        self.assertIn('patch check: does not apply to the reviewed head: error: patch failed: src/a:1; '
                      'outside the pinned scope: src/a', draft)
        self.assertIn('3. deferred: captain decision needed: Which wins?\n', draft)
        self.assertIn('4. fix: open describe the change\n\n```text fix-4\n' + TEXT + '```\n', draft)
        self.assertIn('patch check missing for item 4', draft)
        self.assertTrue(draft.rstrip().endswith(f'Source: reviewer reviewer-ada-tx-r1, round 1, head {self.head}, '
                                                f'signature {record["signature"]}'))
        report = coverage('reject', {}, draft, dict(findings=E.criteria(text, T)), self.tmp, [])
        self.assertEqual(report['gaps'], [], 'a generated mixed draft passes the reject coverage check')

    def test_handcrafted_brief_lines_pass_the_coverage_check(self):
        brief = '1. fix: rename the helper\n2. deferred: done already\n'
        report = coverage('reject', {}, brief, dict(findings=[(1, 'a'), (2, 'b')]), self.tmp, [])
        self.assertEqual(report['gaps'], [])

    def test_unavailable_checks_and_the_cli_path(self):
        self.mixed(fix_checks=dict(version=1, status='unavailable', reason='git missing', items={}))
        result = self.cli('fixes-brief', '--round', '2', '--head', self.head)
        self.assertEqual(result.returncode, 0, result.stderr)
        draft = Path(result.stdout.strip()).read_text()
        self.assertEqual(draft.count('patch check unavailable'), 2)

    def test_refusals_write_nothing_and_exit_65(self):
        def refused(*args, reason):
            result = self.cli('fixes-brief', *args)
            self.assertEqual(result.returncode, 65, result.stderr)
            self.assertIn(reason, result.stderr)
            self.assertFalse((self.state / 'briefs').exists())
        refused('--round', '2', '--head', self.head, reason='no REJECT verdict')
        self.reject('1. open a\n' + block('diff', 1, PATCH) + CLOSE, legacy=True)
        refused('--round', '2', '--head', self.head, reason='legacy REJECT')
        self.reject('1. open a\n' + CLOSE)
        refused('--round', '2', '--head', self.head, reason='fails the review protocol')
        self.reject('1. open a\n' + block('diff', 1, PATCH) + CLOSE, round_number=3)
        refused('--round', '3', '--head', self.head, reason='does not follow')

    def test_same_source_repeats_keep_firstmate_context_and_new_sources_get_new_files(self):
        self.mixed()
        path, _ = E.fixes_brief(self.store, 2, self.head)
        with path.open('a') as stream:
            stream.write('\n## Context from firstmate\nThe helper moved.\n')
        kept = path.read_bytes()
        again = self.cli('fixes-brief', '--round', '2', '--head', self.head)
        self.assertEqual(again.stdout.strip(), str(path))
        self.assertEqual(path.read_bytes(), kept)
        other = 'b' * 40
        self.mixed(head=other)  # a later list re-issues every earlier number
        moved, _ = E.fixes_brief(self.store, 2, other)
        self.assertNotEqual(moved, path)
        self.mixed()  # a corrected verdict for the same head
        corrected, _ = E.fixes_brief(self.store, 2, self.head)
        self.assertNotIn(corrected, (path, moved))
        self.assertEqual(path.read_bytes(), kept)

    def test_existing_pins_and_briefs_keep_their_bytes_and_signatures(self):
        pin = self.state / 'pins/self/T-X/1.json'
        pin.parent.mkdir(parents=True)
        pin.write_text('{"version":1}\n')
        brief = self.store.append('brief', 2, 'firstmate', self.head, '1. fix: earlier brief\n', authorized=True)
        files = {p: p.read_bytes() for p in (self.state / 'evidence').rglob('*.json')}
        self.mixed()
        E.fixes_brief(self.store, 2, self.head)
        for path, data in files.items():
            self.assertEqual(path.read_bytes(), data)
        self.assertEqual(pin.read_text(), '{"version":1}\n')
        found = self.store.brief(2, self.head)
        self.assertEqual((found['text'], found['signature']), (brief['text'], brief['signature']))

    def test_the_avoided_reviewer_is_the_latest_rejection_with_or_without_the_field(self):
        self.assertEqual(E.avoided_reviewer(self.store), '')
        self.reject('1. open a\n' + CLOSE, actor='reviewer-ada-tx-r1', legacy=True)
        self.assertEqual(E.avoided_reviewer(self.store), 'ada')
        self.store.append('verdict', 2, 'reviewer-bo-tx-r2', self.head, 'APPROVE:T-X', verdict='APPROVE',
                          provenance={'level': 'legacy'}, reviewer=dict(name='bo'))
        self.assertEqual(E.avoided_reviewer(self.store), 'ada')
        self.store.append('verdict', 1, 'reviewer-cy-tx-r1', '', '1. open a\n' + CLOSE, verdict='REJECT',
                          provenance={'level': 'legacy'})
        self.assertEqual(E.avoided_reviewer(self.store), 'cy', 'an old record without a reviewer field names its actor')

    def test_history_reaches_a_rotated_reviewer_and_the_login_filter_still_applies(self):
        self.reject('1. open ADA_LIST\n' + CLOSE, actor='reviewer-ada-tx-r1', login='ada-login')
        self.reject('1. open BO_LIST\n' + CLOSE, actor='reviewer-bo-tx-r2', round_number=2, login='bo-login')
        with patch.dict(os.environ):
            os.environ.pop('FM_REVIEWER_LOGIN', None)
            history = self.store.history(reviewer=True)
        self.assertIn('ADA_LIST', history); self.assertIn('BO_LIST', history)
        with patch.dict(os.environ, FM_REVIEWER_LOGIN='bo-login'):
            history = self.store.history(reviewer=True)
        self.assertNotIn('ADA_LIST', history); self.assertIn('BO_LIST', history)


class Retain(unittest.TestCase):
    """retain_verdict's single append, the patch check and its isolation."""
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.repo = self.tmp / 'repo'
        self.head = repository(self.repo)
        self.run_dir = self.tmp / 'run'
        (self.run_dir / 'pinned').mkdir(parents=True)
        (self.run_dir / 'evidence-binding.json').write_text(json.dumps(dict(head=self.head, base='b' * 40, patch='p')))
        (self.run_dir / 'pinned/spec.json').write_text(json.dumps(dict(id=T, scope=['src/**'])))

    def retain(self, store, text, project='self', external='0'):
        (self.run_dir / 'identity.json').write_text(json.dumps(dict(project=project, task=T, role='reviewer',
                                                                    round=1, name='ada')))
        answer = self.run_dir / 'answer.txt'
        answer.write_text(text)
        args = SimpleNamespace(run=str(self.run_dir), round=1, vendor='custom', file=str(answer),
                               head=self.head, base='b' * 40, patch='p', attempt='a1')
        with patch.dict(os.environ, FM_ACTOR='reviewer-ada-tx-r1', FM_TARGET_ROOT=str(self.repo), FM_EXTERNAL=external):
            return E.retain_verdict(store, args)

    def test_fix_checks_and_migration_field(self):
        text = ('1. open a\n' + block('diff', 1, PATCH) + '2. open b\n' + block('diff', 2, STALE)
                + '3. open c\n' + block('diff', 3, OUTSIDE) + '4. open d\n' + block('text', 4, TEXT)
                + '5. open e\n   DECISION:T-X q?\n' + CLOSE)
        before = repository_state(self.repo)
        record = self.retain(E.Store(self.tmp / 'state', 'self', T), text)
        self.assertEqual(record['fix_protocol'], 1)
        checks = record['fix_checks']
        self.assertEqual((checks['version'], checks['status'], checks['reason']), (1, 'complete', None))
        items = checks['items']
        self.assertEqual(items['1'], dict(kind='patch', apply='applies', message=None, outside_scope=[]))
        self.assertEqual((items['2']['apply'], items['2']['outside_scope']), ('does-not-apply', []))
        self.assertTrue(items['2']['message'].startswith('error:'), items['2']['message'])
        self.assertEqual((items['3']['apply'], items['3']['outside_scope']), ('applies', ['docs/b']))
        self.assertEqual(items['4'], dict(kind='text', apply='not-a-patch', message=None, outside_scope=[]))
        self.assertEqual(items['5']['kind'], 'decision')
        self.assertEqual(repository_state(self.repo), before, 'no tracked file, index, ref or worktree changed')
        self.assertEqual(E.Store(self.tmp / 'state', 'self', T).verdicts()[-1]['signature'], record['signature'])

    def test_an_unavailable_check_still_retains_the_verdict(self):
        result = E.fix_checks('1. open a\n' + block('diff', 1, PATCH) + CLOSE, T, self.head, self.repo, [],
                              git=str(self.tmp / 'no-git'))
        self.assertEqual((result['status'], result['items']), ('unavailable', {}))
        self.assertTrue(result['reason'])
        result = E.fix_checks('1. open a\n' + block('diff', 1, PATCH) + CLOSE, T, 'c' * 40, self.repo, [])
        self.assertEqual(result['status'], 'unavailable')
        with patch.object(E, 'fix_checks', lambda *a, **k: dict(version=1, status='unavailable', reason='timeout', items={})):
            record = self.retain(E.Store(self.tmp / 'state', 'self', T), '1. open a\n' + block('diff', 1, PATCH) + CLOSE)
        self.assertEqual(record['fix_checks']['status'], 'unavailable')

    def test_the_temporary_index_is_outside_both_repositories_and_removed(self):
        for name, external in (('self', '0'), ('external', '1')):
            with self.subTest(project=name):
                made = []
                original = tempfile.mkdtemp
                def tracked(*args, **kwargs):
                    made.append(Path(original(*args, **kwargs)))
                    return str(made[-1])
                store = E.Store(self.tmp / ('state-' + name), name, T, external=external == '1')
                before = repository_state(self.repo)
                with patch.object(tempfile, 'mkdtemp', tracked):
                    self.retain(store, '1. open a\n' + block('diff', 1, PATCH) + CLOSE, project=name, external=external)
                checked = [p for p in made if p.name.startswith('fm-fix-check-')]
                self.assertEqual(len(checked), 1)
                for owner in (self.repo, ROOT):
                    self.assertFalse(checked[0].resolve().is_relative_to(owner.resolve()))
                self.assertFalse(checked[0].exists())
                self.assertEqual(repository_state(self.repo), before)

    def test_an_interruption_during_the_check_publishes_nothing(self):
        store = E.Store(self.tmp / 'state', 'self', T)
        earlier = self.retain(store, 'APPROVE:T-X')
        files = {p: p.read_bytes() for p in store.directory.glob('*.json')}
        before = repository_state(self.repo)
        (self.run_dir / 'answer.txt').write_text('1. open a\n' + block('diff', 1, PATCH) + CLOSE)
        argv = ['fm_evidence.py', 'verdict', '--state', str(self.tmp / 'state'), '--project', 'self', '--task', T,
                '--round', '1', '--head', self.head, '--base', 'b' * 40, '--patch', 'p', '--run', str(self.run_dir),
                '--attempt', 'a1', '--vendor', 'custom', '--file', str(self.run_dir / 'answer.txt')]
        real = subprocess.run
        def interrupted(command, *args, **kwargs):
            if 'apply' in command:
                raise KeyboardInterrupt
            return real(command, *args, **kwargs)
        with patch.object(sys, 'argv', argv), patch.object(subprocess, 'run', interrupted), \
                patch.dict(os.environ, FM_ACTOR='reviewer-ada-tx-r1', FM_TARGET_ROOT=str(self.repo)):
            with self.assertRaises(KeyboardInterrupt):
                E.main()
        self.assertEqual({p: p.read_bytes() for p in store.directory.glob('*.json')}, files)
        self.assertEqual([r['signature'] for r in store.records()], [earlier['signature']])
        self.assertFalse((self.run_dir / 'evidence-record.json').exists())
        self.assertEqual(repository_state(self.repo), before)

    def test_a_verdict_from_the_old_frozen_launcher_keeps_the_old_rules(self):
        store = E.Store(self.tmp / 'state', 'self', T)
        old = store.append('verdict', 1, 'reviewer-ada-tx-r1', self.head, '1. open a\n' + CLOSE, verdict='REJECT',
                           provenance={'level': 'legacy'}, reviewer=dict(name='ada'))
        self.assertNotIn('fix_protocol', old)
        self.assertEqual(E.protocol(store.verdicts(), T), [])
        with self.assertRaisesRegex(E.Refused, 'legacy'):
            E.fixes_brief(store, 2, self.head)
        new = self.retain(store, '1. open a\n' + CLOSE)
        self.assertEqual(new['fix_protocol'], 1)
        self.assertEqual(E.protocol(store.verdicts(), T), ['open item 1 has no fix proposal or DECISION'])


class External(unittest.TestCase):
    def test_drafts_stay_in_each_private_project_state(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, FM_EXTERNAL='1'):
            head = 'a' * 40
            stores = [E.Store(Path(tmp) / name / 'state', name, T) for name in ('one', 'two')]
            stores[0].append('verdict', 1, 'reviewer-ada-tx-r1', head, '1. open a\n' + block('text', 1, 'file: SECRET_PROPOSAL\n'
                             'change: c\nfixes: f\nfail-first: g\n') + CLOSE, verdict='REJECT',
                             provenance={'level': 'legacy'}, fix_protocol=1,
                             fix_checks=dict(version=1, status='complete', reason=None, items={}))
            path, _ = E.fixes_brief(stores[0], 2, head)
            self.assertTrue(path.is_relative_to(Path(tmp) / 'one/state/briefs'))
            self.assertIn('SECRET_PROPOSAL', path.read_text())
            with self.assertRaisesRegex(E.Refused, 'no REJECT'):
                E.fixes_brief(stores[1], 2, head)
            self.assertFalse((Path(tmp) / 'two/state/briefs').exists())


class Rotation(unittest.TestCase):
    """Allocation in a fixture installation with a seeded crew."""
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        env = patch.dict(os.environ, {'FM_ROSTER_SEED': 't272'})
        env.start(); self.addCleanup(env.stop)
        for key in ('FM_ROUND', 'FM_PROJECT', 'FM_AVOID_REVIEWER', 'FM_SPEC_PREFLIGHT_MODE'):
            os.environ.pop(key, None)

    def allocate(self, role='reviewer', alias='', round_number=None, avoid=None, preflight=False):
        extra = {}
        if round_number: extra['FM_ROUND'] = str(round_number)
        if avoid: extra['FM_AVOID_REVIEWER'] = avoid
        if preflight: extra['FM_SPEC_PREFLIGHT_MODE'] = '1'
        with patch.dict(os.environ, extra):
            run = H.allocate(self.root, role, 'T-272', alias)
        H.save(run / 'orchestration-result.json', dict(process_exit=0))  # the run ended
        return json.loads((run / 'identity.json').read_text())['name']

    def test_the_review_after_a_rejection_gets_another_name(self):
        first = self.allocate(round_number=1)
        self.assertNotEqual(self.allocate(round_number=2, avoid=first), first)

    def test_a_retry_of_the_round_after_a_rejection_still_moves_on(self):
        first = self.allocate(round_number=1)
        self.assertEqual(self.allocate(round_number=1), first, 'an ordinary retry keeps its own name')
        self.assertNotEqual(self.allocate(round_number=1, avoid=first), first)

    def test_an_explicit_avoided_name_is_refused(self):
        first = self.allocate(round_number=1)
        with self.assertRaisesRegex(RuntimeError, 'reviewed the REJECT this round answers'):
            self.allocate(alias=first, round_number=2, avoid=first)

    def test_exclusion_that_leaves_no_name_runs_the_roster_out(self):
        (self.root / 'config.yaml').write_text('rosters:\n  workers: [bo]\n  reviewers: [ada]\n')
        self.assertEqual(self.allocate(round_number=1), 'ada')
        with self.assertRaisesRegex(RuntimeError, 'the reviewer roster ran out'):
            self.allocate(round_number=2, avoid='ada')

    def test_workers_and_spec_preflight_avoid_no_one(self):
        worker = self.allocate(role='worker')
        self.assertEqual(self.allocate(role='worker', avoid=worker), worker)
        first = self.allocate(preflight=True)
        self.assertEqual(self.allocate(preflight=True, avoid=first), first)


HEAD = 'c' * 40
PR = dict(number=12, title='T-001: fixture', state='open', head=dict(ref='t-001-fixture', sha=HEAD),
          base=dict(ref='main', sha='b' * 40), mergeable=True, mergeable_state='clean', draft=False)
CHECKS = [dict(id=1, name='ci', head_sha=HEAD, status='completed', conclusion='success')]


class Autopilot(BranchFixture, unittest.TestCase):
    """Both REJECT paths run the bound protocol check, then name the draft."""
    def setUp(self, external=False):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.state = self.root / 'state'; self.state.mkdir()
        (self.root / 'tasks').mkdir()
        self.ctx = dict(engine=str(self.root), state=str(self.state), target=str(self.root),
                        project='alpha', evidence_project='alpha', repository='owner/alpha',
                        base='main', external=external, tasks=str(self.root / 'tasks'))
        self.calls = []
        self.branch_setup()
        self.pilot = self.pilot_for()
        if external:
            # This fixture has no confirmed CONVENTIONS.md; its policy wake is not under test.
            self.pilot.policy_error = None
            self.pilot.data['wakes'] = {}

    def pilot_for(self):
        pilot = A.Pilot(self.ctx)
        pilot.api = lambda endpoint: dict(contexts=['ci'], checks=[])
        pilot.start_job = lambda kind, *a, **k: self.calls.append(('job', kind))
        pilot.authoritative_head = lambda task, pr: pr['head']['sha']
        pilot.command = self.command
        pilot.probe = self.branch_probe
        pilot.task = lambda pr: 'T-001'
        pilot.emit = lambda *a, **kw: self.calls.append(('emit', a))
        pilot.busy = lambda task: False
        return pilot

    def store(self):
        return E.Store(str(self.state), 'alpha', 'T-001', external=self.ctx['external'])

    def command(self, argv, **kwargs):
        self.calls.append(('command', argv))
        if argv[0].endswith('fm-protocol.sh'):
            # The real local protocol reader, bound exactly as fm-protocol.sh binds it.
            bound = argv[argv.index('--signature'):argv.index('--signature') + 2] if '--signature' in argv else []
            result = subprocess.run([sys.executable, str(ROOT / 'bin/lib/fm_evidence.py'), 'protocol', *bound,
                                     '--state', str(self.state), '--project', 'alpha', '--task', 'T-001',
                                     *(['--external'] if self.ctx['external'] else [])],
                                    capture_output=True, text=True)
            if result.returncode:
                raise RuntimeError(result.stderr)
            return result.stdout
        if argv[:2] == ['bash', '-c']:
            return A.Pilot.command(self.pilot, argv, **kwargs)
        return ''

    def reject(self, text, legacy=False, checks=None):
        fields = dict(verdict='REJECT', provenance={'level': 'legacy'}, reviewer=dict(name='ada'))
        if not legacy:
            fields.update(fix_protocol=1, fix_checks=checks or dict(version=1, status='complete', reason=None, items={
                '1': dict(kind='patch', apply='applies', message=None, outside_scope=[])}))
        return self.store().append('verdict', 1, 'reviewer-ada-t001-r1', HEAD, text, **fields)

    def wakes(self):
        return [w['summary'] for w in self.pilot.data['wakes'].values()]

    def review_completed(self):
        self.pilot.job_completed(dict(kind='review', task='T-001', pr=PR, code=0, output='', verdict_before='before'))

    def test_a_valid_rejection_names_its_draft_in_both_languages_on_both_paths(self):
        record = self.reject('1. open helper\n' + block('diff', 1, PATCH) + CLOSE.replace('T-X', 'T-001'))
        where = f'briefs/T-001-r2-{HEAD[:12]}-{record["signature"][:8]}-review-fixes.md'
        for trigger in (lambda: self.pilot.advance(PR, CHECKS, []), self.review_completed):
            with self.subTest(trigger=trigger):
                self.pilot.data['wakes'] = {}
                trigger()
                self.assertEqual(self.wakes(), [{
                    'en': f'T-001 REJECT: review fixes ready at {where}; record the brief',
                    'zh-TW': f'T-001 審查拒絕：審查修正草稿已備好於 {where}；請記錄工作簡報'}])
                self.assertTrue((self.state / where).is_file())
                protocol = [c[1] for c in self.calls if c[0] == 'command' and c[1][0].endswith('fm-protocol.sh')]
                self.assertIn(record['signature'], protocol[-1])
                self.assertEqual(protocol[-1][protocol[-1].index('--round') + 1], '1')
        self.assertFalse(any(c[0] == 'job' for c in self.calls), 'no worker, gate or review starts')

    def test_a_round_one_protocol_error_wakes_the_violation_on_both_paths(self):
        self.reject('1. open helper\n' + CLOSE.replace('T-X', 'T-001'))
        for trigger in (lambda: self.pilot.advance(PR, CHECKS, []), self.review_completed):
            with self.subTest(trigger=trigger):
                self.pilot.data['wakes'] = {}
                trigger()
                self.assertEqual(self.wakes(), [{'en': 'T-001: protocol violation in round 1',
                                                 'zh-TW': 'T-001：審查協定違規，需要 firstmate 處理'}])
                self.assertFalse((self.state / 'briefs').exists())

    def test_a_later_valid_record_cannot_mask_the_triggering_error(self):
        bad = self.reject('1. open helper\n' + CLOSE.replace('T-X', 'T-001'))
        self.pilot.verdict = lambda task: bad
        self.store().append('verdict', 1, 'reviewer-bo-t001-r1', 'd' * 40, '1. open helper\n'
                            + block('diff', 1, PATCH) + CLOSE.replace('T-X', 'T-001'), verdict='REJECT',
                            provenance={'level': 'legacy'}, fix_protocol=1)
        self.pilot.advance(PR, CHECKS, [])
        self.assertIn('protocol violation', str(self.wakes()))

    def test_a_restart_raises_no_second_wake_for_the_head(self):
        self.reject('1. open helper\n' + block('diff', 1, PATCH) + CLOSE.replace('T-X', 'T-001'))
        self.pilot.advance(PR, CHECKS, [])
        restored = self.pilot_for()
        restored.advance(PR, CHECKS, [])
        self.review_completed()
        self.assertEqual(len(restored.data['wakes']), 1)
        self.assertEqual(len(self.pilot.data['wakes']), 1)

    def test_decisions_and_legacy_rejections_still_need_a_brief(self):
        for text, legacy in (('1. open conflict\n   DECISION:T-001 spec or code?\n', False),
                             ('1. open helper\n', True)):
            with self.subTest(legacy=legacy):
                self.setUp()
                self.reject(text + CLOSE.replace('T-X', 'T-001'), legacy=legacy)
                self.pilot.advance(PR, CHECKS, [])
                self.assertEqual(self.wakes(), [{'en': 'T-001 REJECT: brief needed',
                                                 'zh-TW': 'T-001 審查拒絕：需要 firstmate 撰寫工作簡報'}])

    def test_an_external_wake_names_no_path_proposal_or_git_message(self):
        self.setUp(external=True)
        self.reject('1. open helper\n' + block('text', 1, TEXT.replace('replace x with y', 'SECRET_PROPOSAL'))
                    + CLOSE.replace('T-X', 'T-001'),
                    checks=dict(version=1, status='complete', reason=None, items={'1': dict(
                        kind='text', apply='not-a-patch', message='SECRET_GIT_MESSAGE', outside_scope=[])}))
        self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(self.wakes(), [{
            'en': 'T-001 REJECT: review fixes ready in the private project state; record the brief',
            'zh-TW': 'T-001 審查拒絕：審查修正草稿已備好於私有專案狀態；請記錄工作簡報'}])
        drafts = list((self.state / 'briefs').glob('*.md'))
        self.assertEqual(len(drafts), 1)
        public = json.dumps(self.pilot.data, ensure_ascii=False) + str([c for c in self.calls if c[0] == 'emit'])
        for secret in ('SECRET_PROPOSAL', 'SECRET_GIT_MESSAGE', str(self.state), 'briefs/'):
            self.assertNotIn(secret, public)


if __name__ == '__main__':
    unittest.main()
