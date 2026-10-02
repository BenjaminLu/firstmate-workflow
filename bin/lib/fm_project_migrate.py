"""Approved, offline consolidation of legacy project records with rollback."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def migrate(source, target, origin):
    source, target = Path(source), Path(target)
    name = source.name
    engine = source.parents[2]
    state = engine / 'state'
    for path in (source, *source.parents, target, *target.parents):
        if path.is_symlink():
            raise ValueError('migration routing path is a symlink')
    if target.exists():
        raise ValueError('destination already exists; retain both stores for recovery')
    for rel in ('repo', 'repo/.git', 'repo/.git/config', 'repo/.git/info',
                'repo/.git/info/exclude', 'state', 'tasks', 'worktrees'):
        if (source / rel).is_symlink():
            raise ValueError('legacy routing path is a symlink: ' + rel)
    repo = source / 'repo'
    if not (repo / '.git').is_dir() or (repo / '.git').is_symlink():
        raise ValueError('legacy clone has no independent git directory')

    def git(*args):
        return subprocess.check_output(['git', '-C', str(repo), *args], text=True).strip()

    if git('rev-parse', '--show-toplevel') != str(repo):
        raise ValueError('legacy clone root mismatch')
    if git('remote', 'get-url', 'origin') != origin or git('remote', 'get-url', '--push', 'origin') != origin:
        raise ValueError('legacy origin mismatch')
    if len([line for line in git('worktree', 'list', '--porcelain').splitlines()
            if line.startswith('worktree ')]) != 1:
        raise ValueError('retire registered worktrees before offline migration')

    def owned(record):
        if not isinstance(record, dict):
            return False
        return (record.get('project') == name
                or str(record.get('id', '')).startswith('D-' + name + '-')
                or isinstance(record.get('identity'), dict) and record['identity'].get('project') == name
                or isinstance(record.get('data'), dict) and owned(record['data']))

    def offline_owner(path):
        if path.suffix != '.pid' and path.name != 'process.json':
            return
        text = path.read_text().strip()
        try:
            value = json.loads(text)
        except ValueError:
            value = text.split()[0] if text else None
        if isinstance(value, dict):
            pid = value.get('pid')
            if pid is None and value.get('status') in ('completed', 'failed', 'stopped', 'exited'):
                return
        else:
            pid = value
        try:
            pid = int(pid)
            if pid <= 0:
                raise ValueError()
        except (TypeError, ValueError):
            raise ValueError('ownership record cannot establish an offline owner: ' + str(path))
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        except PermissionError:
            pass
        raise ValueError('stop the live owner before offline migration: ' + str(path))

    moves = []
    streams = []
    # A project namespace owns its full contents, including opaque prompts,
    # wake/recovery records, diagrams, mirror generations and future stores.
    def collect(path, dest):
        if path.is_symlink():
            raise ValueError('legacy record is a symlink: ' + str(path))
        if not path.exists():
            return
        for ancestor in path.parents:
            if ancestor == engine:
                break
            if ancestor.is_symlink():
                raise ValueError('legacy record parent is a symlink')
        if path.is_dir():
            for child in sorted(path.iterdir()):
                collect(child, dest / child.name)
        elif path.is_file():
            offline_owner(path)
            moves.append((path, dest))
        else:
            raise ValueError('retire live IPC before offline migration: ' + str(path))

    collect(engine / 'projects' / name, target)
    run_roots = set()
    for identity in (state / 'runs').glob('*/identity.json'):
        if owned(json.loads(identity.read_text())):
            run_roots.add(identity.parent)
            collect(identity.parent, target / 'state/runs' / identity.parent.name)

    def scan(directory):
        for path in sorted(directory.iterdir()):
            if path == state / 'projects' or path in run_roots:
                continue
            rel = path.relative_to(state)
            dest = target / 'state' / rel
            if path.name == name or path.name.startswith('D-' + name + '-'):
                collect(path, dest)
            elif path.is_symlink():
                # Never traverse another project's or an ambiguous routing link.
                raise ValueError('shared record routing is a symlink: ' + str(path))
            elif path.is_dir():
                scan(path)
            elif path.suffix == '.jsonl':
                raw = path.read_bytes()
                selected, remaining = [], []
                for line in raw.splitlines(keepends=True):
                    (selected if line.strip() and owned(json.loads(line)) else remaining).append(line)
                if selected:
                    streams.append((path, dest, raw, b''.join(selected), b''.join(remaining)))
            elif path.suffix == '.json':
                try:
                    record = json.loads(path.read_text())
                except (ValueError, UnicodeError):
                    continue
                if owned(record):
                    collect(path, dest)
    scan(state)

    # Validate and hash the complete plan before its first mutation. A collision
    # is never overwritten, even when the operator approved migration generally.
    def fingerprint(path):
        if path.is_symlink():
            # Source files may be symlinks; git administration and records may not.
            relative = path.relative_to(source if source in path.parents else target)
            if relative.parts[0] == 'repo' and '.git' not in relative.parts:
                return 'symlink:' + os.readlink(path)
            raise ValueError('legacy record symlink: ' + str(path))
        if path.is_file():
            return hashlib.sha256(path.read_bytes()).hexdigest()
        if not path.is_dir():
            raise ValueError('retire live IPC before migration: ' + str(path))
        return None

    retained = {str(p.relative_to(source)): fingerprint(p) for p in source.rglob('*')}
    for path in source.rglob('*'):
        if path.is_file():
            offline_owner(path)
    seen = set()
    hashes = {}
    for old, new in moves:
        rel = new.relative_to(target)
        if new in seen or (source / rel).exists():
            raise ValueError('conflicting retained record: ' + str(rel))
        seen.add(new)
        hashes[str(new)] = fingerprint(old)
    for old, new, raw, selected, remaining in streams:
        if new in seen:
            raise ValueError('conflicting shared stream: ' + str(new))
        seen.add(new)
        existing = source / new.relative_to(target)
        if existing.exists():
            fingerprint(existing)
            # Retain existing stream bytes as well as shared records.
            for line in existing.read_bytes().splitlines():
                if line.strip():
                    json.loads(line)

    if (source / 'state/migration-recovery').exists():
        raise ValueError('recover the previous migration journal before migrating again')
    target.parent.mkdir(parents=True, exist_ok=True)
    os.rename(source, target)
    journal = target / 'state/migration-recovery'
    done = []
    rewritten = []
    try:
        if {str(p.relative_to(target)): fingerprint(p) for p in target.rglob('*')} != retained:
            raise ValueError('retained clone or records changed during rename')
        journal.mkdir(parents=True, exist_ok=False)
        plan = {'source': str(source), 'target': str(target),
                'moves': [[str(a), str(b)] for a, b in moves], 'streams': []}
        for i, (old, new, raw, selected, remaining) in enumerate(streams):
            (journal / str(i)).write_bytes(raw)
            plan['streams'].append({'source': str(old), 'target': str(new), 'backup': str(i)})
        (journal / 'plan.json').write_text(json.dumps(plan, indent=2) + '\n')
        for old, new in moves:
            new.parent.mkdir(parents=True, exist_ok=True)
            os.rename(old, new)
            done.append((old, new))
            if fingerprint(new) != hashes[str(new)]:
                raise ValueError('retained shared record changed: ' + str(new))
        for old, new, raw, selected, remaining in streams:
            if old.read_bytes() != raw:
                raise ValueError('shared stream changed during offline migration')
            previous = new.read_bytes() if new.exists() else None
            rewritten.append((old, new, raw, previous))
            new.parent.mkdir(parents=True, exist_ok=True)
            combined = (previous or b'')
            if combined and not combined.endswith(b'\n'):
                combined += b'\n'
            combined += selected
            new.write_bytes(combined)
            if new.read_bytes() != combined:
                raise ValueError('shared stream retention verification failed')
            temp = old.with_name(old.name + '.migration-tmp')
            with temp.open('xb') as out:
                out.write(remaining)
            os.replace(temp, old)
        shutil.rmtree(journal)
    except Exception:
        # On any failed verification restore shared stores before the clone.
        # If rollback itself fails, the outside-engine journal stays recoverable.
        for old, new, raw, previous in reversed(rewritten):
            old.write_bytes(raw)
            if previous is None:
                new.unlink(missing_ok=True)
            else:
                new.write_bytes(previous)
        for old, new in reversed(done):
            old.parent.mkdir(parents=True, exist_ok=True)
            os.rename(new, old)
        shutil.rmtree(journal, ignore_errors=True)
        os.rename(target, source)
        raise
    # Remove only empty directories left by the verified file transfers.
    for old, _ in moves:
        parent = old.parent
        while parent != engine and parent != state:
            try:
                parent.rmdir()
            except OSError:
                break
            parent = parent.parent
