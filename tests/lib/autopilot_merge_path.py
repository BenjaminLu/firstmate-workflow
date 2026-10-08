"""Merge-path behavior using the existing autopilot and intent-card fixtures."""
import copy
import json
import os
import shutil
import shlex
import subprocess
from pathlib import Path
import unittest
from unittest.mock import patch

import autopilot_loop as fixture
from ste_cases import card, walk_card

A, PR, HEAD, BASE, CHECKS = fixture.A, fixture.PR, fixture.HEAD, fixture.BASE, fixture.CHECKS


class MergePath(unittest.TestCase):
    # Reuse fixture helpers without inheriting the unrelated lifecycle tests.
    setUp = fixture.LoopTests.setUp
    def record_job(self, kind, task, pr, argv, **extra):
        # Stock spawn creates the jobs registry for every kind, including gates.
        self.pilot.data.setdefault('jobs', {})
        return fixture.LoopTests.record_job(self, kind, task, pr, argv, **extra)
    command = fixture.LoopTests.command
    probe = fixture.LoopTests.probe
    branch_setup = fixture.BranchFixture.branch_setup
    branch_probe = fixture.BranchFixture.branch_probe
    gate_result = fixture.LoopTests.gate_result

    def dispatch(self, n=2, **changes):
        details = card()
        details['en']['title'] = 'Dispatch T-001: The check passes.'
        details['zh-TW']['title'] = '派工 T-001：檢查通過。'
        record = dict(id=f'D-alpha-T001-{n}', project='alpha', task='T-001',
                      kind='choice', purpose='dispatch', chosen='A', details=details)
        record.update(changes)
        path = self.state / 'decisions' / (record['id'] + '.json')
        path.parent.mkdir(exist_ok=True)
        path.write_text(json.dumps(record))
        return details, path

    def built_path(self):
        return self.state / 'decision-details-built/D-alpha-T001-1.json'

    def built(self):
        self.assertTrue(self.built_path().is_file(), 'green self gates must build missing merge details')
        return json.loads(self.built_path().read_text())

    def requests(self):
        return [c[1] for c in self.calls if c[0] == 'command' and '--request' in c[1]]

    def poll(self, pr=PR):
        # Exercise the real gh JSON decoder, not a scalar or pre-decoded stub.
        self.pilot.api = lambda endpoint: A.Pilot.api(self.pilot, endpoint)
        command = self.pilot.command
        def gh(argv, **kwargs):
            if argv[1:2] == ['api']:
                self.assertEqual(argv[2:], ['repos/owner/alpha/branches/main/protection/required_status_checks', '--include'])
                return 'HTTP/2.0 200 OK\r\n\r\n' + json.dumps(dict(contexts=['ci'], checks=[]))
            return command(argv, **kwargs)
        with patch.object(self.pilot, 'command', side_effect=gh):
            self.pilot.advance(pr, CHECKS, [])

    def test_green_gates_build_checked_card_and_request_once(self):
        dispatch, path = self.dispatch()
        original = path.read_bytes()
        self.poll(); self.gate_result(0); self.gate_result(0)
        built = self.built()
        for lang, title, done in (
                ('en', 'MERGE CARD — merge PR #12: The check passes.',
                 'CI, review and the six gates are green on this head.'),
                ('zh-TW', '【合併卡】合併 PR #12：檢查通過。', '這個 head 的 CI、審查和六關全綠。')):
            self.assertEqual(built[lang]['title'], title)
            self.assertEqual(built[lang]['done'], [dict(kind='fact', text=done)] + dispatch[lang]['done'])
            for field in ('intent', 'why', 'scope_in', 'scope_out', 'notes', 'before_nodes',
                          'after_nodes', 'questions', 'before', 'after'):
                self.assertEqual(built[lang][field], dispatch[lang][field])
            for field in ('pros', 'cons'):
                self.assertEqual(built[lang]['options']['A'][field], dispatch[lang]['options']['A'][field])
            self.assertEqual(built[lang]['options']['B']['cons'], dispatch[lang]['options']['B']['cons'])
            self.assertEqual(built[lang]['explanation'],
                'The review approved T-001. CI, coverage and the six gates must be green on this head before you see this card.'
                if lang == 'en' else '審查核准了 T-001。這個 head 的 CI、覆蓋檢查和六關都必須全綠。')
            self.assertEqual(built[lang]['outcome'],
                'Option A merges only PR #12. The board then replaces itself on the new code.'
                if lang == 'en' else '選項 A 只合併 PR #12。之後看板自己換上新程式。')
            self.assertEqual(built[lang]['options']['A']['description'], 'Merge #12' if lang == 'en' else '合併 #12')
            self.assertEqual(built[lang]['options']['B']['description'], 'Hold the merge' if lang == 'en' else '暫緩合併')
            self.assertEqual(built[lang]['options']['B']['pros'], 'The code stays the same.' if lang == 'en' else '程式維持原樣。')
            self.assertEqual(built[lang]['options']['C'], dict(
                description='Ask for a fix', pros='You can change the scope.',
                cons='A change needs a new review, CI and six gates.') if lang == 'en' else dict(
                description='要求修正', pros='你可以改範圍。', cons='修改需要重新審查、CI 和六關。'))
            self.assertEqual(built[lang]['change_table'], [dict(text=dispatch[lang]['intent'][0]['text'], A='✓', B='—', C='—')])
        from fm_ste import check_details
        self.assertTrue(check_details(built, 'merge')['ok'])
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(len(self.requests()), 1)
        request = self.requests()[0]
        self.assertEqual(request[request.index('--details') + 1], str(self.built_path()))
        self.assertEqual(request[request.index('--expected-head') + 1], HEAD)

    def test_built_details_do_not_regate_unchanged_inputs(self):
        self.dispatch()
        self.poll(); self.gate_result(0)
        self.built()
        before = copy.deepcopy(self.pilot.data['advanced'])
        self.poll(); self.poll()
        self.assertEqual(sum(c[0] == 'gate' for c in self.calls), 1)
        self.assertEqual(self.pilot.data['advanced'], before)

    def test_failed_request_does_not_regate_unchanged_inputs(self):
        self.dispatch()
        command = self.pilot.command
        def fail_request(argv, **kwargs):
            if '--request' in argv:
                raise RuntimeError('PRIVATE_CHILD_CANARY_242: Private customer request context.')
            return command(argv, **kwargs)
        with patch.object(self.pilot, 'command', side_effect=fail_request):
            self.poll()
            with self.assertRaisesRegex(ValueError, 'D-alpha-T001-1.*author.*spec'):
                self.gate_result(0)
            self.built()
            self.poll(); self.poll()
        self.assertEqual(sum(c[0] == 'gate' for c in self.calls), 1)
        failure = self.pilot.data['merge_request_failures']['12']
        self.assertEqual(failure['id'], 'D-alpha-T001-1')
        retained = json.dumps(self.pilot.data)
        self.assertNotIn('PRIVATE_CHILD_CANARY_242', retained)
        self.assertNotIn('Private customer request context.', retained)
        for allowed in ('T-001', 'D-alpha-T001-1', 'author intent and walk fields from the spec'):
            self.assertIn(allowed, retained)
        wakes = json.dumps(self.pilot.data['wakes'])
        self.assertNotIn('PRIVATE_CHILD_CANARY_242', wakes)
        self.assertNotIn('Private customer request context.', wakes)
        for allowed in ('T-001', 'D-alpha-T001-1', 'author intent and walk fields from the spec'):
            self.assertIn(allowed, wakes)
        corrected = self.state / 'decision-details/D-alpha-T001-1.json'
        corrected.parent.mkdir(exist_ok=True)
        corrected.write_text(json.dumps(card()))
        self.poll(); self.gate_result(0)
        self.assertEqual(len(self.requests()), 1)
        self.assertEqual(len(list((self.state / 'pending').glob('*.json'))), 1)
        self.assertNotIn('12', self.pilot.data['merge_request_failures'])

    def test_stock_request_refusal_corrected_input_recovers_same_reservation(self):
        # Reuse the actual stock shell fixture definitions, not its tests or a
        # replacement request implementation. Synthetic readiness is explicit.
        source = (fixture.ROOT / 'tests/decide.test.sh').read_text().split('\nd="$(fixture)"',1)[0]
        source = source.replace('ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"',
                                'ROOT=' + shlex.quote(str(fixture.ROOT)))
        result = subprocess.run(['bash','-c',source+'\nfixture'],capture_output=True,text=True,check=True)
        engine = Path(result.stdout.strip())
        self.addCleanup(shutil.rmtree,engine)
        (engine / 'config.yaml').write_text('home: '+str(engine / 'home')+'\ndefault_project: alpha\nprojects:\n  alpha:\n    repo: .\n    github: owner/alpha\n    base: main\n')
        self.root = engine; self.state = engine / 'state'
        self.ctx.update(engine=str(engine),target=str(engine),state=str(self.state),tasks=str(engine / 'design/tasks'))
        self.pilot = A.Pilot(self.ctx)
        self.pilot.start_job = self.record_job
        self.pilot.authoritative_head = lambda task,pr: pr['head']['sha']
        self.pilot.verdict = lambda task: {}
        self.pilot.busy = lambda task: False
        self.branch_setup(); self.pilot.probe = self.probe
        self.pilot.read_head_spec = lambda pr,task: dict(id=task)
        self.pilot.emit = lambda *a,**kw: self.calls.append(('emit',a,kw))
        def stock(argv, **kwargs):
            if '--request' in argv or '--allocate' in argv:
                self.calls.append(('command',argv))
                actual = [str(engine / 'bin' / Path(argv[0]).name), *argv[1:]]
                return A.Pilot.command(self.pilot,actual,env=dict(os.environ,FM_GH=str(engine / 'gh'),HERDR_ENV='0'),**kwargs)
            return self.command(argv,**kwargs)
        self.pilot.command = stock
        explain = {lang:{k:v for k,v in loc.items() if k in ('intent','why','scope_in','scope_out','done','notes','before_nodes','after_nodes','change_points','door','check')} for lang,loc in walk_card().items()}
        spec = dict(id='T-001',explain=explain,acceptance=['The check passes.'],check_answer=0,
                    change_refs=[dict(files=['src/a.py'],tests=[dict(file='tests/a.py',name='missing')],acceptance=[0])])
        (engine / '.fixture-source.json').write_text(json.dumps(spec))
        (engine / '.fixture-diff').write_text('diff --git a/src/a.py b/src/a.py\n--- a/src/a.py\n+++ b/src/a.py\n@@ -1 +1 @@\n-x\n+y\n')
        (engine / 'prs.jsonl').write_text(json.dumps(dict(number=12,state='OPEN',headRefOid=HEAD,headRefName=PR['head']['ref'],title=PR['title']))+'\n')
        self.dispatch()
        details = self.state / 'decision-details/D-alpha-T001-1.json'
        details.parent.mkdir(exist_ok=True)
        authored = card()
        authored['en']['title'] = 'MERGE CARD — merge PR #12: The check passes.'
        authored['zh-TW']['title'] = '【合併卡】合併 PR #12：檢查通過。'
        authored['en']['intent'][0]['text'] = 'Private customer text.'
        details.write_text(json.dumps(authored))
        self.poll()
        receipt = self.state / 'request-gate.json'
        receipt.with_suffix('.result.json').write_text(json.dumps(dict(kind='gate',task='T-001',pr=PR,base=BASE,round=1,code=0,output='')))
        self.pilot.data['jobs']['stock'] = dict(kind='gate',task='T-001',number=12,head=HEAD,state='running',path=str(receipt))
        self.pilot.consume_jobs()
        self.assertEqual('uncertain',self.pilot.data['jobs']['stock']['state'])
        self.assertFalse((self.state / 'pending/D-alpha-T001-1.json').exists())
        self.assertIn('author intent',json.dumps(self.pilot.data))
        self.assertNotIn('Private customer text',json.dumps(self.pilot.data))
        self.poll(); self.poll()
        self.assertEqual(1,len(self.requests()))
        for lang in ('en','zh-TW'): authored[lang]['intent'] = explain[lang]['intent']
        details.write_text(json.dumps(authored))
        self.poll(); self.gate_result(0)
        pending = json.loads((self.state / 'pending/D-alpha-T001-1.json').read_text())
        self.assertEqual(explain['en']['change_points'],pending['details']['en']['change_points'])
        self.assertEqual(0,pending['check_answer'])
        self.assertEqual(2,len(self.requests()))
        self.assertEqual(1,len(list((self.state / 'pending').glob('*.json'))))
        self.poll()
        self.assertEqual(2,len(self.requests()))
        self.assertFalse((engine / 'merge-calls').exists())

    def test_highest_numeric_answered_dispatch_a_wins(self):
        self.dispatch(9)
        details = card()
        details['en']['title'] = 'Dispatch T-001: The new check passes.'
        details['zh-TW']['title'] = '派工 T-001：新檢查通過。'
        self.dispatch(10, details=details)
        # An unanswered higher-numbered card cannot supply approved intent.
        pending = self.state / 'pending'; pending.mkdir()
        (pending / 'D-alpha-T001-99.json').write_text(json.dumps(dict(
            task='T-001', purpose='dispatch', details=card())))
        for n, change in enumerate((dict(chosen='B'), dict(chosen='C'), dict(chosen='change', picked='A'),
                                    dict(purpose='repin'), dict(task='T-002'), dict(project='beta')), 11):
            self.dispatch(n, **change)
        self.gate_result(0)
        self.assertEqual(self.built()['en']['title'], 'MERGE CARD — merge PR #12: The new check passes.')

    def test_whole_title_and_default_questions(self):
        details = card()
        for loc in details.values():
            loc.pop('questions')
        self.dispatch(details=details)
        self.gate_result(0)
        built = self.built()
        self.assertEqual(built['en']['title'], 'MERGE CARD — merge PR #12: The check passes.')
        self.assertEqual(built['zh-TW']['title'], '【合併卡】合併 PR #12：檢查通過。')
        self.assertEqual(built['en']['questions'], [dict(kind='fact', text='The change stays inside the pinned scope.')])
        self.assertEqual(built['zh-TW']['questions'], [dict(kind='fact', text='改動不超出固定的範圍。')])

    def refused(self, reason, reason_tw=None):
        self.gate_result(0)
        self.assertFalse(self.built_path().exists())
        self.assertEqual(self.requests(), [])
        wake = next(iter(self.pilot.data['wakes'].values()))
        self.assertIn('T-001 ready: merge card details needed (D-alpha-T001-1)', wake['line'])
        self.assertIn(reason, wake['line'])
        self.assertIn(reason, wake['summary']['en'])
        self.assertIn(reason if reason_tw is None else reason_tw, wake['summary']['zh-TW'])

    def test_bad_chinese_names_failing_sentence(self):
        details = card(); details['zh-TW']['intent'][0]['text'] = '檢查將會通過。'
        self.dispatch(details=details)
        self.refused('zh-TW intent: 檢查將會通過。 -> Z4')

    def test_legacy_dispatch_names_missing_intent(self):
        details = card()
        for loc in details.values():
            for field in ('intent', 'why', 'scope_in', 'scope_out', 'done', 'notes',
                          'before_nodes', 'after_nodes', 'questions', 'change_table'):
                loc.pop(field)
        self.dispatch(details=details)
        self.refused('intent is required in both locales')

    def test_done_overflow_keeps_checker_error(self):
        details = card()
        for loc in details.values(): loc['done'] *= 6
        self.dispatch(details=details)
        self.refused('en.done: expected 1-12 items')

    def test_locale_count_mismatch_keeps_checker_error(self):
        details = card(); details['en']['before_nodes'] *= 2
        self.dispatch(details=details)
        self.refused('before_nodes: locale counts must match')

    def test_no_answered_dispatch(self):
        self.dispatch(chosen='B')
        self.refused('no answered dispatch card')

    def test_external_project_needs_author(self):
        self.dispatch()
        self.ctx['external'] = True
        self.refused('external project: author the details', '外部專案：請撰寫決策卡內容')

    def test_authored_details_win_unchanged(self):
        self.dispatch()
        path = self.state / 'decision-details/D-alpha-T001-1.json'
        path.parent.mkdir()
        content = json.dumps(card(), ensure_ascii=False) + '\n'
        path.write_text(content)
        self.gate_result(0)
        self.assertEqual(path.read_text(), content)
        self.assertFalse(self.built_path().exists())
        request = self.requests()[0]
        self.assertEqual(request[request.index('--details') + 1], str(path))

    def test_draft_wakes_once_per_head_for_each_project(self):
        for external in (False, True):
            with self.subTest(external=external):
                self.ctx['external'] = external
                self.pilot.data['wakes'].clear()
                self.pilot.task = lambda pr: 'T-001'
                pr = copy.deepcopy(PR); pr['draft'] = True
                self.poll(pr); self.poll(pr)
                ident = 'autopilot-' + A.key(['alpha', 'draft-12-' + HEAD])
                self.assertEqual(set(self.pilot.data['wakes']), {ident})
                self.assertEqual(self.pilot.data['wakes'][ident]['summary'], dict(
                    en=f'T-001 #12 is a draft at {HEAD[:12]}: the merge path waits; mark it ready',
                    **{'zh-TW': 'T-001 #12 仍是草稿：合併流程在等待，請標成 ready'}))
                pr['head']['sha'] = BASE
                self.poll(pr); self.poll(pr)
                self.assertEqual(set(self.pilot.data['wakes']), {ident, 'autopilot-' + A.key(['alpha', 'draft-12-' + BASE])})
                self.assertFalse(any(c[0] == 'gate' for c in self.calls))
                self.assertFalse(any('--ready' in str(c) for c in self.calls))

    def test_running_job_holds_draft_wake(self):
        self.pilot.busy = lambda task: A.Pilot.busy(self.pilot, task)
        self.pilot.data.setdefault('jobs', {})['active'] = dict(task='T-001', state='running')
        self.poll(dict(PR, draft=True))
        self.assertEqual(self.pilot.data['wakes'], {})


if __name__ == '__main__': unittest.main()
