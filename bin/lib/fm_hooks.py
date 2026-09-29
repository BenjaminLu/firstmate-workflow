#!/usr/bin/env python3
"""Installing the hooks that wake firstmate (T-137).

No harness config is committed. This writes, or removes, exactly our hook
entries in each harness's local, uncommitted config for one checkout:

  claude  .claude/settings.local.json   Stop (the turn-end guard, and the
                                        asyncRewake arm), UserPromptSubmit
  codex   .codex/hooks.json             Stop (the guard), UserPromptSubmit
  cursor  .cursor/hooks.json            stop (the guard, bounded by loop_limit)

It merges into what is there, changes nothing the second time, says what
it changed, and uninstall takes away only what install put. `hooks` in the
fm command line and `fm-session.sh start` (with --detect: the harness this
session runs in, and never in a crew round) both run this file directly.

  fm_hooks.py install|uninstall [--harness claude|codex|cursor] [--repo DIR] [--detect]
"""
import json
import os
import re
import shlex
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
# no __pycache__ in bin/lib: the tree stays exactly what was committed
sys.dont_write_bytecode = True
import fm_lifeline as life  # noqa: E402
import fm_watch as watch  # noqa: E402

HARNESSES = watch.HARNESSES


def hook_config(root, harness):
    """(the local config's path under root, {event: [entries]})."""
    q = shlex.quote
    arm_cmd = q(str(Path(root) / 'bin/fm-watch-arm.sh'))
    guard_cmd = q(str(Path(root) / 'bin/fm-turnend-guard.sh'))
    if harness == 'claude':
        return '.claude/settings.local.json', {
            'Stop': [{'hooks': [
                {'type': 'command', 'command': f'{guard_cmd} --hook claude', 'timeout': 30},
                {'type': 'command', 'command': f'{arm_cmd} --hook claude', 'asyncRewake': True,
                 'timeout': watch.CLAUDE_TIMEOUT}]}],
            'UserPromptSubmit': [{'hooks': [
                {'type': 'command', 'command': f'{arm_cmd} --turn-start claude', 'timeout': 30}]}]}
    if harness == 'codex':
        return '.codex/hooks.json', {
            'Stop': [{'hooks': [{'type': 'command', 'command': f'{guard_cmd} --hook codex', 'timeout': 60}]}],
            'UserPromptSubmit': [{'hooks': [
                {'type': 'command', 'command': f'{arm_cmd} --turn-start codex', 'timeout': 30}]}]}
    if harness == 'cursor':
        return '.cursor/hooks.json', {
            'stop': [{'command': f'{guard_cmd} --hook cursor', 'timeout': 60, 'loop_limit': 5}]}
    raise ValueError(f'no such harness: {harness} (claude, codex, cursor)')


OURS = re.compile(r'/bin/(fm-watch-arm|fm-turnend-guard)\.sh\'? --(hook|turn-start) ')


def _strip(entries):
    """entries without ours: a Claude/Codex group keeps its other hooks and
    goes when it held only ours; a Cursor entry is one command."""
    kept = []
    for entry in entries if isinstance(entries, list) else []:
        if not isinstance(entry, dict):
            kept.append(entry)
            continue
        if isinstance(entry.get('hooks'), list):
            inner = [h for h in entry['hooks'] if not (isinstance(h, dict) and OURS.search(str(h.get('command', '')) + ' '))]
            if inner or not entry['hooks']:
                kept.append(dict(entry, hooks=inner))
        elif not OURS.search(str(entry.get('command', '')) + ' '):
            kept.append(entry)
    return kept


def hooks_change(root, harness, install):
    """Install or uninstall ours in one harness's local config; returns
    what it did, in one line."""
    root = Path(root).resolve()
    rel, entries = hook_config(root, harness)
    path = root / rel
    if install and not (root / 'bin/fm-watch-arm.sh').is_file():
        raise ValueError(f'{root} carries no bin/fm-watch-arm.sh to point the hooks at')
    data = {}
    if path.exists():
        data = json.loads(path.read_text() or '{}')
        if not isinstance(data, dict):
            raise ValueError(f'{rel} is not a JSON object; left as it is')
    before = json.dumps(data, sort_keys=True)
    hooks = data.get('hooks') if isinstance(data.get('hooks'), dict) else {}
    changed = []
    for event in sorted(set(hooks) | set(entries)):
        old = hooks.get(event, [])
        new = _strip(old) + (entries.get(event, []) if install else [])
        if new != old:
            changed.append(event)
        if new:
            hooks[event] = new
        else:
            hooks.pop(event, None)
    if hooks:
        data['hooks'] = hooks
        if harness == 'cursor':
            data.setdefault('version', 1)
    else:
        data.pop('hooks', None)
        if harness == 'cursor' and set(data) == {'version'}:
            data = {}
    if json.dumps(data, sort_keys=True) == before:
        return f'{rel}: nothing to change ({"already installed" if install else "none of ours"})'
    if data:
        path.parent.mkdir(parents=True, exist_ok=True)
        watch.save(path, json.dumps(data, indent=2) + '\n')
    else:
        path.unlink()
        try:
            path.parent.rmdir()     # only when nothing else is in it
        except OSError:
            pass
    return f'{rel}: {"installed" if install else "removed"} {", ".join(changed)}'


def detect():
    """The harness this session runs in: FM_HARNESS, else the name of the
    session's own process (bin/lib/fm_lifeline.py's session_owner), else
    CLAUDECODE=1, which Claude Code sets for every command it runs (its
    process can be named `node`)."""
    given = os.environ.get('FM_HARNESS', '')
    if given:
        return given
    try:
        _, name = life._parent_of(life.session_owner())
    except (RuntimeError, ValueError, OSError):
        name = ''
    for harness in HARNESSES:
        if harness in (name or '').lower():
            return harness
    return 'claude' if os.environ.get('CLAUDECODE') == '1' else None


USAGE = 'usage: fm_hooks.py install|uninstall [--harness claude|codex|cursor] [--repo DIR] [--detect]'


def main(argv):
    if not argv or argv[0] not in ('install', 'uninstall'):
        print(USAGE, file=sys.stderr)
        return 64
    try:
        got = watch.options(argv[1:], {'--detect'}, {'--repo', '--harness'})
        root = watch.root_of(got)
        why = watch.standing_down(root) if '--detect' in got else None
        if why:
            print(f'fm hooks: not installed: {why}', file=sys.stderr)
            return 0
        harness = got.get('--harness') or (detect() if '--detect' in got else None)
        if '--detect' in got and not harness:
            print('fm hooks: no harness detected; run bin/lib/fm_hooks.py install --harness claude|codex|cursor',
                  file=sys.stderr)
            return 0
        for name in [harness] if harness else list(HARNESSES):
            print('fm hooks: ' + hooks_change(root, name, argv[0] == 'install'))
        return 0
    except ValueError as error:
        print(f'fm hooks: {error}', file=sys.stderr)
        return 64
    except OSError as error:
        print(f'fm hooks: {error}', file=sys.stderr)
        return 70


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
