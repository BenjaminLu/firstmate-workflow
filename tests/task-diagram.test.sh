#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
command -v node >/dev/null || { echo 'node absent'; exit 1; }
node - "$ROOT/board/public/diagram.js" <<'JS'
const assert = require('node:assert/strict');
const diagram = require(process.argv[2]);
(async () => {
  for (const id of ['task-T-001','task-alpha-T-001','task-beta-SK-001']) {
    const attrs = {}, frame = {dataset:{decision:id},getAttribute:k=>attrs[k],setAttribute:(k,v)=>attrs[k]=v,removeAttribute:k=>delete attrs[k],remove:()=>{throw Error('unexpected missing frame');}};
    const root = {querySelectorAll:()=>[frame]};
    for (const locale of diagram.LANGS) {
      assert.equal(diagram.src(id,locale), `diagrams/${id}.${locale}.html`);
      assert.ok(diagram.embed(id).includes(`data-decision="${id}"`));
      assert.equal(await diagram.mount(root,locale,async () => ({ok:true})),1);
      assert.equal(attrs.src,`diagrams/${id}.${locale}.html`);
    }
  }
  assert.equal(diagram.src('task-../T-001','en'),'');
})().catch(error => {console.error(error);process.exitCode=1;});
JS
assert_eq 0 "$?" 'task diagrams share src, embed, mount and locale switching'
finish
