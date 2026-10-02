#!/usr/bin/env bash
# T-164: doctor policy reached by real setup/startup wrappers, without vendors.
set -uo pipefail
for key in $(env | sed -nE 's/^(FM_[^=]*|HERDR_[^=]*)=.*/\1/p'); do unset "$key"; done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
python3 - "$ROOT" <<'PY'
import json, os, pathlib, shutil, subprocess, sys, tempfile, unittest
sys.dont_write_bytecode = True
source = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(source / 'bin/lib'))
import fm_hooks as hooks

class Guidance(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='hook guidance ')
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        shutil.copytree(source / 'bin', self.root / 'bin')
        (self.root / 'config.yaml').write_text('vendor: novel-vendor\nreviewer:\n  vendor: claude\n')
        self.env = dict(os.environ, FM_ROOT=str(self.root), FM_HARNESS='codex', FM_CODE_ROOT=str(self.root))
    def run_cmd(self, script, *args, env=None):
        return subprocess.run(['bash', str(self.root / 'bin' / script), *args], cwd=self.root,
                              env=env or self.env, input='', text=True, capture_output=True)
    def doctor(self):
        result = self.run_cmd('fm-doctor.sh', '--hooks-only', '--repo', str(self.root))
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout
    def test_doctor_registry_native_guidance_and_no_false_readiness(self):
        out = self.doctor()
        for word in ('claude', 'codex', 'cursor-agent', 'gemini', 'novel-vendor',
                     'SessionStart', 'UserPromptSubmit', 'Stop', '/hooks',
                     'disableAllHooks', 'Customize', 'foreground', 'delivery=unverified'):
            self.assertIn(word, out)
        self.assertIn('configuration=missing', out)
        self.assertFalse((self.root / '.codex').exists())
        hooks.hooks_change(self.root, 'codex', True)
        out = self.doctor()
        self.assertIn('configuration=installed', out)
        self.assertIn('loading=unverified', out)
        self.assertIn('changed hashes', out)
    def test_disabled_custom_config_preserved_and_malformed_reported(self):
        hooks.hooks_change(self.root, 'claude', True)
        path = self.root / '.claude/settings.local.json'
        data = json.loads(path.read_text()); data['disableAllHooks'] = True
        data['custom'] = 'keep'; path.write_text(json.dumps(data))
        before = path.read_bytes()
        self.assertIn('locally-disabled', self.doctor())
        self.assertEqual(before, path.read_bytes())
        path.write_text('{broken')
        self.assertIn('configuration=unreadable', self.doctor())
    def test_primary_start_reaches_doctor_and_crew_stays_quiet(self):
        # Isolate unrelated session/board startup; the actual shell hook/doctor path runs.
        (self.root / 'bin/fm-herdr.py').write_text('pass\n')
        config = self.root / 'bin/fm-config.sh'
        with config.open('a') as out: out.write('\nfm_freeze() { :; }\n')
        result = self.run_cmd('fm-session.sh', 'start')
        self.assertIn('Necessary agent hooks', result.stderr)
        self.assertIn('delivery=unverified', result.stderr)
        crew = self.run_cmd('fm-session.sh', 'start', env=dict(self.env, FM_IN_ROUND='1'))
        self.assertNotIn('Necessary agent hooks', crew.stderr)
        claude = self.run_cmd('fm-session.sh', 'start', env=dict(self.env, FM_HARNESS='claude'))
        self.assertIn('Claude Code: review local settings', claude.stderr)
        self.assertTrue((self.root / '.claude/settings.local.json').is_file())
    def test_setup_facts_reaches_real_doctor_without_canary_or_prompt(self):
        facts = self.root / 'facts'; facts.write_text('vendor\tclaude\tauthenticated\n')
        answers = self.root / 'answers'
        answers.write_text('worker_vendor: claude\nreviewer_vendor: codex\nbilling_claude: subscription\nbilling_codex: subscription\nrepo_github: example/repo\nrepo_base: main\nboard_port: 4173\nlanguage: en\n')
        (self.root / 'bin/fm-herdr.py').write_text('pass\n')
        result = self.run_cmd('fm-setup.sh', '--answers', str(answers), '--facts', str(facts))
        self.assertIn('Necessary agent hooks', result.stdout)
        self.assertIn('claude:', result.stdout)
        self.assertNotIn('Sandbox reality check', result.stdout)
        self.assertFalse((self.root / '.claude').exists())
        self.assertNotIn('Which installed vendor', result.stderr)

unittest.main(argv=['hook-guidance'], verbosity=2)
PY
assert_eq 0 "$?" "doctor, startup and setup reach native hook guidance without asserting readiness"
finish
