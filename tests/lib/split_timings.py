#!/usr/bin/env python3
"""Reproduce split estimates and longest-first packing without executing ci.sh.

--write-shares updates the migration weights when the split itself changes.
Otherwise it reads the exact weights CI uses. Actual new-path recordings always
win. This is a static planning report, not elapsed-time evidence.
"""
import argparse
import json
from pathlib import Path
import statistics

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write-shares', action='store_true')
    args = parser.parse_args()
    manifest = json.loads((ROOT / 'tests/lib/split-manifest.json').read_text())
    shares = ROOT / 'tests/lib/suite-splits.tsv'
    if args.write_shares:
        rows = []
        for old, entry in manifest['suites'].items():
            suites = [f for f in entry['files'] if f.endswith('.test.sh')]
            weights = {}
            for path in suites:
                text = (ROOT / path).read_text()
                weight = len(text.splitlines())
                # The Herdr wrapper executes a Python feature file. Count that
                # test body too, rather than allocating equal wrapper lengths.
                for code in entry['files']:
                    if code.endswith('.py') and code in text:
                        weight += len((ROOT / code).read_text().splitlines())
                weights[path] = weight
            total = sum(weights.values())
            rows.extend(f'{path} {old} {weight / total:.12f}\n'
                        for path, weight in weights.items())
        shares.write_text(''.join(rows))
    measured = dict(line.split() for line in
                    (ROOT / 'design/t130-main-timings.txt').read_text().splitlines())
    rec = {k: float(v) for k, v in measured.items()}
    for line in shares.read_text().splitlines():
        path, old, fraction = line.split()
        if path not in rec and old in rec:
            rec[path] = rec[old] * float(fraction)
    suites = sorted(str(p.relative_to(ROOT)) for p in (ROOT / 'tests').glob('*.test.sh'))
    sizes = {p: (ROOT / p).stat().st_size for p in suites}
    median = statistics.median(rec[p] / sizes[p] for p in suites if p in rec and sizes[p])
    # ci_suite_estimates emits three decimals before the LPT sort.
    estimates = {p: round(rec.get(p, sizes[p] * median), 3) for p in suites}
    bins = [[] for _ in range(6)]
    loads = [0.0] * 6
    for p in sorted(suites, key=lambda p: (-estimates[p], suites.index(p))):
        i = min(range(6), key=lambda j: (loads[j], j))
        bins[i].append(p)
        loads[i] += estimates[p]
    mean, longest = sum(loads) / 6, max(estimates.values())
    print('Timing evidence supplied by firstmate: main `0dd2ddaa3a8f63941be54779618af06c215ef5d3`, run '
          '[36803506144](https://github.com/BenjaminLu/firstmate-workflow/actions/runs/36803506144). '
          'The dispatch supplied the artifact values and abbreviated SHA, resolved against local Git history; the worker did not fetch GitHub.\n')
    print('Method: allocate each old suite’s measured seconds in proportion to the new feature files’ '
          'source lines, including the Python file executed by a Herdr wrapper. Shared helper setup is '
          'amortized in those shares; repeated setup overhead is unmeasured. Shares conserve the full '
          'parent duration. Direct new-path recordings supersede these migration estimates. New suites '
          'with no parent use CI’s median seconds-per-byte fallback.\n')
    print('| Shard | Predicted summed seconds | Actual PR job elapsed seconds |')
    print('|---|---:|---|')
    for i, load in enumerate(loads):
        print(f'| {i + 1}/6 | {load:.1f} | Pending firstmate’s current-head CI evidence |')
    print(f'\nTotal predicted: {sum(loads):.1f} s; mean: {mean:.1f} s; '
          f'longest suite: {longest:.1f} s. Every shard is within mean + longest '
          f'({mean + longest:.1f} s).')
    print('\nHistorical static plan only. The captain-approved revision of 2026-10-01 '
          'requires measurable optimization, with no hard predicted or actual shard duration limit. '
          'Splitting conserves parent estimates; this plan alone does not demonstrate runtime savings. '
          'See design/t130-timings.md for separately supplied CI observations and their limitations.\n')
    print('| New suite | Predicted seconds | Shard |')
    print('|---|---:|---:|')
    for p in suites:
        i = next(i for i, group in enumerate(bins) if p in group)
        print(f'| {p} | {estimates[p]:.1f} | {i + 1} |')


if __name__ == '__main__':
    main()
