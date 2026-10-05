#!/usr/bin/env python3
"""Firstmate's host facts, separate from crew configuration and identities."""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from fm_hooks import detect_source
import fm_lifeline as life


def text(value):
    return value if isinstance(value, str) and value.strip() else None


def configured_model(root, harness):
    """A configured model is not a claim about the model serving this turn.

    Read only harness-owned settings. Session CLI overrides are not observable
    here; the source lets the board distinguish configuration from a transcript.
    """
    if harness == 'claude':
        home = Path(os.environ.get('CLAUDE_CONFIG_DIR', str(Path.home() / '.claude')))
        paths = [home / 'settings.json', root / '.claude/settings.json',
                 root / '.claude/settings.local.json']
        model, source = None, None
        for path in paths:
            try:
                value = text(json.loads(path.read_text()).get('model'))
                if value:
                    model, source = value, str(path) + ':model'
            except (OSError, ValueError, AttributeError):
                continue
        return model, source
    if harness == 'codex':
        path = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))) / 'config.toml'
        try:
            import tomllib
            data = tomllib.loads(path.read_text())
            model = text(data.get('model'))
            return model, str(path) + ':model' if model else None
        except (ImportError, OSError, ValueError):
            return None, None
    return None, None


def collect(root):
    root = Path(root).resolve()
    harness, detection_source = detect_source()
    version = None
    # Never execute an arbitrary FM_HARNESS value as a command.
    cli = {'claude': 'claude', 'codex': 'codex', 'cursor': 'cursor-agent'}.get(harness)
    if cli:
        try:
            result = subprocess.run([cli, '--version'], cwd=root, capture_output=True,
                                    text=True, timeout=10, check=True)
            version = text(result.stdout.strip())
        except (OSError, subprocess.SubprocessError):
            pass
    model, source = configured_model(root, harness)
    try:
        pid = life.session_owner()
        session = dict(pid=pid, started=process_field(pid, 'lstart'))
    except (RuntimeError, ValueError, OSError):
        session = None
    return dict(harness=harness, cli_version=version, model=model, model_source=source,
                session=session, source=detection_source,
                written_by=dict(pid=os.getpid(), parent_command=process_field(os.getppid(), 'command')[:200]))


def process_field(pid, field):
    try:
        return subprocess.run(['ps', '-p', str(pid), '-o', field + '='],
                              capture_output=True, text=True, timeout=10, check=True).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ''


def decide(previous, detected):
    """Return the record to write, or None to keep its exact existing bytes."""
    if detected.get('source') is not None:
        return dict(detected, confirmed=True)
    if not previous or previous.get('harness') is None:
        return dict(detected, confirmed=False)
    if detected.get('session') is not None and detected['session'] == previous.get('session'):
        return None
    since = (previous.get('unconfirmed_since') if previous.get('confirmed') is False else None)
    return dict(previous, confirmed=False,
                unconfirmed_since=since or datetime.now(timezone.utc).isoformat(),
                last_unknown={key: detected.get(key) for key in ('session', 'written_by')})


def save(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.host-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, indent=2)
            stream.write('\n')
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == '__main__':
    path = Path(sys.argv[2]) / 'session/host.json'
    try:
        previous = json.loads(path.read_text())
        if not isinstance(previous, dict):
            previous = None
    except (OSError, ValueError):
        previous = None
    value = decide(previous, collect(sys.argv[1]))
    if value is not None:
        save(path, value)
