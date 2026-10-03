"""Feature-owned tests; no network or background processes."""
import unittest
from unittest.mock import patch
import fm_stack as stack

A = 'a' * 40
B = 'b' * 40


class Stacking(unittest.TestCase):
    def test_open_base_retained(self):
        with patch.object(stack, 'github', return_value=[{'number': 9}]):
            self.assertFalse(stack.deletable('owner/repo', 't-parent'))

    def test_unknown_base_retained(self):
        with patch.object(stack, 'github', side_effect=ValueError('offline')):
            self.assertFalse(stack.deletable('owner/repo', 't-parent'))
        with patch.object(stack, 'github', return_value={}):
            self.assertFalse(stack.deletable('owner/repo', 't-parent'))

    def test_no_dependents_allows_deletion(self):
        with patch.object(stack, 'github', return_value=[]) as gh:
            self.assertTrue(stack.deletable('owner/repo', 't-parent'))
            self.assertIn('owner/repo', gh.call_args.args)
            self.assertIn('--base', gh.call_args.args)

    def test_stacking_off_waits(self):
        with patch.object(stack, 'github') as gh:
            with self.assertRaisesRegex(ValueError, 'waits'):
                stack.select_base('owner/repo', 'main', ['T-1'], set(), False)
            gh.assert_not_called()

    def test_allowed_dependency_uses_authoritative_head(self):
        prs = [{'number': 1, 'headRefName': 't-1-parent', 'headRefOid': A,
                'isCrossRepository': False}]
        with patch.object(stack, 'github', return_value=prs):
            self.assertEqual(stack.select_base('owner/repo', 'main', ['T-1'], set(), True),
                             {'name': 't-1-parent', 'head': A, 'pr': 1})

    def test_merged_dependencies_use_project_base(self):
        self.assertEqual(stack.select_base('owner/repo', 'main', ['T-1'], {'T-1'}, False),
                         {'name': 'main'})

    def test_ambiguous_and_fork_dependencies_wait(self):
        for prs in ([], [{'number': 1, 'headRefName': 't-1-parent', 'headRefOid': A,
                         'isCrossRepository': True}],
                    [{'number': n, 'headRefName': 't-1-parent', 'headRefOid': A,
                      'isCrossRepository': False} for n in (1, 2)]):
            with patch.object(stack, 'github', return_value=prs):
                with self.assertRaises(ValueError):
                    stack.select_base('owner/repo', 'main', ['T-1'], set(), True)

    def test_multiple_unmerged_dependencies_refused(self):
        with self.assertRaises(ValueError):
            stack.select_base('owner/repo', 'main', ['T-1', 'T-2'], set(), True)

    def test_per_pr_base_is_verified(self):
        view = {'state': 'OPEN', 'baseRefName': 't-1-parent', 'baseRefOid': A,
                'headRefOid': B, 'headRefName': 't-2-child'}
        with patch.object(stack, 'remote_head', return_value=view), \
             patch.object(stack, 'git', return_value=A):
            self.assertEqual(stack.pr_base('/repo', 'owner/repo', 2), 't-1-parent')
        with patch.object(stack, 'remote_head', return_value=view), \
             patch.object(stack, 'git', return_value=B):
            with self.assertRaises(ValueError):
                stack.pr_base('/repo', 'owner/repo', 2)

    def test_restack_requires_force_policy(self):
        with patch.object(stack, 'remote_head') as gh:
            with self.assertRaisesRegex(ValueError, 'policy'):
                stack.restack('/repo', 'owner/repo', 2, 1, B,
                              {'force_with_lease': False, 'base': 'main', 'stacking': 'allowed'}, '/tmp')
            gh.assert_not_called()

    def test_restack_refuses_protected_branch(self):
        view = {'state': 'OPEN', 'headRefName': 'main', 'baseRefName': 't-1-parent',
                'headRefOid': B, 'baseRefOid': A}
        with patch.object(stack, 'remote_head', return_value=view):
            with self.assertRaisesRegex(ValueError, 'protected'):
                stack.restack('/repo', 'owner/repo', 2, 1, B,
                              {'force_with_lease': True, 'base': 'main', 'stacking': 'allowed'}, '/tmp')

    def test_restack_uses_parent_boundary_and_expected_lease(self):
        child = {'state': 'OPEN', 'headRefName': 't-2-child', 'baseRefName': 't-1-parent',
                 'headRefOid': B, 'baseRefOid': A}
        parent = {'state': 'MERGED', 'headRefName': 't-1-parent', 'headRefOid': A,
                  'baseRefName': 'main'}
        new = 'c' * 40
        base = 'd' * 40
        def git_answer(root, *args):
            if args == ('rev-parse', 'refs/heads/t-2-child'): return B
            if args == ('rev-parse', 'FETCH_HEAD'):
                return next(fetches)
            if args == ('merge-base', A, B): return A
            if args == ('rev-parse', 'HEAD'): return new
            return ''
        fetches = iter([base, A])
        final = dict(child, headRefOid=new, baseRefName='main', baseRefOid=base)
        import tempfile
        with tempfile.TemporaryDirectory() as tmp, \
             patch.object(stack, 'remote_head', side_effect=[child, child, final]), \
             patch.object(stack, 'github', side_effect=[parent, {'protected': False}]), \
             patch.object(stack, 'git', side_effect=git_answer) as git, \
             patch.object(stack, 'command') as command:
            result = stack.restack('/repo', 'owner/repo', 2, 1, B,
                {'force_with_lease': True, 'base': 'main', 'stacking': 'allowed', 'delete_branch': False}, tmp)
            self.assertEqual(result['head'], new)
            calls = [call.args[1:] for call in git.call_args_list]
            self.assertIn(('-c', 'core.hooksPath=/dev/null', 'rebase', '--onto', base, A), calls)
            self.assertIn(('push', '--force-with-lease=refs/heads/t-2-child:' + B,
                           'https://github.com/owner/repo.git', 'HEAD:refs/heads/t-2-child'), calls)
            self.assertIn(('update-ref', 'refs/heads/t-2-child', new, B), calls)
            self.assertEqual(command.call_args.args[0][-2:], ['--base', 'main'])

    def test_restack_preserves_dirty_managed_worktree(self):
        child = {'state': 'OPEN', 'headRefName': 't-2-child', 'baseRefName': 't-1-parent',
                 'headRefOid': B, 'baseRefOid': A}
        parent = {'state': 'MERGED', 'headRefName': 't-1-parent', 'headRefOid': A, 'baseRefName': 'main'}
        import tempfile
        import os
        with tempfile.TemporaryDirectory() as tmp:
            fetches = iter(['d' * 40, A])
            def answer(root, *args):
                if args == ('rev-parse', 'refs/heads/t-2-child'): return B
                if args == ('rev-parse', 'FETCH_HEAD'): return next(fetches)
                if args == ('merge-base', A, B): return A
                if args == ('rev-parse', 'HEAD'): return 'c' * 40
                if args == ('worktree', 'list', '--porcelain'):
                    return 'worktree ' + tmp + '/T-2\nbranch refs/heads/t-2-child\n'
                if args == ('status', '--porcelain'): return ' M valuable.txt'
                return ''
            with patch.dict(os.environ, {'FM_WORKTREES': tmp}), \
                 patch.object(stack, 'remote_head', return_value=child), \
                 patch.object(stack, 'github', side_effect=[parent, {'protected': False}]), \
                 patch.object(stack, 'git', side_effect=answer) as git, \
                 patch.object(stack, 'command') as command:
                with self.assertRaisesRegex(ValueError, 'dirty'):
                    stack.restack('/repo', 'owner/repo', 2, 1, B,
                        {'force_with_lease': True, 'base': 'main', 'stacking': 'allowed'}, tmp)
                self.assertFalse(any(call.args[1] == 'push' for call in git.call_args_list))
                command.assert_not_called()

    def test_last_dependent_release_obeys_policy(self):
        with patch.object(stack, 'deletable', return_value=False), patch.object(stack, 'git') as git:
            stack.release_parent('/repo', 'owner/repo', 't-1-parent', A,
                                 {'delete_branch': True, 'base': 'main'})
            git.assert_not_called()
        with patch.object(stack, 'deletable', return_value=True), patch.object(stack, 'git') as git:
            stack.release_parent('/repo', 'owner/repo', 't-1-parent', A,
                                 {'delete_branch': False, 'base': 'main'})
            git.assert_not_called()

    def test_last_dependent_release_uses_parent_lease(self):
        with patch.object(stack, 'deletable', return_value=True), \
             patch.object(stack, 'github', return_value={'protected': False}), \
             patch.object(stack, 'git', return_value='') as git:
            stack.release_parent('/repo', 'owner/repo', 't-1-parent', A,
                                 {'delete_branch': True, 'base': 'main'})
            git.assert_any_call('/repo', 'push', '--force-with-lease=refs/heads/t-1-parent:' + A,
                                'https://github.com/owner/repo.git', ':refs/heads/t-1-parent')
            git.assert_any_call('/repo', 'update-ref', '-d', 'refs/heads/t-1-parent', A)

    def test_unknown_parent_protection_retains_branch(self):
        with patch.object(stack, 'deletable', return_value=True), \
             patch.object(stack, 'github', return_value={}), \
             patch.object(stack, 'git') as git:
            with self.assertRaisesRegex(ValueError, 'protection'):
                stack.release_parent('/repo', 'owner/repo', 't-1-parent', A,
                                     {'delete_branch': True, 'base': 'main'})
            git.assert_not_called()


if __name__ == '__main__':
    unittest.main()
