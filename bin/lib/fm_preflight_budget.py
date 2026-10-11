#!/usr/bin/env python3
"""Spec preflight pass budget (T-288): when a task's preflights stop for the captain.

A pass is a receipt that counts toward the budget (`pass_budget` on receipts
written since T-288; older receipts never count). A task gets PASSES passes
after its last answered budget card. The cards live in
`<project state>/preflight-budget/<task>.json`; a card's answer is the
answered decision record of the same id and task, and any answer resets the
count. Nothing here writes a receipt, a pin or a decision record.
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
from fm_evidence import Store  # noqa: E402

PASSES = 3
IDENT = re.compile(r'[A-Za-z0-9][A-Za-z0-9_-]*')


class Refused(ValueError):
    """record-card refused; nothing was written (exit 65)."""


class Unrequested(ValueError):
    """The card is recorded but its request failed; the message says how to request it."""


class Budget:
    def __init__(self, state, project, task, external=None):
        self.store = Store(state, project, task, external=external)
        self.state = Path(state)
        self.project, self.task = project, task
        self.path = self.state / 'preflight-budget' / (task + '.json')

    def passes(self):
        return [record for record in self.store.records()
                if record['kind'] == 'spec-preflight' and record.get('pass_budget') == 1]

    def cards(self):
        if not self.path.exists():
            return []
        if self.path.is_symlink():
            raise ValueError('preflight-budget file must not be a symlink')
        data = json.loads(self.path.read_text())
        if (data.get('version') != 1 or data.get('task') != self.task or data.get('project') != self.project
                or not isinstance(data.get('cards'), list)):
            raise ValueError('invalid preflight-budget file')
        return data['cards']

    def answer(self, card):
        """The answered decision record whose id and task match the card, else None."""
        ident = card.get('id', '')
        if not IDENT.fullmatch(ident):
            return None
        path = self.state / 'decisions' / (ident + '.json')
        if not path.is_file() or path.is_symlink():
            return None
        try:
            record = json.loads(path.read_text())
        except ValueError:
            return None
        if (not isinstance(record, dict) or record.get('id') != ident or record.get('task') != self.task
                or not isinstance(record.get('chosen'), str) or not record.get('chosen') or not record.get('ts')):
            return None
        return record

    def state_of(self):
        passes = self.passes()
        cards = self.cards()
        card = cards[-1] if cards else None
        start = 0
        result = dict(state='within', used=len(passes), passes=PASSES, card=None, answer=None,
                      verdicts=[record['verdict'] for record in passes])
        if card:
            reply = self.answer(card)
            result.update(card=card['id'], answer=reply and reply['chosen'])
            if reply is None:
                return dict(result, state='waiting', used=card['passes'] - card['start'])
            start = card['passes']
        result.update(used=len(passes) - start, verdicts=result['verdicts'][start:])
        if result['used'] >= PASSES:
            result['state'] = 'stop'
        return result

    def save(self, cards):
        fd, pending = tempfile.mkstemp(prefix='.preflight-budget-', dir=self.path.parent)
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
        if not IDENT.fullmatch(ident or ''):
            raise Refused('invalid decision id')
        folder = self.path.parent
        folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (folder / '.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            cards = self.cards()
            if any(card['id'] == ident for card in cards):
                raise Refused(f'card {ident} is already recorded')
            current = self.state_of()
            if current['state'] != 'stop':
                raise Refused('the task has not used its preflight passes')
            total = len(self.passes())
            card = dict(id=ident, passes=total, start=total - current['used'], verdicts=current['verdicts'],
                        time=datetime.datetime.now(datetime.timezone.utc).isoformat())
            self.save(cards + [card])
            return card


def details(task, card):
    """Choice-card details from counts and verdicts only: no spec or review text,
    so the same card is safe for an external project."""
    used = card['passes'] - card['start']
    en_facts = [f'Pass {n}: {verdict}.' for n, verdict in enumerate(card['verdicts'], 1)]
    tw_facts = [f'第 {n} 次：{verdict}。' for n, verdict in enumerate(card['verdicts'], 1)]
    return {
        'en': dict(
            title=f'{task}: spec preflight passes ran out; choose the next step',
            explanation=f'The spec of {task} used its {PASSES} preflight passes. '
                        'The next preflight waits for your choice.',
            before=f'{task} used {used} of {PASSES} preflight passes.',
            after='Your answer sets the next step for the spec.',
            outcome=f'Any answer allows {PASSES} more preflight passes.',
            options=dict(
                A=dict(description='Narrow the spec.', pros='A smaller spec can pass preflight sooner.',
                       cons='Firstmate writes a smaller spec before the next pass.'),
                B=dict(description='Park the task.', pros='No more preflight passes use time or money.',
                       cons='The task gets no worker.'),
                C=dict(description='Allow one more pass.', pros='Firstmate keeps the current spec.',
                       cons='The same gaps can come back.')),
            intent=[dict(kind='step', text=f'Choose the next step for the spec of {task}.')],
            why=[dict(kind='fact', text=text) for text in en_facts],
            how=[dict(kind='fact', text='A: firstmate writes a smaller spec and runs the preflight again.'),
                 dict(kind='fact', text='B: firstmate runs no more preflight for the task.'),
                 dict(kind='fact', text='C: firstmate runs the preflight again on the current spec.')],
            glossary=['preflight', 'spec-ok', 'scope'],
            done=[dict(kind='fact', text='Intent 1: the preflight records your answer.')]),
        'zh-TW': dict(
            title=f'{task}：規格預檢次數已用完；請選擇下一步',
            explanation=f'{task} 的規格已用完 {PASSES} 次預檢。下一次預檢等待你的選擇。',
            before=f'{task} 已用 {used}／{PASSES} 次預檢。',
            after='你的回答決定規格的下一步。',
            outcome=f'任何回答都再給 {PASSES} 次預檢。',
            options=dict(
                A=dict(description='縮小規格。', pros='較小的規格較快通過預檢。',
                       cons='firstmate 在下一次預檢前撰寫較小的規格。'),
                B=dict(description='暫停任務。', pros='不再花費預檢次數。', cons='任務不派工。'),
                C=dict(description='再預檢一次。', pros='firstmate 保留目前的規格。',
                       cons='缺口不一定消失。')),
            intent=[dict(kind='step', text=f'請選擇 {task} 規格的下一步。')],
            why=[dict(kind='fact', text=text) for text in tw_facts],
            how=[dict(kind='fact', text='A：firstmate 撰寫較小的規格，再跑預檢。'),
                 dict(kind='fact', text='B：firstmate 不再為此任務跑預檢。'),
                 dict(kind='fact', text='C：firstmate 用目前的規格再跑預檢。')],
            glossary=['preflight', 'spec-ok', 'scope'],
            done=[dict(kind='fact', text='意圖 1：預檢記錄你的回答。')]),
    }


def message(task, result):
    if result['state'] == 'waiting':
        return (f'{task}: spec preflight pass budget reached ({result["used"]} of {PASSES} passes); '
                f'captain card {result["card"]} waits for an answer')
    return f'{task}: spec preflight pass budget reached ({result["used"]} of {PASSES} passes)'


def raise_card(budget, code, run=subprocess.run):
    """Allocate, record and request the budget card; return its id."""
    decide = str(Path(code) / 'bin/fm-decide.sh')

    def call(*args):
        done = run([decide, *args], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
        if done.returncode:
            raise ValueError(f'fm-decide.sh {args[0]} exited {done.returncode}')
        return done.stdout.strip()
    ident = call('--allocate', '--task', budget.task).splitlines()[-1:]
    ident = ident[0] if ident else ''
    if not re.fullmatch(r'D-' + IDENT.pattern, ident):
        raise ValueError('invalid allocated card id')
    card = budget.record_card(ident)
    path = budget.state / 'decision-details-built' / (ident + '.json')
    path.parent.mkdir(exist_ok=True)
    path.write_text(json.dumps(details(budget.task, card), ensure_ascii=False, indent=1) + '\n')
    try:
        call('--request', ident, '--task', budget.task, '--purpose', 'decision', '--details', str(path))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise Unrequested(f'card {ident} is recorded but its request failed ({error}); request it by hand: '
                          f'bin/fm-decide.sh --request {ident} --task {budget.task} --purpose decision '
                          f'--details {path}') from error
    return ident


def gate(budget, code, run=subprocess.run):
    """0 when a pass may run; else 65 after naming (and raising) the card."""
    result = budget.state_of()
    if result['state'] == 'within':
        return 0
    if result['state'] == 'stop':
        try:
            result['card'] = raise_card(budget, code, run)
            result['state'] = 'waiting'
        except Unrequested as error:
            print(f'fm-preflight-budget: {message(budget.task, result)}; {error}', file=sys.stderr)
            return 65
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            print(f'fm-preflight-budget: {message(budget.task, result)}; the budget card failed ({error}); '
                  'raise it by hand and run fm_preflight_budget.py record-card', file=sys.stderr)
            return 65
    print('fm-preflight-budget: ' + message(budget.task, result) + '; no reviewer ran', file=sys.stderr)
    return 65


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['gate', 'state', 'record-card'])
    parser.add_argument('--state', required=True)
    parser.add_argument('--project', required=True)
    parser.add_argument('--task', required=True)
    parser.add_argument('--code', default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument('--id')
    parser.add_argument('--external', action='store_true', default=None)
    args = parser.parse_args()
    budget = Budget(args.state, args.project, args.task, external=args.external)
    if args.command == 'gate':
        return gate(budget, args.code)
    if args.command == 'state':
        print(json.dumps(budget.state_of(), ensure_ascii=False))
    else:
        print(json.dumps(budget.record_card(args.id), ensure_ascii=False))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, TypeError) as error:
        print('fm-preflight-budget: ' + str(error), file=sys.stderr)
        sys.exit(65)
