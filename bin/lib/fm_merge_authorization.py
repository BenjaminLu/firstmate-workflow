"""Session-local merge authorization evidence; never performs a merge."""
import argparse
import datetime
import json
from pathlib import Path
import sys
import time
import uuid

sys.dont_write_bytecode = True
from fm_watch import Locked, read_json, save_json
import fm_lifeline as life


def read(state):
    return read_json(Path(state) / 'session/merge-authorization.json')


def record(state, until, quote, clock=time.time):
    expiry = datetime.datetime.fromisoformat(until.replace('Z', '+00:00'))
    now = clock()
    if expiry.tzinfo is None or expiry.utcoffset() is None:
        raise ValueError('--until requires an ISO-8601 timezone offset')
    if expiry.timestamp() <= now or not quote.strip():
        raise ValueError('authorization requires a future expiry and the captain\'s words')
    directory = Path(state) / 'session'
    directory.mkdir(parents=True, exist_ok=True)
    item = dict(id=uuid.uuid4().hex, until=until, expires_at=expiry.timestamp(),
                recorded_at=now, quote=quote)
    with Locked(directory / 'merge-authorization.lock'):
        save_json(directory / 'merge-authorization.json', item)
    life.ring_events(str(state), 'merge authorization recorded')
    return item


def inventory(pilot):
    cards = []
    carded = set()
    for path in sorted((pilot.state / 'pending').glob('*.json')):
        card = read_json(path)
        if card.get('kind') not in ('merge', 'merge-untracked'): continue
        if (card.get('project') or pilot.ctx.get('default_project') or pilot.ctx['project']) != pilot.ctx['project']: continue
        if (pilot.state / 'decisions' / path.name).exists(): continue
        cards.append(f"{card.get('id', path.stem)} {card.get('task', '')} #{card.get('pr', '?')}")
        carded.add(str(card.get('pr')))
    ready = []
    for number, pr in sorted(pilot.data['pulls'].items()):
        evidence = pr.get('merge_evidence', {})
        if (not pr.get('terminal') and number not in carded and evidence.get('head') == pr.get('head')
                and evidence.get('approved') and evidence.get('green')):
            ready.append(f"{pr['task']} #{number}")
    rounds = []
    # Use lifecycle facts already recorded locally. Liveness probing can spawn
    # ps; the reminder must never introduce subprocess or network work.
    active = {}
    for row in pilot.rows():
        actor = row.get('actor')
        kind = row.get('type')
        if kind in ('dispatched', 'review_opened'):
            active[actor] = dict(task=row.get('task', ''),
                                 role='reviewer' if kind == 'review_opened' else 'worker')
        elif kind in ('agent_finished', 'agent_lost', 'worker_crashed', 'review_failed'):
            active.pop(actor, None)
    for row in active.values():
        task = row.get('task', '')
        numbers = [n for n, p in pilot.data['pulls'].items() if p.get('task') == task and not p.get('terminal')]
        rounds.append(f"{task}" + ''.join(' #' + n for n in sorted(numbers)) + f" ({row.get('role', 'worker')})")
    return cards, ready, sorted(set(rounds))


def refresh(pilot):
    # Local input is reread only at startup or a pushed writer notification.
    pilot.authorization = read(pilot.state)


def deadline(pilot, key):
    item = getattr(pilot, 'authorization', {})
    if not item: return []
    for phase, due in [('warning', item['expires_at'] - 3600), ('expired', item['expires_at'])]:
        if phase == 'warning' and pilot.clock() >= item['expires_at']: continue
        ident = 'autopilot-' + key([pilot.ctx['project'], 'merge-authorization-' + item['id'] + '-' + phase])
        if ident not in pilot.data['wakes']: return [due]
    return []


def tick(pilot, key):
    item = getattr(pilot, 'authorization', {})
    if not item: return
    due = deadline(pilot, key)
    if not due or pilot.clock() < due[0]: return
    now = pilot.clock()
    identity = 'merge-authorization-' + item['id']
    if now >= item['expires_at']:
        pilot.queue(identity + '-expired', '', 'merge authorization ended', '合併授權已到期')
    elif now >= item['expires_at'] - 3600:
        cards, ready, rounds = inventory(pilot)
        en = f"merge authorization ends at {item['until']}"
        tw = f"合併授權將於 {item['until']} 到期"
        for english, chinese, rows in [('pending merge cards', '待處理合併卡', cards),
                ('approved green PRs without cards', '已核准且 CI 通過但尚無卡片的 PR', ready),
                ('in-flight rounds', '進行中的工作或審查輪次', rounds)]:
            en += '\n' + english + ': ' + (', '.join(rows) or 'none')
            tw += '\n' + chinese + '：' + (', '.join(rows) or '無')
        pilot.queue(identity + '-warning', '', en, tw)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--state', required=True)
    parser.add_argument('--until')
    parser.add_argument('--quote')
    parser.add_argument('--show', action='store_true')
    args = parser.parse_args()
    if args.show:
        if args.until is not None or args.quote is not None: parser.error('--show takes no window')
        item = read(args.state)
    else:
        if args.until is None or args.quote is None: parser.error('--until and --quote are required')
        try: item = record(args.state, args.until, args.quote)
        except ValueError as error: parser.error(str(error))
    print(json.dumps(item, ensure_ascii=False) if item else 'none')


if __name__ == '__main__': main()
