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
keys = ['intentHeading', 'howHeading', 'alignmentHeading', 'scopeHeading', 'notesHeading']
positions = [intent.find("t('" + key + "')") for key in keys]
checks = [
    ('answered set declared', bool(re.search(r'\banswered\s*=\s*new Set\(\)', html))),
    ('full card lock includes answered', bool(re.search(r'const full = d =>.*?const locked = [^;]*answered.has\(d.id\)', html, re.S))),
    ('answer first guard rejects answered', 'answered.has(id)' in answer.split('\n')[0] if answer else False),
    ('successful answer locks before clearing sent', bool(re.search(r'if \(!r.error\) answered.add\(id\);\s*sent.delete\(id\)', answer))),
    ('validate retains answer lock', 'answered.has(id)' in body('validate')),
    ('render retires absent answered ids', bool(re.search(r'for \(const id of answered\).*?pendingIds.has\(id\).*?answered.delete\(id\)', html))),
    ('detailOnly keeps intent/how/alignment/scope/notes', 'if (detailOnly) return `<div class="intent-alignment">${intent}${how}${alignment}${scope}${notes}</div>`' in intent),
    ('captain body keeps intent/how/scope/notes', '<div class="intent-alignment">${pairedIntent}${how}${scope}${notes}</div>' in intent),
    ('detail headings are complete and ordered', all(p >= 0 for p in positions) and positions == sorted(positions)),
    ('intentBody replaces old alignment title', bool(intent) and "t('intentAlignment')" not in intent),
    ('optional Why line requires items', "hasItems('why') ?" in intent),
    ('optional alignment requires items', "const alignment = hasItems('done') ?" in intent),
    ('optional scope requires items', 'const scope = scopeItems.length ?' in intent),
    ('optional scope columns require items', "['scope_in','scope_out'].filter(hasItems).map" in intent),
    ('optional notes require items', "const notes = hasItems('notes') ?" in intent),
    ('optional questions require items', "const questions = hasItems('questions') ?" in body('decisionSheet')),
    ('optional outcome requires nonempty text', "content?.intent && content.outcome?.trim() ?" in html),
]
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
