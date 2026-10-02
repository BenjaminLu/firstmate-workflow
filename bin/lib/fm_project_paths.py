"""Canonical external storage paths. Resolution is read-only and fails closed."""
import os
from pathlib import Path
import re
import importlib.util


def external_home(engine, name, configured_home='', *, records_only=False):
    engine = Path(engine).resolve()
    if not re.fullmatch(r'[a-z0-9-]{1,24}', name):
        raise ValueError('invalid project name')
    value = os.environ.get('FM_HOME', configured_home or '~/.firstmate')
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError('FM_HOME must not contain control characters')
    home = Path(value).expanduser()
    if not home.is_absolute():
        raise ValueError('FM_HOME must be an absolute path')
    if '..' in home.parts:
        raise ValueError('FM_HOME must not contain traversal')
    # Canonicalize existing ancestors, including an operator-owned home alias.
    home = home.resolve()
    roots = [engine]
    git_dir = engine / '.git'
    if git_dir.is_file():
        pointer = git_dir.read_text().strip()
        if not pointer.startswith('gitdir: '):
            raise ValueError('invalid engine git directory')
        git_dir = (engine / pointer[8:]).resolve()
    common_file = git_dir / 'commondir'
    common = (git_dir / common_file.read_text().strip()).resolve() if common_file.is_file() else git_dir
    if common.name == '.git':
        roots.append(common.parent.resolve())
    if any(home == root or root in home.parents for root in roots):
        raise ValueError('FM_HOME must be outside the engine working tree')
    project = home / 'projects' / name
    for path in (home / 'projects', project):
        if path.is_symlink():
            raise ValueError('project storage must not be a symlink: ' + str(path))
    # Check all immediate stores before any caller creates or mutates one.
    for child in ('repo', 'worktrees', 'CONVENTIONS.md', 'tasks', 'design.md', 'state'):
        path = project / child
        if path.is_symlink():
            raise ValueError('project store must not be a symlink: ' + str(path))
    for rel in ('.git', '.git/config', '.git/info', '.git/info/exclude',
                'repo/.git', 'repo/.git/config', 'repo/.git/info', 'repo/.git/info/exclude'):
        if (project / rel).is_symlink():
            raise ValueError('project git administration must not be a symlink: ' + str(project / rel))
    remaining = 4096
    for directory in (project / 'tasks', project / 'worktrees'):
        if directory.is_dir():
            with os.scandir(directory) as entries:
                for entry in entries:
                    remaining -= 1
                    if records_only and remaining < 0:
                        raise ValueError('project entry validation limit exceeded')
                    if entry.is_symlink():
                        raise ValueError('project entry must not be a symlink: ' + entry.path)
    state = project / 'state'
    if records_only:
        validate_records(state)
    elif state.is_dir():
        # Execution artifacts and source-code copies are distinct. Repository
        # content may contain symlinks; routing records and locks may not.
        copies = {'mirrors', 'rescued', 'review-checkouts', 'gate-worktrees', 'tmp'}
        for directory, dirs, files in os.walk(state, followlinks=False):
            for item in dirs + files:
                path = Path(directory) / item
                if path.is_symlink():
                    raise ValueError('project record must not be a symlink: ' + str(path))
            if Path(directory) == state: dirs[:] = [item for item in dirs if item not in copies]
    return project


def validate_records(state):
    """Bound routing validation without descending into repository copies."""
    todo = [state]
    remaining = 4096
    copies = {'mirrors', 'rescued', 'review-checkouts', 'gate-worktrees', 'tmp'}
    while todo:
        path = todo.pop()
        if path.is_symlink():
            raise ValueError('project record must not be a symlink: ' + str(path))
        if not path.is_dir() or (path.parent == state and path.name in copies):
            continue
        with os.scandir(path) as entries:
            for entry in entries:
                remaining -= 1
                if remaining < 0:
                    raise ValueError('project record validation limit exceeded')
                if entry.is_symlink():
                    raise ValueError('project record must not be a symlink: ' + entry.path)
                if entry.is_dir(follow_symlinks=False):
                    todo.append(Path(entry.path))


_reader = None

def registry_reader():
    global _reader
    if _reader is None:
        reader = Path(__file__).resolve().parents[1] / 'fm-herdr.py'
        if not reader.is_file():
            return None
        spec = importlib.util.spec_from_file_location('fm_storage_reader', reader)
        _reader = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_reader)
    return _reader


def record_root(root):
    """Pure Python routing; self readers need neither a shell nor a registry.

    Inspect routing ancestors and a bounded set of record entries here,
    excluding repository copies. Project setup performs full validation.
    """
    engine = Path(root).resolve()
    herdr = registry_reader()
    selected = os.environ.get('FM_PROJECT', '')
    if herdr is None:
        if selected and os.environ.get('FM_EXTERNAL') == '1':
            raise ValueError('external project registry reader is unavailable')
        return engine
    try:
        lines = herdr._config_lines(engine)
        block = herdr._config_key(lines, 'projects')
        if block is None:
            return engine
        if block[0]:
            raise ValueError('projects must be a map')
        body = [line for line in block[1] if line.strip()]
        level = min((herdr._indent(line) for line in body), default=0)
        names = []
        for line in body:
            if herdr._indent(line) != level:
                continue
            match = re.fullmatch(r'\s*([a-z0-9-]{1,24}):\s*', line)
            if not match or match[1] in names:
                raise ValueError('invalid project registry')
            names.append(match[1])
        projects = {}
        for name in names:
            _, children = herdr._config_key(body, name)
            entry = {}
            for key in ('repo', 'github', 'base', 'required_check'):
                field = herdr._config_key(children, key)
                if field:
                    if any(line.strip() for line in field[1]):
                        raise ValueError('invalid project field')
                    entry[key] = herdr._project_scalar(field[0], key)
            if entry.get('repo', '.') != '.' or not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', entry.get('github', '')):
                raise ValueError('invalid project repository')
            if not entry.get('base') or not entry.get('required_check'):
                raise ValueError('incomplete project registry')
            projects[name] = entry
        default = herdr._config_key(lines, 'default_project')
        default = herdr._project_scalar(default[0], 'default_project') if default else ''
        home = herdr._config_key(lines, 'home')
        home = herdr._project_scalar(home[0], 'home') if home else ''
    except (OSError, ValueError):
        if selected and selected != 'firstmate-workflow':
            raise ValueError('named project registry is unavailable') from None
        return engine
    if not projects:
        return engine
    name = selected or default or next((n for n, e in projects.items() if e.get('repo') == '.'), '')
    if not name:
        return engine
    if name not in projects:
        raise ValueError('unregistered project ' + name)
    if projects[name].get('repo') == '.':
        return engine
    storage = external_home(engine, name, home, records_only=True)
    legacy = engine / 'state/projects' / name
    if legacy.exists() or legacy.is_symlink():
        raise ValueError('legacy project requires approved migration before record access')
    return storage
