#!/usr/bin/env python3
"""Firstmate's host facts, separate from crew configuration and identities."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from fm_hooks import detect


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
    harness = detect()
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
    return dict(harness=harness, cli_version=version, model=model, model_source=source)


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
    save(Path(sys.argv[2]) / 'session/host.json', collect(sys.argv[1]))
