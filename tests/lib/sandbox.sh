# shellcheck shell=bash
# Caller/consumer globals are checked when linting the feature suites.
# shellcheck disable=SC2034
# The crew's permission policy (T-105, T-117): one policy per role, resolved
# from config.yaml by fm_policy, and the OS half of enforcing it,
# bin/fm-sandbox.sh - the sandbox itself, and the vendor's login it reads
# outside the round and hands in. What each adapter's own flags make of the
# same policy is asserted in tests/adapter-contract.test.sh.
#
# No real sandbox runs here: a runner cannot be relied on to have one, and
# a macOS profile cannot be applied inside another. FM_SANDBOX_OS and
# FM_SANDBOX_TOOL name the platform and a stand-in that records what it was
# handed and runs the command, so what is asserted is exactly what the real
# tool would have been given; FM_KEYCHAIN_TOOL names a stand-in for the
# operator's keychain. bin/fm-canary.sh is what runs the real thing.
set -uo pipefail
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
# a login already in this shell would be handed in instead of the stand-in's
unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY CURSOR_API_KEY CODEX_API_KEY GEMINI_API_KEY GOOGLE_API_KEY
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=tests/lib/path.sh
. "$ROOT/tests/lib/path.sh"
suite_original_path="$PATH"
suite_tools="$(safe_tmpdir)"
fixture_path "$suite_tools" 'claude codex gemini cursor-agent agent gh herdr tmux cmux security secret-tool osascript xdg-open open' || exit 1
PATH="$suite_tools"; export PATH
# shellcheck source=bin/fm-config.sh
. "$ROOT/bin/fm-config.sh"
SB="$ROOT/bin/fm-sandbox.sh"

t="$(safe_tmpdir)"
home="$(cd "$HOME" && pwd -P)"
# the operator's name as fm_policy reads it
me="$(python3 -c 'import getpass; print(getpass.getuser())')"
pol() {   # pol <role> <config text> -> the policy file; its exit code too
  printf '%s' "$2" > "$t/config.yaml"
  fm_policy "$1" "" "$t/config.yaml" > "$t/$1.json"
}

