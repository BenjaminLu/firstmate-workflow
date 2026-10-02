#!/usr/bin/env bash
# Feature-owned tests; suites are run by CI and gate 5, never by a worker.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
python3 "$ROOT/tests/lib/local_round_records.py" "$ROOT"
assert_eq 0 "$?" 'local round records preserve authority and closed lists'
# Exercise the same projection boundary used by both launchers, with an external
# registry entry that deliberately omits projection.
d="$(safe_tmpdir)"
cat > "$d/config.yaml" <<'CONFIG'
projects:
  engine:
    repo: .
    github: owner/engine
    base: main
    required_check: ci
  customer:
    github: owner/customer
    base: main
    required_check: ci
CONFIG
cat > "$d/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
GH
chmod +x "$d/gh"
export CALLS="$d/calls"
# shellcheck source=bin/fm-config.sh
. "$ROOT/bin/fm-config.sh"
FM_CONFIG="$d/config.yaml"; FM_PROJECT=customer; FM_GH="$d/gh"
fm_comment_projection 9 --body 'private external round'
assert_eq 0 "$?" 'an external project needs no comment publication'
assert_fail "test -e '$CALLS'" 'external project without projection makes no pr comment call'
FM_PROJECT=engine
fm_comment_projection 9 --body 'self round'
assert_contains "$(cat "$CALLS")" 'pr comment 9 --body self round' 'self defaults to comments'
unset FM_PROJECT
FM_CONFIG="$d/legacy.yaml"
printf 'vendor: mock\ndefault_project: legacy-owner\n' > "$FM_CONFIG"
assert_eq legacy-owner "$(fm_evidence_project)" 'legacy evidence uses configured default project'
assert_eq comments "$(fm_projection)" 'unnamed legacy launchers preserve comments projection'
rm -rf "$d"
finish
