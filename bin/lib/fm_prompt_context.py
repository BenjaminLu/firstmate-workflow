#!/usr/bin/env python3
"""Render launcher-owned design context; never trim conventions or gate policy."""
import hashlib
import json
from pathlib import Path
import sys

DESIGN_CAP = 48000


def design(text):
    raw = text.encode('utf-8')
    excerpt = raw[:DESIGN_CAP].decode('utf-8', errors='ignore')
    print(f'Design cap: {DESIGN_CAP} UTF-8 bytes; source: {len(raw)} bytes; '
          f'sha256={hashlib.sha256(raw).hexdigest()}.')
    if len(raw) > DESIGN_CAP:
        print(f'TRIMMED: showing {len(excerpt.encode("utf-8"))} bytes from the start. '
              'The remaining design is omitted. Ask firstmate for relevant omitted '
              'sections before deciding anything that depends on them.')
    print()
    print(excerpt)


def main():
    if sys.argv[1] == 'pin':
        pin = json.load(sys.stdin)
        print('\n# Approved spec pin\n')
        fields = ('project', 'task', 'version', 'engine_commit', 'target_base_commit',
                  'source', 'approval_binding', 'contract')
        record = {key: pin.get(key) for key in fields}
        record['approval'] = {key: pin.get('approval', {}).get(key)
                              for key in ('decision', 'author', 'time', 'kind')}
        print(json.dumps(record, ensure_ascii=False, indent=2))
        print('\n# Approved design\n')
        design(pin['snapshots']['design']['text'])
        print('\n# Approved CONVENTIONS.md\n')
        print(pin['snapshots']['conventions']['text'])
    else:
        path = Path(sys.argv[2])
        if path.is_file():
            design(path.read_text(encoding='utf-8'))
        else:
            print('Design unavailable; coverage unknown. Ask firstmate for project context.')


if __name__ == '__main__':
    main()
