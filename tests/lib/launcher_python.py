"""T-177 compatibility checks; no vendor, OS sandbox or background process."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv.pop(1)).resolve()
BASE = ROOT / 'tests/lib/t177_sandbox_base.py'


class LauncherPython(unittest.TestCase):
    def test_no_embedded_program_longer_than_five_lines(self):
        for name in ('fm-review.sh', 'fm-sandbox.sh'):
            source = (ROOT / 'bin' / name).read_text()
            # Both directly executed and variable-held Python heredocs.
            blocks = re.finditer(r"<<['\"]?(PY\w*)['\"]?[^\n]*\n(.*?)\n\1\n",
                                 source, re.S)
            for block in blocks:
                with self.subTest(script=name, delimiter=block[1]):
                    self.assertLessEqual(len(block[2].splitlines()), 5,
                                         'embedded Python must move to bin/lib')
            for block in re.finditer(r"python3[^\n]*? -c '([^']*)'", source, re.S):
                self.assertLessEqual(len(block[1].splitlines()), 5)
            for block in re.finditer(r"\b\w+_PY=(['\"])(.*?)\1", source, re.S):
                self.assertLessEqual(len(block[2].splitlines()), 5)

    def test_in_sandbox_loader_preserves_arguments_and_filename(self):
        source = (ROOT / 'bin/fm-sandbox.sh').read_text()
        loader = re.search(r"^INLINE_PY='([^']*)'$", source, re.M)
        self.assertIsNotNone(loader, 'in-sandbox module loader is required')
        module = ROOT / 'bin/lib/fm_sandbox_loopback.py'
        # This filename is deliberately unavailable: loading must not require
        # any engine read grant or a writable copy inside the round.
        filename = '/unmounted engine/lib/fm_sandbox_loopback.py'
        argv = [sys.executable, '-c', loader[1], module.read_text(), filename,
                'fm-loopback-check']
        result = subprocess.run(argv, capture_output=True)
        self.assertEqual((0, b'checked\n', b''),
                         (result.returncode, result.stdout, result.stderr))
        result = subprocess.run([*argv, 'invalid-port'], capture_output=True)
        self.assertNotEqual(0, result.returncode)
        self.assertIn(filename.encode(), result.stderr)
        self.assertIn(b'invalid-port', result.stderr)

    def test_reference_is_frozen(self):
        body = BASE.read_bytes().split(b'\n', 2)[2]
        self.assertEqual('179015cc4fcfa63a15f6804788d8cc3573c6476017fced8c1dda8d0e54fa31a6', hashlib.sha256(body).hexdigest())

    def test_every_adapter_profile_is_byte_identical(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory).resolve()
            tree = home / 'checkout with spaces'; tree.mkdir()
            temp = home / 'round-temp'; temp.mkdir()
            extra = home / 'extra-write'; extra.mkdir()
            run = home / 'state/runs/fixture'; run.mkdir(parents=True)
            pinned = run / 'pinned'; pinned.mkdir(mode=0o755)
            spec = pinned / 'spec.json'; spec.write_text('{}'); spec.chmod(0o444)
            (tree / '.codex').mkdir()
            (tree / '.env').write_text('private fixture')
            gitdir = home / 'git/worktrees/fixture'; gitdir.mkdir(parents=True)
            (gitdir / 'commondir').write_text('../..')
            (tree / '.git').write_text('gitdir: ' + str(gitdir))
            config = home / 'config.yaml'
            config.write_text('vendor: mock\npolicy:\n  network: registry.npmjs.org\n')
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(('FM_', 'HERDR_', 'CODEX_', 'XDG_', 'GIT_'))}
            env.update(HOME=str(home), TMPDIR=str(temp), HERDR_ENV='0', FM_PORT='4317')
            adapters = sorted(p.stem for p in (ROOT / 'bin/adapters').glob('*.sh')
                              if not p.name.startswith('_'))
            self.assertEqual(['claude', 'codex', 'cursor-agent', 'gemini', 'mock'], adapters)
            for role in ('worker', 'reviewer'):
                if role == 'reviewer':
                    (tree / '.git').unlink()
                    (tree / '.git').mkdir()
                policy = home / (role + '.json')
                generated = subprocess.run(['bash', '-c',
                    '. "$1/bin/fm-config.sh"; fm_policy "$2" "" "$3"',
                    '_', str(ROOT), role, str(config)], env=env, capture_output=True)
                self.assertEqual(0, generated.returncode, generated.stderr)
                document = json.loads(generated.stdout)
                if role == 'reviewer':
                    document['review_git_readonly'] = True
                policy.write_text(json.dumps(document))
                for vendor in adapters:
                    for platform in ('darwin', 'linux'):
                        for listeners, grant in (('', False), ('4317,5511', True), ('unknown', True)):
                            case_env = dict(env, FM_SANDBOX_OS=platform)
                            if grant:
                                case_env.update(FM_PINNED_DIR=str(pinned), FM_RUN_DIR=str(run))
                            if listeners == 'unknown':
                                case_env['FM_EXTERNAL'] = '1'
                            before = subprocess.run([sys.executable, str(BASE), 'profile',
                                str(policy), platform, str(tree), str(temp), vendor, '9123',
                                listeners, '', str(extra)], env=case_env, capture_output=True)
                            after = subprocess.run(['bash', str(ROOT / 'bin/fm-sandbox.sh'),
                                'profile', '--policy=' + str(policy), '--root=' + str(tree),
                                '--tmp=' + str(temp), '--vendor=' + vendor,
                                '--proxy-port=9123', '--listening=' + listeners,
                                '--write=' + str(extra)], env=case_env, capture_output=True)
                            with self.subTest(role=role, vendor=vendor, platform=platform,
                                              listeners=listeners, pinned=grant):
                                self.assertEqual(0, before.returncode, before.stderr)
                                self.assertEqual((before.returncode, before.stdout, before.stderr),
                                                 (after.returncode, after.stdout, after.stderr))


if __name__ == '__main__':
    unittest.main()
