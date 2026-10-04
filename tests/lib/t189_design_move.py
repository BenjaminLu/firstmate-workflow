#!/usr/bin/env python3
"""One-time T-189 tooling, not a standing suite.

  t189_design_move.py relocate <base-design.md>
      print the base design with the nine tail sections moved into their
      numbered homes: positions and heading levels change, nothing else
  t189_design_move.py evidence <base-design.md> <moved-design.md> <tasks-dir>
      show that every non-heading line is unchanged as a multiset, that each
      moved body is contiguous and in order under its heading, where each
      section now lives, and that anchors() resolves the same heading texts
      for every spec and both roles
"""
from collections import Counter
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'bin/lib'))
from fm_prompt_context import anchors  # noqa: E402

# tail heading text -> (home heading prefix, one-line reason)
MOVES = [
    ('T-157: diagnosing collected facts', '13.3 ',
     'fm-doctor/fm-setup fact collection belongs with setup, doctor and the vendor probe'),
    ('T-139 private onboarding contract', '15.2 ',
     'onboarding writes the CONVENTIONS.md contract §15.2 defines'),
    ('T-052 portable prompt context', '15.7 ',
     'prompt context for portable roles and stock execution'),
    ('T-143: operating a stack', '15.8 ',
     '§15.8 names T-143 stacking as an advanced integration'),
    ('Autopilot owns PR advancement (T-175)', '15.8 ',
     '§15.8 already specifies the per-project autopilot supervisor'),
    ('New task discovery and question freshness (T-180)', '15.8 ',
     'autopilot discovery of task PRs and their questions'),
    ('Recorded chat merge windows (T-182)', '15.8 ',
     'the autopilot supervisor caches the window and queues its reminders'),
    ('T-125: Live voyage seam', '8. ',
     'the Live voyage is embedded in the captain\'s board'),
    ('Spec preflight and migration (T-185)', '6. ',
     'preflight is a lifecycle step before every dispatch and repin'),
]


def parse(lines):
    """(index, level, text) for headings outside fenced code, as anchors() reads them."""
    found, fence = [], None
    for index, line in enumerate(lines):
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
            found.append((index, len(match[1]), match[2]))
    return found


def strip_blank_tail(body):
    while body and not body[-1].strip():
        body = body[:-1]
    return body


def relocate(text):
    lines = text.split('\n')
    heads = parse(lines)
    texts = [h[2] for h in heads]
    first = texts.index(MOVES[0][0])
    if [h[2] for h in heads[first:]] != [m[0] for m in MOVES]:
        raise SystemExit('relocate: the tail is not the nine expected sections')
    tail_start = heads[first][0]
    # the blank line that separates the last numbered section from the tail
    # travels with the final block, which ended the file without one
    cut = tail_start
    while cut > 0 and not lines[cut - 1].strip():
        cut -= 1
    spare = lines[cut:tail_start]
    blocks = {}
    for n, (start, _, heading) in enumerate(heads[first:], first):
        end = heads[n + 1][0] if n + 1 < len(heads) else len(lines)
        blocks[heading] = lines[start + 1:end]
    last = MOVES[-1][0]
    if lines[-1] == '':          # the final newline stays at the end of the file
        blocks[last] = blocks[last][:-1]
    blocks[last] = blocks[last] + spare
    inserts = {}
    for heading, prefix, _ in MOVES:
        n, (start, level, _) = next((n, h) for n, h in enumerate(heads) if h[2].startswith(prefix))
        end = next((h[0] for h in heads[n + 1:] if h[1] <= level), len(lines))
        k = end - 1
        while not lines[k].strip() or lines[k].strip() == '---':
            k -= 1
        if lines[k + 1].strip():
            raise SystemExit('relocate: no blank line after the home ' + prefix)
        children = [h for h in heads[n + 1:] if h[0] < end]
        if any(re.match(r'^\d', h[2]) for h in children):
            raise SystemExit('relocate: home has numbered children: ' + prefix)
        inserts.setdefault(k + 2, []).append(['#' * (level + 1) + ' ' + heading] + blocks[heading])
    out = []
    for index, line in enumerate(lines[:cut]):
        for block in inserts.get(index, []):
            out.extend(block)
        out.append(line)
    if lines[-1] == '':
        out.append('')
    return '\n'.join(out)


def resolved(text, tasks):
    result = {}
    for path in sorted(Path(tasks).glob('*.json')):
        spec = json.loads(path.read_text(encoding='utf-8'))
        for role in ('worker', 'reviewer'):
            result[(path.name, role)] = {h for h, _, _ in anchors(text, spec, role)}
    return result


def evidence(base, moved, tasks):
    old, new = base.split('\n'), moved.split('\n')
    old_heads, new_heads = parse(old), parse(new)
    ok = True

    def body_lines(lines, heads):
        marks = {h[0] for h in heads}
        return Counter(line for i, line in enumerate(lines) if i not in marks)

    removed = body_lines(old, old_heads) - body_lines(new, new_heads)
    added = body_lines(new, new_heads) - body_lines(old, old_heads)
    print('1. Non-heading lines as a multiset')
    print(f'   base {len(old) - len(old_heads)}, moved {len(new) - len(new_heads)}; '
          f'only in base {sum(removed.values())}, only in moved {sum(added.values())}')
    for line, count in sorted(removed.items()):
        print(f'   - x{count} {line}')
    for line, count in sorted(added.items()):
        print(f'   + x{count} {line}')
    ok &= not removed and not added

    print('2. Heading texts as a multiset (levels ignored)')
    same = Counter(h[2] for h in old_heads) == Counter(h[2] for h in new_heads)
    print('   identical' if same else '   DIFFERENT')
    ok &= same

    print('3. Each moved section: level, destination, body contiguous and in order')
    for heading, prefix, reason in MOVES:
        n, (start, level, _) = next((n, h) for n, h in enumerate(old_heads) if h[2] == heading)
        end = old_heads[n + 1][0] if n + 1 < len(old_heads) else len(old)
        body = strip_blank_tail(old[start + 1:end])
        m, (nstart, nlevel, _) = next((m, h) for m, h in enumerate(new_heads) if h[2] == heading)
        contiguous = new[nstart + 1:nstart + 1 + len(body)] == body
        home = next(h for h in reversed(new_heads[:m]) if h[1] < nlevel)
        print(f'   {"#" * level} -> {"#" * nlevel} {heading}')
        print(f'      now line {nstart + 1}, inside "{home[2]}" (line {home[0] + 1}); '
              f'{len(body)} body lines contiguous and in order: {"yes" if contiguous else "NO"}')
        print(f'      reason: {reason}')
        ok &= contiguous and home[2].startswith(prefix) and nlevel == home[1] + 1

    print('4. anchors() heading texts per spec and role')
    before, after = resolved(base, tasks), resolved(moved, tasks)
    differ = [key for key in before if before[key] != after.get(key)]
    print(f'   {len(before)} spec/role pairs, {len(differ)} differ')
    for name, role in differ:
        print(f'   {name} {role}: -{sorted(before[(name, role)] - after[(name, role)])} '
              f'+{sorted(after[(name, role)] - before[(name, role)])}')
    ok &= not differ
    print('RESULT: ' + ('move only' if ok else 'NOT a pure move'))
    return 0 if ok else 1


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == 'relocate':
        sys.stdout.write(relocate(Path(sys.argv[2]).read_text(encoding='utf-8')))
    elif len(sys.argv) == 5 and sys.argv[1] == 'evidence':
        sys.exit(evidence(Path(sys.argv[2]).read_text(encoding='utf-8'),
                          Path(sys.argv[3]).read_text(encoding='utf-8'), sys.argv[4]))
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(64)
