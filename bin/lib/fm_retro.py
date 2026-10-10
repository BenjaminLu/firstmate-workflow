#!/usr/bin/env python3
"""Periodic retrospective (T-273).

This module is the one writer of the retro records in the self state:
state/retro/index.json, every run's state.json, the label salt, the board's
requests, the card number reservations and the proposal manifests. Every
read-modify-write holds an exclusive flock on state/retro/index.lock, and no
process takes that lock twice. Facts about merged pull requests come from each
project's own local records; no model runs here. The review rounds run through
the reviewer launcher (bin/fm-review.sh --retro), which calls back into this
module for its prompt and to keep its answer.

Privacy: an external project's names, metrics, prompts, reports and drafts stay
in that project's own private state. Outside it, only the card's own records
and private/labels.json may hold its text; everything else written here passes
the identifying text check first or holds only ids, counts and opaque labels.
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote

sys.dont_write_bytecode = True
CODE = Path(__file__).resolve().parents[2]
if str(CODE / 'bin/lib') not in sys.path:
    sys.path.insert(0, str(CODE / 'bin/lib'))

WEEK = 604800
MERGE_COUNT = 10
CAP = 200_000
CUT = 2_000
FOLLOW_CAP = 50
PARKED_CAP = 50
PARKED_IDS_CAP = 500
REFERENCE_CAP = 100
CARD_CAP = 60
ROUND_ITEMS = 20
GENERIC_CAP = 10
FIRST_CARD = 1000
RUN_RE = re.compile(r'\d{8}T\d{6}Z-[0-9a-f]{6}')
LABEL_RE = re.compile(r'firstmate|self|P-[0-9a-f]{8}')
ITEM_RE = re.compile(r'R[1-9][0-9]{0,3}')
FULL_ITEM_RE = re.compile(r'(firstmate|self|P-[0-9a-f]{8})/(R[1-9][0-9]{0,3})')
CARRIED_RE = re.compile(r'(\d{8}T\d{6}Z-[0-9a-f]{6})/(firstmate|self|P-[0-9a-f]{8})/(R[1-9][0-9]{0,3})')
KINDS = ('process', 'simplify', 'cleanup', 'architecture', 'followup')
EFFECTS = ('removes', 'net-removal', 'adds')
LOCALES = ('en', 'zh-TW')
INT_FIELDS = ('worker_attempts', 'worker_rounds', 'dispatch_to_merge_seconds', 'spec_versions',
              'review_rejections', 'external_findings')
LIST_FIELDS = ('scope_first', 'scope_last', 'scope_added', 'scope_removed')
TASK_FIELDS = INT_FIELDS + LIST_FIELDS + ('standing', 'stops', 'cards')
RED = ('real', 'flaky', 'infrastructure', 'unknown')
STOP_RE = re.compile(r'\bASK-[A-Z][A-Z0-9]*(?:-[A-Z0-9]+)*')
STATES = ('running', 'reviewed', 'awaiting-answer', 'completed', 'failed')


class Refused(Exception):
    """A refusal with the exit code the entry point returns."""

    def __init__(self, message, code=65):
        super().__init__(message)
        self.code = code


class TooLarge(Exception):
    pass


class Unreachable(Exception):
    pass


def crash(point):
    """Test hook: stop dead at a named point, the way a killed process stops."""
    if os.environ.get('FM_RETRO_TEST_CRASH') == point:
        os._exit(86)


# --- time and files ----------------------------------------------------------

def iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def parse_time(text):
    if not isinstance(text, str) or not text:
        return None
    try:
        value = datetime.datetime.fromisoformat(text.replace('Z', '+00:00'))
    except ValueError:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=datetime.timezone.utc)
    return value.timestamp()


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return default


def write_json(path, value):
    """Whole or not at all: a temporary file in the same directory, then rename."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.tmp-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as output:
            json.dump(value, output, ensure_ascii=False, indent=1)
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
        os.replace(name, path)
    except BaseException:
        Path(name).unlink(missing_ok=True)
        raise


def write_text(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.tmp-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as output:
            output.write(text)
        os.replace(name, path)
    except BaseException:
        Path(name).unlink(missing_ok=True)
        raise


def create_json(path, value):
    """Exclusive creation: False when the file already exists."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.tmp-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as output:
            json.dump(value, output, ensure_ascii=False, indent=1)
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
        try:
            os.link(name, path)
        except FileExistsError:
            return False
        return True
    finally:
        Path(name).unlink(missing_ok=True)


def events_of(state):
    path = Path(state) / 'events.jsonl'
    rows = []
    try:
        lines = path.read_text(encoding='utf-8').splitlines()
    except OSError:
        return rows
    for line in lines:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict):
            rows.append(row)
    return rows


# --- the self tree and its lock -----------------------------------------------

_HELD = []


class Retro:
    def __init__(self, engine):
        self.engine = Path(engine).resolve()
        self.state = self.engine / 'state'
        self.dir = self.state / 'retro'
        self.index_path = self.dir / 'index.json'
        self.lock_path = self.dir / 'index.lock'
        self.run_lock = self.dir / 'run.lock'

    def run_dir(self, run):
        if not isinstance(run, str) or not RUN_RE.fullmatch(run):
            raise Refused('bad run id', 64)
        return self.dir / run

    def runs(self):
        if not self.dir.is_dir():
            return []
        return sorted(p.name for p in self.dir.iterdir() if p.is_dir() and RUN_RE.fullmatch(p.name))


class Locked:
    """The index lock. Taking it twice in one process is a bug, never a wait."""

    def __init__(self, retro):
        self.retro = retro
        self.fd = None

    def __enter__(self):
        if _HELD:
            raise RuntimeError('the retro index lock is already held by this process')
        self.retro.dir.mkdir(parents=True, exist_ok=True)
        self.fd = os.open(self.retro.lock_path, os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        _HELD.append(self.fd)
        return self

    def __exit__(self, *exc):
        _HELD.pop()
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)
        return False


def run_lock_free(retro):
    """True when no process holds state/retro/run.lock."""
    if not retro.run_lock.exists():
        return True
    fd = os.open(retro.run_lock, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return False
    finally:
        os.close(fd)
    return True


# --- the index ------------------------------------------------------------------

def load_index(retro):
    index = read_json(retro.index_path)
    if not isinstance(index, dict) or index.get('schema') != 1:
        return None
    return index


def ensure_index(retro, now):
    """Under the lock: write baseline_at once, the first time no index exists."""
    index = load_index(retro)
    if index is None:
        index = dict(schema=1, baseline_at=iso(now), last_completed=None, open_run=None)
        write_json(retro.index_path, index)
    return index


def save_index(retro, index, previous):
    old = (previous or {}).get('last_completed') or {}
    new = index.get('last_completed') or {}
    if old.get('window_end') and new.get('window_end'):
        if parse_time(new['window_end']) < parse_time(old['window_end']):
            raise Refused('window_end only moves forward')
    if old and not new:
        raise Refused('window_end only moves forward')
    write_json(retro.index_path, index)


def window_start(index):
    last = index.get('last_completed')
    return last['window_end'] if last else index['baseline_at']


def clock_start(index):
    last = index.get('last_completed')
    return last['completed_at'] if last else index['baseline_at']


# --- projects -------------------------------------------------------------------

PROJECTS_SH = r'''
code="$1"; engine="$2"
. "$code/bin/fm-config.sh" >/dev/null 2>&1 || exit 70
names=''
if [ -f "$engine/config.yaml" ]; then
  names="$(fm_projects "$engine/config.yaml")" || exit 65
fi
if [ -z "$names" ]; then
  jq -cn --arg e "$engine" '{name:"",external:false,ok:true,state:($e+"/state"),tasks:($e+"/design/tasks"),github:"",base:"main",reviewers:[]}'
  exit 0
fi
for name in $names; do
  (
    unset FM_EXTERNAL FM_PROJECT GH_REPO FM_STATE_DIR FM_TASKS_DIR FM_BASE FM_DESIGN FM_TARGET_ROOT
    repo="$(fm_project_get "$name" repo "$engine/config.yaml" 2>/dev/null)"
    external=false; [ "$repo" = . ] || external=true
    if fm_storage_init "$engine" "$name" >/dev/null 2>&1; then
      github="${GH_REPO:-$(fm_project_get "$name" github "$FM_CONFIG" 2>/dev/null)}"
      base="$(fm_project_get "$name" base "$engine/config.yaml" 2>/dev/null)"
      reviewers='[]'
      if [ "$FM_EXTERNAL" = 1 ]; then
        reviewers="$(fm_conventions reviewers 2>/dev/null)" || reviewers='[]'
        jq -e 'type == "array"' >/dev/null 2>&1 <<<"$reviewers" || reviewers='[]'
      fi
      jq -cn --arg n "$name" --argjson x "$external" --arg s "$FM_STATE_DIR" --arg t "$FM_TASKS_DIR" \
        --arg g "$github" --arg b "${base:-main}" --argjson r "$reviewers" \
        '{name:$n,external:$x,ok:true,state:$s,tasks:$t,github:$g,base:$b,reviewers:[$r[]|strings]}'
    else
      jq -cn --arg n "$name" --argjson x "$external" '{name:$n,external:$x,ok:false}'
    fi
  )
done
'''

GITHUB_SH = r'''
code="$1"; engine="$2"; name="$3"; endpoint="$4"
. "$code/bin/fm-config.sh" >/dev/null 2>&1 || exit 70
fm_storage_init "$engine" "$name" >/dev/null 2>&1 || exit 65
fm_github api "$endpoint"
'''

CONFIG_SH = r'''
code="$1"; engine="$2"
. "$code/bin/fm-config.sh" >/dev/null 2>&1 || exit 70
printf '%s\n%s\n' "$(fm_cfg_in retro vendor "$engine/config.yaml" 2>/dev/null)" "$(fm_cfg_in retro model "$engine/config.yaml" 2>/dev/null)"
'''

KEEP_ENV = ('FM_HOME', 'FM_GH', 'FM_GH_TIMEOUT', 'FM_GH_RETRY_DELAYS', 'FM_GITHUB_URL')


def clean_env():
    """Never the caller's project: each project is read by naming it."""
    return {k: v for k, v in os.environ.items()
            if (not k.startswith('FM_') or k in KEEP_ENV) and k != 'GH_REPO'}


def load_projects(retro):
    result = subprocess.run(['bash', '-c', PROJECTS_SH, 'fm-retro', str(CODE), str(retro.engine)],
                            env=clean_env(), capture_output=True, text=True, timeout=600)
    if result.returncode:
        raise Refused('cannot read the project registry', 65)
    projects = []
    for line in result.stdout.splitlines():
        if line.strip():
            projects.append(json.loads(line))
    if not any(not p['external'] for p in projects):
        raise Refused('config.yaml registers no self project', 65)
    return projects


def retro_config(retro):
    result = subprocess.run(['bash', '-c', CONFIG_SH, 'fm-retro', str(CODE), str(retro.engine)],
                            env=clean_env(), capture_output=True, text=True, timeout=120)
    vendor, model = (result.stdout.split('\n') + ['', ''])[:2]
    for key, value in (('retro.vendor', vendor), ('retro.model', model)):
        if not value.strip():
            raise Refused('config.yaml has no ' + key + '; a retrospective uses no other vendor', 65)
    return vendor.strip(), model.strip()


def salt(retro):
    path = retro.dir / 'salt'
    if not path.exists():
        retro.dir.mkdir(parents=True, exist_ok=True)
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            pass
        else:
            with os.fdopen(fd, 'w') as output:
                output.write(secrets.token_hex(16) + '\n')
    return path.read_text().strip()


def label_for(secret, name):
    return 'P-' + hashlib.sha256((secret + '\n' + name).encode()).hexdigest()[:8]


def labels(retro, projects):
    secret = salt(retro)
    result = {}
    for p in projects:
        result['self' if not p['external'] else label_for(secret, p['name'])] = p['name']
    return result


def run_labels(retro, run):
    return read_json(retro.run_dir(run) / 'private/labels.json', {}) or {}


def project_of(projects, name):
    return next((p for p in projects if p['name'] == name), None)


def private_dir(retro, run, label, project):
    if label == 'firstmate':
        return retro.run_dir(run) / 'cross'
    if label == 'self':
        return retro.run_dir(run) / 'projects/self'
    return Path(project['state']) / 'retro' / run


def evidence_project(project, retro):
    if project['name']:
        return project['name']
    return 'self'


# --- the identifying text check -------------------------------------------------

def fm_home(retro):
    configured = ''
    try:
        for raw in (retro.engine / 'config.yaml').read_text().splitlines():
            match = re.match(r'home:\s*(\S+)', raw)
            if match:
                configured = match[1]
    except OSError:
        pass
    return Path(os.environ.get('FM_HOME', configured or '~/.firstmate')).expanduser()


class Check:
    """True when text names an external project, its repository, owner,
    reviewers or private paths."""

    def __init__(self, retro, projects):
        import fm_private_names as private
        self.private = private
        words = set()
        config = retro.engine / 'config.yaml'
        if config.is_file():
            try:
                words.update(private.names(config, fm_home(retro)))
            except (ValueError, OSError, ImportError, AttributeError, TypeError):
                pass
        paths = set()
        for p in projects:
            if not p.get('external'):
                continue
            words.add(p['name'])
            words.update(p.get('reviewers') or [])
            for key in ('state', 'tasks'):
                if p.get(key):
                    paths.add(p[key])
        self.words = sorted({w.lower() for w in words if isinstance(w, str) and len(w) >= 2}, key=len, reverse=True)
        self.paths = sorted(paths)
        self.digests = {private.digest(w) for w in self.words}
        file = retro.engine / private.DIGEST_FILE
        try:
            self.digests |= private._digests(file.read_text())
        except (OSError, ValueError):
            pass
        self.patterns = [re.compile(r'(?<![A-Za-z0-9])' + re.escape(w) + r'(?![A-Za-z0-9])', re.I)
                         for w in self.words]

    def __call__(self, value):
        if isinstance(value, dict):
            return any(self(k) or self(v) for k, v in value.items())
        if isinstance(value, (list, tuple)):
            return any(self(v) for v in value)
        if not isinstance(value, str):
            return False
        if any(path in value for path in self.paths):
            return True
        if any(pattern.search(value) for pattern in self.patterns):
            return True
        for line in value.splitlines() or [value]:
            if any(self.private.digest(token) in self.digests for token in self.private._tokens(line)):
                return True
        return False


REDACTED = '[REDACTED: identifying text]'


def redact(value, check):
    """A copy that passes the check: a string that fails it becomes REDACTED,
    a key that fails it becomes 'REDACTED' (integer counts under it add up).
    Nothing is refused, so a redaction never fails a run."""
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            name = 'REDACTED' if isinstance(key, str) and check(key) else key
            item = redact(item, check)
            if name in out and type(out[name]) is int and type(item) is int:
                out[name] += item
            else:
                out[name] = item
        return out
    if isinstance(value, (list, tuple)):
        return [redact(v, check) for v in value]
    if isinstance(value, str) and check(value):
        return REDACTED
    return value


def withheld_text(path, check):
    """Replace one retained file that names an external project; True if it did."""
    try:
        text = Path(path).read_text(encoding='utf-8', errors='ignore')
    except OSError:
        return False
    if not check(text):
        return False
    write_text(path, '[withheld by the retrospective: this file named an external project]\n')
    return True


def contain(retro, run_dir, projects):
    """A self or cross round's run directory sits in the self state, where no
    external project's text may stay: every retained file that names one (the
    transport's raw answer and logs) is replaced. Returns how many were."""
    check = Check(retro, projects)
    count = 0
    root = Path(run_dir)
    for path in sorted(root.rglob('*')) if root.is_dir() else []:
        if path.is_file() and not path.is_symlink():
            count += withheld_text(path, check)
    return count


def deny_paths(retro, projects, own=None):
    """The state directories a round may never read, written without naming any
    other external project: another project's private state is denied through
    its nearest ancestor that passes the check (the read allowlist already
    leaves it unreadable when no such ancestor is safe to deny)."""
    check = Check(retro, projects)
    keep = [Path(p).resolve() for p in (Path.home(), retro.engine, CODE, tempfile.gettempdir())]
    never = {str(retro.state)}
    for p in projects:
        if not p.get('ok') or not p.get('external') or not p.get('state'):
            continue
        if own is not None and p['name'] == own:
            never.add(p['state'])
            continue
        for candidate in Path(p['state']).parents:
            if check(str(candidate)):
                continue
            if candidate == Path(candidate.anchor) or any(k == candidate or k.is_relative_to(candidate) for k in keep):
                break
            never.add(str(candidate))
            break
    return sorted(never)


# --- metrics ----------------------------------------------------------------------

def merged_events(events, start, end=None):
    seen = {}
    for event in events:
        if event.get('type') != 'merged':
            continue
        ts, pr = parse_time(event.get('ts')), event.get('pr')
        if ts is None or type(pr) is not int:
            continue
        if ts > start and (end is None or ts <= end) and pr not in seen:
            seen[pr] = event
    return sorted(seen.values(), key=lambda e: (parse_time(e['ts']), e['pr']))


def status_token(body):
    text = body.strip().lstrip('*_')
    match = re.match(r'[A-Za-z-]+', text)
    return match[0].lower() if match else ''


def standing(records, task):
    from fm_evidence import criteria
    counts = {}
    for record in records:
        if record.get('kind') != 'verdict':
            continue
        items = criteria(record.get('text') or '', task)
        if not items:
            return None
        for number, body in items:
            token = status_token(body)
            if token not in ('open', 'done', 'ok'):
                return None
            counts.setdefault(number, 0)
            if token == 'open':
                counts[number] += 1
    return [dict(n=n, open_rounds=counts[n]) for n in sorted(counts)]


def stop_category(text):
    match = STOP_RE.search(text or '')
    if match:
        return match[0]
    if 'WORKER_BLOCKED' in (text or ''):
        return 'WORKER_BLOCKED'
    return None


def pins_of(state, task):
    directory = Path(state) / 'pins' / task
    if not directory.is_dir() or directory.is_symlink():
        return []
    files = sorted((p for p in directory.glob('*.json') if p.stem.isdigit() and not p.is_symlink()),
                   key=lambda p: int(p.stem))
    texts = []
    for file in files:
        pin = read_json(file)
        try:
            text = pin['snapshots']['spec']['text']
        except (TypeError, KeyError):
            continue
        if isinstance(text, str):
            texts.append(text)
    return texts


def scope_of(text):
    try:
        scope = json.loads(text).get('scope')
    except (ValueError, AttributeError):
        return None
    if isinstance(scope, list) and all(isinstance(x, str) for x in scope):
        return list(scope)
    return None


def evidence_records(state, project, task, external):
    from fm_evidence import Store
    try:
        store = Store(state, project, task, external=external)
        records = store.records()
        paths = sorted(store.directory.glob('[0-9]*.json'))
    except (ValueError, OSError, KeyError, TypeError):
        return None, []
    names = [p.name for p in paths] if len(paths) == len(records) else [''] * len(records)
    return records, names


def ci_metrics(api, repo, pr):
    """GitHub Actions history of one pull request, by GET requests only."""
    try:
        if not repo:
            raise Unreachable('no repository')
        pull = api(f'repos/{repo}/pulls/{pr}')
        branch = (pull.get('head') or {}).get('ref')
        if not branch:
            raise Unreachable('no head branch')
        runs = []
        for page in range(1, 11):
            body = api(f'repos/{repo}/actions/runs?branch={quote(branch, safe="")}&per_page=100&page={page}')
            batch = body.get('workflow_runs') or []
            runs.extend(batch)
            if len(batch) < 100:
                break
        else:
            return None, 'truncated'
        if not runs:
            history = api(f'repos/{repo}/actions/runs?per_page=1')
            if not history.get('total_count'):
                return None, 'no actions history'
    except (Unreachable, ValueError, KeyError, TypeError, AttributeError):
        return None, 'unreachable'
    return classify(api, repo, pr, runs), None


def classify(api, repo, pr, runs):
    # one entry per distinct run id: a run listed twice (pages shift while they
    # are read) counts once, at its latest attempt
    attempt_of = lambda r: r['run_attempt'] if type(r.get('run_attempt')) is int and r['run_attempt'] > 0 else 1
    distinct = {}
    for r in runs:
        if not any(isinstance(p, dict) and p.get('number') == pr for p in r.get('pull_requests') or []):
            continue
        key = r.get('id') if r.get('id') is not None else ('no-id', len(distinct))
        if key not in distinct or attempt_of(r) > attempt_of(distinct[key]):
            distinct[key] = r
    kept = list(distinct.values())
    kept.sort(key=lambda r: (r.get('created_at') or '', r.get('id') or 0))
    red = dict.fromkeys(RED, 0)
    reruns = 0
    attempts = {}
    for run in kept:
        count = run.get('run_attempt') if type(run.get('run_attempt')) is int and run['run_attempt'] > 0 else 1
        reruns += count - 1
        rows = []
        for k in range(1, count + 1):
            try:
                attempt = api(f'repos/{repo}/actions/runs/{run["id"]}/attempts/{k}')
                rows.append(dict(conclusion=attempt.get('conclusion'),
                                 head_sha=attempt.get('head_sha') or run.get('head_sha')))
            except (Unreachable, ValueError, KeyError, TypeError, AttributeError):
                rows.append(None)
        attempts[run['id']] = rows
    for position, run in enumerate(kept):
        rows = attempts[run['id']]
        for k, row in enumerate(rows):
            if row is None:
                red['unknown'] += 1
                continue
            if row['conclusion'] not in ('failure', 'cancelled', 'timed_out'):
                continue
            if row['conclusion'] in ('cancelled', 'timed_out'):
                red['infrastructure'] += 1
            elif any(later and later['conclusion'] == 'success' for later in rows[k + 1:]):
                red['flaky'] += 1
            elif real_failure(kept, attempts, position, run, row):
                red['real'] += 1
            else:
                red['unknown'] += 1
    return dict(red=red, reruns=reruns)


def real_failure(kept, attempts, position, run, row):
    same = [r for r in kept if r.get('workflow_id') == run.get('workflow_id')]
    failed_head = row['head_sha']
    if any(a and a['head_sha'] == failed_head and a['conclusion'] == 'success'
           for r in same for a in attempts[r['id']]):
        return False
    return any(a and a['head_sha'] != failed_head and a['conclusion'] == 'success'
               for r in kept[position + 1:] if r.get('workflow_id') == run.get('workflow_id')
               for a in attempts[r['id']])


def github_api(retro, project):
    def call(endpoint):
        result = subprocess.run(['bash', '-c', GITHUB_SH, 'fm-retro', str(CODE), str(retro.engine),
                                 project['name'], endpoint],
                                env=clean_env(), capture_output=True, text=True, timeout=900)
        if result.returncode:
            raise Unreachable('GitHub request failed')
        return json.loads(result.stdout)
    return call


def task_row(project, events, merged, api, retro):
    state, external = Path(project['state']), project['external']
    task = merged.get('task') if isinstance(merged.get('task'), str) and merged.get('task') else None
    if task is not None and not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*', task):
        task = None
    merged_ts = parse_time(merged['ts'])
    row = dict(pr=merged['pr'], task=task, merged_at=iso(merged_ts))
    for field in TASK_FIELDS:
        row[field] = None
    if task is not None:
        dispatches = [e for e in events if e.get('type') == 'dispatched' and e.get('task') == task
                      and str(e.get('actor') or '').startswith('worker-')]
        row['worker_attempts'] = len(dispatches)
        rounds, unread = set(), False
        for actor in {e['actor'] for e in dispatches}:
            identity = read_json(state / 'runs' / actor / 'identity.json') \
                if re.fullmatch(r'[A-Za-z0-9_-]+', actor) else None
            if isinstance(identity, dict) and type(identity.get('round')) is int:
                rounds.add(identity['round'])
            else:
                unread = True
        # one unreadable identity makes the count unknown, never a partial number
        row['worker_rounds'] = None if unread else len(rounds)
        times = [t for t in (parse_time(e.get('ts')) for e in dispatches) if t is not None]
        row['dispatch_to_merge_seconds'] = int(merged_ts - min(times)) if times and merged_ts >= min(times) else None
        texts = pins_of(state, task)
        if texts:
            row['spec_versions'] = len({hashlib.sha256(t.encode()).hexdigest() for t in texts})
            first, last = scope_of(texts[0]), scope_of(texts[-1])
            if first is not None and last is not None:
                row['scope_first'], row['scope_last'] = first, last
                row['scope_added'] = sorted(set(last) - set(first))
                row['scope_removed'] = sorted(set(first) - set(last))
        records, _ = evidence_records(state, evidence_project(project, retro), task, external)
        if records is not None:
            row['review_rejections'] = sum(r.get('kind') == 'verdict' and r.get('verdict') == 'REJECT' for r in records)
            if external:
                ids = {json.dumps(f.get('id')) for r in records if r.get('kind') == 'external-verdict'
                       for f in r.get('findings') or [] if isinstance(f, dict) and f.get('id') is not None}
                row['external_findings'] = len(ids)
            stops = {}
            for record in records:
                if record.get('kind') == 'ask':
                    category = stop_category(record.get('text'))
                    if category:
                        stops[category] = stops.get(category, 0) + 1
            row['stops'] = stops
            row['standing'] = standing(records, task)
        cards = []
        directory = state / 'decisions'
        if directory.is_dir():
            for file in sorted(directory.glob('*.json')):
                record = read_json(file)
                if isinstance(record, dict) and record.get('task') == task:
                    cards.append(dict(id=record.get('id'), purpose=record.get('purpose'), chosen=record.get('chosen')))
        row['cards'] = cards
    row['ci'], row['ci_reason'] = ci_metrics(api, project.get('github') or '', merged['pr']) if api else (None, 'unreachable')
    row['unknown'] = [field for field in ('task',) + TASK_FIELDS + ('ci',) if row[field] is None]
    ordered = ('pr', 'task', 'merged_at') + TASK_FIELDS + ('ci', 'ci_reason', 'unknown')
    return {field: row[field] for field in ordered}


def totals(rows):
    result = {}
    for field in INT_FIELDS:
        known = [r[field] for r in rows if r[field] is not None]
        result[field] = dict(sum=sum(known), known_rows=len(known))
    stops = {}
    with_stops = [r['stops'] for r in rows if r['stops'] is not None]
    for category in sorted({c for s in with_stops for c in s}):
        stops[category] = dict(sum=sum(s.get(category, 0) for s in with_stops), known_rows=len(with_stops))
    result['stops'] = stops
    with_ci = [r['ci'] for r in rows if r['ci'] is not None]
    ci = {k: dict(sum=sum(c['red'][k] for c in with_ci), known_rows=len(with_ci)) for k in RED}
    ci['reruns'] = dict(sum=sum(c['reruns'] for c in with_ci), known_rows=len(with_ci))
    result['ci'] = ci
    return result


def metrics_doc(run, label, start, end, rows, generated):
    return dict(schema=1, run_id=run, project_label=label, window=dict(start=start, end=end),
                generated_at=generated, prs=rows, totals=totals(rows))


def metrics_md(doc):
    fields = ('pr', 'task', 'merged_at') + TASK_FIELDS + ('ci', 'ci_reason', 'unknown')
    cell = lambda v: json.dumps(v, ensure_ascii=False, separators=(',', ':')).replace('|', '\\|')
    lines = ['# Retro metrics ' + doc['project_label'], '',
             'Window: ' + doc['window']['start'] + ' to ' + doc['window']['end'], '',
             '| ' + ' | '.join(fields) + ' |', '|' + '---|' * len(fields)]
    for row in doc['prs']:
        lines.append('| ' + ' | '.join(cell(row[f]) for f in fields) + ' |')
    lines += ['', '## Totals', '', '| field | sum | known_rows |', '|---|---|---|']
    for field in INT_FIELDS:
        lines.append(f"| {field} | {doc['totals'][field]['sum']} | {doc['totals'][field]['known_rows']} |")
    for category, value in doc['totals']['stops'].items():
        lines.append(f"| stops.{category} | {value['sum']} | {value['known_rows']} |")
    for key, value in doc['totals']['ci'].items():
        lines.append(f"| ci.{key} | {value['sum']} | {value['known_rows']} |")
    return '\n'.join(lines) + '\n'


def compute_metrics(retro, project, run, label, start, end, now, api=None, check=None):
    """check: given for a file outside the project's own private state (the
    self project's, in the self tree): every field that names an external
    project is redacted before anything is written or totalled."""
    events = events_of(project['state'])
    rows = [task_row(project, events, merged, api, retro) for merged in merged_events(events, parse_time(start), parse_time(end))]
    if check is not None:
        rows = [redact(row, check) for row in rows]
    return metrics_doc(run, label, start, end, rows, iso(now))


# --- the anonymous projection -----------------------------------------------------

def project_rows(doc, check):
    rows = []
    for number, row in enumerate(doc.get('prs') or [], 1):
        length = lambda v: len(v) if isinstance(v, list) else None
        stops = None
        if isinstance(row.get('stops'), dict):
            stops = {}
            for category, count in row['stops'].items():
                name = category if (re.fullmatch(r'ASK-[A-Z0-9-]+|WORKER_BLOCKED', category) and not check(category)) else 'REDACTED'
                stops[name] = stops.get(name, 0) + count
        cards = None
        if isinstance(row.get('cards'), list):
            counted = {}
            for card in row['cards']:
                purpose = card.get('purpose') if isinstance(card.get('purpose'), str) and re.fullmatch(r'[a-z-]{1,20}', card['purpose']) else None
                chosen = card.get('chosen') if isinstance(card.get('chosen'), str) and re.fullmatch(r'[A-Za-z-]{1,10}', card['chosen']) else None
                # a value the syntax allows may still name a project
                purpose = 'REDACTED' if purpose is not None and check(purpose) else purpose
                chosen = 'REDACTED' if chosen is not None and check(chosen) else chosen
                key = (purpose, chosen)
                counted[key] = counted.get(key, 0) + 1
            cards = [dict(purpose=p, chosen=c, count=n) for (p, c), n in sorted(counted.items(), key=lambda x: (str(x[0][0]), str(x[0][1])))]
        rows.append(dict(row=number, merged_at=row.get('merged_at'),
                         **{f: row.get(f) if type(row.get(f)) is int else None for f in INT_FIELDS},
                         scope_first=length(row.get('scope_first')), scope_last=length(row.get('scope_last')),
                         scope_added=length(row.get('scope_added')), scope_removed=length(row.get('scope_removed')),
                         standing=[dict(n=s['n'], open_rounds=s['open_rounds']) for s in row['standing']]
                         if isinstance(row.get('standing'), list) else None,
                         stops=stops, cards=cards,
                         ci=dict(red={k: row['ci']['red'][k] for k in RED}, reruns=row['ci']['reruns'])
                         if isinstance(row.get('ci'), dict) else None,
                         ci_reason=row.get('ci_reason') if row.get('ci_reason') in ('truncated', 'no actions history', 'unreachable') else None))
    return rows


def projection(label, doc, check):
    rows = project_rows(doc, check) if doc else []
    return dict(label=label, rows=rows)


# --- report format -------------------------------------------------------------------

class ReportError(Exception):
    pass


def item_rank(item):
    return (EFFECTS.index(item['effect']), int(item['id'][1:]))


def blocks(answer):
    found, inside, lines = [], None, []
    for line in answer.splitlines():
        if inside is None:
            match = re.fullmatch(r'\s*(`{3,})\s*retro-items\s*', line)
            if match:
                inside, lines = match[1], []
        elif re.fullmatch(r'\s*' + inside + r'`*\s*', line):
            found.append('\n'.join(lines))
            inside = None
        else:
            lines.append(line)
    if inside is not None:
        raise ReportError('unclosed retro-items block')
    return found


def strings(value, low, high, field, limit=2000):
    if not isinstance(value, list) or not low <= len(value) <= high:
        raise ReportError(f'{field}: expected {low} to {high} strings')
    for text in value:
        if not isinstance(text, str) or not text.strip() or len(text) > limit:
            raise ReportError(f'{field}: expected nonempty strings')


def text_field(value, field):
    if not isinstance(value, str) or not value.strip() or len(value) > 2000:
        raise ReportError(field + ': expected nonempty text')


def parse_report(answer, cross=False):
    found = blocks(answer)
    if not found:
        raise ReportError('no retro-items block')
    if len(found) > 1:
        raise ReportError('more than one retro-items block')
    try:
        data = json.loads(found[0])
    except ValueError:
        raise ReportError('invalid JSON')
    if not isinstance(data, dict) or data.get('schema') != 1 or not isinstance(data.get('items'), list):
        raise ReportError('wrong schema')
    generic = data.get('generic', [])
    if not isinstance(generic, list) or len(generic) > GENERIC_CAP:
        raise ReportError('more than 10 generic statements')
    for text in generic:
        if not isinstance(text, str) or not text.strip() or len(text) > 2000:
            raise ReportError('generic: expected nonempty strings')
    items = data['items']
    if len(items) > ROUND_ITEMS:
        raise ReportError('more than 20 items')
    seen = set()
    for item in items:
        if not isinstance(item, dict):
            raise ReportError('items: expected objects')
        if not isinstance(item.get('id'), str) or not ITEM_RE.fullmatch(item['id']):
            raise ReportError('items.id: expected R1, R2, ...')
        if item['id'] in seen:
            raise ReportError('duplicate id ' + item['id'])
        seen.add(item['id'])
        if item.get('kind') not in KINDS:
            raise ReportError('items.kind: unknown kind')
        carried = item.get('carried_from')
        if carried is not None and (not isinstance(carried, str) or not CARRIED_RE.fullmatch(carried)):
            raise ReportError('items.carried_from: expected null or <run-id>/<label>/<id>')
        if item.get('effect') not in EFFECTS:
            raise ReportError('items.effect: expected removes, net-removal or adds')
        strings(item.get('removes'), 0 if item['effect'] == 'adds' else 1, 20, item['id'] + '.removes')
        for lang in LOCALES:
            loc = item.get(lang)
            if not isinstance(loc, dict):
                raise ReportError(item['id'] + ': missing locale ' + lang)
            for key in ('title', 'why', 'how'):
                text_field(loc.get(key), f'{item["id"]}.{lang}.{key}')
            strings(loc.get('evidence'), 1, 10, f'{item["id"]}.{lang}.evidence')
            strings(loc.get('scope', []), 0, 20, f'{item["id"]}.{lang}.scope', 200)
            if item['effect'] == 'adds':
                if not isinstance(loc.get('why_not_removal'), str) or not loc['why_not_removal'].strip():
                    raise ReportError(f'{item["id"]}.{lang}: an adds item needs why_not_removal')
                text_field(loc['why_not_removal'], f'{item["id"]}.{lang}.why_not_removal')
    if [item_rank(i) for i in items] != sorted(item_rank(i) for i in items):
        raise ReportError('items out of the removal-first order')
    clean = []
    for item in items:
        kept = dict(id=item['id'], kind=item['kind'], carried_from=item.get('carried_from'),
                    effect=item['effect'], removes=list(item['removes']))
        for lang in LOCALES:
            loc = item[lang]
            kept[lang] = dict(title=loc['title'], why=loc['why'], how=loc['how'],
                              evidence=list(loc['evidence']), scope=list(loc.get('scope', [])))
            if item['effect'] == 'adds':
                kept[lang]['why_not_removal'] = loc['why_not_removal']
        clean.append(kept)
    return dict(items=clean, generic=[] if cross else list(generic))


# --- prompts --------------------------------------------------------------------------

PLAIN_RULES = """Plain-writing rules:
- Write for a backend engineer with 3 to 5 years' experience who is new to this repository.
- Explain each term on first use.
- Never use an internal code (a task id, a rule id) as the subject of a sentence.
- Keep numbers apart from words.
- Give every item a why and a how."""

CARD_RULES = """The card checker refuses text that breaks these sentence rules, so keep every title, why, how and why_not_removal short:
- At most 25 words in each sentence (at most 30 characters in each zh-TW sentence) and at most 25 words in a title.
- Active voice. No will, would, could, should, shall or might.
- None of: ensure, utilize, perform, require, via, obtain, additional, attempt, indicate, modify, some, various, relevant, appropriate, properly, etc.
- zh-TW: none of 將, 應該, 可能, 一些, 相關, 等等, 被."""


def plain_rules(retro):
    path = retro.engine / 'skills/firstmate/plain-writing.md'
    try:
        return 'Plain-writing rules (skills/firstmate/plain-writing.md):\n' + path.read_text(encoding='utf-8')
    except OSError:
        return PLAIN_RULES


def header(retro, run, label, cross, base):
    scope = 'every project, anonymised' if cross else 'one project, labelled ' + label
    questions = ("""Answer for patterns seen in more than one project:
(a) what went wrong in the process from task to merge;
(b) from first principles, what simpler or more fundamental solution would have avoided it, looking first for something to delete or simplify;
(d) after re-reading firstmate's architecture in design/design.md and design/diagrams/, which parts are wrong, redundant or could be simpler;
(e) for each approved 'firstmate' item below, whether the related metrics improved.
Every item you propose here is labelled 'firstmate'. Leave generic empty.""" if cross else """Answer for this project:
(a) what went wrong in the process from task to merge;
(b) from first principles, what simpler or more fundamental solution would have avoided it, looking first for something to delete or simplify;
(c) which firstmate tests, scripts or skills are obsolete or replaced, with evidence such as no remaining caller, coverage duplicated by another named test, or a named newer part that replaced it;
(d) after re-reading firstmate's architecture in design/design.md and design/diagrams/, which parts are wrong, redundant or could be simpler;
(e) for each approved item below, whether the related metrics improved.
generic holds 0 to 10 patterns for the cross-project round, stated without any project, repository, owner, reviewer, company or path name.""")
    return f"""# Retrospective round {run} ({scope})

You are the reviewer in firstmate's periodic retrospective. The checkout is the
engine at commit {base}; the project's own repository is not checked out, and
the questions are about how firstmate worked on it. Every input is below;
no state directory is readable.

You propose; you never delete, edit, commit or dispatch. A cleanup finding
names the files and the evidence. A finding that needs a captain decision about
direction says so and asks the question instead of proposing a change.

{questions}

Give evidence for every finding: a metric field, a pull request, an evidence
reference, or a file:line in the engine.

Removal first. Every item states what it deletes or simplifies (removes): code,
tests, rules, steps or files, named concretely. effect is 'removes' when it only
removes or simplifies, 'net-removal' when it removes more than it adds, and
'adds' when it adds protocol surface (a rule, command, file format, state,
field, gate, card type or check); an 'adds' item says in why_not_removal why a
simpler removal cannot solve the problem. Order items: removes first, then
net-removal, then adds, each group by id (R1, R2, ...).

Your final answer holds a readable report and exactly one fenced block whose
info string is retro-items, holding JSON:
{{"schema":1,"items":[{{"id":"R1","kind":"process|simplify|cleanup|architecture|followup",
"carried_from":null,"effect":"removes|net-removal|adds","removes":["..."],
"en":{{"title":"...","why":"...","how":"...","evidence":["..."],"scope":["path"]}},
"zh-TW":{{"title":"...","why":"...","how":"...","evidence":["..."],"scope":["path"]}}}}],
"generic":["..."]}}
At most 20 items. carried_from names '<run-id>/<label>/<id>' when an item repeats a parked one.
An 'adds' item adds why_not_removal to both locales.

{plain_rules(retro)}

{CARD_RULES}

End the answer with the line REVIEWER_COMPLETE:retro
"""


OPTIONAL_HEADING = '\n## Optional texts\n'


def drop_line(references, room=None):
    """The one drop summary: how many optional texts were left out, and at most
    100 of their references - fewer when room (characters) is smaller."""
    def render(shown):
        text = f'Left out: {len(references)} optional texts.'
        if shown:
            text += ' References: ' + ', '.join(shown)
            if len(references) > len(shown):
                text += f' and {len(references) - len(shown)} more'
            text += '.'
        return '\n## Left out\n' + text + '\n'
    shown = list(references[:REFERENCE_CAP])
    if room is not None:
        while shown and len(render(shown)) > room:
            shown.pop()
    return render(shown)


def cut(text, limit=CUT):
    if len(text) <= limit:
        return text
    return text[:limit] + f'\n[cut: kept {limit} of {len(text)} characters]'


def assemble(head, mandatory, optional):
    """mandatory: text. optional: [(reference, text)], newest first, so the
    oldest pull request's texts are the first left out. Every character is
    counted before it is added - the optional heading, each text and the drop
    summary for what would be left - so a prompt whose mandatory part fits is
    never refused: optional texts are left out instead."""
    base = head + mandatory
    references = [reference for reference, _ in optional]
    if len(base) + len(drop_line(references, 0)) > CAP:
        raise TooLarge('inputs too large')
    kept, used = [], len(base)
    for position, (reference, text) in enumerate(optional):
        piece = f'\n### {reference}\n{cut(text)}\n'
        heading = 0 if kept else len(OPTIONAL_HEADING)
        if used + heading + len(piece) + len(drop_line(references[position + 1:], 0)) > CAP:
            break
        kept.append(piece)
        used += heading + len(piece)
    body = base + (OPTIONAL_HEADING + ''.join(kept) if kept else '')
    return body + drop_line(references[len(kept):], CAP - len(body))


def mandatory_text(metrics_text, followups, parked, metrics_title='Metrics (metrics.json)'):
    shown_follow = followups[:FOLLOW_CAP]
    parts = [f'\n## {metrics_title}\n```json\n{metrics_text}\n```\n',
             '\n## Approved items awaiting follow-up\n']
    if not shown_follow:
        parts.append('None.\n')
    for item in shown_follow:
        parts.append(json.dumps(item, ensure_ascii=False, indent=1) + '\n')
    if len(followups) > FOLLOW_CAP:
        parts.append(f'Follow-up items not shown: {len(followups) - FOLLOW_CAP}.\n')
    parts.append('\n## Parked items\n')
    full, older = parked[:PARKED_CAP], parked[PARKED_CAP:]
    if not full:
        parts.append('None.\n')
    for item in full:
        parts.append(json.dumps(item, ensure_ascii=False, indent=1) + '\n')
    if older:
        ids = [item['full_id'] for item in older[:PARKED_IDS_CAP]]
        parts.append('\n## Older parked item ids\n' + '\n'.join(ids) + '\n')
        if len(older) > PARKED_IDS_CAP:
            parts.append(f'Older parked items not listed: {len(older) - PARKED_IDS_CAP}.\n')
    return ''.join(parts)


# --- follow-up and parked items -------------------------------------------------------

def completed_runs(retro, before=None):
    result = []
    for run in retro.runs():
        if before is not None and run >= before:
            continue
        state = read_json(retro.run_dir(run) / 'state.json', {}) or {}
        answers = read_json(retro.run_dir(run) / 'answers.json')
        if state.get('state') == 'completed' and isinstance(answers, dict):
            result.append((run, answers))
    return result


def superseded(retro):
    gone = set()
    for _, answers in completed_runs(retro):
        gone.update(answers.get('supersedes') or [])
    return gone


def followed(retro):
    done = set()
    for run, _ in completed_runs(retro):
        done.update((read_json(retro.run_dir(run) / 'followed.json', {}) or {}).get('ids') or [])
    return done


def parked_entries(retro, run):
    """An earlier run's answers, or - for a run that never completed - only
    the items its card had no room for: those were parked as 'card full' the
    moment the card was raised, whatever became of the card."""
    state = run_state(retro, run)
    answers = read_json(retro.run_dir(run) / 'answers.json')
    if state.get('state') == 'completed' and isinstance(answers, dict):
        return answers.get('items') or []
    overflow = (read_json(retro.run_dir(run) / 'overflow.json', {}) or {}).get('ids') or []
    return [dict(id=i, choice='C', reason='card full') for i in overflow]


def item_text(retro, run, label, item_id, projects):
    """An earlier run's item, from its own project's private records."""
    name = run_labels(retro, run).get(label) if label != 'firstmate' else None
    project = None
    if label not in ('firstmate', 'self'):
        project = project_of(projects, name) if name else None
        if not project or not project.get('ok'):
            return None
    data = read_json(private_dir(retro, run, label, project) / 'items.json', {}) or {}
    return next((i for i in data.get('items') or [] if i.get('id') == item_id), None)


def carried_items(retro, label, projects, now_run):
    """Approved items awaiting follow-up and parked items for one label."""
    follow, parked = [], []
    gone, done = superseded(retro), followed(retro)
    for run in retro.runs():
        if run >= now_run:
            continue
        labels_then = run_labels(retro, run)
        if label not in ('firstmate', 'self'):
            name = labels_then.get(label)
            if not name or not project_of(projects, name) or not project_of(projects, name).get('ok'):
                continue
        for entry in parked_entries(retro, run):
            match = FULL_ITEM_RE.fullmatch(entry.get('id') or '')
            if not match or match[1] != label:
                continue
            full_id = f'{run}/{entry["id"]}'
            if entry.get('choice') == 'C' and full_id not in gone:
                item = item_text(retro, run, label, match[2], projects)
                if item is not None:
                    parked.append(dict(full_id=full_id, reason=entry.get('reason') or 'parked', item=item))
            elif entry.get('choice') == 'A' and full_id not in done:
                follow.append(dict(full_id=full_id, run=run, item_id=match[2]))
    parked.sort(key=lambda p: p['full_id'], reverse=True)
    return follow, parked


def proposal_link(retro, run, label, item_id, projects):
    """The approved item's task link, from the manifest its own project holds."""
    if label in ('firstmate', 'self'):
        manifest = read_json(retro.run_dir(run) / 'proposals' / f'{label}-{item_id}.json', {}) or {}
        return manifest.get('status'), manifest.get('task')
    name = run_labels(retro, run).get(label)
    project = project_of(projects, name) if name else None
    if not project or not project.get('ok'):
        return 'refused', None
    manifest = read_json(Path(project['state']) / 'retro' / run / 'proposals' / f'{item_id}.json', {}) or {}
    return manifest.get('status'), manifest.get('task')


def linked_row(retro, project, task, end, now, api=None):
    """The linked task's metrics row once its pull request merged, with its CI
    history read through api like any other row."""
    if not task or not project:
        return None
    events = events_of(project['state'])
    merges = [e for e in events if e.get('type') == 'merged' and e.get('task') == task and type(e.get('pr')) is int
              and parse_time(e.get('ts')) is not None and parse_time(e['ts']) <= parse_time(end)]
    if not merges:
        return None
    return task_row(project, events, merges[0], api, retro)


# --- run states ------------------------------------------------------------------------

def run_state(retro, run):
    return read_json(retro.run_dir(run) / 'state.json', {}) or {}


def set_state(retro, run, **changes):
    state = run_state(retro, run)
    state.update(changes)
    state['updated_at'] = iso(time.time())
    write_json(retro.run_dir(run) / 'state.json', state)
    return state


def fail_run(retro, run, reason):
    """Under the lock."""
    set_state(retro, run, state='failed', failure=reason)
    index = load_index(retro)
    if index and index.get('open_run') == run:
        previous = dict(index)
        index['open_run'] = None
        save_index(retro, index, previous)


def card_status(retro, card_id):
    for status, folder in (('answered', 'decisions'), ('pending', 'pending'),
                           ('archived', 'runtime/archived-pending')):
        if (retro.state / folder / f'{card_id}.json').exists():
            return status
    return None


def answers_from_decision(retro, run):
    card = read_json(retro.run_dir(run) / 'card.json', {}) or {}
    decision = read_json(retro.state / 'decisions' / f'{card.get("id")}.json')
    order = (read_json(retro.run_dir(run) / 'card-items.json', {}) or {}).get('ids') or []
    if not isinstance(decision, dict) or decision.get('id') != card.get('id'):
        raise Refused('the card has no recorded answer')
    if decision.get('chosen') == 'A':
        given = decision.get('item_answers')
        if (not isinstance(given, list) or len(given) != len(order)
                or any(not isinstance(a, dict) or a.get('index') != i or a.get('id') != order[i]
                       or a.get('choice') not in ('A', 'C', 'D') for i, a in enumerate(given))):
            raise Refused('the answer does not match the card items')
        items = [dict(id=a['id'], choice=a['choice']) for a in given]
    elif decision.get('chosen') == 'C':
        items = [dict(id=i, choice='C') for i in order]
    else:
        raise Refused('a retrospective card takes A or C')
    overflow = (read_json(retro.run_dir(run) / 'overflow.json', {}) or {}).get('ids') or []
    items += [dict(id=i, choice='C', reason='card full') for i in overflow]
    return answers_doc(retro, run, items, card.get('id'))


def answers_doc(retro, run, items, card_id=None):
    supersedes = []
    for entry in items:
        match = FULL_ITEM_RE.fullmatch(entry['id'])
        if not match:
            continue
        label = match[1]
        data = (read_json(retro.run_dir(run) / 'rounds' / f'{label}.json', {}) or {})
        for carried in data.get('carried') or []:
            if carried.get('id') == match[2] and carried.get('carried_from'):
                supersedes.append(carried['carried_from'])
    return dict(schema=1, run_id=run, card=card_id, items=items, supersedes=sorted(set(supersedes)))


def complete(retro, run, kind):
    """Under the lock. Resumable four steps; each recorded before it runs."""
    state = run_state(retro, run)
    step = state.get('completion_step')
    if step == 'done':
        return
    if step is None:
        set_state(retro, run, completion_step=1, completion_kind=kind, wake_pending=False)
        step = 1
    kind = state.get('completion_kind') or kind
    crash('before-1')
    if step <= 1:
        answers = answers_doc(retro, run, []) if kind == 'zero' else answers_from_decision(retro, run)
        existing = read_json(retro.run_dir(run) / 'answers.json')
        if existing is not None and existing != answers:
            raise Refused('the run already holds different answers')
        if existing is None:
            write_json(retro.run_dir(run) / 'answers.json', answers)
        crash('after-1')
        set_state(retro, run, completion_step=2)
        crash('before-2')
    if step <= 2:
        current = run_state(retro, run)
        set_state(retro, run, state='completed', completed_at=current.get('completed_at') or iso(time.time()))
        crash('after-2')
        set_state(retro, run, completion_step=3)
        crash('before-3')
    if step <= 3:
        current = run_state(retro, run)
        index = load_index(retro)
        previous = dict(index)
        last = index.get('last_completed') or {}
        if last.get('run_id') != run:
            if last.get('window_end') and parse_time(last['window_end']) > parse_time(current['window']['end']):
                raise Refused('window_end only moves forward')
            index['last_completed'] = dict(run_id=run, window_end=current['window']['end'],
                                           completed_at=current['completed_at'])
        if index.get('open_run') == run:
            index['open_run'] = None
        save_index(retro, index, previous)
        crash('after-3')
        set_state(retro, run, completion_step=4, wake_pending=kind == 'zero')
        crash('before-4')
    if step <= 4:
        if kind == 'zero':
            push_wake(retro, 'retro-complete-' + run, 'retro_complete', 'retro complete: no findings')
        crash('after-4')
        set_state(retro, run, completion_step='done', wake_pending=False)


def push_wake(retro, ident, reason, line):
    """Under the lock: one line per identity on the self wake queue."""
    path = retro.state / 'session/wake.jsonl'
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        for row in path.read_text(encoding='utf-8').splitlines():
            try:
                if json.loads(row).get('id') == ident:
                    return False
            except ValueError:
                continue
    except OSError:
        pass
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.write(fd, (json.dumps(dict(id=ident, reason=reason, line=line, woken=time.time())) + '\n').encode())
    finally:
        os.close(fd)
    try:
        import fm_lifeline
        env = {k: v for k, v in os.environ.items() if k not in ('FM_STATE_DIR', 'FM_PROJECT', 'FM_EXTERNAL')}
        saved = dict(os.environ)
        os.environ.clear(); os.environ.update(env)
        try:
            fm_lifeline.ring(str(retro.engine), ident)
        finally:
            os.environ.clear(); os.environ.update(saved)
    except Exception:  # the queue carries the wake; a bell is only a hint
        pass
    return True


def reconcile(retro, projects, holding_run_lock=False):
    """Under the lock: resume, repair and clear what a dead process left,
    the proposal manifests of every project included."""
    index = load_index(retro)
    lock_free = None
    for run in retro.runs():
        state = run_state(retro, run)
        if not state:
            continue
        step = state.get('completion_step')
        if step in (1, 2, 3, 4):
            try:
                complete(retro, run, state.get('completion_kind') or 'card')
            except Refused:
                pass
            continue
        card = read_json(retro.run_dir(run) / 'card.json', {}) or {}
        status = card_status(retro, card.get('id')) if card.get('id') else None
        if state.get('state') in ('reviewed', 'awaiting-answer') and status:
            if status == 'archived':
                fail_run(retro, run, 'card archived')
                continue
            if state.get('state') == 'reviewed':
                set_state(retro, run, state='awaiting-answer')
            if status == 'answered':
                try:
                    complete(retro, run, 'card')
                except Refused:
                    pass
            continue
        if state.get('state') == 'running' and not holding_run_lock:
            if lock_free is None:
                lock_free = run_lock_free(retro)
            if lock_free:
                fail_run(retro, run, 'interrupted')
    index = load_index(retro)
    if index and index.get('open_run'):
        current = run_state(retro, index['open_run'])
        if current.get('state') in ('failed', 'completed') or not current:
            previous = dict(index)
            index['open_run'] = None
            save_index(retro, index, previous)
    reconcile_manifests(retro, projects)


def reconcile_manifests(retro, projects):
    for run in retro.runs():
        labels_then = run_labels(retro, run)
        folder = retro.run_dir(run) / 'proposals'
        seen = set()
        for label, name in labels_then.items():
            if label == 'self':
                continue
            project = project_of(projects, name)
            if not project or not project.get('ok'):
                continue
            private = Path(project['state']) / 'retro' / run / 'proposals'
            for manifest in sorted(private.glob('R*.json')) if private.is_dir() else []:
                data = read_json(manifest, {}) or {}
                mine = folder / f'{label}-{manifest.stem}.json'
                if (read_json(mine, {}) or {}).get('status') != data.get('status'):
                    write_json(mine, dict(status=data.get('status')))
                seen.add(mine.name)
        for mine in sorted(folder.glob('P-*.json')) if folder.is_dir() else []:
            if mine.name in seen:
                continue
            label = mine.stem.rsplit('-', 1)[0]
            name = labels_then.get(label)
            project = project_of(projects, name) if name else None
            if not project or not project.get('ok'):
                if (read_json(mine, {}) or {}).get('status') != 'refused':
                    write_json(mine, dict(status='refused', reason='project removed'))
            else:
                mine.unlink()


def begin(retro, now, projects):
    """Every entry point: the lock, the index and the whole reconciliation -
    runs, the index and the proposal manifests of every project."""
    with Locked(retro):
        index = ensure_index(retro, now)
        reconcile(retro, projects)
        return load_index(retro) or index


# --- due -------------------------------------------------------------------------------

def due_state(engine, now=None, projects=None, events=None):
    # events: optional {resolved state path: rows already read}, so a caller
    # that has just read a project's event log does not read it again
    retro = Retro(engine)
    now = time.time() if now is None else now
    if projects is None:
        projects = load_projects(retro)
    index = begin(retro, now, projects)
    start = parse_time(window_start(index))
    merges = 0
    for project in projects:
        if project.get('ok'):
            rows = (events or {}).get(str(Path(project['state']).resolve()))
            merges += len(merged_events(rows if rows is not None else events_of(project['state']), start))
    elapsed = now - parse_time(clock_start(index))
    last = index.get('last_completed')
    identity = 'retro-due-' + (last['run_id'] if last else 'initial')
    due = index.get('open_run') is None and (elapsed >= WEEK or merges >= MERGE_COUNT)
    return dict(due=due, identity=identity, merges=merges, elapsed_seconds=int(elapsed),
                start=window_start(index), clock_start=clock_start(index), open_run=index.get('open_run'))


# --- the board's request ----------------------------------------------------------------

def request(engine, now=None):
    retro = Retro(engine)
    now = time.time() if now is None else now
    projects = load_projects(retro)
    with Locked(retro):
        ensure_index(retro, now)
        reconcile(retro, projects)
        index = load_index(retro)
        folder = retro.dir / 'requests'
        if index.get('open_run') or (folder.is_dir() and any(folder.glob('*.json'))):
            raise Refused('a retrospective is already waiting or running', 75)
        ident = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime(now)) + '-' + secrets.token_hex(3)
        if not create_json(folder / f'{ident}.json', dict(schema=1, requested_at=iso(now), source='board')):
            raise Refused('a retrospective is already waiting or running', 75)
    return dict(request_id=ident)


# --- numeric card publication ----------------------------------------------------------

def publish_numeric(state, card_id, payload_file, retro_run=None):
    """Every hand-raised D-<digits> card is published here, under the one lock."""
    match = re.fullmatch(r'D-([0-9]{1,9})', card_id or '')
    if not match:
        raise Refused('bad numeric decision id', 64)
    number = int(match[1])
    state = Path(state).resolve()
    payload = payload_file.read() if hasattr(payload_file, 'read') else Path(payload_file).read_text(encoding='utf-8')
    engine_state = (CODE / 'state').resolve()
    retro = Retro(state.parent)
    if state != engine_state and not (state / 'retro').is_dir() and not retro_run:
        return _publish(state, card_id, payload)
    with Locked(retro):
        # An ordinary card may raise a withdrawn (archived) id again, as it
        # always could; a retrospective's number is free in all three places.
        folders = ('pending', 'decisions') + (('runtime/archived-pending',) if retro_run else ())
        for folder in folders:
            if (state / folder / f'{card_id}.json').exists():
                raise Refused(f'{card_id} already exists; refusing replacement')
        reservation = read_json(retro.dir / 'ids' / f'{number}.json')
        if retro_run:
            if not isinstance(reservation, dict) or reservation.get('run_id') != retro_run:
                raise Refused(f'{card_id} is not reserved for retrospective {retro_run}')
        elif reservation is not None or (retro.dir / 'ids' / f'{number}.json').exists():
            raise Refused(f'{card_id} is reserved for a retrospective card; take another number')
        return _publish(state, card_id, payload)


def _publish(state, card_id, payload):
    folder = state / 'pending'
    folder.mkdir(parents=True, exist_ok=True)
    try:
        fd = os.open(folder / f'{card_id}.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    except FileExistsError:
        raise Refused(f'{card_id} already exists; refusing replacement')
    with os.fdopen(fd, 'w', encoding='utf-8') as output:
        output.write(payload if payload.endswith('\n') else payload + '\n')
    return folder / f'{card_id}.json'


# --- run ---------------------------------------------------------------------------------

def new_run(retro, now):
    """Under the lock."""
    stamp = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime(now))
    while True:
        run = stamp + '-' + secrets.token_hex(3)
        try:
            retro.run_dir(run).mkdir(parents=True)
            return run
        except FileExistsError:
            continue


def resolve_base(retro, base):
    """The self project's configured base branch, resolved once to the commit
    every round of the run names and reads: its prompt, its checkout and its
    round record."""
    for ref in (f'refs/heads/{base}', f'refs/remotes/origin/{base}'):
        result = subprocess.run(['git', '-C', str(retro.engine), 'rev-parse', '--verify', '-q', ref + '^{commit}'],
                                capture_output=True, text=True)
        sha = result.stdout.strip()
        if result.returncode == 0 and re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', sha):
            return dict(base=base, commit=sha)
    raise Refused(f"cannot resolve the self project's base branch {base} in the engine checkout", 65)


def start_run(retro, now, projects, source=None):
    """Take run.lock (kept by the returned descriptor) and open a run.
    source: the resolved base ({base, commit}) the run's rounds read."""
    retro.dir.mkdir(parents=True, exist_ok=True)
    fd = os.open(retro.run_lock, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        raise Refused('a retro is running', 75)
    try:
        with Locked(retro):
            index = ensure_index(retro, now)
            for run in retro.runs():
                if run_state(retro, run).get('state') == 'running':
                    fail_run(retro, run, 'interrupted')
            reconcile(retro, projects, holding_run_lock=True)
            index = load_index(retro)
            if index.get('open_run'):
                raise Refused('an earlier retrospective is waiting for its card or its answer', 75)
            run = new_run(retro, now)
            write_json(retro.run_dir(run) / 'private/labels.json', labels(retro, projects))
            write_json(retro.run_dir(run) / 'state.json', dict(
                schema=1, run_id=run, state='running', started_at=iso(now), updated_at=iso(now),
                window=dict(start=window_start(index), end=iso(now)), failure=None, owner_pid=os.getpid(),
                source=source))
            crash('run-before-open')
            previous = dict(index)
            index['open_run'] = run
            save_index(retro, index, previous)
            crash('run-after-open')
            folder = retro.dir / 'requests'
            for waiting in sorted(folder.glob('*.json')) if folder.is_dir() else []:
                os.rename(waiting, retro.run_dir(run) / 'request.json')
                break
    except BaseException:
        os.close(fd)
        raise
    return run, fd


def round_targets(retro, run, projects, now):
    """Compute and keep metrics, then the project rounds that are due."""
    state = run_state(retro, run)
    start, end = state['window']['start'], state['window']['end']
    names = run_labels(retro, run)
    targets = []
    check = Check(retro, projects)
    for label in sorted(names, key=lambda l: (l != 'self', l)):
        project = project_of(projects, names[label])
        if not project or not project.get('ok'):
            continue
        api = github_api(retro, project)
        # the self project's files sit in the self tree: checked before written
        mine = check if label == 'self' else None
        doc = compute_metrics(retro, project, run, label, start, end, now, api, mine)
        follow, parked = carried_items(retro, label, projects, run)
        folder = private_dir(retro, run, label, project)
        write_json(folder / 'metrics.json', doc)
        write_text(folder / 'metrics.md', metrics_md(doc))
        if doc['prs'] or follow or parked:
            targets.append(label)
            prompt = project_prompt(retro, run, label, project, doc, follow, parked, projects, end, now, mine)
            write_text(folder / 'prompt.txt', prompt)
    follow, parked = carried_items(retro, 'firstmate', projects, run)
    if targets or follow or parked:
        cross = retro.run_dir(run) / 'cross'
        write_text(cross / 'prompt.txt', cross_prompt(retro, run, targets, projects, follow, parked, check, end, now))
        targets.append('firstmate')
    return targets


def source_commit(retro, run):
    return ((run_state(retro, run).get('source') or {}).get('commit')) or 'unknown'


def followup_entry(retro, run, entry, label, project, projects, end, now, check=None):
    status, task = proposal_link(retro, entry['run'], label, entry['item_id'], projects)
    item = item_text(retro, entry['run'], label, entry['item_id'], projects)
    if label == 'firstmate':
        baseline = read_json(retro.run_dir(entry['run']) / 'cross/projection.json')
        target = next((p for p in projects if not p['external']), None)
    else:
        baseline = read_json(private_dir(retro, entry['run'], label, project) / 'metrics.json')
        target = project
    api = github_api(retro, target) if status == 'linked' and target else None
    row = linked_row(retro, target, task, end, now, api) if status == 'linked' else None
    if row is not None and label == 'firstmate':
        row = project_rows(dict(prs=[row]), check or (lambda _: False))[0]
    value = dict(full_id=entry['full_id'], item=item, link=dict(status=status, task=task),
                 baseline=baseline, measured=row if row is not None else 'not yet measurable')
    return redact(value, check) if check is not None else value


def present_followups(retro, run, label, entries):
    """Keep which approved items this round was shown, and which of them with
    a measured row: a later run retires only those (never one the cap left out)."""
    shown = entries[:FOLLOW_CAP]
    write_json(retro.run_dir(run) / 'followups' / f'{label}.json', dict(
        shown=[e['full_id'] for e in shown],
        measured=[e['full_id'] for e in shown if e['measured'] != 'not yet measurable']))


def optional_texts(retro, project, doc):
    state, external = Path(project['state']), project['external']
    found = []
    for row in sorted(doc['prs'], key=lambda r: r['merged_at'], reverse=True):
        task, pr = row['task'], row['pr']
        if not task or task == REDACTED:
            continue
        spec = read_json(Path(project['tasks']) / f'{task}.json')
        if not isinstance(spec, dict):
            texts = pins_of(state, task)
            try:
                spec = json.loads(texts[-1]) if texts else None
            except ValueError:
                spec = None
        if isinstance(spec, dict):
            lines = [f'Task {task}: {spec.get("title", "")}', 'Acceptance:']
            lines += ['- ' + str(a) for a in spec.get('acceptance') or []]
            found.append((f'PR #{pr} {task} spec', '\n'.join(lines)))
        records, names = evidence_records(state, evidence_project(project, retro), task, external)
        for record, name in zip(records or [], names):
            reference = f'PR #{pr} {task} {name}'.strip()
            if record.get('kind') == 'verdict' and record.get('verdict') == 'REJECT':
                found.append((reference + ' REJECT', record.get('text') or ''))
            elif record.get('kind') == 'ask':
                found.append((reference + ' stop', record.get('text') or ''))
            elif external and record.get('kind') == 'external-verdict':
                lines = []
                for finding in record.get('findings') or []:
                    if isinstance(finding, dict):
                        where = f'{finding.get("path")}:{finding.get("line")}' if finding.get('path') else 'no cited line'
                        lines.append(f'Finding {finding.get("id")} by {finding.get("reviewer")}; {where}\n{finding.get("body", "")}')
                if lines:
                    found.append((reference + ' findings', '\n'.join(lines)))
    return found


def project_prompt(retro, run, label, project, doc, follow, parked, projects, end, now, check=None):
    """check: given for the self project, whose prompt sits in the self tree;
    a field that names an external project is redacted and an optional text
    that names one is left out, before the prompt is written."""
    follow_entries = [followup_entry(retro, run, e, label, project, projects, end, now, check) for e in follow]
    present_followups(retro, run, label, follow_entries)
    optional = optional_texts(retro, project, doc)
    if check is not None:
        parked = redact(parked, check)
        optional = [(r, t) for r, t in optional if not check(r) and not check(t)]
    mandatory = mandatory_text(json.dumps(doc, ensure_ascii=False, indent=1), follow_entries, parked)
    prompt = assemble(header(retro, run, label, False, source_commit(retro, run)), mandatory, optional)
    if check is not None and check(prompt):
        raise Refused('the self round prompt failed the identifying text check')
    return prompt


def cross_prompt(retro, run, targets, projects, follow, parked, check, end, now):
    names = run_labels(retro, run)
    projections = []
    for label in targets:
        project = project_of(projects, names.get(label)) if label != 'self' else next(p for p in projects if not p['external'])
        doc = read_json(private_dir(retro, run, label, project) / 'metrics.json')
        projections.append(projection(label, doc, check))
    # every field is a number, a time, an opaque label or a checked word; the
    # whole is checked again, and redacted rather than refused, before written
    if check(json.dumps(projections, ensure_ascii=False)):
        projections = redact(projections, check)
    write_json(retro.run_dir(run) / 'cross/projection.json', dict(schema=1, run_id=run, projects=projections))
    follow_entries = [followup_entry(retro, run, e, 'firstmate', None, projects, end, now, check) for e in follow]
    present_followups(retro, run, 'firstmate', follow_entries)
    text = json.dumps(dict(projects=projections, generic=[], refused=[]), ensure_ascii=False, indent=1)
    prompt = assemble(header(retro, run, 'firstmate', True, source_commit(retro, run)),
                      mandatory_text(text, follow_entries, redact(parked, check), 'Anonymous metrics of every project'), [])
    if check(prompt):
        raise Refused('the cross-project prompt failed the identifying text check')
    return prompt


def add_generic(retro, run, projects, check):
    """After the project rounds: their generic statements, checked, go into the
    cross prompt; a refused one is dropped and recorded as refused."""
    names = run_labels(retro, run)
    path = retro.run_dir(run) / 'cross/prompt.txt'
    if not path.exists():
        return
    generic, refused = [], []
    for label in sorted(names, key=lambda l: (l != 'self', l)):
        project = project_of(projects, names[label])
        if not project or not project.get('ok'):
            continue
        data = read_json(private_dir(retro, run, label, project) / 'items.json', {}) or {}
        for index, statement in enumerate(data.get('generic') or []):
            if check(statement):
                refused.append(dict(label=label, index=index, refused=True))
            else:
                generic.append(dict(label=label, text=statement))
    write_json(retro.run_dir(run) / 'cross/refused.json', dict(refused=refused))
    block = '\n## Generic statements from the project rounds\n' + (
        json.dumps(dict(generic=generic, refused=refused), ensure_ascii=False, indent=1) if generic or refused else 'None.') + '\n'
    prompt = path.read_text(encoding='utf-8')
    marker = '\n## Left out\n'
    head, _, tail = prompt.rpartition(marker)
    prompt = head + block + marker + tail
    if len(prompt) > CAP:
        raise TooLarge('inputs too large')
    if check(prompt):
        raise Refused('the cross-project prompt failed the identifying text check')
    write_text(path, prompt)


def launcher():
    return os.environ.get('FM_RETRO_ROUND') or str(CODE / 'bin/fm-review.sh')


def run_round(retro, run, label, names):
    argv = [launcher(), '--retro', run, '--repo', str(retro.engine)]
    argv += ['--retro-cross'] if label == 'firstmate' else ['--project', names[label]]
    env = clean_env()
    if 'FM_RETRO_ROUND' in os.environ:
        env['FM_RETRO_ROUND'] = os.environ['FM_RETRO_ROUND']
    if 'FM_SESSION_PID' in os.environ:
        env['FM_SESSION_PID'] = os.environ['FM_SESSION_PID']
    for key in ('FM_RETRO_TEST_CRASH', 'FM_RETRO_TEST_ANSWERS'):
        if key in os.environ:
            env[key] = os.environ[key]
    result = subprocess.run(argv, env=env, stdin=subprocess.DEVNULL)
    return result.returncode


def run(engine, now=None):
    retro = Retro(engine)
    now = time.time() if now is None else now
    retro_config(retro)
    projects = load_projects(retro)
    mine = next(p for p in projects if not p['external'])
    source = resolve_base(retro, mine.get('base') or 'main')
    run_id, fd = start_run(retro, now, projects, source)
    try:
        try:
            targets = round_targets(retro, run_id, projects, now)
        except TooLarge:
            with Locked(retro):
                fail_run(retro, run_id, 'inputs too large')
            return dict(run_id=run_id, state='failed', failure='inputs too large')
        with Locked(retro):
            set_state(retro, run_id, rounds=targets)
        names = run_labels(retro, run_id)
        check = Check(retro, projects)
        for label in targets:
            if label == 'firstmate':
                try:
                    add_generic(retro, run_id, projects, check)
                except TooLarge:
                    with Locked(retro):
                        fail_run(retro, run_id, 'inputs too large')
                    return dict(run_id=run_id, state='failed', failure='inputs too large')
            code = run_round(retro, run_id, label, names)
            outcome = read_json(retro.run_dir(run_id) / 'rounds' / f'{label}.json', {}) or {}
            if code != 0 or outcome.get('status') != 'ok':
                reason = 'invalid report: ' + label if outcome.get('status') == 'invalid' else 'round failed: ' + label
                with Locked(retro):
                    fail_run(retro, run_id, reason)
                return dict(run_id=run_id, state='failed', failure=reason)
        count = sum((read_json(retro.run_dir(run_id) / 'rounds' / f'{label}.json', {}) or {}).get('items', 0)
                    for label in targets)
        with Locked(retro):
            write_json(retro.run_dir(run_id) / 'followed.json', dict(ids=followed_now(retro, run_id, targets)))
            if count == 0:
                set_state(retro, run_id, state='reviewed')
                complete(retro, run_id, 'zero')
                return dict(run_id=run_id, state='completed', items=0)
            set_state(retro, run_id, state='reviewed')
        return dict(run_id=run_id, state='reviewed', items=count)
    except BaseException as error:
        if not isinstance(error, (KeyboardInterrupt, SystemExit)):
            try:
                with Locked(retro):
                    if run_state(retro, run_id).get('state') == 'running':
                        fail_run(retro, run_id, 'error: ' + type(error).__name__)
            except Exception:
                pass
        raise
    finally:
        os.close(fd)


def followed_now(retro, run, targets):
    """Approved items this run showed its rounds with their linked task's
    merged row; an item the follow-up cap left out stays for a later run."""
    ids = []
    for label in targets:
        ids += (read_json(retro.run_dir(run) / 'followups' / f'{label}.json', {}) or {}).get('measured') or []
    return ids


# --- a round's answer ----------------------------------------------------------------------

def selected(run_dir, attempt, vendor):
    import importlib.util
    spec = importlib.util.spec_from_file_location('managed', CODE / 'bin/fm-herdr.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if vendor == 'codex':
        answer = module.review_final(run_dir, attempt, os.environ)
        if not answer:
            raise Refused('no authenticated final answer for this round')
        return answer
    result = json.loads((Path(run_dir) / 'last-result.json').read_text())
    own = Path(result['attempt']).resolve()
    if own.parent != Path(run_dir).resolve() or result.get('chain_attempt') != attempt:
        raise Refused('the round answer belongs to another attempt')
    answer = module.cli_final(vendor, own / 'cli.log')
    if answer is None:
        raise Refused('the vendor gave no final answer')
    return answer


def check_carried(retro, run, label, items, projects):
    """carried_from names a parked item of this same label that an earlier run
    still carries; anything else would supersede an item it never repeated."""
    claimed = [i['carried_from'] for i in items if i.get('carried_from')]
    if not claimed:
        return
    parked = {p['full_id'] for p in carried_items(retro, label, projects, run)[1]}
    for carried in claimed:
        if CARRIED_RE.fullmatch(carried)[2] != label or carried not in parked:
            raise ReportError(f'items.carried_from: {carried} is no parked item of {label}')


def check_card_text(label, items):
    """The card checker's sentence rules, applied when the round is accepted:
    text the card would refuse fails this round (and the run, which then
    clears open_run) instead of leaving a reviewed run no card can raise."""
    import fm_ste
    for item in items:
        details = card_details([(label, item)], 0, [(label, 1)])
        try:
            report = fm_ste.check_details(details, 'choice')
        except ValueError as error:
            raise ReportError(f'{item["id"]}: {error}')
        if not report.get('ok'):
            raise ReportError(f'{item["id"]}: its text breaks the card sentence rules')


def accept(engine, run, label, answer, projects=None, run_dir=None):
    """Keep one round's answer and its items in that project's own records.
    run_dir: the round's run directory, contained for a self or cross round."""
    retro = Retro(engine)
    projects = load_projects(retro) if projects is None else projects
    begin(retro, time.time(), projects)
    names = run_labels(retro, run)
    if label != 'firstmate' and label not in names:
        raise Refused('no such label in this run', 64)
    project = project_of(projects, names[label]) if label not in ('firstmate',) else None
    if label == 'self':
        project = next(p for p in projects if not p['external'])
    folder = private_dir(retro, run, label, project)
    check = Check(retro, projects) if label in ('self', 'firstmate') else None
    # The self tree keeps no external project's text: a report that names one
    # is withheld there, its items and statements are checked one by one, and
    # the transport's own copies of the answer in the run directory are
    # replaced before anything else reads them.
    if check is not None and run_dir:
        contain(retro, run_dir, projects)
    withheld = check is not None and check(answer)
    write_text(folder / 'report.md', '[report withheld: it named an external project]\n' if withheld else answer)
    outcome = retro.run_dir(run) / 'rounds' / f'{label}.json'
    base = source_commit(retro, run)
    try:
        report = parse_report(answer, cross=label == 'firstmate')
        check_carried(retro, run, label, report['items'], projects)
        check_card_text(label, report['items'])
    except ReportError as error:
        write_json(folder / 'round.json', dict(status='invalid', reason=str(error)))
        write_json(outcome, dict(status='invalid', base_commit=base))
        return False
    refused = 0
    if check is not None:
        kept = []
        for item in report['items']:
            if check(item):
                refused += 1
            else:
                kept.append(item)
        report['items'] = kept
        generic = [text for text in report['generic'] if not check(text)]
        refused += len(report['generic']) - len(generic)
        report['generic'] = generic
    write_json(folder / 'items.json', dict(schema=1, run_id=run, label=label, items=report['items'],
                                           generic=report['generic']))
    write_json(folder / 'round.json', dict(status='ok', items=len(report['items'])))
    write_json(outcome, dict(status='ok', items=len(report['items']), refused=refused, base_commit=base,
                             carried=[dict(id=i['id'], carried_from=i['carried_from'])
                                      for i in report['items'] if i.get('carried_from')]))
    return True


def round_info(engine, run, label_or_name, cross):
    """The launcher's view of one round: its project name, its prompt, the
    base commit the run resolved, and the paths it may never read."""
    retro = Retro(engine)
    projects = load_projects(retro)
    begin(retro, time.time(), projects)
    names = run_labels(retro, run)
    if cross:
        label, name = 'firstmate', names.get('self', '')
    else:
        label = next((l for l, n in names.items() if n == label_or_name), None)
        if label is None:
            raise Refused('no round for that project in this run', 64)
        name = label_or_name
    project = next(p for p in projects if not p['external']) if label in ('self', 'firstmate') \
        else project_of(projects, name)
    if not project or not project.get('ok'):
        raise Refused('the project is not available', 65)
    prompt = private_dir(retro, run, label, project) / 'prompt.txt'
    if not prompt.is_file():
        raise Refused('this run has no prompt for that round', 65)
    base = source_commit(retro, run)
    if not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', base):
        raise Refused('this run resolved no base commit', 65)
    own = name if label not in ('self', 'firstmate') else None
    return dict(label=label, name=name, prompt=str(prompt), base_commit=base,
                never_read=deny_paths(retro, projects, own))


def live_round(run_dir):
    """True while any managed process of the round may still run (an
    unreadable record counts as live: a checkout in use is never removed)."""
    import importlib.util
    spec = importlib.util.spec_from_file_location('managed', CODE / 'bin/fm-herdr.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    try:
        return any(s['state'] != 'terminated' for s in module.executions(run_dir))
    except (OSError, ValueError, KeyError):
        return True


def release(engine, run_dir, checkout, contained):
    """At a round launcher's exit: once every managed process of the round has
    ended, contain a self or cross round's run directory and remove its
    checkout. While one may still run, both are kept and the caller is told."""
    if run_dir and live_round(run_dir):
        return dict(released=False, checkout=checkout)
    retro = Retro(engine)
    if contained and run_dir:
        contain(retro, run_dir, load_projects(retro))
    if checkout:
        import shutil
        shutil.rmtree(checkout, ignore_errors=True)
    return dict(released=True)


# --- the card ---------------------------------------------------------------------------------

def label_order(label):
    return (0, '') if label == 'firstmate' else (1, '') if label == 'self' else (2, label)


def card_items(retro, run, projects):
    names = run_labels(retro, run)
    state = run_state(retro, run)
    items = []
    for label in state.get('rounds') or []:
        project = None
        if label == 'self':
            project = next(p for p in projects if not p['external'])
        elif label != 'firstmate':
            project = project_of(projects, names.get(label))
            if not project or not project.get('ok'):
                raise Refused('a project of this run is not available', 65)
        data = read_json(private_dir(retro, run, label, project) / 'items.json', {}) or {}
        for item in data.get('items') or []:
            items.append((label, item))
    items.sort(key=lambda pair: (EFFECTS.index(pair[1]['effect']), label_order(pair[0]), int(pair[1]['id'][1:])))
    return items


def card_details(items, overflow, counts):
    details = {}
    shown = len(items)
    for lang in LOCALES:
        en = lang == 'en'
        entries = []
        for label, item in items:
            loc = item[lang]
            entry = dict(id=f'{label}/{item["id"]}', project=label, title=loc['title'], why=loc['why'],
                         how=loc['how'], evidence=loc['evidence'], scope=loc['scope'],
                         effect=item['effect'], removes=item['removes'])
            if item['effect'] == 'adds':
                entry['why_not_removal'] = loc['why_not_removal']
            entries.append(entry)
        summary = ' '.join(f'{label}: {n}.' for label, n in counts)
        loc = dict(
            title='Retrospective: choose what happens to each item.' if en else '回顧：逐項決定處理方式。',
            explanation=(f'The retrospective has {shown} items for you.' if en else f'這次回顧有 {shown} 個項目給你。'),
            before='No item has a recorded choice.' if en else '每個項目都還沒有紀錄的選擇。',
            after=(('Items by label: ' + summary) if en else ('各標籤的項目數：' + summary)),
            outcome=('Approved items become task proposals. Parked items return in the next retrospective. Dropped items stay in the record.'
                     if en else '核准的項目成為任務提案。擱置的項目回到下次回顧。捨棄的項目只留在紀錄裡。'),
            options=dict(
                A=dict(description='Record my choice for each item.' if en else '逐項記錄我的選擇。',
                       pros='Each item gets the choice you pick.' if en else '每個項目都有你的選擇。',
                       cons='You read every item first.' if en else '你要先讀完每個項目。'),
                C=dict(description='Park the whole retrospective.' if en else '擱置整個回顧。',
                       pros='Nothing changes now.' if en else '現在不改任何東西。',
                       cons='Every item waits for the next retrospective.' if en else '每個項目都等到下次回顧。')),
            # why, how and glossary on every card (T-270)
            why=[dict(kind='fact', text='Each item proposes one change to how firstmate works.'
                      if en else '每個項目提出一個 firstmate 工作方式的改變。')],
            how=[dict(kind='fact', text='You choose approve, park or drop for each item.'
                      if en else '你為每個項目選擇核准、擱置或捨棄。'),
                 dict(kind='fact', text='Firstmate turns each approved item into a task proposal.'
                      if en else 'firstmate 把每個核准的項目寫成任務提案。')],
            glossary=[],
            items=entries)
        if overflow:
            loc['notes'] = [dict(kind='note', text=(f'This retrospective has {shown + overflow} items. The card shows {shown} of them. The other {overflow} items wait for the next retrospective.'
                                                    if en else f'這次共有 {shown + overflow} 個項目。卡片顯示其中 {shown} 個。其餘 {overflow} 個項目等到下次回顧。'))]
        details[lang] = loc
    return details


def card_prepare(engine, run):
    """Under the lock: reserve a number, write card.json and the item order.
    Prints what the shell wrapper publishes next."""
    retro = Retro(engine)
    projects = load_projects(retro)
    now = time.time()
    with Locked(retro):
        ensure_index(retro, now)
        reconcile(retro, projects)
        state = run_state(retro, run)
        card = read_json(retro.run_dir(run) / 'card.json')
        if isinstance(card, dict):
            status = card_status(retro, card.get('id'))
            state = run_state(retro, run)
            if status in ('pending', 'answered') or state.get('state') in ('awaiting-answer', 'completed'):
                return dict(action='none', id=card['id'], state=state.get('state'))
            if status == 'archived' or state.get('state') == 'failed':
                return dict(action='none', id=card['id'], state=run_state(retro, run).get('state'))
            reserved = read_json(retro.dir / 'ids' / (card['id'][2:] + '.json'), {}) or {}
            if reserved.get('run_id') != run:
                raise Refused('the reserved card number no longer names this run')
            return dict(action='raise', id=card['id'], details=details_file(retro, run, projects))
        if state.get('state') != 'reviewed':
            raise Refused('a card is raised only for a reviewed run (this one is ' + str(state.get('state')) + ')')
        items = card_items(retro, run, projects)
        if not items:
            raise Refused('a run with no items completes without a card')
        shown, rest = items[:CARD_CAP], items[CARD_CAP:]
        number = FIRST_CARD
        while any((retro.state / folder / f'D-{number}.json').exists()
                  for folder in ('pending', 'decisions', 'runtime/archived-pending')) \
                or (retro.dir / 'ids' / f'{number}.json').exists():
            number += 1
        create_json(retro.dir / 'ids' / f'{number}.json', dict(run_id=run))
        write_json(retro.run_dir(run) / 'overflow.json', dict(ids=[f'{l}/{i["id"]}' for l, i in rest], reason='card full'))
        write_json(retro.run_dir(run) / 'card-items.json', dict(ids=[f'{l}/{i["id"]}' for l, i in shown]))
        write_json(retro.run_dir(run) / 'card.json', dict(schema=1, run_id=run, id=f'D-{number}'))
        crash('card-reserved')
        return dict(action='raise', id=f'D-{number}', details=details_file(retro, run, projects))


def details_file(retro, run, projects):
    items = card_items(retro, run, projects)
    shown, rest = items[:CARD_CAP], items[CARD_CAP:]
    counts = {}
    for label, _ in shown:
        counts[label] = counts.get(label, 0) + 1
    ordered = sorted(counts.items(), key=lambda pair: label_order(pair[0]))
    details = card_details(shown, len(rest), ordered)
    # The card's own text, on its way to its pending record: kept beside the
    # run's labels in private/, never in a shared temporary directory, and
    # removed once the card is published (card-finish).
    path = card_details_path(retro, run)
    write_json(path, details)
    return str(path)


def card_details_path(retro, run):
    return retro.run_dir(run) / 'private' / 'card-details.json'


def card_finish(engine, run):
    retro = Retro(engine)
    projects = load_projects(retro)
    with Locked(retro):
        ensure_index(retro, time.time())
        card = read_json(retro.run_dir(run) / 'card.json', {}) or {}
        status = card_status(retro, card.get('id')) if card.get('id') else None
        if status:
            # published (or answered, or archived): its record holds the text now
            card_details_path(retro, run).unlink(missing_ok=True)
        state = run_state(retro, run)
        if status in ('pending', 'answered') and state.get('state') == 'reviewed':
            set_state(retro, run, state='awaiting-answer')
        reconcile(retro, projects)
        return dict(id=card.get('id'), state=run_state(retro, run).get('state'))


def card_check(engine, run, card_id, details_path):
    """The card publisher's check for a retro card: reserved for this run, and items
    equal to the run's persisted card order."""
    retro = Retro(engine)
    match = re.fullmatch(r'D-([0-9]{1,9})', card_id or '')
    reservation = read_json(retro.dir / 'ids' / f'{match[1]}.json', {}) if match else None
    if not isinstance(reservation, dict) or reservation.get('run_id') != run:
        raise Refused(f'{card_id} is not reserved for retrospective {run}')
    order = (read_json(retro.run_dir(run) / 'card-items.json', {}) or {}).get('ids')
    details = read_json(details_path, {}) or {}
    for lang in LOCALES:
        ids = [i.get('id') for i in (details.get(lang) or {}).get('items') or [] if isinstance(i, dict)]
        if ids != order:
            raise Refused('the card items differ from the run\'s card-items.json')
    return True


# --- record, claim and link -------------------------------------------------------------------

def record(engine, run, decision=None):
    retro = Retro(engine)
    projects = load_projects(retro)
    with Locked(retro):
        ensure_index(retro, time.time())
        reconcile(retro, projects)
        card = read_json(retro.run_dir(run) / 'card.json')
        if not isinstance(card, dict):
            raise Refused('this run has no card')
        if decision and decision != card.get('id'):
            raise Refused(f'{decision} is not this run\'s card ({card.get("id")})')
        state = run_state(retro, run)
        if state.get('state') == 'failed':
            raise Refused('this run failed: ' + str(state.get('failure')))
        answers = answers_from_decision(retro, run)
        existing = read_json(retro.run_dir(run) / 'answers.json')
        if existing is not None and existing != answers:
            raise Refused('the run already holds different answers')
        if state.get('state') == 'reviewed':
            set_state(retro, run, state='awaiting-answer')
        complete(retro, run, 'card')
        return dict(run_id=run, state=run_state(retro, run).get('state'))


def answer_of(retro, run, full_id):
    answers = read_json(retro.run_dir(run) / 'answers.json', {}) or {}
    return next((a for a in answers.get('items') or [] if a.get('id') == full_id), None)


def claim(engine, run, full_id, draft=None):
    retro = Retro(engine)
    match = FULL_ITEM_RE.fullmatch(full_id or '')
    if not match:
        raise Refused('bad item id; expected <label>/R<n>', 64)
    label, item_id = match[1], match[2]
    projects = load_projects(retro)
    with Locked(retro):
        ensure_index(retro, time.time())
        reconcile(retro, projects)
        entry = answer_of(retro, run, full_id)
        if not entry or entry.get('choice') != 'A':
            raise Refused('only an approved item is claimed')
        mine = retro.run_dir(run) / 'proposals' / f'{label}-{item_id}.json'
        if label in ('firstmate', 'self'):
            existing = read_json(mine)
            if isinstance(existing, dict):
                return dict(existing, already=True)
            draft = draft or f'design/tasks/retro-{run}-{label}-{item_id}.json'
            if not re.fullmatch(r'design/tasks/[A-Za-z0-9._-]+\.json', draft):
                raise Refused('a firstmate draft lives under design/tasks/', 64)
            if Check(retro, projects)(draft):
                raise Refused('the draft path names an external project')
            value = dict(status='proposing', draft=draft, task=None)
            create_json(mine, value)
            return value
        name = run_labels(retro, run).get(label)
        project = project_of(projects, name) if name else None
        if not project or not project.get('ok'):
            write_json(mine, dict(status='refused', reason='project removed'))
            raise Refused('project removed')
        private = Path(project['state']) / 'retro' / run / 'proposals' / f'{item_id}.json'
        existing = read_json(private)
        if isinstance(existing, dict):
            if (read_json(mine, {}) or {}).get('status') != existing.get('status'):
                write_json(mine, dict(status=existing.get('status')))
            return dict(existing, already=True)
        value = dict(status='proposing', item=full_id,
                     draft=str(Path(project['state']) / 'retro' / run / 'drafts' / f'{item_id}.json'), task=None)
        create_json(private, value)
        crash('claim-between')
        write_json(mine, dict(status='proposing'))
        return value


def link(engine, run, full_id, task):
    retro = Retro(engine)
    match = FULL_ITEM_RE.fullmatch(full_id or '')
    if not match or not re.fullmatch(r'[A-Za-z][A-Za-z0-9._-]{0,40}', task or ''):
        raise Refused('bad item or task id', 64)
    label, item_id = match[1], match[2]
    projects = load_projects(retro)
    with Locked(retro):
        ensure_index(retro, time.time())
        reconcile(retro, projects)
        mine = retro.run_dir(run) / 'proposals' / f'{label}-{item_id}.json'
        if label in ('firstmate', 'self'):
            existing = read_json(mine)
            if not isinstance(existing, dict):
                raise Refused('claim the item before linking it')
            if Check(retro, projects)(task):
                raise Refused('the task id names an external project')
            value = dict(existing, status='linked', task=task)
            write_json(mine, value)
            return value
        name = run_labels(retro, run).get(label)
        project = project_of(projects, name) if name else None
        if not project or not project.get('ok'):
            write_json(mine, dict(status='refused', reason='project removed'))
            raise Refused('project removed')
        private = Path(project['state']) / 'retro' / run / 'proposals' / f'{item_id}.json'
        existing = read_json(private)
        if not isinstance(existing, dict):
            raise Refused('claim the item before linking it')
        value = dict(existing, status='linked', task=task)
        write_json(private, value)
        crash('link-between')
        write_json(mine, dict(status='linked'))
        return value


def status(engine):
    retro = Retro(engine)
    due = due_state(engine)
    runs = []
    for run_id in retro.runs():
        state = run_state(retro, run_id)
        runs.append(dict(run_id=run_id, state=state.get('state'), failure=state.get('failure'),
                         completion_step=state.get('completion_step')))
    return dict(due, runs=runs)


# --- command line ------------------------------------------------------------------------------

def main(argv):
    parser = argparse.ArgumentParser(description='Periodic retrospective (T-273).')
    parser.add_argument('command', choices=['status', 'due', 'request', 'run', 'card-prepare', 'card-finish',
                                            'card-check', 'record', 'claim', 'link', 'publish-numeric',
                                            'round-info', 'accept', 'release'])
    parser.add_argument('--engine', default=str(CODE))
    parser.add_argument('--run', default='')
    parser.add_argument('--item', default='')
    parser.add_argument('--task', default='')
    parser.add_argument('--draft', default='')
    parser.add_argument('--decision', default='')
    parser.add_argument('--state', default='')
    parser.add_argument('--id', default='')
    parser.add_argument('--payload', default='')
    parser.add_argument('--details', default='')
    parser.add_argument('--retro-run', default='')
    parser.add_argument('--project', default='')
    parser.add_argument('--cross', action='store_true')
    parser.add_argument('--label', default='')
    parser.add_argument('--run-dir', default='')
    parser.add_argument('--attempt', default='')
    parser.add_argument('--vendor', default='')
    parser.add_argument('--answer-file', default='')
    parser.add_argument('--checkout', default='')
    parser.add_argument('--contain', action='store_true')
    try:
        args = parser.parse_args(argv)
    except SystemExit as error:
        return 64 if error.code else 0
    if os.environ.get('FM_EXTERNAL') == '1' and args.command != 'publish-numeric':
        print('fm-retro: a retrospective runs only with the self project\'s context (FM_EXTERNAL=1)', file=sys.stderr)
        return 64
    try:
        if args.command == 'publish-numeric':
            # '-': the payload arrives on standard input, never as a file of its own
            payload = sys.stdin if args.payload == '-' else args.payload
            print(publish_numeric(args.state, args.id, payload, args.retro_run or None))
            return 0
        engine = args.engine
        if args.command in ('status', 'due'):
            result = status(engine) if args.command == 'status' else due_state(engine)
        elif args.command == 'request':
            result = request(engine)
        elif args.command == 'run':
            result = run(engine)
        elif args.command == 'card-prepare':
            result = card_prepare(engine, args.run)
        elif args.command == 'card-finish':
            result = card_finish(engine, args.run)
        elif args.command == 'card-check':
            result = card_check(engine, args.retro_run, args.id, args.details)
        elif args.command == 'record':
            result = record(engine, args.run, args.decision or None)
        elif args.command == 'claim':
            result = claim(engine, args.run, args.item, args.draft or None)
        elif args.command == 'link':
            result = link(engine, args.run, args.item, args.task)
        elif args.command == 'round-info':
            result = round_info(engine, args.run, args.project, args.cross)
        elif args.command == 'release':
            result = release(engine, args.run_dir, args.checkout, args.contain)
        else:
            if args.answer_file:
                answer = Path(args.answer_file).read_text(encoding='utf-8')
            else:
                answer = selected(args.run_dir, args.attempt, args.vendor)
            label = args.label or round_info(engine, args.run, args.project, args.cross)['label']
            ok = accept(engine, args.run, label, answer, run_dir=args.run_dir or None)
            result = dict(accepted=ok)
            print(json.dumps(result))
            return 0 if ok else 65
    except Refused as error:
        print('fm-retro: ' + str(error), file=sys.stderr)
        return error.code
    print(json.dumps(result, ensure_ascii=False))
    if args.command == 'run' and result.get('state') == 'failed':
        return 65
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
