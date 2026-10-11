"""Spec checks and the reader of stored spec preflight receipts.

The spec preflight is gone (T-297): the worker's first round checks the spec
against the code. Receipts written before T-297 stay readable, and nothing
needs one. The checks the preflight ran before its reviewer run at pin time.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sys


def decision(answer, task):
    """The verdict on the answer's last line. Receipts written before T-288
    also carry a numbered list; the verdict they bind reads the same."""
    # Imported here so the pin-time check needs no evidence store module.
    from fm_evidence import unquoted
    lines = answer.strip().splitlines()
    markers = [line for line in unquoted(answer) if re.fullmatch(r'SPEC-(?:OK|GAPS):\S+', line)]
    if len(markers) != 1 or not lines or lines[-1] != markers[0]:
        return None
    for verdict in ('SPEC-OK', 'SPEC-GAPS'):
        if markers[0] == verdict + ':' + task:
            return verdict
    return None


def repository_path(value):
    if (not isinstance(value, str) or not value or value.startswith('/') or '\\' in value
            or any(part in ('', '.', '..') for part in value.split('/'))
            or any(ord(c) < 32 or 127 <= ord(c) <= 159 or 55296 <= ord(c) <= 57343 for c in value)):
        raise ValueError('change_refs: expected normalized repository-relative path')
    return value


def validate_change_refs(spec):
    """Validate locale-free walk fields and evidence visible before confirmation."""
    explain = spec.get('explain', {})
    # Legacy isolated installations do not need the optional STE module.
    # Detect presence before importing; orphan top-level fields still refuse.
    enriched = isinstance(explain, dict) and any(
        isinstance(explain.get(lang), dict) and field in explain[lang]
        for lang in ('en', 'zh-TW') for field in ('change_points', 'door', 'check'))
    if not enriched:
        if 'change_refs' in spec or 'check_answer' in spec:
            raise ValueError('change_refs/check_answer: orphan field')
        return
    import fm_ste
    fm_ste._validate(explain)
    points = explain['en']['change_points']
    refs = spec.get('change_refs')
    if not isinstance(refs, list) or not refs or len(refs) != len(points):
        raise ValueError('change_refs: length must match change_points')
    acceptance = spec.get('acceptance', [])
    for ref in refs:
        if not isinstance(ref, dict) or set(ref) != {'files', 'tests', 'acceptance'}:
            raise ValueError('change_refs: expected files, tests and acceptance')
        files, tests, indices = ref['files'], ref['tests'], ref['acceptance']
        if not isinstance(files, list) or not files or not isinstance(tests, list) or not tests or not isinstance(indices, list) or not indices:
            raise ValueError('change_refs: expected nonempty arrays')
        normalized = [repository_path(file) for file in files]
        if len(set(normalized)) != len(normalized):
            raise ValueError('change_refs.files: duplicate paths')
        seen = set()
        for test in tests:
            if not isinstance(test, dict) or set(test) != {'file', 'name'}:
                raise ValueError('change_refs.tests: expected file and name')
            repository_path(test['file'])
            fm_ste._text(test['name'], 'change_refs.tests.name')
            pair = (test['file'], test['name'])
            if pair in seen:
                raise ValueError('change_refs.tests: duplicate test')
            seen.add(pair)
        if any(not fm_ste._integer(index, 0, len(acceptance) - 1) for index in indices) or len(set(indices)) != len(indices):
            raise ValueError('change_refs.acceptance: invalid or duplicate index')
    if explain['en']['door']['kind'] == 'two-way':
        if 'check_answer' in spec:
            raise ValueError('check_answer: forbidden for two-way door')
        return
    answer = spec.get('check_answer')
    for lang in fm_ste.LOCALES:
        loc = explain[lang]
        check = loc['check']
        if not fm_ste._integer(answer, 0, len(check['options']) - 1):
            raise ValueError('check_answer: missing or out of range')
        number = check['about']['intent']
        visible = [loc['intent'][number - 1]['text'], loc['door']['reason'], loc['door']['rollback']]
        visible += [p['how'] for p in loc['change_points'] if p['intent'] == number]
        if not any(check['options'][answer] in text for text in visible):
            raise ValueError(lang + '.check: correct answer absent from visible evidence')


def validate_spec(task, spec):
    """Every check a submitted spec meets before it pins."""
    if not isinstance(spec, dict) or spec.get('id') != task or not spec.get('scope') or not spec.get('acceptance'):
        raise ValueError('a spec needs the task identity, scope and acceptance lines')
    if 'adopt' in spec:
        if os.environ.get('FM_EXTERNAL') != '1':
            raise ValueError('adopt is only supported for external projects')
        from fm_adopt import validate
        validate(spec['adopt'])
    if os.environ.get('FM_EXTERNAL') == '1':
        from fm_public_text import validate
        problems = validate(spec.get('public_title'), spec.get('public_summary'),
                            os.environ.get('FM_PR_TITLE', 'plain'), spec.get('public_changes'))
        if problems:
            raise ValueError('external spec needs a valid public_title: ' + '; '.join(problems))
        from fm_public_text import plain_problems
        problems = plain_problems(spec.get('public_title'), spec.get('public_summary'), spec.get('public_changes'))
        if problems:
            raise ValueError('external public text is not plain (skills/firstmate/plain-writing.md): '
                             + '; '.join(problems))
    if 'explain' in spec:
        try:
            import fm_ste
            report = fm_ste.check_explain(spec['explain'])
            if not report['ok']:
                raise ValueError('STE check failed')
        except (ImportError, ValueError) as error:
            raise ValueError('explain: ' + str(error)) from error
    validate_change_refs(spec)


def check(task, data):
    """The pin-time spec check (T-297): every check the removed preflight ran
    before its reviewer. Raises ValueError on the first failure."""
    try:
        spec = json.loads(data)
    except ValueError as error:
        raise ValueError('spec is not JSON: ' + str(error)) from error
    validate_spec(task, spec)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    # require is what launchers written before T-297 still call before their
    # adapter. No step needs a SPEC-OK record any more, so it passes.
    p.add_argument('command', choices=['check', 'require'])
    p.add_argument('--task', required=True)
    p.add_argument('--spec', default='')
    for name in ('state', 'project'):
        p.add_argument('--' + name, default='')
    p.add_argument('--pin-stdin', action='store_true')
    a = p.parse_args()
    if a.command == 'require':
        return
    if not a.spec:
        p.error('check needs --spec')
    check(a.task, Path(a.spec).read_bytes())


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('fm-spec-check: ' + str(error), file=sys.stderr)
        sys.exit(65)
