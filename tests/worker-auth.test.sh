#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
# shellcheck source=tests/lib/auth-probe.sh
. "$ROOT/tests/lib/auth-probe.sh"
# --- a crew round never runs on a login it did not check (T-121) -----------
# claude's own status check, asked about the crew token a round would get,
# says it is not signed in; the worker never starts claude's CLI at all - it
# moves straight to the fallback, the same as an outage discovered by
# running it - and reports why on the board. The operator's home and
# keychain are the suite's: the probe resolves the round's login from them.
d6="$(fixture)"; r6="$d6/repo"; GH6="$(ghstub "$d6")"
printf 'vendor: claude\nfallback:\n  - mock\n' > "$r6/config.yaml"
auth_home="$d6/home"; mkdir -p "$auth_home/.config/firstmate"
printf 'crew-token\n' > "$auth_home/.config/firstmate/claude-token"; chmod 600 "$auth_home/.config/firstmate/claude-token"
auth_env=(HOME="$auth_home" FM_KEYCHAIN_TOOL="$d6/no-security" FM_SECRET_TOOL="$d6/no-secret-tool")
mkdir -p "$d6/fakebin"
cat > "$d6/fakebin/claude" <<C
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d6/claude-calls"
case "\$1 \$2" in
  "--version "*) exec "$ROOT/tests/fixtures/auth-status/replay.sh" "$ROOT/tests/fixtures/auth-status/claude-signed-out.txt" --version ;;
  "auth status") exec "$ROOT/tests/fixtures/auth-status/replay.sh" "$ROOT/tests/fixtures/auth-status/claude-signed-out.txt" ;;
esac
exit 1
C
chmod +x "$d6/fakebin/claude"
( cd "$r6" && env "${auth_env[@]}" PATH="$d6/fakebin:$PATH" FM_ROOT="$r6" FM_GH="$GH6" \
    bin/fm-worker.sh --task T-Z >"$d6/out" 2>"$d6/err" )
assert_eq "0" "$?" "a login the probe finds unauthenticated still falls through to the next vendor"
assert_contains "$(cat "$d6/claude-calls" 2>/dev/null)" "auth status" "claude's status is asked about the round's crew token"
assert_eq "" "$(grep -vxF -e '--version' -e 'auth status' "$d6/claude-calls" 2>/dev/null)" \
  "claude's own CLI is invoked only for its version and its status check, never started for the round itself"
assert_contains "$(jq -r 'select(.type=="vendor_unavailable")|.summary.en' "$r6/state/events.jsonl" | tr '\n' ' ')" \
  "claude" "vendor_unavailable names claude"
assert_contains "$(cat "$d6/err")" "claude:" "and says so on stderr too, before the fallback runs"

# Historical refusals are records, never cached auth decisions (T-188).
d10="$(fixture)"; r10="$d10/repo"; GH10="$(ghstub "$d10")"
printf 'vendor: cursor-agent\n' > "$r10/config.yaml"
mkdir -p "$d10/home/.config/firstmate" "$d10/fakebin"
printf 'fixture-cursor-key\n' > "$d10/home/.config/firstmate/cursor-api-key"
chmod 600 "$d10/home/.config/firstmate/cursor-api-key"
printf '#!/usr/bin/env bash\ntouch %q\nexec "$(dirname "$0")/mock.sh" "$@"\n' "$d10/cursor-ran" > "$r10/bin/adapters/cursor-agent.sh"
chmod +x "$r10/bin/adapters/cursor-agent.sh"
cat > "$d10/fakebin/cursor-agent" <<C
#!/usr/bin/env bash
[ "\$#" -eq 1 ] || exit 64
[ "\$1" = --version ] && { echo 2026.10.01-e373342; exit 0; }
[ "\$#" -eq 1 ] && [ "\$1" = --list-models ] || exit 64
printf '%s\n' --list-models >> "$d10/cursor-calls"
[ "\${CURSOR_API_KEY:-}" = fixture-cursor-key ] || exit 64
exec "$ROOT/tests/fixtures/auth-status/replay.sh" "$ROOT/tests/fixtures/auth-status/cursor-agent-signed-in.txt"
C
auth_probe_sandbox_tool "$d10/sandbox-tool" "$d10"
chmod +x "$d10/fakebin/cursor-agent"
printf '%s\n' '{"type":"vendor_unavailable","task":"T-Z","data":{"vendor":"cursor-agent","status":"unauthenticated"},"summary":{"en":"cursor-agent: unauthenticated: historical refusal","zh-TW":"cursor-agent：unauthenticated：歷史拒絕"}}' > "$d10/historical-event"
cat "$d10/historical-event" > "$r10/state/events.jsonl"
( cd "$r10" && env HOME="$d10/home" FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$d10/sandbox-tool" \
    FM_KEYCHAIN_TOOL="$d10/no-security" FM_SECRET_TOOL="$d10/no-secret-tool" \
    PATH="$d10/fakebin:$PATH" FM_ROOT="$r10" FM_GH="$GH10" \
    bin/fm-worker.sh --task T-Z >"$d10/out" 2>"$d10/err" )
assert_eq "0" "$?" "a historical cursor refusal does not refuse a fresh signed-in round"
assert_eq --list-models "$(cat "$d10/cursor-calls" 2>/dev/null)" "the worker checks cursor models afresh"
assert_ok "[ -f '$d10/cursor-ran' ]" "the authenticated cursor adapter runs"
head -n 1 "$r10/state/events.jsonl" > "$d10/preserved-event"
assert_ok "cmp -s '$d10/historical-event' '$d10/preserved-event'" "the historical event is preserved byte for byte"
assert_eq "1" "$(jq -s '[.[] | select(.type=="vendor_unavailable")]|length' "$r10/state/events.jsonl")" "no fresh refusal is appended for the working key"
rm -rf "$d10"

# When nothing in the chain is authenticated, the round is refused exactly
# as "every vendor was unavailable" always was - never by starting claude's
# CLI and discovering the failure inside the sandbox.
d7="$(fixture)"; r7="$d7/repo"; GH7="$(ghstub "$d7")"
printf 'vendor: claude\n' > "$r7/config.yaml"
( cd "$r7" && env "${auth_env[@]}" PATH="$d6/fakebin:$PATH" FM_ROOT="$r7" FM_GH="$GH7" \
    bin/fm-worker.sh --task T-Z >"$d7/out" 2>"$d7/err" )
assert_eq "2" "$?" "a chain with nothing authenticated exits 2, same as every vendor unavailable"
assert_contains "$(cat "$d7/err")" "claude:" "naming the vendor and the probe's own reason"

# A vendor never used exit code the probe cannot recognise (mock) passes
# through unprobed, so the existing fallback tests above are unaffected.

# Only `authenticated` is usable (T-121): a login the probe cannot confirm
# is refused like a definite no. gemini has no status command, so with a
# round's login present its probe is indeterminate - refused, named on the
# board as vendor_unavailable with its status, and the chain moves on to
# mock. gemini's adapter here is a stand-in that records whether it ran, so
# no real CLI or sandbox is involved.
d8="$(fixture)"; r8="$d8/repo"; GH8="$(ghstub "$d8")"
printf 'vendor: gemini\nfallback:\n  - mock\n' > "$r8/config.yaml"
printf '#!/usr/bin/env bash\ntouch %q\nexec "$(dirname "$0")/mock.sh" "$@"\n' "$d8/gemini-ran" > "$r8/bin/adapters/gemini.sh"
chmod +x "$r8/bin/adapters/gemini.sh"
mkdir -p "$d8/fakebin" "$d8/home/.gemini"
printf '#!/usr/bin/env bash\n[ "$1" = --version ] && { echo 0.60.0; exit 0; }\ntouch %q\nexit 1\n' "$d8/gemini-asked" \
  > "$d8/fakebin/gemini"
chmod +x "$d8/fakebin/gemini"
printf '{"access_token":"g","refresh_token":"r","expiry_date":%s}' "$(( ($(date +%s) + 86400) * 1000 ))" \
  > "$d8/home/.gemini/oauth_creds.json"
( cd "$r8" && env HOME="$d8/home" FM_KEYCHAIN_TOOL="$d8/no-security" FM_SECRET_TOOL="$d8/no-secret-tool" \
    PATH="$d8/fakebin:$PATH" FM_ROOT="$r8" FM_GH="$GH8" bin/fm-worker.sh --task T-Z >"$d8/out" 2>"$d8/err" )
assert_eq "0" "$?" "a gemini round whose login the probe cannot verify falls through to the next vendor"
assert_ok "[ ! -e '$d8/gemini-ran' ]" "gemini's adapter never runs: an indeterminate login is refused"
assert_ok "[ ! -e '$d8/gemini-asked' ]" "and gemini's CLI was asked nothing but its version"
refused="$(jq -r 'select(.type=="vendor_unavailable")|.summary.en, .summary["zh-TW"]' "$r8/state/events.jsonl" | tr '\n' ' ')"
assert_contains "$refused" "gemini: indeterminate:" "vendor_unavailable names gemini and the status, in English"
assert_contains "$refused" "gemini：indeterminate：" "and in Traditional Chinese"
assert_contains "$refused" "rounds on it are refused" "with the probe's own reason"
assert_lacks "$(jq -r 'select(.type=="crew_status")|.summary.en' "$r8/state/events.jsonl" | tr '\n' ' ')" \
  "unverified" "and never admitted as unverified"
rm -rf "$d8"

# A status check that does not answer in time is a timeout, refused the
# same way: never read as authenticated, named on the board, and the chain
# moves on.
d9="$(fixture)"; r9="$d9/repo"; GH9="$(ghstub "$d9")"
printf 'vendor: claude\nfallback:\n  - mock\n' > "$r9/config.yaml"
mkdir -p "$d9/fakebin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\n[ "$1" = --version ] && { echo "claude 2.1.0"; exit 0; }\nexec sleep 30\n' \
  "$d9/claude-calls" > "$d9/fakebin/claude"
chmod +x "$d9/fakebin/claude"
( cd "$r9" && env "${auth_env[@]}" FM_AUTH_PROBE_TIMEOUT=1 PATH="$d9/fakebin:$PATH" FM_ROOT="$r9" FM_GH="$GH9" \
    bin/fm-worker.sh --task T-Z >"$d9/out" 2>"$d9/err" )
assert_eq "0" "$?" "a claude login whose status check times out falls through to the next vendor"
assert_eq "" "$(grep -vxF -e '--version' -e 'auth status' "$d9/claude-calls" 2>/dev/null)" \
  "claude's own CLI is never started for the round itself"
assert_contains "$(jq -r 'select(.type=="vendor_unavailable")|.summary.en' "$r9/state/events.jsonl" | tr '\n' ' ')" \
  "claude: timeout:" "vendor_unavailable names claude and the timeout"
rm -rf "$d9"


cd "$ROOT" || exit 1
PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
