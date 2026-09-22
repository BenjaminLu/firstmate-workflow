#!/usr/bin/env python3
"""Managed-transport mid-run board status (T-036).

Full Herdr pane lifecycle (allocate, snapshot, close) is owned elsewhere.
This module is the shared path every vendor uses to refresh authored
activity — and optional bounded progress — through fm-emit.sh. Pane
heartbeat text alone is never board state until emitted here.

  python3 bin/fm-herdr.py emit-status --root . --actor worker-1 --task T-1 \\
      --role worker --en 'still running' --tw '仍在跑'
  python3 bin/fm-herdr.py emit-status ... --done 2 --total 7
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def emit_status(root, actor, task, en, tw, role='worker', crew_name=None,
                done=None, total=None, env=None):
    """Write a crew_status event. Bare percents are never invented here."""
    root = Path(root).resolve()
    emit = root / 'bin' / 'fm-emit.sh'
    if not emit.is_file():
        raise FileNotFoundError('fm-emit.sh missing under ' + str(root))
    name = crew_name or actor
    data = {
        'role': role,
        'crew_name': name,
        'activity': {'en': en, 'zh-TW': tw},
    }
    if done is not None and total is not None:
        done_n, total_n = int(done), int(total)
        if total_n <= 0 or done_n < 0 or done_n > total_n:
            raise ValueError('progress requires 0 <= done <= total and total > 0')
        data['progress'] = {'done': done_n, 'total': total_n}
    cmd = [
        'bash', str(emit),
        '--actor', actor, '--task', task, '--type', 'crew_status',
        '--data', json.dumps(data, ensure_ascii=False),
        '--en', en, '--tw', tw,
    ]
    merged = dict(os.environ if env is None else env)
    merged['FM_ROOT'] = str(root)
    result = subprocess.run(cmd, capture_output=True, text=True, env=merged)
    if result.returncode != 0:
        raise RuntimeError(
            'crew_status emit failed: '
            + (result.stderr or result.stdout or str(result.returncode)))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog='fm-herdr.py')
    sub = parser.add_subparsers(dest='cmd', required=True)
    status = sub.add_parser('emit-status', help='refresh activity via fm-emit.sh')
    status.add_argument('--root', required=True)
    status.add_argument('--actor', required=True)
    status.add_argument('--task', required=True)
    status.add_argument('--en', required=True)
    status.add_argument('--tw', required=True)
    status.add_argument('--role', default='worker')
    status.add_argument('--crew-name', default='')
    status.add_argument('--done', type=int, default=None)
    status.add_argument('--total', type=int, default=None)
    args = parser.parse_args(argv)
    if args.cmd == 'emit-status':
        if (args.done is None) ^ (args.total is None):
            parser.error('--done and --total must be given together')
        return emit_status(
            args.root, args.actor, args.task, args.en, args.tw,
            role=args.role, crew_name=args.crew_name or None,
            done=args.done, total=args.total)
    parser.error('unknown command')
    return 64


if __name__ == '__main__':
    try:
        sys.exit(main() or 0)
    except (OSError, ValueError, RuntimeError) as err:
        print('fm-herdr:', err, file=sys.stderr)
        sys.exit(1)
