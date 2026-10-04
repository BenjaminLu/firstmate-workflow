#!/usr/bin/env python3
"""Heading texts that task prompts anchor in design.md must not disappear (T-189).

  design_anchors.py generate <design.md> <tasks-dir>   print the fixture JSON
  design_anchors.py check <fixture.json> <design.md>   exit 1 on a lost heading

The fixture records, per spec id, the section references the spec carried at
fixture time and, per role, the heading texts fm_prompt_context.anchors()
resolved for them. The check feeds the recorded references (never the current
specs) to anchors() on the current design and requires every recorded heading
text still to resolve: headings may be added, none may disappear.
"""
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'bin/lib'))
from fm_prompt_context import anchors  # noqa: E402

ROLES = ('worker', 'reviewer')
# The reference pattern anchors() applies to the serialized spec.
REFERENCE = re.compile(r'(?:§\s*|sections?\s+)(\d+(?:\.\d+)*)', re.I)


def headings(text, task, references, role):
    """Resolved heading texts, without the placeholder for a missing heading."""
    spec = {'id': task, 'references': ['§' + r for r in references]}
    return sorted({heading for heading, start, _ in anchors(text, spec, role) if start})


def generate(design, tasks):
    text = Path(design).read_text(encoding='utf-8')
    specs = {}
    for path in sorted(Path(tasks).glob('*.json')):
        spec = json.loads(path.read_text(encoding='utf-8'))
        task = spec.get('id', '')
        references = sorted(set(REFERENCE.findall(json.dumps(spec, ensure_ascii=False))))
        specs[task] = {'references': references,
                       'roles': {role: headings(text, task, references, role) for role in ROLES}}
    # One record per line keeps the fixture below the tests/ file-size limit
    # while retaining readable, independently reviewable task records.
    print('{"design_lines": ' + str(len(text.splitlines())) + ', "specs": {')
    records = [json.dumps(task) + ': ' + json.dumps(entry, ensure_ascii=False, sort_keys=True)
               for task, entry in sorted(specs.items())]
    print(',\n'.join(records))
    print('}}')


def check(fixture, design):
    text = Path(design).read_text(encoding='utf-8')
    recorded = json.loads(Path(fixture).read_text(encoding='utf-8'))['specs']
    lost = 0
    for task, entry in sorted(recorded.items()):
        for role, wanted in sorted(entry['roles'].items()):
            now = set(headings(text, task, entry['references'], role))
            for heading in wanted:
                if heading not in now:
                    print(f'{task} {role}: heading no longer resolves: {heading}')
                    lost += 1
    print(f'{len(recorded)} specs checked, {lost} recorded headings lost')
    return 1 if lost else 0


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == 'generate':
        generate(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 4 and sys.argv[1] == 'check':
        sys.exit(check(sys.argv[2], sys.argv[3]))
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(64)
