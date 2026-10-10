"""T-276 change 2: every task gets a review round budget that stops for the captain.

The budget state in bin/lib/fm_round_budget.py, its cards and answers, the
holds, and the autopilot's REJECT, job and card paths. Real signed evidence
records; GitHub and fm-decide.sh calls are recorded, never run. No network
and no background processes.

Modes for tests/round-budget.test.sh:
  round_budget.py <root> details <task> <file>        write a 12-round, 30-item card
  round_budget.py <root> consumer <engine> <state> <project> <task>
                                                      the autopilot's budget, as JSON
  round_budget.py <root> seed <state> <project> <task> <round> <head>
                                                      append one marked REJECT, a new item open
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

os.environ['HERDR_ENV'] = '0'
sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1))
sys.path.insert(0, str(ROOT / 'bin/lib'))
sys.path.insert(0, str(ROOT / 'tests/lib'))
import fm_evidence as E
import fm_round_budget as R
import fm_ste

T = 'T-001'
HEADS = [str(n) * 40 for n in range(1, 10)] + ['c' * 40, 'd' * 40, 'e' * 40, 'f' * 40]
ANSWERED = '2026-10-05T00:00:00Z'
SPEC1, SPEC2 = '{"id":"T-001","v":1}\n', '{"id":"T-001","v":2}\n'


def body(items, decided):
    """items: list of first lines; a list with None is a REJECT without a standing list."""
    if items is None:
        return f'No list this time.\n{decided}:{T}\n'
    lines = ''.join(f'{n}. {line}\n' for n, line in enumerate(items, 1))
    return lines + f'CRITERIA-COMPLETE:{T}\n{decided}:{T}\n'


def append(store, round_number, items, decided='REJECT', marked=True, head=None, actor='reviewer-ada-t001-r1',
           **extra):
    fields = dict(verdict=decided, provenance={'level': 'legacy'}, **extra)
    if marked:
        fields['severity_protocol'] = 1
    return store.append('verdict', round_number, actor, head or HEADS[round_number - 1],
                        body(items, decided), **fields)


def distinct(n):
    """Round n of a history with a different item open in each round."""
    return ['done a'] * (n - 1) + ['open new ground']


def preflight(store, text):
    return store.append('spec-preflight', 1, 'reviewer-fixture', 'a' * 40,
                        '1. Fixture acceptance checked.\nSPEC-OK:' + T,
                        spec_sha256=hashlib.sha256(text.encode()).hexdigest(), verdict='SPEC-OK',
                        provenance={'level': 'legacy', 'vendor': 'claude'})


def pin(version, source='dispatch', time='2026-10-01T00:00:00Z', text=SPEC1, spec_time=None):
    record = dict(version=version, source=source, approval=dict(time=time),
                  snapshots=dict(spec=dict(text=text)))
    if spec_time:
        record['spec_approval'] = dict(time=spec_time)
    return record


def answer(state, ident, chosen, task=T, ts=ANSWERED, record_id=None):
    folder = Path(state) / 'decisions'
    folder.mkdir(parents=True, exist_ok=True)
    (folder / (ident + '.json')).write_text(json.dumps(dict(id=record_id or ident, task=task, kind='choice',
                                                            chosen=chosen, ts=ts)))


def config(folder, text):
    path = Path(folder) / 'config.yaml'
    path.write_text(text)
    return path


class Base(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.state = self.tmp / 'state'; self.state.mkdir()
        self.config = self.tmp / 'config.yaml'  # absent: every default
        self.store = E.Store(str(self.state), 'alpha', T, external=False)
        self.pin = None
        holder = patch.object(R.Budget, 'pin', new=lambda budget: self.pin)
        holder.start(); self.addCleanup(holder.stop)

    def budget(self, **kwargs):
        return R.Budget(str(self.state), 'alpha', T, self.config, env={}, external=False, **kwargs)

    def state_of(self):
        return self.budget().state_of()

    def cli(self, command, *extra, env=None):
        return subprocess.run([sys.executable, str(ROOT / 'bin/lib/fm_round_budget.py'), command,
                               '--state', str(self.state), '--project', 'alpha', '--task', T,
                               '--config', str(self.config), *extra],
                              capture_output=True, text=True,
                              env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1', FM_EXTERNAL='0', **(env or {})))


class Config(Base):
    def test_defaults_when_the_block_or_a_key_is_missing(self):
        self.assertEqual(R.config(self.config), dict(rounds=3, stall=2, extend=2), 'missing file')
        config(self.tmp, 'concurrency: 3\n')
        self.assertEqual(R.config(self.config), dict(rounds=3, stall=2, extend=2), 'missing block')
        config(self.tmp, 'review_budget:\n  stall: 4   # comment\nconcurrency: 3\n')
        self.assertEqual(R.config(self.config), dict(rounds=3, stall=4, extend=2), 'missing keys')

    def test_an_invalid_value_is_an_error_naming_the_key(self):
        for key, value in (('rounds', '0'), ('stall', '100'), ('extend', 'two'), ('rounds', '1.5'), ('stall', '-1')):
            with self.subTest(key=key, value=value):
                config(self.tmp, f'review_budget:\n  {key}: {value}\n')
                with self.assertRaisesRegex(ValueError, f'review_budget.{key} must be a whole number from 1 to 99'):
                    R.config(self.config)
                result = self.cli('check')
                self.assertEqual(result.returncode, 65, 'a configuration error stops the launcher')
                self.assertIn(f'review_budget.{key}', result.stderr)

    def test_the_autopilot_and_the_worker_check_read_the_same_engine_file(self):
        import fm_autopilot as A
        config(self.tmp, 'review_budget:\n  rounds: 4\n  stall: 3\n  extend: 5\n')
        pilot = A.Pilot(dict(engine=str(self.tmp), state=str(self.state), target=str(self.tmp), project='alpha',
                             evidence_project='alpha', repository='owner/alpha', base='main', external=False,
                             tasks=str(self.tmp)))
        self.assertEqual(pilot.budget_reader(T).config, dict(rounds=4, stall=3, extend=5))
        for n in range(1, 4):
            append(self.store, n, distinct(n))
        self.assertEqual(self.cli('check').returncode, 0, 'three of four rounds')
        self.assertEqual(pilot.budget_reader(T).state_of()['state'], 'within')
        append(self.store, 4, distinct(4))
        self.assertEqual(self.cli('check').returncode, 65)
        self.assertEqual(pilot.budget_reader(T).state_of()['state'], 'stop')


class State(Base):
    def test_a_task_with_no_verdicts_passes_check_silently(self):
        result = self.cli('check')
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '', ''))
        self.assertEqual(self.state_of()['state'], 'within')

    def test_the_third_marked_reject_stops_and_rounds_five_moves_it(self):
        for n in (1, 2):
            append(self.store, n, distinct(n))
            self.assertEqual(self.state_of()['state'], 'within', n)
        append(self.store, 3, distinct(3))
        result = self.state_of()
        self.assertEqual((result['state'], result['rounds'], result['budget'], result['stalled']), ('stop', 3, 3, []))
        check = self.cli('check')
        self.assertEqual(check.returncode, 65)
        self.assertIn('no card was raised yet', check.stderr)
        config(self.tmp, 'review_budget:\n  rounds: 5\n')
        self.assertEqual(self.state_of()['state'], 'within')
        append(self.store, 4, distinct(4))
        self.assertEqual(self.state_of()['state'], 'within')
        append(self.store, 5, distinct(5))
        self.assertEqual(self.state_of()['state'], 'stop')

    def test_a_must_fix_item_open_in_two_consecutive_rounds_stops(self):
        append(self.store, 1, ['open lock'])
        append(self.store, 2, ['open lock'])
        result = self.state_of()
        self.assertEqual((result['state'], result['stalled']), ('stop', [1]))

    def test_a_streak_crosses_an_unmarked_and_a_marked_round(self):
        append(self.store, 1, ['open lock'], marked=False)
        append(self.store, 2, ['open lock'])
        self.assertEqual(self.state_of()['state'], 'stop')

    def test_streaks_are_broken(self):
        cases = dict(
            approve=[(['open lock'], 'REJECT'), (None, 'APPROVE'), (['open lock'], 'REJECT')],
            no_list=[(['open lock'], 'REJECT'), (None, 'REJECT'), (['open lock'], 'REJECT')],
            done=[(['open lock'], 'REJECT'), (['done lock', 'open b'], 'REJECT'),
                  (['open lock', 'done b'], 'REJECT')],
            follow_up=[(['open lock', 'open b'], 'REJECT'), (['open [follow-up] lock', 'open b'], 'REJECT'),
                       (['open lock', 'done b'], 'REJECT')])
        config(self.tmp, 'review_budget:\n  rounds: 9\n')
        for name, history in cases.items():
            with self.subTest(name=name):
                self.setUp()
                config(self.tmp, 'review_budget:\n  rounds: 9\n')
                for n, (items, decided) in enumerate(history, 1):
                    append(self.store, n, items, decided)
                self.assertEqual(self.state_of()['state'], 'within')

    def test_an_unmarked_latest_reject_never_stops(self):
        for n in range(1, 6):
            append(self.store, n, ['open lock'], marked=False)
        result = self.state_of()
        self.assertEqual((result['state'], result['rounds']), ('within', 5))
        self.assertEqual(self.cli('check').returncode, 0)

    def test_the_last_record_of_a_round_represents_it(self):
        config(self.tmp, 'review_budget:\n  rounds: 9\n')
        append(self.store, 1, ['open lock'], actor='reviewer-ada-t001-r1', login='ada')
        append(self.store, 2, ['open lock'], actor='reviewer-ada-t001-r2', login='ada')
        append(self.store, 2, ['done lock', 'open b'], actor='reviewer-bo-t001-r2', login='bo')
        rows = R.rounds(self.store)
        self.assertEqual([(row['round'], row['must']) for row in rows], [(1, [1]), (2, [2])])
        self.assertEqual(self.state_of()['state'], 'within', 'the later record breaks the streak')
        with patch.dict(os.environ, FM_REVIEWER_LOGIN='ada'):
            self.assertEqual([row['must'] for row in R.rounds(self.store)], [[1], [1]])
            self.assertEqual(self.state_of()['state'], 'stop', 'the login filter applies first')

    def test_history_lists_every_round_in_private_state(self):
        append(self.store, 1, ['open lock', 'open [follow-up] docs'])
        rows = json.loads(self.cli('history').stdout)
        self.assertEqual([(row['round'], row['must'], row['follow']) for row in rows], [(1, [1], [2])])


class Cards(Base):
    def stop(self):
        for n in range(1, 4):
            append(self.store, n, distinct(n))

    def test_record_card_writes_the_card_and_refuses_a_second_for_one_verdict(self):
        with self.assertRaisesRegex(R.Refused, 'has not stopped'):
            self.budget().record_card('D-alpha-T001-1')
        self.stop()
        self.pin = pin(1)
        card = self.budget().record_card('D-alpha-T001-1')
        latest = self.store.verdicts()[-1]
        self.assertEqual({k: card[k] for k in ('id', 'head', 'signature', 'round', 'rounds', 'budget', 'extend', 'pin')},
                         dict(id='D-alpha-T001-1', head=HEADS[2], signature=latest['signature'], round=3, rounds=3,
                              budget=3, extend=2, pin=1))
        self.assertTrue(card['time'])
        saved = json.loads((self.state / 'round-budget' / (T + '.json')).read_text())
        self.assertEqual((saved['version'], saved['cards']), (1, [card]))
        for ident in ('D-alpha-T001-1', 'D-alpha-T001-2'):
            with self.assertRaises(R.Refused):
                self.budget().record_card(ident)
        # The real resolver reads no pin here, so only the recorded card refuses.
        refused = self.cli('record-card', '--id', 'D-alpha-T001-2', env=dict(
            FM_ENGINE_ROOT=str(self.tmp), FM_TARGET_ROOT=str(self.tmp), FM_STATE_DIR=str(self.state),
            FM_TASKS_DIR=str(self.tmp), FM_DESIGN=str(self.tmp / 'design.md'), FM_PROJECT='alpha'))
        self.assertEqual(refused.returncode, 65)
        self.assertIn('a card is already recorded for the latest stopping verdict', refused.stderr)
        self.assertEqual(json.loads((self.state / 'round-budget' / (T + '.json')).read_text())['cards'], [card])

    def test_writes_are_atomic(self):
        self.stop()
        self.budget().record_card('D-alpha-T001-1')
        path = self.state / 'round-budget' / (T + '.json')
        before = path.read_bytes()
        append(self.store, 4, distinct(4))
        answer(self.state, 'D-alpha-T001-1', 'C')
        append(self.store, 5, distinct(5))
        with patch.object(R.os, 'replace', side_effect=OSError('disk full')):
            with self.assertRaises(OSError):
                self.budget().record_card('D-alpha-T001-2')
        self.assertEqual(path.read_bytes(), before, 'a failed write leaves the old file whole')
        self.assertEqual(sorted(p.name for p in path.parent.iterdir()), ['.lock', T + '.json'],
                         'no temporary file is left behind')

    def test_an_answer_must_match_the_card_id_and_task(self):
        self.stop()
        self.budget().record_card('D-alpha-T001-1')
        for kwargs in (dict(task='T-002'), dict(record_id='D-alpha-T001-9')):
            with self.subTest(**kwargs):
                answer(self.state, 'D-alpha-T001-1', 'B', **kwargs)
                result = self.state_of()
                self.assertEqual((result['state'], result['answer']), ('waiting', None))
                check = self.cli('check')
                self.assertEqual(check.returncode, 65)
                self.assertIn('D-alpha-T001-1', check.stderr)

    def test_answer_c_continues_for_extend_rounds_and_restarts_stall(self):
        self.stop()
        self.budget().record_card('D-alpha-T001-1')
        answer(self.state, 'D-alpha-T001-1', 'C')
        result = self.state_of()
        self.assertEqual((result['state'], result['budget'], result['card']), ('continue', 5, 'D-alpha-T001-1'))
        self.assertEqual(self.cli('check').returncode, 0)
        append(self.store, 4, ['done a', 'done a', 'open new ground'], head=HEADS[3])
        self.assertEqual(self.state_of()['state'], 'within', 'round 3 does not count toward the stall')
        append(self.store, 5, distinct(5))
        result = self.state_of()
        self.assertEqual((result['state'], result['budget']), ('stop', 5), 'card rounds 3 + extend 2')

    def test_answers_b_and_a_hold_the_task(self):
        for chosen, state in (('B', 'parked'), ('A', 'narrow')):
            with self.subTest(chosen=chosen):
                self.setUp()
                self.stop()
                self.pin = pin(1)
                self.budget().record_card('D-alpha-T001-1')
                answer(self.state, 'D-alpha-T001-1', chosen)
                self.assertEqual(self.state_of()['state'], state)
                check = self.cli('check')
                self.assertEqual(check.returncode, 65)
                self.assertIn('D-alpha-T001-1', check.stderr)


class Release(Base):
    def held(self, chosen='B'):
        for n in range(1, 4):
            append(self.store, n, distinct(n))
        self.pin = pin(1)
        preflight(self.store, SPEC1)
        self.budget().record_card('D-alpha-T001-1')
        answer(self.state, 'D-alpha-T001-1', chosen)

    def test_a_later_authorized_repin_with_spec_ok_releases_a_hold(self):
        for chosen in ('B', 'A'):
            with self.subTest(chosen=chosen):
                self.setUp()
                self.held(chosen)
                self.pin = pin(2, 'repin', '2026-10-06T00:00:00Z', SPEC2)
                self.assertIn(self.state_of()['state'], ('parked', 'narrow'), 'no SPEC-OK for the new bytes yet')
                preflight(self.store, SPEC2)
                result = self.state_of()
                self.assertEqual((result['state'], result['budget']), ('within', 6), 'card rounds 3 + rounds 3')
                append(self.store, 4, ['done a', 'done a', 'open lock'], head=HEADS[3])
                append(self.store, 5, ['done a', 'done a', 'open lock'], head=HEADS[4])
                self.assertEqual(self.state_of()['state'], 'stop', 'the stall counts after the card round')

    def test_spec_approval_time_is_used_when_present(self):
        self.held()
        preflight(self.store, SPEC2)
        self.pin = pin(2, 'repin', '2026-10-06T00:00:00Z', SPEC2, spec_time='2026-10-04T00:00:00Z')
        self.assertEqual(self.state_of()['state'], 'parked')

    def test_no_release_without_an_authorized_later_repin(self):
        cases = dict(
            unpinned_candidate=(pin(1), SPEC2),
            same_bytes=(pin(1), SPEC1),
            approved_before_answer=(pin(2, 'repin', '2026-10-04T23:59:59Z', SPEC2), SPEC2),
            not_a_repin=(pin(2, 'dispatch', '2026-10-06T00:00:00Z', SPEC2), SPEC2))
        for name, (current, preflighted) in cases.items():
            with self.subTest(name=name):
                self.setUp()
                self.held()
                preflight(self.store, preflighted)
                self.pin = current
                self.assertEqual(self.state_of()['state'], 'parked')
                self.assertEqual(self.cli('check').returncode, 65)

    def test_a_pinless_hold_ends_only_through_a_later_card_answered_c(self):
        for chosen, state in (('A', 'narrow'), ('B', 'parked')):
            with self.subTest(chosen=chosen):
                self.setUp()
                for n in range(1, 4):
                    append(self.store, n, distinct(n))
                first = self.budget().record_card('D-alpha-T001-1')
                self.assertIsNone(first['pin'])
                answer(self.state, 'D-alpha-T001-1', chosen)
                preflight(self.store, SPEC1)
                preflight(self.store, SPEC2)
                self.assertEqual(self.state_of()['state'], state, 'a SPEC-OK alone does not release')
                second = self.budget().record_card('D-alpha-T001-2')
                self.assertEqual(second['signature'], first['signature'])
                self.assertEqual(self.state_of()['state'], 'waiting')
                with self.assertRaises(R.Refused):
                    self.budget().record_card('D-alpha-T001-3')
                answer(self.state, 'D-alpha-T001-2', 'C')
                self.assertEqual(self.state_of()['state'], 'continue')

    def test_a_pinned_task_gets_no_second_card_for_one_verdict(self):
        self.held('B')
        with self.assertRaises(R.Refused):
            self.budget().record_card('D-alpha-T001-2')


class Details(unittest.TestCase):
    def rows(self, rounds=12, items=30):
        return [dict(round=n, head=HEADS[n - 1], verdict='REJECT', must=list(range(1, items + 1)),
                     follow=list(range(items + 1, items + 8)), listed=True, marked=True, signature=str(n))
                for n in range(1, rounds + 1)]

    def test_twelve_rounds_of_thirty_items_pass_the_details_check(self):
        content = R.details(T, self.rows(), dict(rounds=12, budget=12), 2, 2)
        report = fm_ste.check_details(content, 'choice')
        self.assertTrue(report.get('ok', True), report)
        plain = fm_ste.check_plain(content)
        self.assertTrue(plain['ok'], plain)
        facts = content['en']['why']
        self.assertEqual(len(facts), 12, 'one older summary, ten rounds and the stall fact')
        self.assertIn('Rounds 1 to 2 are older', facts[0]['text'])
        self.assertIn('Round 12: head ' + HEADS[11][:12] + ', REJECT; must-fix 1, 2, 3, 4, 5 and 25 more;',
                      facts[-2]['text'])
        self.assertEqual(facts[-1]['text'], 'Items open for 2 rounds in a row: 1, 2, 3, 4, 5 and 25 more.')
        self.assertEqual(len(content['zh-TW']['why']), 12)
        for locale in ('en', 'zh-TW'):
            for fact in content[locale]['why']:
                self.assertNotIn('\n', fact['text'])
        for fact in facts:
            self.assertLessEqual(len(fact['text'].split()), 25, fact['text'])
        options = content['en']['options']
        self.assertEqual([options[k]['description'] for k in 'ABC'],
                         ['Narrow the scope.', 'Park the task.', 'Continue 2 more review rounds.'])
        for option in list(options.values()) + list(content['zh-TW']['options'].values()):
            self.assertTrue(all(option[k] for k in ('description', 'pros', 'cons')))


def tw2cn(text):
    rows = (ROOT / 'i18n/tw2cn.tsv').read_text(encoding='utf-8').split('\n')
    for line in rows:
        if not line or line.startswith('#'):
            continue
        pair = line.split('\t')
        if len(pair) == 2 and pair[0]:
            text = pair[1].join(text.split(pair[0]))
    return text


class Simplified(unittest.TestCase):
    """The board's zh-CN is the table applied to the fixed zh-TW text."""
    def test_fixed_wake_and_card_text_converts(self):
        content = R.details(T, [dict(round=3, head=HEADS[2], verdict='REJECT', must=list(range(1, 31)), follow=[],
                                     listed=True, marked=True, signature='s')], dict(rounds=3, budget=3), 2, 2)
        tw = content['zh-TW']
        fixed = {
            'T-001 已核准，但仍有 2 個後續項目；請在決策卡上提出後續任務': 'T-001 已核准，但仍有 2 个后续项目；请在决策卡上提出后续任务',
            'T-001：回合預算決策卡建立失敗：boom；請手動提出並執行 record-card': 'T-001：回合预算决策卡建立失败：boom；请手动提出并执行 record-card',
            'T-001：回合預算決策卡建立失敗；請手動提出並執行 record-card': 'T-001：回合预算决策卡建立失败；请手动提出并执行 record-card',
            'T-001：審查回合已達上限（3／3）；決策卡 D-1': 'T-001：审查回合已达上限（3／3）；决策卡 D-1',
            'T-001 已由船長暫停（決策卡 D-1）': 'T-001 已由船长暂停（决策卡 D-1）',
            'T-001：船長選擇縮小範圍（決策卡 D-1）；請準備重新釘選規格': 'T-001：船长选择缩小范围（决策卡 D-1）；请准备重新钉选规格',
            'T-001：審查回合已達上限（3／3）；請撰寫回合預算決策卡': 'T-001：审查回合已达上限（3／3）；请撰写回合预算决策卡',
            'T-001：回合預算狀態無法讀取；請檢查 config.yaml 的 review_budget 與回合預算檔':
                'T-001：回合预算状态无法读取；请检查 config.yaml 的 review_budget 与回合预算档',
            tw['title']: 'T-001：审查回合已用完；请选择下一步',
            tw['explanation']: 'T-001 的审查已达回合预算。任务等待你的选择。',
            tw['before']: 'T-001 已用 3／3 个审查回合。',
            tw['after']: '你的回答决定任务的下一步。',
            tw['outcome']: '自动驾驶依你的回答处理。',
            tw['options']['A']['description']: '缩小范围。',
            tw['options']['A']['pros']: '较小的规格较快通过审查。',
            tw['options']['A']['cons']: 'firstmate 撰写较小的规格，你核准重新钉选。',
            tw['options']['B']['description']: '暂停任务。',
            tw['options']['B']['pros']: '不再花费审查回合。',
            tw['options']['B']['cons']: '任务保持打开且未合并。',
            tw['options']['C']['description']: '再进行 2 个审查回合。',
            tw['options']['C']['pros']: '工作范围保持不变。',
            tw['options']['C']['cons']: '相同问题仍需更多回合。',
            tw['intent'][0]['text']: '请选择 T-001 的下一步。',
            tw['done'][0]['text']: '意图 1：自动驾驶记录你的回答。',
            tw['how'][0]['text']: 'A：firstmate 撰写较小的规格，并请你核准重新钉选。',
            tw['how'][1]['text']: 'B：自动驾驶停止此任务的所有关卡与审查。',
            tw['how'][2]['text']: 'C：自动驾驶再给 2 个审查回合。',
            tw['why'][0]['text']: '第 3 轮：版本 333333333333，REJECT；必修 1, 2, 3, 4, 5 另 25 项；后续 无。',
            tw['why'][1]['text']: '没有项目连续 2 轮未修。',
            '第 1 至 2 輪較早；fm_round_budget.py history 列出每一輪。': '第 1 至 2 轮较早；fm_round_budget.py history 列出每一轮。',
            '連續 2 輪未修的項目：1。': '连续 2 轮未修的项目：1。',
        }
        for source, expected in fixed.items():
            with self.subTest(source=source):
                self.assertEqual(tw2cn(source), expected)


PR = dict(number=12, title='T-001: fixture', state='open', head=dict(ref='t-001-fixture', sha=HEADS[0]),
          base=dict(ref='main', sha='b' * 40), mergeable=True, mergeable_state='clean', draft=False)
CHECKS = [dict(id=1, name='ci', status='completed', conclusion='success')]
CARD = 'D-alpha-T001-1'


def pr(n):
    return dict(PR, head=dict(PR['head'], sha=HEADS[n - 1]))


def checks(n):
    return [dict(CHECKS[0], head_sha=HEADS[n - 1])]


from autopilot_branch_fixture import BranchFixture  # noqa: E402
import fm_autopilot as A  # noqa: E402


class Autopilot(BranchFixture, unittest.TestCase):
    """Both REJECT branches, the holds, running jobs and the card step."""
    def setUp(self, external=False):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.state = self.root / 'state'; self.state.mkdir()
        (self.root / 'tasks').mkdir()
        self.ctx = dict(engine=str(self.root), state=str(self.state), target=str(self.root),
                        project='alpha', evidence_project='alpha', repository='owner/alpha',
                        base='main', external=external, tasks=str(self.root / 'tasks'))
        self.calls = []
        self.fail_request = None
        self.branch_setup()
        self.pin = None
        holder = patch.object(R.Budget, 'pin', new=lambda budget: self.pin)
        holder.start(); self.addCleanup(holder.stop)
        self.pilot = self.pilot_for()
        if external:
            # This fixture has no confirmed CONVENTIONS.md; its policy wake is not under test.
            self.pilot.policy_error = None
            self.pilot.data['wakes'] = {}

    def pilot_for(self):
        pilot = A.Pilot(self.ctx)
        pilot.api = lambda endpoint: dict(contexts=['ci'], checks=[])
        pilot.start_job = lambda kind, *a, **k: self.calls.append(('job', kind))
        pilot.authoritative_head = lambda task, pr: pr['head']['sha']
        pilot.command = self.command
        pilot.probe = self.branch_probe
        pilot.task = lambda pr: T
        pilot.emit = lambda *a, **kw: self.calls.append(('emit', a))
        pilot.busy = lambda task: False
        if self.ctx['external']:
            # Every new pilot re-reads the missing CONVENTIONS.md; that wake is not under test.
            pilot.policy_error = None
            pilot.data['wakes'] = {k: v for k, v in pilot.data['wakes'].items()
                                   if not v['line'].startswith('Conventions unavailable')}
        return pilot

    def command(self, argv, **kwargs):
        argv = [str(a) for a in argv]
        self.calls.append(('command', argv))
        if argv[0] == 'git':
            return 'b' * 40 + '\n'
        if '--allocate' in argv:
            folder = self.state / 'decision-ids' / 'alpha' / 'T001'
            folder.mkdir(parents=True, exist_ok=True)
            n = len(list(folder.glob('*.json'))) + 1
            (folder / f'{n}.json').write_text('{}')
            return f'D-alpha-T001-{n}\n'
        if '--request' in argv:
            if self.fail_request:
                raise RuntimeError(self.fail_request)
            ident = argv[argv.index('--request') + 1]
            json.loads(Path(argv[argv.index('--details') + 1]).read_text())
            (self.state / 'pending').mkdir(exist_ok=True)
            # Shaped like the record the real fm-decide.sh writes.
            kind = argv[argv.index('--kind') + 1] if '--kind' in argv else 'choice'
            record = dict(id=ident, expected_head='', binding=None, task=T, kind=kind)
            if '--purpose' in argv:
                record['purpose'] = argv[argv.index('--purpose') + 1]
            (self.state / 'pending' / (ident + '.json')).write_text(json.dumps(record))
            return str(self.state / 'pending' / (ident + '.json')) + '\n'
        return ''

    def store(self):
        return E.Store(str(self.state), 'alpha', T, external=self.ctx['external'])

    def reject(self, n, items=None, **extra):
        return append(self.store(), n, distinct(n) if items is None else items, **extra)

    def advance(self, n):
        self.pilot.advance(pr(n), checks(n), [])

    def wakes(self):
        return [w['summary'] for w in self.pilot.data['wakes'].values()]

    def wake_id(self, identity):
        return 'autopilot-' + A.key(['alpha', identity])

    def commands(self, flag):
        return [argv for kind, *rest in self.calls if kind == 'command' for argv in rest
                if any(flag in arg for arg in argv)]

    def jobs(self):
        return [c for c in self.calls if c[0] == 'job']

    def card_wake(self, rounds, budget, ident=CARD):
        return {'en': f'T-001: round budget reached ({rounds} of {budget} review rounds); captain card {ident}',
                'zh-TW': f'T-001：審查回合已達上限（{rounds}／{budget}）；決策卡 {ident}'}

    def stopped(self):
        for n in range(1, 4):
            self.reject(n)
        self.advance(3)

    def test_the_third_marked_reject_raises_a_card_and_no_brief_wake(self):
        # Fail-first: main wakes firstmate for a brief on the third REJECT.
        self.stopped()
        self.assertEqual(self.wakes(), [self.card_wake(3, 3)])
        self.assertNotIn('brief needed', str(self.wakes()))
        self.assertEqual(self.jobs(), [], 'no gate and no review')
        request = self.commands('--request')
        self.assertEqual(len(request), 1)
        argv = request[0]
        for flag, value in (('--request', CARD), ('--task', T), ('--project', 'alpha'), ('--purpose', 'decision'),
                            ('--details', str(self.state / 'decision-details-built' / (CARD + '.json')))):
            self.assertEqual(argv[argv.index(flag) + 1], value)
        details = json.loads((self.state / 'decision-details-built' / (CARD + '.json')).read_text())
        self.assertTrue(fm_ste.check_details(details, 'choice').get('ok', True))
        cards = json.loads((self.state / 'round-budget' / (T + '.json')).read_text())['cards']
        self.assertEqual([card['id'] for card in cards], [CARD])
        self.advance(3)
        self.assertEqual(self.wakes(), [self.card_wake(3, 3)], 'one wake per card')
        self.assertEqual((len(self.commands('--allocate')), len(self.commands('--request'))), (1, 1))

    def test_rounds_five_moves_the_stop_to_round_five(self):
        # Fail-first: main has no budget and no card.
        config(self.root, 'review_budget:\n  rounds: 5\n')
        for n in range(1, 6):
            self.reject(n)
            self.advance(n)
        rejects = [w for w in self.wakes() if w['en'].startswith('T-001 REJECT:')]
        self.assertEqual(len(rejects), 4, 'rounds 1 to 4 keep the ordinary wake')
        self.assertEqual(self.wakes()[-1], self.card_wake(5, 5))
        self.assertEqual(len(self.commands('--request')), 1)

    def test_a_must_fix_item_open_in_rounds_one_and_two_raises_the_card(self):
        # Fail-first: main wakes for a brief.
        self.reject(1, ['open lock'])
        self.advance(1)
        self.reject(2, ['open lock'])
        self.advance(2)
        self.assertEqual(self.wakes()[-1], self.card_wake(2, 3))
        details = json.loads((self.state / 'decision-details-built' / (CARD + '.json')).read_text())
        self.assertEqual(details['en']['why'][-1]['text'], 'Items open for 2 rounds in a row: 1.')

    def test_the_review_result_branch_raises_the_card_too(self):
        for n in (1, 2):
            self.reject(n)
            self.advance(n)
        self.reject(3)
        self.pilot.job_completed(dict(kind='review', task=T, pr=pr(3), code=0, round=3, base='b' * 40, output=''))
        self.assertEqual(self.wakes()[-1], self.card_wake(3, 3))
        self.assertEqual(self.jobs(), [])

    def test_an_unmarked_reject_at_round_five_keeps_the_brief_wake_and_no_card(self):
        for n in range(1, 6):
            self.reject(n, ['open lock'], marked=False)
        self.advance(5)
        self.assertEqual(len(self.wakes()), 1)
        self.assertIn('T-001 REJECT:', self.wakes()[0]['en'])
        self.assertEqual(self.commands('--request'), [])
        self.assertFalse((self.state / 'round-budget').exists())

    def test_answer_c_raises_exactly_one_continue_wake_also_after_a_restart(self):
        # Fail-first: main has no card to answer.
        self.stopped()
        # The ordinary wake for this head was queued first.
        self.pilot.attention('reject', T, pr(3), 'T-001 REJECT: brief needed', 'T-001 審查拒絕：需要 firstmate 撰寫工作簡報')
        answer(self.state, CARD, 'C')
        self.advance(3); self.advance(3)
        self.assertIn(self.wake_id('budget-continue-' + CARD), self.pilot.data['wakes'])
        rejects = [w for w in self.wakes() if w['en'].startswith('T-001 REJECT:')]
        self.assertEqual(len(rejects), 2, 'the ordinary wake and one continue wake')
        self.pilot = self.pilot_for()
        self.advance(3)
        self.assertEqual(len([w for w in self.wakes() if w['en'].startswith('T-001 REJECT:')]), 2)
        self.assertEqual(self.jobs(), [])
        self.reject(4)
        self.advance(4)
        self.assertEqual(len(self.commands('--request')), 1, 'round 4 is within 3 + extend 2')
        self.reject(5)
        self.advance(5)
        self.assertEqual(self.wakes()[-1], self.card_wake(5, 5, 'D-alpha-T001-2'))

    def test_answer_b_parks_gates_reviews_and_reject_wakes(self):
        # Fail-first: main keeps waking and gating.
        self.stopped()
        answer(self.state, CARD, 'B')
        before = len(self.wakes())
        self.calls.clear()
        self.advance(3); self.advance(3)
        self.pilot.advance(pr(4), checks(4), [])  # a new head pushed by hand
        park = {'en': f'T-001 parked by the captain (card {CARD})', 'zh-TW': f'T-001 已由船長暫停（決策卡 {CARD}）'}
        self.assertEqual(self.wakes()[before:], [park])
        self.assertEqual(self.jobs(), [])
        self.assertFalse(any(c[0] == 'command' and (os.path.basename(c[1][0]) == 'gh' or 'fm-protocol.sh' in ' '.join(c[1]))
                             for c in self.calls), 'nothing is written to GitHub')

    def held_results(self):
        results = [dict(kind='protocol', code=0), dict(kind='gate', code=6), dict(kind='gate', code=0),
                   dict(kind='review', code=0)]
        return [dict(result, task=T, pr=pr(3), round=3, base='b' * 40, output='') for result in results]

    def test_a_held_tasks_running_results_start_no_gate_review_or_merge_card(self):
        # Fail-first: main starts the gate, the review and the merge card.
        for hold in ('stop', 'waiting', 'parked', 'narrow'):
            with self.subTest(hold=hold):
                self.setUp()
                for n in range(1, 4):
                    self.reject(n)
                if hold != 'stop':
                    self.advance(3)
                if hold in ('parked', 'narrow'):
                    answer(self.state, CARD, 'B' if hold == 'parked' else 'A')
                self.assertEqual(self.pilot.budget_reader(T).state_of()['state'], hold)
                self.calls.clear()
                for result in self.held_results():
                    if result['kind'] == 'review' and hold == 'stop':
                        continue  # a review result in the stop state raises the card, covered above
                    self.pilot.job_completed(result)
                self.assertEqual(self.jobs(), [])
                self.assertEqual(self.commands('--allocate'), [], 'no merge card')
                # Replayed through consume_jobs and recover_jobs, every job is still marked done.
                for index, result in enumerate(self.held_results()[:3]):
                    path = self.state / f'job{index}.json'
                    path.with_suffix('.result.json').write_text(json.dumps(result))
                    self.pilot.data['jobs'] = {'job': dict(kind=result['kind'], task=T, number=12, head=HEADS[2],
                                                           state='running', path=str(path))}
                    (self.pilot.recover_jobs if index else self.pilot.consume_jobs)()
                    self.assertEqual(self.pilot.data['jobs']['job']['state'], 'done')
                self.assertEqual(self.jobs(), [])

    def test_answer_a_holds_until_an_authorized_repin_after_the_answer(self):
        # Fail-first: main has no hold.
        self.pin = pin(1)
        self.stopped()
        answer(self.state, CARD, 'A')
        self.advance(3); self.advance(3)
        narrow = {'en': f'T-001: captain chose to narrow the scope (card {CARD}); prepare a repin',
                  'zh-TW': f'T-001：船長選擇縮小範圍（決策卡 {CARD}）；請準備重新釘選規格'}
        self.assertEqual(self.wakes()[-1], narrow)
        self.assertEqual(len([w for w in self.wakes() if w == narrow]), 1)
        preflight(self.store(), SPEC2)
        self.pin = pin(2, 'repin', '2026-10-04T00:00:00Z', SPEC2)  # approved before the answer
        self.advance(3)
        self.assertNotIn('T-001 REJECT:', str(self.wakes()))
        self.pin = pin(2, 'repin', '2026-10-06T00:00:00Z', SPEC2)
        self.advance(3)
        self.assertIn('T-001 REJECT:', str(self.wakes()), 'released: the REJECT gets its ordinary wake')
        self.assertEqual(self.pilot.budget_reader(T).state_of()['budget'], 6)

    def test_a_failed_card_wakes_and_a_restart_requests_the_same_id(self):
        self.fail_request = 'decide exploded'
        self.stopped()
        self.assertEqual(self.wakes(), [{
            'en': 'T-001: round budget card failed: decide exploded; raise it by hand and run record-card',
            'zh-TW': 'T-001：回合預算決策卡建立失敗：decide exploded；請手動提出並執行 record-card'}])
        self.advance(3)
        self.assertEqual(len(self.wakes()), 1, 'one failure wake per verdict')
        self.fail_request = None
        self.pilot = self.pilot_for()
        self.advance(3)
        requests = [argv[argv.index('--request') + 1] for argv in self.commands('--request')]
        self.assertEqual(requests, [CARD, CARD, CARD])
        self.assertEqual(len(self.commands('--allocate')), 1)
        self.assertEqual(self.wakes()[-1], self.card_wake(3, 3))

    def test_external_wakes_carry_no_private_text_and_projects_keep_separate_files(self):
        self.setUp(external=True)
        for n in range(1, 4):
            self.reject(n, distinct(n)[:-1] + ['open SECRET_ITEM in /private/SECRET_PATH'],
                        actor='reviewer-secretname-t001-r1')
        self.advance(3); self.advance(3)
        author = {'en': 'T-001: round budget reached (3 of 3 review rounds); author the round budget card',
                  'zh-TW': 'T-001：審查回合已達上限（3／3）；請撰寫回合預算決策卡'}
        self.assertEqual(self.wakes(), [author])
        self.assertEqual(self.commands('fm-decide.sh'), [])
        self.assertFalse((self.state / 'decision-details-built').exists())
        latest = self.store().verdicts()[-1]
        self.pilot.budget_failed(T, latest['signature'], 'request failed at /private/SECRET_PATH for ' + HEADS[2])
        self.assertEqual(self.wakes()[-1], {
            'en': 'T-001: round budget card failed; raise it by hand and run record-card',
            'zh-TW': 'T-001：回合預算決策卡建立失敗；請手動提出並執行 record-card'})
        self.pilot.budget_reader(T).record_card(CARD)
        self.pilot = self.pilot_for()
        self.advance(3); self.advance(3)
        self.assertEqual(self.wakes()[-1], self.card_wake(3, 3))
        self.assertEqual(len(self.wakes()), 3)
        public = json.dumps(list(self.pilot.data['wakes'].values()), ensure_ascii=False) + str(
            [c for c in self.calls if c[0] == 'emit'])
        for secret in ('SECRET_ITEM', 'SECRET_PATH', 'secretname', HEADS[2][:12], str(self.state), 'round-budget'):
            self.assertNotIn(secret, public)
        # Two projects with the same task id keep separate private files.
        other = self.root / 'beta-state'
        append(E.Store(str(other), 'beta', T, external=True), 1, ['open lock'])
        append(E.Store(str(other), 'beta', T, external=True), 2, ['open lock'])
        R.Budget(str(other), 'beta', T, self.root / 'config.yaml', env={}, external=True).record_card('D-beta-T001-1')
        mine = json.loads((self.state / 'round-budget' / (T + '.json')).read_text())
        theirs = json.loads((other / 'round-budget' / (T + '.json')).read_text())
        self.assertEqual(([c['id'] for c in mine['cards']], mine['project']), ([CARD], 'alpha'))
        self.assertEqual(([c['id'] for c in theirs['cards']], theirs['project']), (['D-beta-T001-1'], 'beta'))


def main_modes(argv):
    if argv[:1] == ['details']:
        task, path = argv[1:3]
        rows = [dict(round=n, head=HEADS[n - 1], verdict='REJECT', must=list(range(1, 31)),
                     follow=list(range(31, 36)), listed=True, marked=True, signature=str(n)) for n in range(1, 13)]
        Path(path).write_text(json.dumps(R.details(task, rows, dict(rounds=12, budget=12), 2, 2), ensure_ascii=False))
        return 0
    if argv[:1] == ['consumer']:
        import fm_autopilot as A
        engine, state, project, task = argv[1:5]
        pilot = A.Pilot(dict(engine=engine, state=state, target=engine, project='', evidence_project=project,
                             repository='owner/engine', base='main', external=False,
                             tasks=str(Path(engine) / 'design/tasks')))
        reader = pilot.budget_reader(task)
        print(json.dumps(dict(config=reader.config, state=reader.state_of()['state'])))
        return 0
    if argv[:1] == ['seed']:
        state, project, task, round_number, head = argv[1:6]
        items = ''.join(f'{n}. {line}\n' for n, line in enumerate(distinct(int(round_number)), 1))
        E.Store(state, project, task, external=False).append(
            'verdict', int(round_number), 'reviewer-ada-' + task.lower().replace('-', '') + '-r1', head,
            items + f'CRITERIA-COMPLETE:{task}\nREJECT:{task}\n',
            verdict='REJECT', provenance={'level': 'legacy'}, severity_protocol=1)
        return 0
    return None


if __name__ == '__main__':
    if sys.argv[1:2] in (['details'], ['consumer'], ['seed']):
        sys.exit(main_modes(sys.argv[1:]))
    unittest.main()
