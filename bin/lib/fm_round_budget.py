#!/usr/bin/env python3
"""Review round budget (T-276): when a task's review loop stops for the captain.

The state comes from the task's retained verdicts (Store.verdicts(), so the
FM_REVIEWER_LOGIN filter applies), the engine config.yaml `review_budget:`
block and the budget cards in `<project state>/round-budget/<task>.json`.
A card's answer is the answered decision record of the same id and task.
Nothing here writes a verdict, a pin or a decision record.
"""
import argparse
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from fm_evidence import Store, criteria, item_is_open, severity  # noqa: E402

BIN = Path(__file__).resolve().parents[1]
DEFAULTS = dict(rounds=3, stall=2, extend=2)
# States in which no gate, review, merge card, brief or worker round starts.
HELD = ('stop', 'waiting', 'parked', 'narrow')
NUMBERS = 5
ROUND_FACTS = 10


class Refused(ValueError):
    """record-card refused; nothing was written (exit 65)."""


def config(path):
    """The three budget keys through the one config reader; a bad value names its key."""
    script = ('. "$1/fm-config.sh"; for key in rounds stall extend; do '
              'printf "%s\\n" "$(fm_cfg_in review_budget "$key" "$2" 2>/dev/null || true)"; done')
    result = subprocess.run(['bash', '-c', script, '_', str(BIN), str(path)], stdin=subprocess.DEVNULL,
                            capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise ValueError('cannot read review_budget from ' + str(path))
    values = result.stdout.split('\n')
    output = {}
    for index, (key, default) in enumerate(DEFAULTS.items()):
        value = values[index].strip() if index < len(values) else ''
        if not value:
            output[key] = default
        elif re.fullmatch(r'[0-9]{1,2}', value) and 1 <= int(value) <= 99:
            output[key] = int(value)
        else:
            raise ValueError(f'review_budget.{key} must be a whole number from 1 to 99, not {value!r}')
    return output


def rounds(store):
    """One row per review round, represented by its last retained record."""
    by_round = {}
    for record in store.verdicts():
        by_round[int(record['round'])] = record
    rows = []
    listed_before = False
    for number in sorted(by_round):
        record = by_round[number]
        items = criteria(record.get('text', ''), store.task)
        must, follow = [], []
        for n, body in items:
            if item_is_open(body, store.task, listed_before):
                (must if severity(body) == 'must-fix' else follow).append(n)
        rows.append(dict(round=number, head=record.get('head', ''), verdict=record.get('verdict'),
                         signature=record.get('signature', ''), marked=record.get('severity_protocol') == 1,
                         listed=bool(items), must=must, follow=follow))
        listed_before = listed_before or bool(items)
    return rows


def stalled(rows, after, stall):
    """Items open and must-fix in the last `stall` rounds after round `after`."""
    window = [row for row in rows if row['round'] > after]
    if len(window) < stall:
        return []
    tail = window[-stall:]
    return sorted(n for n in tail[-1]['must']
                  if all(row['verdict'] != 'APPROVE' and row['listed'] and n in row['must'] for row in tail))


def moment(text):
    value = datetime.datetime.fromisoformat(str(text).replace('Z', '+00:00'))
    if value.tzinfo is None:
        raise ValueError('time without a zone')
    return value


class Budget:
    def __init__(self, state, project, task, config_path, env=None, external=None):
        self.store = Store(state, project, task, external=external)
        self.state = Path(state)
        self.project, self.task = project, task
        self.env = os.environ if env is None else env
        self.config = config(config_path)
        self.path = self.state / 'round-budget' / (task + '.json')

    def pin(self):
        from fm_spec_pins import Pins
        if any(key not in self.env for key in ('FM_ENGINE_ROOT', 'FM_TARGET_ROOT', 'FM_STATE_DIR',
                                                'FM_TASKS_DIR', 'FM_DESIGN')):
            raise ValueError('reading the spec pin needs the project environment from fm_storage_init')
        return Pins(self.env, self.task).resolve(if_present=True)

    def cards(self):
        if not self.path.exists():
            return []
        if self.path.is_symlink():
            raise ValueError('round-budget file must not be a symlink')
        data = json.loads(self.path.read_text())
        if data.get('version') != 1 or data.get('task') != self.task or not isinstance(data.get('cards'), list):
            raise ValueError('invalid round-budget file')
        if data.get('project', self.project) != self.project:
            raise ValueError('round-budget file belongs to another project')
        return data['cards']

    def answer(self, card):
        """The answered decision record whose id and task match the card, else None."""
        ident = card.get('id', '')
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*', ident):
            return None
        path = self.state / 'decisions' / (ident + '.json')
        if not path.is_file() or path.is_symlink():
            return None
        try:
            record = json.loads(path.read_text())
        except ValueError:
            return None
        if (not isinstance(record, dict) or record.get('id') != ident or record.get('task') != self.task
                or record.get('chosen') not in ('A', 'B', 'C') or not record.get('ts')):
            return None
        return record

    def released(self, card, reply):
        """An A or B hold ends at an authorized repin approved after the answer."""
        if card.get('pin') is None:
            return False  # a repin needs an existing pin; only a later C card resumes
        try:
            pin = self.pin()
            if not pin or pin.get('version', 0) <= card['pin'] or pin.get('source') != 'repin':
                return False
            approval = pin.get('spec_approval') or pin.get('approval') or {}
            if not moment(approval.get('time')) > moment(reply['ts']):
                return False
            from fm_spec_preflight import require_ok
            require_ok(self.store, pin['snapshots']['spec']['text'].encode('utf-8'))
            return True
        except (ValueError, OSError, KeyError, TypeError, AttributeError):
            return False

    def state_of(self):
        rows = rounds(self.store)
        cards = self.cards()
        budget, after = self.config['rounds'], 0
        card = cards[-1] if cards else None
        result = dict(state='within', rounds=len(rows), budget=budget, stalled=[], card=None,
                      answer=None, latest=rows[-1] if rows else None)
        if card:
            reply = self.answer(card)
            result.update(card=card['id'], answer=reply and reply['chosen'], record=card)
            if reply is None:
                return dict(result, state='waiting', budget=card['budget'])
            if reply['chosen'] == 'C':
                budget, after = card['rounds'] + card['extend'], card['round']
            elif self.released(card, reply):
                budget, after = card['rounds'] + self.config['rounds'], card['round']
            else:
                return dict(result, state='parked' if reply['chosen'] == 'B' else 'narrow')
        result['budget'] = budget
        latest = result['latest']
        if latest and latest['marked'] and latest['verdict'] == 'REJECT':
            stuck = stalled(rows, after, self.config['stall'])
            if len(rows) >= budget or stuck:
                return dict(result, state='stop', stalled=stuck)
        if card and result['answer'] == 'C' and latest and latest['signature'] == card['signature']:
            result['state'] = 'continue'
        return result

    def save(self, cards):
        folder = self.path.parent
        fd, pending = tempfile.mkstemp(prefix='.round-budget-', dir=folder)
        try:
            with os.fdopen(fd, 'w') as stream:
                json.dump(dict(version=1, project=self.project, task=self.task, cards=cards), stream,
                          indent=2, ensure_ascii=False)
                stream.write('\n')
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(pending, self.path)
        except BaseException:
            if os.path.exists(pending):
                os.unlink(pending)
            raise

    def record_card(self, ident):
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*', ident or ''):
            raise Refused('invalid decision id')
        folder = self.path.parent
        folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (folder / '.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            cards = self.cards()
            current = self.state_of()
            latest = current['latest']
            if any(card['id'] == ident for card in cards):
                raise Refused(f'card {ident} is already recorded')
            pin = self.pin()
            same = [card for card in cards if latest and card['signature'] == latest['signature']]
            if current['state'] == 'stop' and not same:
                budget = current['budget']
            elif (current['state'] in ('parked', 'narrow') and same and same[-1] is cards[-1]
                    and cards[-1].get('pin') is None and pin is None):
                budget = cards[-1]['budget']  # a pinless task resumes only through a new card
            elif same:
                raise Refused('a card is already recorded for the latest stopping verdict')
            else:
                raise Refused('the task has not stopped at its round budget')
            card = dict(id=ident, head=latest['head'], signature=latest['signature'], round=latest['round'],
                        rounds=current['rounds'], budget=budget, extend=self.config['extend'],
                        pin=pin['version'] if pin else None,
                        time=datetime.datetime.now(datetime.timezone.utc).isoformat())
            self.save(cards + [card])
            return card

    def history(self):
        return rounds(self.store)


def numbers(values, english):
    if not values:
        return 'none' if english else '無'
    shown = ', '.join(map(str, values[:NUMBERS]))
    more = len(values) - NUMBERS
    if more > 0:
        shown += f' and {more} more' if english else f' 另 {more} 項'
    return shown


def details(task, rows, card, stall, extend, after=0):
    """Choice-card details from the round history; every fact fits fm_ste's limits."""
    en_facts, tw_facts = [], []
    older, recent = rows[:-ROUND_FACTS] if len(rows) > ROUND_FACTS else [], rows[-ROUND_FACTS:]
    if older:
        first, last = older[0]['round'], older[-1]['round']
        en_facts.append(f'Rounds {first} to {last} are older; fm_round_budget.py history lists every round.')
        tw_facts.append(f'第 {first} 至 {last} 輪較早；fm_round_budget.py history 列出每一輪。')
    for row in recent:
        head = (row['head'] or 'unknown')[:12]
        verdict = row['verdict'] or 'REJECT'
        en_facts.append(f'Round {row["round"]}: head {head}, {verdict}; must-fix {numbers(row["must"], True)}; '
                        f'follow-up {numbers(row["follow"], True)}.')
        tw_facts.append(f'第 {row["round"]} 輪：版本 {head}，{verdict}；必修 {numbers(row["must"], False)}；'
                        f'後續 {numbers(row["follow"], False)}。')
    stuck = stalled(rows, after, stall)
    if stuck:
        en_facts.append(f'Items open for {stall} rounds in a row: {numbers(stuck, True)}.')
        tw_facts.append(f'連續 {stall} 輪未修的項目：{numbers(stuck, False)}。')
    else:
        en_facts.append(f'No item stayed open for {stall} rounds in a row.')
        tw_facts.append(f'沒有項目連續 {stall} 輪未修。')
    used, budget = card['rounds'], card['budget']
    return {
        'en': dict(
            title=f'{task}: review rounds ran out; choose the next step',
            explanation=f'The review of {task} reached its round budget. The task waits for your choice.',
            before=f'{task} used {used} of {budget} review rounds.',
            after='Your answer sets the next step for the task.',
            outcome='The autopilot follows your answer.',
            options=dict(
                A=dict(description='Narrow the scope.', pros='A smaller spec can pass review sooner.',
                       cons='Firstmate writes a smaller spec, and you approve its repin.'),
                B=dict(description='Park the task.', pros='No more review rounds use time or money.',
                       cons='The task stays open and unmerged.'),
                C=dict(description=f'Continue {extend} more review rounds.',
                       pros='The worker keeps the current scope.',
                       cons='The same findings can take more rounds.')),
            intent=[dict(kind='step', text=f'Choose the next step for {task}.')],
            why=[dict(kind='fact', text=text) for text in en_facts],
            how=[dict(kind='fact', text='A: firstmate writes a smaller spec and asks you to approve its repin.'),
                 dict(kind='fact', text='B: the autopilot stops all gates and reviews for the task.'),
                 dict(kind='fact', text=f'C: the autopilot allows {extend} more review rounds.')],
            glossary=['autopilot', 'round', 'scope', 'repin', 'gate'],
            done=[dict(kind='fact', text='Intent 1: the autopilot records your answer.')]),
        'zh-TW': dict(
            title=f'{task}：審查回合已用完；請選擇下一步',
            explanation=f'{task} 的審查已達回合預算。任務等待你的選擇。',
            before=f'{task} 已用 {used}／{budget} 個審查回合。',
            after='你的回答決定任務的下一步。',
            outcome='自動駕駛依你的回答處理。',
            options=dict(
                A=dict(description='縮小範圍。', pros='較小的規格較快通過審查。',
                       cons='firstmate 撰寫較小的規格，你核准重新釘選。'),
                B=dict(description='暫停任務。', pros='不再花費審查回合。', cons='任務保持開啟且未合併。'),
                C=dict(description=f'再進行 {extend} 個審查回合。', pros='工作範圍保持不變。',
                       cons='相同問題仍需更多回合。')),
            intent=[dict(kind='step', text=f'請選擇 {task} 的下一步。')],
            why=[dict(kind='fact', text=text) for text in tw_facts],
            how=[dict(kind='fact', text='A：firstmate 撰寫較小的規格，並請你核准重新釘選。'),
                 dict(kind='fact', text='B：自動駕駛停止此任務的所有關卡與審查。'),
                 dict(kind='fact', text=f'C：自動駕駛再給 {extend} 個審查回合。')],
            glossary=['autopilot', 'round', 'scope', 'repin', 'gate'],
            done=[dict(kind='fact', text='意圖 1：自動駕駛記錄你的回答。')]),
    }


def message(task, result):
    card = result.get('card')
    if result['state'] == 'stop':
        return (f'{task}: review round budget reached ({result["rounds"]} of {result["budget"]} review rounds); '
                'no card was raised yet')
    if result['state'] == 'waiting':
        return f'{task}: review round budget reached; captain card {card} waits for an answer'
    if result['state'] == 'parked':
        return f'{task} is parked by the captain (card {card})'
    return f'{task}: the captain chose to narrow the scope (card {card}); repin it first'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['check', 'state', 'record-card', 'history'])
    parser.add_argument('--state', required=True)
    parser.add_argument('--project', required=True)
    parser.add_argument('--task', required=True)
    parser.add_argument('--config', default=str(BIN.parent / 'config.yaml'))
    parser.add_argument('--id')
    parser.add_argument('--external', action='store_true', default=None)
    args = parser.parse_args()
    budget = Budget(args.state, args.project, args.task, args.config, external=args.external)
    if args.command == 'check':
        result = budget.state_of()
        if result['state'] in HELD:
            print('fm-round-budget: ' + message(args.task, result), file=sys.stderr)
            return 65
    elif args.command == 'state':
        print(json.dumps(budget.state_of(), ensure_ascii=False))
    elif args.command == 'record-card':
        print(json.dumps(budget.record_card(args.id), ensure_ascii=False))
    elif args.command == 'history':
        print(json.dumps(budget.history(), ensure_ascii=False))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        # A refused card and a configuration error both stop the caller (65).
        print('fm-round-budget: ' + str(error), file=sys.stderr)
        sys.exit(65)
