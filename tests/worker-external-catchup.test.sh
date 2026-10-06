#!/usr/bin/env bash
# T-223: external rebuilds use confirmed policy and the bound PR-head lease.
# Shared executable-block harness: tests/lib/crew_blocks.py
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
python3 - "$ROOT" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
sys.dont_write_bytecode = True
root = Path(sys.argv[1])
sys.path.insert(0, str(root / 'tests/lib'))
sys.path.insert(0, str(root / 'bin/lib'))
from crew_blocks import function, section, shell
worker = root / 'bin/fm-worker.sh'


class Rebuild(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name).resolve()
        self.tree = self.home / 'tree'
        self.remote = self.home / 'origin.git'
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('GIT_', 'FM_', 'HERDR_'))}
        self.git('init', '--bare', str(self.remote), cwd=self.home)
        self.git('init', '-b', 'main', str(self.tree), cwd=self.home)
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.invalid')
        self.git('config', 'commit.gpgSign', 'false')
        self.git('remote', 'add', 'origin', str(self.remote))
        (self.tree / 'app').write_text('original\n')
        self.commit('initial')
        self.initial = self.head()
        self.git('checkout', '-b', 'task')
        (self.tree / 'app').write_text('task intent\n')
        self.commit('task')
        self.prev = self.head()
        self.git('push', 'origin', 'main', 'task')

    def git(self, *args, cwd=None, check=True):
        p = subprocess.run(['git', *args], cwd=cwd or self.tree, env=self.env,
                           capture_output=True, text=True, timeout=15)
        if check:
            self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout.strip()

    def head(self, ref='HEAD'):
        return self.git('rev-parse', ref)

    def commit(self, message):
        self.git('add', '-A')
        self.git('commit', '-qm', message)

    def base_moves(self, kind='clean'):
        self.git('checkout', 'main')
        if kind == 'conflict':
            (self.tree / 'app').write_text('base intent\n')
        else:
            (self.tree / 'base-only').write_text('base addition\n')
        self.commit('base moved')
        self.base = self.head()
        self.git('push', 'origin', 'main')
        self.git('checkout', 'task')

    def definitions(self):
        return ''.join(function(worker, name) for name in (
            'rebuild_state_of', 'rebuild_side_left', 'rebuild_fingerprint',
            'rebuild_unmerged', 'rebuild_lost', 'rebuild_own_file_restore',
            'rebuild_rebases', 'rebuild_probe_drop', 'bring_up_to_date',
            'rebuild_settle', 'worker_changed_files', 'rebuild_unresolved',
            'rebuild_publishes'))

    def run_body(self, body, prefix=''):
        setup = r'''
cd "$tree" || exit 1
FM_TARGET_ROOT="$tree"; FM_WORKTREES="$work"; worker_tmp="$work"
rebuilt=0; rebuild_base=; rebuild_prev=; rebuild_lease=; rebuild_entry=; rebuild_probe=
rebuild_mark=; rebuild_conflicts=(); rebuild_restore=(); rebuild_bare=()
rebuild_bare_left=(); rebuild_bare_side=(); pin_synced=0; spec_copied=0
pinned_path=; pinned_ready=0; held=; refused=0
bound_head="$(git rev-parse task)"; round_start="$bound_head"
fm_stack_policy() { echo true; }
fm_publication_policy() { return "${policy_rc:-0}"; }
fm_private_stage() { :; }
fm_task() { echo forbidden-private-task-read >&2; exit 99; }
fm_git_name() { echo Test; }; fm_git_email() { echo test@example.invalid; }
first_round_question() { return 1; }
git() { printf '%s\n' "$*" >> "$work/gitcalls"; command git "$@"; }
'''
        return shell(root, self.home, self.definitions() + '\n' + body, setup + prefix)

    def check_ok(self, p):
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

    def precommit(self):
        return section(worker, 'rebuild_refuse() {', '# A script the round adds')

    def commit_block(self):
        return section(worker, 'commit_msg="$TASK:', '_fm_wip_done=1\nif [ "$rebuilt" = 1 ]; then')

    def publication(self):
        return section(worker, '_fm_wip_done=1\nif [ "$rebuilt" = 1 ]; then', '# Only now: a push')

    def resolve(self):
        return 'printf "task intent and base intent\\n" > "$tree/app"\n'

    def remote_head(self):
        return self.git('--git-dir=' + str(self.remote), 'rev-parse', 'task')

    def test_conflicting_rebuild_publishes_single_commit_with_bound_lease(self):
        self.base_moves('conflict')
        p = self.run_body('bring_up_to_date\n' + self.resolve() + self.precommit() +
                          self.commit_block() + self.publication())
        self.check_ok(p)
        self.assertEqual(self.git('show', '-s', '--format=%P'), self.base)
        self.assertEqual(self.remote_head(), self.head())
        self.assertEqual(self.git('rev-list', '--count', 'main..task'), '1')
        self.assertIn('--force-with-lease=refs/heads/task:' + self.prev,
                      (self.home / 'gitcalls').read_text())

    def test_false_policy_holds_branch(self):
        self.base_moves('conflict')
        p = self.run_body('bring_up_to_date', 'fm_stack_policy() { echo false; }\n')
        self.check_ok(p)
        self.assertIn('conventions do not allow force_with_lease', p.stderr)
        self.assertEqual(self.head(), self.prev)
        self.assertEqual(self.remote_head(), self.prev)
        self.assertFalse((self.home / 'gitcalls').exists())

    def test_unreadable_policy_holds_even_if_reader_prints_true(self):
        self.base_moves('conflict')
        p = self.run_body('bring_up_to_date', 'fm_stack_policy() { echo true; return 1; }\n')
        self.check_ok(p)
        self.assertIn('conventions do not allow force_with_lease', p.stderr)
        self.assertEqual(self.head(), self.prev)
        self.assertEqual(self.remote_head(), self.prev)
        self.assertFalse((self.home / 'gitcalls').exists())

    def test_remote_moved_after_binding_holds_branch(self):
        self.base_moves('conflict')
        self.git('push', '--force', 'origin', 'main:task')
        p = self.run_body('bring_up_to_date')
        self.check_ok(p)
        self.assertIn('not the head this round was bound to', p.stderr)
        self.assertEqual(self.head(), self.prev)
        self.assertEqual(self.remote_head(), self.base)
        self.assertNotIn('--force-with-lease', (self.home / 'gitcalls').read_text())

    def test_lease_refusal_preserves_remote_and_previous_local_branch(self):
        self.base_moves('conflict')
        p = self.run_body('bring_up_to_date\n' + self.resolve() + self.precommit() +
                          self.commit_block() + r'''
command git --git-dir="$work/origin.git" update-ref refs/heads/task "$rebuild_base"
''' + self.publication())
        self.assertEqual(p.returncode, 71, p.stdout + p.stderr)
        self.assertEqual(self.remote_head(), self.base)
        self.assertEqual(self.head('task'), self.prev)
        self.assertEqual(self.git('rev-parse', '-q', '--verify', 'refs/fm-rebuilt/task', check=False), '')

    def test_publication_rechecks_policy_and_bound_head(self):
        self.base_moves('conflict')
        # Each refusal starts from a newly rebuilt tree and leaves origin alone.
        for change in ('fm_stack_policy() { echo false; }',
                       'fm_stack_policy() { echo true; return 1; }',
                       'rebuild_lease=', 'bound_head=wrong', 'policy_rc=65'):
            with self.subTest(change=change):
                self.git('checkout', '-f', 'task')
                p = self.run_body('bring_up_to_date\n' + self.resolve() + self.precommit() +
                    self.commit_block() + change + '\n' + self.publication())
                self.assertEqual(p.returncode, 65, p.stdout + p.stderr)
                self.assertEqual(self.remote_head(), self.prev)
                self.assertEqual(self.head('task'), self.prev)
                if change.startswith('fm_stack_policy'):
                    self.assertIn('conventions do not allow force_with_lease', p.stderr)
                elif change != 'policy_rc=65':
                    self.assertIn('not the head the round was bound to', p.stderr)
        self.assertNotIn('--force-with-lease', (self.home / 'gitcalls').read_text())

    def test_clean_rebase_is_not_rewritten(self):
        self.base_moves()
        p = self.run_body('bring_up_to_date')
        self.check_ok(p)
        self.assertEqual(self.head(), self.prev)
        self.assertEqual(self.remote_head(), self.prev)
        self.assertNotIn('--force-with-lease', (self.home / 'gitcalls').read_text())

    def test_no_open_pr_is_not_rebuilt(self):
        self.base_moves('conflict')
        p = self.run_body('bring_up_to_date', 'PR=\n')
        self.check_ok(p)
        self.assertIn('no open PR', p.stderr)
        self.assertEqual(self.head(), self.prev)

    def test_merge_catchup_is_removed_from_bin(self):
        p = subprocess.run(['git', 'grep', '-nE',
            'merge --no-ff|commit_parents|fm-caughtup|caught_up|catchup', '--', 'bin'],
            cwd=root, capture_output=True, text=True)
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)

    def test_detached_publication_rejects_all_protected_names(self):
        self.git('checkout', '--detach', self.prev)
        for branch in ('main', 'master', 'release', 'HEAD'):
            with self.subTest(branch=branch):
                p = self.run_body(function(root / 'bin/fm-config.sh', 'fm_publication_policy') +
                    '\nfm_publication_policy "$tree" ' + branch,
                    'FM_BASE=release; fm_conventions() { :; }; fm_target_validate() { :; }\n')
                self.assertEqual(p.returncode, 65, p.stderr)
                self.assertIn('protected-base publication refused', p.stderr)

    def test_dirty_rebuild_exit_publishes_nothing(self):
        self.base_moves('conflict')
        p = self.run_body('bring_up_to_date\n' +
            function(root / 'bin/fm-config.sh', 'fm_publication_policy') +
            function(worker, 'publish_wip_if_dirty') +
            '\n_fm_wip_done=0; publish_wip_if_dirty interrupted',
            'fm_conventions() { :; }; fm_target_validate() { :; }\n')
        self.check_ok(p)
        self.assertIn('was not committed (interrupted); nothing is published', p.stderr)
        self.assertEqual(self.remote_head(), self.prev)
        self.assertNotIn(' push ', (self.home / 'gitcalls').read_text())

    def test_failed_private_rebuild_note_still_projects_pushed_head(self):
        self.base_moves('conflict')
        post_push = section(worker, '# The reviewer reads the pull request,',
                            '# the note refused above still requires')
        for failure in ('fm_private_note() { return 1; }',
                        'scratch_new() { return 1; }',
                        'scratch_new() { echo "$work/missing/note"; }'):
            with self.subTest(failure=failure):
                self.git('checkout', '-f', 'task')
                p = self.run_body('bring_up_to_date\n' + self.resolve() +
                    self.precommit() + self.commit_block() + self.publication() +
                    failure + '\n' + post_push + '\necho completed', r'''
num=9; projection=summary
fm_private_note() { echo unexpected-retention; return 0; }
fm_external() { printf 'projection %s\n' "$*"; }
fm_github() { echo forbidden-public-note; return 1; }
''')
                self.check_ok(p)
                self.assertIn('could not retain the private rebuild note', p.stderr)
                self.assertEqual(self.remote_head(), self.head())
                self.assertEqual(self.git('show', '-s', '--format=%P'), self.base)
                self.assertEqual(p.stdout.count('projection project --pr 9 --head ' +
                                               self.head() + ' --stage worker'), 1)
                self.assertIn('completed', p.stdout)
                self.assertNotIn('forbidden-public-note', p.stdout)
                self.assertNotIn('unexpected-retention', p.stdout)
                # Start the next failure case from the same conflicting task head.
                self.git('reset', '--hard', self.prev)
                self.git('push', '--force', 'origin', 'task')

    def test_rebuilt_note_does_not_project_before_push(self):
        self.base_moves('conflict')
        p = self.run_body('bring_up_to_date\n' + function(worker, 'post_note') + r'''
projection=summary; fm_private_note() { :; }
worker_changed_files() { return 1; }
fm_external() { echo early-projection; }
post_note "$work/note" 9
''')
        self.check_ok(p)
        self.assertNotIn('early-projection', p.stdout)


unittest.main(argv=['worker-external-rebuild'])
PY
assert_eq 0 "$?" "external rebuild block regressions"
# Shared full-launcher fixture: tests/lib/external_rebuild.py
# Registry dependency: tests/lib/external_registry.py
python3 "$ROOT/tests/lib/external_rebuild.py" "$ROOT"
assert_eq 0 "$?" "external rebuild launcher and private evidence"
finish
