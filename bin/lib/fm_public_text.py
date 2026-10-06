#!/usr/bin/env python3
"""Validate the only external spec prose approved for public publication."""
import json
import re
import sys


def validate(title, summary):
    """Return field-specific problems; None means the summary was omitted."""
    import fm_ste

    problems = []
    for field, value in (('public_title', title), ('public_summary', summary)):
        if field == 'public_summary' and value is None:
            continue
        if not isinstance(value, str):
            problems.append(field + ': expected a string')
            continue
        is_title = field == 'public_title'
        text = value.strip() if is_title else value
        low, high = (8, 80) if is_title else (1, 600)
        if not low <= len(text) <= high or not text.strip():
            problems.append(f'{field}: expected {low}-{high} characters')
        if is_title and ('\n' in value or '\r' in value):
            problems.append(field + ': expected one line')
        if any(not 32 <= ord(c) <= 126 and not (not is_title and c == '\n') for c in value):
            problems.append(field + ': expected printable ASCII' + ('' if is_title else ' plus newlines'))
        if any(token in value.lower() for token in ('/', '\\', '.json', '.md', 'fm_home', '~/', 'design/', 'tasks/', 'state/')):
            problems.append(field + ': path-like text is not public prose')
        # Task ids use T-<slug>; validate has no task context, so reject any
        # task-id prefix rather than allowing another private task reference.
        if is_title and re.match(r'T-[A-Za-z0-9]+', text, re.I):
            problems.append(field + ': must not start with a task id')
        for issue in fm_ste.check(text)['issues']:
            if issue['severity'] == 'fail':
                problems.append(f"{field}: STE {issue['rule']}: {issue['detail']}")
    return problems


if __name__ == '__main__':
    try:
        if len(sys.argv) != 3 or sys.argv[1] != 'check':
            raise ValueError('usage: fm_public_text.py check <spec.json>')
        with open(sys.argv[2], encoding='utf-8') as stream:
            spec = json.load(stream)
        if not isinstance(spec, dict):
            raise ValueError('spec must be an object')
        problems = validate(spec.get('public_title'), spec.get('public_summary'))
    except (ValueError, OSError, ImportError) as error:
        problems = [str(error)]
    for problem in problems:
        print(problem)
    sys.exit(65 if problems else 0)
