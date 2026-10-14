#!/usr/bin/env python3
"""Check main's recorded suite timings against the shard split CI makes (T-307).

  ci_shard_model.py --root TREE --timings FILE [--shards 6] [--limit 520]
                    [--gap 120] [--replay FILE [--suites-of-replay]]

The split and its predicted job times come from bin/lib/fm_ci_shards.py,
the code bin/ci.sh runs; nothing here keeps a copy of it. Each shard's
`bin/ci.sh --plan i/n` must name the same suites and print the same
predicted job time, so the load the model checks is the load CI uses.

--timings is the input CI reads (FM_CI_TIMINGS_IN: "path seconds" lines
from the last green runs on main). With --replay, the split made from
--timings is also replayed on the seconds --replay recorded, in each
shard's pool order, the way a run of that split would have gone.
--suites-of-replay plans only the suites --replay recorded, so a past run
is split over its own suites and not over suites added since.

Prints one line per shard and exits 1 when a suite is in no shard or in
two, ci.sh disagrees with the model, a shard is predicted over --limit
seconds of job time, or the slowest shard is more than --gap over the
fastest. These are predictions from recorded seconds, not a measured run.
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'bin/lib'))
import fm_ci_shards  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', required=True)
    ap.add_argument('--timings', required=True)
    ap.add_argument('--shards', type=int, default=6)
    ap.add_argument('--limit', type=float, default=520)
    ap.add_argument('--gap', type=float, default=120)
    ap.add_argument('--replay')
    ap.add_argument('--suites-of-replay', action='store_true')
    a = ap.parse_args()
    if a.suites_of_replay and not a.replay:
        ap.error('--suites-of-replay needs --replay')
    root = Path(a.root).resolve()
    suites = sorted(str(p.relative_to(root)) for p in (root / 'tests').glob('*.test.sh'))
    real = fm_ci_shards.read_timings(a.replay) if a.replay else {}
    if a.suites_of_replay:
        suites = [s for s in suites if s in real]
    timings = fm_ci_shards.read_timings(a.timings)
    shards, est, unit = fm_ci_shards.plan(root, suites, timings, a.shards)
    failed = False
    placed = [suites[i] for shard in shards for i in shard['suites']]
    for s in suites:
        if placed.count(s) != 1:
            print(f'ci: shard split: {s} is in {placed.count(s)} shards')
            failed = True
    if unit != 's':
        print('ci: shard split: no suite in --timings was recorded')
        return 1
    for n, shard in enumerate(shards, 1):
        env = dict(os.environ, FM_ROOT=str(root), FM_CI_TIMINGS_IN=a.timings)
        got = subprocess.run(['bash', str(root / 'bin/ci.sh'), '--plan', f'{n}/{a.shards}', '--', *suites],
                             env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True)
        ci_suites = [int(line[2:]) for line in got.stdout.splitlines() if line.startswith('i ')]
        want = f'predicted job time {shard["job"]:.1f}s'
        if got.returncode or sorted(ci_suites) != sorted(shard['suites']) or want not in got.stderr:
            print(f'ci: shard split: bin/ci.sh --plan {n}/{a.shards} differs from the model'
                  f' (exit {got.returncode}; {got.stderr.strip()[:300]})')
            failed = True
        line = f'shard {n}/{a.shards}: {len(shard["suites"])} suites, {shard["load"]:.0f}s summed, ' \
               f'predicted job time {shard["job"]:.0f}s'
        if real:
            seconds = [real.get(suites[i], est[i][0]) for i in shard['suites']]
            line += f'; replayed on --replay {fm_ci_shards.job_time(seconds):.0f}s'
        over = shard['job'] > a.limit
        failed |= over
        print(line + (' OVER' if over else ''))
    jobs = [shard['job'] for shard in shards]
    spread = max(jobs) - min(jobs)
    print(f'slowest shard {max(jobs):.0f}s, fastest {min(jobs):.0f}s, gap {spread:.0f}s')
    if spread > a.gap:
        print(f'ci: shard split: the gap is over {a.gap:.0f}s')
        failed = True
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
