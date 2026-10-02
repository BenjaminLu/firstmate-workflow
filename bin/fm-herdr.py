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
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import uuid

_lifeline = None


def lifeline():
    """bin/lib/fm_lifeline.py, beside this file: the one way fm starts a
    background process (T-151). Loaded when first needed, so a fixture that
    copies this file alone to read the registry does not need bin/lib."""
    global _lifeline
    if _lifeline is None:
        import importlib.util
        path = Path(__file__).resolve().parent / 'lib/fm_lifeline.py'
        spec = importlib.util.spec_from_file_location('fm_lifeline', path)
        module = importlib.util.module_from_spec(spec)
        # no __pycache__ in bin/lib: the tree stays exactly what was committed
        written, sys.dont_write_bytecode = sys.dont_write_bytecode, True
        try: spec.loader.exec_module(module)
        finally: sys.dont_write_bytecode = written
        _lifeline = module
    return _lifeline


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
    # Atomic replacement alone cannot protect the read/check/write decision.
    # Lock a stable sibling, not the receipt inode that save() replaces. Never
    # unlink this lock: transport and pane-child must serialize on the same inode.
    with locked(path.with_name('close.lock')):
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


def record_model(run, vendor, model_requested, model, cli_version):
    """T-127: what the round actually ran on, read from the round itself and
    merged into identity.json beside name/role/project/task/round/attempt -
    never guessed, and never read back out of the actor. `model` is what the
    vendor's own CLI reported (empty/'unknown' when it said nothing);
    `model_requested` is config.yaml's, resolved before the round ran.
    model_mismatch is true only when both are known and they differ, so a
    config with no model set, or a vendor that said nothing, is never
    reported as a mismatch of nothing against nothing."""
    run = Path(run)
    identity = read(run / 'identity.json')
    model = model or 'unknown'
    cli_version = cli_version or 'unknown'
    mismatch = bool(model_requested) and model != 'unknown' and model != model_requested
    identity.update(vendor=vendor or 'unknown', model_requested=model_requested or '',
                     model=model, cli_version=cli_version, model_mismatch=mismatch)
    save(run / 'identity.json', identity)
    return identity


def record_requested(run, vendor, model_requested):
    """T-146: the vendor a round is on and the model config.yaml names for
    that vendor, recorded when the attempt starts rather than only once the
    round has run, so the board shows them from the round's first event.
    What the vendor reports is not known yet: model, cli_version and
    model_mismatch are cleared, never carried over from another vendor's
    attempt, until record_model writes them."""
    run = Path(run)
    identity = read(run / 'identity.json')
    for key in ('model', 'cli_version', 'model_mismatch'): identity.pop(key, None)
    identity.update(vendor=vendor or 'unknown', model_requested=model_requested or '')
    save(run / 'identity.json', identity)
    return identity


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
            raise RuntimeError('herdr is not installed')

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


HOSTS = ('none', 'herdr', 'cmux', 'tmux')


def window_host(root):
    """The terminal host that gets a window onto a round, or 'none'.

    A window is only somewhere for people to watch: it follows the run's log
    and never carries the round. `host:` in config.yaml (FM_HOST overrides it)
    names one; unset, the host fm was started from is detected. A round with
    FM_TRANSPORT=direct asks for no window at all.
    """
    if os.environ.get('FM_TRANSPORT') == 'direct':
        return 'none'
    asked = os.environ.get('FM_HOST', '')
    if not asked:
        entry = _config_key(_config_lines(root), 'host')
        asked = entry[0].strip('\'" ') if entry else ''
    if asked:
        if asked in HOSTS:
            return asked
        print('fm: host: %r is not one of %s; running with no window' % (asked, '|'.join(HOSTS)),
              file=sys.stderr)
        return 'none'
    if os.environ.get('HERDR_ENV') == '1':
        return 'herdr'
    if os.environ.get('CMUX_WORKSPACE_ID') or os.environ.get('CMUX_SOCKET_PATH'):
        print('fm: inherited cmux context is unverified; set FM_HOST and a verified '
              'FM_CMUX_CALLER_WORKSPACE (or HERDR_PANE_ID for Herdr)', file=sys.stderr)
    if os.environ.get('TMUX'):
        return 'tmux'
    return 'none'


class AlreadyStarted(RuntimeError):
    pass


def spawn_runner(attempt):
    """Start the round as a process group of its own, owned by fm and not by
    any terminal: a session of its own, stdout and stderr to the run's log,
    its pid on file. A pane that closes or crashes cannot take it down.

    A round outlives the script that launched it on purpose (a killed
    fm-worker.sh leaves its round retained, to be stopped or resumed), so it
    names the longer-lived owner it belongs to - the session - and holds a
    lifeline to it (T-151): when the session is gone, so is the round. It
    is started through bin/lib/fm_lifeline.py, and holds the line itself
    (run_supervised), so its pid and its group are the round's."""
    attempt = Path(attempt)
    owner = lifeline().session_owner()
    reserve_execution(attempt)
    with (attempt / 'run.log').open('ab') as out:
        proc = lifeline().start([sys.executable, str(Path(__file__).resolve()), 'pane-child', str(attempt)],
                                owner=owner, direct=True,
                                stdin=subprocess.DEVNULL, stdout=out, stderr=out, close_fds=True)
    (attempt / 'runner.pid').write_text(f'{proc.pid}\n')
    return proc


def write_exit(attempt, rc):
    path = Path(attempt) / 'runner.exit'
    temp = path.with_name(path.name + '.' + uuid.uuid4().hex)
    temp.write_text(f'{rc}\n'); os.replace(temp, path)


def run_supervised(attempt):
    """The runner's own entry: the round, then its exit code on file. It
    holds the lifeline spawn_runner handed it first, and runs nothing
    without one, or for an owner already gone (T-151)."""
    try:
        lifeline().hold()
    except RuntimeError as error:  # OwnerGone included
        print('fm runner: ' + str(error), file=sys.stderr)
        write_exit(attempt, 70); return 70
    try:
        rc = pane_child(attempt)
    except (AlreadyStarted, BlockingIOError):
        raise  # someone else's round owns the exit file
    except BaseException:
        write_exit(attempt, 70); raise
    write_exit(attempt, rc)
    return rc


def follow(attempt, poll=0.2):
    """What a window shows: the run's log from its start, followed until the
    round ends (result or exit file, or nothing of the round left running:
    round_live, never the runner's pid alone). Stopping this
    - a closed pane - stops nothing else."""
    attempt = Path(attempt); log = attempt / 'run.log'; at = 0; unseen = time.monotonic()
    out = sys.stdout.buffer
    while True:
        over = (attempt / 'result.json').exists() or (attempt / 'runner.exit').exists()
        pid = attempt / 'runner.pid'
        if not over and pid.is_file():
            try: runner = int(pid.read_text())
            except (ValueError, OSError): over = True
            else:
                try: os.kill(runner, 0)
                except OSError: over = not round_live(attempt, runner)
        elif not over and time.monotonic() - unseen > float(os.environ.get('FM_FOLLOW_GRACE', '120')):
            over = True  # no round ever started under this window
        if log.is_file():
            with log.open('rb') as source:
                source.seek(at); data = source.read()
            if data:
                out.write(data); out.flush(); at += len(data)
                continue
        if over: return 0
        time.sleep(poll)


SAFE_NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}')


def latest_attempt(root, actor):
    """The attempt a round of `actor` last started, or None."""
    if not SAFE_NAME.fullmatch(actor): raise ValueError('not an actor: ' + repr(actor))
    attempts = [path.parent for path in (Path(root) / 'state/runs' / actor).glob('*/invocation.json')]
    return max(attempts, key=lambda path: path.stat().st_mtime_ns) if attempts else None


def group_live(pgid):
    """Whether any member of a process group is still running. A member that
    has exited and waits only for its parent to reap it (a zombie) is not."""
    try: os.killpg(pgid, 0)
    except ProcessLookupError: return False
    try:
        listing = subprocess.run(['ps', '-A', '-o', 'pgid=,stat='], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError): return True
    if listing.returncode: return True
    return any(fields[0] == str(pgid) and not fields[1].startswith('Z')
               for fields in (line.split() for line in listing.stdout.splitlines()) if len(fields) >= 2)


def round_live(attempt, pid):
    """Whether a round still runs, judged by the round and not by its runner
    alone: the runner itself, or the lifetime lock still held (a killed runner
    can leave its adapter running, holding the lock), or, while the round has
    no exit or result file, any member of its process group. A group id is
    not reused while a member lives, and a finished round's is never read."""
    attempt = Path(attempt)
    if process_matches(dict(pid=pid, token='fm-herdr.py')): return True
    try: state = execution_state(attempt)
    except (OSError, ValueError): state = None
    if state and state.get('live'): return True
    if (attempt / 'runner.exit').exists() or (attempt / 'result.json').exists(): return False
    try: return group_live(pid)
    except PermissionError: return True  # a group is there, if not one fm may signal


def stop_group(pid, grace):
    """TERM a round's process group, and KILL whatever of it is left after the
    grace. True once the group is gone. A group id is not reused while any
    member of the group lives, so the KILL cannot reach someone else's."""
    try: os.killpg(pid, signal.SIGTERM)
    except ProcessLookupError: return True
    for wait, then in ((grace, signal.SIGKILL), (2.0, None)):
        end = time.monotonic() + wait
        while time.monotonic() < end:
            if not group_live(pid): return True
            time.sleep(.05)
        if then is None: return False
        try: os.killpg(pid, then)
        except ProcessLookupError: return True
    return False


def stop_run(root, actor, grace=5.0, out=None):
    """Stop every live round of one actor by its process group. A round is
    live while round_live says so, so a round whose runner was killed but
    whose adapter still runs is stopped by its group, then by the CLI pid it
    recorded. A round from before
    T-144 has no runner: its vendor CLI is sent TERM by the pid it recorded,
    as the board did, and only while ps still shows that CLI."""
    out = out if out is not None else dict(stopped=[], failed=[])
    if not SAFE_NAME.fullmatch(actor): raise ValueError('not an actor: ' + repr(actor))
    run = Path(root) / 'state/runs' / actor
    for attempt in sorted(path for path in run.glob('*') if path.is_dir()):
        pidfile = attempt / 'runner.pid'
        if pidfile.is_file():
            try: pid = int(pidfile.read_text())
            except (ValueError, OSError): continue
            runner = process_matches(dict(pid=pid, token='fm-herdr.py'))
            if not (runner or round_live(attempt, pid)): continue
            label = f'{actor} {pid}' if runner else f'{actor} {pid} (runner gone)'
            try: gone = stop_group(pid, grace)
            except OSError as error: gone, why = False, error.strerror or str(error)
            else: why = 'still running after KILL'
            (out['stopped'] if gone else out['failed']).append(label if gone else f'{label}: {why}')
            if runner: continue
            # a runner that is gone recorded its CLI: TERM it as for a round
            # from before T-144, a no-op once the group stop took it
        try: cli = read(attempt / 'execution.json')
        except (OSError, ValueError): continue
        if cli.get('started') is True: signal_recorded(out, f'{actor} {cli.get("pid")}', cli)
    return out


def signal_recorded(out, label, record):
    """TERM a pid a record names, only while ps shows the program it names."""
    pid = record.get('pid')
    if not isinstance(pid, int) or pid <= 1 or not isinstance(record.get('token'), str):
        return
    if not process_matches(record): return
    try: os.kill(pid, signal.SIGTERM); out['stopped'].append(label)
    except OSError as error: out['failed'].append(f'{label}: {error.strerror or error}')


def stop_task(root, task, project, default, grace=5.0):
    """Every crewman on one task of one project, stopped by the one stop path
    the board and fm's stop command share. First the task's bin/fm-worker.sh, with
    TERM, whose trap saves and pushes the worktree; then each of the task's
    runs: its rounds by process group (stop_run) and the script that launched
    it (process.json), by TERM. A run names its project, or is the default's.
    The pull request is never touched."""
    root = Path(root)
    out = dict(stopped=[], failed=[])
    if not SAFE_NAME.fullmatch(task): return out
    try: pid = int((root / 'state/worktrees' / (task + '.pid')).read_text().strip())
    except (OSError, ValueError): pid = None
    if pid: signal_recorded(out, f'worker {pid}', dict(pid=pid, token='fm-worker.sh'))
    for file in sorted((root / 'state/runs').glob('*/identity.json')):
        try: identity = read(file)
        except (OSError, ValueError): continue
        if identity.get('task') != task or (identity.get('project') or default) != project: continue
        actor = file.parent.name
        if not SAFE_NAME.fullmatch(actor): continue
        stop_run(root, actor, grace, out)
        try: launcher = read(file.parent / 'process.json')
        except (OSError, ValueError): continue
        signal_recorded(out, f'{actor} {launcher.get("pid")}', launcher)
    return out


def stop_command(args):
    """`stop <root> <actor>` or `stop <root> --task <id> [--project P] [--default D]`."""
    root, *rest = args
    grace = float(os.environ.get('FM_STOP_GRACE', '5'))
    if rest[:1] != ['--task']:
        if len(rest) != 1: raise ValueError('usage: stop <root> <actor> | stop <root> --task <id>')
        return stop_run(root, rest[0], grace)
    options = dict(zip(rest[::2], rest[1::2]))
    if len(rest) % 2 or set(options) - {'--task', '--project', '--default'}:
        raise ValueError('usage: stop <root> --task <id> [--project <name>] [--default <name>]')
    default = options.get('--default', default_project(root) or '')
    return stop_task(root, options['--task'], options.get('--project') or default, default, grace)


def supervise(attempt, proc, timeout, identity, chain_attempt):
    """Wait for the round's result; a runner that is gone with nothing live
    left of it and no result was lost, and says so as a result."""
    attempt = Path(attempt)
    deadline = time.monotonic() + timeout
    while not (attempt / 'result.json').exists():
        if proc.poll() is not None and not (attempt / 'result.json').exists():
            state = execution_state(attempt)
            if not (state and state.get('live')):
                if (attempt / 'result.json').exists(): break
                lost = dict(identity, exit_code=70, status='lost', pid=proc.pid,
                            runner_exit=proc.returncode, chain_attempt=chain_attempt,
                            cli_exit_code=None)
                save(attempt / 'result.json', lost); publish_last_result(attempt, lost)
                break
        if time.monotonic() >= deadline:
            save(attempt / 'transport.json', dict(status='timed-out', actor=identity['actor']))
            raise RuntimeError('run timed out; process and artifacts retained at ' + str(attempt))
        time.sleep(.1)
    return read(attempt / 'result.json')


class Host:
    """A terminal host other than Herdr (tmux, cmux): one command, logged."""
    def __init__(self, name, run):
        self.name = name; self.run = Path(run)
        self.binary = shutil.which(name)
        if not self.binary:
            raise RuntimeError(name + ' is not installed')

    def __call__(self, *args):
        env = dict(os.environ)
        if self.name == 'cmux':
            # Targeted calls carry explicit refs; focus observations must not
            # resolve against a stale inherited caller. Preserve socket/auth.
            env.pop('CMUX_WORKSPACE_ID', None)
            env.pop('CMUX_SURFACE_ID', None)
        result = subprocess.run([self.binary, *args], capture_output=True, text=True, timeout=15, env=env)
        # The CLI receives credentials through its supported environment, never
        # argv. Redact a configured password if a host error echoes it.
        secret = os.environ.get('CMUX_SOCKET_PASSWORD') if self.name == 'cmux' else None
        if secret:
            result.stdout = result.stdout.replace(secret, '[redacted]')
            result.stderr = result.stderr.replace(secret, '[redacted]')
        with (self.run / 'window.log').open('a') as out:
            out.write(shlex.join(args) + '\n' + result.stdout + result.stderr)
        if result.returncode:
            detail = result.stderr.strip() or result.stdout.strip() or 'no diagnostic output'
            remedy = ('; verify the intended host/caller and cmux access from the session-owned '
                      'launch path. Foreground ping does not prove detached cmuxOnly access. '
                      'In nested Herdr use FM_HOST=herdr with verified HERDR_PANE_ID, '
                      'HERDR_TAB_ID and HERDR_WORKSPACE_ID, retaining cmuxOnly. '
                      'Otherwise use FM_HOST=none and fm follow; detached cmuxOnly control is deferred. '
                      'do not change socket permissions or enable allowAll'
                      if self.name == 'cmux' else '')
            raise RuntimeError(self.name + ' command failed: ' + shlex.join(args) + ': ' + detail + remedy)
        return result.stdout.strip()


def open_generic_window(host, attempt, tree, actor, command):
    """A labelled tmux window or cmux workspace showing the run's log.

    Only documented interfaces. tmux(1): `new-window [-d] [-P] [-F format]
    [-n window-name] [-c start-directory] [shell-command]`; -P prints the new
    window's information in -F's format, and `#{window_id}` is its `@N` id.
    The window runs the follower and closes itself when the follower exits.
    cmux's own help: `new-workspace [--cwd <path>] [--command <text>]` (no
    name; --command sends the text and Enter to the new workspace's shell),
    `rename-workspace [--workspace <id|ref>] <title>`, and
    `close-workspace --workspace <id|ref>`; its output "defaults to refs"
    (workspace:N), or UUIDs with --id-format. The workspace is opened, then
    labelled by the ref it came back with; one that names no ref cannot be
    labelled or closed, and is said to have failed."""
    control = Host(host, attempt)
    if host == 'tmux':
        if not os.environ.get('TMUX'): raise RuntimeError('not inside a tmux session')
        ref = control('new-window', '-d', '-P', '-F', '#{window_id}', '-n', actor,
                      '-c', str(Path(tree).resolve()), command)
        if not re.fullmatch(r'@\d+', ref): raise RuntimeError('tmux gave no window id: ' + repr(ref))
    else:
        return open_cmux_window(control, attempt, tree, actor, command)
    record = dict(host=host, status='open', ref=ref, actor=actor)
    save(Path(attempt) / 'window.json', record)
    return record


def cmux_workspaces(control):
    """Require structured identity; never treat a display index as ownership."""
    value = json.loads(control('list-workspaces', '--json', '--id-format', 'both'))
    rows = value.get('workspaces') if isinstance(value, dict) else value
    if not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows):
        raise RuntimeError('cmux workspace identity unavailable; retain resources')
    return rows


def cmux_workspace(control, reference):
    rows = [row for row in cmux_workspaces(control)
            if reference in (row.get('id'), row.get('ref'))]
    if len(rows) != 1 or not rows[0].get('id') or not rows[0].get('ref'):
        raise RuntimeError('cmux cannot verify workspace identity: ' + reference)
    return rows[0]


def cmux_ref(text):
    found = re.fullmatch(r'(?:OK\s+)?(workspace:\d+|[0-9A-Fa-f-]{36})', text.strip())
    if not found: raise RuntimeError('cmux named no unique workspace: ' + repr(text))
    return found.group(1)


def open_cmux_window(control, attempt, tree, actor, command):
    caller = os.environ.get('FM_CMUX_CALLER_WORKSPACE', '')
    if not caller:
        raise RuntimeError('cmux requires explicit verified FM_CMUX_CALLER_WORKSPACE; '
                           'inherited CMUX_WORKSPACE_ID and focused workspace are not caller evidence')
    # This runs at the point of use, not in the foreground shell which may
    # have different socket authorization after the supervised launch.
    capabilities = json.loads(control('capabilities', '--json'))
    # Accept cmuxOnly when this actual caller is authorized by the host.
    # A successful foreground call never promises detached authorization.
    if not isinstance(capabilities, dict) or capabilities.get('access_mode') not in ('cmuxOnly', 'password'):
        raise RuntimeError('cmux access mode must be cmuxOnly or explicitly operator-configured password; '
                           'do not enable allowAll or change settings for this launch. '
                           'Use FM_HOST=herdr with verified caller context or FM_HOST=none')
    try:
        current = cmux_workspace(control, caller)
    except (RuntimeError, ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        raise RuntimeError('cmux caller verification failed for FM_CMUX_CALLER_WORKSPACE='
                           + caller + ': ' + str(error) + '; verify the intended conversation '
                           'workspace explicitly; focused workspace is not a caller fallback') from error
    window_before = control('current-window')
    if not window_before: raise RuntimeError('cmux cannot verify focused window')
    before = cmux_ref(control('current-workspace'))
    focus_identity = cmux_workspace(control, before)
    record = dict(host='cmux', status='none', actor=actor, caller=current['id'],
                  caller_source='FM_CMUX_CALLER_WORKSPACE',
                  access_mode=capabilities.get('access_mode'), focus_before=focus_identity['id'],
                  window_before=window_before)
    save(Path(attempt) / 'window.json', record)
    existing = {row['id'] for row in cmux_workspaces(control) if row.get('id')}
    try:
        ref = cmux_ref(control('new-workspace', '--cwd', str(Path(tree).resolve()), '--command', command))
        record['ref'] = ref
        save(Path(attempt) / 'window.json', record)
        created = cmux_workspace(control, ref)
        if created['id'] in existing:
            raise RuntimeError('cmux creation returned an existing workspace; retained')
        record['workspace_id'] = created['id']
        control('rename-workspace', '--workspace', ref, actor)
        observed = cmux_workspace(control, ref)
        if observed['id'] != created['id'] or observed.get('title') != actor:
            raise RuntimeError('cmux label or workspace identity verification failed; retained')
        # Keep the entire observed structure. Any later difference is grounds
        # to retain, including an additional surface or a changed label.
        record['tree'] = json.loads(control('tree', '--workspace', ref, '--json'))
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError) as error:
        record['reason'] = str(error)
        record['cleanup'] = 'retained: creation or label not verified'
        raise
    finally:
        if isinstance(sys.exc_info()[1], (SystemExit, KeyboardInterrupt)):
            save(Path(attempt) / 'window.json', record)
        else:
            try:
                if control('current-window') != window_before:
                    raise RuntimeError('cmux focused window changed; retained without stealing focus')
                after = cmux_ref(control('current-workspace'))
                if after != before:
                    # Restore only focus taken by this creation. Never take focus
                    # from a third workspace selected meanwhile by the captain.
                    if after != record.get('ref'):
                        raise RuntimeError('cmux focus changed concurrently; retained')
                    if cmux_workspace(control, before)['id'] != focus_identity['id']:
                        raise RuntimeError('cmux previous focus identity changed; retained')
                    control('select-workspace', '--workspace', before)
                    if cmux_ref(control('current-workspace')) != before:
                        raise RuntimeError('cmux focus restoration failed; retained')
            except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError) as focus_error:
                record['reason'] = '; '.join(filter(None, (record.get('reason'), str(focus_error))))
                raise RuntimeError(record['reason']) from focus_error
            finally:
                save(Path(attempt) / 'window.json', record)
    record['status'] = 'open'
    save(Path(attempt) / 'window.json', record)
    return record


def close_generic_window(record, attempt):
    """Close only a cmux resource whose observed identity and structure agree.

    This is a conservative observation, not an atomic host ownership lease.
    Without one, concurrent host changes remain a real integration limitation.
    """
    if record['host'] == 'cmux' and record.get('ref'):
        if os.environ.get('FM_AUTOCLOSE', '1') == '0': return 'retained: auto-close disabled'
        try:
            result = read(Path(attempt) / 'result.json')
            if (not isinstance(result, dict) or result.get('exit_code') != 0
                    or result.get('status') != 'completed'):
                return 'retained: incomplete result'
            path = Path(attempt) / 'window.json'
            if path.is_symlink() or read(path) != record:
                return 'retained: ownership receipt changed'
            control = Host('cmux', attempt)
            observed = cmux_workspace(control, record['ref'])
            if (not record.get('workspace_id') or observed['id'] != record['workspace_id']
                    or observed.get('title') != record['actor'] or 'tree' not in record
                    or json.loads(control('tree', '--workspace', record['ref'], '--json')) != record['tree']):
                return 'retained: workspace identity, label or structure changed'
            control('close-workspace', '--workspace', record['ref'])
        except (RuntimeError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            return 'retained: ' + str(error)
    return 'closed'


def open_herdr_window(attempt, logical, tree, actor, task, env, command):
    """The round's labelled Herdr tab, opened before the round starts, running
    `command` (the follower). Anything uncertain raises and leaves the pane
    alone; the round then runs with no window."""
    control = Herdr(attempt)
    caller = os.environ.get('HERDR_PANE_ID')
    if not caller: raise RuntimeError('no caller HERDR_PANE_ID to open a tab beside')
    # Read caller membership and UI focus separately: dispatch may itself be unfocused.
    current = control('pane', 'get', caller)['pane']
    if (current.get('pane_id') != caller or not current.get('tab_id')
            or not current.get('workspace_id')): raise RuntimeError('cannot verify caller pane')
    # Pane-only detection remains supported. Every supplied membership claim
    # must agree with the host before creating or reusing an owned resource.
    for name, field in (('HERDR_TAB_ID', 'tab_id'), ('HERDR_WORKSPACE_ID', 'workspace_id')):
        if name in os.environ and os.environ[name] != current[field]:
            raise RuntimeError('cannot verify caller context: ' + name + ' does not match caller pane')
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
    # The follower only prints the run's log; a lost reply here launches nothing.
    control('pane', 'run', pane, command)
    return owner, control


# What a round's environment may hold (T-156): the one list both what is saved
# to its environment.json and what the runner hands the adapter are read
# from. Never a copy of the launcher's os.environ, which holds the operator's
# own GitHub and harness credentials (GH_TOKEN, CLAUDE_CODE_MESSAGING_TOKEN);
# credential option A keeps those out of rounds, and so off their disk too.
# fm-sandbox.sh's scrub stays the second line. A name the runner needs that
# is not here is added here, with the reason.
ROUND_ENV_PREFIXES = ('FM_',   # the round's identity, paths and fm's own settings
                      'LC_')   # the locale
ROUND_ENV_NAMES = frozenset((
    'PATH', 'HOME', 'TMPDIR', 'LANG', 'TERM', 'TZ',
    # who the operator is: fm-config.sh's {user} (getpass) and the CLIs'
    'USER', 'LOGNAME', 'SHELL',
    # the Herdr window the round is shown in; the adapter reads HERDR_ENV
    'HERDR_ENV', 'HERDR_PANE_ID', 'HERDR_TAB_ID', 'HERDR_WORKSPACE_ID',
    # a CA bundle the operator's TLS needs to reach a vendor or a registry
    # through the round's proxy; fm-sandbox.sh reads SSL_CERT_FILE. No secret.
    'SSL_CERT_FILE', 'SSL_CERT_DIR', 'NODE_EXTRA_CA_CERTS',
    # fm-sandbox.sh reads the crew's login with secret-tool, outside the
    # round, over the session bus (T-126); its scrub keeps the bus out of it
    'DBUS_SESSION_BUS_ADDRESS', 'XDG_RUNTIME_DIR',
))
# Each vendor's login variables, in fm-config.sh's order (VENDORS, `given`):
# These are candidates, not permission to use ambient API billing. The first
# set candidate allowed by the adapters' billing/overriding-credential policy
# is handed on. Subscription codex/gemini logins travel as sandbox file copies.
# tests/herdr.test.sh holds the candidate lists equal to the policy's `given`.
ROUND_LOGIN = {
    'claude': ('CLAUDE_CODE_OAUTH_TOKEN', 'ANTHROPIC_API_KEY'),
    'codex': ('CODEX_API_KEY',),
    'cursor-agent': ('CURSOR_API_KEY',),
    'gemini': ('GEMINI_API_KEY', 'GOOGLE_API_KEY'),
}


def round_environment(source, vendor):
    """The part of <source> a round of <vendor> may have: the allowlist above,
    and the vendor's own login variable. Anything else is dropped."""
    env = {key: value for key, value in source.items()
           if key in ROUND_ENV_NAMES or key.startswith(ROUND_ENV_PREFIXES)}
    candidates = ROUND_LOGIN.get(vendor, ())
    if not any(source.get(name) for name in candidates):
        return env
    # Ask the same functions the adapters use, from the round's immutable
    # code snapshot. Only variable names leave this helper, never credentials.
    code = Path(source.get('FM_CODE_ROOT') or Path(__file__).resolve().parents[1])
    # The library resolves settings from FM_ROOT, with FM_ADAPTER_CONFIG as
    # an explicit override. A code snapshot intentionally has no config.yaml.
    policy_env = {'PATH': os.environ.get('PATH', os.defpath)}
    for name in ('FM_ROOT', 'FM_ADAPTER_CONFIG'):
        if source.get(name):
            policy_env[name] = source[name]
    policy = subprocess.run(
        ['bash', '-c', '. "$1/bin/adapters/_lib.sh" || exit; '
         'if [ "$(fm_adapter_billing "$2")" != api-key ]; then '
         'fm_adapter_outranking "$2"; fi', 'round-login', str(code), vendor],
        env=policy_env,
        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20, check=True)
    shed = set(policy.stdout.splitlines())
    for name in candidates:
        if source.get(name) and name not in shed:
            env[name] = source[name]
            break
    return env


def review_context(env):
    """Validate the isolated launcher checkout before admitting a Codex review."""
    if env.get('FM_ROLE') != 'reviewer' or env.get('FM_RUN_REVIEW') != '1':
        raise ValueError('Codex run review requires reviewer launcher context')
    directory = env.get('FM_REVIEW_CHECKOUT', '')
    checkout = Path(directory)
    if not directory or not checkout.is_absolute() or str(checkout.resolve()) != directory:
        raise ValueError('review checkout must be an absolute canonical path')
    if not (checkout / '.git').is_dir() or (checkout / '.git').is_symlink():
        raise ValueError('review checkout must have its own git directory')
    for key in ('FM_ROOT', 'FM_CODE_ROOT', 'FM_RUN_DIR'):
        if env.get(key):
            protected = Path(env[key]).resolve()
            if checkout == protected or protected in checkout.parents:
                raise ValueError('review checkout overlaps launcher state or source')
    if (checkout / '.git/objects/info/alternates').exists():
        raise ValueError('review checkout must not borrow another object database')
    def git(*args):
        clean = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
        clean.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
        return subprocess.check_output(['git', '-C', directory, *args], env=clean,
                                       stderr=subprocess.DEVNULL, text=True).strip()
    head, base = env.get('FM_REVIEW_HEAD', ''), env.get('FM_REVIEW_BASE', '')
    if not all(re.fullmatch(r'[0-9a-f]{40,64}', x) for x in (head, base)):
        raise ValueError('review context has no pinned head/base')
    if git('rev-parse', '--show-toplevel') != directory or git('rev-parse', '--absolute-git-dir') != str(checkout / '.git'):
        raise ValueError('review checkout redirects git outside its own tree')
    if git('rev-parse', 'HEAD') != head or git('rev-parse', 'refs/fm/head') != head:
        raise ValueError('review checkout does not match pinned head')
    if git('rev-parse', 'refs/fm/base') != base or git('remote'):
        raise ValueError('review checkout has wrong base or a remote')
    if git('status', '--porcelain'):
        raise ValueError('review checkout is not fresh')
    return dict(checkout=directory, head=head, base=base, patch=env.get('FM_REVIEW_PATCH', ''))


def review_final(run, chain_attempt, env):
    """Read only this invocation's transport-authored, digest-bound final answer."""
    try:
        run = Path(run).resolve()
        result = read(run / 'last-result.json')
        attempt = Path(result['attempt']).resolve()
        if attempt.parent != run or not chain_attempt or result.get('chain_attempt') != chain_attempt:
            return ''
        invocation = read(attempt / 'invocation.json')
        for key, name in [('actor', 'FM_ACTOR'), ('task', 'FM_TASK'), ('role', 'FM_ROLE')]:
            if result.get(key) != env.get(name) or invocation.get(key) != env.get(name): return ''
        if env.get('FM_RUN_REVIEW') == '1':
            expected = dict(checkout=env.get('FM_REVIEW_CHECKOUT'), head=env.get('FM_REVIEW_HEAD'),
                            base=env.get('FM_REVIEW_BASE'), patch=env.get('FM_REVIEW_PATCH', ''))
            if result.get('review') != expected or invocation.get('review') != expected: return ''
        if result.get('final_source') != 'codex-json-completed-turn': return ''
        answer = (attempt / 'final.txt').read_bytes().decode('utf-8')
        if hashlib.sha256(answer.encode()).hexdigest() != result.get('final_sha256'): return ''
        if completion('reviewer', env.get('FM_TASK', ''), answer) != 'completed': return ''
        if not any(line in ('APPROVE:' + env.get('FM_TASK', ''), 'REJECT:' + env.get('FM_TASK', ''))
                   for line in answer.splitlines()): return ''
        return answer
    except (OSError, ValueError, KeyError, TypeError):
        return ''


@contextlib.contextmanager
def cmux_shutdown(attempt):
    """Record bounded termination without closing resources of uncertain ownership.

    The existing lifeline sends TERM and enforces its KILL deadline. No new
    process or host RPC is started during shutdown. A hard kill can still
    prevent this best-effort receipt; it is not proof of owner-exit cleanup.
    """
    stopped = False
    def stop(signum, _frame):
        nonlocal stopped
        stopped = True
        raise SystemExit(128 + signum)
    previous = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGINT)}
    for sig in previous: signal.signal(sig, stop)
    try:
        yield
    finally:
        for sig, handler in previous.items(): signal.signal(sig, handler)
        if stopped:
            path = Path(attempt) / 'window.json'
            try:
                if path.is_file() and not path.is_symlink():
                    record = read(path)
                    if record.get('host') == 'cmux':
                        record['shutdown'] = 'termination'
                        record['cleanup'] = 'retained: termination; foreground ownership unverified'
                        if record.get('status') == 'open': record['status'] = record['cleanup']
                        save(path, record)
            except (OSError, ValueError, TypeError):
                pass  # Preserve the original termination; never delay the lifeline.


def transport(adapter, prompt, tree, log):
    """A whole adapter executes as a round fm owns, preserving normal verdict/fallback."""
    # Caller-side wait must survive the launching shell exiting (SIGHUP). The
    # runner is a session of its own and ignores it too.
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
    env = dict(round_environment(os.environ, Path(adapter).stem), FM_ROLE=role, FM_TASK=task,
               FM_ACTOR=actor, FM_FINAL_PATH=str(attempt / 'final.txt'),
               FM_ATTEMPT_DIR=str(attempt), FM_CONTEXT_READY='1')
    # The round does not inherit the launcher's environment, only the
    # allowlist's part of it (T-156). Keep that private and never print it.
    save(attempt / 'environment.json', env); (attempt / 'environment.json').chmod(0o600)
    payload = dict(adapter=str(Path(adapter).resolve()), prompt=str(attempt / 'prompt.md'),
                   tree=str(Path(tree).resolve()), actor=actor, role=role, task=task,
                   lifetime_tracking=True)
    if Path(adapter).stem == 'codex' and env.get('FM_RUN_REVIEW') == '1':
        payload['review'] = review_context(env)
    save(attempt / 'invocation.json', payload)
    timeout = float(os.environ.get('FM_HERDR_TIMEOUT', '21600'))
    if not math.isfinite(timeout) or timeout <= 0:
        raise ValueError('FM_HERDR_TIMEOUT must be positive finite seconds')
    # The window first, so it is there when the round starts; it only follows
    # the run's log, so failing to open one costs the round nothing.
    host = window_host(root)
    save(attempt / 'host.json', dict(host=host, source=('FM_TRANSPORT' if os.environ.get('FM_TRANSPORT') == 'direct'
         else 'FM_HOST' if os.environ.get('FM_HOST') else 'config-or-detection'),
         inherited_cmux_context_ignored=bool(os.environ.get('CMUX_WORKSPACE_ID')),
         caller=os.environ.get('FM_CMUX_CALLER_WORKSPACE') if host == 'cmux'
         else os.environ.get('HERDR_PANE_ID') if host == 'herdr' else None))
    command = shlex.join([sys.executable, str(Path(__file__).resolve()), 'follow', str(attempt)])
    # window.json always says what window the round has, `none` included, so
    # a round with no window is recorded as one, never inferred from absence.
    with cmux_shutdown(attempt) if host == 'cmux' else contextlib.nullcontext():
        owner = control = window = None
        # the caller's own Herdr context, put back if a window fails after
        # open_herdr_window has already handed the round its pane
        caller = {key: env.get(key) for key in ('HERDR_PANE_ID', 'HERDR_TAB_ID', 'HERDR_WORKSPACE_ID')}
        try:
            if host == 'herdr':
                owner, control = open_herdr_window(attempt, logical, tree, actor, task, env, command)
                window = dict(host=host, status='open', pane=owner['pane_id'], actor=actor)
                save(attempt / 'window.json', window)
            elif host != 'none':
                window = open_generic_window(host, attempt, tree, actor, command)
            else:
                window = dict(host='none', status='none', reason='no terminal host', actor=actor)
                save(attempt / 'window.json', window)
        except (OSError, ValueError, KeyError, TypeError, AttributeError, RuntimeError,
                subprocess.SubprocessError) as error:
            # never let a pane the round is not running in be closed by the round
            if (attempt / 'owner.json').exists(): (attempt / 'owner.json').rename(attempt / 'owner.failed.json')
            owner = control = None
            # nor run with, or leave reported as working, a pane fm has disowned
            if any(env.get(key) != value for key, value in caller.items()):
                for key, value in caller.items():
                    if value is None: env.pop(key, None)
                    else: env[key] = value
                save(attempt / 'environment.json', env); (attempt / 'environment.json').chmod(0o600)
            disowned = attempt / 'owner.failed.json'
            if host == 'herdr' and disowned.is_file():
                try:
                    pane = read(disowned)['pane_id']
                    Herdr(attempt)('pane', 'report-agent', pane, '--source', 'firstmate', '--agent', actor,
                                   '--state', 'idle', '--agent-session-id', actor,
                                   '--message', task + ': no window')
                except (OSError, ValueError, KeyError, TypeError, RuntimeError,
                        subprocess.SubprocessError) as report:
                    print(f'{actor}: could not report the disowned pane idle ({report})', file=sys.stderr)
            # A partial creation is not a visible, verified worker window.
            opened = read(attempt / 'window.json') if (attempt / 'window.json').is_file() else {}
            window = dict(opened, host=host, status='none', reason=str(error), actor=actor)
            save(attempt / 'window.json', window)
            print(f'{actor}: no {host} window ({error}); the round runs without one', file=sys.stderr)
        proc = spawn_runner(attempt)
        result = supervise(attempt, proc, timeout, dict(actor=actor, task=task, role=role),
                           env.get('FM_CHAIN_ATTEMPT', ''))
        with Path(log).open('ab') as out:
            cli = attempt / 'cli.log'
            if cli.exists(): out.write(cli.read_bytes())
            out.flush(); os.fsync(out.fileno())
        save(logical / 'last-result.json', dict(result, attempt=str(attempt)))
        if owner is None:
            close = 'no window'
            if window and window.get('status') == 'open':
                close = close_generic_window(window, attempt)
                save(attempt / 'window.json', dict(window, status=close))
            print(f'{actor}: {close}; artifacts {attempt}', file=sys.stderr)
            return result['exit_code']
        pane = owner['pane_id']
        close = 'retained: auto-close disabled'
        if os.environ.get('FM_AUTOCLOSE', '1') != '0':
            prior = attempt / 'close.json'
            if prior.exists() and read(prior).get('status') == 'closed':
                close = 'closed'
            else:
                try:
                    # Let the follower leave the foreground; never report idle on a busy pane.
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
            raise AlreadyStarted('attempt already started; refusing duplicate execution')
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
    never succeed on a real Herdr. By default, fork a closer through the
    lifeline (bin/lib/fm_lifeline.py) that waits for this process to exit,
    then rechecks ownership and closes. Pass wait_pid=0 to close inline (unit
    tests with an injected control). The transport waiter may race;
    record_close keeps the first durable closed receipt.
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

    # The closer is owned by this pane-child through a lifeline (T-151): it
    # sits in a session of its own, so closing the pane does not take it,
    # and reads EOF the moment this process exits, however it exits. It
    # never asks whether a pid is alive: a zombie answers yes, and a reused
    # pid answers yes for somebody else.
    try:
        child, lifeline_fd = lifeline().fork()
    except OSError as error:
        return 'retained: cleanup observation failed: ' + str(error)
    if child != 0:
        return 'scheduled'
    try:
        wait = float(os.environ.get('FM_HERDR_SHELL_WAIT', '60'))
        if not lifeline().wait_owner(lifeline_fd, wait):
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
    if vendor not in ('codex', 'claude', 'cursor-agent', 'gemini'): return None
    try: text = Path(log).read_text()
    except OSError: return None
    if vendor == 'codex':
        # exec --json emits completed items, then turn.completed. Tool output,
        # reasoning, prompt echoes and abandoned turns cannot provide a final.
        answer = None
        active = complete = False
        kind = None
        for line in text.splitlines():
            try: event = json.loads(line)
            except ValueError: continue
            if not isinstance(event, dict): continue
            kind = event.get('type')
            if kind == 'thread.started':
                active, complete, answer = False, False, None
            elif kind == 'turn.started':
                active, complete, answer = True, False, None
            elif kind in ('turn.failed', 'error'):
                active, complete, answer = False, False, None
            elif kind == 'item.completed' and active:
                item = event.get('item', {})
                if isinstance(item, dict) and item.get('type') == 'agent_message' and isinstance(item.get('text'), str):
                    answer = item['text']
                else:
                    answer = None
            elif kind == 'turn.completed':
                complete, active = active and answer is not None, False
        return answer if complete and kind == 'turn.completed' else None
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
    # the same allowlist again, so a file written by an older launcher hands
    # the adapter nothing more than a new one would (T-156)
    env = round_environment(read(attempt / 'environment.json'), Path(invocation.get('adapter', '')).stem)
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
    vendor = Path(invocation['adapter']).stem
    answer = cli_final(vendor, attempt / 'cli.log')
    if vendor == 'codex' and role == 'reviewer' and final.exists():
        final.unlink()  # CLI output files never establish provenance
    if answer is not None:
        final.write_text(answer)
    status = completion(invocation['role'], invocation['task'], final.read_text()) if final.exists() else 'unknown'
    if final.exists():
        with final.open('rb') as source: os.fsync(source.fileno())
    result = dict(actor=invocation['actor'], task=invocation['task'], role=invocation['role'],
                  exit_code=rc, status=status, pid=os.getpid(),
                  chain_attempt=env.get('FM_CHAIN_ATTEMPT', ''))
    if vendor == 'codex' and answer is not None:
        result.update(final_source='codex-json-completed-turn',
                      final_sha256=hashlib.sha256(answer.encode()).hexdigest())
    if 'review' in invocation:
        result['review'] = invocation['review']
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

    T-118: a run whose recorded process is gone and that never said
    agent_finished was lost, not finished, and the log says so once: one
    `agent_lost` under that exact actor, in English and Traditional Chinese,
    which blocks its task on the board unless a later event has moved it.
    The agent_finished that has always closed a ghost follows it; the board
    shows the loss and not that close. A loss already written is not written
    again, so a run interrupted between the two only adds the close.
    """
    root = Path(root).resolve()
    emit = root / 'bin/fm-emit.sh'
    retired, kept, lost = [], [], []
    if not emit.is_file():
        return dict(retired=retired, kept=kept, lost=lost)
    env = dict(os.environ, FM_ROOT=str(root))
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
        pr = ['--pr', str(event['pr'])] if isinstance(event.get('pr'), int) else []
        if event.get('type') != 'agent_lost':
            cmd = ['bash', str(emit), '--actor', str(actor), '--type', 'agent_lost', '--task', str(task),
                   '--data', json.dumps({'role': role, 'status': 'process_gone'}), *pr,
                   '--en', f'{actor} was lost on {task}: its process is gone and it never said it finished',
                   '--tw', f'{actor} 在 {task} 上失聯：行程已不在，也從未回報完成']
            result = subprocess.run(cmd, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True)
            if result.returncode != 0:
                raise RuntimeError('deck reconcile emit failed for ' + actor + ': ' + (result.stderr or result.stdout))
            lost.append(actor)
            # the loss wakes firstmate (T-137), pushed by whoever wrote it
            try:
                lifeline().push(root, actor, 'lost', f'lost: {task} {actor}', dict(task=task, actor=actor))
            except (OSError, ValueError) as error:
                print(f'fm-herdr: the wake for {actor} was not pushed: {error}', file=sys.stderr)
        data = json.dumps({'role': role, 'status': 'process_gone'})
        cmd = ['bash', str(emit), '--actor', str(actor), '--type', 'agent_finished',
               '--task', str(task), '--data', data, *pr,
               '--en', f'deck reconcile: {actor} has no live process',
               '--tw', f'甲板對帳：{actor} 無活進程']
        result = subprocess.run(cmd, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError('deck reconcile emit failed for ' + actor + ': ' + (result.stderr or result.stdout))
        retired.append(actor)
    return dict(retired=retired, kept=kept, lost=lost)


# --- The wake (T-151) ----------------------------------------------------------
# Nothing watches for a decision. Whoever writes one - the board, on the
# captain's click, and again when the merge it started settles - delivers
# the wake at write time: it appends the item to the wake queue, durable and
# read again at every session start and status, then rings every waiter's
# own doorbell under state/session/wake.d (bin/lib/fm_lifeline.py's ring;
# with no waiter the queue alone carries it). A waiter - `fm-session.sh
# wait`, `fm-decide.sh --await` - registers its doorbell before it reads the
# queue, so a wake written in between is found, never a miss; and each
# waiter has a bell of its own, so no waiter takes another's wake.
WAKE_QUEUE = 'state/session/wake.jsonl'


def wakes(root):
    """The wake queue, oldest first; a line that does not parse is skipped."""
    path = Path(root) / WAKE_QUEUE
    found = []
    if path.is_file():
        for line in path.read_text().splitlines():
            try: item = json.loads(line)
            except ValueError: continue
            if isinstance(item, dict) and isinstance(item.get('id'), str) and re.fullmatch(r'[A-Za-z0-9_-]+', item['id']):
                found.append(item)
    return found


def unacknowledged(root):
    """Captain decisions pushed to the wake queue that firstmate has not
    acknowledged since; reads, never consumes. An id acknowledged and then
    woken again (its merge settled) is listed again."""
    base = Path(root) / 'state/session'
    latest = {}
    for item in wakes(root):
        latest[item['id']] = item
    # observations the retired watcher wrote before T-151 stay readable
    for path in sorted((base / 'observed').glob('*.json')):
        if path.stem in latest: continue
        receipt = read(path)
        latest[path.stem] = dict(id=receipt.get('id', path.stem), decision=receipt.get('decision') or {},
                                 woken=receipt.get('observed'), reason='observed')
    found = []
    committed = lifeline().acknowledged_many(root, latest) if latest else {}
    for ident, item in latest.items():
        # the one record of delivery (T-137): acknowledged here, or taken
        # by the watch that handed it to the harness's hook
        seen = committed[ident]
        if seen is not None and seen >= (item.get('woken') or 0): continue
        answer = item.get('decision') or {}
        found.append(dict(id=ident, task=answer.get('task') if answer else item.get('task'), kind=answer.get('kind'),
                          chosen=answer.get('chosen'), text=answer.get('text'), ts=answer.get('ts'),
                          merge=answer.get('merge'), reason=item.get('reason'), woken=item.get('woken'),
                          # a crew wake (T-137) carries its own reason line
                          **({'line': item['line']} if isinstance(item.get('line'), str) else {})))
    return sorted(found, key=lambda item: (item['woken'] or 0, item['id']))


def wake_wait(root, decision='all', timeout=0):
    """Block on a doorbell of this wait's own until an unacknowledged
    decision (that one, or any) is in the queue; [] when the timeout
    (seconds, 0 for none) ends first. A foreground wait of the caller's
    own: it starts nothing, and its doorbell goes when it does."""
    if decision != 'all' and not re.fullmatch(r'[A-Za-z0-9_-]+', decision): raise ValueError('invalid decision ID')
    deadline = time.monotonic() + timeout if timeout else None
    # registered first, then the queue read: a wake in between is found
    with lifeline().Doorbell(root) as bell:
        while True:
            items = [item for item in unacknowledged(root) if decision in ('all', item['id'])]
            if items: return items
            left = None if deadline is None else deadline - time.monotonic()
            if left is not None and left <= 0: return []
            if not bell.wait(left):
                return [item for item in unacknowledged(root) if decision in ('all', item['id'])]


def pending_summary(items):
    if not items: return 'fm-session: no unacknowledged captain decisions'
    decisions = [item for item in items if 'line' not in item]
    crew = [item for item in items if 'line' in item]
    lines = []
    if decisions:
        lines.append(f'fm-session: {len(decisions)} captain decision{"" if len(decisions) == 1 else "s"} '
                     'woken but not acknowledged; act on each, then run fm-session.sh ack --decision <id>')
    for item in decisions:
        chosen = item['chosen'] if item['text'] is None else f'{item["chosen"]} "{item["text"]}"'
        merge = f', merge {item["merge"]}' if item.get('merge') else ''
        lines.append(f'  {item["id"]} {item["task"]} {item["kind"]} chose {chosen} at {item["ts"]}{merge}')
    # T-137: a round's end, a verdict, a loss, a gate
    if crew:
        lines.append(f'fm-session: {len(crew)} crew wake{"" if len(crew) == 1 else "s"} '
                     'not acknowledged; act on each, then run fm-session.sh ack --decision <id>')
    for item in crew:
        lines.append(f'  {item["id"]} {item["line"]}')
    return '\n'.join(lines)


def acknowledge(root, decision):
    """Durably record that firstmate acted on a wake; idempotent, deletes nothing."""
    if decision == 'all' or not re.fullmatch(r'[A-Za-z0-9_-]+', decision):
        raise ValueError('ack requires --decision <id>')
    base = Path(root) / 'state/session'
    items = [item for item in wakes(root) if item['id'] == decision]
    observation = base / 'observed' / (decision + '.json')
    if not items and not observation.exists():
        raise LookupError(f'no wake for {decision}; nothing to acknowledge')
    woken = max([item.get('woken') or 0 for item in items] or [0])
    # the same record the watch writes when it takes a wake (T-137)
    return lifeline().acknowledge(root, decision, woken, wakes=len(items))


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


# How long the opener may take (T-145). The code it hands a browser lives 60
# seconds (T-122), and the board's re-login route stops the opener after 60
# (RELOGIN_TIMEOUT_MS in board/server.ts). Every question to a browser has a
# timeout of its own, and the search for a board tab ends by OPENER_BUDGET -
# ASK_OPEN, leaving the new tab its own ASK_OPEN, so the whole run ends inside
# both. A code is minted just before the one question that carries it, so no
# code is older than that question's timeout when a browser gets it.
OPENER_BUDGET, ASK_RUNNING, ASK_TAB, ASK_OPEN = 45, 5, 8, 10


def open_address(address, timeout=ASK_OPEN):
    """Hand an address to the browser, within `timeout` seconds. On macOS it
    goes to osascript on stdin, never in an argument list: `ps` shows every
    process's arguments to every other, and a one-time code read there could
    be redeemed before the captain's browser gets to it."""
    try:
        if sys.platform == 'darwin' and shutil.which('osascript'):
            return subprocess.run([shutil.which('osascript')], input=f'open location "{address}"\n'.encode(),
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout).returncode == 0
        opener = shutil.which('xdg-open') or shutil.which('open')
        if not opener: return False
        return subprocess.call([opener, address], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout) == 0
    except subprocess.TimeoutExpired:
        return False


# The browsers whose tabs fm can find on macOS (T-145), by bundle id, so a
# renamed application is still found, and the family of AppleScript words each
# one speaks. Chrome and Brave share Chromium's; Arc's tab has no index to set.
BOARD_BROWSERS = (('Google Chrome', 'com.google.Chrome', 'chromium'),
                  ('Brave Browser', 'com.brave.Browser', 'chromium'),
                  ('Arc', 'company.thebrowser.Browser', 'arc'),
                  ('Safari', 'com.apple.Safari', 'safari'))


def applescript_string(text):
    return '"' + text.replace('\\', '\\\\').replace('"', '\\"') + '"'


def board_tab_script(bundle, family, url, address):
    """An AppleScript that finds a tab on the board's address - the address
    itself or any page under it, as 127.0.0.1 or as localhost - in one running
    browser, sends that tab to `address`, brings it to the front and prints
    `reused`; finding none, it prints nothing and changes nothing."""
    port = url.rsplit(':', 1)[1]
    bases = [f'http://127.0.0.1:{port}', f'http://localhost:{port}']
    test = ' or '.join(f'u is {applescript_string(b)} or u starts with {applescript_string(b + "/")}' for b in bases)
    front = {'chromium': 'set active tab index of w to i',
             'safari': 'set current tab of w to t',
             'arc': 'tell t to select'}[family]
    return '\n'.join([
        f'tell application id {applescript_string(bundle)}',
        '  repeat with w in windows',
        '    set i to 0',
        '    repeat with t in tabs of w',
        '      set i to i + 1',
        '      set u to ""',
        '      try',
        '        set u to URL of t as text',
        '      end try',
        f'      if {test} then',
        f'        set URL of t to {applescript_string(address)}',
        '        try',
        f'          {front}',
        '          set index of w to 1',
        '        end try',
        '        activate',
        '        return "reused"',
        '      end if',
        '    end repeat',
        '  end repeat',
        'end tell',
        'return ""', ''])


def reuse_board_tab(url, mint, deadline):
    """Send a tab already on the board to a one-time address, and name the
    browser it was in; None when there is none, off macOS, when no browser
    could be scripted, or at `deadline` (time.monotonic()). `mint()` makes
    each address just before the question that carries it. Every script goes
    to osascript on stdin, like open_address's, so the code is never in an
    argument list. Only running browsers are asked, so none is started, and
    each is asked in a script of its own, so one that cannot be scripted, or
    is slow to answer, leaves the others to be asked."""
    osascript = shutil.which('osascript') if sys.platform == 'darwin' else None
    if not osascript: return None
    def ask(script, most):
        left = deadline - time.monotonic()
        if left <= 0: raise subprocess.TimeoutExpired('osascript', 0)
        return subprocess.run([osascript], input=script.encode(), capture_output=True, timeout=min(most, left))
    # The ids are looked up at run time, through a variable: a literal
    # `application id "..."` is resolved when the script compiles, and one
    # browser that is not installed would fail the whole question.
    running = '\n'.join([
        'set found to ""',
        'repeat with b in {' + ', '.join(applescript_string(bundle) for _, bundle, _ in BOARD_BROWSERS) + '}',
        '  try',
        '    if application id (b as text) is running then set found to found & (b as text) & linefeed',
        '  end try',
        'end repeat',
        'return found', ''])
    try: answer = ask(running, ASK_RUNNING)
    except (OSError, subprocess.SubprocessError): return None
    live = set(answer.stdout.decode(errors='replace').split()) if answer.returncode == 0 else set()
    for name, bundle, family in BOARD_BROWSERS:
        if bundle not in live: continue
        if deadline <= time.monotonic(): break
        try: done = ask(board_tab_script(bundle, family, url, mint()), ASK_TAB)
        except (OSError, subprocess.SubprocessError): continue
        if done.returncode == 0 and done.stdout.decode(errors='replace').strip() == 'reused': return name
    return None


def board_open(url, port):
    """Send the captain's browser to a fresh one-time sign-in address (T-122):
    into a tab already on the board when one is found (T-145), else a new one.
    What it says names neither the address nor the code; `tab` says which it
    did: `reused` (with the `browser`) or `new`."""
    opener = shutil.which('osascript') if sys.platform == 'darwin' else None
    opener = opener or shutil.which('xdg-open') or shutil.which('open')
    said = dict(opener_invoked=False, tab=None)
    if not opener:
        said['sign_in_error'] = 'no program to open a browser with was found; nothing was opened'
        return said
    # No code is minted before the search: each is made just before the one
    # question that carries it, and the whole run is bounded (OPENER_BUDGET).
    deadline = time.monotonic() + OPENER_BUDGET - ASK_OPEN
    mint = lambda: board_login_url(url, port)
    try:
        board_secret(port)   # the secret is read first, so a missing one is said before any browser is asked
        browser = reuse_board_tab(url, mint, deadline)
        address = None if browser else mint()
    except (OSError, RuntimeError):
        # said without the path: state/ never names where the secret is
        said['sign_in_error'] = 'the board secret could not be read; restart the board'
        return said
    if browser:
        said.update(opener_invoked=True, tab='reused', browser=browser,
                    said=f"sent the board's open tab in {browser} to a new sign-in and brought it to the front")
    else:
        opened = open_address(address)
        said.update(opener_invoked=opened, tab='new' if opened else None,
                    said='no open board tab was found; opened a new one' if opened
                    else 'the browser could not be asked to open the sign-in address')
    return said


def board_check_port(root, port):
    """An occupied TCP port is usable only after this root's nonce verifies."""
    if not 1 <= port <= 65535:
        raise ValueError('board.port must be between 1 and 65535')
    try:
        with socket.create_connection(('127.0.0.1', port), timeout=2):
            pass
    except ConnectionRefusedError:
        return
    if not board_matches(Path(root).resolve(), f'http://127.0.0.1:{port}'):
        raise RuntimeError(f'board port belongs to an unverified root: http://127.0.0.1:{port}')


def configured_board_port(root):
    try:
        result = subprocess.run(['/bin/bash', '-c', '. "$1"; fm_board_port "$2"',
                                 'fm-board', str(Path(__file__).resolve().parent / 'fm-config.sh'),
                                 str(Path(root) / 'config.yaml')], capture_output=True, text=True)
    except OSError as error:
        raise RuntimeError('board configuration requires /bin/bash') from error
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    port = int(result.stdout.strip())
    if port == 0:
        raise RuntimeError('fm board needs a stable port; FM_PORT=0 is only for a directly started test server')
    return port


def board_start(root):
    root = Path(root).resolve(); port = configured_board_port(root)
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
            # The board outlives this command on purpose, so it names the
            # longer-lived owner it belongs to - the session - and ends with
            # it (T-151). The keeper exports that owner as FM_SESSION_PID,
            # and the merges the board starts belong to the same session.
            owner = lifeline().session_owner()
            with (base / 'board.log').open('ab') as log:
                child = lifeline().start([bun, 'run', str(root / 'board/server.ts')], owner=owner,
                        name='board', cwd=root, env=dict(os.environ, FM_ROOT=str(root), FM_PORT=str(port)),
                        stdin=subprocess.DEVNULL, stdout=log, stderr=log)
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
        # The tab the board is already open in is reused when one is found
        # (T-145), so the captain keeps one tab and it is the one that writes.
        record = dict(root=str(root), url=url, reused=reused, page_http_verified=page,
                      browser_navigation_verified=False, **board_open(url, port))
        if not reused: record['owner'] = owner
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
    # the waiters holding a doorbell now (one killed outright counts until the next ring)
    wake = dict(queue=str(root / WAKE_QUEUE), doorbells=len(list((root / 'state/session/wake.d').glob('*.fifo'))))
    report = dict(root=str(root), runs=runs, wake=wake,
                  pending=[p.name for p in (root / 'state/pending').glob('*.json')],
                  unacknowledged=unacknowledged(root),
                  worktrees=[p.name for p in (root / 'state/worktrees').glob('*') if p.is_dir()])
    events = root / 'state/events.jsonl'
    report['events'] = [json.loads(line) for line in events.read_text().splitlines() if line.strip()] if events.exists() else []
    config = root / 'config.yaml'
    report['configuration'] = config.read_text() if config.exists() else None
    if window_host(root) == 'herdr':
        # a window listing, for people; a Herdr that does not answer is not an error
        base = root / 'state/session'; base.mkdir(parents=True, exist_ok=True)
        try: report['panes'] = Herdr(base)('pane', 'list')
        except (RuntimeError, OSError, ValueError, subprocess.SubprocessError): pass
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


# T-146: the same eleven fields fm-worker.sh and fm-review.sh send
# (fm_crew_identity in bin/fm-config.sh). With only T-116's six here, every
# crew_status a Herdr round emitted carried no vendor or model, and the board,
# reading a crewman from its latest event, showed them as unknown.
IDENTITY_FIELDS = ('name', 'role', 'project', 'task', 'round', 'attempt',
                   'vendor', 'model_requested', 'model', 'cli_version', 'model_mismatch')


def crew_identity(run):
    """A run's identity as the board reads it: the separate fields of its
    identity.json (T-116; vendor and model since T-127, T-146), or None for
    a run that recorded none of them."""
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
    if mode == 'record-model':
        run, vendor, model_requested, model, cli_version = args
        print(json.dumps(record_model(run, vendor, model_requested, model, cli_version))); return 0
    if mode == 'record-requested':
        run, vendor, model_requested = args
        print(json.dumps(record_requested(run, vendor, model_requested))); return 0
    if mode == 'roster':
        try: return roster_command(*args)
        except (OSError, ValueError) as error:
            print('fm roster: ' + str(error), file=sys.stderr); return 65
    if mode == 'board-check-port':
        try: board_check_port(args[0], int(args[1]))
        except (OSError, RuntimeError, ValueError) as error:
            print('fm setup: ' + str(error), file=sys.stderr); return 64
        return 0
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
    if mode == 'board-login':
        # `board-login <port>`: what the board runs for its re-login button
        # (T-145), on its own port. The same opener as `board`, on a board
        # that is already up; what it prints names neither address nor code.
        if len(args) != 1 or not re.fullmatch(r'[1-9][0-9]{0,4}', args[0]) or int(args[0]) > 65535:
            print('fm board-login: usage: board-login <port>', file=sys.stderr); return 64
        said = board_open(f'http://127.0.0.1:{args[0]}', int(args[0]))
        print(json.dumps(said))
        return 69 if said.get('sign_in_error') or not said['opener_invoked'] else 0
    if mode == 'launch': launch(args[0], args[1], args[2:])
    if mode == 'transport': return transport(*args)
    if mode == 'pane-child': return run_supervised(*args)
    if mode == 'follow':
        # `follow <attempt>`, what a window runs, or `follow <root> <actor>`,
        # what `fm.sh follow` runs: the actor's latest round
        if len(args) == 2:
            attempt = latest_attempt(*args)
            if attempt is None: raise ValueError('no round of ' + args[1] + ' to follow')
            args = [attempt]
        return follow(*args)
    if mode == 'stop':
        out = stop_command(args); print(json.dumps(out)); return 1 if out['failed'] else 0
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
        elif action == 'wait':
            timeout = float(rest[1]) if len(rest) > 1 and rest[1] else 0
            # a TERM, INT or HUP unwinds the wait, so its doorbell goes with it
            lifeline()._leave_on_signals()
            items = wake_wait(root, decision, timeout)
            print(json.dumps(items, indent=2))
            print(pending_summary(items), file=sys.stderr)
            return 0 if items else 1
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
            # nothing is started to wait for a wake (T-151): the board rings
            # whoever is waiting, and the queue read above carries the rest
            report['board'] = board_start(root)
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
