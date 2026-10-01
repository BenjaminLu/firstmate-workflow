# shellcheck shell=bash
# Caller/consumer globals are checked when linting the feature suites.
# shellcheck disable=SC2034
# bin/ci.sh is the single entry point CI and the local gate both call.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=tests/lib/path.sh
. "$ROOT/tests/lib/path.sh"
suite_original_path="$PATH"
suite_tools="$(safe_tmpdir)"
fixture_path "$suite_tools" 'claude codex gemini cursor-agent agent gh herdr tmux cmux security secret-tool osascript xdg-open open' || exit 1
PATH="$suite_tools"; export PATH
for required in bun bunx shellcheck; do
  command -v "$required" >/dev/null 2>&1 || {
    echo "ci.test: install the declared toolchain before running this suite (missing $required)" >&2
    exit 1
  }
done

fixture() {                      # a throwaway repo root for ci.sh to operate on
  # safe_tmpdir, not a bare mktemp -d: this result feeds FM_ROOT, and a
  # mktemp this sandbox refuses used to hand back an empty string here,
  # which FM_ROOT="${FM_ROOT:-...}" then read as unset and ran the whole
  # gate against the real tree instead (T-123, round 5).
  d="$(safe_tmpdir)"; mkdir -p "$d/bin" "$d/tests"; printf '%s' "$d"
}


