#!/usr/bin/env bash
# T-167: real adapter with a foreground CLI fixture; no model or OS sandbox.
set -euo pipefail
exec < /dev/null
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
sys.dont_write_bytecode = True
root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('managed', root / 'bin/fm-herdr.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class Availability(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name).resolve()
        code = self.home / 'code'
        (code / 'bin/adapters').mkdir(parents=True)
        for name in ['bin/fm-config.sh', 'bin/fm-herdr.py', 'bin/adapters/_lib.sh', 'bin/adapters/codex.sh']:
            shutil.copy2(root / name, code / name)
        sandbox = code / 'bin/fm-sandbox.sh'
        sandbox.write_text('''#!/usr/bin/env bash
case "$1" in
  os) echo darwin;;
  covers) echo 'write read network sockets env repo-config refuse ulimit';;
  run)
    [ "${FIXTURE_LAUNCH:-0}" = 0 ] || exit 1
    shift
    while [ "$1" != -- ]; do
      case "$1" in --started=*) printf 'started\\n' > "${1#*=}";; esac
      shift
    done
    shift
    exec "$@";;
  *) exit 99;;
esac
''')
        sandbox.chmod(0o755)
        vendor = self.home / 'tools'; vendor.mkdir()
        cli = vendor / 'codex'
        cli.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
sys.stdin.read()
sys.stdout.write(pathlib.Path(os.environ['FIXTURE_LOG']).read_text())
sys.exit(int(os.environ['FIXTURE_EXIT']))
''')
        cli.chmod(0o755)
        self.attempt = self.home / 'attempt'; self.attempt.mkdir()
        self.tree = self.home / 'tree'; self.tree.mkdir()
        self.log = self.attempt / 'cli.log'
        self.fixture = self.home / 'events'
        policy = self.home / 'policy.json'
        policy.write_text(json.dumps(dict(role='worker', write=['{root}', '{tmp}'], network=[],
                                         env_scrub=dict(names=[], prefixes=[]))))
        prompt = self.home / 'prompt'; prompt.write_text('Worker fixture')
        self.env = dict(PATH=str(vendor) + os.pathsep + os.environ['PATH'], HOME=str(self.home),
            TMPDIR=str(self.home), FM_CONTEXT_READY='1', FM_ATTEMPT_DIR=str(self.attempt),
            FM_FINAL_PATH=str(self.attempt / 'final.txt'), FM_ROLE='worker', FM_TASK='T-167',
            FM_ACTOR='worker-fixture-t167-r1', FM_POLICY=str(policy),
            FIXTURE_LOG=str(self.fixture), FIXTURE_EXIT='0')
        self.command = [str(code / 'bin/adapters/codex.sh'), 'run', str(prompt), str(self.tree), str(self.log)]

    def stream(self, quote='ENOTFOUND authentication required not logged in', answer='WORKER_COMPLETE:T-167'):
        return '\n'.join(json.dumps(e, ensure_ascii=False) for e in [
            dict(type='thread.started', thread_id='current'), dict(type='turn.started'),
            dict(type='item.completed', item=dict(id='tool', type='command_execution',
                 command='rg "ENOTFOUND" tests', aggregated_output=quote, exit_code=0, status='completed')),
            dict(type='item.completed', item=dict(id='comment', type='agent_message', text=quote)),
            dict(type='item.completed', item=dict(id='final', type='agent_message', text=answer)),
            dict(type='turn.completed', usage=dict(input_tokens=10, output_tokens=10))]) + '\n'

    def run_adapter(self, text, expected, rc=0, prefix='', **extra):
        self.fixture.write_text(text)
        self.log.write_text(prefix)
        result = subprocess.run(self.command, env=dict(self.env, FIXTURE_EXIT=str(rc), **extra),
                                capture_output=True, text=True)
        self.assertEqual(expected, result.returncode, result.stderr)
        if extra.get('FM_ATTEMPT_DIR', str(self.attempt)):
            self.assertEqual(str(rc), (self.attempt / 'cli-exit-code').read_text().strip())
        return m.cli_final('codex', self.log)

    def test_completed_worker_quotes_are_not_outages(self):
        # Fail-first: base adapter returns 2 for both observed incident shapes.
        for quote in ['\n'.join(['eNotFound'] * 6), 'authentication required; not logged in']:
            with self.subTest(quote=quote):
                final = self.run_adapter(self.stream(quote), 0)
                self.assertEqual('completed', m.completion('worker', 'T-167', final))
                self.assertEqual('unknown', m.completion('reviewer', 'T-167', final))
                self.assertEqual('unknown', m.completion('worker', 'T-old', final))

    def test_json_string_separators_preserve_composed_completion(self):
        # Literal Unicode separators are legal JSON string bytes. ASCII controls
        # must be JSON-escaped: exercise every control, including all splitlines
        # boundaries, through the real adapter and the original-log final reader.
        separators = [chr(value) for value in range(32)] + ['\x7f', '\x85', '\u2028', '\u2029']
        for separator in separators:
            quote = 'Quoted fixture:' + separator + 'authentication required ENOTFOUND' + separator + 'end quote'
            for location in ('command', 'aggregated_output', 'model', 'final'):
                with self.subTest(separator=repr(separator), location=location):
                    events = [json.loads(line) for line in self.stream().split('\n') if line]
                    answer = 'WORKER_COMPLETE:T-167'
                    if location in ('command', 'aggregated_output'):
                        events[2]['item'][location] = quote
                    elif location == 'model':
                        events[3]['item']['text'] = quote
                    else:
                        answer = quote + '\nWORKER_COMPLETE:T-167'
                        events[4]['item']['text'] = answer
                    text = '\n'.join(json.dumps(event, ensure_ascii=False) for event in events) + '\n'
                    final = self.run_adapter(text, 0)
                    self.assertEqual(answer, final)
                    self.assertEqual('completed', m.completion('worker', 'T-167', final))
                    self.assertEqual('unknown', m.completion('reviewer', 'T-167', final))
                    self.assertEqual('unknown', m.completion('worker', 'T-old', final))
                    # A completion marker in earlier payloads cannot complete
                    # a final answer which says only that it quoted a fixture.
                    events[2]['item']['aggregated_output'] = 'WORKER_COMPLETE:T-167'
                    events[3]['item']['text'] = 'WORKER_COMPLETE:T-167'
                    events[4]['item']['text'] = quote
                    text = '\n'.join(json.dumps(event, ensure_ascii=False) for event in events) + '\n'
                    final = self.run_adapter(text, 0)
                    self.assertEqual(quote, final)
                    self.assertEqual('unknown', m.completion('worker', 'T-167', final))

    def test_real_errors_and_cli_failures(self):
        for phrase in ['authentication required', 'quota exceeded', 'network error: ENOTFOUND']:
            for kind in ['error', 'turn.failed']:
                event = dict(type=kind, **({'message':phrase} if kind == 'error' else {'error':{'message':phrase}}))
                with self.subTest(kind=kind, phrase=phrase):
                    self.run_adapter(json.dumps(event) + '\n', 2)
                    self.run_adapter(self.stream() + json.dumps(event) + '\n', 2)
            self.run_adapter(phrase + '\n', 2)
        self.run_adapter(json.dumps(dict(type='turn.failed', error=dict(message='other failure'))) + '\n', 1)
        for rc, expected in [(1, 1), (2, 2), (4, 2), (41, 2), (69, 2), (75, 2)]:
            with self.subTest(rc=rc): self.run_adapter(self.stream(), expected, rc=rc)
        self.run_adapter('', 2, rc=1, FIXTURE_LAUNCH='1')

    def test_missing_partial_and_stale_evidence(self):
        (self.attempt / 'final.txt').write_text('WORKER_COMPLETE:T-167')
        for text in ['', '{"type":"turn.started"}\n',
                     self.stream().rsplit('\n', 2)[0] + '\n',
                     self.stream() + '{"type":"turn.started"}\n',
                     self.stream() + '{"type":', self.stream() + '[]\n']:
            with self.subTest(text=text): self.run_adapter(text, 1, prefix=self.stream())
        self.run_adapter(self.stream(), 0, prefix='authentication required\n')
        # A marker in tool output is not a final answer.
        events = [dict(type='turn.started'), dict(type='item.completed', item=dict(
            type='command_execution', aggregated_output='WORKER_COMPLETE:T-167')), dict(type='turn.completed')]
        self.run_adapter('\n'.join(map(json.dumps, events)) + '\n', 1)

    def test_role_status_is_final_only(self):
        for answer, status in [('WORKER_BLOCKED:T-167', 'blocked'), ('Ordinary answer', 'unknown')]:
            final = self.run_adapter(self.stream(answer=answer), 0)
            self.assertEqual(status, m.completion('worker', 'T-167', final))
        final = self.run_adapter(self.stream(answer='Quotes: authentication required\nWORKER_COMPLETE:T-167'), 0)
        self.assertEqual('completed', m.completion('worker', 'T-167', final))

    def test_legacy_contract_unchanged(self):
        self.run_adapter(self.stream(), 2, FM_ATTEMPT_DIR='')

unittest.main(argv=['codex-availability'], verbosity=2)
PY
