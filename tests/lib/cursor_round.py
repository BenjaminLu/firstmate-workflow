"""T-219 fixtures consumed literally by adapter-protocol.test.sh; no live vendors."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT, PK, CLOSED = map(Path, sys.argv[1:4])
OLD_ADAPTER, OLD_LIBRARY = map(Path, sys.argv[4:6])
MESSAGE = 'You’ve hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Oct 10th, 2026 7:58 AM.'
CAPTURED = ('{"type":"error","message":"' + MESSAGE + '"}\n'
            '{"type":"turn.failed","error":{"message":"' + MESSAGE + '"}}\n')
REFUSAL = 'cursor-agent: cannot make a short data directory for cursor; refusing the round'


class CursorRound(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()
        self.code = self.home / 'code'
        shutil.copytree(ROOT / 'bin', self.code / 'bin',
                        ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
        self.tools = self.home / 'tools'
        self.tools.mkdir()
        self.tree = self.home / 'tree'
        self.tree.mkdir()
        self.prompt = self.home / 'prompt'
        self.prompt.write_text('Reply with exactly: OK')
        self.long_tmp = self.home / ('long-caller-' + 'x' * 100)
        self.long_tmp.mkdir()
        self.record = self.home / 'record'
        self.record.mkdir()
        # A deliberately broken cleanup must fail assertions without leaking
        # the test's allocations into later cases.
        self.addCleanup(self.cleanup_allocations)
        self.events = self.home / 'events'
        self.events.write_text(CAPTURED)
        self.hook = self.home / 'hook.sh'
        # Hooks observe real allocations. pwd injects failure/signal only after
        # allocation has returned and the adapter has installed its EXIT trap.
        self.hook.write_text('''mktemp() {
  if [ "$*" = '-d /tmp/fmc.XXXXXX' ] && [ "${CASE:-}" = mktemp ]; then return 1; fi
  local made
  made="$("$REAL_MKTEMP" "$@")" || return $?
  printf '%s\\n' "$made" >> "$RECORD/allocations"
  printf '%s\\n' "$made"
}
pwd() {
  case "$PWD" in /tmp/fmc.*|/private/tmp/fmc.*)
    case "${CASE:-}" in
      long) printf '/%0100d\\n' 0; return;;
      term) kill -TERM "$$";;
    esac;;
  esac
  builtin pwd "$@"
}
case "$0:${1-}" in */fm-sandbox.sh:run|*/fm-sandbox.sh:plain)
  printf '%s\\n' "$@" > "$RECORD/launch";;
esac
''')
        cursor = self.tools / 'cursor-agent'
        cursor.write_text('''#!/usr/bin/env python3
import hashlib, json, os, pathlib, re, sys
if '--list-models' in sys.argv:
    sys.exit(1)
sys.stdin.read()
record = pathlib.Path(os.environ['RECORD'])
base = os.environ.get('CURSOR_DATA_DIR') or os.environ['HOME'] + '/.cursor'
candidate = base + '/projects'
if len(candidate) > 84:
    candidate = base
    if len(candidate) > 84:
        candidate = '/tmp/.cursor'
project = str(pathlib.Path.cwd()).replace('/', '-')
project_dir = candidate + '/' + project
if len(project_dir) > 92:
    project_dir = project_dir[:84] + '-' + hashlib.sha256(project_dir.encode()).hexdigest()[:7]
launch = (record / 'launch').read_text().splitlines()
pk = pathlib.Path(os.environ['PROFILE_ROOT'])
if launch[0] == 'plain':
    roots = [base]
elif os.environ['FM_SANDBOX_OS'] == 'darwin':
    roots = []
    for line in (pk / 'profile.sb').read_text().splitlines():
        if line.startswith('(allow file-write* '):
            roots += re.findall(r'\\(subpath "([^"]*)"\\)', line)
else:
    args = (pk / 'bwrap.args').read_text().splitlines()
    roots = [args[i+1] for i, arg in enumerate(args[:-1]) if arg == '--bind']
allowed = any(project_dir.startswith(root.rstrip('/') + '/') for root in roots)
data = dict(data=os.environ.get('CURSOR_DATA_DIR', ''), candidate=candidate,
            directory=project_dir, roots=roots, allowed=allowed)
if os.environ.get('CURSOR_DATA_DIR'):
    st = pathlib.Path(base).stat()
    data.update(mode=st.st_mode & 0o777, owner=st.st_uid)
(record / 'vendor.json').write_text(json.dumps(data))
if not allowed:
    print("Error: EPERM: operation not permitted, mkdir '" + project_dir + "'")
    sys.exit(1)
# The fake sandbox does not enforce boundaries: never write before this check.
pathlib.Path(project_dir).mkdir(parents=True, exist_ok=True)
print('OK')
sys.exit(int(os.environ.get('VENDOR_EXIT', '0')))
''')
        cursor.chmod(0o755)
        codex = self.tools / 'codex'
        codex.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
sys.stdin.read()
sys.stdout.write(pathlib.Path(os.environ['EVENTS']).read_text())
sys.exit(1)
''')
        codex.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.tools) + os.pathsep + str(CLOSED),
                        HOME=str(PK / 'home'), TMPDIR=str(self.long_tmp), FM_CONTEXT_READY='1',
                        FM_POLICY=str(PK / 'none.json'), RECORD=str(self.record),
                        BASH_ENV=str(self.hook), REAL_MKTEMP=shutil.which('mktemp'),
                        PYTHONDONTWRITEBYTECODE='1',
                        PROFILE_ROOT=str(PK), EVENTS=str(self.events), FM_MODEL='',
                        CURSOR_DATA_DIR=str(self.home / 'inherited'), FM_ADAPTER_ARGS='')
        for key in ('FM_ATTEMPT_DIR', 'FM_FINAL_PATH', 'FM_RUN_REVIEW', 'FM_IN_ROUND',
                    'FM_ROUND_UNSANDBOXED', 'FM_CODE_ROOT'):
            self.env.pop(key, None)

    def run_adapter(self, os_name='darwin', code=None, vendor='cursor-agent', **extra):
        self.cleanup_allocations()
        for file in self.record.iterdir():
            file.unlink()
        log = self.home / 'log'
        log.write_text('')
        tool = PK / ('sandbox-exec' if os_name == 'darwin' else 'bwrap')
        env = dict(self.env, FM_SANDBOX_OS=os_name, FM_SANDBOX_TOOL=str(tool))
        env['FM_CODE_ROOT'] = str(code or self.code)
        env.update(extra)
        result = subprocess.run([str((code or self.code) / 'bin/adapters' / (vendor + '.sh')),
                                 'run', str(self.prompt), str(self.tree), str(log)],
                                env=env, capture_output=True, text=True, timeout=30)
        return result

    def cleanup_allocations(self):
        receipt = self.record / 'allocations'
        if receipt.exists():
            for path in receipt.read_text().splitlines():
                shutil.rmtree(path, ignore_errors=True)

    def allocations_cleaned(self, cursor=True):
        paths = (self.record / 'allocations').read_text().splitlines()
        for prefix in ('fm-round.', 'fm-ctl.') + (('fmc.',) if cursor else ()):
            matches = [Path(p) for p in paths if Path(p).name.startswith(prefix)]
            self.assertEqual(1, len(matches), (prefix, paths))
            # Round/control cleanup is an unchanged guard; Cursor cleanup is new.
            self.assertFalse(matches[0].exists(), str(matches[0]))

    def test_short_private_writable_and_cleaned(self):
        for platform in ('darwin', 'linux'):
            for rc in (0, 1):
                with self.subTest(platform=platform, rc=rc):
                    result = self.run_adapter(platform, VENDOR_EXIT=str(rc))
                    self.assertEqual(rc, result.returncode, result.stderr)
                    seen = json.loads((self.record / 'vendor.json').read_text())
                    self.assertRegex(seen['data'], r'^(/private)?/tmp/fmc\.[A-Za-z0-9]+$')
                    self.assertLessEqual(len(seen['data'] + '/projects'), 84)
                    self.assertEqual(0o700, seen['mode'])
                    self.assertEqual(os.getuid(), seen['owner'])
                    self.assertNotEqual(self.env['CURSOR_DATA_DIR'], seen['data'])
                    self.assertIn('--write=' + seen['data'], (self.record / 'launch').read_text().splitlines())
                    self.assertTrue(seen['allowed'])
                    self.assertNotIn('/tmp', seen['roots'])
                    self.assertNotIn('/private/tmp', seen['roots'])
                    self.assertNotIn('/tmp/.cursor', seen['roots'])
                    self.allocations_cleaned()

    def test_refused_allocations(self):
        for case in ('mktemp', 'long'):
            with self.subTest(case=case):
                result = self.run_adapter(CASE=case)
                self.assertEqual(70, result.returncode, result.stderr)
                self.assertEqual(REFUSAL, result.stderr.strip())
                self.assertFalse((self.record / 'vendor.json').exists())
                self.allocations_cleaned(cursor=case != 'mktemp')

    def test_confine_refusal_and_term_cleanup(self):
        for extra, expected in (({'FM_SANDBOX_TOOL':str(self.home / 'missing')}, 2),
                                ({'CASE':'term'}, 143)):
            with self.subTest(extra=extra):
                result = self.run_adapter(**extra)
                self.assertEqual(expected, result.returncode, result.stderr)
                self.assertFalse((self.record / 'vendor.json').exists())
                self.allocations_cleaned()

    def test_plain_launch_has_no_write_grant(self):
        result = self.run_adapter(FM_ROUND_UNSANDBOXED='1')
        self.assertEqual(0, result.returncode, result.stderr)
        launch = (self.record / 'launch').read_text().splitlines()
        self.assertEqual('plain', launch[0])
        self.assertFalse(any(arg.startswith('--write=') for arg in launch))
        self.assertRegex(json.loads((self.record / 'vendor.json').read_text())['data'],
                         r'^(/private)?/tmp/fmc\.[A-Za-z0-9]+$')
        self.allocations_cleaned()

    def test_retained_old_and_new_snapshots(self):
        old = self.home / 'old-snapshot'
        shutil.copytree(self.code, old)
        # Immutable pre-change baseline; never reconstruct old behavior by
        # stripping arbitrary lines out of the implementation under test.
        # Exact files from 2b8826dc26ef94722dc05acb0f7293c0b21aab93,
        # checked in as fixtures so shallow CI needs no historical git objects.
        for fixture in (OLD_ADAPTER, OLD_LIBRARY):
            (old / 'bin/adapters' / fixture.name).write_bytes(fixture.read_bytes())
        def digest(code):
            return {str(p.relative_to(code)):hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in code.rglob('*') if p.is_file()}
        before = digest(old)
        # Guards: long round HOME still triggers the old fallback, and the
        # old classifier still returns 1. The exact same CLI stub serves both.
        for snapshot, expected_cursor, expected_codex in ((old, 1, 1), (self.code, 0, 2)):
            result = self.run_adapter(code=snapshot, CURSOR_DATA_DIR='')
            self.assertEqual(expected_cursor, result.returncode, result.stderr)
            seen = json.loads((self.record / 'vendor.json').read_text())
            if snapshot == old:
                self.assertEqual('/tmp/.cursor', seen['candidate'])
                self.assertFalse(seen['allowed'])
                self.assertIn("Error: EPERM: operation not permitted, mkdir '", (self.home / 'log').read_text())
            else:
                self.assertTrue(seen['data'])  # fail-first updated snapshot
                self.allocations_cleaned()
            result = self.run_adapter(code=snapshot, vendor='codex')
            self.assertEqual(expected_codex, result.returncode, result.stderr)
        self.assertEqual(before, digest(old), 'retained snapshot stays byte-identical')


if __name__ == '__main__':
    unittest.main(argv=['cursor-round'], verbosity=2)
