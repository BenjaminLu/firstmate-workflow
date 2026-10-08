#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/adapter.sh
. "$ROOT/tests/lib/adapter.sh"
# shellcheck source=tests/lib/adapter-policy.sh
. "$ROOT/tests/lib/adapter-policy.sh"
for v in claude codex cursor-agent gemini; do
  # every adapter declares what its own flags enforce, and what the sandbox adds
  said="$(FM_SANDBOX_OS=linux FM_SANDBOX_TOOL="$pk/bwrap" FM_POLICY="$pk/none.json" \
    "$ROOT/bin/adapters/$v.sh" dimensions 2>/dev/null)"
  assert_contains "$said" "native: " "$v declares the dimensions its flags enforce"
  assert_contains "$said" "sandbox: write read network sockets env repo-config refuse ulimit" \
    "and the ones the Linux sandbox adds: every one"
  # no OS sandbox: reading is default-deny only there, so every vendor is refused
  assert_eq "2" "$(confined darwin "$pv/no-such-sandbox" "$pk/none.json" "$v")" \
    "$v with no OS sandbox is refused, as an unavailable vendor is"
  assert_fail "test -e '$pv/argv'" "and $v's CLI never starts"
  assert_contains "$(cat "$pv/err")" "read" "and it says the dimension nobody enforces"
  # macOS: the sandbox covers every dimension, so every vendor runs inside it
  assert_eq "0" "$(confined darwin "$pk/sandbox-exec" "$pk/none.json" "$v")" "$v runs inside sandbox-exec"
  assert_ok "test -s '$pk/profile.sb'" "behind a profile made from the policy"
  assert_contains "$(cat "$pk/profile.sb" 2>/dev/null)" "(deny network*)" "which denies $v's round the network"
  # the sandbox's own files are in the adapter's control directory: not the
  # round's TMPDIR, a write root, and not a fixed /tmp a confined caller
  # cannot write
  assert_matches "$(cat "$pk/profile.path" 2>/dev/null)" '/fm-ctl\.[A-Za-z0-9]+/fm-sb\.[A-Za-z0-9]+/profile$' \
    "$v's profile is kept in the adapter's control directory, out of the round's reach"
  # the keychain is out of reach of every vendor's round, whatever login it
  # was handed (T-117): gh's token and git's credentials are kept there
  assert_contains "$(grep '^(deny mach-lookup' "$pk/profile.sb" 2>/dev/null)" '(global-name "com.apple.SecurityServer")' \
    "$v's round cannot reach the keychain"
  assert_eq "" "$(grep 'allow mach-lookup' "$pk/profile.sb" 2>/dev/null || true)" "and nothing lets it back in"
  # claude's own quiet-refusals switch (T-123): turns off its non-essential
  # network traffic (telemetry, error reporting), so the proxy no longer
  # reports one of those hosts (http-intake.logs.us5.datadoghq.com, for one)
  # as a refused host needing the project's network policy. Claude's alone,
  # never another vendor's round.
  case "$v" in
    claude) assert_contains "$(cat "$pv/env" 2>/dev/null)" "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1" \
              "$v turns off its own non-essential network traffic (telemetry, error reporting)" ;;
    *) assert_lacks "$(cat "$pv/env" 2>/dev/null)" "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" \
         "$v is given none of claude's quiet-refusals variable" ;;
  esac
done
# a seatbelt cannot start inside sandbox-exec, so under it the vendors' own
# sandboxes are off and the outer one confines their commands
confined darwin "$pk/sandbox-exec" "$pk/none.json" claude >/dev/null
assert_eq "false" "$(settings_of | jq -r '.sandbox.enabled' 2>/dev/null)" "on macOS claude's own sandbox is off"
assert_eq "Bash" "$(awk '$0=="--allowedTools"{on=1;next} /^--/{on=0} on' "$pv/argv" | grep -x Bash)" \
  "and its shell runs under the outer one"
assert_ne "" "$(awk '$0=="--disallowedTools"{on=1;next} /^--/{on=0} on' "$pv/argv" | grep -xF 'Bash(git push:*)')" \
  "while its deny rules still refuse a push"
# claude's own state and temp directories (T-117): the one /tmp/claude-<uid>
# it keeps whatever TMPDIR says is writable, and nothing of the operator's
# ~/.claude is
cprof="$(cat "$pk/profile.sb" 2>/dev/null)"
ctmp="$(cd /tmp && pwd -P)/claude-$(id -u)"
assert_contains "$cprof" "(allow file-read* file-write* (subpath \"$ctmp\"))" \
  "claude's round may write the temp directory claude keeps under /tmp"
assert_lacks "$cprof" "(regex #\"^$(printf '%s' "$phome" | sed 's/[.^$|?*+()]/\\&/g')/\\.claude" \
  "and none of the operator's ~/.claude"
rtmp_c="$(sed -n 's/^TMPDIR=//p' "$pv/env" 2>/dev/null)"
assert_eq "$rtmp_c/claude-config" "$(sed -n 's/^CLAUDE_CONFIG_DIR=//p' "$pv/env" 2>/dev/null)" \
  "its config directory is the round's own"
assert_eq "$rtmp_c" "$(sed -n 's/^CLAUDE_CODE_TMPDIR=//p' "$pv/env" 2>/dev/null)" "and its temp files go to the round's"
confined darwin "$pk/sandbox-exec" "$pk/none.json" codex >/dev/null
assert_eq "danger-full-access" "$(awk 'on{print;exit} $0=="--sandbox"{on=1}' "$pv/argv")" "codex's own sandbox is off"
assert_lacks "$(cat "$pk/profile.sb" 2>/dev/null)" "claude-$(id -u)" "and another vendor's round is given none of claude's"
confined darwin "$pk/sandbox-exec" "$pk/none.json" cursor-agent >/dev/null
assert_eq "disabled" "$(awk 'on{print;exit} $0=="--sandbox"{on=1}' "$pv/argv")" "and cursor-agent's"
assert_ne "" "$(grep -x -- --trust "$pv/argv")" "cursor-agent still trusts only the worktree it is handed"
# with its own sandbox off, a print-mode round approves no shell command
# unless forced (the canary, 2026-09-26: signed in, exit 0, no probe run);
# inside sandbox-exec the OS sandbox confines them, as it does claude's Bash
assert_ne "" "$(grep -x -- -f "$pv/argv")" "and its commands go through to the OS sandbox around it"
assert_eq "" "$(grep -x -- --approve-mcps "$pv/argv")" "while MCP servers stay unapproved"
# Linux: bwrap gives the round a network namespace of its own whose one way
# out is the proxy, so every vendor runs there too, registries or not - and
# a host it refuses is named, whichever vendor's commands asked for it
for pol in none net; do
  for v in claude codex cursor-agent gemini; do
    assert_eq "0" "$(confined linux "$pk/bwrap" "$pk/$pol.json" "$v")" "$v runs under bwrap ($pol)"
    assert_contains "$(cat "$pk/bwrap.args" 2>/dev/null)" "--unshare-net" "in a network of the round's own"
    assert_contains "$(cat "$pk/bwrap.args" 2>/dev/null)" "proxy.sock" "reaching out only through the proxy's socket"
  done
done
# the vendors' own sandboxes on Linux: claude's off (its proxy would route
# around fm's), codex's and cursor-agent's on, codex's network switch on so
# its commands can reach the proxy at all
confined linux "$pk/bwrap" "$pk/none.json" claude >/dev/null
assert_eq "false" "$(settings_of | jq -r '.sandbox.enabled' 2>/dev/null)" "on Linux claude's own sandbox is off"
assert_eq "null" "$(settings_of | jq -c '.sandbox.network' 2>/dev/null)" "and it carries no network of its own to route around fm's"
confined linux "$pk/bwrap" "$pk/none.json" codex >/dev/null
assert_eq "workspace-write" "$(awk 'on{print;exit} $0=="--sandbox"{on=1}' "$pv/argv")" "codex's own sandbox confines its writes"
assert_ne "" "$(grep -x 'sandbox_workspace_write.network_access=true' "$pv/argv")" "with its network switch on"
confined linux "$pk/bwrap" "$pk/none.json" cursor-agent >/dev/null
assert_eq "enabled" "$(awk 'on{print;exit} $0=="--sandbox"{on=1}' "$pv/argv")" "cursor-agent's own sandbox is on"
assert_eq "" "$(grep -xE -- '-f|--force' "$pv/argv")" "and cursor-agent is not forced on Linux, where its sandbox runs the commands"

# --- every location a round is handed is one it may write (T-117) ----------
# A round is handed directories through its environment: its temp
# directory, the toolchain's caches (bun's, Playwright's, npm's, pip's,
# Go's, XDG's), each vendor's config home, and the directory its final
# answer goes to. Each has to be inside what the generated profile (macOS)
# or bwrap arguments (Linux) let the round write, or `setup` and the
# vendor itself are refused. The caller here hands in cache locations of
# its own, the way fm-review.sh once did beside its checkout and the
# operator's shell may: none is a write root, so none may reach the round.
writable_in() {   # writable_in <os> <path> -> 0 when the round may write <path>
  local r roots
  if [ "$1" = darwin ]; then
    # the write roots are the one rule that follows (deny file-write*)
    roots="$(grep '^(allow file-write\* ' "$pk/profile.sb" 2>/dev/null \
      | grep -o '(subpath "[^"]*")' | sed 's/^(subpath "//; s/")$//')"
  else
    roots="$(awk 'prev=="--bind"{print} {prev=$0}' "$pk/bwrap.args" 2>/dev/null)"
  fi
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$2/" in "${r%/}"/*) return 0 ;; esac
  done <<< "$roots"
  return 1
}
round_locations() {   # round_locations <vendor> <os> -> the variables naming a location its CLI is handed
  printf '%s\n' TMPDIR TMP TEMP XDG_CACHE_HOME BUN_INSTALL_CACHE_DIR PLAYWRIGHT_BROWSERS_PATH \
    npm_config_cache PIP_CACHE_DIR GOCACHE GOMODCACHE
  case "$1" in
    claude) printf '%s\n' CLAUDE_CONFIG_DIR CLAUDE_CODE_TMPDIR ;;
    codex) printf '%s\n' CODEX_HOME ;;
    cursor-agent) printf '%s\n' CURSOR_DATA_DIR ;;
    gemini) printf '%s\n' HOME GEMINI_CLI_HOME ;;
  esac
}
mkdir -p "$pv/elsewhere/checkout/.git" "$pv/attempt"
for loc_role in worker run-review; do
  for loc_os in darwin linux; do
    loc_tool="$pk/sandbox-exec"; [ "$loc_os" = linux ] && loc_tool="$pk/bwrap"
    for v in claude codex cursor-agent gemini; do
      if [ "$loc_role" = run-review ]; then
        grep -q '^# fm:review-run' "$ROOT/bin/adapters/$v.sh" || continue
        loc_rc="$(FM_RUN_REVIEW=1 FM_REVIEW_CHECKOUT="$pv/elsewhere/checkout" \
          XDG_CACHE_HOME="$pv/elsewhere/xdg" BUN_INSTALL_CACHE_DIR="$pv/elsewhere/bun" \
          PLAYWRIGHT_BROWSERS_PATH="$pv/elsewhere/pw" npm_config_cache="$pv/elsewhere/npm" \
          confined "$loc_os" "$loc_tool" "$pk/none.json" "$v")"
      else
        loc_rc="$(FM_ATTEMPT_DIR="$pv/attempt" FM_FINAL_PATH="$pv/attempt/final.txt" \
          XDG_CACHE_HOME="$pv/elsewhere/xdg" BUN_INSTALL_CACHE_DIR="$pv/elsewhere/bun" \
          PLAYWRIGHT_BROWSERS_PATH="$pv/elsewhere/pw" npm_config_cache="$pv/elsewhere/npm" \
          confined "$loc_os" "$loc_tool" "$pk/none.json" "$v")"
      fi
      loc_at="$v, $loc_role, $loc_os"
      if [ "$loc_role" = run-review ] && [ "$v" = codex ]; then
        # This unmanaged fixture lacks the transport receipt and pinned refs.
        # T-163's feature suite checks the managed launch and protected roots.
        assert_eq "64" "$loc_rc" "codex refuses missing managed context ($loc_os)"
        continue
      fi
      assert_eq "0" "$loc_rc" "$v's round starts ($loc_role, $loc_os)"
      # the CLI's own view of its environment, as the fake sandbox ran it
      loc_env="$(cat "$pv/env" 2>/dev/null)"
      while IFS= read -r loc_n; do
        loc_p="$(sed -n "s/^$loc_n=//p" <<< "$loc_env" | head -1)"
        assert_ne "" "$loc_p" "$v's round is handed $loc_n ($loc_at)"
        [ -n "$loc_p" ] || continue
        writable_in "$loc_os" "$loc_p"
        assert_eq "0" "$?" "and may write it: $loc_n=$loc_p ($loc_at)"
      done < <(round_locations "$v" "$loc_os")
      # Regression guard (unchanged on base): cursor-agent's login is CURSOR_API_KEY (T-117 round 6): no config
      # home of fm's moves it off its own ~/.cursor/cli-config.json
      if [ "$v" = cursor-agent ]; then
        assert_eq "${XDG_CONFIG_HOME:-}" "$(sed -n 's/^XDG_CONFIG_HOME=//p' <<< "$loc_env")" \
          "cursor-agent is handed no XDG_CONFIG_HOME of fm's ($loc_at)"
      fi
      # and every other directory the round is handed that the caller did
      # not already have: a location added later is checked too
      while IFS='=' read -r loc_n loc_p; do
        case "$loc_n" in PWD|OLDPWD|''|*[!A-Za-z0-9_]*) continue ;; esac
        case "$loc_p" in /*) ;; *) continue ;; esac
        [ -d "$loc_p" ] || continue
        [ "$(printenv "$loc_n" 2>/dev/null)" != "$loc_p" ] || continue
        writable_in "$loc_os" "$loc_p"
        assert_eq "0" "$?" "every directory $v's round is handed may be written: $loc_n=$loc_p ($loc_at)"
      done <<< "$loc_env"
      # the final answer is written by the CLI itself for codex; wherever
      # it is, its directory is a write root
      if [ "$loc_role" = worker ]; then
        writable_in "$loc_os" "$(cd "$pv/attempt" && pwd -P)/final.txt"
        assert_eq "0" "$?" "and the directory its final answer goes to ($loc_at)"
      fi
    done
  done
done
rm -f "$pv/attempt/cli-exit-code"
# the declared registries reach the layer that enforces the network: the
# proxy, which lets exactly them through, and the profile, whose only way
# off the machine is that proxy
for h in registry.npmjs.org cdn.playwright.dev; do
  "$ROOT/bin/fm-sandbox.sh" decide --policy="$pk/net.json" "$h" >/dev/null 2>&1
  assert_eq "0" "$?" "the OS sandbox's proxy lets $h through"
done
"$ROOT/bin/fm-sandbox.sh" decide --policy="$pk/net.json" pypi.org >/dev/null 2>&1
assert_eq "1" "$?" "but no undeclared host"
assert_eq "0" "$(confined darwin "$pk/sandbox-exec" "$pk/net.json" codex)" "on macOS codex runs with registries declared"
# Off the machine only through the proxy: nothing but loopback is allowed.
# Loopback itself holds two allows - the ports the round opens, and the
# proxy's again after the denies of what was already listening.
cprof="$(cat "$pk/profile.sb" 2>/dev/null)"
assert_ne "" "$cprof" "and a profile was made for it"
assert_eq "" "$(grep 'allow network' <<< "$cprof" | grep -v '"localhost:' || true)" \
  "and its round reaches the network only through that proxy"
assert_matches "$(grep 'allow network-outbound' <<< "$cprof" | tail -1)" '"localhost:[0-9]+"' \
  "whose port is the last allowed, after every deny"
assert_contains "$cprof" '(deny network-outbound (remote ip "localhost:5555"))' \
  "while a listener older than the round stays out of reach"
assert_contains "$cprof" '(deny network-bind network-inbound (local ip "localhost:5555"))' \
  "and cannot be bound or accepted on either (T-153)"

# The sandbox failing before the CLI is not the model giving up: the
# launcher's exit code is not the CLI's, and the vendor counts unavailable
# so the chain moves on. The CLI's own non-zero exit is still a failed
# attempt.
cat > "$pv/broken-sandbox" <<'S'
#!/usr/bin/env bash
echo "sandbox-exec: sandbox_apply: Operation not permitted" >&2
exit 70
S
chmod +x "$pv/broken-sandbox"
for v in claude codex cursor-agent gemini; do
  assert_eq "2" "$(confined darwin "$pv/broken-sandbox" "$pk/none.json" "$v")" \
    "$v whose sandbox cannot start reports unavailable, not a failed attempt"
  assert_fail "test -e '$pv/argv'" "and $v's CLI never started"
  assert_contains "$(cat "$pv/err")" "did not start the CLI" "and says so"
  printf '#!/usr/bin/env bash\ncat > /dev/null\nprintf "%%s\\n" "$@" > "%s/argv"\necho "it went wrong"\nexit 70\n' \
    "$pv" > "$pv/fakebin/$v"
  rm -f "$pv/argv"
  FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$pk/sandbox-exec" FM_POLICY="$pk/none.json" PATH="$pv/fakebin:$closed_path" \
    "$ROOT/bin/adapters/$v.sh" run "$pv/prompt" "$pv/tree" "$pv/log" >/dev/null 2>&1
  assert_eq "1" "$?" "while $v's own exit 70, inside a sandbox that started, is a failed attempt"
  assert_ok "test -e '$pv/argv'" "($v's CLI did run)"
done
# Policy parsing and adapter enforcement share this suite as their home.
refusal_root="$(safe_tmpdir)"
refusal_policy() {
  printf '%s' "$2" > "$refusal_root/config.yaml"
  ( . "$ROOT/bin/fm-config.sh"
    fm_policy "$1" "" "$refusal_root/config.yaml" )
}
# what may never be declared: GitHub, loopback, anything not a plain name
for bad in github.com api.github.com raw.githubusercontent.com ghcr.io localhost dev.localhost \
           127.0.0.1 10.0.0.1 '*' '*.com'; do
  out="$(refusal_policy worker "policy:
  network: registry.npmjs.org $bad
" 2>&1)"
  assert_eq "65" "$?" "a network naming '$bad' is refused"
  assert_contains "$out" "names $bad, which" "and names it"
done
out="$(refusal_policy worker 'policy:
  network: localhost
' 2>&1)"
assert_contains "$out" "may not reach loopback" "loopback is said to be loopback"
out="$(refusal_policy worker 'policy:
  network: api.github.com
' 2>&1)"
assert_contains "$out" "may not reach GitHub" "and GitHub GitHub"
out="$(refusal_policy worker 'projects:
  app:
    repo: .
    github: o/app
    base: main
    required_check: ci
    policy:
      worker:
        network: 127.0.0.1
' 2>&1)"
assert_eq "65" "$?" "a project cannot declare loopback either"
out="$(refusal_policy worker 'policy:
  network: notgithub.com
' 2>&1)"
assert_eq "0" "$?" "a label ending in github is not GitHub policy"
assert_eq '["notgithub.com"]' "$(jq -c .network <<<"$out")" "the allowed label survives policy parsing"
rm -rf "$refusal_root"

# loopback and GitHub are never allowed, not even by a policy file that says so
# The hosts every adapter builds its flags from are the policy's
# (FM_POLICY_HOSTS), so a malformed entry is refused there too - not only in
# FM_REVIEW_NETWORK, which fm_adapter_context still checks for a run-mode
# review. A `*` is read as itself: expanded, it became the file names in
# the working directory, which pass as domains.
mkdir -p "$pv/globdir"; : > "$pv/globdir/x.org"
for bad in github.com api.github.com localhost 127.0.0.1 'x.org","*' '*'; do
  jq --arg h "$bad" '.network = ["registry.npmjs.org", $h]' "$pk/net.json" > "$pv/bad.json"
  for v in claude codex cursor-agent gemini; do
    assert_eq "65" "$(cd "$pv/globdir" && confined darwin "$pk/sandbox-exec" "$pv/bad.json" "$v")" \
      "$v refuses a policy whose network names $bad"
    assert_fail "test -e '$pv/argv'" "and $v's CLI never starts ($bad)"
  done
  "$ROOT/bin/fm-sandbox.sh" decide --policy="$pv/bad.json" "$bad" >/dev/null 2>&1
  assert_eq "1" "$?" "and the proxy never lets $bad through"
done

# FM_ADAPTER_ARGS come after the policy's flags and the last value wins, so
# one that touches permissions is refused in every round, not only a
# run-mode review, and for every vendor
for pair in "claude --dangerously-skip-permissions" "claude --permission-mode bypassPermissions" \
            "claude --settings x.json" "claude --add-dir /" "claude --mcp-config x.json" \
            "codex --sandbox danger-full-access" "codex --dangerously-bypass-approvals-and-sandbox" \
            "codex -c sandbox_mode=danger-full-access" "codex --full-auto" "codex --add-dir /" \
            "cursor-agent -f" "cursor-agent --force" "cursor-agent --sandbox disabled" "cursor-agent --approve-mcps" \
            "gemini --sandbox false" "gemini --extensions all" "gemini --allowed-mcp-server-names x" \
            "gemini --include-directories /"; do
  v="${pair%% *}"; extra="${pair#* }"
  assert_eq "64" "$(FM_ADAPTER_ARGS="$extra" confined darwin "$pk/sandbox-exec" "$pk/none.json" "$v")" \
    "$v refuses a worker round whose extra arguments say $extra"
  assert_fail "test -e '$pv/argv'" "and $v's CLI never starts ($extra)"
done


safe_rm_rf "$pv"
safe_rm_rf "$pk" "$closed_path"
finish
