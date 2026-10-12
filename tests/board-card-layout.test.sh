#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import json
import re
import sys
from pathlib import Path
root = Path(sys.argv[1])
html = (root / 'board/public/index.html').read_text()
def body(name):
    match = re.search(r'^(?:async )?function ' + name + r'\([^\n]*\) \{\n(.*?)(?=^(?:async )?function |\Z)', html, re.M | re.S)
    return match.group(1) if match else ''
answer = body('answer')
intent = body('intentBody')
card = body('cardBody')
bar = body('decisionBar')
drawer = body('whyDrawer')
keys = ['intentHeading', 'howHeading', 'alignmentHeading', 'scopeHeading', 'notesHeading']
positions = [intent.find("t('" + key + "')") for key in keys]
# T-289: the open card reads as the approved prototype: header, intent rows,
# How it works, then Walk the diff and Intent check, then the decision bar.
full = re.search(r'const full = \(d, index, total\) => \{(.*?)\n  \};', html, re.S)
full = full.group(1) if full else ''
order = [full.find(part) for part in ['const header = `<header class="caphead', 'cardBody(d, content, locked)', 'header + body + designCompare(d) + decisionBar(d, content, locked)']]
card_order = [card.find(part) for part in ['kpSection(d, content)', '<section class="hero', '<section class="align"', "t('walkDiff')", "t('walkIntentCheck')", 'intentCheck(d, content, locked)']]
checks = [
    ('answered set declared', bool(re.search(r'\banswered\s*=\s*new Set\(\)', html))),
    ('full card lock includes answered', bool(re.search(r'const locked = [^;]*answered.has\(d.id\)', full))),
    ('answer first guard rejects answered', 'answered.has(id)' in answer.split('\n')[0] if answer else False),
    ('successful answer locks before clearing sent', bool(re.search(r'if \(!r.error\) answered.add\(id\);\s*sent.delete\(id\)', answer))),
    ('validate retains answer lock', 'answered.has(id)' in body('validate')),
    ('render retires absent answered ids', bool(re.search(r'for \(const id of answered\).*?pendingIds.has\(id\).*?answered.delete\(id\)', html))),
    ('the card reads header, body, then the decision bar', all(p >= 0 for p in order) and order == sorted(order)),
    ('the body reads intent rows, How it works, then the walk and the check', all(p >= 0 for p in card_order) and card_order == sorted(card_order)),
    ('the header keeps the prose behind "Why you see this"', 't("whyYouSeeThis")' in full and 'whyDrawer(d, content)' in full and "openWhys.has(d.id) ? '' : ' hidden'" in full),
    ('the drawer holds explanation, why, notes and outcome', all(k in drawer for k in ["'explanationHeading'", "'whyHeading'", "'notesHeading'", "'outcomeHeading'", 'plainBlock(content)'])),
    ('the bar is the fixed flag bar with its sheet', all(k in bar for k in ['class="dbar decision-bar"', 'class="dsheet decision-sheet"', 'class="mflag opt f-', 'class="flagbtn f-', 'data-decision-details'])),
    ('detail keeps intent/how/alignment/scope/notes', 'return `<div class="intent-alignment">${hasItems(\'change_points\') ? changeWalk(d,content,true) : intent}${how}${alignment}${scope}${notes}</div>`' in intent),
    ('detail headings are complete and ordered', all(p >= 0 for p in positions) and positions == sorted(positions)),
    ('intentBody replaces old alignment title', bool(intent) and "t('intentAlignment')" not in intent),
    ('optional Why line requires items', "hasItems('why') ?" in intent),
    ('optional alignment requires items', "const alignment = hasItems('done') ?" in intent),
    ('optional scope requires items', 'const scope = scopeItems.length ?' in intent),
    ('optional scope columns require items', "['scope_in','scope_out'].filter(hasItems).map" in intent),
    ('optional notes require items', "const notes = hasItems('notes') ?" in intent),
    ('optional questions require items', "const questions = (content?.questions || []).length ?" in bar),
    ('optional outcome requires nonempty text', "content?.outcome?.trim() ?" in drawer),
    ('the inline stylesheet balances its braces', (lambda css: css.count('{') == css.count('}'))(re.sub(r'/\*.*?\*/', '', ''.join(re.findall(r'<style[^>]*>(.*?)</style>', html, re.S)), flags=re.S))),
]
# the same check for the board's own stylesheets: a deleted rule leaves no half behind
for sheet in ['board.css', 'ship.css']:
    css = re.sub(r'/\*.*?\*/', '', (root / 'board/public' / sheet).read_text(), flags=re.S)
    checks.append((f'{sheet} balances its braces', css.count('{') == css.count('}')))
for locale in ['en', 'zh-TW']:
    dictionary = json.loads((root / f'i18n/ui.{locale}.json').read_text())
    for key in ['howHeading', 'scopeHeading', 'alignmentHeading', 'optionsHeading', 'notesHeading', 'showMore']:
        checks.append((f'{locale} defines {key}', bool(dictionary.get(key))))
rows = (root / 'i18n/tw2cn.tsv').read_text().splitlines()
for source, target in [('對','对'), ('麼','么'), ('備','备'), ('註','注')]:
    checks.append((f'conversion {source}', rows.count(source + '\t' + target) == 1))
for name, passed in checks:
    print(f'    {name}: {"ok" if passed else "FAIL"}')
sys.exit(0 if all(passed for _, passed in checks) else 1)
PY
