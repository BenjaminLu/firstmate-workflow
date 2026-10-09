#!/usr/bin/env python3
"""The flaky-test ledger (T-274): one JSON file per project state root.

A signature is the GitHub repository (owner/name), the test file without a
line number, the test title without a trailing parameter in parentheses, and
the error class. A hit is one failed CI job attempt; the second hit in the
current cycle starts a root-cause investigation (skills/firstmate, Process
rule 2). firstmate is the only writer.

  fm_flaky.py hit         SIG --pr N --head SHA --run N --job N --attempt N --at TIME [--rerun]
  fm_flaky.py investigate SIG --owner NAME
  fm_flaky.py link        SIG --task T-N
  fm_flaky.py fixed       SIG --pr N --commit SHA --at TIME
  fm_flaky.py show

SIG is --repo owner/name --file PATH --title TITLE --error CLASS. Every
command takes --project NAME (default: config.yaml's default project). The
ledger is <record root>/state/flaky-ledger.json, the root chosen by
record_root in fm_project_paths.py; an external project that cannot be
resolved exits 65 and nothing is written. Refusals exit 65, usage errors 64.
"""
import argparse
import datetime
import fcntl
import importlib.util
import json
import os
import re
import sys
import tempfile
from pathlib import Path

LEDGER = 'state/flaky-ledger.json'
SELF = 'firstmate-workflow'
ACTIVE = ('open', 'fix-task')
STATUSES = ('none', 'open', 'fix-task', 'fixed')


class Refused(Exception):
    pass


def _paths():
    spec = importlib.util.spec_from_file_location('fm_project_paths', Path(__file__).with_name('fm_project_paths.py'))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def _self_listed(paths, engine, name):
    """Whether config.yaml registers `name` as this repository (repo: .)."""
    herdr = paths.registry_reader()
    if herdr is None:
        return False
    try:
        block = herdr._config_key(herdr._config_lines(engine), 'projects')
        entry = herdr._config_key(block[1], name) if block and not block[0] else None
        repo = herdr._config_key(entry[1], 'repo') if entry else None
        return bool(repo) and herdr._project_scalar(repo[0], 'repo') == '.'
    except Exception:
        return False


def resolve(project):
    """(project name, ledger path). Never falls back to the engine's state/
    for a project that is not this repository."""
    engine = Path(os.environ.get('FM_ROOT') or Path(__file__).resolve().parents[2]).resolve()
    paths = _paths()
    if project is None:
        default = getattr(paths.registry_reader(), 'default_project', None)
        project = (default(engine) if default else None) or SELF
    if not re.fullmatch(r'[a-z0-9-]{1,24}', project):
        raise Refused('invalid project name: ' + project)
    os.environ['FM_PROJECT'] = project
    try:
        root = Path(paths.record_root(engine)).resolve()
    except (ValueError, OSError) as error:
        raise Refused(f'project {project} has no resolvable state root: {error}') from None
    if root == engine and project != SELF and not _self_listed(paths, engine, project):
        raise Refused(f'project {project} has no resolvable private state root')
    return project, root / LEDGER


def norm_title(title):
    """'name (en)' and 'name (zh-TW)' are one signature."""
    return re.sub(r'\s*\([^()]*\)\s*$', '', title.strip()).strip()


def norm_file(path):
    """Line numbers are not part of a signature."""
    return re.sub(r'(:\d+){1,2}$', '', path.strip())


def timestamp(value):
    if not re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ', value or ''):
        raise ValueError(f'not a UTC time like 2026-10-09T10:13:07Z: {value!r}')
    return datetime.datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ')


def describe(entry):
    return f"{entry.get('repository')} {entry.get('file')} '{entry.get('title')}' [{entry.get('error_class')}]"


def validate(ledger):
    if not isinstance(ledger, dict) or ledger.get('schema') != 1 or not isinstance(ledger.get('signatures'), list):
        raise Refused('the ledger is not {"schema": 1, "signatures": [...]}')
    for entry in ledger['signatures']:
        if not isinstance(entry, dict) or not isinstance(entry.get('hits'), list):
            raise Refused('a ledger entry has no hits list')
        current = entry.get('investigation')
        if not isinstance(current, dict) or current.get('status') not in STATUSES:
            raise Refused('signature has an invalid investigation: ' + describe(entry))
        for investigation in [current] + list(entry.get('history') or []):
            if isinstance(investigation, dict) and investigation.get('status') == 'fixed':
                try:
                    timestamp(investigation.get('fixed_at'))
                except ValueError:
                    raise Refused('fixed record without fixed_at for signature: ' + describe(entry)) from None
        for hit in entry['hits']:
            try:
                timestamp(hit.get('at'))
            except (ValueError, AttributeError):
                raise Refused('hit without a valid at for signature: ' + describe(entry)) from None


def load(path):
    try:
        text = path.read_text()
    except FileNotFoundError:
        return {'schema': 1, 'signatures': []}
    try:
        ledger = json.loads(text)
    except ValueError:
        raise Refused(f'{path} is not JSON') from None
    validate(ledger)
    return ledger


def save(path, ledger):
    fd, temp = tempfile.mkstemp(prefix='.flaky-ledger.', suffix='.new', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as out:
            json.dump(ledger, out, indent=2, ensure_ascii=False); out.write('\n')
            out.flush(); os.fsync(out.fileno())
        os.replace(temp, path)
    except BaseException:
        try: os.unlink(temp)
        except OSError: pass
        raise


def last_fixed(entry):
    times = [timestamp(i['fixed_at']) for i in [entry['investigation']] + list(entry.get('history') or [])
             if isinstance(i, dict) and i.get('status') == 'fixed']
    return max(times) if times else None


def cycle_hits(entry):
    """Hits since the last fix: the count the second-hit rule uses."""
    cutoff = last_fixed(entry)
    return sum(1 for hit in entry['hits'] if cutoff is None or timestamp(hit['at']) > cutoff)


def find(ledger, args):
    key = (args.repo, norm_file(args.file), norm_title(args.title), args.error.strip())
    for entry in ledger['signatures']:
        if (entry.get('repository'), entry.get('file'), entry.get('title'), entry.get('error_class')) == key:
            return entry
    return None


def summary(entry):
    current = entry['investigation']
    return {'repository': entry['repository'], 'file': entry['file'], 'title': entry['title'],
            'error_class': entry['error_class'], 'cycle_hits': cycle_hits(entry), 'hits': len(entry['hits']),
            'status': current['status'], 'owner': current.get('owner'), 'task': current.get('task'),
            'investigation_due': cycle_hits(entry) >= 2 and current['status'] not in ACTIVE}


def blank_investigation():
    return {'status': 'none', 'owner': None, 'task': None, 'merged_pr': None, 'merge_commit': None, 'fixed_at': None}


def command_hit(ledger, args, project):
    timestamp(args.at)
    entry = find(ledger, args)
    if entry is None:
        entry = {'repository': args.repo, 'project': project, 'file': norm_file(args.file),
                 'title': norm_title(args.title), 'error_class': args.error.strip(),
                 'first_seen': args.at, 'hits': [], 'investigation': blank_investigation()}
        ledger['signatures'].append(entry)
    same = [h for h in entry['hits'] if (h.get('run'), h.get('job'), h.get('attempt')) == (args.run, args.job, args.attempt)]
    if same:
        if args.rerun:
            same[0]['rerun'] = True
    else:
        entry['hits'].append({'pr': args.pr, 'head': args.head, 'run': args.run, 'job': args.job,
                              'attempt': args.attempt, 'at': args.at, 'rerun': bool(args.rerun)})
    entry['first_seen'] = min((h['at'] for h in entry['hits']), key=timestamp)
    return entry


def existing(ledger, args):
    entry = find(ledger, args)
    if entry is None:
        raise Refused('no such signature; record a hit first')
    return entry


def command_investigate(ledger, args, project):
    entry = existing(ledger, args)
    current = entry['investigation']
    if current['status'] in ACTIVE:
        raise Refused(f"an investigation is already {current['status']} for signature: " + describe(entry))
    if current['status'] == 'fixed':
        entry.setdefault('history', []).append(current)
    entry['investigation'] = dict(blank_investigation(), status='open', owner=args.owner)
    return entry


def command_link(ledger, args, project):
    entry = existing(ledger, args)
    current = entry['investigation']
    if current['status'] != 'open':
        raise Refused(f"link needs an open investigation, not {current['status']}: " + describe(entry))
    current.update(status='fix-task', task=args.task)
    return entry


def command_fixed(ledger, args, project):
    timestamp(args.at)
    entry = existing(ledger, args)
    current = entry['investigation']
    if current['status'] not in ACTIVE:
        raise Refused(f"fixed needs an open investigation or fix task, not {current['status']}: " + describe(entry))
    current.update(status='fixed', merged_pr=args.pr, merge_commit=args.commit, fixed_at=args.at)
    return entry


class Usage(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(64, f'{self.prog}: {message}\n')


def parser():
    top = Usage(prog='fm_flaky.py', description='The flaky-test ledger (T-274).')
    commands = top.add_subparsers(dest='command', required=True, parser_class=Usage)
    def signature(name):
        sub = commands.add_parser(name)
        sub.add_argument('--project')
        sub.add_argument('--repo', required=True)
        sub.add_argument('--file', required=True)
        sub.add_argument('--title', required=True)
        sub.add_argument('--error', required=True)
        return sub
    hit = signature('hit')
    hit.add_argument('--pr', type=int, required=True)
    hit.add_argument('--head', required=True)
    hit.add_argument('--run', type=int, required=True)
    hit.add_argument('--job', type=int, required=True)
    hit.add_argument('--attempt', type=int, required=True)
    hit.add_argument('--at', required=True)
    hit.add_argument('--rerun', action='store_true')
    signature('investigate').add_argument('--owner', required=True)
    signature('link').add_argument('--task', required=True)
    fixed = signature('fixed')
    fixed.add_argument('--pr', type=int, required=True)
    fixed.add_argument('--commit', required=True)
    fixed.add_argument('--at', required=True)
    commands.add_parser('show').add_argument('--project')
    return top


def check_arguments(args):
    if args.command == 'show':
        return
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repo):
        raise ValueError('--repo must be a GitHub owner/name: ' + args.repo)
    if not (norm_file(args.file) and norm_title(args.title) and args.error.strip()):
        raise ValueError('--file, --title and --error must not be empty')
    if args.command == 'hit' and not re.fullmatch(r'[0-9a-f]{7,40}', args.head):
        raise ValueError('--head must be a commit sha')
    if args.command == 'fixed' and not re.fullmatch(r'[0-9a-f]{7,40}', args.commit):
        raise ValueError('--commit must be a commit sha')
    if args.command == 'link' and not re.fullmatch(r'T-\d+', args.task):
        raise ValueError('--task must be a task id like T-275')
    if args.command == 'hit' and args.attempt < 1:
        raise ValueError('--attempt starts at 1')


def show(ledger):
    if not ledger['signatures']:
        print('no flaky signatures')
    for entry in ledger['signatures']:
        s = summary(entry)
        print('\t'.join([s['repository'], s['file'], s['title'], s['error_class'],
                         f"cycle_hits={s['cycle_hits']}", f"hits={s['hits']}", f"status={s['status']}",
                         f"owner={s['owner'] or '-'}", f"task={s['task'] or '-'}",
                         'investigate=due' if s['investigation_due'] else 'investigate=no']))


def main(argv):
    args = parser().parse_args(argv)
    try:
        check_arguments(args)
        if args.command in ('hit', 'fixed'):
            timestamp(args.at)
    except ValueError as error:
        print('fm_flaky: ' + str(error), file=sys.stderr)
        return 64
    try:
        project, path = resolve(args.project)
        if args.command == 'show':
            show(load(path))
            return 0
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path.parent / '.flaky-ledger.lock', 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            ledger = load(path)
            entry = {'hit': command_hit, 'investigate': command_investigate,
                     'link': command_link, 'fixed': command_fixed}[args.command](ledger, args, project)
            save(path, ledger)
    except Refused as error:
        print('fm_flaky: refused: ' + str(error), file=sys.stderr)
        return 65
    print(json.dumps(summary(entry), ensure_ascii=False))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
