#!/usr/bin/env bash
set -euo pipefail
exec < /dev/null
# A live managed worker exports FM_* / HERDR_* into this shell; scrub before
# fixture work so session status/watch binds to the temp tree only.
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import sys
from pathlib import Path
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(sys.argv[1]) / 'tests/lib'))
from session_fixture import *  # tests/lib/session_fixture.py

class Session(SessionFixture):
    def start_with(self, config):
        """T-043: session start against a fixture that declares its own project contract."""
        import io, contextlib
        (self.repo / 'config.yaml').write_text(config)
        out = io.StringIO()
        with patch.object(m, 'board_start', return_value=dict(stub=True)) as board, \
             patch.dict(os.environ, {'FM_SESSION_PID': str(os.getpid())}), \
             contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            rc = m.main(['session', 'start', str(self.repo)])
        return rc, json.loads(out.getvalue()), board
    def test_start_runs_declared_setup_once_and_reports_it(self):
        rc, report, board = self.start_with(
            'vendor: mock\nproject:\n  setup: echo ran >> setup-count && echo "it\'s done"\n  check: make test\n')
        self.assertEqual(0, rc)
        self.assertEqual('ran\n', (self.repo / 'setup-count').read_text(), 'setup runs exactly once, in the checkout')
        project = report['project']
        self.assertEqual(['setup', 'check'], project['declared'])
        self.assertEqual(0, project['setup']['exit'])
        self.assertTrue(project['ready'])
        self.assertTrue(board.called)
    def test_failed_setup_is_not_ready_and_never_aborts_startup(self):
        rc, report, board = self.start_with(
            'project:\n  setup: echo "lockfile is out of date" >&2; exit 4\n  check: make test\n')
        self.assertEqual(0, rc, 'a failed setup is reported, not fatal')
        self.assertTrue(board.called, 'the rest of startup still runs')
        self.assertEqual(dict(stub=True), report['board'])
        project = report['project']
        self.assertEqual(4, project['setup']['exit'])
        self.assertIn('lockfile is out of date', project['setup']['error'])
        self.assertFalse(project['ready'])
    def test_start_without_setup_runs_nothing(self):
        rc, report, _ = self.start_with('project:\n  check: make test\n')
        self.assertEqual(0, rc)
        self.assertEqual(['check'], report['project']['declared'])
        self.assertIsNone(report['project']['setup'])
        self.assertTrue(report['project']['ready'])
        self.assertFalse((self.repo / 'state/session/project-setup.log').exists())
    def test_start_without_check_is_not_ready(self):
        rc, report, _ = self.start_with('vendor: mock\n')
        self.assertEqual(0, rc)
        self.assertEqual([], report['project']['declared'])
        self.assertFalse(report['project']['ready'])
        self.assertIn('declares no project.check', report['project']['error'])
    def test_status_reports_contract_and_never_runs_setup(self):
        (self.repo / 'config.yaml').write_text('project:\n  setup: touch setup-ran\n  check: make test\n  tests:\n    - "*_test.go"\n')
        status = self.session_cli('status')
        self.assertEqual(0, status.returncode, status.stderr)
        project = json.loads(status.stdout)['project']
        self.assertEqual(['setup', 'check', 'tests'], project['declared'])
        self.assertIsNone(project['setup'], 'status reports; it does not run')
        self.assertFalse((self.repo / 'setup-ran').exists(), 'status never runs setup')
        self.assertFalse((self.repo / 'state/crew/rosters.json').exists(), 'status never draws a crew')
    def test_start_draws_the_crew_once_and_a_second_start_keeps_it(self):
        """T-104: the installation's crew is drawn the first time firstmate runs."""
        crew = self.repo / 'state/crew/rosters.json'
        with patch.dict(os.environ, {'FM_ROSTER_SEED': 'first'}):
            rc, report, _ = self.start_with('vendor: mock\n')
        self.assertEqual(0, rc)
        self.assertTrue(report['crew']['drawn_now'])
        drawn = json.loads(crew.read_text())
        self.assertEqual((24, 24), (len(drawn['workers']), len(drawn['reviewers'])))
        self.assertEqual([], [n for n in drawn['workers'] if n in drawn['reviewers']])
        self.assertEqual(drawn['workers'], report['crew']['workers'])
        saved = crew.read_bytes()
        with patch.dict(os.environ, {'FM_ROSTER_SEED': 'second'}):
            rc, report, _ = self.start_with('vendor: mock\n')
        self.assertEqual(0, rc)
        self.assertFalse(report['crew']['drawn_now'])
        self.assertEqual(saved, crew.read_bytes(), 'a second start keeps the same crew')
    def roster_cli(self, *args, seed='cli'):
        env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        env['FM_ROSTER_SEED'] = seed
        return subprocess.run(['bash', str(self.repo / 'bin/fm.sh'), 'roster', *args, '--repo', str(self.repo)],
                              cwd=self.repo, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True)
    def test_fm_roster_prints_draws_once_and_redraws_only_when_asked(self):
        crew = self.repo / 'state/crew/rosters.json'
        none = self.roster_cli()
        self.assertEqual(1, none.returncode, none.stderr)
        self.assertIn('no crew drawn yet; roster init draws one', none.stderr)
        self.assertFalse(crew.exists())
        init = self.roster_cli('init')
        self.assertEqual(0, init.returncode, init.stderr)
        drawn = json.loads(crew.read_text())
        self.assertIn('workers (24, drawn ' + drawn['drawn_at'] + '): ' + ' '.join(drawn['workers']), init.stdout)
        self.assertIn('reviewers (24, drawn ' + drawn['drawn_at'] + '): ' + ' '.join(drawn['reviewers']), init.stdout)
        saved = crew.read_bytes()
        again = self.roster_cli('init', seed='other')
        self.assertEqual(1, again.returncode, again.stderr)
        self.assertIn('already has a crew', again.stderr)
        self.assertIn('never redrawn unless you ask with --redraw', again.stderr)
        self.assertEqual(saved, crew.read_bytes())
        shown = self.roster_cli(seed='other')
        self.assertEqual(0, shown.returncode, shown.stderr)
        self.assertIn(' '.join(drawn['reviewers']), shown.stdout)
        self.assertEqual(saved, crew.read_bytes())
        redraw = self.roster_cli('init', '--redraw', seed='other')
        self.assertEqual(0, redraw.returncode, redraw.stderr)
        self.assertIn('Ranks and service records keyed by the old names stay with the old names', redraw.stdout)
        redrawn = json.loads(crew.read_text())
        self.assertNotEqual(drawn['workers'], redrawn['workers'])
        self.assertIn(' '.join(redrawn['workers']), redraw.stdout)
    def test_emit_status_is_board_path_not_pane_heartbeat(self):
        """T-036: pane text is board activity only after emit-status."""
        d = Path(tempfile.mkdtemp()); self.addCleanup(lambda: shutil.rmtree(d, ignore_errors=True))
        (d/'bin').mkdir(); (d/'state').mkdir()
        shutil.copy(root/'bin/fm-emit.sh', d/'bin/fm-emit.sh')
        (d/'bin/lib').mkdir()
        shutil.copy(root/'bin/lib/fm-task-grammar.sh', d/'bin/lib/fm-task-grammar.sh')
        shutil.copy(root/'bin/fm-herdr.py', d/'bin/fm-herdr.py')
        self.assertEqual(0, m.main(['emit-status','--root',str(d),'--actor','session-h',
            '--task','T-S','--role','worker','--en','pane heartbeat','--tw','窗格心跳']))
        ev = json.loads((d/'state/events.jsonl').read_text().splitlines()[0])
        self.assertEqual('crew_status', ev['type'])
        self.assertEqual('pane heartbeat', ev['data']['activity']['en'])
        self.assertNotIn('progress', ev.get('data', {}))
    def reviewer_report(self, config, mode='start'):
        """T-066: fm-session.sh itself, with the session engine stubbed out.

        `exec` keeps the pid, so the frozen-entry check passes without a
        snapshot, and the stub stands in for everything after the report."""
        (self.repo / 'bin/fm-herdr.py').write_text('import sys\nprint("stub " + " ".join(sys.argv[1:3]))\n')
        (self.repo / 'config.yaml').write_text(config)
        env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        return subprocess.run(
            ['bash', '-c', 'export FM_ENTRY_PID=$$ FM_ENTRY_SCRIPT=fm-session.sh; exec "$0" "$@"',
             str(self.repo / 'bin/fm-session.sh'), mode, '--repo', str(self.repo)],
            env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
    def test_start_external_default_reports_engine_models(self):
        """Registry imports stay real; only the session script call is stubbed."""
        shutil.copyfile(self.repo / 'bin/fm-herdr.py', self.repo / 'bin/fm-herdr-real.py')
        (self.repo / 'bin/fm-herdr.py').write_text("""import importlib.util
import os
from pathlib import Path
import runpy
import sys
real = Path(__file__).with_name('fm-herdr-real.py')
if __name__ != '__main__':
    spec = importlib.util.spec_from_file_location('fm_herdr_real', real)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    globals().update({key: value for key, value in vars(module).items()
                      if not key.startswith('__')})
elif len(sys.argv) > 1 and sys.argv[1] == 'session':
    print('FM_EXTERNAL=' + os.environ.get('FM_EXTERNAL', ''))
    print('FM_STATE_DIR=' + os.environ.get('FM_STATE_DIR', ''))
else:
    runpy.run_path(str(real), run_name='__main__')
""")
        private_home = tempfile.TemporaryDirectory()
        self.addCleanup(private_home.cleanup)
        state = Path(private_home.name).resolve() / 'projects/sample/state'
        state.mkdir(parents=True)
        (state / 'config.yaml').write_text(
            'reviewer:\n  vendor: codex\nworker:\n  vendor: claude\n')
        (self.repo / 'config.yaml').write_text(
            'vendor: codex\nreviewer:\n  vendor: claude\n  model: claude-opus-5-5\n'
            'default_project: sample\nprojects:\n  sample:\n'
            '    github: owner/sample\n    base: main\n    required_check: ci\n')
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(('FM_', 'HERDR_', 'CLAUDE', 'CODEX'))}
        env.update(FM_HOME=str(Path(private_home.name).resolve()),
                   HOME=private_home.name, FIRSTMATE_CI_SESSION='1')
        result = subprocess.run(
            ['bash', '-c', 'export FM_ENTRY_PID=$$ FM_ENTRY_SCRIPT=fm-session.sh; exec "$0" "$@"',
             str(self.repo / 'bin/fm-session.sh'), 'start', '--repo', str(self.repo)],
            env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('FM_EXTERNAL=1', result.stdout)
        self.assertIn('FM_STATE_DIR=' + str(state), result.stdout)
        self.assertNotIn('names no reviewer', result.stderr)

    def test_start_reports_a_project_that_names_no_reviewer(self):
        for config, missing in [('vendor: claude\n', 'vendor and model'),
                                ('vendor: claude\nreviewer:\n  vendor: claude\n', 'model'),
                                ('reviewer:\n  model: opus-5\n', 'vendor')]:
            result = self.reviewer_report(config)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertIn('stub session start', result.stdout, 'startup carries on after the report')
            self.assertIn('config.yaml names no reviewer ' + missing + ';', result.stderr, config)
            self.assertIn("the reviewer is the captain's choice", result.stderr)
            self.assertIn('installed adapters:', result.stderr)
    def test_start_is_quiet_when_the_reviewer_is_named(self):
        result = self.reviewer_report('reviewer:\n  vendor: claude\n  model: opus-5\n')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('stub session start', result.stdout)
        self.assertNotIn('names no reviewer', result.stderr)
        # and this repository names its own: claude and opus-5, the captain's choice
        result = self.reviewer_report((root / 'config.yaml').read_text())
        self.assertNotIn('names no reviewer', result.stderr)
    def test_start_reports_a_model_the_vendor_does_not_accept(self):
        """T-127: a missing model was already reported; an unrecognised one
        is too - opus-5 is not a name claude accepts, only a name it fell
        back to before the model was applied at all."""
        result = self.reviewer_report('reviewer:\n  vendor: claude\n  model: opus-5\n')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("reviewer model 'opus-5' is not one claude is known to accept", result.stderr)
        self.assertNotIn('names no reviewer', result.stderr)
    def test_start_is_quiet_about_a_model_the_vendor_does_accept(self):
        for model in ['claude-opus-5-5', 'opus', 'claude-sonnet-5']:
            result = self.reviewer_report('reviewer:\n  vendor: claude\n  model: ' + model + '\n')
            self.assertNotIn('is not one claude is known to accept', result.stderr, model)
        # this repository's own config names one claude accepts
        result = self.reviewer_report((root / 'config.yaml').read_text())
        self.assertNotIn('is not one claude is known to accept', result.stderr)
    def test_start_reports_the_worker_model_too(self):
        result = self.reviewer_report('vendor: claude\nmodel: opus-5\nreviewer:\n  vendor: claude\n  model: claude-opus-5-5\n')
        self.assertIn("worker model 'opus-5' is not one claude is known to accept", result.stderr)
    def test_start_checks_the_worker_vendor_and_model_that_actually_run(self):
        """T-146: the worker's own vendor, not the top-level one, paired with
        that vendor's model - here claude and models.claude, under a codex
        top level, so the check that used to ask codex (no catalogue, quiet)
        now asks claude about the name claude would be handed."""
        result = self.reviewer_report('vendor: codex\nmodels:\n  claude: opus-5\n  codex: gpt-6-astra\n'
                                      'worker:\n  vendor: claude\n'
                                      'reviewer:\n  vendor: claude\n  model: claude-opus-5-5\n')
        self.assertIn("worker model 'opus-5' is not one claude is known to accept", result.stderr)
    def test_start_is_quiet_about_a_vendor_with_no_offline_catalogue(self):
        """T-127: fm_model_known returns 2 (no catalogue) for a vendor other
        than claude - not 1 (not known) - and a config check that reads that
        as any nonzero code would wrongly warn about every codex/cursor-agent
        /gemini model, however real, that it simply cannot check."""
        for config in ('vendor: codex\nmodel: o1\nreviewer:\n  vendor: claude\n  model: claude-opus-5-5\n',
                       'vendor: claude\nmodel: claude-opus-5-5\nreviewer:\n  vendor: cursor-agent\n  model: gpt-5\n'):
            result = self.reviewer_report(config)
            self.assertNotIn('is not one', result.stderr, config)
    def test_status_does_not_repeat_the_reviewer_report(self):
        result = self.reviewer_report('vendor: claude\n', mode='status')
        self.assertIn('stub session status', result.stdout)
        self.assertNotIn('names no reviewer', result.stderr)

unittest.main(argv=['session'], verbosity=2)
PY
