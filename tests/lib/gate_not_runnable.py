"""T-240 production gate control flow and readiness with isolated boundaries."""
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch, MagicMock

sys.dont_write_bytecode = True
ROOT = Path(sys.argv[1]).resolve()
sys.path[:0] = [str(ROOT / 'bin/lib'), str(ROOT / 'tests/lib')]
from crew_blocks import function, section, shell
import fm_binding
import fm_evidence
import fm_spec_pins

REASON = 'The machine has no test credentials'
HEAD, BASE = 'a' * 40, 'b' * 40


class NotRunnable(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.state = self.home / 'state'
        self.state.mkdir()
        self.pin = {'contract': {'unrunnable': REASON, 'check': 'touch should-not-run'}}

    def gate(self, pin, failfirst=0, other=0):
        (self.home / 'pin.json').write_text(json.dumps(pin))
        engine = self.home / 'bin'
        engine.mkdir(exist_ok=True)
        (engine / 'fm-failfirst.sh').write_text(
            '#!/bin/sh\ntouch "$FM_STATE_DIR/ran"\nexit ' + str(failfirst) + '\n')
        path = ROOT / 'bin/fm-gate.sh'
        body = function(path, 'say') + section(path, 'want() {', '\ng()')
        body += function(path, 'g') + function(path, 'gate4')
        body += '\nfor n in 1 2 3 4 5 6; do\n'
        body += 'if [ "$n" = 4 ]; then g 4 fail-first gate4; else g "$n" fixture other; fi\ndone\n'
        prefix = ('ONLY=""; BRANCH=task; BASE=main; TASK=T-240; '
                  'GATE_LIST="$1/bin/lib/fm_gates.json"; GATE_BIN="$work/bin"; '
                  'fm_pin() { cat "$work/pin.json"; }; '
                  'other() { return ' + str(other) + '; };\n')
        return shell(ROOT, self.home, body, prefix)

    def test_full_gate_control_flow_warns_and_runs_no_command(self):
        result = self.gate(self.pin)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('  ! gate 4 (fail-first): fail-first: not runnable: ' + REASON, result.stdout)
        self.assertIn('  + gate 6 (approval):', result.stdout)
        self.assertFalse((self.state / 'ran').exists(), 'no fail-first/test command may run')

    def test_no_declaration_keeps_failfirst_and_red_exit(self):
        result = self.gate({'contract': {'check': 'false'}}, failfirst=1)
        self.assertEqual(4, result.returncode)
        self.assertIn('  x gate 4 (fail-first):', result.stdout)
        self.assertTrue((self.state / 'ran').exists())

    def test_unrelated_exit_three_is_red(self):
        result = self.gate(self.pin, other=3)
        self.assertEqual(1, result.returncode)
        self.assertNotIn('  ! gate', result.stdout)

    def ready(self, warning=4, declared=True, extra=''):
        gates = fm_binding.gate_list()['gates']
        report = self.state / 'gates/report'
        report.parent.mkdir(exist_ok=True)
        report.write_text(f'HEAD:{HEAD}\nBASE:{BASE}\nGATES:2\n' + ''.join(
            f"  {'!' if g['n'] == warning else '+'} gate {g['n']} ({g['name']}): fixture\n"
            for g in gates) + extra)
        bound = {k: 'same' for k in ('patch', 'files', 'spec_sha256', 'contract_sha256', 'conventions_sha256')}
        reviewed = dict(head=HEAD, round=1, binding=bound, signature='review')
        store = MagicMock()
        store.append.side_effect = lambda *args, **kwargs: kwargs
        env = dict(FM_EXTERNAL='1', FM_STATE_DIR=str(self.state), FM_TARGET_ROOT=str(self.home),
                   FM_ENGINE_ROOT=str(ROOT), FM_EVIDENCE_PROJECT='app', FM_TASKS_DIR=str(self.home / 'tasks'))
        argv = ['binding', 'ready', '--task', 'T-240', '--pr', '9', '--head', HEAD, '--gate-report', str(report)]
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.dict(os.environ, env))
            stack.enter_context(patch.object(sys, 'argv', argv))
            stack.enter_context(patch.object(fm_evidence, 'Store', return_value=store))
            stack.enter_context(patch.object(fm_spec_pins.Pins, 'resolve', return_value=self.pin if declared else {'contract': {}}))
            for name, value in [('repository', 'org/app'), ('remote_head', {'headRefOid': HEAD}),
                                ('required_checks', ['ci']), ('view_base', 'main'), ('git', BASE),
                                ('selected_review', (reviewed, None)), ('source_binding', bound), ('verify_current', None)]:
                stack.enter_context(patch.object(fm_binding, name, return_value=value))
            output = stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            fm_binding.main()
            return json.loads(output.getvalue())

    def test_ready_records_pinned_reason(self):
        self.assertEqual({'fail-first': REASON}, self.ready()['not_runnable'])

    def test_ready_refuses_unpinned_warning(self):
        with self.assertRaises(ValueError):
            self.ready(declared=False)

    def test_ready_refuses_warning_for_other_gate_even_with_plus(self):
        with self.assertRaises(ValueError):
            self.ready(extra='  ! gate 5 (ci): forged\n')
        with self.assertRaises(ValueError):
            self.ready(warning=5)

    def test_ready_still_refuses_red_ci(self):
        with self.assertRaises(ValueError):
            self.ready(extra='  x gate 5 (ci): red\n')

    def test_green_transcript_omits_warning_field(self):
        self.assertNotIn('not_runnable', self.ready(warning=None))

    def test_reviewer_summary_does_not_call_warning_missing(self):
        gates = fm_binding.gate_list()['gates']
        folder = self.state / 'gates'
        folder.mkdir()
        (folder / ('T-240-' + HEAD + '.txt')).write_text('GATES:2\n' + ''.join(
            f"  {'!' if g['n'] == 4 else '+'} gate {g['n']} ({g['name']}): fixture\n"
            for g in gates))
        source = section(ROOT / 'bin/fm-review.sh', '  local summary="$FM_STATE_DIR/gates/', '\n}\n\nreviewed_line')
        source = source.replace('$(dirname "${BASH_SOURCE[0]}")/lib/fm_gates.json', str(ROOT / 'bin/lib/fm_gates.json'))
        result = shell(ROOT, self.home, 'summary() {\n' + source + '\n}\nsummary',
                       'TASK=T-240; sha=' + HEAD + ';')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('  ! gate 4 (fail-first):', result.stdout)
        self.assertNotIn('no result line', result.stdout)

    def test_merge_payload_carries_warning(self):
        (self.home / 'details.json').write_text('{"en":{"title":"Merge"}}')
        record = self.ready()
        (self.home / 'binding.json').write_text(json.dumps(record))
        # Execute the production jq payload expression, retaining its actual gate list.
        source = section(ROOT / 'bin/fm-decide.sh', '    payload="$(jq -cn --arg expected_head', '\n    (set -o noclobber;')
        source = source.replace('$(dirname "${BASH_SOURCE[0]}")/lib/fm_gates.json', str(ROOT / 'bin/lib/fm_gates.json'))
        result = shell(ROOT, self.home, source + '\nprintf "%s" "$payload"',
                       'EXPECTED_HEAD=' + HEAD + '; binding="$(cat "$work/binding.json")"; '
                       'ID=D-1; TASK=T-240; KIND=merge; PR=9; PURPOSE=""; ste=null; RECORD=app; DETAILS="$work/details.json";')
        self.assertEqual(0, result.returncode, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual('not_runnable', payload['gates']['fail-first'])
        self.assertEqual({'fail-first': REASON}, payload['not_runnable'])
        self.assertIs(True, payload['gates']['ci'])


unittest.main(argv=['gate-not-runnable'], verbosity=2)
