"""T-238: private vendor configuration through the shared production resolver."""
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
ROOT = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(ROOT / 'bin/lib'))
import fm_binding
import fm_spec_pins


class ProjectVendor(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='fm-project-vendor-')
        self.addCleanup(temporary.cleanup)
        self.temp = Path(temporary.name)
        self.root = self.temp / 'engine'
        self.root.mkdir()
        shutil.copytree(ROOT / 'bin', self.root / 'bin')
        self.state = self.temp / 'private/state'
        self.state.mkdir(parents=True)
        self.private = self.state / 'config.yaml'
        self.private.write_text('')
        self.config = self.root / 'config.yaml'
        self.base = ('vendor: opposite-of-host\nmodels:\n  claude: claude-model\n'
                     '  codex: codex-model\nfallback:\n  - claude\n  - gemini\n')
        self.config.write_text(self.base)
        self.host = self.root / 'state/session/host.json'
        self.host.parent.mkdir(parents=True)
        self.host.write_text('{"harness":"claude"}')
        self.run = self.temp / 'run'
        self.run.mkdir()
        (self.run / 'identity.json').write_text('{}')
        stubs = self.temp / 'stubs'
        stubs.mkdir()
        for cli in ('claude', 'codex', 'gemini'):
            stub = stubs / cli
            stub.write_text('#!/bin/sh\n[ "$1" = --version ] || exit 64\necho fixture\n')
            stub.chmod(0o755)
        home = self.temp / 'home'
        home.mkdir()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('FM_', 'HERDR_', 'CLAUDE', 'CODEX', 'XDG_'))}
        self.env.update(HOME=str(home), CODEX_HOME=str(home / '.codex'), FM_ROOT=str(self.root), FM_ENGINE_ROOT=str(self.root),
                        FM_CONFIG=str(self.config), FM_EXTERNAL='1',
                        FM_STATE_DIR=str(self.state), FM_RUN_DIR=str(self.run),
                        FIRSTMATE_CI_SESSION='1', HERDR_ENV='0',
                        PATH=str(stubs) + os.pathsep + self.env['PATH'])

    def shell(self, command, **extra):
        result = subprocess.run(['bash', '-c', '. "$1/bin/fm-config.sh"; ' + command,
                                 'fixture', str(self.root)], cwd=self.root,
                                env=dict(self.env, **extra), text=True, capture_output=True)
        self.assertEqual(0, result.returncode, result.stderr)
        return result

    def test_private_worker(self):
        self.private.write_text('worker:\n  vendor: claude\n')
        self.assertEqual('claude\n', self.shell('fm_role_vendor worker').stdout)
        self.assertEqual('project\n', self.shell('fm_vendor_source worker').stdout)

    def test_private_reviewer(self):
        self.private.write_text('reviewer:\n  vendor: claude\n')
        self.assertEqual('claude\n', self.shell('fm_role_vendor reviewer').stdout)

    def test_private_chain(self):
        self.private.write_text('worker:\n  vendor: claude\nfallback:\n  - codex\n')
        self.assertEqual('claude\ncodex\n', self.shell('fm_vendor_chain worker').stdout)

    def test_unknown_host_uses_private_fallback_head(self):
        self.host.unlink()
        self.private.write_text('worker:\n  vendor: opposite-of-host\nfallback:\n  - codex\n')
        self.assertEqual('codex\n', self.shell('fm_role_vendor worker').stdout)

    def test_opposite_pair_still_precedes_private_fallback(self):
        self.private.write_text('worker:\n  vendor: opposite-of-host\nfallback:\n  - gemini\n')
        self.assertEqual('codex\nclaude\ngemini\n', self.shell('fm_vendor_chain worker').stdout)
        self.shell('fm_record_vendor_resolution worker ""')
        self.assertEqual('opposite-of-host', self.resolution()['rule'])

    def model_config(self):
        self.config.write_text(self.base + 'worker:\n  vendor: codex\n  model: gpt-x\n')
        self.private.write_text('worker:\n  vendor: claude\n  model: ignored-private-model\n')

    def test_project_model_uses_vendor_model(self):
        self.model_config()
        self.assertEqual('claude-model\n', self.shell('fm_model worker').stdout)

    def test_model_for_retains_vendor_isolation(self):
        self.model_config()
        self.assertEqual('claude-model\n', self.shell('fm_model_for worker claude').stdout)
        self.assertEqual('gpt-x\n', self.shell('fm_model_for worker codex').stdout)

    def test_top_level_model_stays_with_engine_fallback_vendor(self):
        self.host.unlink()
        self.config.write_text('vendor: opposite-of-host\nmodel: engine-model\n'
                               'fallback:\n  - claude\n')
        self.private.write_text('fallback:\n  - codex\n')
        self.assertEqual('\n', self.shell('fm_model worker').stdout)
        self.assertEqual('engine-model\n', self.shell('fm_model_for worker claude').stdout)

    def test_inline_fallback_warns_and_uses_engine_list(self):
        self.private.write_text('fallback: [codex]\n')
        result = self.shell('fm_vendor_chain worker')
        self.assertIn(f"fm-vendor: {self.private}: fallback must use '- vendor' lines; using the engine fallback list", result.stderr)
        self.assertEqual('codex\nclaude\ngemini\n', result.stdout)

    def resolution(self):
        return json.loads((self.run / 'identity.json').read_text())['vendor_resolution']

    def test_project_resolution_record(self):
        self.private.write_text('worker:\n  vendor: claude\n')
        result = self.shell('fm_record_vendor_resolution worker ""')
        self.assertEqual(dict(host='claude', rule='project', vendor='claude'), self.resolution())
        self.assertIn('fm-vendor: host=claude rule=project resolved=claude', result.stderr)

    def test_self_ignores_private_config(self):
        self.private.write_text('worker:\n  vendor: claude\nfallback:\n  - codex\n')
        self.assertEqual('codex\nclaude\ngemini\n', self.shell('fm_vendor_chain worker', FM_EXTERNAL='0').stdout)
        self.assertEqual('engine\n', self.shell('fm_vendor_source worker', FM_EXTERNAL='0').stdout)

    def test_explicit_vendor_is_whole_chain_and_reason(self):
        self.private.write_text('worker:\n  vendor: claude\nfallback:\n  - codex\n')
        self.assertEqual('gemini\n', self.shell('fm_vendor_chain worker gemini').stdout)
        self.shell('fm_record_vendor_resolution worker gemini')
        self.assertEqual(dict(host='claude', rule='explicit', vendor='gemini'), self.resolution())

    def test_missing_and_empty_private_values_keep_engine(self):
        for content in ('', 'worker:\n  vendor:\nfallback:\n'):
            self.private.write_text(content)
            self.assertEqual('codex\nclaude\ngemini\n', self.shell('fm_vendor_chain worker').stdout)
        self.private.unlink()
        self.assertEqual('codex\n', self.shell('fm_role_vendor worker').stdout)

    def test_caller_file_is_preserved_without_private_override(self):
        alternate = self.root / 'alternate.yaml'
        alternate.write_text('vendor: gemini\n')
        self.assertEqual('gemini\n', self.shell('fm_role_vendor worker alternate.yaml').stdout)
        self.private.write_text('worker:\n  vendor: claude\n')
        self.assertEqual('claude\n', self.shell('fm_role_vendor worker alternate.yaml').stdout)

    def test_binding_live_contract_changes_but_pin_stays_fixed(self):
        tasks = self.state.parent / 'tasks'
        tasks.mkdir()
        (tasks / 'T-238.json').write_text('{"id":"T-238"}')
        (self.state.parent / 'CONVENTIONS.md').write_text('')
        original = 'project:\n  check: make test\n'
        updated = original + 'worker:\n  vendor: claude\nfallback:\n  - codex\n'
        env = dict(self.env, FM_TARGET_ROOT=str(self.root), FM_TASKS_DIR=str(tasks))
        # Isolate the unchanged git patch and pin lookup; exercise the real
        # source_binding byte selection and digest for live versus pinned data.
        snapshot = {'snapshots': {key: {'text': text} for key, text in
                                 [('spec', '{"id":"T-238"}'), ('contract', original), ('conventions', '')]}}
        with patch.dict(os.environ, env, clear=True), patch.object(fm_binding, 'change', return_value={}):
            for pin, same in [(None, False), (snapshot, True)]:
                with patch.object(fm_spec_pins.Pins, 'resolve', return_value=pin):
                    self.private.write_text(original)
                    before = fm_binding.source_binding('T-238', 'head', 'base', self.root)
                    self.private.write_text(updated)
                    after = fm_binding.source_binding('T-238', 'head', 'base', self.root)
                    self.assertEqual(same, before['contract_sha256'] == after['contract_sha256'])
            self.assertEqual(fm_spec_pins.contract(original, 'sample'),
                             fm_spec_pins.contract(updated, 'sample'))


unittest.main(argv=['project-vendor'], verbosity=2)
