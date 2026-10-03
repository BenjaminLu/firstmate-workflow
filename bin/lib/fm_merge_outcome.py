"""Merge record semantics shared by Python turn readers.

Keep parity with board/server.ts mergeOf: recognized modern values take
precedence, otherwise only literal legacy booleans report a final outcome.
The board cannot import this Python module; parity is covered by tests.
"""


def merge_outcome(record):
    if not isinstance(record, dict):
        return None
    outcome = record.get('merge')
    if outcome in ('running', 'merged', 'failed'):
        return outcome
    legacy = record.get('merged')
    ok = legacy.get('ok') if isinstance(legacy, dict) else None
    return 'merged' if ok is True else 'failed' if ok is False else None
