#!/usr/bin/env bash
# T-051: execute target preparation and review head checks at their boundaries.
# Shared executable-block harness: tests/lib/crew_blocks.py
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
python3 - "$ROOT" <<'PY'
import os
import fcntl
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.dont_write_bytecode = True
root = Path(sys.argv[1])
sys.path.insert(0, str(root / 'tests/lib'))
sys.path.insert(0, str(root / 'bin/lib'))
from crew_blocks import function, section


class ExternalExecution(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('FM_', 'HERDR_', 'GIT_')) and k != 'GH_REPO'}
        self.env.update(PYTHONDONTWRITEBYTECODE='1')

    def shell(self, body):
        return subprocess.run(['bash', '-uc', '. "$1/bin/fm-config.sh"\n' + body,
                               '_', str(root), str(self.path)], env=self.env,
                              capture_output=True, text=True, timeout=30)

    def test_prepare_syncs_before_validation_and_verifies_afterwards(self):
        code = self.path / 'code/bin'
        code.mkdir(parents=True)
        script = code / 'fm-project.sh'
        script.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$FM_TEST_CALLS"\n')
        script.chmod(0o755)
        p = self.shell('''
export FM_EXTERNAL=1 FM_PROJECT=app FM_CODE_ROOT="$2/code" FM_TEST_CALLS="$2/calls"
FM_ENGINE_ROOT="$2/engine"
fm_target_validate() { echo validate >> "$FM_TEST_CALLS"; }
fm_external_prepare
''')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual((self.path / 'calls').read_text().splitlines(), [
            'sync app --repo ' + str(self.path / 'engine'), 'validate',
            'verify app --repo ' + str(self.path / 'engine')])

    def test_sync_failure_stops_before_validation_or_launch(self):
        code = self.path / 'code/bin'
        code.mkdir(parents=True)
        script = code / 'fm-project.sh'
        script.write_text('#!/bin/sh\nexit 1\n')
        script.chmod(0o755)
        p = self.shell('''
FM_EXTERNAL=1; FM_PROJECT=app; FM_CODE_ROOT="$2/code"; FM_ENGINE_ROOT="$2/engine"
fm_target_validate() { touch "$2/validated"; }
fm_external_prepare || exit 65
touch "$2/launched"
''')
        self.assertEqual(p.returncode, 65, p.stderr)
        self.assertFalse((self.path / 'launched').exists())

    def test_self_preparation_does_not_contact_project_service(self):
        p = self.shell('FM_EXTERNAL=0; fm_external_prepare')
        self.assertEqual(p.returncode, 0, p.stderr)

    def test_github_commands_name_external_repository(self):
        script = self.path / 'gh'
        script.write_text('#!/bin/sh\nprintf "%s\\n" "$*"\n')
        script.chmod(0o755)
        p = self.shell('FM_EXTERNAL=1; GH_REPO=owner/app; GH="$2/gh"; fm_github pr view 9')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.strip(), 'pr view 9 --repo owner/app')

    def test_github_preserves_self_argv(self):
        script = self.path / 'gh'
        script.write_text('#!/bin/sh\nprintf "%s\\n" "$*"\n')
        script.chmod(0o755)
        p = self.shell('FM_EXTERNAL=0; GH="$2/gh"; fm_github pr view 9')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.strip(), 'pr view 9')

    def test_worker_context_binds_github_requests_to_project(self):
        from fm_context_pack import Collector
        gh = self.path / 'context-gh'
        gh.write_text('#!/usr/bin/env python3\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n')
        gh.chmod(0o755)
        with patch.dict(os.environ, FM_EXTERNAL='1', GH_REPO='owner/app'):
            collector = Collector(self.path, str(gh), 'a'*40)
            self.assertEqual(collector.github('pr', 'view', '9'),
                             ['pr', 'view', '9', '--repo', 'owner/app'])
            self.assertEqual(collector.github('api', 'repos/{owner}/{repo}/commits/head/status'),
                             ['api', 'repos/owner/app/commits/head/status'])

    def test_review_rest_requests_bind_repository(self):
        gh = self.path / 'gh'
        gh.write_text('#!/usr/bin/env python3\nimport json,os,sys\n'
                      'with open(os.environ["FM_TEST_CALLS"], "a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\n'
                      'print(json.dumps({"contexts":["ci"], "check_runs":[]}))\n')
        gh.chmod(0o755)
        body = function(root / 'bin/fm-review.sh', 'required_names')
        body += function(root / 'bin/fm-review.sh', 'check_runs_of')
        p = self.shell('export FM_TEST_CALLS="$2/calls"; GH="$2/gh"; GH_REPO=owner/app; '
                       'BASE=trunk; FM_EXTERNAL=0\n' + body +
                       '\nrequired_names\nFM_EXTERNAL=1; check_runs_of abc per_page=100')
        self.assertEqual(p.returncode, 0, p.stderr)
        calls = [json.loads(line) for line in (self.path / 'calls').read_text().splitlines()]
        self.assertEqual(calls, [
            ['api', 'repos/owner/app/branches/trunk/protection/required_status_checks'],
            ['api', 'repos/owner/app/commits/abc/check-runs?per_page=100']])
        # External review uses confirmed names, without guessing protection.
        from fm_context_pack import Collector
        with patch.dict(os.environ, FM_EXTERNAL='1', GH_REPO='owner/app',
                        FM_TEST_CALLS=str(self.path / 'calls')):
            Collector(self.path, str(gh), 'abc').github(
                'api', 'repos/{owner}/{repo}/branches/trunk/protection/required_status_checks')
        calls = [json.loads(line) for line in (self.path / 'calls').read_text().splitlines()]
        self.assertEqual(calls[-1][1], 'repos/owner/app/branches/trunk/protection/required_status_checks')

    def test_review_clones_target_for_initial_and_rebuilt_checkout(self):
        def git(directory, *args):
            return subprocess.check_output(['git', '-C', str(directory), *args],
                                           env=self.env, stderr=subprocess.DEVNULL,
                                           text=True).strip()
        target = self.path / 'target'
        target.mkdir()
        git(target, 'init', '-q', '-b', 'main')
        git(target, '-c', 'core.hooksPath=/dev/null', '-c', 'user.name=Fixture',
            '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'base', '--allow-empty')
        base = git(target, 'rev-parse', 'HEAD')
        (target / 'target-only').write_text('target content')
        git(target, 'add', 'target-only')
        git(target, '-c', 'core.hooksPath=/dev/null', '-c', 'user.name=Fixture',
            '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'change')
        head = git(target, 'rev-parse', 'HEAD')
        for name in ('build_checkout', 'rebuild_checkout'):
            with self.subTest(name=name):
                body = function(root / 'bin/fm-review.sh', name)
                clone = body[body.index('  git clone '):body.rfind('\n}')]
                checkout = self.path / name
                p = self.shell('REPO="$2/engine-without-git"; FM_TARGET_ROOT="$2/target"; '
                               'CHECKOUT="$2/' + name + '"; R_HEAD=' + head +
                               '; head=$R_HEAD; R_BASE=' + base + '\n' + clone)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertEqual(git(checkout, 'rev-parse', 'HEAD'), head)
                self.assertEqual(git(checkout, 'remote'), '')
                self.assertEqual((checkout / 'target-only').read_text(), 'target content')
                self.assertFalse((checkout / '.git/objects/info/alternates').exists())

    def test_external_base_fast_forwards_without_discarding_local_work(self):
        def git(*args):
            return subprocess.check_output(['git', '-C', str(self.path), *args],
                env=self.env, text=True, stderr=subprocess.DEVNULL).strip()
        git('init', '-q', '-b', 'trunk')
        commit = ['-c', 'core.hooksPath=/dev/null', '-c', 'user.name=Fixture',
                  '-c', 'user.email=fixture@example.invalid', 'commit', '-qm']
        git(*commit, 'base', '--allow-empty')
        old = git('rev-parse', 'HEAD')
        git('checkout', '-qb', 'remote-next')
        (self.path / 'file').write_text('upstream')
        git('add', 'file'); git(*commit, 'next')
        new = git('rev-parse', 'HEAD')
        git('update-ref', 'refs/remotes/origin/trunk', new)
        git('checkout', '-q', 'trunk')
        (self.path / 'unpublished').write_text('keep')
        body = 'FM_EXTERNAL=1; FM_TARGET_ROOT="$2"; FM_BASE=trunk; fm_external_base'
        p = self.shell(body)
        self.assertNotEqual(p.returncode, 0, 'dirty target must not be changed')
        self.assertEqual(git('rev-parse', 'HEAD'), old)
        self.assertEqual((self.path / 'unpublished').read_text(), 'keep')
        (self.path / 'unpublished').unlink()
        p = self.shell(body)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(git('rev-parse', 'HEAD'), new)

    def test_external_commit_refuses_nested_private_artifacts(self):
        p = self.shell(r'''
FM_EXTERNAL=1
git() { printf 'src/real\0nested/.fm-private/prompt.md\0'; }
fm_private_stage "$2"
''')
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('nested/.fm-private/prompt.md', p.stderr)

    def test_cleanup_retains_surviving_and_uncertain_attempts(self):
        spec = importlib.util.spec_from_file_location('external_herdr', root / 'bin/fm-herdr.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        run = self.path / 'state/runs/worker-shira-t051-r1'
        attempt = run / 'attempt'
        attempt.mkdir(parents=True)
        (run / 'identity.json').write_text(json.dumps({'task': 'T-051', 'project': 'app'}))
        (run / 'orchestration-result.json').write_text('{}')
        receipt = attempt / 'execution.json'
        receipt.write_text('{"started":true}')
        with patch.object(module, 'record_root', return_value=self.path):
            with (attempt / 'execution.lock').open('w') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                self.assertEqual(module.task_idle(self.path, 'T-051'), 1)
                self.assertEqual(module.task_idle(self.path, 'T-052'), 0)
            self.assertEqual(module.task_idle(self.path, 'T-051'), 0)
            receipt.write_text('{"started":false}')
            self.assertEqual(module.task_idle(self.path, 'T-051'), 1)

    def test_new_external_worktree_uses_fetched_base(self):
        # The actual creation block, with git recording the chosen start point.
        block = section(root / 'bin/fm-worker.sh',
                        '  if git show-ref --verify --quiet "refs/heads/$branch"; then\n    git worktree add',
                        '# A stale ephemeral question')
        p = self.shell('''
FM_EXTERNAL=1; BASE=trunk; branch=t-051-work; tree="$2/tree"
git() {
  if [ "$1" = show-ref ]; then return 1; fi
  printf '%s\\n' "$*" >> "$2/calls"
}
''' .replace('"$2/calls"', '"' + str(self.path / 'calls') + '"') + 'if true; then\n' + block)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('refs/remotes/origin/trunk', (self.path / 'calls').read_text())

    def test_review_refuses_moved_or_unreadable_head(self):
        body = function(root / 'bin/fm-review.sh', 'verify_review_head')
        for binding in ('printf stale', 'return 1'):
            p = self.shell('''
FM_EXTERNAL=1; TASK=T-051; PR=9; BRANCH=t-051-work; R_HEAD=reviewed
fm_binding() { ''' + binding + '''; }
''' + body + '\nverify_review_head')
            self.assertNotEqual(p.returncode, 0, p.stderr)

    def test_review_accepts_only_matching_authoritative_head(self):
        body = function(root / 'bin/fm-review.sh', 'verify_review_head')
        p = self.shell('''
FM_EXTERNAL=1; TASK=T-051; PR=9; BRANCH=t-051-work; R_HEAD=reviewed
fm_binding() { printf reviewed; }
''' + body + '\nverify_review_head')
        self.assertEqual(p.returncode, 0, p.stderr)

    def test_settled_review_binds_reviewed_head_and_base_name(self):
        body = function(root / 'bin/fm-review.sh', 'verify_review_head')
        for answer in ('reviewed', 'stale'):
            p = self.shell('''
FM_EXTERNAL=1; TASK=T-051; PR=9; BRANCH=t-051-work; R_HEAD=reviewed
REVIEW_PR_BASE=main; CALLS="$2/calls"
fm_binding() { printf '%s\\n' "$*" > "$CALLS"; printf ''' + answer + '''; }
''' + body + '\nverify_review_head settled')
            if answer == 'reviewed':
                self.assertEqual(p.returncode, 0, p.stderr)
            else:
                self.assertNotEqual(p.returncode, 0, p.stderr)
            calls = (self.path / 'calls').read_text().strip()
            self.assertTrue(calls.startswith('review-final '), calls)
            self.assertIn('--head reviewed --base-name main', calls)

    def test_external_branch_and_pr_title_do_not_publish_private_spec(self):
        worker = root / 'bin/fm-worker.sh'
        branch = section(worker, 'if [ -n "$branch_guess" ]; then\n  branch=',
                         'case "$branch" in main|master|"$BASE")')
        publication = section(worker, '  pr_body="Dispatched by firstmate',
                              '  url="$(fm_github pr create')
        p = self.shell('FM_EXTERNAL=1; branch_guess=""; slug=t-051; TASK=T-051; '
                       'spec=\'{"title":"Private launch strategy"}\'\n' + branch + publication +
                       '\nprintf "%s\\n" "$branch" "$pr_title" "$pr_body"')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.splitlines()[0], 't-051-work')
        self.assertEqual(p.stdout.splitlines()[1], 'T-051: project work')
        self.assertNotIn('Private launch strategy', p.stdout)
        commit = section(worker, 'commit_msg="$TASK:', 'commit_ok=')
        p = self.shell('FM_EXTERNAL=1; TASK=T-051; spec=\'{"title":"Private launch strategy"}\'\n'
                       + 'tree="$2"; fm_private_stage() { :; }\n' + commit + '\nprintf "%s" "$commit_msg"')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, 'T-051: project work')


unittest.main(argv=['external-execution'], verbosity=2)
PY
assert_eq 0 "$?" "external launch synchronizes target and refuses stale review heads"
# The index, not the working copy or filename, owns publication bytes.
t="$(safe_tmpdir)"
guard_tree="$t/design-guard"
git init -q "$guard_tree"
printf 'private design body\n' > "$t/private-design"
cp "$t/private-design" "$guard_tree/copied-reference.txt"
git -C "$guard_tree" add copied-reference.txt
printf 'different working copy\n' > "$guard_tree/copied-reference.txt"
guard_rc=0
FM_EXTERNAL=1 FM_DESIGN="$t/private-design" bash -c '. "$1/bin/fm-config.sh"; fm_private_stage "$2"' _ "$ROOT" "$guard_tree" > "$t/design-out" 2> "$t/design-err" || guard_rc=$?
assert_eq 65 "$guard_rc" "private design bytes in index cannot be published"
assert_contains "$(cat "$t/design-err")" "copied-reference.txt" "refusal names the staged copy"
git -C "$guard_tree" add copied-reference.txt
guard_rc=0
FM_EXTERNAL=1 FM_DESIGN="$t/private-design" bash -c '. "$1/bin/fm-config.sh"; fm_private_stage "$2"' _ "$ROOT" "$guard_tree" || guard_rc=$?
assert_eq 0 "$guard_rc" "different staged content passes"
guard_rc=0
FM_EXTERNAL=1 FM_DESIGN="$t/missing-design" bash -c '. "$1/bin/fm-config.sh"; fm_private_stage "$2"' _ "$ROOT" "$guard_tree" || guard_rc=$?
assert_eq 0 "$guard_rc" "unreadable private source counts as no match"

finish
