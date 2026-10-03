#!/usr/bin/env bash
set -uo pipefail
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do unset "$_fm_k" || true; done
export HERDR_ENV=0 FM_TRANSPORT=direct
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=tests/lib/stacking.sh
. "$ROOT/tests/lib/stacking.sh"
d="$(safe_tmpdir)"
trap 'rm -rf "$d"' EXIT
mkdir -p "$d/bin" "$d/design/tasks" "$d/state"
cp "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-herdr.py" "$ROOT/bin/fm-dispatch.sh" "$ROOT/bin/fm-ready.sh" "$ROOT/bin/fm-emit.sh" "$d/bin/"
cp -R "$ROOT/bin/lib" "$d/bin/"
printf 'concurrency: 3\n' > "$d/config.yaml"
printf '{"id":"T-902","depends_on":["T-901"]}\n' > "$d/design/tasks/T-902.json"
FM_ROOT="$d" bash "$d/bin/fm-emit.sh" --actor firstmate --type greenlit >/dev/null
printf '{"id":"T-901","depends_on":[]}\n' > "$d/design/tasks/T-901.json"
stacking_gh "$d" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa t-901-parent
for policy in hold allowed; do
  stacking_policy "$d/CONVENTIONS.md" "$policy"
  : > "$d/ghcalls"
  out="$(GH_REPO=fixture/project FM_ROOT="$d" FM_GH="$d/gh" bash "$d/bin/fm-dispatch.sh" --repo "$d" --task T-902 --dry-run 2>"$d/stderr")"; code=$?
  if [ "$policy" = hold ]; then
    assert_eq '' "$(sed '/^fm-dispatch:/d' <<<"$out")" 'held stacking never dispatches child'
    assert_eq '' "$(cat "$d/ghcalls")" 'held stacking makes no GitHub calls'
  else
    assert_eq 0 "$code" 'allowed stack dispatch succeeds'
    assert_eq T-902 "$(sed '/^fm-dispatch:/d' <<<"$out")" 'allowed stack dispatch selects child'
    assert_contains "$(cat "$d/ghcalls")" 'pr list --repo fixture/project' 'allowed stack verifies parent repository'
  fi
done
finish
