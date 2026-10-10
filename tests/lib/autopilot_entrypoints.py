"""Shell orchestration boundaries; all external effects are fixture-local."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1))
os.environ['HERDR_ENV'] = '0'


class Entrypoints(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.bin = self.root/'bin'
        (self.bin/'lib').mkdir(parents=True)
        self.env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        self.env.update(FM_ROOT=str(self.root), FM_CODE_ROOT=str(self.root),
                        FIRSTMATE_CI_SESSION=str(os.getpid()), FM_AUTOPILOT_TEST_ENABLE='1')
        # Actual shell parser, storage resolver and option guards.
        for name in ('fm.sh', 'fm-autopilot.sh', 'fm-session.sh', 'fm-config.sh', 'fm-herdr.py', 'fm-emit.sh'):
            shutil.copy2(ROOT/'bin'/name, self.bin/name)
        for name in ('fm_registry.py', 'fm_config_values.py', 'fm_config_tasks.py', 'fm_config_runtime.py',
                     'fm-task-grammar.sh', 'fm-stack.sh', 'fm_project_paths.py', 'fm_spec_pins.py', 'fm_concurrent.py', 'fm_merge_outcome.py',
                     'fm_host.py', 'fm_hooks.py', 'fm-ssh-transfer.sh', 'fm_git_transfer.py'):
            shutil.copy2(ROOT/'bin/lib'/name, self.bin/'lib'/name)
        (self.root/'config.yaml').write_text('project:\n  check: "true"\n')

    def run_shell(self, script, *args, frozen=False):
        argv = ['bash', str(self.bin/script), *args, '--repo', str(self.root)]
        if frozen:
            # Session start's side-effect wiring is isolated from the board and
            # hook installers. The lifecycle suite exercises real Herdr freeze.
            argv = ['bash', '-c', 'export FM_ENTRY_PID=$$ FM_ENTRY_SCRIPT=fm-session.sh; exec bash "$@"', '_', *argv[1:]]
        return subprocess.run(argv, env=self.env, capture_output=True, text=True, timeout=30)

    def test_resume_without_owner_does_not_start_service(self):
        result = self.run_shell('fm-autopilot.sh', 'ensure', '--resume')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root/'state/autopilot').exists())

    def test_plain_command_without_session_starts_nothing(self):
        result = self.run_shell('fm.sh', 'help')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root/'state').exists())

    def test_automatic_resume_is_not_called_in_tests_or_rounds(self):
        call = self.root/'calls'
        (self.bin/'fm-autopilot.sh').write_text('#!/bin/sh\ntouch "'+str(call)+'"\n')
        for changes in ({'FM_AUTOPILOT_TEST_ENABLE':'0'}, {'FM_IN_ROUND':'1'}):
            with self.subTest(changes=changes):
                env = self.env.copy()
                self.env.update(changes)
                try:
                    result = self.run_shell('fm.sh', 'help')
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertFalse(call.exists(), 'ineligible command must not invoke resume')
                finally:
                    self.env = env
                    call.unlink(missing_ok=True)

    def test_test_service_start_exits_before_storage_or_locks(self):
        self.env.pop('FM_AUTOPILOT_TEST_ENABLE')
        (self.root/'config.yaml').unlink()
        result = self.run_shell('fm-autopilot.sh', 'ensure', '--all')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root/'state').exists())

    def test_emit_without_channel_never_invokes_notification_helper(self):
        # A failing probe proves that no Python notification work follows the
        # append in ordinary fixtures, even when the lifeline module exists.
        call = self.root/'notification-called'
        (self.bin/'lib/fm_lifeline.py').write_text(
            'from pathlib import Path\nPath('+repr(str(call))+').touch()\nraise SystemExit(1)\n')
        result = subprocess.run(['bash', str(self.bin/'fm-emit.sh'), '--actor', 'fixture',
                                 '--type', 'agent_finished', '--task', 'T-001'],
                                env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.root/'state/events.jsonl').read_text())['type'], 'agent_finished')
        self.assertFalse(call.exists(), 'no channel means no post-append notification process')

    def test_round_exits_before_resolving_or_writing_project_state(self):
        self.env['FM_IN_ROUND'] = '1'
        (self.root/'config.yaml').unlink()
        result = self.run_shell('fm-autopilot.sh', 'ensure', '--all')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root/'state').exists())

    def test_all_fans_out_to_each_registered_project(self):
        # Only the terminal Python context printer is replaced; recursive shell
        # dispatch, registry parsing and private storage routing are real.
        private = tempfile.TemporaryDirectory()
        self.addCleanup(private.cleanup)
        self.env['FM_HOME'] = private.name
        (self.root/'config.yaml').write_text('''projects:
  firstmate-workflow:
    repo: .
    github: owner/self
    base: main
    required_check: ci
  other:
    github: owner/private
    base: main
    required_check: ci
''')
        (self.bin/'lib/fm_autopilot.py').write_text('import json, os\nprint(json.dumps({k:os.environ[k] for k in ("FM_PROJECT", "FM_STATE_DIR")}))\n')
        result = self.run_shell('fm-autopilot.sh', 'context', '--all')
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual({r['FM_PROJECT']:r['FM_STATE_DIR'] for r in rows}, {
            'firstmate-workflow':str(self.root/'state'),
            'other':str(Path(private.name).resolve()/'projects/other/state')})

    def test_unknown_project_is_refused_before_network(self):
        private = tempfile.TemporaryDirectory(); self.addCleanup(private.cleanup)
        self.env['FM_HOME'] = private.name
        (self.root/'config.yaml').write_text('projects:\n  firstmate-workflow:\n    repo: .\n    github: owner/self\n    base: main\n')
        result = self.run_shell('fm-autopilot.sh', 'context', '--project', 'unknown')
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertFalse((Path(private.name)/'projects/unknown/state/autopilot').exists())

    def test_frozen_launch_normalizes_repo_after_each_boolean_option(self):
        spec = importlib.util.spec_from_file_location('entry_herdr', ROOT/'bin/fm-herdr.py')
        herdr = importlib.util.module_from_spec(spec); spec.loader.exec_module(herdr)
        for flag in ('--all', '--resume'):
            with self.subTest(flag=flag), patch.dict(os.environ, self.env, clear=True), \
                 patch.object(herdr.os, 'execve') as execute:
                herdr.launch(self.bin/'fm-autopilot.sh', self.root,
                             ['ensure', flag, '--repo', 'relative-root'])
                executable, argv, env = execute.call_args.args
                self.assertEqual(argv[-1], str(self.root))
                self.assertEqual(env['FM_ENTRY_SCRIPT'], 'fm-autopilot.sh')
                self.assertEqual(env['FM_CODE_ROOT'], str(self.root))

    def test_session_start_ensures_all_projects_but_status_does_not(self):
        call = self.root/'calls'
        (self.bin/'fm-autopilot.sh').write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "'+str(call)+'"\n')
        (self.bin/'fm-autopilot.sh').chmod(0o755)
        (self.bin/'fm-doctor.sh').write_text('#!/bin/sh\nexit 0\n')
        (self.bin/'fm-doctor.sh').chmod(0o755)
        hooks = self.bin/'lib/fm_hooks.py'
        # Disable hook installation only; the host collector imports detect().
        hooks.write_text(hooks.read_text().replace("if __name__ == '__main__':", "if False:"))
        herdr = self.bin/'fm-herdr.py'
        herdr.write_text(herdr.read_text().replace("if __name__ == '__main__':", "if False:"))
        result = self.run_shell('fm-session.sh', 'start', frozen=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(call.read_text().strip(), 'ensure --all --repo '+str(self.root))
        call.unlink()
        result = self.run_shell('fm-session.sh', 'status', frozen=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(call.exists())
        for changes in ({'FM_AUTOPILOT_TEST_ENABLE':'0'}, {'FM_IN_ROUND':'1'}):
            with self.subTest(changes=changes):
                env = self.env.copy()
                self.env.update(changes)
                try:
                    result = self.run_shell('fm-session.sh', 'start', frozen=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertFalse(call.exists(), 'ineligible session must not invoke ensure')
                finally:
                    self.env = env
                    call.unlink(missing_ok=True)


if __name__ == '__main__': unittest.main()
