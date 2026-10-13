#!/usr/bin/env python3
"""T-303: a task's door picks its path.

A two-way change can be undone by a revert; a one-way change cannot. A self
task spec names its door as `door: {"kind": "two-way"|"one-way", "reason":
"<one line>"}`. Anything else, a missing door included, is one-way. The
effective door is computed once, when a pin or repin is written, and kept in
the pin as `door: {kind, reason, forced_by}`; a pin without it (one written
before T-303) is one-way. External projects keep the one-way path.

The engine config.yaml's `door.sensitive` globs name the paths that are
always one-way. A two-way spec with a scope entry that itself falls inside
one of them is pinned one-way; a two-way pin whose diff touches one is
handled as one-way at the gates, path by path.

A two-way task skips the plan round and the fail-first gate and gets one
review round. A round whose report holds a standalone `DOOR-CHANGE:<task>`
line writes a stop for the current pin version: no further round, review or
merge card starts on that pin, and firstmate raises a new card.

    fm_door.py effective --spec FILE --config FILE
    fm_door.py pin                                      (the pin JSON on stdin)
    fm_door.py gate --repo R --base B --head H          (the pin JSON on stdin)
    fm_door.py ci --event FILE --repo R --base B --head H
    fm_door.py stopped --state S --task T               exit 3 when stopped
    fm_door.py stop --state S --task T --version N --round N --head H --actor A
    fm_door.py marker --task T --file NOTE              exit 0 when it says DOOR-CHANGE
"""
import argparse
from datetime import datetime, timezone
import fnmatch
import json
import os
from pathlib import Path
import re
import subprocess
import sys

KINDS = ('two-way', 'one-way')
NO_DOOR = 'The spec names no door, so the task takes the one-way path.'
BAD_DOOR = 'The spec door is not a kind and a reason, so the task takes the one-way path.'
OLD_PIN = 'This pin was written before doors chose the path, so the task takes the one-way path.'
EXTERNAL = 'An external project keeps the one-way path.'


def sensitive(config_text):
    """The top-level `door: sensitive:` globs of a config.yaml text."""
    lines = (config_text or '').splitlines()
    out, inside, listing = [], False, False
    for raw in lines:
        line = re.sub(r'\s+#.*$', '', raw).rstrip()
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        if not line.startswith((' ', '\t')):
            inside, listing = re.fullmatch(r'door:\s*', line) is not None, False
            continue
        if not inside:
            continue
        key = re.fullmatch(r'\s+([A-Za-z_]+):\s*(.*)', line)
        if key:
            listing = key.group(1) == 'sensitive'
            continue
        item = re.fullmatch(r'\s+-\s+(.+)', line)
        if listing and item:
            out.append(item.group(1).strip().strip('"\''))
    return out


def matched(path, globs):
    return next((glob for glob in globs if fnmatch.fnmatchcase(path, glob)), None)


def declared(spec):
    """(kind, reason) the spec names; one-way with a fixed reason otherwise."""
    door = spec.get('door') if isinstance(spec, dict) else None
    if door is None:
        return 'one-way', NO_DOOR
    if (isinstance(door, dict) and set(door) == {'kind', 'reason'} and door['kind'] in KINDS
            and isinstance(door['reason'], str) and door['reason'].strip() and '\n' not in door['reason']):
        return door['kind'], door['reason'].strip()
    return 'one-way', BAD_DOOR


def effective(spec, config_text):
    """The door a pin keeps: a two-way spec with a sensitive scope entry is one-way."""
    kind, reason = declared(spec)
    if kind == 'two-way':
        globs = sensitive(config_text)
        for entry in spec.get('scope') or []:
            glob = matched(entry, globs) if isinstance(entry, str) else None
            if glob:
                return dict(kind='one-way', forced_by=entry,
                            reason=f'The scope entry {entry} is on the sensitive list ({glob}), '
                                   'so the task takes the one-way path.')
    return dict(kind=kind, reason=reason, forced_by=None)


def at_gate(pin, paths):
    """The door a head is gated by: the pin's, one-way when a changed path is sensitive."""
    if not isinstance(pin, dict) or pin.get('external'):
        return dict(kind='one-way', reason=EXTERNAL, forced_by=None)
    door = pin.get('door')
    if not (isinstance(door, dict) and door.get('kind') in KINDS and isinstance(door.get('reason'), str)):
        return dict(kind='one-way', reason=OLD_PIN, forced_by=None)
    if door['kind'] == 'two-way':
        globs = sensitive(((pin.get('snapshots') or {}).get('contract') or {}).get('text', ''))
        for path in paths:
            glob = matched(path, globs)
            if glob:
                return dict(kind='one-way', forced_by=path,
                            reason=f'The diff changes {path}, which is on the sensitive list ({glob}), '
                                   'so the head takes the one-way path.')
    return dict(kind=door['kind'], reason=door['reason'], forced_by=door.get('forced_by'))


def changed(repo, base, head):
    result = subprocess.run(['git', '-C', str(repo), 'diff', '--no-renames', '--name-only', '-z',
                             base + '...' + head], stdin=subprocess.DEVNULL, capture_output=True, check=False)
    if result.returncode:
        raise ValueError('cannot list the changed paths: ' + result.stderr.decode(errors='replace').strip())
    return [p for p in result.stdout.decode().split('\0') if p]


def body_line(door, version):
    """The `Door:` line the launcher renders from a pin into a self PR body."""
    return f'Door: {door["kind"]}, from pin {version}: {door["reason"]}'


def body_door(body):
    """The kind on the last `Door:` line rendered from a pin. A body rendered
    before T-303 ("Door: two-way — not recorded.") names no pin: one-way."""
    found = re.findall(r'^Door: (two-way|one-way), from pin [0-9]+: ', body or '', re.M)
    return found[-1] if found else None


def ci(event, repo, base, head):
    """CI's door: the PR body's, one-way when the diff touches a sensitive path.
    The sensitive list is the base's config.yaml, never the head's."""
    try:
        body = (json.loads(Path(event).read_text()).get('pull_request') or {}).get('body') or ''
    except (OSError, ValueError, AttributeError):
        body = ''
    said = body_door(body)
    if said != 'two-way':
        return dict(kind='one-way', said=said or 'none', forced_by=None)
    config = subprocess.run(['git', '-C', str(repo), 'show', base + ':config.yaml'], stdin=subprocess.DEVNULL,
                            capture_output=True, check=False).stdout.decode(errors='replace')
    globs = sensitive(config)
    for path in changed(repo, base, head):
        if matched(path, globs):
            return dict(kind='one-way', said=said, forced_by=path)
    return dict(kind='two-way', said=said, forced_by=None)


def line(door):
    """One line for a gate transcript or a prompt."""
    return door['kind'] + ': ' + door['reason']


# --- the door-change stop --------------------------------------------------

def current_version(state, task):
    folder = Path(state) / 'pins' / task
    versions = [int(p.stem) for p in folder.glob('*.json') if p.stem.isdigit()] if folder.is_dir() else []
    return max(versions) if versions else None


def stop_path(state, task, version):
    return Path(state) / 'door-stops' / task / (str(version) + '.json')


def stopped(state, task):
    """The stop record of the task's current pin, or None."""
    version = current_version(state, task)
    if version is None:
        return None
    path = stop_path(state, task, version)
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text())
    except ValueError:
        return dict(task=task, version=version)


def write_stop(state, task, version, round_number, head, actor):
    path = stop_path(state, task, version)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        return json.loads(path.read_text())
    record = dict(task=task, version=version, round=round_number, head=head, actor=actor,
                  time=datetime.now(timezone.utc).isoformat())
    temporary = path.with_name('.' + path.name + '.' + str(os.getpid()))
    temporary.write_text(json.dumps(record) + '\n')
    os.replace(temporary, path)
    return record


def marker(task, text):
    return re.search(r'^DOOR-CHANGE:' + re.escape(task) + r'\s*$', text or '', re.M) is not None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['effective', 'pin', 'gate', 'ci', 'stopped', 'stop', 'marker'])
    for name in ('spec', 'config', 'repo', 'base', 'head', 'event', 'state', 'task', 'actor', 'file'):
        parser.add_argument('--' + name, default='')
    parser.add_argument('--version', type=int)
    parser.add_argument('--round', type=int, default=0)
    args = parser.parse_args()
    if args.command == 'effective':
        config = Path(args.config).read_text() if args.config and Path(args.config).is_file() else ''
        print(json.dumps(effective(json.loads(Path(args.spec).read_text()), config), ensure_ascii=False))
    elif args.command in ('pin', 'gate'):
        paths = changed(args.repo, args.base, args.head) if args.command == 'gate' else []
        door = at_gate(json.loads(sys.stdin.read()), paths)
        print(json.dumps(dict(door, line=line(door)), ensure_ascii=False))
    elif args.command == 'ci':
        print(json.dumps(ci(args.event, args.repo, args.base, args.head)))
    elif args.command == 'stopped':
        record = stopped(args.state, args.task)
        if record:
            print(json.dumps(record))
            return 3
    elif args.command == 'stop':
        if args.version is None:
            raise ValueError('a stop needs the pin version')
        print(json.dumps(write_stop(args.state, args.task, args.version, args.round, args.head, args.actor)))
    else:
        return 0 if marker(args.task, Path(args.file).read_text()) else 1
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('fm-door: ' + str(error), file=sys.stderr)
        sys.exit(65)
