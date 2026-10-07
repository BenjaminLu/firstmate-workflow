#!/usr/bin/env python3
"""Validate the only external spec prose approved for public publication."""
import json
import os
import re
import sys


CONVENTIONAL = re.compile(r'^(\[[A-Za-z][A-Za-z0-9]*-[0-9]+\] )?(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\([a-z0-9][a-z0-9._-]{0,29}\))?!?: \S')


def validate(title, summary, style='plain', changes=None):
    """Return field-specific problems; None means the summary was omitted."""
    import fm_ste

    problems = []
    fields = [('public_title', title), ('public_summary', summary)]
    if changes is not None:
        if not isinstance(changes, list) or not 1 <= len(changes) <= 10:
            problems.append('public_changes: expected a list of 1-10 strings')
        else:
            fields.extend((f'public_changes[{i}]', value) for i, value in enumerate(changes))
    for field, value in fields:
        if field == 'public_summary' and value is None:
            continue
        if not isinstance(value, str):
            problems.append(field + ': expected a string')
            continue
        is_title = field == 'public_title'
        text = value.strip() if is_title else value
        is_change = field.startswith('public_changes[')
        multiline = not is_title and not is_change
        low, high = (8, 80) if is_title else (1, 200) if is_change else (1, 600)
        if not low <= len(text) <= high or not text.strip():
            problems.append(f'{field}: expected {low}-{high} characters')
        if not multiline and ('\n' in value or '\r' in value):
            problems.append(field + ': expected one line')
        if any(not 32 <= ord(c) <= 126 and not (multiline and c == '\n') for c in value):
            problems.append(field + ': expected printable ASCII' + (' plus newlines' if multiline else ''))
        if any(token in value.lower() for token in ('/', '\\', '.json', '.md', 'fm_home', '~/', 'design/', 'tasks/', 'state/')):
            problems.append(field + ': path-like text is not public prose')
        # Task ids use T-<slug>; validate has no task context, so reject any
        # task-id prefix rather than allowing another private task reference.
        if is_title and re.match(r'T-[A-Za-z0-9]+', text, re.I):
            problems.append(field + ': must not start with a task id')
        conventional = is_title and CONVENTIONAL.match(text)
        if is_title and style == 'conventional' and not conventional:
            problems.append('public_title: expected a conventional subject such as fix(scope): text')
        prose = text.split(': ', 1)[1] if conventional else text
        for issue in fm_ste.check(prose)['issues']:
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
        problems = validate(spec.get('public_title'), spec.get('public_summary'),
                            os.environ.get('FM_PR_TITLE', 'plain'), spec.get('public_changes'))
    except (ValueError, OSError, ImportError) as error:
        problems = [str(error)]
    for problem in problems:
        print(problem)
    sys.exit(65 if problems else 0)
