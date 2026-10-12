#!/usr/bin/env python3
"""Is this worker round the first one on its spec's bytes? (T-297)

The worker's first round on a new task, and its first round after a repin,
reads the spec and the code and then asks or plans before it changes a file.
A round is such a round when no earlier worker run of the same project and
task had the same bytes in its round's pinned/spec.json. Nothing here writes;
a run directory that does not read is no earlier run.

  fm_first_round.py <current run directory>   prints first or again
"""
import json
from pathlib import Path
import sys


def read(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def first(run):
    run = Path(run).resolve()
    identity = read(run / 'identity.json')
    if not isinstance(identity, dict):
        raise ValueError('the current run has no identity')
    spec = (run / 'pinned' / 'spec.json').read_bytes()
    for other in run.parent.glob('*/identity.json'):
        if other.parent.resolve() == run:
            continue
        earlier = read(other)
        if (not isinstance(earlier, dict) or earlier.get('role') != 'worker'
                or earlier.get('task') != identity.get('task')
                or earlier.get('project') != identity.get('project')):
            continue
        try:
            if (other.parent / 'pinned' / 'spec.json').read_bytes() == spec:
                return False
        except OSError:
            continue
    return True


if __name__ == '__main__':
    try:
        if len(sys.argv) != 2:
            raise ValueError('usage: fm_first_round.py <run directory>')
        print('first' if first(sys.argv[1]) else 'again')
    except (OSError, ValueError) as error:
        print('fm-first-round: ' + str(error), file=sys.stderr)
        sys.exit(65)
