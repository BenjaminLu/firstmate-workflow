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

from python_programs import embedded_programs
from t177_launcher_base import SOURCES, SHA256

ROOT = Path(sys.argv.pop(1)).resolve()
BASE = ROOT / 'tests/lib/t177_sandbox_base.py'


class LauncherPython(unittest.TestCase):
    def test_no_embedded_program_longer_than_five_lines(self):
        for name in ('fm-review.sh', 'fm-sandbox.sh'):
            source = (ROOT / 'bin' / name).read_text()
            with self.subTest(script=name):
                for program in embedded_programs(source):
                    self.assertLessEqual(len(program.splitlines()), 5,
                                         'embedded Python must move to bin/lib')

    def test_guard_still_detects_programs_after_each_real_launcher(self):
        program = '\n'.join(['print(1)'] * 6)
        for name in ('fm-review.sh', 'fm-sandbox.sh'):
            source = (ROOT / 'bin' / name).read_text()
            for invocation in (f"python3 - <<'ANY_NAME'\n{program}\nANY_NAME\n",
                               f'python3 -c "{program}"\n'):
                with self.subTest(script=name, invocation=invocation):
                    self.assertIn(program, list(embedded_programs(source + '\n' + invocation)))

    def test_guard_recognizes_shell_forms_without_naming_conventions(self):
        for length in (5, 6):
            program = '\n'.join(['print(1)'] * length)
            forms = [
                f"python3 - <<PY\n{program}\nPY\n",
                f"python3 - <<EOF\n{program}\nEOF\n",
                f"python3 - <<'X'\n{program}\nX\n",
                f'python3 - <<"END"\n{program}\nEND\n',
                "python3 - <<-'TABS'\n\t" + program.replace('\n', '\n\t') + "\n\tTABS\n",
                f"python3 -c '{program}'\n",
                f'python3 -c "{program}"\n',
                f"python -c '{program}'\n",
                f"if ! python3 - \\\n  <<'CONTINUED'\n{program}\nCONTINUED\n",
                f"result=\"$(python3 -c '{program}')\"\n",
                f"arbitrary='{program}'\npython3 -c \"$arbitrary\"\n",
                f"IFS= read -r -d '' arbitrary <<'DATA'\n{program}\nDATA\npython3 -c \"$arbitrary\"\n",
                f"arbitrary=$(cat <<'SOURCE'\n{program}\nSOURCE\n)\npython3 -c \"${{arbitrary}}\"\n",
            ]
            for source in forms:
                with self.subTest(source=source):
                    programs = list(embedded_programs(source))
                    self.assertEqual([program], programs)
                    self.assertEqual(int(length > 5),
                                     sum(len(p.splitlines()) > 5 for p in programs))
            # Real launcher expressions used to crash the whole-shell tokenizer.
            # They must neither hide nor add Python programs around them.
            unrelated = r'''CREW_DATA="$(jq -cn --argjson identity "$(fm_crew_identity)" '.identity=$identity')"
listening="$(awk '$NF == "LISTEN" { n = split($4, a, /[.]/); print a[n] }' <<< "$listing" | sort -u)"
legacy="`printf '%s' "nested"`"
count=$(("$count" + 1))
unknown="unterminated shell word
'''
            self.assertEqual([program, program], list(embedded_programs(
                f"python3 -c '{program}'\n" + unrelated
                + f"python3 - <<'AFTER'\n{program}\nAFTER\n")))
        self.assertEqual([], list(embedded_programs(
            "cat <<'EOF'\nnot Python\nEOF\n# python3 -c 'comment'\n")))
        self.assertEqual([], list(embedded_programs(
            "python3 helper.py\npython3 -c 'unfinished\n")))

    def test_guard_finds_every_frozen_base_program(self):
        expected = {'fm-review.sh': [9, 1, 5],
                    'fm-sandbox.sh': [22] + [780] * 9 + [57, 22, 780]}
        sandbox = SOURCES['fm-sandbox.sh']
        payloads = {name: re.search(r"read[^\n]* " + name
                    + r" <<'PY'\n(.*?)\nPY", sandbox, re.S)[1]
                    for name in ('SB_PY', 'FWD_PY', 'LOOP_PY')}
        found = list(embedded_programs(sandbox))
        for name, count in (('SB_PY', 10), ('FWD_PY', 1), ('LOOP_PY', 2)):
            with self.subTest(program=name):
                self.assertEqual(count, found.count(payloads[name]))
        for name, source in SOURCES.items():
            with self.subTest(script=name):
                self.assertEqual(SHA256[name], hashlib.sha256(source.encode()).hexdigest())
                self.assertEqual(expected[name],
                                 [len(p.splitlines()) for p in embedded_programs(source)])
                self.assertEqual([], list(embedded_programs((ROOT / 'bin' / name).read_text())))

    def test_guard_recognizes_interpreter_words_and_assignments(self):
        program = '\n'.join(['print(1)'] * 6)
        interpreters = [('', 'python3.12'), ('', '/usr/bin/python3'),
                        ('', '"/usr/bin/python3"'), ('', '"$(command -v python3)"'),
                        ('py=/usr/bin/python3\n', '"$py"'),
                        ('py="$(command -v python3)"\n', '"${py}"'),
                        ("py='python3.12'\n", '$py')]
        for setup, interpreter in interpreters:
            for payload in (f"'{program}'", f'"{program}"', '"$payload"'):
                for context in ('{}\n', 'inner=({})\n', 'result="$({})"\n'):
                    source = setup + f"payload='{program}'\n"
                    source += context.format(f'{interpreter} -c {payload}')
                    with self.subTest(source=source):
                        self.assertEqual([program], list(embedded_programs(source)))
            source = setup + f"payload=$(cat <<'DATA'\n{program}\nDATA\n)\n"
            source += f'{interpreter} -c "$payload"\n'
            self.assertEqual([program], list(embedded_programs(source)))
            self.assertEqual([program], list(embedded_programs(
                setup + f"{interpreter} - <<'DATA'\n{program}\nDATA\n")))
        self.assertEqual([], list(embedded_programs(
            'py=python3\npayload="$(python3 "$INLINE_MODULE" "$FWD_MODULE")"\n'
            '"$py" -c "$payload"\n')))

    def test_sandbox_python_payload_positions(self):
        source = (ROOT / 'bin/fm-sandbox.sh').read_text()
        # The existing sandbox-login stand-in observes OS argv[3], before
        # Python can normalize sys.argv. Cover every policy call, not just run.
        calls = re.findall(r'python3 -- "\$SB_MODULE" ([a-z-]+)', source)
        self.assertEqual(['hosts', 'decide', 'login-source', 'login-env',
                          'profile', 'scrub', 'limits', 'login', 'proxy', 'profile'], calls)
        self.assertNotIn('"$INLINE_PY"', source)

    def test_review_python_payload_positions(self):
        source = (ROOT / 'bin/fm-review.sh').read_text()
        self.assertIn('python3 "${FM_CODE_ROOT:-$REPO}/bin/lib/fm_review_checkout_is_free.py" "${FM_CODE_ROOT:-$REPO}" "$(cat "$run_file")"', source)
        self.assertIn('python3 "${FM_CODE_ROOT:-$REPO}/bin/lib/fm_review_attempt_output.py" "${FM_CODE_ROOT:-$REPO}" "$FM_RUN_DIR" "${FM_CHAIN_ATTEMPT:-}"', source)
        self.assertIn('python3 -- "${FM_CODE_ROOT:-$REPO}/bin/lib/fm_review_network.py"', source)
        with tempfile.TemporaryDirectory() as directory:
            policy = Path(directory) / 'policy with spaces.json'
            policy.write_text('{"network": ["registry.example", "cdn.example"]}')
            result = subprocess.run([sys.executable, '--',
                str(ROOT / 'bin/lib/fm_review_network.py'), str(policy)], capture_output=True)
            self.assertEqual((0, b'registry.example cdn.example\n', b''),
                             (result.returncode, result.stdout, result.stderr))

    def test_in_sandbox_loader_preserves_arguments_and_filename(self):
        module = ROOT / 'bin/lib/fm_sandbox_loopback.py'
        # Encode source before entering the sandbox; the child cannot read it.
        filename = '/unmounted engine/lib/fm_sandbox_loopback.py'
        sys.path.insert(0, str(ROOT / 'bin/lib'))
        from fm_sandbox_inline import inline_program
        program = inline_program(module.read_text(), filename)
        argv = [sys.executable, '-c', program, 'fm-loopback-check']
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
