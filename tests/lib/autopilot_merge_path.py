"""Merge-path behavior using the existing autopilot and intent-card fixtures."""
import copy
import json
import os
os.environ['HERDR_ENV'] = '0'
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
            for field in ('intent', 'why', 'how', 'scope_in', 'scope_out', 'before_nodes',
                          'after_nodes', 'questions', 'before', 'after'):
                self.assertEqual(built[lang][field], dispatch[lang][field])
            # T-270: without a reviewed merge card the dispatch text carries a caution.
            self.assertEqual(built[lang]['notes'], dispatch[lang]['notes'] + [dict(
                kind='caution', text='Not reviewed for readability.' if lang == 'en' else '未經可讀性審查。')])
            self.assertEqual(built[lang]['glossary'], ['six-gates', 'board', 'scope'])
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
        from fm_ste import check_details, check_plain
        self.assertTrue(check_details(built, 'merge')['ok'])
        self.assertTrue(check_plain(built)['ok'])
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
                raise RuntimeError('card refs: en.intent mismatch with spec; PRIVATE_CHILD_CANARY_242: Private customer request context.')
            return command(argv, **kwargs)
        with patch.object(self.pilot, 'command', side_effect=fail_request):
            self.poll()
            with self.assertRaisesRegex(RuntimeError, 'D-alpha-T001-1.*author.*spec'):
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

    def test_legacy_request_failure_preserves_exception_and_has_no_walk_retry(self):
        self.dispatch()
        command = self.pilot.command
        error = RuntimeError('legacy readiness refused')
        def fail_request(argv, **kwargs):
            if '--request' in argv:
                raise error
            return command(argv, **kwargs)
        with patch.object(self.pilot, 'command', side_effect=fail_request):
            self.poll()
            with self.assertRaises(RuntimeError) as caught:
                self.gate_result(0)
        self.assertIs(error, caught.exception)
        self.assertNotIn('12', self.pilot.data.get('merge_request_failures', {}))
        self.assertFalse(any(k.startswith('merge-request:') for k in self.pilot.data['retries']))
        self.assertFalse((self.state / 'pending').exists())

    def test_walk_retry_rechecks_changed_evidence_with_unchanged_details(self):
        self.dispatch()
        command = self.pilot.command
        def fail_request(argv, **kwargs):
            if '--request' in argv:
                raise RuntimeError('card refs: en.intent mismatch with spec')
            return command(argv, **kwargs)
        with patch.object(self.pilot, 'command', side_effect=fail_request):
            self.poll()
            with self.assertRaises(RuntimeError):
                self.gate_result(0)
        details = self.built_path().read_bytes()
        token = 'merge-request:12:' + HEAD
        self.pilot.data['retries'][token]['due_seq'] = self.pilot.data['poll_seq'] + 100
        # A new authorized advancement fingerprint represents changed CI/review
        # evidence; the old details-only throttle must not suppress its request.
        self.pilot.data['advanced']['12']['fingerprint'] = 'fresh-authorized-evidence'
        self.gate_result(0)
        self.assertEqual(details, self.built_path().read_bytes())
        self.assertEqual(1, len(self.requests()))
        self.assertEqual(1, len(list((self.state / 'pending').glob('*.json'))))
        self.assertNotIn(token, self.pilot.data['retries'])

    def test_stock_request_refusal_corrected_input_recovers_same_reservation(self):
        # Reuse the actual stock shell fixture definitions, not its tests or a
        # replacement request implementation. Synthetic readiness is explicit.
        source = (fixture.ROOT / 'tests/decide.test.sh').read_text().split('\nd="$(fixture)"',1)[0]
        source = source.replace('ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"',
                                'ROOT=' + shlex.quote(str(fixture.ROOT)))
        result = subprocess.run(['bash','-c',source+'\nengine="$(fixture)"\nprintf "language: en\\n" > "$engine/config.yaml"\nproject_fixture_config "$engine" || exit $?\nprintf "%s\\n" "$engine"'],capture_output=True,text=True,check=True)
        engine = Path(result.stdout.strip())
        self.addCleanup(shutil.rmtree,engine)
        home = Path((engine / '.fixture-fm-home').read_text().strip())
        self.addCleanup(shutil.rmtree,home)
        (engine / 'config.yaml').write_text('home: '+str(home)+'\ndefault_project: alpha\nprojects:\n  alpha:\n    repo: .\n    github: owner/alpha\n    base: main\n    required_check: ci\n')
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
        # T-256: a self spec is a local file, which fm-decide.sh reads without a pin.
        (engine / 'design/tasks').mkdir(parents=True, exist_ok=True)
        (engine / 'design/tasks/T-001.json').write_text(json.dumps(spec))
        (engine / '.fixture-diff').write_text('diff --git a/src/a.py b/src/a.py\n--- a/src/a.py\n+++ b/src/a.py\n@@ -1 +1 @@\n-x\n+y\n')
        (engine / 'prs.jsonl').write_text(json.dumps(dict(number=12,state='OPEN',headRefOid=HEAD,headRefName=PR['head']['ref'],title=PR['title']))+'\n')
        self.dispatch()
        # Reserve through the stock allocator after dispatch has occupied ID 2.
        # merge_card must reuse this genuine reservation, not allocate another ID.
        ident = self.pilot.command(self.pilot.script('fm-decide.sh', '--allocate',
            '--task', 'T-001', '--project', 'alpha', '--kind', 'merge')).strip()
        self.assertEqual('D-alpha-T001-3', ident)
        reservation = self.state / 'decision-ids/alpha/T001/3.json'
        self.assertEqual('merge', json.loads(reservation.read_text())['kind'])
        pending_path = self.state / 'pending' / (ident + '.json')
        details = self.state / 'decision-details' / (ident + '.json')
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
        self.assertFalse(pending_path.exists())
        self.assertEqual([], list((self.state / 'pending').glob('*.json')))
        self.assertIn('author intent',json.dumps(self.pilot.data))
        self.assertEqual(ident, self.pilot.data['merge_request_failures']['12']['id'])
        request = self.requests()[0]
        self.assertEqual(ident, request[request.index('--request') + 1])
        self.assertEqual(str(details), request[request.index('--details') + 1])
        self.assertNotIn('Private customer text',json.dumps(self.pilot.data))
        self.poll(); self.poll()
        self.assertEqual(1,len(self.requests()))
        for lang in ('en','zh-TW'): authored[lang]['intent'] = explain[lang]['intent']
        details.write_text(json.dumps(authored))
        self.poll(); self.gate_result(0)
        pending = json.loads(pending_path.read_text())
        self.assertEqual(explain['en']['change_points'],pending['details']['en']['change_points'])
        self.assertEqual(0,pending['check_answer'])
        self.assertEqual(2,len(self.requests()))
        for request in self.requests():
            self.assertEqual(ident, request[request.index('--request') + 1])
            self.assertEqual(str(details), request[request.index('--details') + 1])
        self.assertEqual([pending_path], list((self.state / 'pending').glob('*.json')))
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
        # The default question's own terms join the glossary (T-270).
        self.assertEqual(built['en']['glossary'], ['six-gates', 'pin', 'scope', 'board'])
        self.assertEqual(built['zh-TW']['glossary'], ['six-gates', 'pin', 'scope', 'board'])

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

    # --- T-270: the reviewer's merge card -------------------------------------

    CARD = {lang: dict(title=title, why=[dict(kind='fact', text=why)], how=[dict(kind='fact', text=how)],
                       notes=[dict(kind='note', text=note)], glossary=['scope'])
            for lang, title, why, how, note in (
                ('en', 'Show the plain card.', 'Readers needed the reason.',
                 'The change edits `src/a.py` inside the scope.', 'The reviewer wrote this card.'),
                ('zh-TW', '顯示易讀的卡片。', '讀者需要原因。', '這次改動在範圍內編輯 `src/a.py`。', '審查者寫了這張卡。'))}

    def reviewed(self, card=None, readiness=None, carried=False, signature=None, extra_verdicts=0):
        """A real git head holding the spec, a signed APPROVE with a merge card,
        and the readiness record that selected it."""
        from fm_evidence import Store
        import hashlib
        def git(*args):
            return subprocess.run(['git', '-C', str(self.root), *args], check=True,
                                  capture_output=True, text=True).stdout.strip()
        git('init', '-q'); git('config', 'user.email', 'f@e.test'); git('config', 'user.name', 'F')
        spec = (self.root / 'design/tasks/T-001.json')
        spec.parent.mkdir(parents=True, exist_ok=True)
        spec.write_text(json.dumps(dict(id='T-001', scope=['src/**'], acceptance=['The check passes.'])) + '\n')
        git('add', 'design'); git('commit', '-qm', 'spec')
        reviewed_head = git('rev-parse', 'HEAD')
        spec_sha = hashlib.sha256(spec.read_bytes()).hexdigest()
        if carried:
            (self.root / 'carry').write_text('x'); git('add', 'carry'); git('commit', '-qm', 'carry')
        head = git('rev-parse', 'HEAD')
        store = Store(str(self.state), 'alpha', 'T-001', external=False)
        records = []
        for n, value in enumerate([card or self.CARD] + [dict(self.CARD, en=dict(self.CARD['en'], title='A later card.'))] * extra_verdicts):
            records.append(store.append('verdict', n + 1, 'reviewer-fixture', reviewed_head, 'APPROVE:T-001',
                                        verdict='APPROVE', provenance=dict(level='legacy'),
                                        binding=dict(files=['src/a.py'], spec_sha256=spec_sha),
                                        merge_card=value, merge_card_status='present'))
        fields = dict(pr=12, verdict_signature=signature or records[0]['signature'])
        fields.update(readiness or {})
        store.append('readiness', 1, 'firstmate', fields.pop('head', head), '', **fields)
        pr = copy.deepcopy(PR); pr['head']['sha'] = head
        return pr

    def merge_built(self, pr):
        self.dispatch()
        self.pilot.job_completed(dict(kind='gate', task='T-001', pr=pr, base=BASE, round=1, code=0, output=''))
        return self.built()

    def assert_fallback(self, built):
        self.assertEqual(built['en']['title'], 'MERGE CARD — merge PR #12: The check passes.')
        self.assertEqual(built['en']['notes'][-1], dict(kind='caution', text='Not reviewed for readability.'))

    def test_reviewed_merge_card_supplies_title_why_how_notes_glossary(self):
        built = self.merge_built(self.reviewed())
        for lang, prefix in (('en', 'MERGE CARD — merge PR #12: '), ('zh-TW', '【合併卡】合併 PR #12：')):
            self.assertEqual(built[lang]['title'], prefix + self.CARD[lang]['title'])
            for field in ('why', 'how', 'notes'):
                self.assertEqual(built[lang][field], self.CARD[lang][field])
            self.assertEqual(built[lang]['glossary'], ['scope', 'six-gates', 'board'])
            self.assertEqual(built[lang]['intent'], card()[lang]['intent'])
        self.assertEqual(len(self.requests()), 1)

    def test_carried_approval_supplies_the_merge_card(self):
        built = self.merge_built(self.reviewed(carried=True))
        self.assertEqual(built['en']['title'], 'MERGE CARD — merge PR #12: Show the plain card.')

    def test_card_comes_only_from_the_selected_review(self):
        built = self.merge_built(self.reviewed(extra_verdicts=1))
        self.assertEqual(built['en']['title'], 'MERGE CARD — merge PR #12: Show the plain card.')

    def test_unmatched_readiness_falls_back(self):
        for readiness in (dict(head=BASE), dict(pr=13), dict(verdict_signature='0' * 64)):
            with self.subTest(readiness=readiness):
                self.setUp()
                self.assert_fallback(self.merge_built(self.reviewed(readiness=readiness)))

    def test_readiness_of_another_task_or_project_falls_back(self):
        from fm_evidence import Store
        pr = self.reviewed()
        # The only readiness for this head lives in another task's store.
        for path in (self.state / 'evidence/alpha/T-001').glob('*.json'):
            if json.loads(path.read_text())['kind'] == 'readiness': path.unlink()
        Store(str(self.state), 'alpha', 'T-002', external=False).append(
            'readiness', 1, 'firstmate', pr['head']['sha'], '', pr=12, verdict_signature='0' * 64)
        Store(str(self.state), 'beta', 'T-001', external=False).append(
            'readiness', 1, 'firstmate', pr['head']['sha'], '', pr=12, verdict_signature='0' * 64)
        self.assert_fallback(self.merge_built(pr))

    def test_invented_path_falls_back(self):
        invented = copy.deepcopy(self.CARD)
        invented['en']['how'][0]['text'] = 'The change edits `bin/invented.py` inside the scope.'
        self.assert_fallback(self.merge_built(self.reviewed(card=invented)))

    def test_malformed_merge_card_fields_fall_back(self):
        # Each authored field with a wrong shape makes the block unusable; the
        # build falls back to the dispatch card and never raises TypeError.
        for field, value in (('glossary', 42), ('why', 'x'), ('how', [1]), ('notes', None)):
            with self.subTest(field=field):
                self.setUp()
                malformed = copy.deepcopy(self.CARD)
                malformed['en'][field] = value
                self.assert_fallback(self.merge_built(self.reviewed(card=malformed)))

    def test_any_build_failure_raises_the_details_wake(self):
        for error in (TypeError('forced type failure'), KeyError('forced key failure')):
            with self.subTest(error=type(error).__name__):
                self.setUp()
                self.dispatch()
                def fail(*args, **kwargs): raise error
                with patch('fm_merge_details.build', fail):
                    self.refused('forced')

    def test_merge_card_keeps_every_hash_form(self):
        # Shared hash matcher (T-270 Changes 1 and 6): letters-only and
        # uppercase hashes pass through the reviewed card unchanged.
        hashed = copy.deepcopy(self.CARD)
        hashed['en']['why'][0]['text'] = 'Commits abcdefa and ABC123DEF hold the fix.'
        hashed['zh-TW']['why'][0]['text'] = '提交 abcdefa 和 ABC123DEF 帶有修正。'
        built = self.merge_built(self.reviewed(card=hashed))
        for lang in ('en', 'zh-TW'):
            self.assertEqual(built[lang]['why'], hashed[lang]['why'])

    def test_fallback_without_how_or_glossary_wakes_firstmate(self):
        for missing in ('how', 'glossary', 'why'):
            with self.subTest(missing=missing):
                self.setUp()
                details = card()
                for loc in details.values(): loc.pop(missing)
                self.dispatch(details=details)
                self.refused(missing)

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
