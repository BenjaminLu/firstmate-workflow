#!/usr/bin/env python3
"""Join coverage with observed vendor turns and duration; unknown is not zero."""
import json
from pathlib import Path
import sys
import time


def metrics(run, ended):
    run = Path(run)
    identity = json.loads((run / 'identity.json').read_text())
    coverage = json.loads((run / 'coverage.json').read_text())
    turns = 0
    observed = False
    for invocation in run.glob('*/invocation.json'):
        log = invocation.parent / 'cli.log'
        if not log.is_file():
            continue
        with log.open(errors='replace') as source:
            for line in source:
                try:
                    item = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(item, dict):
                    continue
                if item.get('type') == 'turn.completed':
                    turns += 1
                    observed = True
                elif item.get('type') == 'result' and isinstance(item.get('num_turns'), int):
                    turns += item['num_turns']
                    observed = True
    return dict(evidence_event='brief_round_finished', coverage=coverage, turns=turns if observed else None,
                turns_source='vendor terminal events' if observed else 'unavailable',
                duration=max(0, ended - identity['created']))


if __name__ == '__main__':
    print(json.dumps(metrics(sys.argv[1], time.time())))
