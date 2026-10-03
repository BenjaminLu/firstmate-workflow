#!/usr/bin/env python3
"""Materialize complete launcher-owned round inputs and render their index."""
import hashlib
import json
import os
from pathlib import Path
import re
import sys

FILES = {'spec': 'spec.json', 'design': 'design.md',
         'conventions': 'CONVENTIONS.md', 'contract': 'contract.yaml'}


def digest(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def materialize(pin, folder):
    """The caller resolves approval provenance; verify bytes again before writing."""
    snapshots = pin['snapshots']
    if set(snapshots) != set(FILES):
        raise ValueError('incomplete pin snapshots')
    expected = {}
    for key, name in FILES.items():
        snap = snapshots[key]
        if digest(snap['text']) != snap['sha256']:
            raise ValueError(key + ' snapshot hash mismatch')
        if key == 'conventions' and (snap.get('source') == 'absent' or snap.get('absent')):
            if snap['text']:
                raise ValueError('absent conventions contain text')
            continue
        expected[name] = snap['text'].encode('utf-8')
    if not folder.is_absolute() or folder.name != 'pinned':
        raise ValueError('pinned folder must be an absolute pinned/ path')
    if any(p.is_symlink() for p in (folder, *folder.parents)):
        raise ValueError('pinned folder must not traverse symlinks')
    if folder.exists():
        if {p.name for p in folder.iterdir()} != set(expected):
            raise ValueError('pinned folder contents mismatch')
        for name, data in expected.items():
            path = folder / name
            if path.is_symlink() or path.read_bytes() != data or path.stat().st_mode & 0o222:
                raise ValueError('pinned file mismatch or writable: ' + name)
        if folder.stat().st_mode & 0o222:
            raise ValueError('pinned folder is writable')
        return
    folder.mkdir(parents=True, mode=0o700)
    for name, data in expected.items():
        path = folder / name
        with path.open('xb') as stream:
            stream.write(data)
        path.chmod(0o444)
    folder.chmod(0o555)


def anchors(text, spec, role):
    """Heading ranges include subsections, excluding fenced code headings."""
    headings = []
    fence = None
    lines = text.splitlines()
    for number, line in enumerate(lines, 1):
        marker = re.match(r'^\s*(`{3,}|~{3,})', line)
        if marker:
            token = marker.group(1)
            if fence is None:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence):
                fence = None
            continue
        match = re.match(r'^(#{1,6})\s+(.+)', line)
        if match and fence is None:
            headings.append((number, len(match[1]), match[2]))
    references = set(re.findall(r'(?:§\s*|sections?\s+)(\d+(?:\.\d+)*)',
                                json.dumps(spec, ensure_ascii=False), re.I)) | {'6', '7', '8'}
    task = spec.get('id', '')
    found = set()
    for i, (start, level, heading) in enumerate(headings):
        number = re.match(r'^(\d+(?:\.\d+)*)(?:\.|\s|$)', heading)
        identifier = number[1] if number else None
        named = identifier in references
        if not (named or (task and task in heading) or re.search(r'\b' + re.escape(role) + r's?\b', heading, re.I)):
            continue
        if named:
            found.add(identifier)
        end = next((n - 1 for n, depth, _ in headings[i + 1:] if depth <= level), len(lines))
        yield heading, start, end
    for missing in sorted(references - found):
        yield '§' + missing + ' (heading not present in this design)', None, None


def render(pin, folder, role):
    print('\n# Approved spec pin\n' if pin.get('version') else '\n# Unpinned round inputs\n')
    fields = ('project', 'task', 'version', 'engine_commit', 'target_base_commit',
              'source', 'approval_binding', 'contract')
    record = {key: pin.get(key) for key in fields}
    record['approval'] = {key: pin.get('approval', {}).get(key)
                          for key in ('decision', 'author', 'time', 'kind')}
    print(json.dumps(record, ensure_ascii=False, indent=2))
    print('\n# Complete round inputs in pinned/\n')
    print('Read these complete files when needed. They are read-only; do not substitute checkout copies.')
    if not pin.get('version'):
        print('UNPINNED: legacy source snapshots, not approved pin authority.')
    for key, name in FILES.items():
        snap = pin['snapshots'][key]
        if key == 'conventions' and (snap.get('source') == 'absent' or snap.get('absent')):
            print(f'CONVENTIONS.md: absent from this project (sha256={snap["sha256"]}).')
        else:
            print(f'- {folder / name} (sha256={snap["sha256"]})')
    print('\n# Design section anchors\n')
    spec = json.loads(pin['snapshots']['spec']['text'])
    for heading, start, end in anchors(pin['snapshots']['design']['text'], spec, role):
        location = f'lines {start}-{end}' if start else 'unresolved anchor; read the complete design'
        print(f'- {heading}: {folder / "design.md"}, {location}')
    print('\n# Approved CONVENTIONS.md\n' if pin.get('version') else '\n# Unpinned CONVENTIONS.md\n')
    print(pin['snapshots']['conventions']['text'])


def legacy(spec):
    external = os.environ.get('FM_EXTERNAL') == '1'
    engine = Path(os.environ['FM_ENGINE_ROOT'])
    state = Path(os.environ['FM_STATE_DIR'])
    conventions = Path(os.environ.get('FM_ROUND_CONVENTIONS') or
                       (state.parent / 'CONVENTIONS.md' if external else engine / 'CONVENTIONS.md'))
    config = state / 'config.yaml' if external else Path(os.environ.get('FM_CONFIG') or engine / 'config.yaml')
    if external and not config.is_file():
        config = engine / 'config.yaml'
    snapshots = {'spec': dict(text=spec, sha256=digest(spec))}
    for key, path in (('design', Path(os.environ['FM_DESIGN'])),
                      ('conventions', conventions), ('contract', config)):
        absent = key == 'conventions' and not path.exists()
        text = '' if absent else path.read_bytes().decode('utf-8')
        snapshots[key] = dict(text=text, sha256=digest(text), absent=absent)
    from fm_spec_pins import contract
    # Legacy checkouts can predate a declared project contract. Preserve that
    # absence; the copied config is complete but supplies no gate authority.
    try:
        parsed = contract(snapshots['contract']['text'], os.environ.get('FM_PROJECT') or 'firstmate-workflow')
    except ValueError as error:
        if str(error) != 'no approved gate contract':
            raise
        parsed = {}
    return dict(project=os.environ.get('FM_PROJECT') or 'firstmate-workflow',
                task=json.loads(spec)['id'], version=None, source='legacy-unpinned', snapshots=snapshots,
                contract=parsed)


def main():
    role = (sys.argv[2] if len(sys.argv) > 2 else '') or 'worker'
    pin = json.load(sys.stdin) if sys.argv[1] == 'pin' else legacy(sys.stdin.read())
    path = os.environ.get('FM_PINNED_DIR')
    if not path:
        run = os.environ.get('FM_RUN_DIR')
        if not run:
            raise ValueError('missing round pinned/ folder')
        path = str(Path(run) / 'pinned')
    folder = Path(path)
    materialize(pin, folder)
    render(pin, folder, role)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        print(f'fm-prompt-context: {error}', file=sys.stderr)
        sys.exit(65)
