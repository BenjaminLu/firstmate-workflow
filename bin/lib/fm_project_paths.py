"""Canonical external storage paths. Resolution is read-only and fails closed."""
import os
from pathlib import Path
import re
import subprocess


def external_home(engine, name, configured_home=''):
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
    if (engine / '.git').exists():
        result = subprocess.run(['git', '-C', str(engine), 'rev-parse', '--git-common-dir'],
                                text=True, capture_output=True)
        if result.returncode == 0:
            common = (engine / result.stdout.strip()).resolve()
            if common.name == '.git': roots.append(common.parent)
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
    for directory in (project / 'tasks', project / 'worktrees'):
        if directory.is_dir():
            for path in directory.iterdir():
                if path.is_symlink():
                    raise ValueError('project entry must not be a symlink: ' + str(path))
    state = project / 'state'
    if state.is_dir():
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


def record_root(root):
    """Resolve CLI callers too; never trust an arbitrary state-path override."""
    import subprocess
    engine = Path(root).resolve()
    config = engine / 'config.yaml'
    if not config.is_file():
        if os.environ.get('FM_PROJECT'):
            raise ValueError('project records require engine configuration')
        return Path(root)
    lib = Path(__file__).resolve().parents[1] / 'fm-config.sh'
    code = '. "$1"; n="$(fm_projects "$2")" || exit 65; [ -n "$n" ] || { printf "%s" "$3"; exit; }; p="$(fm_project_resolve "" "$2")" && fm_project_get "$p" home "$2"'
    storage = Path(subprocess.check_output(['bash', '-c', code, 'fm-paths', str(lib),
                                          str(config), str(root)], text=True).strip())
    if storage != engine:
        legacy = engine / 'state/projects' / storage.name
        if legacy.exists() or legacy.is_symlink():
            raise ValueError('legacy project requires approved migration before record access')
    return storage
