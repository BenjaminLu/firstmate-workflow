#!/usr/bin/env bash
# T-223: external catch-up keeps published history and recovers interrupted merges.
# Shared executable-block harness: tests/lib/crew_blocks.py
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import shlex
import sys
import tempfile
import unittest
sys.dont_write_bytecode = True
root = Path(sys.argv[1])
sys.path.insert(0, str(root / 'tests/lib'))
sys.path.insert(0, str(root / 'bin/lib'))
from crew_blocks import function, section, shell
from fm_onboard import infer, approve
worker = root / 'bin/fm-worker.sh'


class Catchup(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
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
        elif kind == 'delete':
            (self.tree / 'app').unlink()
        elif kind == 'literal':
            (self.tree / 'base-only').write_text('<<<<<<< literal example\n')
        else:
            (self.tree / 'base-only').write_text('base addition\n')
        self.commit('base moved')
        self.base = self.head()
        self.git('push', 'origin', 'main')
        self.git('checkout', 'task')

    def policy(self, method):
        evidence = dict(repository='owner/app', base='main', source='github', pulls=[], commits=[],
            protection={'status': 'unknown'}, repository_info={
                'allow_squash_merge': method == 'squash', 'allow_merge_commit': method == 'merge',
                'allow_rebase_merge': method == 'rebase', 'delete_branch_on_merge': False})
        approve(self.home, evidence, infer(evidence), dict(confirmed=True, policy_confirmed=True,
            captain='captain', intent='Catch up branches', product='Fixture', required_checks=['ci'],
            contract={'check': 'true'}, review='fm', post='local', merge_method=method))
        return '. "$1/bin/lib/fm-stack.sh"\n'

    def definitions(self):
        return ''.join(function(worker, name) for name in (
            'rebuild_state_of', 'rebuild_side_left', 'rebuild_fingerprint',
            'rebuild_collect_conflicts', 'external_catch_up', 'catchup_settle',
            'worker_changed_files', 'rebuild_unresolved', 'rebuild_publishes'))

    def run_body(self, body, prefix=''):
        setup = '''
cd "$tree" || exit 1
FM_TARGET_ROOT="$tree"; rebuilt=0; caught_up=0; rebuild_base=; rebuild_prev=
rebuild_mark=; rebuild_conflicts=(); rebuild_restore=(); rebuild_bare=()
rebuild_bare_left=(); rebuild_bare_side=(); pin_synced=0; spec_copied=0
bound_head="$(git rev-parse task)"; round_start="$bound_head"
fm_stack_policy() { echo "${method:-squash}"; }
fm_publication_policy() { return "${policy_rc:-0}"; }
fm_private_stage() { :; }
fm_task() { echo forbidden-private-task-read >&2; exit 99; }
fm_git_name() { echo Test; }; fm_git_email() { echo test@example.invalid; }
first_round_question() { return 1; }
git() { printf '%s\\n' "$*" >> "$work/gitcalls"; command git "$@"; }
'''
        return shell(root, self.home, self.definitions() + '\n' + body, setup + prefix)

    def assert_ok(self, p):
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

    def precommit(self):
        return section(worker, 'rebuild_refuse() {', '# A script the round adds')

    def commit_block(self):
        return section(worker, 'commit_msg="$TASK:', '_fm_wip_done=1\nif [ "$rebuilt" = 1 ]; then')

    def publication(self):
        return section(worker, '_fm_wip_done=1\nif [ "$rebuilt" = 1 ]; then', '# Only now: a push')

    def resolve(self):
        return 'printf "task intent and base intent\\n" > "$tree/app"\n'

    def test_clean_merge_keeps_bound_attached_head_and_no_rewrite(self):
        self.base_moves()
        p = self.run_body('external_catch_up\nprintf "conflicts=%s\\n" "${#rebuild_conflicts[@]}"')
        self.assert_ok(p)
        self.assertEqual(self.head('MERGE_HEAD'), self.base)
        self.assertEqual(self.head(), self.prev)
        self.assertEqual(self.git('symbolic-ref', '--short', 'HEAD'), 'task')
        self.assertIn('conflicts=0', p.stdout)
        calls = (self.home / 'gitcalls').read_text()
        for prohibited in (' rebase ', ' reset ', 'checkout --detach', ' push ', '--squash', '--force'):
            self.assertNotIn(prohibited, calls)

    def test_conflicting_file_is_named_and_has_markers(self):
        self.base_moves('conflict')
        p = self.run_body('external_catch_up\nprintf "conflict=%s\\n" "${rebuild_conflicts[@]}"')
        self.assert_ok(p)
        self.assertIn('conflict=app', p.stdout)
        self.assertIn('<<<<<<<', (self.tree / 'app').read_text())

    def test_remote_lease_refuses_before_merge(self):
        self.base_moves()
        self.git('push', '--force', 'origin', 'main:task')
        p = self.run_body('external_catch_up')
        self.assertEqual(p.returncode, 65, p.stderr)
        self.assertEqual(self.git('rev-parse', '-q', '--verify', 'MERGE_HEAD', check=False), '')

    def test_local_lease_refuses_before_merge(self):
        self.base_moves()
        p = self.run_body('bound_head=wrong\nexternal_catch_up')
        self.assertEqual(p.returncode, 65, p.stderr)
        self.assertEqual(self.head(), self.prev)

    def test_ancestor_needs_no_merge(self):
        p = self.run_body('external_catch_up')
        self.assert_ok(p)
        self.assertEqual(self.git('rev-parse', '-q', '--verify', 'MERGE_HEAD', check=False), '')

    def test_rebase_policy_does_not_merge(self):
        self.base_moves('conflict')
        p = self.run_body('external_catch_up', self.policy('rebase'))
        self.assert_ok(p)
        self.assertEqual(self.git('rev-parse', '-q', '--verify', 'MERGE_HEAD', check=False), '')
        self.assertIn('lands by rebase', p.stderr)

    def test_lost_merge_is_refused(self):
        self.base_moves()
        p = self.run_body('external_catch_up\ngit merge --abort\n' + self.precommit())
        self.assertEqual(p.returncode, 75, p.stderr)

    def test_marker_is_refused(self):
        self.base_moves('conflict')
        p = self.run_body('external_catch_up\n' + self.precommit())
        self.assertEqual(p.returncode, 75, p.stderr)
        self.assertIn('conflict markers', p.stderr)

    def test_resolved_commit_has_two_parents_and_records_before_move(self):
        self.base_moves('conflict')
        p = self.run_body('external_catch_up\n' + self.resolve() + self.precommit() + self.commit_block())
        self.assert_ok(p)
        self.assertEqual(self.git('show', '-s', '--format=%P'), self.prev + ' ' + self.base)
        self.assertEqual(self.head('refs/fm-caughtup/task'), self.head())
        self.assertEqual(self.git('status', '--porcelain'), '')
        self.assertEqual(self.git('rev-parse', '-q', '--verify', 'MERGE_HEAD', check=False), '')
        calls = (self.home / 'gitcalls').read_text()
        self.assertLess(calls.index('update-ref refs/fm-caughtup/task'),
                        calls.index('update-ref refs/heads/task'))

    def test_base_literal_marker_is_not_scanned(self):
        self.base_moves('literal')
        p = self.run_body('external_catch_up\n' + self.precommit() + self.commit_block())
        self.assert_ok(p)
        self.assertEqual(self.git('status', '--porcelain'), '')

    def test_unmarked_conflict_direction_and_untouched_refusal(self):
        self.base_moves('delete')
        p = self.run_body('external_catch_up\nprintf "side=%s\\n" "${rebuild_bare_side[@]}"\n'
                          'rebuild_side_left app\n' + self.precommit())
        self.assertEqual(p.returncode, 75, p.stderr)
        self.assertIn("side=your task's version; main deleted it", p.stdout)
        self.assertIn("main's version; your task deleted it", p.stdout)

    def test_gate_ancestor_shortcut_is_external_and_policy_specific(self):
        self.base_moves('conflict')
        self.git('merge', '--no-ff', '--no-commit', 'main', check=False)
        (self.tree / 'app').write_text('both intentions\n')
        self.commit('resolved merge')
        gate = function(root / 'bin/fm-gate.sh', 'gate2')
        for external, method, success in ((1, 'squash', True), (1, 'merge', True),
                                          (0, 'squash', False), (1, 'rebase', False)):
            with self.subTest(external=external, method=method):
                p = self.run_body(gate + '\nBRANCH=task; gate2',
                                  self.policy(method) + f'FM_EXTERNAL={external}\n')
                self.assertEqual(p.returncode == 0, success, p.stderr)

    def test_checkpoint_refuses_pending_merge(self):
        self.base_moves()
        self.assert_ok(self.run_body('external_catch_up'))
        p = subprocess.run(['bash', str(root / 'bin/fm-checkpoint.sh'), '--dir', str(self.tree), '--message', 'checkpoint'],
                           env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(p.returncode, 71, p.stderr)
        self.assertEqual(self.head(), self.prev)
        self.assertEqual(self.head('MERGE_HEAD'), self.base)

    def test_gate_unreadable_policy_replays_clean_branch(self):
        self.base_moves()
        self.check_gate_unreadable_policy_replays(True)

    def test_gate_unreadable_policy_replays_conflicting_merge(self):
        self.base_moves('conflict')
        self.git('merge', '--no-ff', '--no-commit', 'main', check=False)
        (self.tree / 'app').write_text('both intentions\n')
        self.commit('resolved merge')
        self.check_gate_unreadable_policy_replays(False)

    def check_gate_unreadable_policy_replays(self, success):
        gate = function(root / 'bin/fm-gate.sh', 'gate2')
        # Even a failed reader that printed a recognized method cannot shortcut.
        p = self.run_body(gate + '\nBRANCH=task; gate2',
                          'fm_stack_policy() { echo squash; return 1; }\n')
        self.assertEqual(p.returncode == 0, success, p.stderr)
        self.assertIn('rebase main', (self.home / 'gitcalls').read_text().splitlines())

    def test_catchup_event_data_is_emitted_once_on_pr_event(self):
        self.base_moves()
        events = section(worker, '# Only now: a push', '# The reviewer reads the pull request')
        p = self.run_body('external_catch_up\n' + self.precommit() +
                          self.commit_block() + self.publication() + events,
                          'note_unsent_published() { :; }\n'
                          'emit() { printf "%s\\n" "$*" >> "$work/pushed-events"; }\n')
        self.assert_ok(p)
        records = []
        for line in (self.home / 'pushed-events').read_text().splitlines():
            # JSON stays intact after --data; parse it before the summary flags.
            if '--data ' in line:
                data, _ = json.JSONDecoder().raw_decode(line.split('--data ', 1)[1])
                if 'caught_up' in data:
                    records.append((shlex.split(line.split('--data ', 1)[0]), data['caught_up']))
        self.assertEqual(len(records), 1, records)
        args, data = records[0]
        self.assertEqual(args[args.index('--pr') + 1], '9')
        self.assertEqual(data, dict(previous_head=self.prev, base='main',
                                   base_head=self.base, head=self.head(), conflicts=[]))

    def test_policy_refusal_leaves_no_commit(self):
        self.base_moves()
        p = self.run_body('external_catch_up\n' + self.precommit() + self.commit_block(), 'policy_rc=65\n')
        self.assertEqual(p.returncode, 65, p.stderr)
        self.assertEqual(self.head(), self.prev)
        self.assertEqual(self.head('MERGE_HEAD'), self.base)

    def test_clean_catchup_projects_only_after_publication(self):
        self.base_moves()
        p = self.run_body('external_catch_up\n' + function(worker, 'post_note') + '''
projection=summary; fm_private_note() { :; }
fm_external() { echo early-projection; }
post_note "$work/note" 9
''')
        self.assert_ok(p)
        self.assertNotIn('early-projection', p.stdout)

    def test_refused_push_rolls_back_even_through_finished(self):
        self.base_moves()
        # A concurrent writer replaces origin's task head after the lease check.
        body = 'external_catch_up\n' + self.precommit() + self.commit_block() + '''
merge_id="$(git rev-parse HEAD)"; echo "merge-id=$merge_id"
'''
        # Diverge origin from both merge parents, so the plain push must refuse.
        body += '''
other="$(printf concurrent | command git commit-tree "$(git rev-parse HEAD^{tree})" -p "$catchup_prev")"
command git push -q origin "$other:refs/heads/concurrent" || exit 98
command git --git-dir="$work/origin.git" update-ref refs/heads/task "$other" || exit 98
'''
        body += function(worker, 'finished') + '''
FM_RUN_DIR="$work/run"; mkdir -p "$FM_RUN_DIR"; scratch=()
publish_wip_if_dirty() { :; }; rebuild_settle() { :; }; fm_record_end() { :; }
emit() { :; }; mirror_watch_stop() { :; }
clean_scratch() { :; }; emit_once() { :; }; wake_round_end() { :; }
trap finished EXIT
''' + self.publication()
        p = self.run_body(body)
        self.assertEqual(p.returncode, 71, p.stderr)
        merge_id = p.stdout.split('merge-id=')[1].splitlines()[0]
        self.assertIn(merge_id, p.stderr)
        self.assertEqual(self.head(), self.prev)
        self.assertEqual(self.git('rev-parse', '-q', '--verify', 'refs/fm-caughtup/task', check=False), '')

    def test_prompt_describes_pending_merge_without_self_task_freeze(self):
        self.base_moves()
        prompt = section(worker,
            '  if [ "$rebuilt" = 1 ] || [ "${caught_up:-0}" = 1 ]; then\n    if [ "${caught_up:-0}" = 1 ]; then',
            '  # T-117: a crew round runs inside the OS sandbox')
        p = self.run_body('external_catch_up\n' + prompt)
        self.assert_ok(p)
        self.assertIn('# The current main was merged into your branch', p.stdout)
        self.assertIn(self.prev, p.stdout)
        self.assertIn(self.base, p.stdout)
        self.assertIn('Every file merged cleanly; there is nothing to resolve.', p.stdout)
        self.assertIn('Do not commit, abort or restart the merge', p.stdout)
        self.assertNotIn('design/tasks/', p.stdout)
        self.assertNotIn('worktree is detached', p.stdout)

    def test_question_only_clean_catchup_reaches_commit(self):
        self.base_moves()
        question = section(worker, 'if [ "$asked" = 1 ] && ! first_round_question && ! worker_changed_files;',
                           '# the same predicate the chain was given')
        no_work = section(worker,
            'if [ "$rebuilt" = 0 ] && [ "${caught_up:-0}" = 0 ] && ! first_round_question',
            '# --- from here on it is the script')
        body = ('external_catch_up\nasked=1; projection=local; held=; refused=0\n' +
                question + no_work + self.precommit() + self.commit_block() + self.publication())
        p = self.run_body(body)
        self.assert_ok(p)
        self.assertEqual(self.git('--git-dir=' + str(self.remote), 'rev-parse', 'task'), self.head())
        self.assertNotEqual(self.head(), self.prev)

    def test_successful_push_is_fast_forward_and_clears_record(self):
        self.base_moves()
        p = self.run_body('external_catch_up\n' + self.precommit() +
                          self.commit_block() + self.publication())
        self.assert_ok(p)
        self.assertEqual(self.git('--git-dir=' + str(self.remote), 'rev-parse', 'task'), self.head())
        self.assertEqual(self.git('show', '-s', '--format=%P'), self.prev + ' ' + self.base)
        self.assertEqual(self.git('rev-parse', '-q', '--verify', 'refs/fm-caughtup/task', check=False), '')
        self.assertNotIn('--force', (self.home / 'gitcalls').read_text())

    def test_clean_merge_counts_as_publication_but_not_worker_edits(self):
        self.base_moves()
        p = self.run_body('external_catch_up\n'
            'worker_changed_files && exit 96\nrebuild_publishes || exit 97\n'
            'printf worker-change > "$tree/worker-file"\nworker_changed_files')
        self.assert_ok(p)

    def test_unresolved_merge_is_not_exit_checkpointed(self):
        self.base_moves('conflict')
        p = self.run_body('external_catch_up\n' + function(worker, 'publish_wip_if_dirty') +
            '_fm_wip_done=0; publish_wip_if_dirty interrupted\n'
            'rebuild_publishes && exit 97\nexit 0')
        self.assert_ok(p)
        self.assertIn('nothing is published', p.stderr)
        self.assertEqual(self.head(), self.prev)
        self.assertEqual(self.head('MERGE_HEAD'), self.base)
        self.assertNotIn(' push ', (self.home / 'gitcalls').read_text())

    def test_unreadable_policy_refuses_without_merge(self):
        self.base_moves()
        p = self.run_body('external_catch_up', 'fm_stack_policy() { return 1; }\n')
        self.assertEqual(p.returncode, 65, p.stderr)
        self.assertEqual(self.git('rev-parse', '-q', '--verify', 'MERGE_HEAD', check=False), '')

    def test_missing_pr_and_dirty_tree_skip_merge(self):
        self.base_moves()
        for setup in ('PR=\n', 'printf dirty > "$tree/untracked"\n'):
            with self.subTest(setup=setup):
                p = self.run_body('external_catch_up', setup)
                self.assert_ok(p)
                self.assertEqual(self.git('rev-parse', '-q', '--verify', 'MERGE_HEAD', check=False), '')
                self.assertIn('not caught up', p.stderr)

    def test_merge_failure_without_conflict_aborts_before_worker(self):
        self.base_moves()
        prefix = r'''git() {
  case " $* " in *" merge --no-ff "*) return 128 ;; esac
  command git "$@"
}
'''
        p = self.run_body('external_catch_up\necho worker-started', prefix)
        self.assertEqual(p.returncode, 70, p.stderr)
        self.assertNotIn('worker-started', p.stdout)
        self.assertEqual(self.head(), self.prev)

    def test_committed_or_detached_merge_is_refused(self):
        self.base_moves()
        for action in ('git commit -qm premature', 'git symbolic-ref HEAD refs/heads/other'):
            with self.subTest(action=action):
                self.git('update-ref', 'refs/heads/other', self.prev)
                p = self.run_body('external_catch_up\n' + action + '\n' + self.precommit())
                self.assertEqual(p.returncode, 75, p.stderr)
                self.git('symbolic-ref', 'HEAD', 'refs/heads/task')
                self.git('merge', '--abort', check=False)
                self.git('reset', '--hard', self.prev)

    def test_unmarked_side_names_follow_both_merge_directions(self):
        # Task deleted, base changed: the worktree holds the base's version.
        self.git('rm', 'app')
        self.commit('task deletes')
        self.git('push', 'origin', 'task')
        self.base_moves('conflict')
        p = self.run_body('external_catch_up\nprintf "%s\\n" "${rebuild_bare_side[@]}"')
        self.assert_ok(p)
        self.assertIn("main's version; your task deleted it", p.stdout)
        self.git('merge', '--abort')
        # A self rebuild reverses the merge direction; its wording stays the same.
        self.git('checkout', '--detach', 'main')
        self.git('merge', '--squash', 'task', check=False)
        p = self.run_body('rebuild_collect_conflicts\nprintf "%s\\n" "${rebuild_bare_side[@]}"')
        self.assert_ok(p)
        self.assertIn("main's version; your task deleted it", p.stdout)

    def test_settle_interrupted_merge_for_every_remote_outcome(self):
        self.base_moves()
        self.assert_ok(self.run_body('external_catch_up\n' + self.precommit() + self.commit_block()))
        merged = self.head()
        self.git('push', 'origin', merged + ':refs/heads/transfer')
        for outcome in ('previous', 'merged', 'descendant', 'unrelated', 'absent', 'unreachable'):
            with self.subTest(outcome=outcome):
                self.git('update-ref', 'refs/heads/task', merged)
                self.git('update-ref', 'refs/fm-caughtup/task', merged)
                remote_head = self.prev
                if outcome == 'merged':
                    remote_head = merged
                elif outcome in ('descendant', 'unrelated'):
                    parent = merged if outcome == 'descendant' else self.prev
                    remote_head = self.git('--git-dir=' + str(self.remote),
                        '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                        'commit-tree', self.head('HEAD^{tree}'), '-p', parent, '-m', outcome)
                    self.assertEqual(self.git('rev-parse', '-q', '--verify',
                        remote_head + '^{commit}', check=False), '')
                self.git('--git-dir=' + str(self.remote), 'update-ref', 'refs/heads/task', remote_head)
                if outcome == 'absent':
                    self.git('--git-dir=' + str(self.remote), 'update-ref', '-d', 'refs/heads/task')
                if outcome == 'unreachable':
                    self.git('remote', 'set-url', 'origin', str(self.home / 'missing.git'))
                p = self.run_body('catchup_settle')
                self.assertEqual(p.returncode, 1 if outcome == 'unreachable' else 0, p.stderr)
                self.assertEqual(self.head(), merged if outcome in ('merged', 'descendant', 'unreachable') else self.prev)
                pending = self.git('rev-parse', '-q', '--verify', 'refs/fm-caughtup/task', check=False)
                self.assertEqual(pending, merged if outcome == 'unreachable' else '')


unittest.main(argv=['worker-external-catchup'])
PY
