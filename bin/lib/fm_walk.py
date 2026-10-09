#!/usr/bin/env python3
"""Read-only, exact-head code walks. Failures affect presentation only."""
import argparse
from copy import deepcopy
import json
import re
import subprocess
from pathlib import Path
import sys

import fm_ste


def segments(text):
    """One fence tokenizer for reading and projection: nested fences never open a walk.

    Yields ('line', text) for every line outside a walk fence, including other
    fences, and ('walk', body) for each walk fence opened at the top level.
    """
    active, body, walk = None, [], False
    for line in text.splitlines():
        match = re.match(r'^\s*(`{3,}|~{3,})(.*)$', line)
        if active:
            closing = match and match[1][0] == active[0] and len(match[1]) >= len(active) and not match[2].strip()
            if walk:
                if closing: yield 'walk', '\n'.join(body)
                else: body.append(line)
            else: yield 'line', line
            if closing: active, body, walk = None, [], False
        elif match:
            active, walk = match[1], match[2].strip() == 'walk'
            if not walk: yield 'line', line
        else: yield 'line', line
    if active and walk: yield 'walk', '\n'.join(body)


def fences(text):
    """Recognize walk fences without treating nested fences as new blocks."""
    return [body for kind, body in segments(text) if kind == 'walk']


def hunks(diff, repo='owner/repo', pr=0):
    # Selection and absent walks do not require the optional refs helper.
    from fm_card_refs import parse_diff
    result = {}
    for entry in parse_diff(diff, repo, pr, typed_rows=True):
        for item in entry['code']:
            side = 'L' if item.get('side') == 'left' else 'R'
            suffix = item.get('kind') or side + str(item['start']) + '-' + str(item['end'])
            identifier = item['file'] + '#' + suffix
            if identifier in result: raise ValueError('duplicate canonical hunk')
            result[identifier] = dict(item, side=side, id=identifier)
    return result


def fact(value):
    if not isinstance(value, str) or not value.strip() or len(fm_ste.split(value)) != 1:
        return False
    return not any(i['severity'] == 'fail' for i in fm_ste.check(value, 'fact')['issues'])


def check(text, spec, diff, repo='owner/repo', pr=0):
    blocks = fences(text)
    if not blocks: return dict(status='absent', reason='no walk')
    def invalid(reason): return dict(status='invalid', reason=reason)
    if len(blocks) != 1: return invalid('duplicate walk')
    try:
        value = json.loads(blocks[0])
    except (ValueError, TypeError): return invalid('invalid JSON')
    if not isinstance(value, dict) or set(value) != {'intents'} or not isinstance(value['intents'], list):
        return invalid('invalid walk fields')
    try: canonical = hunks(diff, repo, pr)
    except (ValueError, TypeError): return invalid('diff unavailable')
    explain = spec.get('explain', {}).get('en', {})
    count = len(explain.get('intent', []))
    scene = explain.get('scene')
    scene_nodes = {n['id'] for n in scene['nodes']} if scene else set()
    scene_edges = {e['id'] for e in scene['edges']} if scene else set()
    changes = {c['id']: c['intents'] for c in scene['changes']} if scene else {}
    used, seen, result = {}, set(), []
    total = 0
    def ids(value, allowed):
        return isinstance(value, list) and all(isinstance(n, str) and n in allowed for n in value)
    for intent in value['intents']:
        if not isinstance(intent, dict) or set(intent) != {'intent', 'key'}: return invalid('invalid intent fields')
        number = intent['intent']
        if type(number) is not int or not 1 <= number <= count: return invalid('intent out of range')
        if number in seen: return invalid('duplicate intent')
        seen.add(number)
        keys = intent['key']
        if not isinstance(keys, list) or len(keys) > 5: return invalid('too many key blocks per intent')
        total += len(keys)
        if total > 40: return invalid('too many key blocks')
        enriched = []
        for block in keys:
            if not isinstance(block, dict) or not {'hunk', 'kind', 'note'} <= set(block) or set(block) - {'hunk', 'kind', 'note', 'line_note', 'proves', 'changes', 'step'}:
                return invalid('invalid block fields')
            identifier = block['hunk']
            if not isinstance(identifier, str) or identifier not in canonical: return invalid('unknown hunk id')
            if identifier in used: return invalid('duplicate key hunk')
            source = canonical[identifier]
            if 'kind' in source: return invalid('nontext key hunk')
            if block['kind'] not in ('code', 'test'): return invalid('invalid block kind')
            note = block['note']
            if not isinstance(note, dict) or set(note) != {'en', 'zh-TW'}: return invalid('invalid note fields')
            if not all(fact(s) for s in note.values()): return invalid('note fails STE')
            rows = source['rows']
            row_index = None
            line_note = block.get('line_note')
            if 'line_note' in block:
                if not isinstance(line_note, dict) or set(line_note) != {'line', 'en', 'zh-TW'} or type(line_note['line']) is not int:
                    return invalid('invalid line note fields')
                if not all(fact(line_note[lang]) for lang in ('en', 'zh-TW')): return invalid('line note fails STE')
                side_field = 'old' if source['side'] == 'L' else 'new'
                row_index = next((i for i, r in enumerate(rows) if r[side_field] == line_note['line']), None)
                if row_index is None: return invalid('line note outside block')
            if scene:
                step = block.get('step')
                if not isinstance(step, dict) or set(step) != {'nodes', 'edges'}: return invalid('missing or invalid step')
                if not ids(step['nodes'], scene_nodes) or not ids(step['edges'], scene_edges): return invalid('unknown step id')
                if not step['nodes'] and not step['edges']: return invalid('empty step')
            elif 'step' in block: return invalid('step without scene')
            if 'changes' in block:
                if not ids(block['changes'], changes) or any(number not in changes[c] for c in block['changes']):
                    return invalid('invalid block changes')
            if 'proves' in block and block['kind'] != 'test': return invalid('proves on code block')
            item = deepcopy(block)
            item.update({k: source[k] for k in ('file', 'side', 'start', 'end', 'url')})
            start = max(0, min((row_index - 40) if row_index is not None else 0, len(rows) - 80))
            item['rows'] = rows[start:start + 80]
            if len(rows) > 80: item['truncated'] = dict(before=start, after=len(rows) - start - 80)
            used[identifier] = block
            enriched.append(item)
        result.append(dict(intent=number, key=enriched))
    code = {identifier for identifier, b in used.items() if b['kind'] == 'code'}
    for block in used.values():
        if 'proves' in block and not ids(block['proves'], code): return invalid('invalid proves target')
    other = {}
    for identifier, item in canonical.items():
        if identifier in used: continue
        row = other.setdefault(item['file'], dict(file=item['file'], hunks=0))
        row['hunks'] += 1
        if 'kind' in item:
            kinds = row.setdefault('kinds', [])
            if item['kind'] not in kinds: kinds.append(item['kind'])
    return dict(status='valid', intents=result, other=[other[f] for f in sorted(other)])


def canonical_diff(root, base, head):
    result = subprocess.run(['git', '-C', str(root), 'diff', '--no-ext-diff', '--no-color',
                             '--no-renames', base, head], capture_output=True, text=True, timeout=120)
    if result.returncode: raise ValueError('diff unavailable')
    return result.stdout


def attach(records, head, spec, root, repo='owner/repo', pr=0):
    absent = lambda reason: dict(status='absent', head=head, reason=reason)
    if not records: return absent('no local review')
    approvals = [r for r in records if r.get('verdict') == 'APPROVE']
    if not approvals: return absent('no local approval')
    eligible = [r for r in approvals if r.get('signature') and all(isinstance(r.get(k), str) and r[k].strip() for k in ('head', 'base', 'patch'))]
    if not eligible: return absent('verdict has no source binding')
    current = [r for r in eligible if r['head'] == head]
    if not current: return dict(status='stale', reviewed_head=eligible[-1]['head'])
    record = current[-1]
    if not fences(record['text']): return absent('no walk')
    try: diff = canonical_diff(root, record['base'], record['head'])
    except (ValueError, OSError, subprocess.SubprocessError): return dict(status='invalid', head=head, reason='diff unavailable')
    result = check(record['text'], spec, diff, repo, pr)
    result['head'] = head
    if result['status'] == 'valid': result.update(base=record['base'], patch=record['patch'])
    return result


def project_comment(text):
    """Remove walk text even when its JSON is invalid; keep every other line."""
    output = []
    for kind, body in segments(text):
        if kind == 'line':
            output.append(body)
            continue
        try: count = sum(len(i['key']) for i in json.loads(body)['intents'])
        except (ValueError, TypeError, KeyError): count = 0
        output.append('Code walk retained with the evidence (%s key blocks).' % count)
    return '\n'.join(output)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['check', 'attach', 'ids', 'comment'])
    for name in ('spec', 'file', 'diff', 'root', 'head', 'base', 'state', 'project', 'task', 'details'):
        parser.add_argument('--' + name)
    parser.add_argument('--repo', default='owner/repo')
    parser.add_argument('--pr', default=0)
    args = parser.parse_args()
    if args.command == 'comment':
        print(project_comment(sys.stdin.read() if args.file == '-' else Path(args.file).read_text()))
        return
    if args.command == 'ids':
        diff = Path(args.diff).read_text() if args.diff else canonical_diff(args.root, args.base, args.head)
        for identifier, item in hunks(diff, args.repo, args.pr).items():
            print(identifier + '  ' + item.get('header', item.get('kind', '')))
        return
    try:
        spec = json.loads(Path(args.spec).read_text())
        if args.command == 'check':
            text = Path(args.file).read_text()
            diff = Path(args.diff).read_text() if args.diff else canonical_diff(args.root, args.base, args.head)
            result = check(text, spec, diff, args.repo, args.pr)
        else:
            from fm_evidence import Store
            records = Store(args.state, args.project, args.task).verdicts()
            result = attach(records, args.head, spec, args.root, args.repo, args.pr)
    except Exception:
        result = dict(status='invalid', reason='walk check failed')
        if args.head: result['head'] = args.head
    if args.command == 'attach':
        details = json.loads(Path(args.details).read_text())
        details['walk'] = result
        print(json.dumps(details, ensure_ascii=False))
    else: print(json.dumps(result, ensure_ascii=False))

if __name__ == '__main__':
    main()
