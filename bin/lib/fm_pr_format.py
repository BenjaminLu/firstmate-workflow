#!/usr/bin/env python3
"""Render external PRs from validated public fields and confirmed format data."""
import argparse
import json
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True
from fm_public_text import validate

START = '<!-- fm:testing -->'
END = '<!-- /fm:testing -->'


def heading_class(heading):
    heading = heading.lower()
    if 'ai' in heading and any(word in heading for word in ('参与', '參與', 'participation', 'involvement')):
        return 'ai'
    for kind, words in (('summary', ('summary', '摘要', '概要')),
                        ('testing', ('test', '测试', '測試')),
                        ('changes', ('change', '改动', '变更', '變更'))):
        if any(word in heading for word in words):
            return kind
    return None


def render(spec, fmt, required_checks, review_mode='diff', unrunnable=False):
    if validate(spec.get('public_title'), spec.get('public_summary'),
                style='plain', changes=spec.get('public_changes')):
        return None
    summary = spec.get('public_summary') or ''
    sections = fmt.get('pr_sections', [])
    body = summary
    if sections:
        tests = [f'- [ ] {name}: pending' for name in required_checks]
        if review_mode == 'run':
            tests.append('- [ ] Local tests: run in the firstmate review')
        if unrunnable:
            tests.append('- [ ] Local tests: not run on this machine')
        content = dict(
            summary='\n'.join(line if line.startswith('- ') else '- ' + line
                              for line in summary.splitlines() if line.strip()),
            changes='\n'.join('- ' + item for item in spec.get('public_changes') or []),
            testing='\n'.join([START, *tests, END]),
            ai='- [x] 🤖 AI-Generated\n- [ ] 🤝 AI-Assisted\n- [ ] 👤 Human-Written')
        body = '\n\n'.join('## ' + heading + '\n\n' + content[heading_class(heading)]
                           for heading in sections if content.get(heading_class(heading)))
    return dict(title=spec['public_title'].strip(), body=body)


def refresh_testing(body, states):
    """Preserve all bytes outside CI checklist lines within the owned markers."""
    lines = body.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if line.rstrip('\r\n') == START]
    ends = [i for i, line in enumerate(lines) if line.rstrip('\r\n') == END]
    if not starts or not ends or ends[0] <= starts[0]:
        return None
    for i in range(starts[0] + 1, ends[0]):
        text = lines[i].rstrip('\r\n')
        match = re.fullmatch(r'- \[[ x]\] (.+): (.*)', text)
        if not match or match[1] == 'Local tests':
            continue
        state = states.get(match[1])
        if state in ('passed', 'failed', 'pending'):
            tick = 'x' if state == 'passed' else ' '
            lines[i] = f'- [{tick}] {match[1]}: {state}' + lines[i][len(text):]
    return ''.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['render'])
    parser.add_argument('--spec', required=True)
    parser.add_argument('--format', required=True)
    parser.add_argument('--required-checks', required=True)
    parser.add_argument('--review-mode', default='diff')
    parser.add_argument('--unrunnable', choices=['0', '1'], default='0')
    args = parser.parse_args()
    try:
        spec = json.loads(Path(args.spec).read_text())
        fmt = json.loads(args.format)
        result = render(spec, fmt, json.loads(args.required_checks), args.review_mode, args.unrunnable == '1')
        if result is None:
            return 65
        print(json.dumps(result))
    except (OSError, ValueError, TypeError, AttributeError, ImportError):
        return 65
    return 0


if __name__ == '__main__':
    sys.exit(main())
