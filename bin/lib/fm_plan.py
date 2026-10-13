#!/usr/bin/env python3
"""A worker's first round returns one plan; firstmate accepts it before a build (T-302).

The first run on a spec's bytes (a new task, or the first round after a
repin) writes a plan-required marker into its run directory. Only a run with
that marker turns the rules below on, so a task already in flight under an
older launcher goes on as before.

  fm_plan.py state --run RUN --state STATE --project P --task T --round N --head H
      prints {"mode": off|plan|unaccepted|accepted, ...} as JSON
  fm_plan.py check-plan --spec SPEC --file NOTE
      exit 65 naming every done line the plan has no row for
  fm_plan.py check-class --task T --file NOTE
      exit 65 when a fix report holds no complete SWEPT:<task> block, or one
      whose fixed count is more than its found count

A plan row is a table row whose first cell is a done line's number, by its
position in the spec's acceptance list, and whose next three cells (the test,
where it runs, how it fails on the base) are not empty.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fm_evidence import Store  # noqa: E402

REPORTS = ('worker-report', 'ask')


def delivered(record):
    """A worker's report from a round the launcher did not refuse."""
    return record['kind'] in REPORTS and not record.get('refused')


def sha256(data):
    return hashlib.sha256(data if isinstance(data, bytes) else data.encode()).hexdigest()


def read(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def plan_required(run):
    """True when a worker run on these spec bytes wrote the marker."""
    run = Path(run).resolve()
    identity = read(run / 'identity.json')
    if not isinstance(identity, dict):
        raise ValueError('the current run has no identity')
    spec = (run / 'pinned' / 'spec.json').read_bytes()
    for other in run.parent.glob('*/identity.json'):
        earlier = read(other)
        if (not isinstance(earlier, dict) or earlier.get('role') != 'worker'
                or earlier.get('task') != identity.get('task')
                or earlier.get('project') != identity.get('project')):
            continue
        try:
            if ((other.parent / 'pinned' / 'spec.json').read_bytes() == spec
                    and (other.parent / 'plan-required').is_file()):
                return True
        except OSError:
            continue
    return False


def state(run, store, round_number, head):
    spec_sha = sha256((Path(run) / 'pinned' / 'spec.json').read_bytes())
    if not plan_required(run):
        return dict(mode='off')
    records = store.records()
    plans = [r for r in records if delivered(r) and r.get('plan') == spec_sha]
    if not plans:
        return dict(mode='plan', spec_sha256=spec_sha)
    plan = plans[-1]
    plan_sha = sha256(plan['text'])
    accepts = [n for n, r in enumerate(records) if r['kind'] == 'plan-accept'
               and r.get('plan_sha256') == plan_sha and r.get('authorized') is True]
    found = dict(spec_sha256=spec_sha, plan_round=plan['round'], plan_head=plan['head'])
    if not accepts:
        return dict(found, mode='unaccepted')
    accepted = accepts[-1]
    answers = records[accepted]['text']
    built = any(delivered(r) and not r.get('plan') for r in records[accepted + 1:])
    fix = []
    # (c) the build round right after an accepted plan with answers
    if not built and answers.strip():
        fix.append('answers')
    # (a) the round after a REJECT: no worker report since the latest verdict
    verdicts = [n for n, r in enumerate(records) if r['kind'] == 'verdict' and r.get('lane', 'code') == 'code']
    if verdicts and records[verdicts[-1]].get('verdict') == 'REJECT' and not any(
            delivered(r) for r in records[verdicts[-1] + 1:]):
        fix.append('reject')
    # (b) a firstmate brief bound to this round and head, once the build began
    if built and store.brief(round_number, head):
        fix.append('brief')
    return dict(found, mode='accepted', answers=answers, fix=fix, built=built)


def missing_rows(spec, note):
    acceptance = spec.get('acceptance') or []
    rows = set()
    for line in note.splitlines():
        cells = line.strip()
        if not (cells.startswith('|') and cells.endswith('|')):
            continue
        cells = [c.strip() for c in cells[1:-1].split('|')]
        if re.fullmatch(r'\d+', cells[0]) and len(cells) >= 4 and all(cells[1:4]):
            rows.add(int(cells[0]))
    return [(n, item) for n, item in enumerate(acceptance, 1) if n not in rows]


def class_problems(task, note):
    """What keeps a fix report's SWEPT:<task> blocks from passing; empty when none.

    Each block needs a searched: line and a found-and-fixed line. Detail may
    sit between and after the numbers ('found 2 (the merge card), fixed 2',
    'found 1, fixed 1 (tests/lib.sh)'), but fixed is never more than found
    (T-304).
    """
    marker = re.compile(r'^SWEPT:' + re.escape(task) + r'(\s|$)')
    blocks, current = [], None
    for line in note.splitlines():
        if marker.match(line.strip()):
            current = (line.strip(), [])
            blocks.append(current)
        elif current is not None:
            current[1].append(line)
    if not blocks:
        return [f'the report lists no complete SWEPT:{task} block (searched: and found N, fixed M)']
    problems = []
    for head, block in blocks:
        counts = [(int(m.group(1)), int(m.group(2))) for m in
                  (re.search(r'\bfound\s+(\d+)\b.*?\bfixed\s+(\d+)\b', line) for line in block) if m]
        if not (any(re.match(r'\s*searched:\s*\S', line) for line in block) and counts):
            problems.append(f'the report lists no complete SWEPT:{task} block (searched: and found N, fixed M): {head[:80]}')
        problems += [f'the SWEPT:{task} block says fixed {fixed} but found {found}; fixed is never more than found: {head[:80]}'
                     for found, fixed in counts if fixed > found]
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['state', 'check-plan', 'check-class'])
    parser.add_argument('--run')
    parser.add_argument('--state')
    parser.add_argument('--project')
    parser.add_argument('--task')
    parser.add_argument('--round', type=int, default=1)
    parser.add_argument('--head', default='')
    parser.add_argument('--spec')
    parser.add_argument('--file')
    args = parser.parse_args()
    if args.command == 'state':
        store = Store(args.state, args.project, args.task, external=False)
        print(json.dumps(state(args.run, store, args.round, args.head), ensure_ascii=False))
    elif args.command == 'check-plan':
        missing = missing_rows(json.loads(Path(args.spec).read_text()), Path(args.file).read_text())
        if missing:
            for number, item in missing:
                print(f'the plan has no row for done line {number}: {item[:80]}', file=sys.stderr)
            return 65
    else:
        problems = class_problems(args.task, Path(args.file).read_text())
        if problems:
            for problem in problems:
                print(problem, file=sys.stderr)
            return 65
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('fm-plan: ' + str(error), file=sys.stderr)
        sys.exit(1)
