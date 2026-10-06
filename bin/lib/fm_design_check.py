"""Bind firstmate's private reference to the external base without editing on check."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode = True

from fm_onboard import atomic, save
from fm_lifeline import forward


def now():
    return datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')


def git(home, *args):
    return subprocess.run(['git', '-C', str(home/'repo'), *args],
                          stdin=subprocess.DEVNULL, capture_output=True,
                          text=True, timeout=30, check=True).stdout.rstrip('\n')


def front_matter(text):
    lines = text.splitlines(keepends=True)
    if lines and lines[0].rstrip('\r\n') == '---':
        for end in range(1, len(lines)):
            if lines[end].rstrip('\r\n') == '---':
                values = {}
                for line in lines[1:end]:
                    key, sep, value = line.partition(':')
                    if sep and key.strip() in ('based_on', 'checked_at'):
                        values[key.strip()] = value.strip()
                return lines, end, values
    return lines, None, {}


def record(status, based, origin, commits=None, files=None):
    files = files or []
    return dict(status=status, based_on=based, origin=origin,
                commits=commits or [], files=files[:50], files_total=len(files), at=now())


def check(args):
    home = Path(args.home)
    path = home/'design.md'
    if path.is_symlink():
        print(f'fm-project: refusing symlink design.md of {args.name}', file=sys.stderr)
        return
    if not path.exists():
        return
    text = path.read_bytes().decode('utf-8')
    _, _, values = front_matter(text)
    based = values.get('based_on', '')
    if not values.get('checked_at') or not re.fullmatch(r'[0-9a-fA-F]{40}', based):
        based = None
    else:
        based = based.lower()
    origin = git(home, 'rev-parse', '--verify', f'refs/remotes/origin/{args.base}^{{commit}}')
    status = 'unrecorded' if based is None else ('fresh' if based == origin else 'stale')
    data = record(status, based, origin)
    stamp = home/'state/onboarding/design-check.json'
    try:
        previous = json.loads(stamp.read_text())
        notified = previous.get('notified') if isinstance(previous, dict) else None
    except (OSError, ValueError):
        notified = None
    if notified is not None:
        data['notified'] = notified
    line = ''
    action = f'review it and run fm-project.sh design-checked {args.name}'
    if status == 'unrecorded':
        line = (f'design.md of {args.name} is not bound to a {args.base} commit; '
                f'review it against {origin[:12]} and run fm-project.sh design-checked {args.name}')
    elif status == 'stale':
        try:
            git(home, 'cat-file', '-e', f'{based}^{{commit}}')
        except subprocess.CalledProcessError:
            line = (f'design.md of {args.name} may be stale: based_on {based[:12]} '
                    f"is not in the clone's history (rewritten?); {action}")
        else:
            commits = git(home, 'log', '--format=%h %s', '-n', '20', f'{based}..{origin}').splitlines()
            files = git(home, 'diff', '--name-only', based, origin).splitlines()
            data.update(commits=commits, files=files[:50], files_total=len(files))
            line = (f'design.md of {args.name} may be stale: {args.base} moved '
                    f'{based[:12]}..{origin[:12]} ({len(commits)} commits, {len(files)} files); {action}')
    save(stamp, data)
    if line:
        print('fm-project: ' + line, file=sys.stderr)
    pair = [based, origin]
    if status == 'stale' and notified != pair:
        forward(args.engine, args.name, 'design-stale', 'design_stale', line)
        data['notified'] = pair
        save(stamp, data)


def mark(args):
    home = Path(args.home)
    path = home/'design.md'
    if path.is_symlink() or not path.is_file():
        raise ValueError(f'missing or symlinked design.md of {args.name}')
    origin = git(home, 'rev-parse', '--verify', f'refs/remotes/origin/{args.base}^{{commit}}')
    # read_bytes avoids universal-newline conversion of the existing body.
    text = path.read_bytes().decode('utf-8')
    lines, end, _ = front_matter(text)
    values = dict(based_on=origin, checked_at=now())
    if end is None:
        text = f"---\nbased_on: {origin}\nchecked_at: {values['checked_at']}\n---\n" + text
    else:
        seen = set()
        for i in range(1, end):
            key, sep, _ = lines[i].partition(':')
            key = key.strip()
            if sep and key in values:
                ending = '\r\n' if lines[i].endswith('\r\n') else '\n'
                lines[i] = f'{key}: {values[key]}' + ending
                seen.add(key)
        lines[end:end] = [f'{key}: {value}\n' for key, value in values.items() if key not in seen]
        text = ''.join(lines)
    atomic(path, text)
    save(home/'state/onboarding/design-check.json', record('fresh', origin, origin))
    print(f'fm-project: design.md of {args.name} checked against {args.base} {origin[:12]}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=('check', 'mark'))
    for name in ('engine', 'name', 'home', 'base'):
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    try:
        (check if args.command == 'check' else mark)(args)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        if args.command == 'mark':
            print(f'fm-project: cannot mark design.md of {args.name}: {error}', file=sys.stderr)
            return 65
        # Optional drift detection must not make a dispatch fail.
    return 0


if __name__ == '__main__':
    sys.exit(main())
