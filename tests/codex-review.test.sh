#!/usr/bin/env bash
# T-163: feature-owned tests. No model, GitHub or nested OS sandbox.
set -euo pipefail
exec < /dev/null
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import importlib.util
import json
import shutil
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.dont_write_bytecode = True
root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('managed', root / 'bin/fm-herdr.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class CodexReview(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name).resolve()
        self.tree = self.home / 'checkout'
        self.tree.mkdir()
        def git(*args):
            return subprocess.check_output(['git', '-C', str(self.tree), *args], env={
                'PATH': os.environ['PATH'], 'HOME': str(self.home),
                'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null'}, stderr=subprocess.DEVNULL).decode().strip()
        self.git = git
        git('init', '-q'); git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                              'commit', '-q', '--allow-empty', '-m', 'fixture')
        self.head = git('rev-parse', 'HEAD')
        git('update-ref', 'refs/fm/head', self.head)
        git('update-ref', 'refs/fm/base', self.head)
        git('checkout', '-q', '--detach', self.head)
        self.env = dict(FM_RUN_REVIEW='1', FM_ROLE='reviewer', FM_TASK='T-163',
                        FM_ACTOR='reviewer-fixture-t163-r1', FM_REVIEW_CHECKOUT=str(self.tree),
                        FM_REVIEW_HEAD=self.head, FM_REVIEW_BASE=self.head, FM_REVIEW_PATCH='')
        self.log = self.home / 'cli.log'

    def events(self, *events):
        self.log.write_text('\n'.join(json.dumps(e) for e in events) + '\n')
        return m.cli_final('codex', self.log)

    def test_final_only(self):
        answer = 'APPROVE:T-163\nREVIEWER_COMPLETE:T-163'
        self.assertEqual(answer, self.events(
            {'type':'thread.started','thread_id':'fixture'}, {'type':'turn.started'},
            {'type':'item.completed','item':{'id':'1','type':'command_execution','aggregated_output':'REJECT:T-163'}},
            {'type':'item.completed','item':{'id':'2','type':'agent_message','text':answer}},
            {'type':'turn.completed','usage':{'input_tokens':1,'output_tokens':1}}))
        self.assertIsNone(self.events({'type':'item.completed','item':{'type':'agent_message','text':answer}}))
        self.assertIsNone(self.events({'type':'turn.started'},
            {'type':'item.completed','item':{'type':'command_execution','aggregated_output':answer}},
            {'type':'turn.completed'}))
        self.assertIsNone(self.events({'type':'turn.started'},
            {'type':'item.completed','item':{'type':'agent_message','text':answer}},
            {'type':'turn.failed','error':{'message':'failure'}}))
        self.assertIsNone(self.events({'type':'turn.started'},
            {'type':'item.completed','item':{'type':'agent_message','text':answer}},
            {'type':'turn.completed'}, {'type':'turn.started'}))

    def test_checkout_binding(self):
        context = m.review_context(self.env)
        self.assertEqual(str(self.tree), context['checkout'])
        self.assertEqual(self.head, context['head'])
        for key, value in [('FM_REVIEW_CHECKOUT',''), ('FM_REVIEW_CHECKOUT','relative'),
                           ('FM_REVIEW_HEAD','0'*40), ('FM_ROLE','worker')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                m.review_context(dict(self.env, **{key:value}))
        self.git('remote', 'add', 'origin', '/unrelated')
        with self.assertRaises(ValueError): m.review_context(self.env)

    def test_review_profiles_protect_git(self):
        spec = importlib.util.spec_from_file_location('sandbox', root / 'bin/lib/fm_sandbox_policy.py')
        sandbox = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(sandbox)
        namespace = vars(sandbox)
        policy = dict(never_read=[], repo_config=['.codex'], review_git_readonly=True)
        (self.tree / '.codex').mkdir()
        roots = [str(self.tree), str(self.home / 'round-temp')]
        profile = namespace['darwin'](policy, roots, [], {}, '', None)
        self.assertIn('(deny file-write* (subpath "' + str(self.tree / '.git') + '"))', profile)
        linux = namespace['linux'](policy, roots, [], {}, '').splitlines()
        self.assertIn(['--ro-bind', str(self.tree / '.git'), str(self.tree / '.git')],
                      [linux[i:i+3] for i in range(len(linux))])
        policy.pop('review_git_readonly')
        self.assertNotIn('--ro-bind\n' + str(self.tree / '.git'),
                         namespace['linux'](policy, roots, [], {}, ''))

    def test_bound_result(self):
        attempt = self.home / 'attempt'; attempt.mkdir()
        context = m.review_context(self.env)
        answer = 'APPROVE:T-163\nREVIEWER_COMPLETE:T-163'
        (attempt / 'final.txt').write_text(answer)
        invocation = dict(actor=self.env['FM_ACTOR'], role='reviewer', task='T-163', review=context)
        m.save(attempt / 'invocation.json', invocation)
        result = dict(invocation, attempt=str(attempt), chain_attempt='current',
                      final_source='codex-json-completed-turn', final_sha256=m.hashlib.sha256(answer.encode()).hexdigest())
        m.save(self.home / 'last-result.json', result)
        self.assertEqual(answer, m.review_final(self.home, 'current', self.env))
        self.assertEqual('', m.review_final(self.home, 'old', self.env))
        self.assertEqual('', m.review_final(self.home, 'current', dict(self.env, FM_REVIEW_HEAD='0'*40)))
        self.assertEqual('', m.review_final(self.home, 'current', dict(self.env, FM_ACTOR='other')))
        (attempt / 'final.txt').write_text('REJECT:T-163')
        self.assertEqual('', m.review_final(self.home, 'current', self.env))

    def adapter_fixture(self):
        code = self.home / 'code'; (code / 'bin/adapters').mkdir(parents=True)
        for name in ['bin/fm-config.sh', 'bin/fm-herdr.py', 'bin/adapters/_lib.sh', 'bin/adapters/codex.sh']:
            shutil.copy2(root / name, code / name)
        sandbox = code / 'bin/fm-sandbox.sh'
        sandbox.write_text("""#!/usr/bin/env bash
case "$1" in
  os) echo darwin;;
  covers) echo 'write read network sockets env repo-config refuse ulimit';;
  run)
    printf '%s\n' "$@" > "$CAPTURE/sandbox.args"
    shift
    while [ "$1" != -- ]; do
      case "$1" in --started=*) printf 'started\n' > "${1#*=}";; esac
      shift
    done
    shift
    exec "$@";;
  *) exit 99;;
esac
""")
        sandbox.chmod(0o755)
        vendor = self.home / 'tools'; vendor.mkdir()
        codex = vendor / 'codex'
        codex.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
p = pathlib.Path(os.environ['CAPTURE'])
(p / 'argv.json').write_text(json.dumps(sys.argv[1:]))
(p / 'cwd').write_text(os.getcwd())
(p / 'prompt').write_text(sys.stdin.read())
assert sys.argv[1] == 'exec' and sys.argv[-1] == '-'
assert '--json' in sys.argv
for event in [{'type':'turn.started'}, {'type':'item.completed','item':{'id':'0','type':'agent_message','text':'APPROVE:T-163\\nREVIEWER_COMPLETE:T-163'}}, {'type':'turn.completed','usage':{}}]:
    print(json.dumps(event))
""")
        codex.chmod(0o755)
        attempt = self.home / 'attempt'; attempt.mkdir()
        adapter = code / 'bin/adapters/codex.sh'
        m.save(attempt / 'invocation.json', dict(adapter=str(adapter), actor=self.env['FM_ACTOR'],
            role='reviewer', task='T-163', review=m.review_context(self.env)))
        policy = self.home / 'policy.json'
        policy.write_text(json.dumps(dict(role='reviewer', write=['{root}','{tmp}'], network=[],
            env_scrub=dict(names=[], prefixes=[]))))
        prompt = self.home / 'prompt.md'; prompt.write_text('Review the pinned head')
        env = dict(self.env, PATH=str(vendor) + os.pathsep + os.environ['PATH'], HOME=str(self.home),
            TMPDIR=str(self.home), CAPTURE=str(self.home), FM_CONTEXT_READY='1',
            FM_ATTEMPT_DIR=str(attempt), FM_FINAL_PATH=str(attempt / 'final.txt'),
            FM_POLICY=str(policy), FM_MODEL='fixture-model')
        def run(**extra):
            return subprocess.run([str(adapter), 'run', str(prompt), str(self.tree), str(self.log)],
                env=dict(env, **extra), capture_output=True, text=True)
        return run, codex

    def test_launch_and_tampering(self):
        run, codex = self.adapter_fixture()
        result = run()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(str(self.tree), (self.home / 'cwd').read_text())
        args = json.loads((self.home / 'argv.json').read_text())
        self.assertEqual('fixture-model', args[args.index('-m') + 1])
        self.assertNotIn('--output-last-message', args)
        self.assertNotIn('--write=', (self.home / 'sandbox.args').read_text())
        self.assertEqual([], list(self.home.glob('fm-round.*')))
        for option in ['-sworkspace-write', '-cfoo=bar', '-C/', '--cd=/', '--profile=x',
                       '--enable=feature', '--output-last-message=x', '-mwrong', '--ask-for-approval=on-request']:
            with self.subTest(option=option):
                (self.home / 'argv.json').unlink(missing_ok=True)
                self.assertEqual(64, run(FM_ADAPTER_ARGS=option).returncode)
                self.assertFalse((self.home / 'argv.json').exists())
        self.assertEqual(64, run(FM_REVIEW_HEAD='0'*40).returncode)
        self.assertEqual(64, run(FM_REVIEW_CHECKOUT='').returncode)
        self.assertEqual(64, run(FM_ROUND_UNSANDBOXED='1').returncode)
        codex.unlink()
        # Empty executable shim models unavailable CLI without exposing ambient vendors.
        codex.write_text('#!/bin/sh\nexit 69\n'); codex.chmod(0o755)
        self.assertEqual(2, run().returncode)
        self.assertEqual([], list(self.home.glob('fm-round.*')))

    def test_cleanup_live_owner(self):
        # Exercise the launcher's actual cleanup functions, with an inherited
        # kernel lock in this foreground process. No background test process.
        script = (root / 'bin/fm-review.sh').read_text()
        drop = script[script.index('drop_checkout() {'):script.index('# Mid-run activity')]
        check = script[script.index('checkout_is_free() {'):script.index('# checkout_ok:')]
        directory = self.home / 'fm-review.fixture'; directory.mkdir()
        owner = directory / 'owner'; owner.write_text('fixture')
        run = self.home / 'run'; run.mkdir()
        attempt = run / 'attempt'; attempt.mkdir()
        (directory / 'run').write_text(str(run))
        m.save(attempt / 'invocation.json', dict(lifetime_tracking=True))
        m.save(attempt / 'execution.json', dict(started=True))
        lock = (attempt / 'execution.lock').open('w')
        self.addCleanup(lock.close)
        fcntl.flock(lock, fcntl.LOCK_EX)
        env = dict(PATH=os.environ['PATH'], FM_CODE_ROOT=str(root), REPO=str(root),
                   CHECKOUT_ROOT=str(directory), CHECKOUT=str(directory / 'checkout'), OWNER_LOCK_HELD='')
        command = check + '\n' + drop + '\ndrop_checkout\n'
        subprocess.run(['bash', '-c', command], env=env, check=True)
        self.assertTrue(directory.exists(), 'live adapter checkout retained')
        rebuild = script[script.index('rebuild_checkout() {'):script.index('sweep_checkouts() {')]
        refresh = subprocess.run(['bash', '-c', check + '\n' + rebuild + '\nrebuild_checkout'],
            env=dict(env, R_HEAD=self.head, R_BASE=self.head), capture_output=True)
        self.assertNotEqual(0, refresh.returncode, 'retry refuses a live execution owner')
        self.assertTrue(directory.exists(), 'refused retry preserves the live checkout')
        fcntl.flock(lock, fcntl.LOCK_UN)
        subprocess.run(['bash', '-c', command], env=env, check=True)
        self.assertFalse(directory.exists(), 'failed/dead adapter checkout cleaned')

    def test_checkout_uses_pinned_head_after_branch_moves(self):
        self.git('checkout', '-qb', 'moving')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '-q', '--allow-empty', '-m', 'branch moved')
        script = (root / 'bin/fm-review.sh').read_text()
        build = script[script.index('build_checkout() {'):script.index('# A checkout left')]
        rebuild = script[script.index('rebuild_checkout() {'):script.index('sweep_checkouts() {')]
        check = script[script.index('checkout_is_free() {'):script.index('# checkout_ok:')]
        run = self.home / 'run'; run.mkdir()
        env = dict(PATH=os.environ['PATH'], HOME=str(self.home), TMPDIR=str(self.home),
                   REPO=str(self.tree), FM_RUN_DIR=str(run), FM_CODE_ROOT=str(root),
                   R_HEAD=self.head, R_BASE=self.head, BRANCH='moving', BASE='moving')
        command = build + '\n' + rebuild + '\n' + check + '''
build_checkout || exit 1
git -C "$CHECKOUT" rev-parse HEAD
rebuild_checkout || exit 1
git -C "$CHECKOUT" rev-parse HEAD
'''
        result = subprocess.run(['bash', '-c', command], env=env, capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual([self.head, self.head], result.stdout.splitlines())

    def test_legacy_final(self):
        self.log.write_text(json.dumps({'type':'result','result':'Claude answer','is_error':False}))
        self.assertEqual('Claude answer', m.cli_final('claude', self.log))

unittest.main(argv=['codex-review'], verbosity=2)
PY
