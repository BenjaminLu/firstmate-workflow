#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib/worker.sh"
d="$(fixture)"; repo="$d/repo"; GH="$(ghstub "$d")"
printf 'vendor: mock\nproject:\n  check: true\n' > "$repo/config.yaml"
printf 'state/\n' > "$repo/.gitignore"
git -C "$repo" add config.yaml .gitignore; git -C "$repo" commit -qm contract
git -C "$repo" push -q origin main
printf '%s\n' '{"type":"greenlit","actor":"captain","ts":"2026-10-03T00:00:00Z"}' > "$repo/state/events.jsonl"
cat > "$repo/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
cp "$2" "$FM_SEEN/prompt.md"
printf '%s' "${FM_PINNED_DIR:-}" > "$FM_SEEN/pinned-path"
mkdir -p "$3/src"
printf 'implemented\n' > "$3/src/feature"
M
chmod +x "$repo/bin/adapters/mock.sh"
(cd "$repo" && FM_ROOT="$repo" FM_GH="$GH" FM_SEEN="$d" bin/fm-worker.sh --task T-Z --project firstmate-workflow) > "$d/out" 2>&1
assert_eq 0 "$?" 'authorized worker pins before running its adapter'
assert_ok "test -f '$repo/state/pins/T-Z/1.json'" 'worker stores its first pin outside the worktree'
assert_contains "$(cat "$d/prompt.md")" '# Approved spec pin' 'worker prompt uses the shared pin resolver'
assert_contains "$(cat "$d/prompt.md")" '"approval_binding": "dispatch-time"' 'worker exposes the dispatch-time approval limit'
assert_eq committed "$(jq -r '.snapshots.spec.source' "$repo/state/pins/T-Z/1.json")" 'worker records committed self spec provenance'
assert_eq 1 "$(jq -s '[.[]|select(.type=="spec_pinned")]|length' "$repo/state/events.jsonl")" 'worker emits one initial pin event'
assert_contains "$(cat "$d/prompt.md")" '# Complete round inputs in pinned/' 'stock worker prompt indexes complete approved design'
assert_lacks "$(cat "$d/prompt.md")" '# Launcher project context' 'self worker retains its existing prompt sections'
python3 - "$d/pinned-path" "$repo/state/pins/T-Z/1.json" <<'PY_PINNED'
import json
from pathlib import Path
import sys
folder = Path(Path(sys.argv[1]).read_text())
pin = json.loads(Path(sys.argv[2]).read_text())
assert folder.name == 'pinned' and folder.is_absolute()
assert folder.stat().st_mode & 0o222 == 0
for key, name in [('spec', 'spec.json'), ('design', 'design.md'), ('contract', 'contract.yaml')]:
    path = folder / name
    assert path.read_bytes() == pin['snapshots'][key]['text'].encode()
    assert path.stat().st_mode & 0o222 == 0
PY_PINNED
assert_eq 0 "$?" 'worker adapter receives exact read-only pin files'
# A valid mutable branch spec must never rescue an existing corrupt pin.
for corruption in hash unreadable; do
  rm -f "$d/prompt.md"
  if [ "$corruption" = hash ]; then
    jq '.snapshots.design.text += "tampered"' "$repo/state/pins/T-Z/1.json" > "$d/corrupt.json"
    cp "$d/corrupt.json" "$repo/state/pins/T-Z/1.json"
  else
    printf '{broken' > "$repo/state/pins/T-Z/1.json"
  fi
  (cd "$repo" && FM_ROOT="$repo" FM_GH="$GH" FM_SEEN="$d" bin/fm-worker.sh --task T-Z) > "$d/out" 2>&1
  assert_eq 65 "$?" 'worker refuses corrupt existing pin without branch fallback'
  assert_ok "test ! -e '$d/prompt.md'" 'worker never invokes adapter with corrupt pin'
  if [ "$corruption" = hash ]; then
    assert_contains "$(cat "$d/out")" 'hash mismatch' 'worker names corrupt snapshot reason'
  fi
done
rm -rf "$d"
# Authorized legacy sources cannot pin, but still run in both self modes.
for missing in contract design; do
  for mode in default explicit; do
    d="$(fixture)"; repo="$d/repo"; GH="$(ghstub "$d")"
    if [ "$missing" = design ]; then
      printf 'vendor: mock\nproject:\n  check: true\n' > "$repo/config.yaml"
      git -C "$repo" rm -q design/design.md
      git -C "$repo" add config.yaml
      git -C "$repo" commit -qm 'legacy missing design'
      git -C "$repo" push -q origin main
    fi
    mkdir -p "$repo/state/pins/T-Z"
    touch "$repo/state/pins/T-Z/.lock"
    printf '%s\n' '{"type":"greenlit","actor":"captain","ts":"2026-10-03T00:00:00Z"}' > "$repo/state/events.jsonl"
    cat > "$repo/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
cp "$2" "$FM_SEEN/prompt.md"
printf '%s' "${FM_PINNED_DIR:-}" > "$FM_SEEN/pinned-path"
mkdir -p "$3/src"
printf 'implemented\n' > "$3/src/feature"
printf 'Adapter report\n' > "$3/.fm-say.md"
M
    chmod +x "$repo/bin/adapters/mock.sh"
    project_args=(); [ "$mode" != explicit ] || project_args=(--project firstmate-workflow)
    (cd "$repo" && FM_ROOT="$repo" FM_GH="$GH" FM_SEEN="$d" bin/fm-worker.sh --task T-Z ${project_args[@]+"${project_args[@]}"}) > "$d/out" 2>&1
    assert_eq 0 "$?" "authorized worker survives missing $missing ($mode self)"
    assert_ok "test -s '$d/prompt.md'" 'legacy worker still runs its adapter'
    assert_ok "test ! -e '$repo/state/pins/T-Z/1.json'" 'failed first pin writes no record'
    assert_contains "$(cat "$d/out")" 'no pin; gate 4 will refuse' 'failed first pin warns on stderr'
    assert_ok "grep -Rq 'no pin; gate 4 will refuse' '$repo/state/evidence'" 'failed first pin warning retained in round report'
    rm -rf "$d"
  done
done

finish
