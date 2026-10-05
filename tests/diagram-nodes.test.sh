#!/usr/bin/env bash
# T-211: node drawings, text-only compatibility, and authored precedence.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/lib/project-storage.sh"
x="$(mktemp -d)"
trap 'rm -rf "$x"' EXIT
mkdir -p "$x/bin" "$x/i18n" "$x/state/pending" "$x/design/diagrams" "$x/board/public"
cp "$ROOT/bin/fm-emit.sh" "$x/bin/"
project_storage_fixture "$x/bin/"
cp "$ROOT/i18n/"* "$x/i18n/"
cat > "$x/state/pending/D-211.json" <<'JSON'
{"id":"D-211","details":{"en":{"before":"Before","after":"After","before_nodes":[{"state":"same","label":"Input"},{"state":"gone","label":"<script>old</script>"}],"after_nodes":[{"state":"same","label":"Input"},{"state":"new","label":"Safe output"}],"change_table":[{"text":"<script>change</script>","A":"✓","B":"—","C":"?"}]},"zh-TW":{"before":"之前","after":"之後","before_nodes":[{"state":"same","label":"任務"},{"state":"gone","label":"舊程式碼"}],"after_nodes":[{"state":"same","label":"任務"},{"state":"new","label":"新程式碼"}],"change_table":[{"text":"修改","A":"✓","B":"—","C":"?"}]}}}
JSON
bash "$ROOT/bin/fm-diagram.sh" --decision D-211 --repo "$x" >/dev/null
for lang in en zh-TW zh-CN; do
  f="$x/board/public/diagrams/D-211.$lang.html"
  assert_eq 2 "$(grep -o '<svg ' "$f" | wc -l | tr -d ' ')" "$lang draws two node flows"
  assert_eq 4 "$(grep -o '<rect ' "$f" | wc -l | tr -d ' ')" "$lang draws every node"
  assert_ok "grep -q 'stroke-dasharray=\"4 2\"' '$f'" "$lang marks gone nodes with dashed strokes"
  assert_ok "grep -q '✕' '$f' && grep -q '>+</text>' '$f'" "$lang draws gone and new marks"
  assert_ok "grep -q 'class=\"node-legend\"' '$f' && grep -q '<table' '$f'" "$lang includes legend and change table"
  for color in ok fg3 warn; do assert_ok "grep -q 'color:var(--$color)' '$f'" "$lang table uses $color"; done
  assert_ok "grep -q 'role=\"img\"' '$f' && ! grep -q 'aria-label=' '$f'" "$lang SVG uses title text for its name"
done
python3 - "$x/board/public/diagrams" <<'PYTEST'
import sys
from pathlib import Path
from html.parser import HTMLParser
class Flows(HTMLParser):
    def __init__(self):
        super().__init__(); self.flows=[]; self.current=None
    def handle_starttag(self, tag, attrs):
        attrs=dict(attrs)
        if tag == 'svg':
            self.current={'attrs':attrs,'rects':[]}; self.flows.append(self.current)
        elif tag == 'rect' and self.current is not None:
            self.current['rects'].append(attrs)
    def handle_endtag(self, tag):
        if tag == 'svg': self.current=None
for lang in ('en','zh-TW','zh-CN'):
    page=Flows(); page.feed((Path(sys.argv[1])/f'D-211.{lang}.html').read_text())
    assert len(page.flows)==2, f'{lang}: two accessible node flows'
    for flow in page.flows:
        assert flow['attrs']['role']=='img'
        assert flow['attrs']['viewbox']=='0 0 300 72'
        assert len(flow['rects'])==2, f'{lang}: each flow has one rect per node'
        for rect in flow['rects']:
            assert (rect['height'],rect['rx'])==('24','4')
        assert int(flow['rects'][1]['y'])-int(flow['rects'][0]['y'])==36
        assert flow['rects'][0]['stroke']=='var(--line)'
    gone=page.flows[0]['rects'][1]; new=page.flows[1]['rects'][1]
    assert gone['stroke']=='var(--bad)' and gone['stroke-dasharray']=='4 2'
    assert gone['fill']=='rgba(242,100,90,.08)'
    assert new['stroke']=='var(--brass)' and new['fill']=='rgba(217,164,65,.08)'
PYTEST
assert_eq 0 "$?" 'each locale has the specified node geometry and state styling'
assert_ok "grep -q '&lt;script&gt;old&lt;/script&gt;' '$x/board/public/diagrams/D-211.en.html'" 'node labels are escaped'
assert_ok "grep -q '&lt;script&gt;change&lt;/script&gt;' '$x/board/public/diagrams/D-211.en.html'" 'table labels are escaped'
assert_ok "grep -q '<title>任务 → 旧代码</title>' '$x/board/public/diagrams/D-211.zh-CN.html'" 'simplified SVG accessible name is converted as text'
printf '<p>Authored wins</p>\n' > "$x/design/diagrams/D-211.html"
bash "$ROOT/bin/fm-diagram.sh" --decision D-211 --repo "$x" >/dev/null
assert_ok "grep -q 'Authored wins' '$x/board/public/diagrams/D-211.en.html' && ! grep -q '<svg ' '$x/board/public/diagrams/D-211.en.html'" 'authored drawing wins over nodes'
# The existing D-013 fixture from tests/diagram.test.sh, compared with the
# pre-T-211 renderer's literal output at ddac6e0522c1645f0c568c2e6ec64621e5f56c7f.
cat > "$x/state/pending/D-013.json" <<'JSON'
{"id":"D-013","task":"T-099","kind":"choice","title":"pick one","details":{"en":{"before":"pick one","after":"One read"},"zh-TW":{"before":"pick one","after":"已合併閘門程式碼"}}}
JSON
bash "$ROOT/bin/fm-diagram.sh" --decision D-013 --repo "$x" >/dev/null
for lang in en zh-TW zh-CN; do
  assert_ok "cmp '$ROOT/tests/fixtures/diagram-text-only.$lang.html' '$x/board/public/diagrams/D-013.$lang.html'" "$lang legacy text-only output is byte-identical to base"
done
finish
