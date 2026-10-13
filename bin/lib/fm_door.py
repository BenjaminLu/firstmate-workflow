#!/usr/bin/env python3
"""T-303, T-305: a task's door picks its path, on every project.

A two-way change can be undone by a revert; a one-way change cannot. A task
spec, self or external, names its door as `door: {"kind": "two-way"|"one-way",
"reason": "<one line>"}`. The effective door is computed once, when a pin or
repin is written, and kept in the pin as `door: {kind, reason, forced_by}`; a
pin without it (one written before T-303) is one-way.

The paths that are always one-way (T-305): the engine config.yaml's
`door.base` globs apply to every project and no project can remove them; the
self project adds its own `door.sensitive`, and an external project adds
`projects.<name>.door.sensitive`, which counts only while it equals the list a
captain card approved (`<project state>/door-list.json`). A pin written since
T-305 keeps the lists it was decided with as `door_lists: {base, project}`.

A two-way spec with a scope entry that itself falls inside a listed path is
pinned one-way. A two-way pin whose diff touches a listed path, or a path no
list can classify (a new top-level path, a rename, a submodule), is handled as
one-way at the gates, path by path, and the worker launcher writes a stop for
the pin at the end of the round that touched it.

Cannot decide means ask (T-305): a pin whose spec names no door or a malformed
one, or an external pin whose project has no approved list, keeps one-way and
records `door_ask: {signal, en, zh-TW}`. Its task waits on a captain card: A
takes the one-way path, B revises the spec, C parks the task. A stop found in a
round (a listed or unclassified path, or a `DOOR-CHANGE:<task>` line) waits on
a card that never offers another path. An engine config.yaml without a
`door.base` list keeps the T-303 rules: a missing door is one-way and an
external project keeps the one-way path.

A two-way task skips the plan round and the fail-first gate, and its review
checks correctness and scope only, under the same round budget.

    fm_door.py effective --spec FILE --config FILE
    fm_door.py pin                                      (the pin JSON on stdin)
    fm_door.py gate --repo R --base B --head H          (the pin JSON on stdin)
    fm_door.py ci --event FILE --repo R --base B --head H
    fm_door.py stopped --state S --task T               exit 3 when stopped
    fm_door.py touched --repo TREE --base B             (the pin JSON on stdin)
    fm_door.py stop --state S --task T --version N --round N --head H --actor A [--path P --why W]
    fm_door.py marker --task T --file NOTE              exit 0 when it says DOOR-CHANGE
    fm_door.py card --state S --task T --project P --repo ENGINE   raise the stop's captain card once
    fm_door.py list-status --state S --project P --config FILE
    fm_door.py propose-list --state S --project P --task T --id ID --globs JSON   (card details on stdout)
    fm_door.py apply-list --state S --project P --id ID --config FILE
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
LIST_RECORD = 'door-list.json'
BIN = Path(__file__).resolve().parents[1]


# --- the lists -------------------------------------------------------------

def yaml_lists(config_text):
    """Every block list of a config.yaml text, keyed by its tuple of keys."""
    out, stack = {}, []
    for raw in (config_text or '').splitlines():
        line = re.sub(r'\s+#.*$', '', raw).rstrip()
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        indent = len(line) - len(line.lstrip(' '))
        body = line.strip()
        item = re.fullmatch(r'-\s+(.+)', body)
        while stack and stack[-1][0] >= indent:
            stack.pop()
        if item:
            out.setdefault(tuple(key for _, key in stack), []).append(item.group(1).strip().strip('"\''))
            continue
        key = re.fullmatch(r'([^\s:#][^:]*):(?:\s+.*)?', body)
        if key:
            stack.append((indent, key.group(1).strip()))
    return out


def unique(globs):
    return list(dict.fromkeys(globs))


def base(config_text):
    """The engine's `door.base` globs: always one-way, on every project."""
    return yaml_lists(config_text).get(('door', 'base'), [])


def asking(config_text):
    """T-305 rules apply where the engine config declares its base list."""
    return bool(base(config_text))


def sensitive(config_text):
    """The self project's list: the engine's base list and its own `door.sensitive`."""
    found = yaml_lists(config_text)
    return unique(found.get(('door', 'base'), []) + found.get(('door', 'sensitive'), []))


def project_list(config_text, project):
    """An external project's own `projects.<name>.door.sensitive`, or None."""
    return yaml_lists(config_text).get(('projects', project, 'door', 'sensitive'))


def matched(path, globs):
    return next((glob for glob in globs if fnmatch.fnmatchcase(path, glob)), None)


def answered(state, ident, task=None):
    """The letter the captain chose on card `ident`, or None."""
    if not isinstance(ident, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*', ident):
        return None
    path = Path(state) / 'decisions' / (ident + '.json')
    if not path.is_file() or path.is_symlink():
        return None
    try:
        record = json.loads(path.read_text())
    except ValueError:
        return None
    if not isinstance(record, dict) or record.get('id') != ident or record.get('chosen') not in ('A', 'B', 'C'):
        return None
    if task is not None and record.get('task') != task:
        return None
    return record['chosen']


def list_record(state):
    path = Path(state) / LIST_RECORD
    if not path.is_file() or path.is_symlink():
        return None
    try:
        record = json.loads(path.read_text())
    except ValueError:
        return None
    return record if isinstance(record, dict) else None


def list_status(state, project, config_text):
    """(globs, why): the approved list, or None and 'missing' or 'edited'.

    A list counts only while it equals the record an answered captain card
    wrote; a hand-written or hand-edited list counts as no list."""
    globs = project_list(config_text, project)
    if globs is None:
        return None, 'missing'
    record = list_record(state)
    if (not record or record.get('project') != project or record.get('sensitive') != globs
            or answered(state, record.get('card'), record.get('task')) != 'A'):
        return None, 'edited'
    return globs, None


# --- what a pin keeps ------------------------------------------------------

def declared(spec):
    """(kind, reason) the spec names; one-way with a fixed reason otherwise."""
    door = spec.get('door') if isinstance(spec, dict) else None
    if door is None:
        return 'one-way', NO_DOOR
    if (isinstance(door, dict) and set(door) == {'kind', 'reason'} and door['kind'] in KINDS
            and isinstance(door['reason'], str) and door['reason'].strip() and '\n' not in door['reason']):
        return door['kind'], door['reason'].strip()
    return 'one-way', BAD_DOOR


def scope_forced(spec, globs):
    """A two-way spec's scope entry inside a listed path makes the pin one-way."""
    for entry in spec.get('scope') or []:
        glob = matched(entry, globs) if isinstance(entry, str) else None
        if glob:
            return dict(kind='one-way', forced_by=entry,
                        reason=f'The scope entry {entry} is on the sensitive list ({glob}), '
                               'so the task takes the one-way path.')
    return None


def effective(spec, config_text):
    """The T-303 door of a self pin: a two-way spec with a sensitive scope entry is one-way."""
    kind, reason = declared(spec)
    if kind == 'two-way':
        forced = scope_forced(spec, sensitive(config_text))
        if forced:
            return forced
    return dict(kind=kind, reason=reason, forced_by=None)


def signal(name, project='', path='', glob='', old=''):
    """A cannot-decide signal, named in both languages."""
    text = {
        'no-door': ('The spec names no door.', 'spec 沒寫 door。'),
        'bad-door': ('The spec door is not a kind and a reason.', 'spec 的 door 不是種類加理由。'),
        'no-list': (f'Project {project} has no approved sensitive list.', f'專案 {project} 沒有核准的敏感清單。'),
        'edited-list': (f'The sensitive list of project {project} in config.yaml is not the list the captain approved.',
                        f'config.yaml 中專案 {project} 的敏感清單不是船長核准的那一份。'),
        'sensitive': (f'The spec says two-way, but the diff changes `{path}`, which is on the sensitive list (`{glob}`).',
                      f'spec 說是 two-way，但 diff 改了 `{path}`，它在敏感清單上（`{glob}`）。'),
        'new-top': (f'The diff adds `{path}`, a new top-level path that no list can classify.',
                    f'diff 新增了 `{path}`，這是清單無法分類的新頂層路徑。'),
        'rename': (f'The diff renames `{old}` to `{path}`, which no list can classify.',
                   f'diff 把 `{old}` 改名為 `{path}`，清單無法分類。'),
        'submodule': (f'The diff changes the submodule `{path}`, which no list can classify.',
                      f'diff 改了子模組 `{path}`，清單無法分類。'),
        'door-change': ('A round reported that the door is wrong (DOOR-CHANGE).',
                        '有一輪回報 door 判斷錯誤（DOOR-CHANGE）。'),
    }[name]
    record = {'signal': name, 'en': text[0], 'zh-TW': text[1]}
    if path:
        record['path'] = path
    return record


def for_pin(spec, config_text, project=None, state=None, external=False):
    """(door, lists, ask) for a pin written under T-305.

    The lists are the engine's base list and the project's own list (the self
    project's `door.sensitive`, an external project's approved list). `ask` is
    the first cannot-decide signal, or None."""
    kind, reason = declared(spec)
    ask = None
    if reason == NO_DOOR:
        ask = signal('no-door')
    elif reason == BAD_DOOR:
        ask = signal('bad-door')
    found = yaml_lists(config_text)
    if external:
        own, why = list_status(state, project, config_text)
        if why and not ask:
            ask = signal('no-list' if why == 'missing' else 'edited-list', project=project)
    else:
        own = found.get(('door', 'sensitive'), [])
    lists = dict(base=found.get(('door', 'base'), []), project=own or [])
    door = dict(kind=kind, reason=reason, forced_by=None)
    if ask:
        door = dict(kind='one-way', forced_by=None,
                    reason=ask['en'] + ' The task waits on a captain card and keeps the one-way path.')
    elif kind == 'two-way':
        door = scope_forced(spec, unique(lists['base'] + lists['project'])) or door
    return door, lists, ask


def odd_paths(repo, base_ref, head=None):
    """The changed paths no list can classify: (path, signal) for a new
    top-level path, a rename or a submodule. head None reads the worktree,
    untracked files included."""
    def run(*args):
        result = subprocess.run(['git', '-C', str(repo), *args], stdin=subprocess.DEVNULL,
                                capture_output=True, check=False)
        if result.returncode:
            raise ValueError('cannot read the changed paths: ' + result.stderr.decode(errors='replace').strip())
        return result.stdout.decode()
    top = set(filter(None, run('ls-tree', '-z', '--name-only', base_ref).split('\0')))
    raw = run('diff', '--raw', '-z', '-M', *([base_ref + '...' + head] if head else [base_ref])).split('\0')
    found, i = [], 0
    while i < len(raw) - 1:
        meta = raw[i].split()
        if not meta or not raw[i].startswith(':'):
            i += 1
            continue
        status = meta[4]
        if status[:1] in ('R', 'C'):
            old, path = raw[i + 1], raw[i + 2]
            i += 3
            if status[:1] == 'R':
                found.append((path, signal('rename', path=path, old=old)))
                continue
        else:
            old, path = None, raw[i + 1]
            i += 2
        if '160000' in (meta[0][1:], meta[1]):
            found.append((path, signal('submodule', path=path)))
        elif path.split('/')[0] not in top and status[:1] in ('A', 'C'):
            found.append((path, signal('new-top', path=path.split('/')[0])))
    if head is None:
        for path in filter(None, run('ls-files', '-z', '-o', '--exclude-standard').split('\0')):
            if path.split('/')[0] not in top:
                found.append((path, signal('new-top', path=path.split('/')[0])))
    return [(path, why) for path, why in found if not set_aside(path)]


def at_gate(pin, paths, odd=()):
    """The door a head is gated by: the pin's, one-way when a changed path is
    listed or, on a pin written since T-305, cannot be classified."""
    stored = pin.get('door_lists') if isinstance(pin, dict) else None
    if not isinstance(pin, dict) or (pin.get('external') and not isinstance(stored, dict)):
        return dict(kind='one-way', reason=EXTERNAL, forced_by=None)
    door = pin.get('door')
    if not (isinstance(door, dict) and door.get('kind') in KINDS and isinstance(door.get('reason'), str)):
        return dict(kind='one-way', reason=OLD_PIN, forced_by=None)
    if door['kind'] == 'two-way':
        if isinstance(stored, dict):
            globs = unique(list(stored.get('base') or []) + list(stored.get('project') or []))
        else:
            globs = sensitive(((pin.get('snapshots') or {}).get('contract') or {}).get('text', ''))
        for path in paths:
            glob = matched(path, globs)
            if glob:
                return dict(signal('sensitive', path=path, glob=glob), kind='one-way', forced_by=path,
                            reason=f'The diff changes {path}, which is on the sensitive list ({glob}), '
                                   'so the head takes the one-way path.')
        if isinstance(stored, dict):
            for path, why in odd:
                return dict(why, kind='one-way', forced_by=why.get('path', path),
                            reason=why['en'] + ' So the head takes the one-way path.')
    return dict(kind=door['kind'], reason=door['reason'], forced_by=door.get('forced_by'))


def changed(repo, base_ref, head):
    result = subprocess.run(['git', '-C', str(repo), 'diff', '--no-renames', '--name-only', '-z',
                             base_ref + '...' + head], stdin=subprocess.DEVNULL, capture_output=True, check=False)
    if result.returncode:
        raise ValueError('cannot list the changed paths: ' + result.stderr.decode(errors='replace').strip())
    return [p for p in result.stdout.decode().split('\0') if p]


SET_ASIDE = ('.fm-say.md', '.fm-prompt.md')


def set_aside(path):
    return path in SET_ASIDE or path.startswith('design/tasks/') or path.startswith('.fm-')


def touched(tree, base_ref):
    """The paths a round's worktree changes against base: committed, uncommitted
    and untracked, without the round's note, its prompt or the pinned spec."""
    paths = set(changed(tree, base_ref, 'HEAD'))
    for args in (['diff', '--no-renames', '--name-only', '-z', base_ref],
                 ['ls-files', '-z', '-o', '--exclude-standard']):
        result = subprocess.run(['git', '-C', str(tree)] + args, stdin=subprocess.DEVNULL,
                                capture_output=True, check=False)
        if result.returncode:
            raise ValueError('cannot list the round\'s paths: ' + result.stderr.decode(errors='replace').strip())
        paths.update(p for p in result.stdout.decode().split('\0') if p)
    return sorted(p for p in paths if not set_aside(p))


def body_line(door, version):
    """The `Door:` line the launcher renders from a pin into a self PR body."""
    return f'Door: {door["kind"]}, from pin {version}: {door["reason"]}'


def body_door(body):
    """The kind on the last `Door:` line rendered from a pin. A body rendered
    before T-303 ("Door: two-way — not recorded.") names no pin: one-way."""
    found = re.findall(r'^Door: (two-way|one-way), from pin [0-9]+: ', body or '', re.M)
    return found[-1] if found else None


def ci(event, repo, base_ref, head):
    """CI's door: the PR body's, one-way when the diff touches a sensitive path.
    The sensitive list is the base's config.yaml, never the head's."""
    try:
        body = (json.loads(Path(event).read_text()).get('pull_request') or {}).get('body') or ''
    except (OSError, ValueError, AttributeError):
        body = ''
    said = body_door(body)
    if said != 'two-way':
        return dict(kind='one-way', said=said or 'none', forced_by=None)
    config = subprocess.run(['git', '-C', str(repo), 'show', base_ref + ':config.yaml'], stdin=subprocess.DEVNULL,
                            capture_output=True, check=False).stdout.decode(errors='replace')
    globs = sensitive(config)
    for path in changed(repo, base_ref, head):
        if matched(path, globs):
            return dict(kind='one-way', said=said, forced_by=path)
    return dict(kind='two-way', said=said, forced_by=None)


def line(door):
    """One line for a gate transcript or a prompt."""
    return door['kind'] + ': ' + door['reason']


# --- the stop and its captain card -----------------------------------------

def current_version(state, task):
    folder = Path(state) / 'pins' / task
    versions = [int(p.stem) for p in folder.glob('*.json') if p.stem.isdigit()] if folder.is_dir() else []
    return max(versions) if versions else None


def stop_path(state, task, version):
    return Path(state) / 'door-stops' / task / (str(version) + '.json')


def ask_path(state, task, version):
    """The card record of a pin that could not decide its door."""
    return Path(state) / 'door-stops' / task / (str(version) + '.pin.json')


def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except ValueError:
        return None


def stopped(state, task):
    """The stop record of the task's current pin, or None.

    A stop written in a round holds the pin until a repin. A pin that could
    not decide its door holds until the captain answers A on its card."""
    version = current_version(state, task)
    if version is None:
        return None
    path = stop_path(state, task, version)
    if path.is_file():
        return read_json(path) or dict(task=task, version=version)
    pin = read_json(Path(state) / 'pins' / task / (str(version) + '.json')) or {}
    ask = pin.get('door_ask')
    if not isinstance(ask, dict):
        return None
    record = dict(ask, task=task, version=version, round=0, when='pin')
    held = ask_path(state, task, version)
    if held.is_file():
        record.update(card=(read_json(held) or {}).get('card'))
        if answered(state, record['card'], task) == 'A':
            return None
    return record


def save(path, record):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name('.' + path.name + '.' + str(os.getpid()))
    temporary.write_text(json.dumps(record, ensure_ascii=False) + '\n')
    os.replace(temporary, path)


def write_stop(state, task, version, round_number, head, actor, path_=None, why=None, found=None):
    path = stop_path(state, task, version)
    if path.exists():
        return json.loads(path.read_text())
    record = dict(task=task, version=version, round=round_number, head=head, actor=actor, when='round',
                  time=datetime.now(timezone.utc).isoformat())
    if path_:
        record.update(forced_by=path_, reason=why or '')
    record.update(found or signal('door-change'))
    save(path, record)
    return record


def marker(task, text):
    return re.search(r'^DOOR-CHANGE:' + re.escape(task) + r'\s*$', text or '', re.M) is not None


GLOSSARY_FALLBACK = ['door', 'spec', 'pin', 'repin', 'round']


def glossary(texts, lang):
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import fm_plain
        terms = fm_plain.load_glossary()
        return list(dict.fromkeys(fm_plain.find_terms('\n'.join(texts), lang, terms)))
    except (ImportError, ValueError, OSError):
        return GLOSSARY_FALLBACK


def card_details(task, stop):
    """A captain card for a held pin, in both languages. A pin that could not
    decide offers the one-way path; a stop found in a round never offers
    another path, so its A asks firstmate to explain first."""
    pinned = stop.get('when') == 'pin'
    en, tw = stop.get('en') or signal('door-change')['en'], stop.get('zh-TW') or signal('door-change')['zh-TW']
    if pinned:
        a_en = dict(description='Take the one-way path.', pros='The task starts now, with the full checks.',
                    cons='The task takes more steps than a two-way task.')
        a_tw = dict(description='走 one-way 流程。', pros='任務馬上開始，並經過完整檢查。', cons='步驟比 two-way 任務多。')
        how_en = 'A: the task starts on the one-way path.'
        how_tw = 'A：任務以 one-way 流程開始。'
    else:
        a_en = dict(description='Ask firstmate to explain the signal first.', pros='You learn more before you decide.',
                    cons='The task waits longer.')
        a_tw = dict(description='先請 firstmate 說明這個訊號。', pros='決定前可以了解更多。', cons='任務等待較久。')
        how_en = 'A: the task stays held while firstmate explains the signal.'
        how_tw = 'A：firstmate 說明訊號時，任務維持暫停。'
    version = stop.get('version')
    content = {
        'en': dict(
            title=f'{task}: the door cannot be decided; choose the next step',
            explanation=f'Firstmate cannot decide the door of {task}. {en}',
            before=f'Pin v{version} of {task} is held, and no round starts.',
            after='Your answer sets the next step for the task.',
            outcome='The worker launcher follows your answer.',
            options=dict(A=a_en,
                         B=dict(description='Revise the spec.', pros='A new spec can name the right door.',
                                cons='Firstmate writes a new spec, and you approve its repin.'),
                         C=dict(description='Park the task.', pros='No round uses time or money.',
                                cons='The task stays open and unmerged.')),
            intent=[dict(kind='step', text=f'Choose the next step for {task}.')],
            why=[dict(kind='fact', text=en)],
            how=[dict(kind='fact', text=how_en),
                 dict(kind='fact', text='B: firstmate writes a new spec and asks you to approve its repin.'),
                 dict(kind='fact', text='C: the task stays held, and firstmate writes no spec.')],
            done=[dict(kind='fact', text='Intent 1: the launcher records your answer.')]),
        'zh-TW': dict(
            title=f'{task}：無法判定 door；請選擇下一步',
            explanation=f'firstmate 無法判定 {task} 的 door。{tw}',
            before=f'{task} 的 pin v{version} 已暫停，不會開始新一輪。',
            after='你的回答決定任務的下一步。',
            outcome='worker 啟動器依你的回答處理。',
            options=dict(A=a_tw,
                         B=dict(description='修改 spec。', pros='新的 spec 可以寫對 door。',
                                cons='firstmate 撰寫新的 spec，你核准重新固定。'),
                         C=dict(description='暫停任務。', pros='不再花費時間與費用。', cons='任務保持開啟且未合併。')),
            intent=[dict(kind='step', text=f'請選擇 {task} 的下一步。')],
            why=[dict(kind='fact', text=tw)],
            how=[dict(kind='fact', text=how_tw),
                 dict(kind='fact', text='B：firstmate 撰寫新的 spec，並請你核准重新固定。'),
                 dict(kind='fact', text='C：任務維持暫停，firstmate 不撰寫 spec。')],
            done=[dict(kind='fact', text='意圖 1：啟動器記錄你的回答。')]),
    }
    for lang, loc in content.items():
        loc['glossary'] = glossary([json.dumps(loc, ensure_ascii=False)], lang)
    return content


def raise_card(state, task, project, engine):
    """Request the captain card of the current pin's stop once; its id."""
    stop = stopped(state, task)
    if not stop:
        return None
    record_path = ask_path(state, task, stop['version']) if stop.get('when') == 'pin' \
        else stop_path(state, task, stop['version'])
    record = read_json(record_path) if record_path.is_file() else None
    record = record if isinstance(record, dict) else dict(task=task, version=stop['version'])
    ident = record.get('card')
    if ident and any((Path(state) / folder / (ident + '.json')).exists() for folder in ('pending', 'decisions')):
        return ident
    decide = [str(BIN / 'fm-decide.sh'), '--repo', str(engine)]
    run = dict(stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False, timeout=120)
    if not ident:
        result = subprocess.run(decide + ['--allocate', '--task', task, '--project', project], **run)
        ident = result.stdout.strip()
        if result.returncode or not re.fullmatch(r'D-[A-Za-z0-9-]+', ident):
            raise ValueError('cannot allocate the door card: ' + result.stderr.strip())
        record['card'] = ident
        save(record_path, record)
    details = Path(state) / 'decision-details-built' / (ident + '.json')
    save(details, card_details(task, stop))
    result = subprocess.run(decide + ['--request', ident, '--task', task, '--project', project,
                                      '--purpose', 'decision', '--details', str(details)], **run)
    if result.returncode:
        raise ValueError('cannot request the door card ' + ident + ': ' + (result.stderr or result.stdout).strip())
    return ident


# --- a project's own list --------------------------------------------------

def list_details(project, task, globs, config_text):
    """The card that proposes a project's sensitive list; A writes it."""
    shown = ', '.join('`' + glob + '`' for glob in globs) or 'none'
    base_shown = ', '.join('`' + glob + '`' for glob in base(config_text)) or 'none'
    content = {
        'en': dict(
            title=f'{project}: approve its sensitive list',
            explanation=f'Project {project} needs its own sensitive list before firstmate can decide a door.',
            before=f'Project {project} has no approved sensitive list.',
            after=f'The list is {shown}, on top of the base list.',
            outcome='Firstmate writes the list into config.yaml and keeps your answer.',
            options=dict(A=dict(description='Approve this list.', pros='Tasks of this project can take two paths.',
                                cons='A path missing from the list can take the two-way path.'),
                         B=dict(description='Change the list first.', pros='The list matches the project better.',
                                cons='Its tasks wait for a new card.'),
                         C=dict(description='Keep no list.', pros='Nothing changes.',
                                cons='Every task of this project waits on a card.')),
            intent=[dict(kind='step', text=f'Approve the sensitive list of {project} for {task}.')],
            why=[dict(kind='fact', text=f'The base list ({base_shown}) applies to every project.')],
            how=[dict(kind='fact', text='A: firstmate writes the list, and every later pin of the project uses it.')],
            done=[dict(kind='fact', text='Intent 1: the list in config.yaml equals this list.')]),
        'zh-TW': dict(
            title=f'{project}：核准它的敏感清單',
            explanation=f'專案 {project} 需要自己的敏感清單，firstmate 才能判定 door。',
            before=f'專案 {project} 沒有核准的敏感清單。',
            after=f'清單是 {shown}，加在基本清單之上。',
            outcome='firstmate 把清單寫進 config.yaml，並保存你的回答。',
            options=dict(A=dict(description='核准這份清單。', pros='這個專案的任務可以走兩種流程。',
                                cons='清單漏掉的路徑可能走 two-way 流程。'),
                         B=dict(description='先修改清單。', pros='清單更符合專案。', cons='任務要等新卡。'),
                         C=dict(description='不設清單。', pros='不做任何改動。', cons='這個專案的每個任務都要等卡。')),
            intent=[dict(kind='step', text=f'為 {task} 核准 {project} 的敏感清單。')],
            why=[dict(kind='fact', text=f'基本清單（{base_shown}）適用於每個專案。')],
            how=[dict(kind='fact', text='A：firstmate 寫入清單，之後這個專案的每個 pin 都使用它。')],
            done=[dict(kind='fact', text='意圖 1：config.yaml 中的清單等於這份清單。')]),
    }
    for lang, loc in content.items():
        loc['glossary'] = glossary([json.dumps(loc, ensure_ascii=False)], lang)
    return content


def check_globs(globs):
    if (not isinstance(globs, list) or not globs
            or not all(isinstance(g, str) and g.strip() == g and g and '\n' not in g and not g.startswith('/')
                       and '..' not in g.split('/') and not re.search(r'["\'#]', g) for g in globs)):
        raise ValueError('a sensitive list is a nonempty list of repository-relative globs')
    return globs


def propose_list(state, project, task, ident, globs, config_text):
    check_globs(globs)
    save(Path(state) / 'door-list-proposals' / (ident + '.json'),
         dict(project=project, task=task, card=ident, sensitive=globs))
    return list_details(project, task, globs, config_text)


def write_list(config_text, project, globs):
    """The config text with `projects.<project>.door.sensitive` set to globs."""
    lines = config_text.splitlines(keepends=True)
    start = next((i for i, raw in enumerate(lines) if re.match(r'projects:\s*(#.*)?$', raw.rstrip('\r\n'))), None)
    if start is None:
        raise ValueError('config.yaml has no projects: block')
    entry = None
    for i in range(start + 1, len(lines)):
        raw = lines[i].rstrip('\r\n')
        if raw.strip() and not raw.lstrip().startswith('#') and not raw[:1].isspace():
            break
        if re.match(r'  ' + re.escape(project) + r':\s*(#.*)?$', raw):
            entry = i
            break
    if entry is None:
        raise ValueError('project ' + project + ' is not registered in config.yaml')
    end, door = entry + 1, None
    while end < len(lines):
        raw = lines[end].rstrip('\r\n')
        if raw.strip() and not raw.lstrip().startswith('#') and len(raw) - len(raw.lstrip(' ')) <= 2:
            break
        if re.match(r'    door:\s*(#.*)?$', raw):
            door = end
        end += 1
    while end > entry + 1 and not lines[end - 1].strip():
        end -= 1
    block = ['    door:\n', '      sensitive:\n'] + ['        - "' + glob + '"\n' for glob in globs]
    if door is not None:
        stop = door + 1
        while stop < end and (not lines[stop].strip() or len(lines[stop]) - len(lines[stop].lstrip(' ')) > 4):
            stop += 1
        lines[door:stop] = block
    else:
        if end and not lines[end - 1].endswith('\n'):
            lines[end - 1] += '\n'
        lines[end:end] = block
    return ''.join(lines)


def apply_list(state, project, ident, config_path):
    """Write the proposed list once the captain answered A on its card."""
    proposal = read_json(Path(state) / 'door-list-proposals' / (ident + '.json'))
    if not isinstance(proposal, dict) or proposal.get('project') != project or proposal.get('card') != ident:
        raise ValueError('no proposed list for card ' + ident)
    if answered(state, ident, proposal.get('task')) != 'A':
        raise ValueError('card ' + ident + ' has no captain A; no list was written')
    globs = check_globs(proposal['sensitive'])
    config_path = Path(config_path)
    text = write_list(config_path.read_text() if config_path.is_file() else '', project, globs)
    if project_list(text, project) != globs:
        raise ValueError('the written list does not read back; config.yaml was not changed')
    temporary = config_path.with_name('.' + config_path.name + '.' + str(os.getpid()))
    temporary.write_text(text)
    os.replace(temporary, config_path)
    record = dict(project=project, task=proposal['task'], card=ident, sensitive=globs,
                  time=datetime.now(timezone.utc).isoformat())
    save(Path(state) / LIST_RECORD, record)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['effective', 'pin', 'gate', 'touched', 'ci', 'stopped', 'stop', 'marker',
                                            'card', 'list-status', 'propose-list', 'apply-list'])
    for name in ('spec', 'config', 'repo', 'base', 'head', 'event', 'state', 'task', 'actor', 'file', 'path', 'why',
                 'project', 'id', 'globs', 'found'):
        parser.add_argument('--' + name, default='')
    parser.add_argument('--version', type=int)
    parser.add_argument('--round', type=int, default=0)
    args = parser.parse_args()
    config = Path(args.config).read_text() if args.config and Path(args.config).is_file() else ''
    if args.command == 'effective':
        print(json.dumps(effective(json.loads(Path(args.spec).read_text()), config), ensure_ascii=False))
    elif args.command in ('pin', 'gate', 'touched'):
        pin = json.loads(sys.stdin.read())
        paths, odd = [], []
        if args.command == 'gate':
            paths = changed(args.repo, args.base, args.head)
            odd = odd_paths(args.repo, args.base, args.head) if isinstance(pin.get('door_lists'), dict) else []
        elif args.command == 'touched':
            paths = touched(args.repo, args.base)
            odd = odd_paths(args.repo, args.base) if isinstance(pin.get('door_lists'), dict) else []
        door = at_gate(pin, paths, odd)
        print(json.dumps(dict(door, line=line(door)), ensure_ascii=False))
    elif args.command == 'ci':
        print(json.dumps(ci(args.event, args.repo, args.base, args.head)))
    elif args.command == 'stopped':
        record = stopped(args.state, args.task)
        if record:
            print(json.dumps(record, ensure_ascii=False))
            return 3
    elif args.command == 'stop':
        if args.version is None:
            raise ValueError('a stop needs the pin version')
        found = json.loads(args.found) if args.found else None
        if found is not None and not (isinstance(found, dict) and isinstance(found.get('signal'), str)
                                      and isinstance(found.get('en'), str) and isinstance(found.get('zh-TW'), str)):
            raise ValueError('--found is a signal with en and zh-TW text')
        if found:
            found = {key: found[key] for key in ('signal', 'en', 'zh-TW', 'path') if key in found}
        print(json.dumps(write_stop(args.state, args.task, args.version, args.round, args.head, args.actor,
                                    args.path or None, args.why or None, found), ensure_ascii=False))
    elif args.command == 'card':
        ident = raise_card(args.state, args.task, args.project, args.repo)
        if ident:
            print(ident)
    elif args.command == 'list-status':
        globs, why = list_status(args.state, args.project, config)
        print(json.dumps(dict(project=args.project, sensitive=globs, why=why, base=base(config))))
        return 0 if globs is not None else 3
    elif args.command == 'propose-list':
        print(json.dumps(propose_list(args.state, args.project, args.task, args.id, json.loads(args.globs or 'null'),
                                      config), ensure_ascii=False))
    elif args.command == 'apply-list':
        print(json.dumps(apply_list(args.state, args.project, args.id, args.config)))
    else:
        return 0 if marker(args.task, Path(args.file).read_text()) else 1
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print('fm-door: ' + str(error), file=sys.stderr)
        sys.exit(65)
