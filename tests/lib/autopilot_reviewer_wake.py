"""T-254: private evidence refresh, per-row wakes and confirmed review requests."""
import json
import os
from unittest.mock import patch

os.environ['HERDR_ENV'] = '0'

import fm_autopilot as A
from autopilot_branch_fixture import recheck_response

HEAD = 'a' * 40
SECRET = 'SECRET-BODY src/x.py:9 https://example.invalid/r'


class ReviewerWakeCases:
    def reviewer_setup(self):
        self.external_pilot()
        self.ancestry[(self.base_tip, HEAD)] = 0
        self.pilot.policy.update(review='both', reviewers=['Rev'], request_reviewers=[])
        self.pilot.push = lambda *args: None
        self.pilot.notify = lambda *args: None
        self.collect_calls = []
        self.evidence = dict(kind='external-verdict', task='T-001', pr=12, head=HEAD,
            ready=False, blockers=['Rev requested changes'],
            states={'rev': dict(state='CHANGES_REQUESTED', reviewed_head=HEAD, covers=True,
                                review={'body': SECRET})},
            findings=[dict(id=i, reviewer='rev', path='src/x.py', line=i, body=SECRET,
                           url='https://example.invalid/r', reviewed_head=HEAD, resolved=False)
                      for i in (9, 10)])
        original = self.pilot.command
        def command(argv, **kwargs):
            if argv[0].endswith('/fm-external.sh'):
                self.collect_calls.append(argv)
                if isinstance(self.evidence, Exception):
                    raise self.evidence
                return self.evidence if isinstance(self.evidence, str) else json.dumps(self.evidence)
            return original(argv, **kwargs)
        self.pilot.command = command
        # Reuse the shared PR shape, deliberately without an author.
        return dict(self.behind(), mergeable_state='clean')

    def reviewer_row(self, ident=31, login='rev'):
        return dict(id=ident, user={'login': login}, state='CHANGES_REQUESTED',
                    body=SECRET, commit_id=HEAD, submitted_at='2026-10-07T00:00:00Z',
                    html_url='https://example.invalid/review')

    def reviewer_comment(self, ident=32, source='review-comment'):
        row = dict(id=ident, user={'login': 'rev'}, body=SECRET,
                   updated_at='2026-10-07T00:00:00Z')
        if source == 'review-comment':
            row.update(pull_request_review_id=31, path='src/x.py', line=9,
                       original_line=9, commit_id=HEAD)
        else:
            row['html_url'] = 'https://example.invalid/comment'
        if source is not None:
            row['_source'] = source
        return row

    def reviewer_flush(self):
        self.pilot.clock = lambda: 2000
        self.pilot.flush()
        return [w['line'] for w in self.pilot.data['wakes'].values()]

    def test_external_collect_exact_argv_private_wake_and_outsider_regression(self):
        pr = self.reviewer_setup()
        rows = [self.reviewer_row(), self.reviewer_row(33, 'other')]
        self.pull_at(pr, rows)
        self.assertEqual(self.collect_calls, [[str(A.BIN / 'fm-external.sh'),
            'collect', '--task', 'T-001', '--pr', '12', '--branch', 't-001-work',
            '--repo', str(self.root), '--project', 'self']])
        self.assertEqual(set(self.pilot.data['batches']), {'12:rev:review:31', '12:other'})
        self.assertEqual(self.pilot.data['batches']['12:other']['lines'],
                         ['T-001 #12 other: CHANGES_REQUESTED https://example.invalid/review'])
        self.pull_at(pr, rows)
        self.assertEqual(len(self.collect_calls), 1)
        lines = self.reviewer_flush()
        line = next(x for x in lines if '#12 rev ' in x)
        self.assertEqual(line, 'T-001 #12 rev CHANGES_REQUESTED 31: external evidence blocked '
                         'at aaaaaaa, 2 finding(s); read fm_external findings for the task')
        self.assertNotIn(SECRET, line)
        self.assertNotIn('https:', line)
        self.assertEqual(len(lines), 2)

    def test_external_review_and_comment_collect_once_and_wake_independently(self):
        pr = self.reviewer_setup()
        self.pull_at(pr, [self.reviewer_row()], [self.reviewer_comment()])
        self.assertEqual(len(self.collect_calls), 1)
        self.assertEqual(set(self.pilot.data['batches']), {'12:rev:review:31', '12:rev:review-comment:32'})
        self.assertEqual(len(self.reviewer_flush()), 2)

    def test_external_issue_and_untagged_comment_sources(self):
        pr = self.reviewer_setup()
        self.pull_at(pr, [], [self.reviewer_comment(33, 'issue-comment'), self.reviewer_comment(34, None)])
        self.assertEqual(set(self.pilot.data['batches']), {'12:rev:issue-comment:33', '12:rev:comment:34'})
        lines = self.reviewer_flush()
        self.assertTrue(any('rev issue-comment 33:' in x for x in lines))
        self.assertTrue(any('rev comment 34:' in x for x in lines))
        self.assertNotIn(SECRET, str(lines))

    def test_external_equal_endpoint_ids_remain_distinct(self):
        pr = self.reviewer_setup()
        self.pull_at(pr, [self.reviewer_row(31)], [self.reviewer_comment(31)])
        self.assertEqual(len(self.reviewer_flush()), 2)
        self.assertEqual(len(self.collect_calls), 1)

    def test_external_evidence_failure_classes_do_not_hide_review_or_leak_text(self):
        for failure in ('command', 'json', 'fields', 'stale-head'):
            with self.subTest(failure=failure):
                pr = self.reviewer_setup()
                self.pilot.data['seen'].clear()
                self.pilot.data['batches'].clear()
                if failure == 'command': self.evidence = RuntimeError(SECRET)
                elif failure == 'json': self.evidence = SECRET
                elif failure == 'fields': self.evidence.update(head=SECRET, ready='false', findings={})
                else: self.evidence['head'] = 'b' * 40
                self.pilot.attention('advance-error', 'T-001', pr, 'advance error', '流程錯誤')
                self.pull_at(pr, [self.reviewer_row()])
                identity = 'autopilot-' + A.key(['self', f'external-evidence-{failure}-12-{HEAD}'])
                wake = self.pilot.data['wakes'][identity]
                self.assertEqual(wake['summary'], {'en': 'external evidence refresh failed: ' + failure,
                                                  'zh-TW': '外部證據更新失敗：' + failure})
                self.pull_at(pr, [self.reviewer_row(35)])
                lines = self.reviewer_flush()
                self.assertEqual(sum('refresh failed' in x for x in lines), 1)
                self.assertTrue(any('advance error' in x for x in lines))
                self.assertTrue(any('external evidence unknown at aaaaaaa;' in x for x in lines))
                self.assertNotIn('finding(s)', str(lines))
                for secret in (SECRET, 'src/x.py', 'https://example.invalid'):
                    self.assertNotIn(secret, str(self.pilot.data['wakes']))

    def test_external_evidence_validation_requires_object_and_each_typed_field(self):
        samples = [('[]', 'json'), ('null', 'json'),
                   ({'head': 'bad', 'ready': False, 'findings': []}, 'fields'),
                   ({'head': HEAD, 'ready': 1, 'findings': []}, 'fields'),
                   ({'head': HEAD, 'ready': True, 'findings': {}}, 'fields'),
                   ({'head': 'b'*40, 'ready': 'yes', 'findings': []}, 'fields')]
        for index, (record, failure) in enumerate(samples):
            with self.subTest(record=record):
                pr = self.reviewer_setup()
                self.evidence = record
                self.pull_at(pr, [self.reviewer_row(100 + index)])
                identity = 'autopilot-' + A.key(['self', f'external-evidence-{failure}-12-{HEAD}'])
                self.assertIn(identity, self.pilot.data['wakes'])

    def test_external_unmapped_pr_does_not_collect_or_request(self):
        pr = self.external_request_setup()
        pr['head']['ref'] = 'unmapped-work'
        self.pull_at(pr, [self.reviewer_row()])
        self.assertEqual(self.collect_calls, [])
        self.assertEqual(self.review_posts, [])
        self.assertEqual(self.pilot.data['rechecked'], {})

    def test_external_ready_and_external_policy(self):
        pr = self.reviewer_setup()
        self.pilot.policy['review'] = 'external'
        self.evidence['ready'] = True
        self.pull_at(pr, [self.reviewer_row()])
        self.assertEqual(len(self.collect_calls), 1)
        self.assertIn('external evidence ready', self.reviewer_flush()[0])

    def test_external_edited_review_wakes_again(self):
        pr = self.reviewer_setup()
        row = self.reviewer_row()
        self.pull_at(pr, [row]); self.reviewer_flush()
        row['body'] += ' edited'
        self.pull_at(pr, [row])
        self.pilot.clock = lambda: 3000
        self.pilot.flush()
        self.assertEqual(len(self.collect_calls), 2)
        self.assertEqual(len(self.pilot.data['wakes']), 2)

    def test_external_fm_policy_keeps_original_batch(self):
        pr = self.reviewer_setup()
        self.pilot.policy['review'] = 'fm'
        self.pull_at(pr, [self.reviewer_row()])
        self.assertEqual(self.collect_calls, [])
        self.assertEqual(list(self.pilot.data['batches']), ['12:rev'])
        self.assertEqual(self.reviewer_flush(), ['T-001 #12 rev: CHANGES_REQUESTED https://example.invalid/review'])

    def test_external_restart_preserves_seen_and_old_batches(self):
        pr = self.reviewer_setup()
        row = self.reviewer_row()
        token = A.key(['12', 'review', None, 31, None, 'CHANGES_REQUESTED', SECRET, HEAD])
        self.pilot.data['seen'][token] = True
        self.pilot.data['batches']['12:rev'] = dict(task='T-001', lines=['legacy finding'], due=1100)
        self.pilot.queue('legacy-wake', 'T-001', 'already queued', '已排入')
        self.pilot.save()
        old = self.pilot
        with patch.object(A, 'read_policy', return_value=old.policy):
            self.pilot = A.Pilot(self.context, clock=lambda: 1000)
        for name in ('command', 'probe', 'read_head_spec', 'advance', 'prepare_head', 'push', 'notify'):
            setattr(self.pilot, name, getattr(old, name))
        self.assertEqual(self.pilot.data['seen'], old.data['seen'])
        self.assertEqual(self.pilot.data['wakes'], old.data['wakes'])
        self.pull_at(pr, [row])
        self.assertEqual(self.collect_calls, [])
        lines = self.reviewer_flush()
        self.assertEqual(lines.count('already queued'), 1)
        self.assertEqual(lines.count('legacy finding'), 1)
        self.pilot.flush()
        self.assertEqual(len(self.pilot.data['wakes']), 2)
        self.pull_at(pr, [row, self.reviewer_row(36)])
        self.pilot.clock = lambda: 3000
        self.pilot.flush()
        lines = [w['line'] for w in self.pilot.data['wakes'].values()]
        self.assertEqual(lines.count('legacy finding'), 1)
        self.assertTrue(any('CHANGES_REQUESTED 36:' in x for x in lines))

    def external_request_setup(self):
        pr = self.reviewer_setup()
        self.recheck_setup(old=False)
        self.pilot.policy.update(reviewers=['Rev', 'Bot'], post='local')
        self.pilot.policy.pop('request_reviewers')
        return pr

    def test_external_first_sight_requests_confirmed_names_except_author(self):
        pr = self.external_request_setup()
        pr['user'] = {'login': 'bot'}
        self.pull_at(pr); self.pull_at(pr)
        self.assertEqual([argv for _, argv in self.review_posts], [['gh', 'api', '-X', 'POST',
            'repos/owner/repo/pulls/12/requested_reviewers', '-f', 'reviewers[]=Rev', '--include']])
        self.assertEqual(self.pilot.data['rechecked']['12'], dict(head=HEAD, names=[], rule='external-request'))

    def test_external_new_head_and_upgrade_request_once_in_local_mode(self):
        pr = self.external_request_setup()
        self.pilot.policy['reviewers'] = ['Rev']
        self.pilot.data['rechecked']['12'] = dict(head=HEAD, names=[])
        self.pull_at(pr); self.pull_at(pr)
        self.assertEqual(len(self.review_posts), 1)
        old_review = dict(id=1, user={'login':'Rev'}, commit_id=HEAD, state='APPROVED')
        pr['head']['sha'] = 'c'*40
        self.pull_at(pr, [old_review]); self.pull_at(pr, [old_review])
        self.assertEqual(len(self.review_posts), 2)
        self.assertEqual(self.pilot.data['rechecked']['12']['rule'], 'external-request')

    def test_external_refused_name_does_not_block_other_requests(self):
        pr = self.external_request_setup()
        original = self.pilot.probe
        def probe(argv, *, env=None):
            self.review_answer = (recheck_response(422, 'Unprocessable Entity', {'message':'not a collaborator'})
                                  if 'reviewers[]=Rev' in argv else recheck_response(201, 'Created', pr))
            return original(argv, env=env)
        self.pilot.probe = probe
        self.pull_at(pr); self.pull_at(pr)
        self.assertEqual(len(self.review_posts), 2)
        self.assertEqual(self.pilot.data['rechecked']['12']['names'], [])
        self.assertEqual(len(self.pilot.data['wakes']), 1)
        self.assertIn('not a collaborator', str(self.pilot.data['wakes']))

    def test_external_request_transport_retries_zero_one_three(self):
        pr = self.external_request_setup()
        self.pilot.policy['reviewers'] = ['Rev']
        self.review_answer = RuntimeError('connection reset')
        for _ in range(8): self.pull_at(pr)
        self.assertEqual([seq for seq, _ in self.review_posts], [1, 2, 4])
        self.assertEqual(len(self.pilot.data['wakes']), 1)

    def test_external_request_missing_author_empty_and_override(self):
        pr = self.external_request_setup()
        self.pull_at(pr)
        self.assertEqual(len(self.review_posts), 2)
        self.assertEqual(self.pilot.data['rechecked']['12']['rule'], 'external-request')
        pr['head']['sha'] = 'c'*40
        self.pilot.policy['request_reviewers'] = []
        self.pull_at(pr)
        self.assertEqual(len(self.review_posts), 2)
        pr['head']['sha'] = 'd'*40
        self.pilot.policy['request_reviewers'] = ['Other']
        self.pull_at(pr)
        self.assertEqual(len(self.review_posts), 3)
        self.assertIn('reviewers[]=Other', self.review_posts[-1][1])

    def test_external_requested_or_current_review_suppresses_request(self):
        pr = self.external_request_setup()
        pr['requested_reviewers'] = [{'login':'REV'}]
        self.pull_at(pr, [dict(id=1, user={'login':'bot'}, state='APPROVED', commit_id=HEAD)])
        self.assertEqual(self.review_posts, [])
        self.assertEqual(self.pilot.data['rechecked']['12'], dict(head=HEAD, names=[], rule='external-request'))
