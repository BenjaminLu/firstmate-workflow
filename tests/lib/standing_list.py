"""Standing-list regressions, including the real signed gate reader."""
import os
from pathlib import Path
import subprocess
import sys
import unittest

code, temporary = map(Path, sys.argv[1:])
sys.path.insert(0, str(code / 'bin/lib'))
from fm_evidence import Store, criteria, protocol
from fm_binding import source_binding

TASK = 'T-180'
FIXTURE = code / 'tests/lib/fixtures/t180-round1-standing-list.md'
review = FIXTURE.read_text()


def rejection(text):
    return dict(kind='verdict', verdict='REJECT', text=text)


def closed(block):
    return block + '\nCRITERIA-COMPLETE:T-180\nREJECT:T-180'


class StandingList(unittest.TestCase):
    def test_t180_fixture_extracts_only_standing_items(self):
        self.assertEqual([1, 2], [n for n, _ in criteria(review, TASK)])
        self.assertEqual([], protocol([rejection(review)], TASK))

    def test_continuations_and_blank_lines_belong_to_items(self):
        text = closed('1. open: first\nwrapped text\n\n'
                      '   another paragraph\n\n2) open: second\n  more detail\n')
        self.assertEqual([(1, 'open: first\nwrapped text\n\n   another paragraph'),
                          (2, 'open: second\n  more detail')], criteria(text, TASK))

    def test_prior_numbered_sections_are_ignored(self):
        for prefix in ('1. summary\n2. summary\n\nStanding list:\n',
                       '## Executed\n1. command\n2. command\n\n## Standing list\n',
                       '99. code outside a fence\n\nThe standing list follows.\n'):
            with self.subTest(prefix=prefix):
                self.assertEqual([1, 2], [n for n, _ in criteria(
                    prefix + closed('1. open: first\n2. open: second'), TASK)])

    def test_duplicate_and_skipped_numbers_remain_errors(self):
        for block in ('1. first\n1. duplicate', '1. first\n3. skipped',
                      '1. first\n2. second\n1. duplicate\n2. duplicate'):
            with self.subTest(block=block):
                self.assertIn('standing list numbering is not consecutive and unique',
                              protocol([rejection(closed(block))], TASK))

    def test_carry_forward_states_and_new_labels_remain_required(self):
        first = rejection(review)
        for block, error in (('1. done: first', 'standing list dropped item 2'),
                             ('1. first\n2. open: second', 'item 1 has no done/open state'),
                             ('1. done: first\n2. open: second\n3. extra',
                              'new item 3 has no REGRESSION or NEW-GROUND label'),
                             ('1. done: first\n2. open: second\n3. extra\n'
                              '   REGRESSION:T-180 quoted detail',
                              'new item 3 has no REGRESSION or NEW-GROUND label')):
            with self.subTest(block=block):
                self.assertIn(error, protocol([first, rejection(closed(block))], TASK))
        for label in ('REGRESSION', 'NEW-GROUND'):
            block = f'1. done: first\n2. open: second\n3. open: {label}:T-180 extra'
            self.assertEqual([], protocol([first, rejection(closed(block))], TASK))

    def test_only_unquoted_final_marker_closes_the_block(self):
        text = closed('1. obsolete') + '\n\n' + review
        text += '\n```\n9. example\nCRITERIA-COMPLETE:T-180\n```\n'
        text += '> 9. quoted\n> CRITERIA-COMPLETE:T-180\n'
        self.assertEqual([1, 2], [n for n, _ in criteria(text, TASK)])
        self.assertEqual([], criteria('1. incomplete', TASK))
        self.assertEqual([], criteria('1. unrelated\n\nA separate paragraph.\n'
                                      'CRITERIA-COMPLETE:T-180', TASK))

    def test_approve_without_reissued_list_passes_signed_gate(self):
        root = temporary / 'repo'
        root.mkdir()
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(('FM_', 'HERDR_'))}
        env.update(HERDR_ENV='0', FM_EXTERNAL='0', FM_TARGET_ROOT=str(root),
                   FM_STATE_DIR=str(root / 'state'), FM_TASKS_DIR=str(root / 'design/tasks'))

        def git(*args):
            return subprocess.check_output(['git', '-C', str(root), *args],
                                           env=env, text=True).strip()

        git('init', '-q', '-b', 'main')
        git('config', 'user.name', 'Fixture')
        git('config', 'user.email', 'fixture@example.invalid')
        (root / 'design/tasks').mkdir(parents=True)
        (root / 'design/tasks/T-180.json').write_text('{"id":"T-180","scope":["*"]}')
        (root / 'config.yaml').write_text('project:\n  check: true\n')
        (root / 'feature').write_text('base\n')
        git('add', '.')
        git('commit', '-qm', 'base')
        base = git('rev-parse', 'HEAD')
        git('checkout', '-qb', 'task')
        (root / 'feature').write_text('head\n')
        git('commit', '-qam', 'feature')
        head = git('rev-parse', 'HEAD')
        old_env = os.environ.copy()
        try:
            os.environ.clear()
            os.environ.update(env)
            binding = source_binding(TASK, head, base, code)
            store = Store(root / 'state', 'self', TASK)
            for round_number, text, verdict in ((1, review, 'REJECT'),
                                                (2, 'APPROVE:T-180', 'APPROVE')):
                store.append('verdict', round_number, 'reviewer', head, text,
                             verdict=verdict, base=base, patch=binding['patch'],
                             binding=binding, provenance={'level': 'legacy'})
            result = subprocess.run([
                sys.executable, str(code / 'bin/lib/fm_evidence.py'), 'gate',
                '--state', str(root / 'state'), '--project', 'self', '--task', TASK,
                '--head', head, '--base', base, '--patch', binding['patch'],
                '--code', str(code)], env=env, capture_output=True, text=True)
            self.assertEqual(0, result.returncode, result.stderr)
        finally:
            os.environ.clear()
            os.environ.update(old_env)


unittest.main(argv=[sys.argv[0]])
