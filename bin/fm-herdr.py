#!/usr/bin/env python3
"""Managed run artifacts, checked Herdr transport and observable session services.

Only documented CLI operations are used. Checked close is not atomic with an
unrelated client's pane operations; uncertainty always retains the pane.

Also hosts emit-status (T-036): mid-run crew_status via fm-emit.sh so every
vendor refreshes authored activity through one path.
"""
import contextlib
import fcntl
import hashlib
import hmac
import json
import math
import os
from pathlib import Path
import random
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import uuid

_children = []  # Keep Popen objects until a status/stop operation can reap them.


def save(path, value):
    """Publish durable complete JSON; never expose a partially written receipt."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.' + uuid.uuid4().hex)
    with temp.open('x') as out:
        json.dump(value, out, indent=2); out.write('\n'); out.flush(); os.fsync(out.fileno())
    os.replace(temp, path)
    fd = os.open(path.parent, os.O_RDONLY)
    try: os.fsync(fd)
    finally: os.close(fd)


def record_close(attempt, payload):
    """First successful close wins; never let a racer flip a durable closed record."""
    path = Path(attempt) / 'close.json'
    if path.exists():
        prior = read(path)
        if prior.get('status') == 'closed':
            return prior
    save(path, payload)
    return payload


def read(path):
    return json.loads(Path(path).read_text())


@contextlib.contextmanager
def locked(path, blocking=True):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        yield lock


# Two rosters (T-104): a crew member's name, rank and service record belong to
# one role, so workers and reviewers never share a name. Each installation
# draws its own crew from POOL once, into state/crew/rosters.json.
POOL = (
    'ada', 'alba', 'alma', 'anna', 'arlo', 'asa', 'ben', 'bea', 'cora', 'dora', 'eli', 'ella',
    'elsa', 'emil', 'emma', 'eva', 'ezra', 'finn', 'flora', 'gus', 'hugo', 'ida', 'ines', 'iris',
    'ivan', 'jack', 'jade', 'joel', 'jonas', 'juno', 'kit', 'lars', 'leo', 'lena', 'liam', 'lily',
    'lotte', 'luca', 'lucy', 'mabel', 'mae', 'max', 'mila', 'mira', 'nell', 'nico', 'nina', 'noah',
    'nora', 'olaf', 'olga', 'otto', 'pia', 'rosa', 'ruby', 'rufus', 'sara', 'silas', 'sofia',
    'stella', 'theo', 'tilda', 'toby', 'vera', 'viola', 'wren', 'zoe',
    'astrid', 'bjorn', 'dagny', 'elin', 'freya', 'greta', 'ingrid', 'kari', 'leif', 'linnea',
    'maja', 'nils', 'odin', 'sigrid', 'sven', 'tove', 'ulf',
    'anya', 'boris', 'darya', 'ilya', 'katya', 'lev', 'oksana', 'pavel', 'sasha', 'vesna', 'zora',
    'milan',
    'bruno', 'carla', 'diego', 'elena', 'enzo', 'gael', 'joao', 'lola', 'lucia', 'luis', 'marco',
    'mateo', 'nuno', 'paco', 'pilar', 'raul', 'rocio', 'sol', 'tiago', 'vito',
    'amir', 'aziz', 'dina', 'emre', 'farah', 'hana', 'idris', 'karim', 'laila', 'malik', 'nadia',
    'omar', 'rami', 'reza', 'sami', 'samir', 'tariq', 'yara', 'yusuf', 'zain', 'zara', 'ayse',
    'can', 'deniz', 'elif', 'kaan', 'selin', 'cyrus', 'darius', 'parisa', 'roya', 'shirin',
    'anil', 'arjun', 'asha', 'devi', 'dev', 'ishan', 'kavya', 'kiran', 'maya', 'neha', 'nikhil',
    'priya', 'raj', 'ravi', 'rohan', 'sana', 'tara', 'uma', 'veer', 'vikram',
    'aiko', 'akira', 'chen', 'daiki', 'haru', 'hiro', 'jin', 'jun', 'kaito', 'kenji', 'lan', 'lei',
    'mei', 'min', 'ming', 'riku', 'ryo', 'sakura', 'sora', 'tao', 'wei', 'yan', 'yuki', 'yuna',
    'yuto', 'hyun', 'jiwoo', 'minho', 'seo', 'anh', 'bao', 'linh', 'minh', 'thao', 'trang',
    'abeni', 'ade', 'amara', 'ayo', 'chidi', 'dayo', 'efua', 'femi', 'jabari', 'kofi', 'kwame',
    'lulu', 'nia', 'obi', 'sade', 'tendai', 'thabo', 'zola', 'zuri', 'baraka', 'imani', 'jelani',
    'kamau', 'makena', 'neema',
    'avi', 'eitan', 'noa', 'tal', 'yael', 'ari', 'shira',
    'aoife', 'cian', 'eoin', 'niamh', 'oisin', 'orla', 'rhys', 'sian', 'bryn', 'cara',
    'aroha', 'kai', 'manu', 'moana', 'nalu', 'tane', 'hemi',
    'inti', 'nayeli', 'eleni', 'nikos', 'yanni', 'juan', 'ana', 'sofie', 'kalani',
)
CREW_SIZE = 24
ROLES = {'worker': 'workers', 'reviewer': 'reviewers'}


def _config_lines(root):
    path = Path(root) / 'config.yaml'
    lines = []
    for raw in (path.read_text().splitlines() if path.is_file() else []):
        line = '' if raw.lstrip().startswith('#') else re.sub(r'\s+#.*$', '', raw).rstrip()
        lines.append(line)
    return lines


def _indent(line):
    return len(line) - len(line.lstrip())


def _config_key(lines, key):
    """`key:` among lines at their shallowest indent: (inline value, child lines), or None."""
    body = [line for line in lines if line.strip()]
    if not body: return None
    base = min(_indent(line) for line in body)
    for at, line in enumerate(lines):
        if not line.strip() or _indent(line) != base: continue
        found = re.match(r'\s*' + re.escape(key) + r':\s*(.*)$', line)
        if not found: continue
        children = []
        for child in lines[at + 1:]:
            if child.strip() and (_indent(child) < base
                                  or (_indent(child) == base and not child.lstrip().startswith('- '))):
                break
            children.append(child)
        return found.group(1).strip(), children
    return None


def _config_names(entry, label):
    """A block or [flow] list of short given names, validated as T-089 did."""
    inline, children = entry
    if inline:
        if not (inline.startswith('[') and inline.endswith(']')):
            raise ValueError('config.yaml ' + label + ' must be a list of names')
        names = [item.strip().strip('"\'') for item in inline[1:-1].split(',') if item.strip()]
    else:
        names = []
        for line in children:
            if not line.strip(): continue
            item = re.match(r'\s*-\s+(.*)$', line)
            if not item: raise ValueError('config.yaml ' + label + ' must be a list of names')
            names.append(item.group(1).strip().strip('"\''))
    if not names: raise ValueError('config.yaml ' + label + ' is empty; list names or remove the key')
    roster = []
    for name in names:
        name = name.lower()
        # Short enough that <role>-<name>-<task>-r<n> stays a readable label.
        if not re.fullmatch(r'[a-z]{1,6}', name):
            raise ValueError('config.yaml ' + label + ': ' + repr(name) + ' is not a short given name (letters only)')
        if name in roster: raise ValueError('config.yaml ' + label + ' names ' + name + ' more than once')
        roster.append(name)
    return roster


def pinned_rosters(root, warn=True):
    """The names config.yaml pins per role: `rosters:` with `workers:` and/or
    `reviewers:`, or the old single `roster:`, whose names are workers."""
    lines = _config_lines(root)
    new, old = _config_key(lines, 'rosters'), _config_key(lines, 'roster')
    if new and old:
        raise ValueError('config.yaml has both roster: and rosters:; move the roster: names under rosters: workers:')
    if old:
        if warn:
            print('fm-herdr: config.yaml roster: is the old single roster; its names are workers only'
                  ' now, so move them under rosters: workers:', file=sys.stderr)
        return {'workers': _config_names(old, 'roster')}
    if not new: return {}
    inline, children = new
    if inline:
        raise ValueError('config.yaml rosters must be a block holding workers: and/or reviewers: lists,'
                         ' not an inline value')
    body = [line for line in children if line.strip()]
    base = min((_indent(line) for line in body), default=0)
    keyed = False
    for line in body:
        if _indent(line) != base: continue
        # A list may sit at its key's own indent: `workers:` then `- ada`.
        if keyed and line.lstrip().startswith('- '): continue
        key = re.match(r'\s*([^\s:]+):', line)
        keyed = True
        if not key or key.group(1) not in ROLES.values():
            raise ValueError('config.yaml rosters: ' + (key.group(1) if key else line.strip())
                             + ' is not workers: or reviewers:')
    pinned = {}
    for key in ROLES.values():
        entry = _config_key(children, key)
        if entry: pinned[key] = _config_names(entry, 'rosters.' + key)
    if not pinned:
        raise ValueError('config.yaml rosters must hold a workers: or reviewers: list of names')
    both = [name for name in pinned.get('workers', []) if name in pinned.get('reviewers', [])]
    if both:
        raise ValueError('config.yaml rosters: ' + both[0] + ' is in both workers and reviewers;'
                         ' a name belongs to one role')
    return pinned


def rosters_path(root):
    return Path(root) / 'state/crew/rosters.json'


def drawn_rosters(root):
    """state/crew/rosters.json, checked, or None before the draw."""
    path = rosters_path(root)
    if not path.exists(): return None
    broken = ValueError(str(path) + ' is not a crew of two rosters; roster init --redraw draws a new one')
    try: crew = read(path)
    except (OSError, ValueError): raise broken
    if not isinstance(crew, dict): raise broken
    names = []
    for key in ROLES.values():
        roster = crew.get(key)
        if not (isinstance(roster, list) and roster
                and all(isinstance(n, str) and re.fullmatch(r'[a-z]{1,6}', n) for n in roster)):
            raise broken
        names += roster
    if len(set(names)) != len(names): raise broken
    return crew


def served_roles(root):
    """Each name's role: the role of its earliest run recorded under the one-role
    rule. Runs from before T-104 are not counted: T-089 let one name serve both
    roles, and that history is not judged by a rule it was not written under."""
    first = {}
    for file in (Path(root) / 'state/runs').glob('*/identity.json'):
        try: identity = read(file)
        except (OSError, ValueError): continue
        if identity.get('one_role') is not True: continue
        name, role = crew_name(identity), identity.get('role')
        if not name or role not in ROLES: continue
        record = (identity.get('created') or 0, role)
        if name not in first or record < first[name]: first[name] = record
    return {name: role for name, (_, role) in first.items()}


def crossed(name, role, served):
    """The role this name already belongs to when it is not `role`, or None: a
    name keeps the role of its first record, whatever the rosters say now."""
    held = served.get(name)
    return held if held and held != role else None


def draw_rosters(root, redraw=False):
    """Draw the installation's crew once: 2 x CREW_SIZE distinct names, uniformly
    at random from POOL; the first half are workers. Returns (crew, drawn now).
    A name a recorded run served under one role is never drawn for the other,
    so a redraw cannot hand an old worker's name to a reviewer.
    FM_ROSTER_SEED seeds the draw and exists only for tests."""
    path = rosters_path(root)
    with locked(path.parent / '.rosters.lock'):
        if not redraw:
            crew = drawn_rosters(root)
            if crew: return crew, False
        seed = os.environ.get('FM_ROSTER_SEED')
        chance = random.Random(seed) if seed else random.SystemRandom()
        served = served_roles(root)
        order = chance.sample(POOL, len(POOL))
        workers = [n for n in order if not crossed(n, 'worker', served)][:CREW_SIZE]
        reviewers = [n for n in order if n not in workers
                     and not crossed(n, 'reviewer', served)][:CREW_SIZE]
        if len(workers) < CREW_SIZE or len(reviewers) < CREW_SIZE:
            raise ValueError('the name pool cannot fill two rosters of ' + str(CREW_SIZE)
                             + ' without giving a name a second role')
        crew = dict(workers=workers, reviewers=reviewers,
                    drawn_at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
        save(path, crew)
        return crew, True


def crew_rosters(root, warn=True):
    """Each role's names: config.yaml's pinned list where it has one, else the
    drawn crew, drawn now if this installation has none. A drawn name pinned
    to the other role is left out, so no name ever serves both."""
    pinned = pinned_rosters(root, warn)
    crew, _ = draw_rosters(root)
    rosters = {}
    for key in ROLES.values():
        other = [name for k, names in pinned.items() if k != key for name in names]
        rosters[key] = pinned.get(key) or [name for name in crew[key] if name not in other]
    return rosters


# An actor is <role>-<name>-<task slug>-r<n>[<attempt mark>]. Before T-116 <n>
# was the global run counter; since, it is the task's review round, and a
# retry of the same role, task and round adds a letter (r12b). One pattern
# reads both forms; which one <n> is comes from identity.json, never from here.
ACTOR = re.compile(r'^(worker|reviewer|firstmate)-(.+)-([a-z0-9]+)-r([0-9]+)([a-z]*)$')


def crew_name(identity):
    """The crew member a run belongs to; runs before T-089 carry it in the actor."""
    if identity.get('name'): return identity['name']
    found = ACTOR.match(identity.get('actor', ''))
    return found.group(2) if found else None


def attempt_mark(attempt):
    """'' for a first attempt, then b, c, ... z, ba, bb: bijective base 26, so
    every attempt has its own mark and 2 is b, the second."""
    mark, n = '', int(attempt)
    if n <= 1: return ''
    while n:
        n, digit = divmod(n - 1, 26)
        mark = chr(ord('a') + digit) + mark
    return mark


def run_project(root):
    """The project a run is for: FM_PROJECT, then config.yaml's default_project.
    That is the order the registry's resolve takes without an explicit name,
    but nothing here checks the name is registered or refuses when none is."""
    return os.environ.get('FM_PROJECT') or default_project(root)


def default_project(root):
    """config.yaml's default_project: the project an event naming none is
    about. None when it names none, which is the board's one default."""
    config = Path(root) / 'config.yaml'
    if not config.is_file(): return None
    for raw in config.read_text().splitlines():
        found = re.match(r'default_project:(?:\s+(.*))?$', raw)
        if found:
            try: return _project_scalar(found.group(1) or '', 'config.yaml default_project') or None
            except ValueError: return None
    return None


def review_round(root, task, project):
    """The task's review round for a run starting now: FM_ROUND when the caller
    knows it (fm-review.sh --round), else one past the review rounds the log
    has opened on this task of this project. Only this project's: the round
    loop's own count takes every project's, so the two can differ when two
    projects share a task id. A worker's first run is round 1, and the review
    that follows it is too."""
    given = os.environ.get('FM_ROUND', '')
    if re.fullmatch(r'[1-9][0-9]{0,5}', given): return int(given)
    opened, default = 0, default_project(root)
    log = Path(root) / 'state/events.jsonl'
    try: lines = log.read_text().splitlines() if log.is_file() else []
    except OSError: lines = []
    for line in lines:
        try: event = json.loads(line)
        except ValueError: continue
        if not isinstance(event, dict): continue
        if event.get('type') != 'review_opened' or event.get('task') != task: continue
        # an event naming no project is the default project's
        if (event.get('project') or default) != project: continue
        opened += 1
    return opened + 1


def run_is_live(run):
    """An unfinished run holds its name unless it is proven over: no
    orchestration result, and not (its launcher gone and every attempt ended)."""
    run = Path(run)
    if (run / 'orchestration-result.json').exists(): return False
    process = run / 'process.json'
    if process.is_file():
        try:
            if process_matches(read(process)): return True
        except (OSError, ValueError): pass
    attempts = executions(run)
    if any(item['state'] != 'terminated' for item in attempts): return True
    # fm_identity writes process.json right after allocation and transport()
    # writes the attempt; with neither yet the run is starting, not over.
    return not process.is_file() and not attempts


def choose_name(alias, role, rosters, live, last, other_role, room, served=None):
    """The crew name for one run, whole, from its own role's roster only. Every
    comparison is on the whole name and it is never cut: a name the final
    actor has no `room` for is refused. A roster that has run out fails the
    run; it never borrows the other role's names (T-104). A name any recorded
    run `served` under the other role is refused however it is asked for: on
    neither roster, back from a redraw, or moved in config.yaml. The refusals
    that never lift come before the one that does: a name that belongs to the
    other role is refused as such even while it is live, since waiting for
    that run to finish would not make it usable."""
    served = served or {}
    roster = rosters.get(ROLES.get(role), [])
    foreign = {key[:-1]: names for key, names in rosters.items() if key != ROLES.get(role)}
    if alias:
        name = re.sub('[^a-z0-9]+', '-', alias.lower()).strip('-')
        name = re.sub(r'^(worker|reviewer|firstmate)-', '', name) or 'crew'
        for other, names in foreign.items():
            if name in names:
                raise RuntimeError('crew name ' + name + ' is on the ' + other + ' roster and a name belongs to'
                                   ' one role; choose another --name or omit it')
        if crossed(name, role, served):
            raise RuntimeError('crew name ' + name + ' has served as a ' + crossed(name, role, served)
                               + ' and a name belongs to one role; choose another --name or omit it')
        if name in other_role:
            raise RuntimeError('crew name ' + name + " is this task's other role; choose another --name or omit it")
        if name in live:
            raise RuntimeError('crew name ' + name + ' is live in another run; choose another --name or omit it')
    elif not roster:
        raise RuntimeError(role + ' has no roster; give it a --name')
    else:
        # A task's worker and reviewer are never the same crew member.
        free = [n for n in roster if n not in other_role and n not in live
                and not crossed(n, role, served)]
        if last in free: name = last  # the same crew member across a task's rounds
        elif free: name = free[0]
        else:
            held = [n for n in roster if n in other_role and n not in live]
            gone = [n for n in roster if n not in other_role and n not in live
                    and crossed(n, role, served)]
            also = f', {", ".join(held)} held by this task\'s other role' if held else ''
            also += f', {", ".join(gone)} already served the other role' if gone else ''
            raise RuntimeError(f'the {role} roster ran out: none of its {len(roster)} names is free'
                               f' ({len(roster) - len(held) - len(gone)} live{also}), and a name of the other'
                               f' role is never borrowed; wait for a {role} run to finish, or pin more'
                               f' names under rosters: in config.yaml')
    if len(name) > room:
        raise RuntimeError('crew name ' + name + ' does not fit a ' + str(room)
                           + '-character room in this actor; choose a shorter --name or roster')
    return name


def allocate(root, role, task, alias):
    if role not in ('worker', 'reviewer', 'firstmate'):
        raise ValueError('unsupported role')
    if not re.fullmatch(r'[A-Za-z0-9_-]+', task):
        raise ValueError('invalid task identity')
    root = Path(root).resolve()
    directory = root / 'state/runs'
    rosters = crew_rosters(root)
    project = run_project(root)
    with locked(directory / '.identity.lock'):
        # The actor carries the task's review round, not a global counter
        # (T-116): r465 read as round 465 on a task in its first round.
        number = review_round(root, task, project)
        task_slug = re.sub('[^a-z0-9]', '', task.lower())
        # Long task IDs keep a digest so truncation cannot hide their mapping.
        if len(task_slug) > 9:
            task_slug = task_slug[:4] + hashlib.sha256(task.encode()).hexdigest()[:5]
        live, previous, other_role = set(), [], set()
        attempt = 1
        served = served_roles(root)
        for file in directory.glob('*/identity.json'):
            try: identity = read(file)
            except (OSError, ValueError): continue
            name = crew_name(identity)
            if not name: continue
            if identity.get('task') == task:
                if identity.get('role') == role: previous.append((identity.get('created', 0), name))
                else: other_role.add(name)
                # a retry of this role, task and round is the next attempt;
                # a run from before T-116 records no round and is none of them
                if (identity.get('role') == role and identity.get('round') == number
                        and identity.get('project') == project
                        and isinstance(identity.get('attempt'), int)):
                    attempt = max(attempt, identity['attempt'] + 1)
            if run_is_live(file.parent): live.add(name)
        last = max(previous)[1] if previous else None
        while True:
            suffix = f'-{task_slug}-r{number}{attempt_mark(attempt)}'
            # Measured against the final suffix: an attempt mark added on
            # retry must not push the actor past 32 characters.
            room = 32 - len(role) - 1 - len(suffix)
            name = choose_name(alias, role, rosters, live, last, other_role, room, served)
            actor = role + '-' + name + suffix
            run = directory / actor
            # a directory already there - a run from before T-116 whose counter
            # happened to equal this round, or a racing retry - is another
            # attempt, so every run still has its own identity
            try: run.mkdir(parents=True); break
            except FileExistsError: attempt += 1
        # one_role: written under T-104's rule, so this run binds the name to its role.
        # name, role, project, task, round and attempt are the board's fields
        # (T-116): nothing reads them back out of the actor.
        record = dict(actor=actor, role=role, task=task, name=name, project=project,
                      round=number, attempt=attempt, one_role=True,
                      requested_alias=alias, run=str(run), created=time.time())
        save(run / 'identity.json', record)
    return run


def snapshot(root):
    root = Path(root).resolve()
    base = root / 'state/snapshots'; base.mkdir(parents=True, exist_ok=True)
    dest = Path(tempfile.mkdtemp(prefix='code-', dir=base))
    def inventory(where):
        return {str(p.relative_to(where)): hashlib.sha256(p.read_bytes()).hexdigest()
                for folder in ('bin', 'skills') for p in (where / folder).rglob('*')
                if p.is_file() and '__pycache__' not in p.parts}
    before = inventory(root)
    for folder in ('bin', 'skills'):
        if (root / folder).exists():
            shutil.copytree(root / folder, dest / folder, ignore=shutil.ignore_patterns('__pycache__'))
    if before != inventory(dest) or before != inventory(root):
        raise RuntimeError('source changed during snapshot; retry before dispatch')
    save(dest / 'manifest.json', before)
    return dest


def role_context(root, role, task, actor, prompt):
    skill = (Path(root) / 'skills' / role / 'SKILL.md').read_text()
    return (f'You are explicitly dispatched {role}. Canonical crew identity: {actor}. '
            f'Task: {task}. This explicit role wins over native startup routing.\n\n'
            + skill + '\n\n' + prompt + '\n\n'
            + (f'End the final assistant answer with the standalone line {role.upper()}_COMPLETE:{task} '
               f'only when this role task is complete; otherwise {role.upper()}_BLOCKED:{task}. '
               'Process success is not PR acceptance.\n' if role != 'firstmate' else ''))


def completion(role, task, final):
    lines = final.strip().splitlines()
    markers = [line for line in lines if re.fullmatch(r'(WORKER|REVIEWER)_(COMPLETE|BLOCKED|FAILED|INCOMPLETE):\S+', line)]
    if len(markers) != 1 or not lines or lines[-1] != markers[0]: return 'unknown'
    for suffix, status in [('COMPLETE', 'completed'), ('BLOCKED', 'blocked'), ('FAILED', 'failed'), ('INCOMPLETE', 'incomplete')]:
        if markers[0] == f'{role.upper()}_{suffix}:{task}': return status
    return 'unknown'


def shell_only(info, pane, shell=None):
    pid = info.get('shell_pid')
    foreground = info.get('foreground_processes')
    return (info.get('pane_id') == pane and isinstance(pid, int) and pid > 0
            and (shell is None or pid == shell) and bool(foreground)
            and all(p.get('pid') == pid for p in foreground))


def focus(snapshot):
    keys = ('focused_workspace_id', 'focused_tab_id', 'focused_pane_id')
    result = {key: snapshot[key] for key in keys}
    if not all(isinstance(value, str) and value for value in result.values()):
        raise RuntimeError('unknown caller focus')
    return result


def owned_tab(owner, control):
    """One unchanged root pane in the created tab; unknown topology refuses use."""
    snapshot = control('api', 'snapshot')['snapshot']
    tab_id = owner['tab_id']; pane_id = owner['pane_id']
    if (not tab_id or not owner['caller_tab'] or tab_id == owner['caller_tab']
            or pane_id == owner['caller']):
        return False
    tabs = [t for t in snapshot['tabs'] if t['tab_id'] == tab_id]
    panes = [p for p in snapshot['panes'] if p['tab_id'] == tab_id]
    layouts = [v for v in snapshot['layouts'] if v['tab_id'] == tab_id]
    return (len(tabs) == len(panes) == len(layouts) == 1
            and tabs[0]['workspace_id'] == owner['workspace_id']
            and tabs[0]['label'] == owner['actor'] and tabs[0]['pane_count'] == 1
            and panes[0]['pane_id'] == pane_id
            and panes[0]['workspace_id'] == owner['workspace_id']
            and panes[0]['terminal_id'] == owner['terminal_id']
            and layouts[0]['workspace_id'] == owner['workspace_id']
            and [p['pane_id'] for p in layouts[0]['panes']] == [pane_id]
            and layouts[0]['splits'] == [])


def close_owned(run, owner, control):
    """Immediately recheck observations, then close. Not a conditional server API."""
    run = Path(run)
    try:
        result = read(run / 'result.json')
        if result.get('exit_code') != 0 or result.get('status') != 'completed': return 'retained: incomplete result'
        if any(not (run / name).is_file() or not (run / name).stat().st_size
               for name in ('final.txt', 'cli.log')): return 'retained: missing evidence'
        if (run / 'owner.json').is_symlink() or read(run / 'owner.json') != owner: return 'retained: ownership changed'
        pane = owner['pane_id']
        if (owner.get('owned') is not True or not owner.get('caller') or pane == owner['caller']
                or owner.get('run') != str(run) or owner.get('actor') != result.get('actor')
                or owner.get('task') != result.get('task')): return 'retained: not owned'
        status = control('pane', 'get', pane)['pane']
        tokens = status.get('tokens', {})
        # agent_status is not consulted: real Herdr keeps reporting 'working'
        # after the agent exits and the pane is back at an idle prompt, so it
        # retained every completed run. Idleness is shell_only() below.
        if (status.get('pane_id') != pane or status.get('terminal_id') != owner['terminal_id']
                or status.get('tab_id') != owner['tab_id']
                or status.get('workspace_id') != owner['workspace_id']
                or status.get('label') != owner['actor']
                or tokens.get('fm_actor') != owner['actor'] or tokens.get('fm_task') != owner['task']
                or tokens.get('fm_run') != (owner.get('run_token') or Path(owner['run']).name)):
            return 'retained: pane identity or state changed'
        info = control('pane', 'process-info', '--pane', pane)['process_info']
        if not shell_only(info, pane, owner['shell_pid']): return 'retained: busy or shell changed'
        if not owned_tab(owner, control): return 'retained: tab ownership or layout changed'
        control('pane', 'close', pane)
        return 'closed'
    except (OSError, ValueError, KeyError, TypeError, AttributeError, RuntimeError, subprocess.SubprocessError) as error:
        return 'retained: uncertain observation: ' + str(error)


class Herdr:
    def __init__(self, run):
        self.run = Path(run)
        self.binary = shutil.which('herdr')
        if not self.binary:
            raise RuntimeError('HERDR_ENV=1 but herdr is unavailable; stop and report — do not set FM_TRANSPORT=direct')

    def __call__(self, *args):
        result = subprocess.run([self.binary, *args], capture_output=True, timeout=15)
        with (self.run / 'herdr.log').open('ab') as out:
            out.write((shlex.join(args) + '\n').encode() + result.stdout + result.stderr)
            out.flush(); os.fsync(out.fileno())
        if result.returncode: raise RuntimeError('Herdr command failed: ' + shlex.join(args))
        # Mutators such as report-metadata / report-agent succeed with empty stdout.
        if not result.stdout.strip():
            return {}
        return json.loads(result.stdout)['result']


def managed():
    """True when adapters must use owned Herdr panes.

    Inside HERDR_ENV=1, FM_TRANSPORT=direct is refused (protocol violation)
    unless FM_ALLOW_DIRECT=1 for isolated tests. Outside Herdr, adapters run
    in-process without inventing session wrappers.
    """
    if os.environ.get('HERDR_ENV') != '1':
        return False
    if os.environ.get('FM_TRANSPORT', 'herdr') == 'direct':
        if os.environ.get('FM_ALLOW_DIRECT') == '1':
            return False
        raise RuntimeError(
            'FM_TRANSPORT=direct is refused when HERDR_ENV=1; '
            'use stock fm-worker.sh / fm-review.sh managed Herdr transport')
    return True


def transport(adapter, prompt, tree, log):
    """A whole adapter executes in the pane, preserving normal verdict/fallback."""
    # Caller-side wait must survive the launching shell exiting (SIGHUP). The
    # pane-child also ignores SIGHUP and publishes last-result / close itself.
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    root = Path(os.environ.get('FM_ROOT', Path(adapter).resolve().parents[2])).resolve()
    code = Path(os.environ['FM_CODE_ROOT']) if os.environ.get('FM_CODE_ROOT') else snapshot(root)
    adapter = str(code / 'bin/adapters' / Path(adapter).name)
    role = os.environ.get('FM_ROLE', 'worker'); task = os.environ.get('FM_TASK', 'T-adapter')
    logical = Path(os.environ['FM_RUN_DIR']) if os.environ.get('FM_RUN_DIR') else allocate(root, role, task, '')
    # Vendor fallback keeps the logical actor and verified tab/pane; artifacts differ.
    attempt = Path(tempfile.mkdtemp(prefix=Path(adapter).stem + '-', dir=logical))
    actor = logical.name
    (attempt / 'prompt.md').write_text(role_context(code, role, task, actor, Path(prompt).read_text()))
    env = dict(os.environ, FM_ROLE=role, FM_TASK=task,
               FM_ACTOR=actor, FM_FINAL_PATH=str(attempt / 'final.txt'),
               FM_ATTEMPT_DIR=str(attempt), FM_CONTEXT_READY='1')
    # A spawned pane does not necessarily inherit the launcher's environment.
    # Keep its explicit environment private and do not print credentials.
    save(attempt / 'environment.json', env); (attempt / 'environment.json').chmod(0o600)
    payload = dict(adapter=str(Path(adapter).resolve()), prompt=str(attempt / 'prompt.md'),
                   tree=str(Path(tree).resolve()), actor=actor, role=role, task=task,
                   lifetime_tracking=True)
    save(attempt / 'invocation.json', payload)
    if not managed():
        reserve_execution(attempt)
        rc = pane_child(attempt)
        with Path(log).open('ab') as out: out.write((attempt / 'cli.log').read_bytes())
        save(logical / 'last-result.json', dict(read(attempt / 'result.json'), attempt=str(attempt)))
        return rc
    control = Herdr(attempt)
    timeout = float(os.environ.get('FM_HERDR_TIMEOUT', '21600'))
    if not math.isfinite(timeout) or timeout <= 0:
        raise ValueError('FM_HERDR_TIMEOUT must be positive finite seconds')
    caller = os.environ.get('HERDR_PANE_ID')
    if not caller: raise RuntimeError('managed transport requires a known caller HERDR_PANE_ID')
    # Read caller membership and UI focus separately: dispatch may itself be unfocused.
    current = control('pane', 'get', caller)['pane']
    if (current.get('pane_id') != caller or not current.get('tab_id')
            or not current.get('workspace_id')): raise RuntimeError('cannot verify caller pane')
    focus_before = focus(control('api', 'snapshot')['snapshot'])
    previous = logical / 'pane.json'
    if previous.exists():
        old = read(previous); pane = old['pane_id']
        observed = control('pane', 'get', pane)['pane']
        live = control('pane', 'process-info', '--pane', pane)['process_info']
        if (previous.is_symlink() or (Path(old['run']) / 'owner.json').is_symlink()
                or old.get('owned') is not True or old['caller'] != caller
                or old.get('caller_tab') != current['tab_id'] or old.get('actor') != actor
                or old.get('task') != task
                or read(Path(old['run']) / 'owner.json') != old
                or not owned_tab(old, control) or observed.get('terminal_id') != old['terminal_id']
                or observed.get('label') != actor or observed.get('tokens', {}).get('fm_run') != (
                    old.get('run_token') or Path(old['run']).name)
                or observed.get('tokens', {}).get('fm_task') != task
                or observed.get('tokens', {}).get('fm_actor') != actor
                or not shell_only(live, pane, old['shell_pid'])):
            raise RuntimeError('fallback pane ownership uncertain; retained')
    else:
        created = control('tab', 'create', '--workspace', current['workspace_id'],
                          '--cwd', str(Path(tree).resolve()), '--label', actor, '--no-focus')
        save(attempt / 'creation.json', created)
        pane = created['root_pane']['pane_id']
    if pane == caller: raise RuntimeError('creation returned caller; refusing to use it')
    expected_terminal = old['terminal_id'] if previous.exists() else created['root_pane'].get('terminal_id')
    expected_shell = old['shell_pid'] if previous.exists() else None
    if expected_shell is None:
        # New tabs briefly run path_helper / brew shellenv in the foreground.
        shell_deadline = time.monotonic() + float(os.environ.get('FM_HERDR_SHELL_WAIT', '60'))
        while True:
            status = control('pane', 'get', pane)['pane']
            info = control('pane', 'process-info', '--pane', pane)['process_info']
            if (status.get('terminal_id') == expected_terminal
                    and shell_only(info, pane, expected_shell)):
                break
            if time.monotonic() >= shell_deadline:
                raise RuntimeError('pane identity changed before ownership; retained')
            time.sleep(0.2)
    else:
        # Reused ownership must match the recorded shell immediately.
        status = control('pane', 'get', pane)['pane']
        info = control('pane', 'process-info', '--pane', pane)['process_info']
        if (status.get('terminal_id') != expected_terminal
                or not shell_only(info, pane, expected_shell)):
            raise RuntimeError('pane identity changed before ownership; retained')
    if status.get('pane_id') != pane or not status.get('terminal_id') or not shell_only(info, pane):
        raise RuntimeError('new pane is not an observed shell; retained')
    owner = dict(owned=True, actor=actor, task=task, run=str(attempt), pane_id=pane,
                 caller=caller, caller_tab=current['tab_id'], workspace_id=current['workspace_id'],
                 tab_id=old['tab_id'] if previous.exists() else created['tab']['tab_id'],
                 terminal_id=status['terminal_id'], shell_pid=info['shell_pid'],
                 focus_before=focus_before, focus_after=focus(control('api', 'snapshot')['snapshot']))
    save(attempt / 'owner.json', owner)
    if owner['focus_before'] != owner['focus_after']:
        raise RuntimeError('caller focus changed during tab creation; retained without launch')
    if not owned_tab(owner, control):
        raise RuntimeError('new tab ownership or layout uncertain; retained')
    save(previous, owner)
    # Override inherited caller context for the process executing in the owned pane.
    env.update(HERDR_PANE_ID=pane, HERDR_TAB_ID=owner['tab_id'],
               HERDR_WORKSPACE_ID=owner['workspace_id'])
    save(attempt / 'environment.json', env); (attempt / 'environment.json').chmod(0o600)
    # Herdr truncates long token values; the attempt directory name stays unique
    # and short enough to round-trip through pane metadata.
    run_token = attempt.name
    owner['run_token'] = run_token
    save(attempt / 'owner.json', owner)
    save(previous, owner)
    control('pane', 'rename', pane, actor)
    control('pane', 'report-metadata', pane, '--source', 'firstmate',
            '--token', 'fm_actor=' + actor, '--token', 'fm_task=' + task, '--token', 'fm_run=' + run_token)
    control('pane', 'report-agent', pane, '--source', 'firstmate', '--agent', actor,
            '--state', 'working', '--agent-session-id', actor, '--message', task)
    control('agent', 'rename', pane, actor)
    # Metadata reporting can briefly busy the login shell; wait before launch.
    shell_deadline = time.monotonic() + float(os.environ.get('FM_HERDR_SHELL_WAIT', '60'))
    while True:
        live = control('pane', 'process-info', '--pane', pane)['process_info']
        observed = control('pane', 'get', pane)['pane']
        if (shell_only(live, pane, owner['shell_pid'])
                and observed.get('terminal_id') == owner['terminal_id']
                and observed.get('pane_id') == pane and observed.get('tab_id') == owner['tab_id']
                and observed.get('workspace_id') == owner['workspace_id']
                and observed.get('label') == actor
                and all(observed.get('tokens', {}).get(key) == value for key, value in
                        [('fm_run', run_token), ('fm_task', task), ('fm_actor', actor)])
                and owned_tab(owner, control)):
            break
        if time.monotonic() >= shell_deadline:
            raise RuntimeError('pane changed before launch; retained')
        time.sleep(0.2)
    command = shlex.join([sys.executable, str(Path(__file__).resolve()), 'pane-child', str(attempt)])
    # Persist before sending input: a lost reply may still have launched work.
    reserve_execution(attempt)
    control('pane', 'run', pane, command)
    deadline = time.monotonic() + timeout
    while not (attempt / 'result.json').exists():
        if time.monotonic() >= deadline:
            save(attempt / 'transport.json', dict(status='timed-out', actor=actor, pane=pane))
            raise RuntimeError('pane run timed out; process and artifacts retained at ' + str(attempt))
        time.sleep(.1)
    result = read(attempt / 'result.json')
    with Path(log).open('ab') as out:
        out.write((attempt / 'cli.log').read_bytes()); out.flush(); os.fsync(out.fileno())
    save(logical / 'last-result.json', dict(result, attempt=str(attempt)))
    close = 'retained: auto-close disabled'
    if os.environ.get('FM_AUTOCLOSE', '1') != '0':
        prior = attempt / 'close.json'
        if prior.exists() and read(prior).get('status') == 'closed':
            close = 'closed'
        else:
            try:
                # Let the runner leave the foreground; never report idle on a busy pane.
                for _ in range(20):
                    info = control('pane', 'process-info', '--pane', pane)['process_info']
                    if shell_only(info, pane, owner['shell_pid']): break
                    time.sleep(.1)
                close = close_owned(attempt, owner, control)
            except (OSError, ValueError, KeyError, TypeError, AttributeError, RuntimeError, subprocess.SubprocessError) as error:
                close = 'retained: cleanup observation failed: ' + str(error)
    recorded = record_close(attempt, dict(actor=actor, pane=pane, status=close, source='transport'))
    close = recorded.get('status', close)
    print(f'{actor}: {close}; artifacts {attempt}', file=sys.stderr)
    return result['exit_code']


def execution_state(attempt):
    """A reservation survives launch uncertainty; an inherited lock covers descendants."""
    attempt = Path(attempt)
    receipt = attempt / 'execution.json'
    if not receipt.exists():
        invocation = attempt / 'invocation.json'
        if not invocation.exists() or read(invocation).get('lifetime_tracking'): return None
        # Older frozen launchers cannot publish lifetime locks. An unfinished
        # legacy invocation is uncertainty, never permission to destroy its tree.
        state = 'terminated' if (attempt / 'result.json').exists() else 'uncertain'
        return dict(state=state, live=False, attempt=str(attempt), legacy=True)
    record = read(receipt)
    try:
        with locked(attempt / 'execution.lock', blocking=False):
            state = 'terminated' if record.get('started') else 'uncertain'
    except BlockingIOError:
        state = 'live'
    return dict(record, state=state, live=state == 'live', attempt=str(attempt))


def executions(run):
    attempts = {path.parent for name in ('execution.json', 'invocation.json')
                for path in Path(run).glob('*/' + name)}
    return [state for attempt in sorted(attempts)
            if (state := execution_state(attempt)) is not None]


def reserve_execution(attempt):
    save(Path(attempt) / 'execution.json', dict(started=False, reserved=time.time()))


def pane_child(attempt):
    attempt = Path(attempt)
    # Pane-child must survive a dead transport waiter (SIGHUP from the launching
    # shell). Ignore hangup here so durable handoff still runs to completion.
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    # This lock is independent of the launcher: a Herdr pane is not its child.
    # Pass it into the adapter and its CLI descendants, even if this runner dies.
    with locked(attempt / 'execution.lock', blocking=False) as lifetime:
        receipt = attempt / 'execution.json'
        if receipt.exists() and read(receipt).get('started'):
            raise RuntimeError('attempt already started; refusing duplicate execution')
        save(receipt, dict(started=True, runner_pid=os.getpid()))
        return execute_child(attempt, lifetime.fileno())


def publish_last_result(attempt, result):
    """Publish attempt evidence to the logical run dir even if transport never resumes."""
    attempt = Path(attempt)
    logical = attempt.parent
    if not (logical / 'identity.json').is_file():
        return None
    payload = dict(result, attempt=str(attempt))
    save(logical / 'last-result.json', payload)
    return logical


def close_from_child(attempt, owner, result, control=None, wait_pid=None):
    """Ownership-safe autoclose after this pane-child leaves the foreground.

    Evaluating shell_only while we are still the pane's foreground process can
    never succeed on a real Herdr. By default, fork a setsid closer that waits
    for our PID to exit, then rechecks ownership and closes. Pass wait_pid=0 to
    close inline (unit tests with an injected control). The transport waiter may
    race; record_close keeps the first durable closed receipt.
    """
    if os.environ.get('FM_AUTOCLOSE', '1') == '0':
        return 'retained: auto-close disabled'
    if result.get('exit_code') != 0 or result.get('status') != 'completed':
        return 'retained: incomplete result'

    def _close_now(ctrl):
        for _ in range(40):
            info = ctrl('pane', 'process-info', '--pane', owner['pane_id'])['process_info']
            if shell_only(info, owner['pane_id'], owner['shell_pid']):
                break
            time.sleep(0.1)
        return close_owned(attempt, owner, ctrl)

    if wait_pid == 0:
        try:
            if control is None:
                control = Herdr(attempt)
            close = _close_now(control)
        except (OSError, ValueError, KeyError, TypeError, AttributeError, RuntimeError, subprocess.SubprocessError) as error:
            close = 'retained: cleanup observation failed: ' + str(error)
        record_close(attempt, dict(actor=owner.get('actor'), pane=owner.get('pane_id'),
                                   status=close, source='pane-child'))
        return close

    parent = os.getpid() if wait_pid is None else wait_pid
    try:
        child = os.fork()
    except OSError as error:
        return 'retained: cleanup observation failed: ' + str(error)
    if child != 0:
        return 'scheduled'
    try:
        try:
            os.setsid()
        except OSError:
            pass
        deadline = time.monotonic() + float(os.environ.get('FM_HERDR_SHELL_WAIT', '60'))
        while time.monotonic() < deadline:
            try:
                os.kill(parent, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        else:
            record_close(attempt, dict(actor=owner.get('actor'), pane=owner.get('pane_id'),
                                       status='retained: closer timed out waiting for child exit',
                                       source='pane-child'))
            os._exit(0)
        if control is None:
            control = Herdr(attempt)
        close = _close_now(control)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, RuntimeError, subprocess.SubprocessError) as error:
        close = 'retained: cleanup observation failed: ' + str(error)
    record_close(attempt, dict(actor=owner.get('actor'), pane=owner.get('pane_id'),
                               status=close, source='pane-child'))
    os._exit(0)


def cli_final(vendor, log):
    """A vendor's answer, only from a complete CLI result object.

    Only such an object establishes final-answer provenance; mixed or partial
    output stays in cli.log and authorizes nothing. But these CLIs print
    transport notices ('Connection lost, reconnecting...', 'Retry attempt 1...')
    onto the same stream as the object, so the file as a whole stops parsing
    while the object inside it is whole and says success. Reading only the file
    filed a finished worker as uncertain, which by design retains its pane - a
    reconnect on the way to a complete answer left the tab open for good.

    The last object in the transcript is the one that counts: a retry appends,
    and an earlier success must not speak for a later failure. A truncated
    object parses as nothing, so partial output is still worth nothing.
    """
    if vendor not in ('claude', 'cursor-agent', 'gemini'): return None
    try: text = Path(log).read_text()
    except OSError: return None
    for candidate in (text, *reversed(text.splitlines())):
        try: response = json.loads(candidate)
        except ValueError: continue
        if not isinstance(response, dict): continue
        value = response.get('response') if vendor == 'gemini' else response.get('result')
        valid = vendor == 'gemini' or response.get('type') == 'result'
        if valid and not response.get('is_error') and not response.get('error') and isinstance(value, str):
            return value
        return None
    return None


def execute_child(attempt, lifetime_fd):
    attempt = Path(attempt); invocation = read(attempt / 'invocation.json')
    env = read(attempt / 'environment.json')
    rc = 1
    actor = invocation.get('actor', 'crew')
    role = invocation.get('role', 'worker')
    task = invocation.get('task', '')
    heartbeat = float(os.environ.get('FM_HEARTBEAT_SECS', '15'))
    if not math.isfinite(heartbeat) or heartbeat < 0:
        raise ValueError('FM_HEARTBEAT_SECS must be non-negative finite seconds')
    with (attempt / 'cli.log').open('ab') as log:
        # stdout remains on the real terminal; adapters tee their CLI transcript.
        # Vendors using -p/--output-format json often buffer until the end, so
        # captains watching the Herdr pane also get periodic heartbeats here.
        try:
            child = subprocess.Popen([invocation['adapter'], 'run', invocation['prompt'],
                                      invocation['tree'], str(attempt / 'cli.log')], env=env,
                                     stdin=subprocess.DEVNULL, pass_fds=(lifetime_fd,))
            save(attempt / 'execution.json', dict(started=True, runner_pid=os.getpid(),
                 pid=child.pid, token=invocation['adapter']))
            print(f'[fm] {actor} {role} started on {task} (pid {child.pid})', flush=True)
            started = time.monotonic()
            while True:
                try:
                    rc = child.wait(timeout=None if heartbeat == 0 else heartbeat)
                    break
                except subprocess.TimeoutExpired:
                    elapsed = int(time.monotonic() - started)
                    print(f'[fm] {actor} still running ({elapsed}s); '
                          f'vendor may buffer until complete', flush=True)
            print(f'[fm] {actor} finished exit={rc} after '
                  f'{int(time.monotonic() - started)}s', flush=True)
        finally:
            log.flush(); os.fsync(log.fileno())
    final = attempt / 'final.txt'
    answer = cli_final(Path(invocation['adapter']).stem, attempt / 'cli.log')
    if answer is not None:
        final.write_text(answer)
    status = completion(invocation['role'], invocation['task'], final.read_text()) if final.exists() else 'unknown'
    if final.exists():
        with final.open('rb') as source: os.fsync(source.fileno())
    result = dict(actor=invocation['actor'], task=invocation['task'], role=invocation['role'],
                  exit_code=rc, status=status, pid=os.getpid(),
                  chain_attempt=env.get('FM_CHAIN_ATTEMPT', ''))
    raw = attempt / 'cli-exit-code'
    result['cli_exit_code'] = int(raw.read_text()) if raw.exists() else None
    # Retain evidence before lifecycle reporting or any close operation.
    save(attempt / 'result.json', result)
    publish_last_result(attempt, result)
    if not (attempt / 'owner.json').exists(): return rc
    owner = read(attempt / 'owner.json')
    try:
        Herdr(attempt)('pane', 'report-agent', owner['pane_id'], '--source', 'firstmate',
                       '--agent', invocation['actor'], '--state', 'idle' if status == 'completed' else 'blocked',
                       '--agent-session-id', invocation['actor'], '--message', invocation['task'] + ': ' + status)
    except (RuntimeError, ValueError, subprocess.SubprocessError): pass
    # When the caller-side transport dies, this child still owns close — but
    # only after we leave the foreground (see close_from_child).
    close = close_from_child(attempt, owner, result)
    if close != 'scheduled':
        record_close(attempt, dict(actor=actor, pane=owner.get('pane_id'),
                                   status=close, source='pane-child'))
    print(f'{actor}: {close}; artifacts {attempt}', file=sys.stderr)
    return rc


def process_matches(record):
    try:
        pid = int(record['pid'])
        result = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True)
        return result.returncode == 0 and record['token'] in result.stdout
    except (KeyError, ValueError, OSError): return False


def crew_last_events(root):
    """Last event per actor — the same fold the captain board uses for who is aboard."""
    log = Path(root) / 'state/events.jsonl'
    last = {}
    if not log.is_file():
        return last
    for line in log.read_text().splitlines():
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        actor = event.get('actor')
        if not actor or actor in ('github', 'captain'):
            continue
        last[actor] = event
    return last


def actor_is_live(root, actor):
    """Corroborate an aboard actor against run receipts, not task-level pid files."""
    run = Path(root) / 'state/runs' / actor
    if not run.is_dir():
        return False
    process = run / 'process.json'
    identity = run / 'identity.json'
    if process.is_file():
        record = read(process)
    elif identity.is_file():
        record = read(identity)
    else:
        return False
    if process_matches(record):
        return True
    return any(item.get('live') for item in executions(run))


def retire_dead_crew(root):
    """Close the log for aboard actors whose processes are gone.

    The board paints crew from events only: an actor stays aboard until that
    actor emits agent_finished. Task-level reconcile cannot clear actor ghosts.
    This keeps event-sourcing and makes the log match process reality.
    """
    root = Path(root).resolve()
    emit = root / 'bin/fm-emit.sh'
    retired, kept = [], []
    if not emit.is_file():
        return dict(retired=retired, kept=kept)
    for actor, event in crew_last_events(root).items():
        if actor == 'firstmate' or event.get('type') == 'agent_finished':
            continue
        if actor_is_live(root, actor):
            kept.append(actor)
            continue
        role = (event.get('data') or {}).get('role') if isinstance(event.get('data'), dict) else None
        if role not in ('worker', 'reviewer'):
            role = 'reviewer' if str(actor).startswith('reviewer') else 'worker'
        task = event.get('task') or ''
        if not task:
            continue
        data = json.dumps({'role': role, 'status': 'process_gone'})
        cmd = ['bash', str(emit), '--actor', str(actor), '--type', 'agent_finished',
               '--task', str(task), '--data', data,
               '--en', f'deck reconcile: {actor} has no live process',
               '--tw', f'甲板對帳：{actor} 無活進程']
        if isinstance(event.get('pr'), int):
            cmd.extend(['--pr', str(event['pr'])])
        env = dict(os.environ, FM_ROOT=str(root))
        result = subprocess.run(cmd, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError('deck reconcile emit failed for ' + actor + ': ' + (result.stderr or result.stdout))
        retired.append(actor)
    return dict(retired=retired, kept=kept)


def watch_start(root, decision='all'):
    root = Path(root).resolve()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', decision): raise ValueError('invalid decision ID')
    base = root / 'state/session'; base.mkdir(parents=True, exist_ok=True)
    registry = base / ('watch-' + decision + '.json')
    with locked(base / '.watch.lock'):
        if registry.exists() and process_matches(read(registry)): return read(registry)
        directory = Path(tempfile.mkdtemp(prefix='watch-', dir=base))
        code = snapshot(root)
        token = str(directory)
        with (directory / 'log').open('ab') as log:
            child = subprocess.Popen([sys.executable, str(code / 'bin/fm-herdr.py'), 'watch-child',
                                      str(root), decision, token], stdin=subprocess.DEVNULL,
                                     stdout=log, stderr=log, start_new_session=True)
        _children.append(child)
        record = dict(pid=child.pid, token=token, directory=token, root=str(root), decision=decision)
        save(registry, record)
        return record


def watch_stop(root, decision='all'):
    if not re.fullmatch(r'[A-Za-z0-9_-]+', decision): raise ValueError('invalid decision ID')
    registry = Path(root) / 'state/session' / ('watch-' + decision + '.json')
    if not registry.exists(): return
    with locked(registry.parent / '.watch.lock'):
        record = read(registry)
        if process_matches(record):
            os.killpg(record['pid'], signal.SIGTERM)
            for _ in range(50):
                if not process_matches(record): break
                time.sleep(.02)
        result = Path(record['directory']) / 'result.json'
        if not result.exists(): save(result, dict(status='stopped'))
        for child in _children:
            if child.pid == record['pid']:
                try: child.wait(timeout=2)
                except subprocess.TimeoutExpired: pass


def watch_child(root, decision, directory):
    root = Path(root); directory = Path(directory)
    result = directory / 'result.json'
    def stop(_signum, _frame):
        save(result, dict(status='stopped')); raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop)
    save(directory / 'status.json', dict(status='live', pid=os.getpid(), decision=decision))
    observed = root / 'state/session/observed' if decision == 'all' else directory / 'observed'
    observed.mkdir(parents=True, exist_ok=True)
    # Observation reads decision files directly. Invoking fm-decide --await
    # would reject non-numeric ids, remove pending cards, and (on older
    # decide builds) re-emit decision_made — none of which belong on a watch.
    try:
        while True:
            ids = [decision] if decision != 'all' else sorted({p.stem for name in ('pending', 'decisions')
                    for p in (root / 'state' / name).glob('*.json')})
            for ident in ids:
                if (observed / (ident + '.json')).exists(): continue
                answer_path = root / 'state/decisions' / (ident + '.json')
                if not answer_path.exists(): continue
                answer = json.loads(answer_path.read_text())
                receipt = dict(status='observed', decision=answer, id=ident, observed=time.time())
                save(observed / (ident + '.json'), receipt)
                if decision != 'all': save(result, receipt); return 0
            time.sleep(.2)
    except Exception as error:
        save(result, dict(status='failed', error=str(error))); return 1


def unacknowledged(root):
    """Observed captain decisions firstmate has not acknowledged; reads, never consumes."""
    base = Path(root) / 'state/session'
    found = []
    for path in sorted((base / 'observed').glob('*.json')):
        if (base / 'acknowledged' / path.name).exists(): continue
        receipt = read(path); answer = receipt.get('decision') or {}
        found.append(dict(id=receipt.get('id', path.stem), task=answer.get('task'), kind=answer.get('kind'),
                          chosen=answer.get('chosen'), text=answer.get('text'), ts=answer.get('ts'),
                          observed=receipt.get('observed')))
    return found


def pending_summary(items):
    if not items: return 'fm-session: no unacknowledged captain decisions'
    lines = [f'fm-session: {len(items)} captain decision{"" if len(items) == 1 else "s"} '
             'observed but not acknowledged; act on each, then run fm-session.sh ack --decision <id>']
    for item in items:
        chosen = item['chosen'] if item['text'] is None else f'{item["chosen"]} "{item["text"]}"'
        lines.append(f'  {item["id"]} {item["task"]} {item["kind"]} chose {chosen} at {item["ts"]}')
    return '\n'.join(lines)


def acknowledge(root, decision):
    """Durably record that firstmate acted on an observation; idempotent, deletes nothing."""
    if decision == 'all' or not re.fullmatch(r'[A-Za-z0-9_-]+', decision):
        raise ValueError('ack requires --decision <id>')
    base = Path(root) / 'state/session'
    observation = base / 'observed' / (decision + '.json')
    if not observation.exists():
        raise LookupError(f'no observation for {decision}; nothing to acknowledge')
    receipt = base / 'acknowledged' / (decision + '.json')
    with locked(base / '.ack.lock'):
        if receipt.exists(): return read(receipt)
        record = dict(id=decision, acknowledged=time.time(),
                      observation=hashlib.sha256(observation.read_bytes()).hexdigest())
        save(receipt, record)
        return record


def http_get(url):
    try:
        with urllib.request.urlopen(url, timeout=2) as response: return response.read()
    except urllib.error.HTTPError as error:
        error.close()
        raise


def board_matches(root, url):
    root = Path(root)
    directory = root / 'state/session'; directory.mkdir(parents=True, exist_ok=True)
    relative = Path('state/session') / ('probe-' + uuid.uuid4().hex)
    nonce = uuid.uuid4().hex.encode(); (root / relative).write_bytes(nonce)
    try:
        return http_get(url + '/file?path=' + urllib.parse.quote(str(relative))) == nonce
    except (OSError, ValueError): return False
    finally: (root / relative).unlink()


def board_secret_file(port):
    """The board's secret (T-122), where board/server.ts keeps it: outside the
    repository, under the operator's config directory, mode 0600."""
    base = os.environ.get('XDG_CONFIG_HOME', '')
    base = Path(base) if base.startswith('/') else Path.home() / '.config'
    return base / 'firstmate' / f'board-{port}.secret'


def board_secret(port):
    """Read the secret through a descriptor that refuses a symlink. Never printed."""
    fd = os.open(board_secret_file(port), os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    with os.fdopen(fd) as f: secret = f.read().strip()
    if not re.fullmatch(r'[0-9a-f]{64,}', secret): raise RuntimeError('the board secret holds no secret')
    return secret


def board_login_url(url, port):
    """A one-time address for the captain's browser: /login#<code>. The code
    is the issue time, a nonce and an HMAC over them and the board's origin,
    keyed by the secret; the board takes it once, within 60 seconds."""
    issued = str(int(time.time() * 1000)); nonce = uuid.uuid4().hex
    tag = hmac.new(board_secret(port).encode(), f'login:{url}:{issued}.{nonce}'.encode(), hashlib.sha256).hexdigest()
    return f'{url}/login#{issued}.{nonce}.{tag}'


def open_address(address):
    """Hand an address to the browser. On macOS it goes to osascript on stdin,
    never in an argument list: `ps` shows every process's arguments to every
    other, and a one-time code read there could be redeemed before the
    captain's browser gets to it."""
    if sys.platform == 'darwin' and shutil.which('osascript'):
        return subprocess.run([shutil.which('osascript')], input=f'open location "{address}"\n'.encode(),
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    opener = shutil.which('xdg-open') or shutil.which('open')
    if not opener: return False
    return subprocess.call([opener, address], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0


def board_start(root):
    root = Path(root).resolve(); port = int(os.environ.get('FM_PORT', '4173'))
    url = f'http://127.0.0.1:{port}'
    base = root / 'state/session'; base.mkdir(parents=True, exist_ok=True)
    with locked(base / '.board.lock'):
        reused = board_matches(root, url)
        if not reused:
            # Any response means a different/unverifiable listener, never reuse it.
            try: http_get(url); occupied = True
            except urllib.error.HTTPError: occupied = True
            except OSError: occupied = False
            if occupied: raise RuntimeError('board port belongs to an unverified root: ' + url)
            bun = shutil.which('bun')
            if not bun: raise RuntimeError('board requires Bun')
            with (base / 'board.log').open('ab') as log:
                child = subprocess.Popen([bun, 'run', str(root / 'board/server.ts')], cwd=root,
                        env=dict(os.environ, FM_ROOT=str(root), FM_PORT=str(port)),
                        stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
            for _ in range(50):
                if child.poll() is not None: break
                if board_matches(root, url): break
                time.sleep(.1)
            if not board_matches(root, url): raise RuntimeError('board did not verify; inspect state/session/board.log')
        page = bool(http_get(url))
        # The browser is sent to a one-time sign-in address (T-122), which
        # alone lets the page write. The address is never recorded: `url`
        # below is the board's own, without a code.
        # A board with no secret file is one started before T-122, open to
        # every local caller: it is reported, and nothing is opened on it.
        opener = shutil.which('osascript') if sys.platform == 'darwin' else None
        opener = opener or shutil.which('xdg-open') or shutil.which('open')
        opened, refused = False, None
        if not opener: refused = 'no program to open a browser with was found; nothing was opened'
        else:
            try: opened = open_address(board_login_url(url, port))
            except (OSError, RuntimeError):
                # said without the path: state/ never names where the secret is
                refused = 'the board secret could not be read; restart the board'
        record = dict(root=str(root), url=url, reused=reused, page_http_verified=page,
                      opener_invoked=opened, browser_navigation_verified=False)
        if refused: record['sign_in_error'] = refused
        save(base / 'board.json', record)
        return record


def inspect(root):
    root = Path(root).resolve()
    runs = []
    for file in (root / 'state/runs').glob('*/identity.json'):
        process = file.parent / 'process.json'
        record = read(process) if process.exists() else read(file)
        active = executions(file.parent)
        launcher_live = process_matches(record)
        runs.append(dict(record, orchestration_live=launcher_live, executions=active,
                         live=launcher_live or any(item['live'] for item in active),
                         uncertain=any(item['state'] == 'uncertain' for item in active)))
    watches = []
    for file in (root / 'state/session').glob('watch-*.json'):
        record = read(file); result = Path(record['directory']) / 'result.json'
        watches.append(dict(record, live=process_matches(record), result=read(result) if result.exists() else None))
    report = dict(root=str(root), runs=runs, watches=watches,
                  pending=[p.name for p in (root / 'state/pending').glob('*.json')],
                  unacknowledged=unacknowledged(root),
                  worktrees=[p.name for p in (root / 'state/worktrees').glob('*') if p.is_dir()])
    events = root / 'state/events.jsonl'
    report['events'] = [json.loads(line) for line in events.read_text().splitlines() if line.strip()] if events.exists() else []
    config = root / 'config.yaml'
    report['configuration'] = config.read_text() if config.exists() else None
    if managed():
        base = root / 'state/session'; base.mkdir(parents=True, exist_ok=True)
        report['panes'] = Herdr(base)('pane', 'list')
    return report


def launch(script, root, args):
    root = Path(root).resolve(); script = Path(script).resolve()
    supplied = os.environ.get('FM_CODE_ROOT')
    # Freeze the tree that owns the entrypoint, not --repo. Invoking
    # $CHECKOUT/bin/fm-dispatch.sh --repo $fixture must snapshot CHECKOUT;
    # a sparse fixture bin/ must not become the frozen code source.
    source = script.parent.parent
    code = Path(supplied) if supplied and script.is_relative_to(Path(supplied)) else snapshot(source)
    # The shell has already resolved root in the caller's cwd. Replay that one
    # canonical value for every occurrence, including inherited relative FM_ROOT.
    args = list(args)
    task = None
    index = 0
    while index < len(args):
        value = args[index]
        # All validated long options in these five entrypoints take one value,
        # except --dry-run. Skip values so an alias is never read as an option.
        if value.startswith('--') and value != '--dry-run':
            if value == '--repo': args[index + 1] = str(root)
            if value == '--task': task = args[index + 1]
            index += 2
        else:
            index += 1
    env = dict(os.environ, FM_ROOT=str(root), FM_CODE_ROOT=str(code),
               FM_ENTRY_PID=str(os.getpid()), FM_ENTRY_SCRIPT=script.name)
    # A worker owns its task worktree for the entire orchestration, including
    # commits. Competing callers must not recreate a live worker's directory.
    if script.name == 'fm-worker.sh' and task is not None:
        if not re.fullmatch(r'[A-Za-z0-9_-]+', task): raise ValueError('invalid task')
        lock_path = root / 'state/runs' / ('.worker-' + task + '.lock')
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: raise RuntimeError('task already has a live worker; resume it: ' + task)
        # Inspect while holding task exclusion, before any worktree mutation.
        # Pending launches fail closed: absence of a PID is not proof of death.
        for identity_file in (root / 'state/runs').glob('*/identity.json'):
            identity = read(identity_file)
            if identity.get('role') == 'worker' and identity.get('task') == task:
                if any(item['state'] != 'terminated' for item in executions(identity_file.parent)):
                    raise RuntimeError('task already has a live worker or uncertain launch; resume it: ' + task)
        os.set_inheritable(fd, True)
        # Publish the fd so the worker can drop it in the adapter subshell.
        # The parent orchestration process keeps its copy for exclusion; a
        # surviving adapter after SIGKILL of the published PID must not keep
        # the lock or recovery relaunch blocks forever.
        env['FM_WORKER_TASK_LOCK_FD'] = str(fd)
    os.execve('/bin/bash', ['bash', str(code / 'bin' / script.name), *args], env)


IDENTITY_FIELDS = ('name', 'role', 'project', 'task', 'round', 'attempt')


def crew_identity(run):
    """A run's identity as the board reads it: the separate fields of its
    identity.json (T-116), or None for a run that recorded none of them."""
    try: record = read(Path(run) / 'identity.json')
    except (OSError, ValueError): return None
    if not isinstance(record, dict) or 'round' not in record: return None
    return {key: record.get(key) for key in IDENTITY_FIELDS}


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
    fields = crew_identity(root / 'state/runs' / actor)
    if fields: data['identity'] = fields
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


# --- the project contract --------------------------------------------------
# config.yaml's `project:` block is how a target project tells firstmate how to
# prepare a checkout and what green means. Values are opaque shell command
# strings: read and returned exactly, never evaluated here. Nothing in bin/
# may know which toolchain a project uses; it only runs what is declared.
PROJECT_KEYS = ('setup', 'check', 'check_env', 'tests', 'test', 'docs')


def _project_scalar(text, where):
    """One YAML scalar: plain, "double" or 'single' quoted. Returns the value."""
    text = text.strip()
    if text[:1] in ('|', '>'):
        raise ValueError(where + ': block scalars are not supported; write the command on one line')
    if text[:1] == '"':
        out, i = [], 1
        while i < len(text):
            if text[i] == '\\' and i + 1 < len(text):
                out.append({'n': '\n', 't': '\t'}.get(text[i + 1], text[i + 1])); i += 2; continue
            if text[i] == '"': break
            out.append(text[i]); i += 1
        else: raise ValueError(where + ': unterminated double quote')
        rest = text[i + 1:].strip()
    elif text[:1] == "'":
        out, i = [], 1
        while i < len(text):
            if text[i] == "'":
                if text[i + 1:i + 2] == "'": out.append("'"); i += 2; continue
                break
            out.append(text[i]); i += 1
        else: raise ValueError(where + ': unterminated single quote')
        rest = text[i + 1:].strip()
    else:
        # a plain scalar ends at a comment, which YAML starts with " #"
        found = re.search(r'\s#', text)
        return (text[:found.start()] if found else text).rstrip()
    if rest and not rest.startswith('#'):
        raise ValueError(where + ': unexpected text after the closing quote: ' + rest)
    return ''.join(out)


def project_contract(config):
    """The declared project block as {key: value}; absent keys are absent."""
    path = Path(config)
    if not path.is_file(): return {}
    block, inside = [], False
    for raw in path.read_text().splitlines():
        if not inside:
            inside = bool(re.match(r'project:\s*(#.*)?$', raw))
            continue
        if not raw.strip() or raw.lstrip().startswith('#'): continue
        if not raw[:1].isspace(): break
        block.append(raw.expandtabs(8))
    indent = lambda line: len(line) - len(line.lstrip(' '))
    contract, i = {}, 0
    while i < len(block):
        line = block[i]; level = indent(line)
        found = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*):(?:\s+(.*))?$', line)
        if not found: raise ValueError('config.yaml project: cannot read line: ' + line.strip())
        key, value = found.group(1), (found.group(2) or '').strip()
        if key not in PROJECT_KEYS:
            raise ValueError('config.yaml project: unknown key ' + key + ' (known: ' + ', '.join(PROJECT_KEYS) + ')')
        children = []
        i += 1
        # YAML lets a list sit at its key's own indent
        while i < len(block) and (indent(block[i]) > level or block[i].lstrip().startswith('- ')):
            children.append(block[i]); i += 1
        where = 'config.yaml project.' + key
        if key in ('setup', 'check', 'test'):
            if children or not value or value.startswith('#'):
                if children: raise ValueError(where + ' must be a one-line command')
                continue
            contract[key] = _project_scalar(value, where)
        elif key in ('tests', 'docs'):
            if value and not value.startswith('#'): raise ValueError(where + ' must be a list of globs')
            items = []
            for child in children:
                item = re.match(r'\s*-\s+(.*)$', child)
                if not item: raise ValueError(where + ' must be a list of globs')
                items.append(_project_scalar(item.group(1), where))
            if items: contract[key] = items
        else:
            if value and not value.startswith('#'): raise ValueError(where + ' must be a map of variables')
            env = {}
            for child in children:
                item = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*):(?:\s+(.*))?$', child)
                if not item: raise ValueError(where + ' must map variable names to values: ' + child.strip())
                env[item.group(1)] = _project_scalar(item.group(2) or '', where + '.' + item.group(1))
            if env: contract[key] = env
    for key in ('setup', 'check', 'test'):
        if contract.get(key) == '': del contract[key]
    if 'test' in contract and '{file}' not in contract['test']:
        raise ValueError('config.yaml project.test must contain {file}')
    return contract


def project_report(root, run_setup=False):
    """What start and status say about the project. Only start runs setup."""
    root = Path(root).resolve()
    report = dict(declared=[], setup=None, ready=False)
    try: contract = project_contract(root / 'config.yaml')
    except ValueError as error:
        report['error'] = str(error); return report
    report['declared'] = [key for key in PROJECT_KEYS if key in contract]
    if run_setup and 'setup' in contract:
        base = root / 'state/session'; base.mkdir(parents=True, exist_ok=True)
        log = base / 'project-setup.log'
        with log.open('w') as out:
            code = subprocess.call(['bash', '-c', contract['setup']], cwd=root,
                                   stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT)
        report['setup'] = dict(exit=code, log=str(log))
        if code != 0:
            tail = [line for line in log.read_text(errors='replace').splitlines() if line.strip()][-3:]
            report['setup']['error'] = ('setup failed (exit %d)' % code
                                        + (': ' + ' | '.join(tail) if tail else ''))[:300]
    if 'check' not in contract:
        report['error'] = 'config.yaml declares no project.check'
    report['ready'] = 'check' in contract and (report['setup'] is None or report['setup']['exit'] == 0)
    return report


def project_field(config, field):
    """Print one declared value for bin/fm-config.sh, exactly as declared."""
    contract = project_contract(config)
    if field == 'keys':
        for key in PROJECT_KEYS:
            if key in contract: print(key)
    elif field in ('tests', 'docs'):
        for glob in contract.get(field, []): print(glob)
    elif field == 'check_env':
        for name, value in contract.get('check_env', {}).items():
            sys.stdout.write(name + '=' + value + '\0')
    elif field in ('setup', 'check', 'test'):
        if field in contract: print(contract[field])
    else: raise ValueError('unknown project field ' + field)
    return 0


def roster_command(root, action='show', redraw=''):
    """The roster command: print both rosters; `init` draws them once; `--redraw`
    replaces them, and only when asked."""
    if action not in ('show', 'init'): raise ValueError('unknown roster action ' + action)
    if action == 'show' and not redraw:
        crew = drawn_rosters(root)
        if not crew:
            print('fm roster: no crew drawn yet; roster init draws one', file=sys.stderr)
            return 1
    else:
        crew, drawn = draw_rosters(root, redraw=bool(redraw))
        if redraw:
            print('fm roster: drew a new crew. Ranks and service records keyed by the old names'
                  ' stay with the old names; the new names start without them. A name that'
                  ' already served one role is never drawn for the other.')
        elif drawn: print('fm roster: drew this installation\'s crew')
        else:
            print('fm roster: this installation already has a crew, drawn ' + str(crew.get('drawn_at'))
                  + '; it is never redrawn unless you ask with --redraw', file=sys.stderr)
            return 1
    pinned = pinned_rosters(root)
    rosters = crew_rosters(root, warn=False)
    for key in ROLES.values():
        source = 'pinned in config.yaml' if key in pinned else 'drawn ' + str(crew.get('drawn_at'))
        print(f'{key} ({len(rosters[key])}, {source}): ' + ' '.join(rosters[key]))
    return 0


def main(args):
    mode, *args = args
    if mode == 'project':
        try: return project_field(*args)
        except ValueError as error:
            print('fm-config: ' + str(error), file=sys.stderr); return 65
    if mode == 'allocate': print(allocate(Path(args[0]), *args[1:])); return 0
    if mode == 'roster':
        try: return roster_command(*args)
        except (OSError, ValueError) as error:
            print('fm roster: ' + str(error), file=sys.stderr); return 65
    if mode == 'board':
        # a board that cannot start, or a tab that could not be signed in, is
        # said in one line and a non-zero exit, never a traceback
        try: record = board_start(args[0])
        except (OSError, RuntimeError) as error:
            print('fm board: ' + str(error), file=sys.stderr); return 70
        print(json.dumps(record, indent=2))
        if record.get('sign_in_error'):
            print('fm board: ' + record['sign_in_error'], file=sys.stderr); return 69
        return 0
    if mode == 'launch': launch(args[0], args[1], args[2:])
    if mode == 'transport': return transport(*args)
    if mode == 'pane-child': return pane_child(*args)
    if mode == 'watch-child': return watch_child(*args)
    if mode == 'context':
        root, role, task, actor, prompt, target = args
        Path(target).write_text(role_context(root, role, task, actor, Path(prompt).read_text())); return 0
    if mode == 'session':
        action, root, *rest = args; decision = rest[0] if rest else 'all'
        if action == 'status':
            reconcile = retire_dead_crew(root)
            report = inspect(root); report['deck_reconcile'] = reconcile
            report['project'] = project_report(root)
            print(json.dumps(report, indent=2))
            print(pending_summary(report['unacknowledged']), file=sys.stderr)
        elif action == 'ack':
            try: print(json.dumps(acknowledge(root, decision)))
            except LookupError as error:
                print('fm-session: ' + str(error.args[0]), file=sys.stderr); return 1
        elif action == 'watch': print(json.dumps(watch_start(root, decision)))
        elif action == 'stop': watch_stop(root, decision)
        elif action == 'start':
            # Close ghost actors before the board is shown or work is planned.
            reconcile = retire_dead_crew(root)
            report = inspect(root); report['deck_reconcile'] = reconcile
            # The installation's crew is drawn the first time firstmate runs
            # in a checkout, and never again (T-104).
            try:
                crew, drawn = draw_rosters(root)
                report['crew'] = dict(crew, drawn_now=drawn)
            except (OSError, ValueError) as error: report['crew'] = dict(error=str(error))
            # Before the board: a fresh checkout is prepared once, as the
            # project declares. A failure is reported, never fatal.
            report['project'] = project_report(root, run_setup=True)
            report['board'] = board_start(root)
            if os.environ.get('FM_WATCH', '1') != '0': report['watch'] = watch_start(root)
            print(json.dumps(report, indent=2))
            print(pending_summary(report['unacknowledged']), file=sys.stderr)
        else: raise ValueError('unknown session action')
        return 0
    if mode == 'emit-status':
        # T-036 mid-run activity. Accept equals-form long opts (fm_herdr_emit_status).
        root = actor = task = en = tw = None
        role = 'worker'
        crew_name = None
        done = total = None
        i = 0
        while i < len(args):
            a = args[i]
            def take(flag, equal=True):
                nonlocal i
                if a == flag:
                    i += 1
                    if i >= len(args): raise ValueError(flag + ' needs a value')
                    return args[i]
                if equal and a.startswith(flag + '='):
                    return a.split('=', 1)[1]
                return None
            if (v := take('--root')) is not None: root = v
            elif (v := take('--actor')) is not None: actor = v
            elif (v := take('--task')) is not None: task = v
            elif (v := take('--en')) is not None: en = v
            elif (v := take('--tw')) is not None: tw = v
            elif (v := take('--role')) is not None: role = v
            elif (v := take('--crew-name')) is not None: crew_name = v or None
            elif (v := take('--done')) is not None: done = int(v)
            elif (v := take('--total')) is not None: total = int(v)
            else: raise ValueError('unknown emit-status option: ' + a)
            i += 1
        if not all([root, actor, task, en, tw]):
            raise ValueError('emit-status requires --root --actor --task --en --tw')
        if (done is None) ^ (total is None):
            raise ValueError('--done and --total must be given together')
        return emit_status(root, actor, task, en, tw, role=role,
                           crew_name=crew_name, done=done, total=total)
    raise ValueError('unknown managed action')


if __name__ == '__main__':
    try: sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError, KeyError, TypeError, AttributeError, RuntimeError, subprocess.SubprocessError) as error:
        print('fm-managed: ' + str(error), file=sys.stderr); sys.exit(70)
