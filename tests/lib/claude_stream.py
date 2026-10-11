"""T-287: a claude round streams its steps, and keeps its final result.

The rounds here are real ones: bin/adapters/claude.sh, run as a worker round
under bin/fm-herdr.py's transport (the runner, run.log, cli.log, final.txt,
result.json), with tests/lib/claude_stream_stub.py as the claude CLI on PATH.
The stub reads the output flag the adapter gives it: on the base that is
`--output-format json` and it prints one object at the end; with T-287 it is
`--output-format stream-json --verbose` and it streams events with delays.
Only the OS sandbox is a stand-in (tests/lib/adapter.sh's), as in every
adapter suite.

`steps appear while running` and `malformed line is incomplete` fail on the
base; the other three are regression checks.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1)).resolve()
STUB = ROOT / 'tests/lib/claude_stream_stub.py'
ADAPTER = ROOT / 'bin/adapters/claude.sh'
WAIT = 120


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


herdr = load('managed', ROOT / 'bin/fm-herdr.py')
runtime = load('fm_config_runtime', ROOT / 'bin/lib/fm_config_runtime.py')
metrics = load('fm_round_metrics', ROOT / 'bin/lib/fm_round_metrics.py')


def vendor_model(log):
    """bin/fm-config.sh's fm_vendor_model, the run's model record, on <log>."""
    done = subprocess.run([sys.executable, str(ROOT / 'bin/lib/fm_config_runtime.py'), 'vendor-model', ''],
                          input=Path(log).read_text(), capture_output=True, text=True, timeout=WAIT)
    return done.stdout.strip()


def eventually(predicate, seconds=WAIT):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = predicate()
        if value: return value
        time.sleep(0.05)
    return predicate()


class ClaudeStream(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='claude-stream-')).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.root = self.tmp / 'engine'
        (self.root / 'state/runs').mkdir(parents=True)
        (self.root / 'config.yaml').write_text('vendor: claude\n')
        self.tree = self.tmp / 'tree'
        self.tree.mkdir()
        (self.tree / 'notes.txt').write_text('the notes\n')
        # a worktree, so the follow view can show an edit as its diff
        git = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull)
        for args in (['init', '-q'], ['add', 'notes.txt'],
                     ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'commit', '-qm', 'base']):
            subprocess.run(['git', '-C', str(self.tree), *args], env=git, check=True, capture_output=True,
                           timeout=WAIT)
        fake = self.tmp / 'fakebin'
        fake.mkdir()
        (fake / 'claude').write_text('#!' + sys.executable + '\n' + STUB.read_text())
        (fake / 'claude').chmod(0o755)
        self.gates = self.tmp / 'gates'
        self.gates.mkdir()
        (self.tmp / 'prompt').write_text('do the thing\n')
        self.addCleanup(self.release)
        self.env = dict(os.environ, PATH=str(fake) + os.pathsep + os.environ['FM_TEST_CLOSED_PATH'],
                        FM_ROOT=str(self.root), FM_CODE_ROOT=str(ROOT), FM_SESSION_PID=str(os.getpid()),
                        FM_TRANSPORT='direct', HERDR_ENV='0', FM_HEARTBEAT_SECS='0',
                        FM_ROLE='worker', FM_TASK='T-287', FM_TEST_DELAY='0.05')
        for name in ('FM_RUN_DIR', 'FM_ATTEMPT_DIR', 'FM_CONTEXT_READY', 'FM_FINAL_PATH', 'FM_MODEL'):
            self.env.pop(name, None)

    def release(self):
        for n in range(1, 20): (self.gates / ('go-%d' % n)).touch()

    def stub(self, fmt, shape='complete', **env):
        """The stub run on its own, with the flags the adapter gives it."""
        flags = ['--output-format', 'json'] if fmt == 'json' else ['--output-format', 'stream-json', '--verbose']
        return subprocess.run([str(self.tmp / 'fakebin/claude'), '-p', *flags], cwd=self.tree, input='prompt',
                              capture_output=True, text=True, timeout=WAIT,
                              env=dict(self.env, FM_TEST_SHAPE=shape, **env)).stdout

    def start(self, shape='complete', gated=False):
        """A worker round through the adapter and the runner; (process, run dir)."""
        done = subprocess.run([sys.executable, str(ROOT / 'bin/fm-herdr.py'), 'allocate', str(self.root),
                               'worker', 'T-287', 'Ada'], env=self.env, capture_output=True, text=True,
                              timeout=WAIT)
        self.assertEqual(0, done.returncode, done.stderr)
        run = Path(done.stdout.strip())
        env = dict(self.env, FM_RUN_DIR=str(run), FM_ACTOR=run.name, FM_TEST_SHAPE=shape)
        if gated: env['FM_TEST_GATES'] = str(self.gates)
        log = open(self.tmp / 'adapter.out', 'ab')
        self.addCleanup(log.close)
        proc = subprocess.Popen(['bash', str(ADAPTER), 'run', str(self.tmp / 'prompt'), str(self.tree),
                                 str(self.tmp / 'round.log')], env=env, stdin=subprocess.DEVNULL,
                                stdout=log, stderr=subprocess.STDOUT)
        self.addCleanup(lambda: proc.poll() is None and (self.release(), proc.wait(timeout=WAIT)))
        return proc, run

    def finish(self, proc, run):
        self.release()
        code = proc.wait(timeout=WAIT)
        attempts = [p for p in run.glob('claude-*') if p.is_dir()]
        self.assertEqual(1, len(attempts), (self.tmp / 'adapter.out').read_text())
        attempt = attempts[0]
        result = json.loads((attempt / 'result.json').read_text())
        final = attempt / 'final.txt'
        (run / 'coverage.json').write_text('{}')
        return dict(code=code, attempt=attempt, status=result['status'], exit_code=result['exit_code'],
                    final=final.read_text() if final.exists() else None,
                    model=vendor_model(attempt / 'cli.log'),
                    turns=metrics.metrics(run, time.time())['turns'])

    def test_steps_appear_while_running(self):
        """claude stream: steps appear while running"""
        for n in range(1, 5): (self.gates / ('go-%d' % n)).touch()
        proc, run = self.start(gated=True)
        # held after its command (step 5): the round is running, and its
        # earlier steps are already in the run log
        self.assertTrue(eventually(lambda: (self.gates / 'at-5').exists()), 'the round never started')
        log = next(iter(run.glob('claude-*/run.log')))
        shown = eventually(lambda: '"name":"Bash"' in log.read_text() and log.read_text(), 10)
        self.assertTrue(shown, 'no step in the run log while the round runs: %r' % log.read_text())
        self.assertIsNone(proc.poll(), 'the round is still running')
        self.assertFalse((log.parent / 'result.json').exists())
        self.assertIn('"name":"Read"', shown)
        self.assertIn(str(self.tree / 'notes.txt'), shown)
        self.assertIn('ls -1 stream-probe', shown)
        self.assertIn('I will read the notes first.', shown)
        self.assertNotIn('WORKER_COMPLETE', shown)
        # and the follow view says what it does now
        view = herdr.follow_view()
        os.environ.pop('FM_FOLLOW_QUIET', None)
        now = view.Round(log.parent, herdr.follow_probe())
        now.feed(now.read_log())
        self.assertEqual('running a command: ls -1 stream-probe', now.activity())
        out = self.finish(proc, run)
        self.assertEqual('completed', out['status'])
        shown = subprocess.run([sys.executable, str(ROOT / 'bin/fm-herdr.py'), 'follow', str(out['attempt'])],
                               env=dict(self.env, NO_COLOR='1'), capture_output=True, text=True,
                               timeout=WAIT).stdout
        for said in ('read ' + str(self.tree / 'notes.txt'), '$ ls -1 stream-probe', '  one', '  two',
                     '> I will read the notes first.', 'diff of work.txt against HEAD', '+done',
                     '> WORKER_COMPLETE:T-287'):
            self.assertIn(said, shown)
        self.assertEqual(1, shown.count('WORKER_COMPLETE:T-287'), 'the result is not shown twice')
        self.assertNotIn('{"type":', shown)

    def test_final_result_unchanged(self):
        """claude stream: final result unchanged"""
        old = self.tmp / 'old.log'
        old.write_text(self.stub('json'))
        self.assertEqual(1, len(old.read_text().splitlines()), 'the old format is one object')
        verdict = subprocess.run(['bash', '-c', '. "$1/bin/adapters/_lib.sh"; fm_adapter_verdict 0 "$2" 0',
                                  'verdict', str(ROOT), str(old)], env=self.env, capture_output=True,
                                 timeout=WAIT).returncode
        run_dir = self.tmp / 'old-run'
        (run_dir / 'old').mkdir(parents=True)
        (run_dir / 'identity.json').write_text(json.dumps(dict(created=time.time())))
        (run_dir / 'coverage.json').write_text('{}')
        (run_dir / 'old/invocation.json').write_text('{}')
        shutil.copy(old, run_dir / 'old/cli.log')
        answer = herdr.cli_final('claude', old)
        expected = dict(code=verdict, exit_code=verdict, final=answer,
                        status=herdr.completion('worker', 'T-287', answer),
                        model=vendor_model(old), turns=metrics.metrics(run_dir, time.time())['turns'])
        self.assertEqual(dict(code=0, exit_code=0, final='Implemented the change and checked it.\n\n'
                              'WORKER_COMPLETE:T-287', status='completed', model='claude-opus-5-5', turns=4),
                         expected)
        out = self.finish(*self.start())
        self.assertEqual(expected, {key: out[key] for key in expected})

    def assert_incomplete(self, out):
        self.assertIsNone(out['final'], 'no final answer is recorded')
        self.assertNotEqual('completed', out['status'])
        last = json.loads((out['attempt'].parent / 'last-result.json').read_text())
        self.assertNotEqual('completed', last['status'])

    def test_cut_off_stream_is_incomplete(self):
        """claude stream: cut-off stream is incomplete"""
        self.assert_incomplete(self.finish(*self.start('cutoff')))
        cut = self.tmp / 'cut.log'
        cut.write_text(self.stub('stream-json', 'cutoff'))
        self.assertIn('"type":"assistant"', cut.read_text())
        self.assertIsNone(herdr.cli_final('claude', cut))

    def test_malformed_line_is_incomplete(self):
        """claude stream: malformed line is incomplete"""
        self.assert_incomplete(self.finish(*self.start('malformed')))
        # in the stream itself: a cut-off event line, then a valid result
        bad = self.tmp / 'bad.log'
        bad.write_text(self.stub('stream-json', 'malformed'))
        lines = bad.read_text().splitlines()
        self.assertEqual('result', json.loads(lines[-1])['type'])
        self.assertTrue(any(l.startswith('{') and not self.parses(l) for l in lines))
        self.assertIsNone(herdr.cli_final('claude', bad))
        # lines that do not start with `{` are skipped, and the last result counts
        good = self.tmp / 'good.log'
        stream = self.stub('stream-json').splitlines()
        failed = dict(json.loads(stream[-1]), is_error=True, result='API Error')
        good.write_text('\n'.join(['fm-sandbox: login from the crew token',
                                   'Connection lost, reconnecting (attempt 1)...', *stream]) + '\n')
        self.assertEqual('Implemented the change and checked it.\n\nWORKER_COMPLETE:T-287',
                         herdr.cli_final('claude', good))
        good.write_text('\n'.join([*stream, json.dumps(failed)]) + '\n')
        self.assertIsNone(herdr.cli_final('claude', good))

    def test_outage_read_from_notices_only(self):
        """claude stream: outage read from notices only"""
        log = self.tmp / 'outage.log'

        def verdict(rc, *lines):
            log.write_text('\n'.join(lines) + '\n')
            return subprocess.run(['bash', '-c', '. "$1/bin/adapters/_lib.sh"; fm_adapter_verdict "$3" "$2" 0 claude',
                                   'verdict', str(ROOT), str(log), str(rc)], env=self.env,
                                  capture_output=True, timeout=WAIT).returncode
        stream = self.stub('stream-json').splitlines()
        read = json.dumps({'type': 'user', 'message': {'role': 'user', 'content': [
            {'tool_use_id': 't', 'type': 'tool_result', 'content': 'rate limit exceeded: 401 unauthorized'}]}})
        self.assertEqual(0, verdict(0, stream[0], read, *stream[1:]), 'a file it reads is not an outage')
        failed = json.dumps(dict(json.loads(stream[-1]), is_error=True,
                                 result='API Error: 429 Too Many Requests, rate limit exceeded'))
        self.assertEqual(2, verdict(1, stream[0], failed), 'a result event still reports an outage')
        self.assertEqual(2, verdict(1, stream[0], 'Error: not logged in'), 'and so does a non-JSON notice')

    @staticmethod
    def parses(text):
        try: json.loads(text)
        except ValueError: return False
        return True

    def test_silence_from_last_step(self):
        """claude stream: silence from last step"""
        attempt = self.root / 'state/runs/worker-ada-t287-r1/claude-live'
        attempt.mkdir(parents=True)
        (attempt / 'invocation.json').write_text(json.dumps(dict(
            adapter=str(ADAPTER), tree=str(self.tree), actor='worker-ada-t287-r1', role='worker', task='T-287')))
        log = attempt / 'run.log'
        with log.open('ab') as out:
            proc = subprocess.Popen([str(self.tmp / 'fakebin/claude'), '-p', '--output-format', 'stream-json',
                                     '--verbose'], cwd=self.tree, stdin=subprocess.DEVNULL, stdout=out,
                                    env=dict(self.env, FM_TEST_GATES=str(self.gates), FM_TEST_DELAY='0'))
        self.addCleanup(lambda: proc.poll() is None and (self.release(), proc.wait(timeout=WAIT)))
        os.environ['FM_FOLLOW_QUIET'] = '0'
        self.addCleanup(os.environ.pop, 'FM_FOLLOW_QUIET', None)
        view = herdr.follow_view()
        now = view.Round(attempt, herdr.follow_probe())
        self.assertTrue(eventually(lambda: '"subtype":"init"' in log.read_text()))
        now.feed(now.read_log())
        time.sleep(1.5)
        self.assertGreaterEqual(now.silence(), 1.5)
        self.assertEqual('possibly stuck', now.row(False, True, 1.0)[-1])
        for n in (1, 2):  # its text, then the file it reads
            (self.gates / ('go-%d' % n)).touch()
            self.assertTrue(eventually(lambda: len(log.read_text().splitlines()) >= n + 1))
        now.feed(now.read_log())
        self.assertLess(now.silence(), 1.0, 'silence counts from the latest step')
        self.assertEqual('', now.row(False, True, 1.0)[-1])
        self.release()
        proc.wait(timeout=WAIT)


unittest.main(argv=['claude-stream', *os.environ.get('FM_TEST_CASES', '').split()], verbosity=2)
