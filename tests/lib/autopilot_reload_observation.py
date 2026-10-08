"""Passive, test-only observations of the reload fixture's publication boundary."""
import fcntl
import json
import os

# Disable inherited Herdr routing before imports or fixtures can reach fm.
os.environ['HERDR_ENV'] = '0'

import fm_autopilot as A


def read_completion(directory):
    """Return (owner, normalized reload), or None immediately if publication is busy."""
    with (directory / 'start.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return None
        return A.read_json(directory / 'owner.json'), A.read_reload(directory)


def completed(snapshot, target, old_pid=None):
    """Keep bounded waits pending until both records describe the exact target."""
    if snapshot is None:
        return None
    owner, reload = snapshot
    outcome = reload.get('outcome') or {}
    if (owner.get('started_ok') and owner.get('code') == target
            and (old_pid is None or owner.get('pid') != old_pid)
            and outcome.get('kind') == 'reloaded' and outcome.get('to') == target):
        return snapshot
    return None


def service_live(directory):
    """Probe an existing lock without creating service state or calling running()."""
    try:
        lock = (directory / 'service.lock').open('rb')
    except FileNotFoundError:
        return False
    with lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
    return False


def process_state(pid):
    if type(pid) is not int or pid <= 0:
        return dict(pid=pid, alive=None)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return dict(pid=pid, alive=False)
    return dict(pid=pid, alive=True)


def timeout_report(directory, elapsed):
    """Independent best-effort probes: a broken probe cannot hide other evidence."""
    def probe(callback):
        try:
            return callback()
        except Exception as error:
            return dict(diagnostic_error=type(error).__name__)

    def log_tail():
        with (directory / 'service.log').open('rb') as log:
            log.seek(0, os.SEEK_END)
            log.seek(max(0, log.tell() - 8192))
            # Ignore a partial UTF-8 character at the byte boundary; output also
            # stays within 8 KiB when encoded back to UTF-8.
            return log.read(8192).decode('utf-8', errors='ignore')

    owner = probe(lambda: json.loads((directory / 'owner.json').read_text()))
    reload = probe(lambda: json.loads((directory / 'reload.json').read_text()))
    coherent = probe(lambda: read_completion(directory))
    lock_state = ('busy' if coherent is None else
                  'unavailable' if isinstance(coherent, dict) else 'available')
    recorded = owner if isinstance(owner, dict) else {}
    return dict(elapsed_seconds=elapsed, owner=owner, reload=reload,
                coherent=coherent, start_lock=lock_state,
                service_lock_live=probe(lambda: service_live(directory)),
                processes={name: probe(lambda field=field: process_state(recorded.get(field)))
                           for name, field in [('owner', 'owner'), ('service', 'pid')]},
                service_log_tail=probe(log_tail))
