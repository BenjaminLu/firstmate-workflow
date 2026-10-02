#!/usr/bin/env bash
# Stock launcher/transport/adapter composition; external services are fixtures.
set -euo pipefail
exec < /dev/null
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import json
import os
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

root = Path(sys.argv[1])

class StockReview(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name).resolve()
        self.repo = self.home / 'repo'
        self.repo.mkdir()
        self.tools = self.home / 'tools'
        self.tools.mkdir()
        self.roundtmp = self.home / 'tmp'
        self.roundtmp.mkdir()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('FM_', 'HERDR_', 'GIT_', 'CODEX_', 'CMUX_', 'TMUX', 'XDG_'))}
        self.env.update(HOME=str(self.home), TMPDIR=str(self.roundtmp),
                        PATH=str(self.tools) + os.pathsep + os.environ['PATH'],
                        GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
                        FM_ROOT=str(self.repo), FM_TRANSPORT='direct', HERDR_ENV='0',
                        FM_REVIEW_CI_WAIT='0', FM_GH=str(self.tools / 'gh'))
        shutil.copytree(root / 'bin', self.repo / 'bin')
        shutil.copytree(root / 'skills', self.repo / 'skills')
        (self.repo / 'design/tasks').mkdir(parents=True)
        (self.repo / 'design/tasks/T-Z.json').write_text(json.dumps(dict(
            id='T-Z', title='fixture', scope=['src/**'], acceptance=['pinned review'])))
        (self.repo / 'config.yaml').write_text(
            'vendor: codex\nreviewer:\n  vendor: codex\n  mode: run\n  model: fixture-model\n')
        self.write(self.repo / 'bin/fm-auth-probe.sh',
                   '#!/bin/sh\necho "status: authenticated"\n')
        # This is only a launch fixture, never evidence of OS confinement.
        self.write(self.repo / 'bin/fm-sandbox.sh', '''#!/bin/sh
case "$1" in
 os) echo darwin;;
 covers) echo 'write read network sockets env repo-config refuse ulimit';;
 run)
   shift
   while [ "$1" != -- ]; do
     case "$1" in --started=*) echo started > "${1#*=}";; esac
     shift
   done
   shift
   exec "$@";;
 *) exit 99;;
esac
''')
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('add', '.')
        self.git('commit', '-qm', 'base')
        self.base = self.git('rev-parse', 'HEAD')
        self.git('checkout', '-qb', 'work')
        (self.repo / 'src').mkdir()
        (self.repo / 'src/a').write_text('pinned change\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'head')
        self.head = self.git('rev-parse', 'HEAD')
        self.git('commit', '-q', '--allow-empty', '-m', 'later head')
        self.later = self.git('rev-parse', 'HEAD')
        self.git('reset', '--hard', self.head)
        self.git('checkout', '-q', 'main')
        self.write(self.tools / 'gh', '''#!/usr/bin/env python3
import json, pathlib, subprocess, sys
home = pathlib.Path(HOME_LITERAL)
args = sys.argv[1:]
with (home / 'ghcalls').open('a') as f: f.write(json.dumps(args) + '\\n')
if args[:2] == ['pr', 'comment']:
    (home / 'published').write_text(args[args.index('--body') + 1])
elif args and args[0] == 'api' and 'protection' in ' '.join(args):
    if (home / 'move').exists():
        subprocess.run(['git', '-C', str(home / 'repo'), 'update-ref', 'refs/heads/work', LATER_LITERAL], check=True)
    print('{"contexts":["ci"]}')
elif args and args[0] == 'api' and 'check-runs' in ' '.join(args):
    print('{"check_runs":[]}')
elif args[:2] == ['pr', 'view'] and 'comments' in args:
    print((home / 'comments.json').read_text() if (home / 'comments.json').exists() else '{"comments":[]}')
elif '--json' in args:
    print('[]')
'''.replace('HOME_LITERAL', repr(str(self.home))).replace('LATER_LITERAL', repr(self.later)))
        self.write(self.tools / 'codex', '''#!/usr/bin/env python3
import json, pathlib, subprocess, sys, re, hashlib
home = pathlib.Path(HOME_LITERAL)
if sys.argv[1:] == ['--version']:
    print('codex-cli fixture'); raise SystemExit
assert sys.argv[1] == 'exec' and sys.argv[-1] == '-'
assert '--json' in sys.argv and '--output-last-message' not in sys.argv
assert sys.argv[sys.argv.index('-m') + 1] == 'fixture-model'
prompt = sys.stdin.read()
mode = (home / 'mode').read_text()
old = list(home.glob('capture-*.json'))
number = len(old) + 1
checkout = pathlib.Path.cwd()
record = dict(prompt=prompt, checkout=str(checkout),
              head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
              clean=not subprocess.check_output(['git', 'status', '--porcelain'], text=True).strip())
if '# Bounded review context' in prompt:
    archive = pathlib.Path(re.search(r'are retained in (.+?)\\. Those paths', prompt)[1])
    assert checkout in archive.parents
    record['archive'] = str(archive)
    record['sources'] = {p.name: p.read_text() for p in archive.iterdir()}
    for name in ('history.md', 'diff.md'):
        digest = hashlib.sha256((archive / name).read_bytes()).hexdigest()
        assert digest in prompt, (name, 'missing source digest')
(home / ('capture-%s.json' % number)).write_text(json.dumps(record))
assert record['clean'], 'every invocation starts fresh'
(checkout / 'review-scratch').write_text('legitimate reviewer write')
print(json.dumps({'type':'thread.started', 'thread_id':'fixture'}))
print(json.dumps({'type':'turn.started'}))
answer = 'APPROVE:T-Z\\nREVIEWER_COMPLETE:T-Z'
print(json.dumps({'type':'item.completed','item':{'type':'command_execution','aggregated_output':answer}}))
if mode == 'unavailable':
    print('rate limit exceeded'); raise SystemExit(2)
if mode == 'retry' and number == 1:
    answer = 'Read the files; no decision yet.'
if mode == 'transcript':
    answer = 'No signed final answer.'
print(json.dumps({'type':'item.completed','item':{'id':'final','type':'agent_message','text':answer}}))
if mode != 'failed-turn':
    print(json.dumps({'type':'turn.completed','usage':{}}))
else:
    print(json.dumps({'type':'turn.failed','error':{'message':'fixture failure'}}))
'''.replace('HOME_LITERAL', repr(str(self.home))))

    def write(self, path, source):
        path.write_text(source)
        path.chmod(0o755)

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args],
            env=self.env, stderr=subprocess.DEVNULL, text=True).strip()

    def run_review(self, mode='success', round_number='1', **extra):
        (self.home / 'mode').write_text(mode)
        result = subprocess.run([str(self.repo / 'bin/fm-review.sh'), '--task', 'T-Z',
            '--branch', 'work', '--pr', '9', '--round', round_number], cwd=self.repo, env=dict(self.env, **extra),
            capture_output=True, text=True, timeout=90)
        self.assertFalse(list(self.roundtmp.glob('fm-review.*')), result.stderr)
        self.assertFalse(list(self.roundtmp.glob('fm-round.*')), result.stderr)
        return result

    def test_pinned_prompt_receipt_and_managed_final(self):
        (self.home / 'move').touch()
        result = self.run_review()
        self.assertEqual(0, result.returncode, result.stderr)
        capture = json.loads((self.home / 'capture-1.json').read_text())
        self.assertEqual(self.later, self.git('rev-parse', 'work'))
        self.assertEqual(self.head, capture['head'])
        self.assertIn('Head SHA: ' + self.head, capture['prompt'])
        self.assertNotIn('Head SHA: ' + self.later, capture['prompt'])
        published = (self.home / 'published').read_text()
        self.assertIn('head=' + self.head, published)
        self.assertIn('base=' + self.base, published)
        records = list((self.repo / 'state').rglob('last-result.json'))
        self.assertEqual(1, len(records))
        receipt = json.loads(records[0].read_text())
        self.assertEqual('codex-json-completed-turn', receipt['final_source'])
        local = [json.loads(p.read_text()) for p in
                 sorted((self.repo / 'state/evidence/self/T-Z').glob('*.json'))]
        verdicts = [r for r in local if r['kind'] == 'verdict']
        self.assertEqual('authenticated', verdicts[-1]['provenance']['level'])
        self.assertEqual(receipt['final_sha256'], verdicts[-1]['provenance']['final_sha256'])
        self.assertEqual(capture['checkout'], receipt['review']['checkout'])
        self.assertEqual(self.head, receipt['review']['head'])
        self.assertIn('patch=' + receipt['review']['patch'], published)
        invocation = json.loads((Path(receipt['attempt']) / 'invocation.json').read_text())
        self.assertEqual(invocation['actor'], receipt['actor'])
        self.assertEqual(invocation['review'], receipt['review'])
        final = (Path(receipt['attempt']) / 'final.txt').read_bytes()
        self.assertEqual(hashlib.sha256(final).hexdigest(), receipt['final_sha256'])
        envelope, body = published.split('\n\n', 1)
        self.assertEqual('EVIDENCE:T-Z ' + verdicts[-1]['signature'], envelope)
        self.assertTrue(body.startswith(final.decode().rstrip()))
        self.assertEqual(self.head, verdicts[-1]['binding']['head'])
        self.assertEqual(self.base, verdicts[-1]['binding']['base'])
        self.assertEqual(receipt['review']['patch'], verdicts[-1]['binding']['patch'])
        self.assertFalse(Path(capture['checkout']).exists())
        events = [json.loads(line) for line in (self.repo / 'state/events.jsonl').read_text().splitlines()]
        self.assertIn('approved', [e['type'] for e in events])

    def test_oversized_managed_context_survives_fresh_retry(self):
        # Fail first against T-165's worktree-root archive: real managed
        # admission refuses before the fake CLI can record any invocation.
        original = '1. ORIGINAL complete acceptance\n2. Preserve pinned evidence\nCRITERIA-COMPLETE:T-Z\nREJECT:T-Z'
        later = '1. **done** ORIGINAL complete acceptance\n2. **open** Preserve pinned evidence\n3. REGRESSION:T-Z retain new evidence\nCRITERIA-COMPLETE:T-Z\nREJECT:T-Z'
        bodies = [original] + [later, original] * 40
        (self.home / 'comments.json').write_text(json.dumps(
            dict(comments=[dict(body=body) for body in bodies])))
        # T-135: the same review history is now operator-retained local evidence.
        for body in bodies:
            subprocess.run([sys.executable, str(root / 'tests/lib/evidence.py'),
                            str(root), str(self.repo / 'state'), 'T-Z', 'reviewer-fixture', body], check=True)

        self.git('checkout', '-q', 'work')
        (self.repo / 'src/oversized').write_text('oversized pinned line\n' * 145000)
        self.git('add', 'src/oversized')
        self.git('commit', '-qm', 'oversized context')
        self.head = self.git('rev-parse', 'HEAD')
        self.git('checkout', '-q', 'main')
        result = self.run_review('retry', round_number='2')
        self.assertEqual(0, result.returncode, result.stderr)
        captures = [json.loads(p.read_text()) for p in sorted(self.home.glob('capture-*.json'))]
        self.assertEqual(2, len(captures), result.stderr)
        for capture in captures:
            self.assertTrue(capture['clean'])
            self.assertEqual(self.head, capture['head'])
            self.assertLessEqual(len(capture['prompt'].encode()), 524288)
            self.assertIn(original, capture['prompt'])
            self.assertIn(later, capture['prompt'])
            self.assertIn('OMITTED entire inline patch', capture['prompt'])
            self.assertIn('exact repeat', capture['prompt'])
            self.assertGreater(len(capture['sources']['diff.md']), 2719034)
            self.assertIn(original, capture['sources']['history.md'])
            pins = json.loads(capture['sources']['pins.json'])
            self.assertEqual(self.head, pins['head'])
            self.assertEqual(self.base, pins['base'])
            for key in ('head', 'base', 'patch'):
                self.assertIn(pins[key], capture['prompt'])
        self.assertEqual(captures[0]['archive'], captures[1]['archive'])
        self.assertEqual(captures[0]['sources'], captures[1]['sources'])
        published = (self.home / 'published').read_text()
        self.assertIn('REVIEWED:T-Z verdict=APPROVE head=' + self.head, published)
        receipt = json.loads(next((self.repo / 'state').rglob('last-result.json')).read_text())
        self.assertEqual('codex-json-completed-turn', receipt['final_source'])
        local = [json.loads(p.read_text()) for p in
                 sorted((self.repo / 'state/evidence/self/T-Z').glob('*.json'))]
        verdicts = [r for r in local if r['kind'] == 'verdict']
        self.assertEqual('authenticated', verdicts[-1]['provenance']['level'])
        self.assertEqual(receipt['final_sha256'], verdicts[-1]['provenance']['final_sha256'])
        self.assertEqual(self.head, receipt['review']['head'])

    def test_dirty_unsigned_retry(self):
        result = self.run_review('retry')
        self.assertEqual(0, result.returncode, result.stderr)
        captures = [json.loads(p.read_text()) for p in sorted(self.home.glob('capture-*.json'))]
        self.assertEqual(2, len(captures), result.stderr)
        self.assertTrue(all(c['clean'] and c['head'] == self.head for c in captures))
        self.assertEqual(captures[0]['checkout'], captures[1]['checkout'])
        self.assertTrue((self.home / 'published').exists())

    def test_dirty_vendor_fallback(self):
        # Custom unavailable adapter dirties the checkout before Codex fallback.
        self.write(self.repo / 'bin/adapters/down.sh', '''#!/bin/sh
# fm:review-run
echo scratch > "$FM_REVIEW_CHECKOUT/from-unavailable"
exit 2
''')
        (self.repo / 'config.yaml').write_text('vendor: down\nreviewer:\n  vendor: down\n  mode: run\nfallback:\n  - codex\nmodels:\n  codex: fixture-model\n')
        result = self.run_review()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(json.loads((self.home / 'capture-1.json').read_text())['clean'])
        self.assertTrue((self.home / 'published').exists())

    def test_negative_provenance_and_failure_cleanup(self):
        for mode in ('transcript', 'failed-turn', 'unavailable'):
            with self.subTest(mode=mode):
                result = self.run_review(mode)
                self.assertNotEqual(0, result.returncode, result.stderr)
                self.assertFalse((self.home / 'published').exists())
                events = [json.loads(line) for line in (self.repo / 'state/events.jsonl').read_text().splitlines()]
                self.assertNotIn('approved', [e['type'] for e in events])

    def test_policy_tampering_refuses_before_cli(self):
        result = self.run_review(FM_ADAPTER_ARGS='--cd=/')
        self.assertNotEqual(0, result.returncode)
        self.assertFalse(list(self.home.glob('capture-*.json')))
        self.assertFalse((self.home / 'published').exists())

unittest.main(argv=['codex-review-integration'], verbosity=2)
PY
