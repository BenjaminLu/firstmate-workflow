# shellcheck shell=bash
# No real Herdr control or model calls: lifecycle observations are isolated.
set -euo pipefail
exec < /dev/null
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=tests/lib/path.sh
. "$ROOT/tests/lib/path.sh"
suite_tools="$(safe_tmpdir)"
trap 'rm -rf "$suite_tools"' EXIT
fixture_path "$suite_tools" 'claude codex gemini cursor-agent agent gh herdr tmux cmux security secret-tool osascript xdg-open open' || exit 1
PATH="$suite_tools"; export PATH
