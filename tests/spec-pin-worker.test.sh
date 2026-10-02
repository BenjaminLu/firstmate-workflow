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
rm -rf "$d"
finish
