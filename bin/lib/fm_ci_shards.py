#!/usr/bin/env python3
"""The bash shards' split, pool order and predicted job time (T-307).

  fm_ci_shards.py split <want> <n> [<only>] -- <suite>...

bin/ci.sh calls this for --shard, --plan and its pool, and
tests/lib/ci_shard_model.py calls the same functions, so the split CI makes
and the split the model checks are one computation from one input.

Each suite's estimate, in seconds: the median of its recordings in
FM_CI_TIMINGS_IN ("path seconds" per line, the last green runs on main).
A suite with no recording takes its share of a split parent
(tests/lib/suite-splits.tsv), and the parent loses that share; any other
takes its byte size times the median seconds per byte, and may not weigh
less than UNKNOWN_FLOOR_PERCENTILE of the recorded suites (a file that is
not a *.test.sh suite, which --plan may be given, may). The pool starts
both kinds first, so a new suite is neither under-weighted nor started
late (T-307: a 244 s suite estimated at 23 s ran last and took shard 6 to
657 s). With neither a recording nor a share, every estimate is the suite's
byte size.

The split is longest-processing-time packing of those estimates: slowest
first, each to the shard with the lightest summed load, ties to the lower
index. A shard's predicted job time replays its suites, in the order its
pool starts them, through RUNNER_JOBS at once, plus JOB_OVERHEAD.

Prints "i <index>" for each suite of shard <want>, in pool order, then
"s <summary>", "p <load> <longest> <unit>" for shard <want> and
"b <load> <longest> <unit>" for each shard. Loads are summed seconds; the
predicted job time is on the summary only. With <only>, only the first
<only> suites are split; the rest only set the rates the estimates use.
"""
import heapq
import math
import os
from pathlib import Path
import re
import statistics
import sys

# The bash shards' pool width on a GitHub runner (4 vCPUs).
RUNNER_JOBS = 4
# Setup and teardown around the pool: run 38454069859's job time minus its
# replayed pool time, shards 1-5 (51, 49, 40, 55, 68 s; mean 52.6 s).
JOB_OVERHEAD = 53.0
# An unrecorded suite weighs at least this percentile of the recorded ones.
UNKNOWN_FLOOR_PERCENTILE = 90
# The families the gate has always spent longest on start first when no
# suite was recorded at all.
SLOW_FAMILIES = ('tests/herdr', 'tests/worker')


def read_timings(path):
    """Each suite's median over its recordings; a bad value is no recording."""
    seen = {}
    if path and os.access(path, os.R_OK):
        for line in Path(path).read_text(errors='replace').splitlines():
            cells = line.split()
            if len(cells) >= 2 and re.fullmatch(r'[0-9]+(\.[0-9]+)?', cells[1]):
                seen.setdefault(cells[0], []).append(float(cells[1]))
    return {suite: statistics.median(values) for suite, values in seen.items()}


def read_splits(root):
    rows = []
    path = Path(root) / 'tests/lib/suite-splits.tsv'
    if path.exists():
        for line in path.read_text().splitlines():
            cells = line.split()
            if len(cells) != 3:
                continue
            if not re.fullmatch(r'0(\.[0-9]+)?|1(\.0+)?', cells[2]):
                continue
            share = float(cells[2])
            if share > 0:
                rows.append((cells[0], cells[1], share))
    return rows


def percentile(values, pct):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(pct / 100 * len(ordered)) - 1)] if ordered else 0.0


def estimates(root, suites, timings):
    """(estimate, recorded) per suite, and the unit: "s", or "B" for bytes."""
    root = Path(root)
    sizes = []
    for suite in suites:
        try:
            sizes.append((root / suite).stat().st_size)
        except OSError:
            sizes.append(0)
    rec = {suite: timings[suite] for suite in suites if suite in timings}
    # A split child no run recorded takes its share of the parent, and the
    # parent keeps only the rest: CI's split and its pool weigh both. This
    # comes first, as in the old ci.sh: a child with a share counts as
    # recorded, so a plan of only split children is still in seconds.
    derived, base, given = {}, dict(timings), {}
    for child, parent, share in read_splits(root):
        if child in timings or child in derived or parent not in base:
            continue
        derived[child] = base[parent] * share
        base.setdefault(child, derived[child])
        given[parent] = given.get(parent, 0.0) + derived[child]
    known = {s: rec[s] if s in rec else derived[s] for s in suites if s in rec or s in derived}
    if suites and not known:
        return [(float(size), False) for size in sizes], 'B'
    rates = sorted(known[s] / size for s, size in zip(suites, sizes) if s in known and size)
    rate = statistics.median(rates) if rates else 0.0
    # the floor is only for a suite with neither a recording nor a share
    floor = percentile(rec.values(), UNKNOWN_FLOOR_PERCENTILE)
    out = []
    for suite, size in zip(suites, sizes):
        if suite in rec:
            out.append((round(max(0.0, rec[suite] - given.get(suite, 0.0)), 3), True))
        else:
            if suite in derived:
                est = max(0.0, derived[suite] - given.get(suite, 0.0))
            else:
                est = size * rate
                # the floor is for a suite; --plan may also be given other files
                if suite.endswith('.test.sh'):
                    est = max(est, floor)
            out.append((round(est, 3), False))
    return out, 's'


def pool_order(suites, indices, est, unit):
    """The order a shard's pool starts its suites in."""
    if unit == 's':
        return sorted(indices, key=lambda i: (est[i][1], -est[i][0], i))
    def family(suite):
        return suite.startswith(SLOW_FAMILIES) or suite == 'tests/reconcile.test.sh'
    return sorted(indices, key=lambda i: (0, 0, i) if family(suites[i]) else (1, -est[i][0], i))


def job_time(seconds, jobs=RUNNER_JOBS):
    """Predicted job time of a pool starting <seconds> in order, <jobs> at once."""
    pool = [0.0] * jobs
    for value in seconds:
        heapq.heappush(pool, heapq.heappop(pool) + value)
    return JOB_OVERHEAD + max(pool)


def plan(root, suites, timings, n, only=None):
    """Split suites[:only] into n shards. Returns (shards, est, unit): each
    shard a dict of its suite indices in pool order, summed load, longest
    suite, and predicted job time (seconds; None in bytes)."""
    est, unit = estimates(root, suites, timings)
    count = len(suites) if only is None else only
    loads, longest, members = [0.0] * n, [0.0] * n, [[] for _ in range(n)]
    for i in sorted(range(count), key=lambda i: (-est[i][0], i)):
        b = min(range(n), key=lambda k: (loads[k], k))
        loads[b] += est[i][0]
        longest[b] = max(longest[b], est[i][0])
        members[b].append(i)
    shards = []
    for b in range(n):
        order = pool_order(suites, members[b], est, unit)
        shards.append({'suites': order, 'load': loads[b], 'longest': longest[b],
                       'job': job_time([est[i][0] for i in order]) if unit == 's' else None})
    return shards, est, unit


def split_lines(root, suites, timings, want, n, only=None):
    shards, est, unit = plan(root, suites, timings, n, only)
    count = len(suites) if only is None else only
    top = max(range(count), key=lambda i: (est[i][0], -i), default=None)
    shown = 's' if unit == 's' else ' bytes'
    mine = shards[want - 1]
    lines = [f'i {i}' for i in mine['suites']]
    summary = (f's shard {want}/{n}: {len(mine["suites"])} suites, predicted {mine["load"]:.1f}{shown}; '
               f'mean {sum(s["load"] for s in shards) / n:.1f}{shown}; longest suite '
               f'{suites[top] if top is not None else "(none)"} {est[top][0] if top is not None else 0:.1f}{shown}')
    if mine['job'] is not None:
        summary += f'; predicted job time {mine["job"]:.1f}s ({RUNNER_JOBS} at a time, {JOB_OVERHEAD:.0f}s setup)'
    lines.append(summary)
    lines.append(f'p {mine["load"]:.3f} {mine["longest"]:.3f} {unit}')
    lines.extend(f'b {s["load"]:.3f} {s["longest"]:.3f} {unit}' for s in shards)
    return lines


def main(argv):
    if len(argv) < 4 or argv[0] != 'split' or '--' not in argv:
        print('usage: fm_ci_shards.py split <want> <n> [<only>] -- <suite>...', file=sys.stderr)
        return 64
    cut = argv.index('--')
    head, suites = argv[1:cut], argv[cut + 1:]
    want, n = int(head[0]), int(head[1])
    only = int(head[2]) if len(head) > 2 and head[2] != '' else None
    timings = read_timings(os.environ.get('FM_CI_TIMINGS_IN', ''))
    print('\n'.join(split_lines(os.getcwd(), suites, timings, want, n, only)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
