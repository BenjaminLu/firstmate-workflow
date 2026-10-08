#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/adapter.sh
. "$ROOT/tests/lib/adapter.sh"
assert_eq "[]" "$(jq -c .network "$pk/none.json" 2>/dev/null)" "the suite's policy declares no registry"
assert_eq '["registry.npmjs.org","cdn.playwright.dev"]' "$(jq -c .network "$pk/net.json" 2>/dev/null)" \
  "and its other one two"
for adapter in "$ROOT"/bin/adapters/*.sh; do
  name="$(basename "$adapter" .sh)"
  case "$name" in _*) continue ;; esac   # shared library, not an adapter
  printf '  %s\n' "$name"
  # Linux, where the vendors' own sandboxes that can nest stay on (codex's
  # workspace-write, cursor-agent's); macOS's below
  export FM_SANDBOX_OS=linux FM_SANDBOX_TOOL="$pk/bwrap"

  assert_ok "test -x '$adapter'" "$name is executable"
  out="$("$adapter" 2>&1)"; rc=$?
  assert_eq "64" "$rc" "$name rejects a missing subcommand"
  assert_contains "$out" "usage" "$name prints usage"

  d="$(safe_tmpdir)"; make_sandbox "$d"
  mkdir -p "$d/tree" "$d/outside"
  echo "do the thing" > "$d/prompt"
  echo "canary" > "$d/outside/canary"
  before="$(find "$d/outside" -type f -exec shasum {} + | shasum)"

  if [ "$name" = "mock" ]; then
    PATH="$d/fakebin:$PATH" "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
    assert_eq "0" "$?" "mock exits 0 by default"
    assert_ok "test -s '$d/tree/mock.txt'" "mock wrote inside the worktree"
    FM_MOCK_EXIT=1 PATH="$d/fakebin:$PATH" "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
    assert_eq "1" "$?" "mock can report an attempt that failed"
    FM_MOCK_EXIT=2 PATH="$d/fakebin:$PATH" "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
    assert_eq "2" "$?" "mock can report the vendor being unavailable"
    # mock is the default vendor and the engine every e2e runs on, so its
    # scripted verdicts are a contract too. A fresh log each time, or the
    # assertion is satisfied by what the previous run wrote.
    FM_MOCK_EXIT=0 FM_MOCK_BODY="a body only this test would ask for" PATH="$d/fakebin:$PATH" \
      "$adapter" run "$d/prompt" "$d/tree" "$d/fresh.log" >/dev/null 2>&1
    assert_ok "test -s '$d/fresh.log'" "mock says what it did in the log it was handed"
    assert_contains "$(cat "$d/tree/mock.txt")" "only this test would ask for" "and FM_MOCK_BODY is a knob that exists"
    # an unavailable vendor leaves the worktree exactly as it found it, which
    # is checked by comparing it rather than by naming a file nothing creates
    rm -rf "$d/tree"; mkdir -p "$d/tree"; echo keep > "$d/tree/existing"
    tb="$(find "$d/tree" -type f -exec shasum {} + | shasum)"
    FM_MOCK_EXIT=2 PATH="$d/fakebin:$PATH" "$adapter" run "$d/prompt" "$d/tree" "$d/u.log" >/dev/null 2>&1
    assert_eq "$tb" "$(find "$d/tree" -type f -exec shasum {} + | shasum)" \
      "an unavailable mock leaves the worktree exactly as it found it"
  else
    # a PATH without the vendor CLI - but with a shell, or the script never
    # starts and 127 gets mistaken for a contract failure
    PATH="$d/fakebin:$closed_path" "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
    assert_eq "2" "$?" "$name exits 2 when its CLI is missing"
  fi

  # a vendor that prints an auth error and exits 0 is unavailable, not done.
  # Every vendor can do this, so every adapter is asked - except mock, which
  # has no CLI to lie to it. Its own promise is checked just below instead.
  if [ "$name" != "mock" ]; then
    vendor_says() {  # <stdout> <exit code>
      # cursor-agent's own preflight (T-127) asks `--list-models` before
      # every round with a model configured; a stub built for the real
      # invocation's transcript answers that separate call as a CLI with no
      # session yet would - silently (exit 1) - so a canned body meant for
      # the round's own transcript is never misread as its model catalogue.
      printf '#!/usr/bin/env bash\nif [ "$1" = "--list-models" ]; then exit 1; fi\nprintf "%%s\\n" %s\nexit %s\n' \
        "$(printf '%q' "$1")" "$2" > "$d/fakebin/$name"
      chmod +x "$d/fakebin/$name"
    }
    for line in "Error: Authentication required. Please run 'agent login' first" \
                "Error: you are not logged in" \
                "Error: quota exceeded for this organisation" \
                "fetch failed: ENOTFOUND api.example.com" \
                "Authentication required." \
                "401 Unauthorized"; do
      vendor_says "$line" 0
      PATH="$d/fakebin:$closed_path" "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
      assert_eq "2" "$?" "$name reports unavailable when the CLI says: ${line%% *}..."
    done
    vendor_says "" 0
    PATH="$d/fakebin:$closed_path" "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
    assert_eq "1" "$?" "$name does not call a silent run a success"
    # the prompt has to actually reach the CLI, AND the invocation has to be
    # one the real CLI would accept. A fake that unconditionally reads stdin
    # cannot exhibit the gemini bug - real gemini's -p takes the prompt as
    # its value and ignores stdin - so the argv is asserted as well, against
    # the invocation each vendor documents.
    # stdin and argv are recorded apart, so each adapter can be held to the
    # half its CLI actually documents
    # cursor-agent's own preflight (T-127) asks `--list-models` before every
    # round with a model configured; this stub is reused below with
    # FM_MODEL=claude-opus-5-5, so it answers that separate call with a
    # catalogue naming it, rather than recording it into argv/stdin as
    # though it were the round's own invocation.
    printf '#!/usr/bin/env bash\nif [ "$1" = "--list-models" ]; then printf "claude-opus-5-5 - Claude Opus\\n"; exit 0; fi\ncat >> "%s/stdin" 2>/dev/null\nprintf "%%s" "$*" >> "%s/argv"\nprintf "ran\\n"\nexit 0\n' \
      "$d" "$d" > "$d/fakebin/$name"
    chmod +x "$d/fakebin/$name"
    : > "$d/stdin"; : > "$d/argv"
    PATH="$d/fakebin:$closed_path" "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
    # every one of them hands the prompt over on stdin; that is the whole
    # reason an adapter may not touch git - the CLI never sees the repository
    assert_contains "$(cat "$d/stdin")" "do the thing" "$name delivers the prompt on stdin"
    argv="$(cat "$d/argv")"
    tr_="$(cd "$d/tree" && pwd -P)"
    case "$name" in
      # a worker must be able to edit files in its own worktree and there is
      # nobody to answer a prompt; a run that cannot write produces nothing
      # and reads as a model that gave up. Since T-105 that is a rule for
      # the worktree, not acceptEdits for every path
      claude) assert_contains " $argv " " --permission-mode dontAsk " \
                "$name asks nobody: what no rule allows is denied"
              assert_contains "$argv" "Edit(/$tr_/**)" "$name may edit files in its worktree without asking"
              assert_lacks "$argv" "acceptEdits" "$name no longer accepts every edit wholesale" ;;
    esac
    # One branch per vendor: a combined `claude|cursor-agent)` above a
    # `cursor-agent)` branch matched first, and the second never ran.
    case "$name" in
      # -p here means "print mode", a bare flag: stdin carries the prompt
      claude) assert_contains " $argv " " -p " "$name asks for print mode" ;;
      # gemini's -p takes the prompt as its VALUE. The documented headless
      # form is a piped stdin and no -p at all: a bare -p leaves the flag
      # dangling and the prompt is never delivered.
      # and, since T-105, only the flags that carry the policy
      gemini) assert_eq "--approval-mode yolo --extensions none --allowed-mcp-server-names fm-none --output-format json" "$argv" \
                "$name uses the documented headless form, with the policy's flags, and JSON output for its record (T-127)"
              assert_lacks " $argv " " -p " "$name passes no dangling -p" ;;
      # under bwrap (this loop's platform for it) cursor's own sandbox stays on
      cursor-agent)
              assert_contains " $argv " " -p " "$name asks for print mode"
              assert_contains " $argv " " --trust --sandbox enabled " "$name trusts the worktree and runs its sandbox"
              assert_lacks " $argv " " -f " "$name no longer forces every command through"
              assert_lacks " $argv " " --force " "$name nor with --force" ;;
      # codex reads stdin only when the last argument is the marker "-"
      # codex reads a prompt only as `codex exec ... -`: the subcommand, the
      # flag that lets it run outside a repository, and the stdin marker
      # last. Asserting only the marker let the rest drift.
      codex) assert_eq "exec" "${argv%% *}" "$name asks for the non-interactive subcommand"
             assert_contains " $argv " " --skip-git-repo-check " "$name does not require a repository"
             assert_eq "-" "${argv##* }" "$name keeps the stdin marker last"
             # its network switch is on: codex has only on and off, and the
             # OS sandbox is what limits it to the declared registries
             assert_contains " $argv " " --sandbox workspace-write -c sandbox_workspace_write.network_access=true " \
               "$name confines its commands' writes to the worktree"
             assert_contains " $argv " ' -c approval_policy="never" ' "$name asks nobody to approve a command"
             assert_contains " $argv " " -c mcp_servers={} " "$name starts no MCP server"
             assert_contains "$argv" 'shell_environment_policy.exclude=["GH_TOKEN","GITHUB_TOKEN"' \
               "$name drops the policy's scrub list from its commands' environment"
             assert_contains "$argv" '"AWS_*"' "$name drops whole credential families by prefix" ;;
    esac
    # every round is confined now, not only a run-mode review (T-105)
    case "$name" in
      claude) assert_contains " $argv " " --restricted " "$name loads none of the operator's or the branch's settings" ;;
    esac
    assert_ok "test -s '$pk/bwrap.args' || test -s '$pk/profile.sb'" "$name's CLI ran inside the OS sandbox"
    rm -f "$pk/bwrap.args" "$pk/profile.sb"

    # --- config.yaml's model, applied (T-127) -----------------------------
    : > "$d/argv"
    FM_MODEL="claude-opus-5-5" PATH="$d/fakebin:$closed_path" \
      "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
    model_argv="$(cat "$d/argv")"
    case "$name" in
      claude|cursor-agent)
        assert_contains " $model_argv " " --model claude-opus-5-5 " \
          "$name passes the configured model with --model" ;;
      codex|gemini)
        assert_contains " $model_argv " " -m claude-opus-5-5 " \
          "$name passes the configured model with -m" ;;
    esac
    # every vendor is asked for JSON output now, unconditionally, since that
    # is where the round's own model comes back (T-127)
    case "$name" in
      claude|cursor-agent|gemini) assert_contains " $model_argv " " --output-format json " \
        "$name asks for JSON output so its round's model can be read back" ;;
      codex) assert_contains " $model_argv " " --json " "$name asks for JSON output too" ;;
    esac
    # with no FM_MODEL at all, none of these flags appear
    : > "$d/argv"
    PATH="$d/fakebin:$closed_path" "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
    no_model_argv="$(cat "$d/argv")"
    assert_lacks " $no_model_argv " " --model " "$name passes no --model when none is configured"
    assert_lacks " $no_model_argv " " -m " "$name passes no -m when none is configured"
    # config.yaml is the one place a model is chosen: an operator argument
    # naming one is refused, for every vendor, in every round
    case "$name" in
      claude) model_extras="--model gpt-5|--fallback-model gpt-5" ;;
      cursor-agent) model_extras="--model gpt-5" ;;
      codex|gemini) model_extras="-m gpt-5|--model gpt-5" ;;
    esac
    saved_ifs2="$IFS"; IFS='|'
    for extra in $model_extras; do
      IFS="$saved_ifs2"
      FM_ADAPTER_ARGS="$extra" PATH="$d/fakebin:$closed_path" \
        "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>"$d/model-err"
      assert_eq "64" "$?" "$name refuses FM_ADAPTER_ARGS naming a model ($extra)"
      assert_contains "$(cat "$d/model-err")" "config.yaml is the one place a model is chosen" \
        "and says why ($name, $extra)"
      IFS='|'
    done
    IFS="$saved_ifs2"
    # a model the vendor does not recognise refuses the round loudly, named
    # on the board, rather than falling back to another vendor or running on
    # the CLI's default: claude's own answer, verbatim; the others against
    # a generic phrase list, the way _FM_SIG covers an outage for all four
    case "$name" in
      claude) refusal_line='[claude-code:unrecognized_model] the model "bad-model-9000" was not recognised' ;;
      *)      refusal_line='Error: unrecognized model "bad-model-9000"' ;;
    esac
    vendor_says "$refusal_line" 1
    refused_dir="$(safe_tmpdir)"; : > "$refused_dir/refused"
    FM_MODEL="bad-model-9000" FM_MODEL_REFUSED="$refused_dir/refused" \
      PATH="$d/fakebin:$closed_path" "$adapter" run "$d/prompt" "$d/tree" "$d/model-refusal.log" \
      >/dev/null 2>"$d/model-refusal.err"
    assert_eq "64" "$?" "$name refuses a round whose model it does not recognise"
    assert_contains "$(cat "$d/model-refusal.err")" "bad-model-9000" "and names the model on stderr"
    assert_contains "$(cat "$refused_dir/refused")" "bad-model-9000" "and records it for the caller to raise on the board"
    safe_rm_rf "$refused_dir"

    # --- false positives (T-127 review round 5) ---------------------------
    # A completed round (exit 0) is never read as a refusal, however the
    # words in its transcript happen to fall: the whole point of the check
    # is that a signature alone must never discard real work.
    vendor_says "$refusal_line" 0
    : > "$d/model-ok.log"
    FM_MODEL="bad-model-9000" PATH="$d/fakebin:$closed_path" \
      "$adapter" run "$d/prompt" "$d/tree" "$d/model-ok.log" >/dev/null 2>"$d/model-ok.err"
    assert_ne "64" "$?" "$name does not refuse a completed round even carrying the refusal's words"
    # Ordinary prose that merely discusses models - the kind this very
    # codebase's own commits now contain - must never trip it either, exit
    # code aside: it does not open the line the way a CLI's own usage error
    # does.
    for prose in "Reviewed the ORM's invalid model names and fixed the migration." \
                 "The data model was unknown to the linter; renamed the field." \
                 "No such model found in the fixtures; added one."; do
      vendor_says "$prose" 1
      : > "$d/model-prose.log"
      FM_MODEL="bad-model-9000" PATH="$d/fakebin:$closed_path" \
        "$adapter" run "$d/prompt" "$d/tree" "$d/model-prose.log" >/dev/null 2>"$d/model-prose.err"
      assert_ne "64" "$?" "$name does not refuse on prose alone: \"${prose%% *}...\""
    done
    # A vendor that reports the model it actually ran on already ran a
    # turn: whatever error text follows in the same transcript is not "the
    # CLI never started", so it is never read as a model refusal either.
    vendor_says "{\"type\":\"result\",\"model\":\"claude-opus-5-5\"} then: $refusal_line" 1
    : > "$d/model-worked.log"
    FM_MODEL="bad-model-9000" PATH="$d/fakebin:$closed_path" \
      "$adapter" run "$d/prompt" "$d/tree" "$d/model-worked.log" >/dev/null 2>"$d/model-worked.err"
    assert_ne "64" "$?" "$name does not refuse a transcript that already reports a model ran"
    # claude's result names no "model": what ran is modelUsage's keys (T-146)
    vendor_says "{\"type\":\"result\",\"modelUsage\":{\"claude-opus-5-5\":{\"outputTokens\":9}}} then: $refusal_line" 1
    : > "$d/model-usage.log"
    FM_MODEL="bad-model-9000" PATH="$d/fakebin:$closed_path" \
      "$adapter" run "$d/prompt" "$d/tree" "$d/model-usage.log" >/dev/null 2>"$d/model-usage.err"
    assert_ne "64" "$?" "$name does not refuse a transcript whose modelUsage reports a model ran"
    # and an empty modelUsage reports nothing that ran
    vendor_says "{\"type\":\"result\",\"is_error\":true,\"modelUsage\":{}}
$refusal_line" 1
    : > "$d/model-nousage.log"
    FM_MODEL="bad-model-9000" PATH="$d/fakebin:$closed_path" \
      "$adapter" run "$d/prompt" "$d/tree" "$d/model-nousage.log" >/dev/null 2>"$d/model-nousage.err"
    assert_eq "64" "$?" "$name still refuses when modelUsage is empty"

    # T-197: both the unconfined preflight and confined round use memory.
    if [ "$name" = cursor-agent ]; then
      {
        printf '#!/usr/bin/env bash\n'
        # shellcheck disable=SC2016  # expanded by the stub on each invocation
        printf 'printf "%%s\\n" "${AGENT_CLI_CREDENTIAL_STORE-unset}" >> %q\n' "$d/credential-stores"
        printf 'if [ "$1" = --list-models ]; then exec %q %q; fi\n' \
          "$ROOT/tests/fixtures/auth-status/replay.sh" "$ROOT/tests/fixtures/auth-status/cursor-agent-signed-in-memory.txt"
        printf 'cat >/dev/null\nprintf "ran\\n"\n'
      } > "$d/fakebin/cursor-agent"
      chmod +x "$d/fakebin/cursor-agent"
      for caller_store in unset default; do
        : > "$d/credential-stores"
        : > "$d/memory.log"
        (
          unset AGENT_CLI_CREDENTIAL_STORE
          [ "$caller_store" = unset ] || export AGENT_CLI_CREDENTIAL_STORE="$caller_store"
          FM_MODEL=auto PATH="$d/fakebin:$closed_path" \
            "$adapter" run "$d/prompt" "$d/tree" "$d/memory.log"
        ) >/dev/null 2>"$d/memory.err"
        assert_eq 0 "$?" "cursor round succeeds with caller store $caller_store"
        assert_eq $'memory\nmemory' "$(cat "$d/credential-stores")" "cursor preflight and round override caller store $caller_store with memory"
      done
    fi

    # --- cursor-agent can list its own models, before the round (T-127) ---
    if [ "$name" = "cursor-agent" ]; then
      # a stub that answers --list-models differently from a real round, the
      # way the live CLI's two purposes differ
      printf '#!/usr/bin/env bash\nif [ "$1" = "--list-models" ]; then\n  printf "gpt-visor-1 - GPT Visor\\nclaude-opus-5-5 - Claude Opus\\n"\n  exit 0\nfi\nprintf "{\\"type\\":\\"result\\",\\"model\\":\\"claude-opus-5-5\\"}\\n"\nexit 0\n' \
        > "$d/fakebin/cursor-agent"
      chmod +x "$d/fakebin/cursor-agent"
      : > "$d/list-unknown.log"
      FM_MODEL="not-a-real-model" PATH="$d/fakebin:$closed_path" \
        "$adapter" run "$d/prompt" "$d/tree" "$d/list-unknown.log" >/dev/null 2>"$d/list-unknown.err"
      assert_eq "64" "$?" "cursor-agent refuses before the round when --list-models names no such model"
      assert_contains "$(cat "$d/list-unknown.err")" "not-a-real-model" "and names the model on stderr"
      : > "$d/list-known.log"
      FM_MODEL="claude-opus-5-5" PATH="$d/fakebin:$closed_path" \
        "$adapter" run "$d/prompt" "$d/tree" "$d/list-known.log" >/dev/null 2>"$d/list-known.err"
      assert_ne "64" "$?" "and lets a name the list does carry through"

      # a vendor with no session yet cannot list anything; the check must
      # stay silent, not refuse a round it could not actually ask about
      printf '#!/usr/bin/env bash\nif [ "$1" = "--list-models" ]; then\n  echo "Error: Authentication required." >&2\n  exit 1\nfi\nprintf "{\\"type\\":\\"result\\",\\"model\\":\\"claude-opus-5-5\\"}\\n"\nexit 0\n' \
        > "$d/fakebin/cursor-agent"
      chmod +x "$d/fakebin/cursor-agent"
      : > "$d/list-noauth.log"
      FM_MODEL="whatever-model" PATH="$d/fakebin:$closed_path" \
        "$adapter" run "$d/prompt" "$d/tree" "$d/list-noauth.log" >/dev/null 2>"$d/list-noauth.err"
      assert_ne "64" "$?" "and a list command that cannot run refuses nothing"
    fi

    # --- a run-mode review (T-066) ---------------------------------------
    # The reviewer runs commands in fm-review.sh's checkout. What keeps it
    # there is the CLI's own permission flags, so those are what is asserted:
    # an adapter either carries `# fm:review-run` and confines the round, or
    # refuses it before its CLI starts.
    mkdir -p "$d/checkout/.git"
    ck="$(cd "$d/checkout" && pwd -P)"
    tmpd="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
    printf '#!/usr/bin/env bash\ncat > /dev/null\npwd -P > "%s/cwd.run"\nprintf "%%s\\n" "$@" > "%s/argv.run"\nenv > "%s/env.run"\nprintf "ran\\n"\nexit 0\n' \
      "$d" "$d" "$d" > "$d/fakebin/$name"
    chmod +x "$d/fakebin/$name"
    rm -f "$d/cwd.run" "$d/argv.run" "$d/env.run"
    # The launcher's own state goes with it: fm_identity exports FM_ROOT at
    # the task's repository, and the checkout's scripts pick their tree from
    # FM_ROOT, so a `check` run in the checkout would gate another tree.
    FM_ROOT="$d/tree" FM_CODE_ROOT="$d/tree" FM_TASK=T-Z FM_ACTOR=reviewer-x FM_GH=gh \
      FM_PROJECT_ROOT="$d/tree" HERDR_PANE_ID=p1 GIT_DIR="$d/tree/.git" GH_TOKEN=secret GITHUB_TOKEN=secret \
      XDG_CACHE_HOME="$d/cache" \
      FM_RUN_REVIEW=1 FM_REVIEW_CHECKOUT="$d/checkout" PATH="$d/fakebin:$closed_path" \
      "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1; rrc=$?
    if [ "$name" = codex ]; then
      # T-163: a marker alone is insufficient. This fixture deliberately has
      # no managed invocation or pinned head; the feature suite supplies both.
      assert_eq "64" "$rrc" "codex refuses an unmanaged run-mode review"
      assert_fail "test -e '$d/cwd.run'" "codex never starts without launcher context"
    elif grep -q '^# fm:review-run' "$adapter"; then
      assert_eq "0" "$rrc" "$name runs a run-mode review"
      assert_eq "$ck" "$(cat "$d/cwd.run" 2>/dev/null)" "$name's engine works in the checkout, not its output directory"
      assert_ok "test -s '$d/env.run'" "$name's engine environment was recorded"
      # FM_IN_ROUND is not the launcher's: fm-sandbox.sh marks the round with
      # it, so an fm script started inside cannot take the operator's hatch
      assert_eq "" "$(grep -E '^(FM_|HERDR_|GIT_|GH_|GITHUB_TOKEN=)' "$d/env.run" 2>/dev/null | grep -vx 'FM_IN_ROUND=1' || true)" \
        "$name's run-mode engine sees none of the launcher's FM_, HERDR_, GIT_ or GitHub-token variables"
      assert_contains "$(cat "$d/env.run" 2>/dev/null)" "FM_IN_ROUND=1" "and knows it is inside a round"
      runargv="$(cat "$d/argv.run" 2>/dev/null)"
      list_after() { awk -v f="$1" '$0==f{on=1;next} /^--/{on=0} on' "$d/argv.run"; }
      # the round's temp directory is its own, not the shared TMPDIR that
      # holds every other round's files and run-mode checkouts (T-105)
      rtmp="$(sed -n 's/^TMPDIR=//p' "$d/env.run" 2>/dev/null)"
      # a cache location the caller handed in is not one the round may
      # write: the adapter points it into the round's own (T-117)
      assert_eq "$rtmp/cache/xdg" "$(sed -n 's/^XDG_CACHE_HOME=//p' "$d/env.run" 2>/dev/null)" \
        "$name points the round's caches into its own temp directory, not where the caller said"
      assert_matches "$rtmp" "^$tmpd/fm-round\\.[A-Za-z0-9]+\$" "$name's engine is given a temp directory of the round's own"
      assert_fail "test -e '$rtmp'" "which is removed when the round ends"
      case "$name" in
        claude)
          assert_contains "$runargv" "--permission-mode
dontAsk" "$name denies every tool call no rule allows"
          assert_lacks "$runargv" "acceptEdits" "$name does not accept edits wholesale in run mode"
          assert_lacks "$runargv" "bypassPermissions" "$name never bypasses permissions"
          assert_lacks "$runargv" "dangerously" "$name never skips permission checks"
          allowed="$(list_after --allowedTools)"; denied="$(list_after --disallowedTools)"
          assert_ne "" "$allowed" "$name names what the reviewer may do"
          stray="$(grep -E '^(Edit|Write|Read)' <<< "$allowed" \
            | grep -vE "^(Edit|Write|Read)\(/($ck|$rtmp)/\*\*\)$" || true)"
          assert_eq "" "$stray" "$name allows file writes only under the checkout and the temp directory"
          assert_contains "$allowed" "Edit(/$ck/**)" "$name lets the reviewer edit its own checkout"
          assert_lacks "$allowed" "WebFetch" "$name gives the reviewer no web access"
          # the shell is allowed because it runs inside the OS sandbox
          # around claude, not claude's own (T-105)
          assert_eq "Bash" "$(grep -xE 'Bash|Bash\(.*\)' <<< "$allowed" || true)" \
            "$name allows the shell, and no narrower shell rule"
          assert_ok "test -s '$pk/bwrap.args'" "$name's run-mode round ran inside the OS sandbox that confines it"
          # claude's own state and temp directories are the round's (T-117):
          # its config directory in the round's temp directory, never the
          # operator's ~/.claude, and its temp files there too
          assert_eq "$rtmp/claude-config" "$(sed -n 's/^CLAUDE_CONFIG_DIR=//p' "$d/env.run" 2>/dev/null)" \
            "$name's config directory is one of the round's own"
          assert_eq "$rtmp" "$(sed -n 's/^CLAUDE_CODE_TMPDIR=//p' "$d/env.run" 2>/dev/null)" \
            "and so is the directory it keeps its temp files in"
          for rule in "Bash(git push:*)" "Bash(git remote:*)" "Bash(gh pr comment:*)" \
                      "Bash(gh pr review:*)" "Bash(gh pr merge:*)" "Bash(gh api:*)" "Bash(curl:*)"; do
            assert_contains "
$denied
" "
$rule
" "$name denies $rule on the command line"
          done
          settings="$(awk 'on{print;exit} $0=="--settings"{on=1}' "$d/argv.run")"
          assert_eq "false" "$(jq -r '.sandbox.enabled' <<< "$settings" 2>/dev/null)" \
            "$name's own sandbox is off: its proxy would route around the one that names a refused host"
          assert_eq "true" "$(jq -r '.permissions.defaultMode == "dontAsk"
                     and any(.permissions.deny[]; . == "Bash(git push:*)")
                     and any(.permissions.deny[]; . == "Bash(gh pr comment:*)")' <<< "$settings" 2>/dev/null)" \
            "$name's settings deny push and comments as well"
          # What the adapter leaves loaded matters as much as what it adds:
          # rules merge across settings sources, and the checkout is the
          # branch under review, so its .claude/settings.json and .mcp.json -
          # hooks, allow rules, sandbox exclusions, extra directories - and
          # the operator's own ~/.claude would all join the round. Restricted
          # mode loads none of them; only --settings and managed policy apply.
          assert_contains "
$runargv
" "
--restricted
" "$name loads no user, project or local settings, so the branch cannot add hooks or rules"
          assert_contains "
$runargv
" "
--strict-mcp-config
" "$name loads no MCP server the branch or the operator's config declares"
          assert_contains "
$runargv
" "
--disable-slash-commands
" "$name loads no skill or command from the branch or the operator"
          # A closed list: BashOutput and KillShell, which is what a
          # background job would need checked on, are not among them, so a
          # review round has no way to read a job it backgrounded even if it
          # tried to start one (T-123). This one exact match is what keeps
          # either from being added back quietly beside Bash.
          assert_eq "Bash,Read,Edit,Write,Grep,Glob" "$(list_after --tools)" \
            "$name names the only tools the round has, offering it no way to check on a backgrounded job"
          assert_eq "$rtmp" "$(list_after --add-dir)" "$name's file tools reach only the checkout and the round's own temp directory"
          assert_lacks "$allowed" "(/$tmpd/**)" "and not the shared one"
          # the barriers push actually meets: the OS sandbox's network is a
          # namespace of the round's own, whose one way out is the proxy
          # that reaches only the declared registries (tests/sandbox.test.sh),
          # and no settings exclude a command from anything
          assert_contains "$(cat "$pk/bwrap.args" 2>/dev/null)" "--unshare-net" \
            "$name's round has no network of the host's, nor its unix sockets"
          assert_eq "null" "$(jq -c '.sandbox.excludedCommands' <<< "$settings" 2>/dev/null)" \
            "$name exempts no command from anything"
          never="$(jq -r --arg h "$phome" '.permissions.deny | map(select(. == "Read(/\($h)/.ssh/**)")) | length' <<< "$settings" 2>/dev/null)"
          assert_eq "1" "$never" "$name's settings deny reading ~/.ssh as well"
          # A never_read path that CONTAINS the round's own tree must not
          # become a blanket deny of everything under it: on the self
          # project, state is never_read and a worker's worktree or a
          # reviewer's checkout lives at state/worktrees/<task> - a
          # blanket "Read(/state/**)" would deny the round's own tree too,
          # since a deny beats the Read(/$work/**) allow rule above in
          # claude's own rule order. That overlap refused a live
          # reviewer's checkout under main's policy (T-123). Build the
          # same shape - state/worktrees/T-Z (the round's own tree),
          # a sibling worktree, state/runs and state/events.jsonl - and
          # check the generated deny rules carve around the round's own
          # tree instead of swallowing it.
          nr="$(safe_tmpdir)"
          mkdir -p "$nr/state/worktrees/T-Z" "$nr/state/worktrees/T-Y" \
            "$nr/state/runs/run1" "$nr/state/other-worktree"
          : > "$nr/state/events.jsonl"
          printf 'vendor: mock\n' > "$nr/carve.yaml"
          (
            export HOME="$pk/home"   # the suite's login home, as above
            # shellcheck source=bin/fm-config.sh
            . "$ROOT/bin/fm-config.sh"
            fm_policy worker "" "$nr/carve.yaml" \
              | jq --arg s "$nr/state" '.never_read += [$s]' > "$nr/carve.json"
          )
          printf '#!/usr/bin/env bash\ncat > /dev/null\nprintf "%%s\\n" "$@" > "%s/carve.argv"\nprintf "ran\\n"\nexit 0\n' \
            "$nr" > "$d/fakebin/$name"
          chmod +x "$d/fakebin/$name"
          FM_POLICY="$nr/carve.json" PATH="$d/fakebin:$closed_path" \
            "$adapter" run "$d/prompt" "$nr/state/worktrees/T-Z" "$d/log" >/dev/null 2>&1
          csettings="$(awk 'on{print;exit} $0=="--settings"{on=1}' "$nr/carve.argv" 2>/dev/null)"
          cwork="$(cd "$nr/state/worktrees/T-Z" && pwd -P)"
          swallowed="$(printf '%s' "$csettings" | jq -r --arg work "$cwork" '
            .permissions.deny[]
            | sub("^Read\\("; "") | sub("\\)$"; "") | sub("/\\*\\*$"; "") | sub("^/+"; "/")
            | . as $p
            | select($p == $work or ($work | startswith($p + "/")))
          ' 2>/dev/null)"
          assert_eq "" "$swallowed" \
            "$name's deny rules do not swallow the round's own tree when a never_read path is its ancestor"
          assert_contains "$csettings" "state/runs" \
            "but a sibling under the same never_read ancestor is still denied"
          assert_contains "$csettings" "state/events.jsonl" \
            "and a file directly under it"
          assert_contains "$csettings" "state/other-worktree" \
            "and a sibling directory beside the branch that leads to the round's tree"
          assert_contains "$csettings" "state/worktrees/T-Y" \
            "and a sibling worktree one level further down, on the branch itself"
          # "but never the round's own tree, at any level" is exactly what
          # $swallowed above already proves, on the deny list alone, with
          # an ancestor-prefix match at every depth (T-123 round 14). A
          # plain assert_lacks "$csettings" "state/worktrees/T-Z" here
          # (round 12's finding) greps the *whole* settings JSON, allow
          # rules included, which correctly name the round's own tree via
          # Read(/$work/**) - so it fails on the fix exactly as it would on
          # the bug it was meant to catch, and is dropped as a duplicate.
          rm -f "$d/cwd.run"
          FM_REVIEW_NETWORK='x.org","*' FM_RUN_REVIEW=1 FM_REVIEW_CHECKOUT="$d/checkout" \
            PATH="$d/fakebin:$closed_path" "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
          assert_eq "64" "$?" "$name refuses a network entry that is not a domain name"
          assert_fail "test -e '$d/cwd.run'" "and its CLI never starts"
          # a `*` is read as itself: expanded, it became the file names in
          # the adapter's working directory, which pass as domains
          mkdir -p "$d/globdir"; : > "$d/globdir/x.org"; rm -f "$d/cwd.run"
          ( cd "$d/globdir" && FM_REVIEW_NETWORK='*' FM_RUN_REVIEW=1 FM_REVIEW_CHECKOUT="$d/checkout" \
            PATH="$d/fakebin:$closed_path" "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1 )
          assert_eq "64" "$?" "$name refuses a network entry of '*' rather than globbing it"
          assert_fail "test -e '$d/cwd.run'" "and its CLI never starts"
          # an operator argument that touches permissions or what is loaded
          # would undo all of it
          for extra in "--dangerously-skip-permissions" "--setting-sources user,project" \
                       "--mcp-config x.json" "--plugin-dir p" "--agents {}"; do
            rm -f "$d/cwd.run"
            FM_ADAPTER_ARGS="$extra" FM_RUN_REVIEW=1 FM_REVIEW_CHECKOUT="$d/checkout" \
              PATH="$d/fakebin:$closed_path" "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
            assert_eq "64" "$?" "$name refuses a run-mode review whose extra arguments say $extra"
            assert_fail "test -e '$d/cwd.run'" "and its CLI never starts"
          done
          ;;
      esac
      # a checkout that is not one is refused, not reviewed from wherever
      rm -f "$d/cwd.run"
      FM_RUN_REVIEW=1 FM_REVIEW_CHECKOUT="$d/tree" PATH="$d/fakebin:$closed_path" \
        "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
      assert_eq "64" "$?" "$name refuses a run-mode checkout with no .git"
      assert_fail "test -e '$d/cwd.run'" "and its CLI never starts"
      # no GitHub access at all, enforced where the CLI starts, not only by
      # fm-review.sh: a caller that hands the adapter a GitHub host directly
      # is refused the same way
      for gh_host in github.com raw.githubusercontent.com ghcr.io x.github.io API.GitHub.com; do
        rm -f "$d/cwd.run"
        FM_REVIEW_NETWORK="registry.npmjs.org $gh_host" FM_RUN_REVIEW=1 FM_REVIEW_CHECKOUT="$d/checkout" \
          PATH="$d/fakebin:$closed_path" "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
        assert_eq "64" "$?" "$name refuses a run-mode network naming $gh_host"
        assert_fail "test -e '$d/cwd.run'" "and its CLI never starts ($gh_host)"
      done
    else
      assert_eq "64" "$rrc" "$name cannot confine a run-mode review, so it refuses one"
      assert_fail "test -e '$d/cwd.run'" "and its CLI never starts"
    fi

    vendor_says "wrote the thing" 0
    PATH="$d/fakebin:$closed_path" "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
    assert_eq "0" "$?" "$name still reports success when the CLI does the work"
    rm -f "$d/fakebin/$name"
  fi

  assert_eq "" "$(cat "$d/calls")" "$name ran no git and no gh"
  after="$(find "$d/outside" -type f -exec shasum {} + | shasum)"
  assert_eq "$before" "$after" "$name wrote nothing outside the worktree"
  assert_ok "test -f '$d/log'" "$name wrote to the log it was given"
  safe_rm_rf "$d"
done


# T-219: copied immutable snapshots and faithful Cursor data-path stub.
# Literal helper dependency lets gate 4 select this consuming suite.
python3 "$ROOT/tests/lib/cursor_round.py" "$ROOT" "$pk" "$closed_path" \
  "$ROOT/tests/lib/cursor_round_old/cursor-agent.sh" \
  "$ROOT/tests/lib/cursor_round_old/_lib.sh"
assert_eq 0 "$?" "Cursor private round data and frozen snapshot contract"

safe_rm_rf "$pk" "$closed_path"
finish
