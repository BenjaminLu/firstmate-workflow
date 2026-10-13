#!/usr/bin/env python3
"""Replay main's recorded suite timings through bin/ci.sh's shard split (T-306).

  ci_shard_model.py --root TREE --timings TSV [--shards 6] [--jobs 4]
                    [--overhead 60] [--average 480] [--peak 560]

The split is bin/ci.sh's own: every recorded run is handed to it as
FM_CI_TIMINGS_IN, and `--plan i/n` names the suites of each shard, slowest
first, which is also the order the shard's pool starts them in. Each
recorded run is then replayed on that split: the shard's suites go through
a pool of --jobs (the 4 vCPUs of a GitHub runner), each taking the seconds
that run recorded for it, and the shard's time is the pool's last finish
plus --overhead, the job's setup before and after bin/ci.sh (about 50 s on
the recorded runs). A suite the runs never named takes its split share of
the suite it came from (tests/lib/suite-splits.tsv), and that suite keeps
the rest; any other unrecorded suite takes its size times the run's median
seconds per byte, the estimate bin/ci.sh makes for it.

Prints one line per shard and exits 1 when a suite is in no shard or in
two, when a shard averages over --average, or when any run of it goes over
--peak. This is a replay of recorded seconds, not a measurement of a run.
"""
import argparse
import heapq
import os
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile


def recorded(path):
    runs, table = [], {}
    for line in Path(path).read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        cells = line.split('\t')
        if cells[0] == 'suite':
            runs = cells[1:]
            continue
        table[cells[0]] = [None if c == '-' else float(c) for c in cells[1:]]
    return runs, table


def splits(root):
    rows = []
    path = root / 'tests/lib/suite-splits.tsv'
    if path.exists():
        for line in path.read_text().splitlines():
            cells = line.split()
            if len(cells) == 3:
                rows.append((cells[0], cells[1], float(cells[2])))
    return rows


def run_seconds(root, suites, table, shares, k):
    got = {s: table[s][k] for s in suites if s in table and table[s][k] is not None}
    rates = sorted(v / os.path.getsize(root / s) for s, v in got.items() if os.path.getsize(root / s))
    rate = statistics.median(rates) if rates else 0
    out = dict(got)
    for child, parent, share in shares:
        if child in suites and child not in got and parent in got:
            out[child] = got[parent] * share
            if parent in out:
                out[parent] -= got[parent] * share
    for s in suites:
        out.setdefault(s, os.path.getsize(root / s) * rate)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', required=True)
    ap.add_argument('--timings', required=True)
    ap.add_argument('--ci')
    ap.add_argument('--shards', type=int, default=6)
    ap.add_argument('--jobs', type=int, default=4)
    ap.add_argument('--overhead', type=float, default=60)
    ap.add_argument('--average', type=float, default=480)
    ap.add_argument('--peak', type=float, default=560)
    a = ap.parse_args()
    root = Path(a.root).resolve()
    ci = a.ci or str(root / 'bin/ci.sh')
    suites = sorted(str(p.relative_to(root)) for p in (root / 'tests').glob('*.test.sh'))
    runs, table = recorded(a.timings)
    shares = splits(root)
    with tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False) as tin:
        for k in range(len(runs)):
            for s, values in table.items():
                if values[k] is not None:
                    tin.write(f'{s} {values[k]}\n')
    try:
        shard_of = []
        for i in range(1, a.shards + 1):
            env = dict(os.environ, FM_ROOT=str(root), FM_CI_TIMINGS_IN=tin.name)
            out = subprocess.run(['bash', ci, '--plan', f'{i}/{a.shards}', '--', *suites], env=env,
                                 stdin=subprocess.DEVNULL, capture_output=True, text=True, check=True).stdout
            shard_of.append([suites[int(line[2:])] for line in out.splitlines() if line.startswith('i ')])
    finally:
        os.unlink(tin.name)
    failed = False
    placed = [s for shard in shard_of for s in shard]
    for s in suites:
        if placed.count(s) != 1:
            print(f'ci: balanced shards: {s} is in {placed.count(s)} shards')
            failed = True
    seconds = [run_seconds(root, suites, table, shares, k) for k in range(len(runs))]
    for i, shard in enumerate(shard_of, 1):
        walls = []
        for times in seconds:
            pool = [0.0] * a.jobs
            for s in shard:
                heapq.heappush(pool, heapq.heappop(pool) + times[s])
            walls.append(a.overhead + max(pool))
        mean, peak = statistics.mean(walls), max(walls)
        bad = mean > a.average or peak > a.peak
        failed |= bad
        print(f'shard {i}/{a.shards}: {len(shard)} suites, average {mean:.0f}s, peak {peak:.0f}s'
              f' over {len(walls)} runs{" OVER" if bad else ""}')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
