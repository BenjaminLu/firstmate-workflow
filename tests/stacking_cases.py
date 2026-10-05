"""Feature-owned tests; no network or background processes."""
import unittest
import subprocess
import tempfile
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from stacking_fixture import restack_fixture, record_conflict_stderr
from unittest.mock import patch
import fm_stack as stack
import fm_binding as binding

A = 'a' * 40
B = 'b' * 40


class Stacking(unittest.TestCase):
    def test_local_gate_without_origin_uses_project_base(self):
        with patch.object(binding, 'repository', side_effect=ValueError('no origin')), \
             patch.object(binding, 'remote_head') as remote:
            self.assertEqual(binding.local_gate_base('/repo', 9, 'trunk'), 'trunk')
            remote.assert_not_called()

    def test_local_gate_without_remote_pr_uses_project_base(self):
        with patch.object(binding, 'repository', return_value='owner/repo'), \
             patch.object(binding, 'remote_head', side_effect=ValueError('no PR')):
            self.assertEqual(binding.local_gate_base('/repo', 9, 'main'), 'main')

    def test_local_gate_unstacked_base_needs_no_remote_sha_check(self):
        with patch.object(binding, 'repository', return_value='owner/repo'), \
             patch.object(binding, 'remote_head', return_value={'baseRefName': 'main'}), \
             patch.object(binding, 'git') as git:
            self.assertEqual(binding.local_gate_base('/repo', 9, 'main'), 'main')
            git.assert_not_called()

    def test_local_gate_stacked_base_still_refuses_stale_ref(self):
        with patch.object(binding, 'repository', return_value='owner/repo'), \
             patch.object(binding, 'remote_head', return_value={
                 'baseRefName': 'parent', 'baseRefOid': A}), \
             patch.object(binding, 'fetch_ref', return_value=A), \
             patch.object(binding, 'git', return_value=B), \
             patch.dict('os.environ', {'FM_TARGET_ROOT': '/repo'}):
            with self.assertRaisesRegex(ValueError, 'local base is stale; synchronize'):
                binding.local_gate_base('/repo', 9, 'main')

    def test_storage_setup_preserves_installed_binding(self):
        import os
        import subprocess
        import tempfile
        from pathlib import Path
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run(['bash', '-c',
                '. "$ROOT/tests/lib/project-storage.sh"; '
                'project_storage_fixture "$1/bin"; '
                'printf fixture-reader > "$1/bin/lib/fm_binding.py"; '
                'project_storage_fixture "$1/bin"; '
                'cat "$1/bin/lib/fm_binding.py"', '_', tmp],
                env=dict(os.environ, ROOT=str(root)), capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'fixture-reader')

    def test_external_checks_without_exported_base_use_project_default(self):
        import os
        view = dict(headRefOid=B, baseRefName='t-1-parent', baseRefOid=A)
        runs = {'check_runs': [dict(id=1, name='ci', head_sha=B,
                                   status='completed', conclusion='success')]}
        with patch.dict(os.environ, {'FM_EXTERNAL': '1', 'FM_STATE_DIR': '/project/state'}, clear=True), \
             patch('fm_conventions.read_policy', return_value={
                 'required_checks': ['ci'], 'base': 'main', 'stacking': 'allowed'}) as policy, \
             patch.object(binding, 'remote_head', return_value=view), \
             patch.object(binding, 'git', return_value=A), \
             patch.object(binding, 'fetch_ref', return_value=A) as fetch, \
             patch.object(binding, 'github', side_effect=[
                 {'contexts': ['ci'], 'checks': []}, runs, {'sha': B, 'statuses': []}]) as github:
            self.assertEqual(len(binding.required_checks('/repo', 'owner/repo', 2, B)), 1)
            self.assertEqual(policy.call_args.args[2], 'main')
            fetch.assert_called_once_with('/repo', 'https://github.com/owner/repo.git',
                                          'refs/heads/t-1-parent')
            self.assertEqual(github.call_args_list[0].args, ('owner/repo', 'api',
                'repos/owner/repo/branches/t-1-parent/protection/required_status_checks'))

    def test_external_stacked_checks_with_hold_are_unknown(self):
        import os
        view = dict(headRefOid=B, baseRefName='t-1-parent', baseRefOid=A)
        with patch.dict(os.environ, {'FM_EXTERNAL': '1', 'FM_STATE_DIR': '/project/state'}, clear=True), \
             patch('fm_conventions.read_policy', return_value={
                 'required_checks': ['ci'], 'base': 'main', 'stacking': 'hold'}) as policy, \
             patch.object(binding, 'remote_head', return_value=view), \
             patch.object(binding, 'git', return_value=A), \
             patch.object(binding, 'fetch_ref', return_value=A) as fetch, \
             patch.object(binding, 'github') as github:
            with self.assertRaisesRegex(ValueError, 'unknown: stacked PR base requires confirmed stacking policy'):
                binding.required_checks('/repo', 'owner/repo', 2, B)
            self.assertEqual(policy.call_args.args[2], 'main')
            fetch.assert_called_once_with('/repo', 'https://github.com/owner/repo.git',
                                          'refs/heads/t-1-parent')
            github.assert_not_called()

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
        with patch.object(binding, 'remote_head', return_value=view), \
             patch.object(binding, 'fetch_ref', return_value=A), \
             patch.object(binding, 'git', return_value=A), \
             patch.dict('os.environ', {'FM_TARGET_ROOT': '/repo'}):
            self.assertEqual(binding.view_base('owner/repo', 2), 't-1-parent')
        with patch.object(binding, 'remote_head', return_value=view), \
             patch.object(binding, 'fetch_ref', return_value=A), \
             patch.object(binding, 'git', return_value=B), \
             patch.dict('os.environ', {'FM_TARGET_ROOT': '/repo'}):
            with self.assertRaises(ValueError):
                binding.view_base('owner/repo', 2)

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
            if args == ('merge-base', A, B): return A
            if args == ('rev-parse', 'HEAD'): return new
            return ''
        final = dict(child, headRefOid=new, baseRefName='main', baseRefOid=base)
        import tempfile
        with tempfile.TemporaryDirectory() as tmp, \
             patch.object(stack, 'remote_head', side_effect=[child, child, final]), \
             patch.object(stack, 'github', side_effect=[parent, {'protected': False}]), \
             patch.object(stack, 'fetch_ref', side_effect=[base, A]) as fetch, \
             patch.object(stack, 'git', side_effect=git_answer) as git, \
             patch.object(stack.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '', '')) as rebase, \
             patch.object(stack, 'command') as command:
            result = stack.restack('/repo', 'owner/repo', 2, 1, B,
                {'force_with_lease': True, 'base': 'main', 'stacking': 'allowed', 'delete_branch': False}, tmp)
            self.assertEqual(result['head'], new)
            self.assertEqual([c.args for c in fetch.call_args_list], [
                ('/repo', 'https://github.com/owner/repo.git', 'refs/heads/main'),
                ('/repo', 'https://github.com/owner/repo.git', 'refs/pull/1/head')])
            calls = [call.args[1:] for call in git.call_args_list]
            tree = next(c.args[4] for c in git.call_args_list if c.args[1:3] == ('worktree', 'add'))
            rebase.assert_called_once_with(['git', '-C', tree, '-c', 'core.hooksPath=/dev/null',
                'rebase', '--onto', base, A], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
            self.assertEqual(list(Path(tmp).glob('restack-*')), [])
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
            def answer(root, *args):
                if args == ('rev-parse', 'refs/heads/t-2-child'): return B
                if args == ('merge-base', A, B): return A
                if args == ('rev-parse', 'HEAD'): return 'c' * 40
                if args == ('worktree', 'list', '--porcelain'):
                    return 'worktree ' + tmp + '/T-2\nbranch refs/heads/t-2-child\n'
                if args == ('status', '--porcelain'): return ' M valuable.txt'
                return ''
            with patch.dict(os.environ, {'FM_WORKTREES': tmp}), \
                 patch.object(stack, 'remote_head', return_value=child), \
                 patch.object(stack, 'github', side_effect=[parent, {'protected': False}]), \
                 patch.object(stack, 'fetch_ref', side_effect=['d' * 40, A]), \
                 patch.object(stack, 'git', side_effect=answer) as git, \
                 patch.object(stack.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '', '')), \
                 patch.object(stack, 'command') as command:
                with self.assertRaisesRegex(ValueError, 'dirty'):
                    stack.restack('/repo', 'owner/repo', 2, 1, B,
                        {'force_with_lease': True, 'base': 'main', 'stacking': 'allowed'}, tmp)
                self.assertFalse(any(call.args[1] == 'push' for call in git.call_args_list))
                command.assert_not_called()

    def test_restack_remote_move_precedes_local_ref_read(self):
        child = dict(headRefName='t-2-child', headRefOid='c' * 40)
        with patch.object(stack, 'remote_head', return_value=child), patch.object(stack, 'git') as git:
            with self.assertRaisesRegex(stack.RestackMoved, 'task head changed on GitHub') as caught:
                stack.restack('/repo', 'owner/repo', 2, 1, B,
                              dict(base='main', stacking='allowed', force_with_lease=True), '/unused')
            self.assertIsInstance(caught.exception, ValueError)
            self.assertFalse(any(c.args[1] == 'rev-parse' for c in git.call_args_list))

    def test_restack_stale_and_missing_local_refs(self):
        for local in ('d' * 40, ValueError('unknown revision')):
            with self.subTest(local=local), restack_fixture(local=local) as (run, git, command, scratch):
                with self.assertRaisesRegex(stack.RestackStaleLocal, 'local task ref is not the expected head') as caught:
                    run()
                self.assertIsInstance(caught.exception, ValueError)
                command.assert_not_called()

    def test_restack_conflict_preserves_full_real_stderr_tail(self):
        stderr = record_conflict_stderr()
        self.assertGreater(len(stderr.encode()), 500)
        last = next(line for line in reversed(stderr.splitlines()) if line.strip())
        self.assertTrue(last.startswith('Could not apply '), stderr)
        with restack_fixture(rebase_stderr=stderr) as (run, git, command, scratch):
            with self.assertRaises(stack.RestackConflict) as caught: run()
            self.assertIsInstance(caught.exception, ValueError)
            self.assertEqual(str(caught.exception), 'rebase conflict restacking onto main: ' + last)
            self.assertFalse(any(c.args[1] == 'push' for c in git.call_args_list))
            self.assertEqual(list(scratch.glob('restack-*')), [])
            command.assert_not_called()

    def test_restack_add_failure_removes_temporary_directory(self):
        with restack_fixture(git_errors={('worktree', 'add'): ValueError('cannot add')}) as (run, git, command, scratch):
            with self.assertRaisesRegex(ValueError, 'cannot add') as caught: run()
            self.assertIs(type(caught.exception), ValueError)
            self.assertEqual(list(scratch.glob('restack-*')), [])

    def test_restack_inflight_move_is_distinct_and_never_pushes(self):
        with restack_fixture(moved=True) as (run, git, command, scratch):
            with self.assertRaisesRegex(stack.RestackMoved, 'child moved during restack; nothing published') as caught:
                run()
            self.assertIsInstance(caught.exception, ValueError)
            self.assertFalse(any(c.args[1] == 'push' for c in git.call_args_list))

    def test_restack_push_failure_is_unknown_even_when_cleanup_fails(self):
        for error in (ValueError("error: failed to push some refs to 'https://github.com/owner/repo.git'"),
                      subprocess.TimeoutExpired('git push', 120), OSError('connection lost')):
            for cleanup in (False, True):
                with self.subTest(error=error, cleanup=cleanup):
                    errors = {('push',): error}
                    if cleanup: errors[('worktree', 'remove')] = ValueError('cleanup failed')
                    with restack_fixture(git_errors=errors) as (run, git, command, scratch):
                        with self.assertRaises(stack.RestackPushUnknown) as caught: run()
                        self.assertIsInstance(caught.exception, ValueError)
                        self.assertIn('push outcome unknown for t-2-child (expected old head ' + B + ')', str(caught.exception))
                        self.assertIn(str(error), str(caught.exception))
                        if cleanup: self.assertIn('cleanup failed', str(caught.exception))
                        command.assert_not_called()
                        self.assertEqual(list(scratch.glob('restack-*')), [])

    def test_restack_postpublication_errors_keep_published_head(self):
        cases = [dict(retarget_error=ValueError('retarget failed')),
                 dict(retarget_error=subprocess.TimeoutExpired('gh pr edit', 120)),
                 dict(remote_error=KeyError('headRefOid')),
                 dict(git_errors={('update-ref',): OSError('local ref failed')}),
                 dict(git_errors={('fetch',): subprocess.TimeoutExpired('git fetch', 120)})]
        for options in cases:
            for cleanup in (False, True):
                with self.subTest(options=options, cleanup=cleanup):
                    args = dict(options)
                    args['git_errors'] = dict(args.get('git_errors', {}))
                    if cleanup: args['git_errors'][('worktree', 'remove')] = ValueError('cleanup failed')
                    with restack_fixture(**args) as (run, git, command, scratch):
                        with self.assertRaises(stack.RestackPublished) as caught: run()
                        self.assertIsInstance(caught.exception, ValueError)
                        self.assertIn('task head published as ' + 'c' * 40, str(caught.exception))
                        if cleanup: self.assertIn('cleanup failed', str(caught.exception))
                        self.assertEqual(list(scratch.glob('restack-*')), [])

    def test_restack_success_reports_cleanup_failure(self):
        with restack_fixture(git_errors={('worktree', 'remove'): ValueError('cleanup failed')}) as (run, git, command, scratch):
            result = run()
            self.assertEqual(result['head'], 'c' * 40)
            self.assertEqual(result['tree_cleanup'], 'cleanup failed')
            self.assertEqual(list(scratch.glob('restack-*')), [])

    def test_restack_result_output_failure_exits_published(self):
        import io
        with tempfile.TemporaryDirectory() as tmp, \
             patch.dict('os.environ', dict(FM_TARGET_ROOT=tmp, FM_STACK_REPOSITORY='owner/repo',
                                          FM_STATE_DIR=tmp, FM_EXTERNAL='1')), \
             patch('fm_conventions.read_policy', return_value=dict(base='main', stacking='allowed', force_with_lease=True)), \
             patch('fm_binding.remote_head', return_value=dict(headRefName='t-2-child')), \
             patch.object(sys, 'argv', ['fm_stack.py', 'restack', '--pr', '2', '--parent', '1', '--expected-head', B]), \
             patch.object(sys, 'stderr', new_callable=io.StringIO) as stderr:
            # Replace restack after module definitions, before its entrypoint runs.
            source = Path(stack.__file__).read_text()
            source = source.replace("if __name__ == '__main__':", "restack = lambda *args: {'head': 'published'}\nif __name__ == '__main__':")
            original_print = print
            def output(*args, **kwargs):
                if kwargs.get('file') is sys.stderr: return original_print(*args, **kwargs)
                raise OSError('output closed')
            with patch('builtins.print', side_effect=output):
                with self.assertRaises(SystemExit) as caught:
                    exec(compile(source, stack.__file__, 'exec'), {'__name__': '__main__'})
            self.assertEqual(caught.exception.code, 69)
            self.assertIn('fm-stack: restack published; result output failed: output closed', stderr.getvalue())

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
    import sys
    if sys.argv[1:] == ['--list']:
        for name in unittest.defaultTestLoader.getTestCaseNames(Stacking):
            print('Stacking.' + name)
    else:
        unittest.main(verbosity=2)
