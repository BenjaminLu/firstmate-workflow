"""Restack boundaries and real git diagnostics for the stacking suite."""
from contextlib import contextmanager, ExitStack
from pathlib import Path
import os
import subprocess
import tempfile
from unittest.mock import patch
import fm_stack as stack

A, B, C, D = (letter * 40 for letter in 'abcd')


@contextmanager
def restack_fixture(*, local=B, remote_error=None, git_errors=None, retarget_error=None,
                    rebase_stderr=None, moved=False, adopted=False, retargeted=False, pinned=True,
                    fetched=B, wrong_parent=False, lost_head=False, parent_adopted=False, identity=None, changed_identity=None):
    child = dict(state='OPEN', headRefName='t-2-child', baseRefName='t-1-parent',
                 headRefOid=B, baseRefOid=A, title='Human change', isCrossRepository=False)
    parent = dict(state='MERGED', headRefName='t-1-parent', headRefOid=A, baseRefName='main', isCrossRepository=False)
    if adopted:
        child['headRefName'] = 'human-child'
        parent['headRefName'] = 'human-parent'
        child['baseRefName'] = 'main' if retargeted else 'human-parent'
    child.update(identity or {})
    if identity and identity.get('isCrossRepository') == 'missing':
        child.pop('isCrossRepository')
    final = dict(child, headRefOid=C, baseRefName='main', baseRefOid=D)
    def git_answer(root, *args):
        for prefix, error in (git_errors or {}).items():
            if args[:len(prefix)] == prefix: raise error
        if args == ('rev-parse', 'refs/heads/' + child['headRefName']):
            if isinstance(local, Exception): raise local
            return local
        if args[:2] == ('merge-base', '--is-ancestor') and lost_head:
            raise ValueError('not an ancestor')
        if args == ('merge-base', A, B): return A
        if args == ('rev-parse', 'HEAD'): return C
        return ''
    real_run = subprocess.run
    def rebase(argv, **kwargs):
        if argv[0] == 'bash': return real_run(argv, **kwargs)
        assert argv[:2] == ['git', '-C']
        assert argv[3:] == ['-c', 'core.hooksPath=/dev/null', 'rebase', '--onto', D, A]
        assert kwargs == dict(stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
        return subprocess.CompletedProcess(argv, int(rebase_stderr is not None), '', rebase_stderr or '')
    with tempfile.TemporaryDirectory() as tmp, ExitStack() as context:
        import fm_adopt
        owners = {2: 'T-002'} if adopted else {}
        if parent_adopted: owners[1] = 'T-001'
        context.enter_context(patch.object(fm_adopt, 'scan', return_value=(owners, {}, {})))
        context.enter_context(patch.object(fm_adopt, 'pinned_adoption', create=True, side_effect=lambda env, task:
            dict(pr=2 if task == 'T-002' else 1, head=B, base='wrong' if wrong_parent else 'human-parent') if pinned else None))
        context.enter_context(patch.object(fm_adopt, 'event_rows', create=True, return_value=[]))
        context.enter_context(patch.object(stack, 'remote_head', side_effect=(
            [remote_error or final] if adopted else
            [child, dict(child, headRefOid=C) if moved else child, remote_error or final])))
        views = iter([child, dict(child, **(changed_identity or {})), final])
        def github_answer(repository, *args):
            if args[:3] == ('pr', 'view', '2'):
                fields = args[args.index('--json') + 1].split(',')
                view = next(views)
                return {key: view[key] for key in fields if key in view}
            if args[0] == 'pr': return parent
            return {'protected': False}
        context.enter_context(patch.object(stack, 'github', side_effect=github_answer))
        context.enter_context(patch.dict(os.environ, FM_EXTERNAL='1'))
        context.enter_context(patch.object(fm_adopt, 'authorized_spec', return_value={'depends_on': ['T-001']}))
        context.enter_context(patch.object(fm_adopt, 'task_of', return_value='T-001'))
        context.enter_context(patch.object(stack, 'fetch_ref', side_effect=([fetched] if adopted and isinstance(local, Exception) else []) + [D, A]))
        git = context.enter_context(patch.object(stack, 'git', side_effect=git_answer))
        command = context.enter_context(patch.object(stack, 'command', side_effect=retarget_error))
        context.enter_context(patch.object(stack.subprocess, 'run', side_effect=rebase))
        def run():
            return stack.restack('/repo', 'owner/repo', 2, 1, B,
                dict(force_with_lease=True, stacking='allowed', base='main'), tmp)
        yield run, git, command, Path(tmp)


def record_conflict_stderr():
    """Record a genuine conflict, with a subject beyond binding's 500-byte cap."""
    with tempfile.TemporaryDirectory() as tmp:
        env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                   GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
                   GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid',
                   LC_ALL='C', GIT_TERMINAL_PROMPT='0')
        def git(*args, check=True):
            return subprocess.run(['git', '-C', tmp, '-c', 'core.hooksPath=/dev/null', *args],
                                  env=env, capture_output=True, text=True, check=check, timeout=30)
        git('init')
        file = Path(tmp) / 'conflict.txt'
        file.write_text('base\n'); git('add', '.'); git('commit', '-m', 'base')
        boundary = git('rev-parse', 'HEAD').stdout.strip()
        file.write_text('child\n'); git('commit', '-am', 'child subject ' + 'long subject ' * 80)
        child = git('rev-parse', 'HEAD').stdout.strip()
        git('checkout', '--detach', boundary)
        file.write_text('target\n'); git('commit', '-am', 'target')
        target = git('rev-parse', 'HEAD').stdout.strip()
        git('checkout', '--detach', child)
        result = git('rebase', '--onto', target, boundary, check=False)
        assert result.returncode != 0
        return result.stderr
