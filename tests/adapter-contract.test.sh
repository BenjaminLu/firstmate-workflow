#!/usr/bin/env bash
# One contract, every adapter. This is what keeps the system from quietly
# growing a dependency on whichever vendor happened to be configured.
set -uo pipefail
# A live managed worker exports FM_RUN_DIR / FM_ENTRY_* / FM_WORKER_TASK_LOCK_FD
# and Herdr pane ids into this shell. Suites must not inherit them or freeze,
# identity, locks and pushes bind to the outer run instead of the fixture.
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
# The legacy contract exercises direct CLIs; managed tests supply fake Herdr.
export HERDR_ENV=0 FM_TRANSPORT=direct
unset FM_RUN_DIR FM_ROLE FM_TASK FM_ACTOR FM_CODE_ROOT FM_CONTEXT_READY FM_ATTEMPT_DIR FM_FINAL_PATH FM_CLI_EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

# a PATH where git and gh record every call instead of doing anything
make_sandbox() {
  local d="$1"
  mkdir -p "$d/fakebin"
  for c in git gh; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/calls"\nexit 0\n' "$c" "$d" > "$d/fakebin/$c"
    chmod +x "$d/fakebin/$c"
  done
  : > "$d/calls"
}

# Every round runs under the policy fm owns (T-105): each adapter starts its
# CLI behind bin/fm-sandbox.sh and refuses a round it cannot confine. No
# real sandbox runs in this suite - a runner cannot be relied on to have
# one - so FM_SANDBOX_TOOL names a stand-in that records what it was handed
# and runs the command, on the platform FM_SANDBOX_OS says. The sandbox
# itself is tests/sandbox.test.sh's.
pk="$(mktemp -d)"; pk="$(cd "$pk" && pwd -P)"
(
  # shellcheck source=bin/fm-config.sh
  . "$ROOT/bin/fm-config.sh"
  printf 'vendor: mock\n' > "$pk/none.yaml"
  fm_policy worker "" "$pk/none.yaml" > "$pk/none.json"
  printf 'vendor: mock\npolicy:\n  network: registry.npmjs.org cdn.playwright.dev\n' > "$pk/net.yaml"
  fm_policy reviewer "" "$pk/net.yaml" > "$pk/net.json"
)
assert_eq "[]" "$(jq -c .network "$pk/none.json" 2>/dev/null)" "the suite's policy declares no registry"
assert_eq '["registry.npmjs.org","cdn.playwright.dev"]' "$(jq -c .network "$pk/net.json" 2>/dev/null)" \
  "and its other one two"
cat > "$pk/sandbox-exec" <<S
#!/usr/bin/env bash
[ "\$1" = -f ] || exit 99
cp "\$2" "$pk/profile.sb"
shift 2
exec "\$@"
S
cat > "$pk/bwrap" <<S
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$pk/bwrap.args"
while [ \$# -gt 0 ] && [ "\$1" != -- ]; do shift; done
shift
exec "\$@"
S
chmod +x "$pk/sandbox-exec" "$pk/bwrap"
export FM_POLICY="$pk/none.json"

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

  d="$(mktemp -d)"; make_sandbox "$d"
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
    PATH="$d/fakebin:/usr/bin:/bin" "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
    assert_eq "2" "$?" "$name exits 2 when its CLI is missing"
  fi

  # a vendor that prints an auth error and exits 0 is unavailable, not done.
  # Every vendor can do this, so every adapter is asked - except mock, which
  # has no CLI to lie to it. Its own promise is checked just below instead.
  if [ "$name" != "mock" ]; then
    vendor_says() {  # <stdout> <exit code>
      printf '#!/usr/bin/env bash\nprintf "%%s\\n" %s\nexit %s\n' "$(printf '%q' "$1")" "$2" \
        > "$d/fakebin/$name"
      chmod +x "$d/fakebin/$name"
    }
    for line in "Error: Authentication required. Please run 'agent login' first" \
                "Error: you are not logged in" \
                "Error: quota exceeded for this organisation" \
                "fetch failed: ENOTFOUND api.example.com" \
                "Authentication required." \
                "401 Unauthorized"; do
      vendor_says "$line" 0
      PATH="$d/fakebin:/usr/bin:/bin" "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
      assert_eq "2" "$?" "$name reports unavailable when the CLI says: ${line%% *}..."
    done
    vendor_says "" 0
    PATH="$d/fakebin:/usr/bin:/bin" "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
    assert_eq "1" "$?" "$name does not call a silent run a success"
    # the prompt has to actually reach the CLI, AND the invocation has to be
    # one the real CLI would accept. A fake that unconditionally reads stdin
    # cannot exhibit the gemini bug - real gemini's -p takes the prompt as
    # its value and ignores stdin - so the argv is asserted as well, against
    # the invocation each vendor documents.
    # stdin and argv are recorded apart, so each adapter can be held to the
    # half its CLI actually documents
    printf '#!/usr/bin/env bash\ncat >> "%s/stdin" 2>/dev/null\nprintf "%%s" "$*" >> "%s/argv"\nprintf "ran\\n"\nexit 0\n' \
      "$d" "$d" > "$d/fakebin/$name"
    chmod +x "$d/fakebin/$name"
    : > "$d/stdin"; : > "$d/argv"
    PATH="$d/fakebin:/usr/bin:/bin" "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
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
      gemini) assert_eq "--approval-mode yolo --extensions none --allowed-mcp-server-names fm-none" "$argv" \
                "$name uses the documented headless form, with the policy's flags"
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
      FM_RUN_REVIEW=1 FM_REVIEW_CHECKOUT="$d/checkout" PATH="$d/fakebin:/usr/bin:/bin" \
      "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1; rrc=$?
    if grep -q '^# fm:review-run' "$adapter"; then
      assert_eq "0" "$rrc" "$name runs a run-mode review"
      assert_eq "$ck" "$(cat "$d/cwd.run" 2>/dev/null)" "$name's engine works in the checkout, not its output directory"
      assert_ok "test -s '$d/env.run'" "$name's engine environment was recorded"
      assert_eq "" "$(grep -E '^(FM_|HERDR_|GIT_|GH_|GITHUB_TOKEN=)' "$d/env.run" 2>/dev/null || true)" \
        "$name's run-mode engine sees none of the launcher's FM_, HERDR_, GIT_ or GitHub-token variables"
      assert_contains "$(cat "$d/env.run" 2>/dev/null)" "XDG_CACHE_HOME=$d/cache" \
        "$name keeps the round's cache redirection"
      runargv="$(cat "$d/argv.run" 2>/dev/null)"
      list_after() { awk -v f="$1" '$0==f{on=1;next} /^--/{on=0} on' "$d/argv.run"; }
      # the round's temp directory is its own, not the shared TMPDIR that
      # holds every other round's files and run-mode checkouts (T-105)
      rtmp="$(sed -n 's/^TMPDIR=//p' "$d/env.run" 2>/dev/null)"
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
          assert_eq "Bash,Read,Edit,Write,Grep,Glob" "$(list_after --tools)" \
            "$name names the only tools the round has"
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
          never="$(jq -r --arg h "$(cd "$HOME" && pwd -P)" '.permissions.deny | map(select(. == "Read(/\($h)/.ssh/**)")) | length' <<< "$settings" 2>/dev/null)"
          assert_eq "1" "$never" "$name's settings deny reading ~/.ssh as well"
          rm -f "$d/cwd.run"
          FM_REVIEW_NETWORK='x.org","*' FM_RUN_REVIEW=1 FM_REVIEW_CHECKOUT="$d/checkout" \
            PATH="$d/fakebin:/usr/bin:/bin" "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
          assert_eq "64" "$?" "$name refuses a network entry that is not a domain name"
          assert_fail "test -e '$d/cwd.run'" "and its CLI never starts"
          # a `*` is read as itself: expanded, it became the file names in
          # the adapter's working directory, which pass as domains
          mkdir -p "$d/globdir"; : > "$d/globdir/x.org"; rm -f "$d/cwd.run"
          ( cd "$d/globdir" && FM_REVIEW_NETWORK='*' FM_RUN_REVIEW=1 FM_REVIEW_CHECKOUT="$d/checkout" \
            PATH="$d/fakebin:/usr/bin:/bin" "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1 )
          assert_eq "64" "$?" "$name refuses a network entry of '*' rather than globbing it"
          assert_fail "test -e '$d/cwd.run'" "and its CLI never starts"
          # an operator argument that touches permissions or what is loaded
          # would undo all of it
          for extra in "--dangerously-skip-permissions" "--setting-sources user,project" \
                       "--mcp-config x.json" "--plugin-dir p" "--agents {}"; do
            rm -f "$d/cwd.run"
            FM_ADAPTER_ARGS="$extra" FM_RUN_REVIEW=1 FM_REVIEW_CHECKOUT="$d/checkout" \
              PATH="$d/fakebin:/usr/bin:/bin" "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
            assert_eq "64" "$?" "$name refuses a run-mode review whose extra arguments say $extra"
            assert_fail "test -e '$d/cwd.run'" "and its CLI never starts"
          done
          ;;
      esac
      # a checkout that is not one is refused, not reviewed from wherever
      rm -f "$d/cwd.run"
      FM_RUN_REVIEW=1 FM_REVIEW_CHECKOUT="$d/tree" PATH="$d/fakebin:/usr/bin:/bin" \
        "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
      assert_eq "64" "$?" "$name refuses a run-mode checkout with no .git"
      assert_fail "test -e '$d/cwd.run'" "and its CLI never starts"
      # no GitHub access at all, enforced where the CLI starts, not only by
      # fm-review.sh: a caller that hands the adapter a GitHub host directly
      # is refused the same way
      for gh_host in github.com raw.githubusercontent.com ghcr.io x.github.io API.GitHub.com; do
        rm -f "$d/cwd.run"
        FM_REVIEW_NETWORK="registry.npmjs.org $gh_host" FM_RUN_REVIEW=1 FM_REVIEW_CHECKOUT="$d/checkout" \
          PATH="$d/fakebin:/usr/bin:/bin" "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
        assert_eq "64" "$?" "$name refuses a run-mode network naming $gh_host"
        assert_fail "test -e '$d/cwd.run'" "and its CLI never starts ($gh_host)"
      done
    else
      assert_eq "64" "$rrc" "$name cannot confine a run-mode review, so it refuses one"
      assert_fail "test -e '$d/cwd.run'" "and its CLI never starts"
    fi

    vendor_says "wrote the thing" 0
    PATH="$d/fakebin:/usr/bin:/bin" "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
    assert_eq "0" "$?" "$name still reports success when the CLI does the work"
    rm -f "$d/fakebin/$name"
  fi

  assert_eq "" "$(cat "$d/calls")" "$name ran no git and no gh"
  after="$(find "$d/outside" -type f -exec shasum {} + | shasum)"
  assert_eq "$before" "$after" "$name wrote nothing outside the worktree"
  assert_ok "test -f '$d/log'" "$name wrote to the log it was given"
  rm -rf "$d"
done

# --- one policy, every vendor (T-105) ----------------------------------------
# Each vendor's flags enforce what they can of the policy and the OS sandbox
# the rest; a dimension neither covers refuses the round with 2 - the
# fallback chain's "try the next one" - before the CLI starts, so no round
# runs less confined than its policy.
pv="$(mktemp -d)"; pv="$(cd "$pv" && pwd -P)"; mkdir -p "$pv/fakebin" "$pv/tree"
echo "do it" > "$pv/prompt"
confined() {   # confined <os> <tool> <policy> <vendor> -> its exit code; argv in $pv/argv
  printf '#!/usr/bin/env bash\ncat > /dev/null\nprintf "%%s\\n" "$@" > "%s/argv"\nprintf "ran\\n"\nexit 0\n' \
    "$pv" > "$pv/fakebin/$4"
  chmod +x "$pv/fakebin/$4"
  rm -f "$pv/argv" "$pk/profile.sb" "$pk/bwrap.args"
  FM_SANDBOX_OS="$1" FM_SANDBOX_TOOL="$2" FM_POLICY="$3" PATH="$pv/fakebin:/usr/bin:/bin" \
    "$ROOT/bin/adapters/$4.sh" run "$pv/prompt" "$pv/tree" "$pv/log" >/dev/null 2>"$pv/err"
  echo $?
}
settings_of() { awk 'on{print;exit} $0=="--settings"{on=1}' "$pv/argv"; }
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
done
# a seatbelt cannot start inside sandbox-exec, so under it the vendors' own
# sandboxes are off and the outer one confines their commands
confined darwin "$pk/sandbox-exec" "$pk/none.json" claude >/dev/null
assert_eq "false" "$(settings_of | jq -r '.sandbox.enabled' 2>/dev/null)" "on macOS claude's own sandbox is off"
assert_eq "Bash" "$(awk '$0=="--allowedTools"{on=1;next} /^--/{on=0} on' "$pv/argv" | grep -x Bash)" \
  "and its shell runs under the outer one"
assert_ne "" "$(awk '$0=="--disallowedTools"{on=1;next} /^--/{on=0} on' "$pv/argv" | grep -xF 'Bash(git push:*)')" \
  "while its deny rules still refuse a push"
confined darwin "$pk/sandbox-exec" "$pk/none.json" codex >/dev/null
assert_eq "danger-full-access" "$(awk 'on{print;exit} $0=="--sandbox"{on=1}' "$pv/argv")" "codex's own sandbox is off"
confined darwin "$pk/sandbox-exec" "$pk/none.json" cursor-agent >/dev/null
assert_eq "disabled" "$(awk 'on{print;exit} $0=="--sandbox"{on=1}' "$pv/argv")" "and cursor-agent's"
assert_ne "" "$(grep -x -- --trust "$pv/argv")" "cursor-agent still trusts only the worktree it is handed"
assert_eq "" "$(grep -x -- -f "$pv/argv")" "and never forces every command"
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
assert_eq '(allow network-outbound (remote ip "localhost:' \
  "$(grep -o '(allow network-outbound (remote ip "localhost:' "$pk/profile.sb" 2>/dev/null)" \
  "and its round reaches the network only through that proxy"

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
  FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$pk/sandbox-exec" FM_POLICY="$pk/none.json" PATH="$pv/fakebin:/usr/bin:/bin" \
    "$ROOT/bin/adapters/$v.sh" run "$pv/prompt" "$pv/tree" "$pv/log" >/dev/null 2>&1
  assert_eq "1" "$?" "while $v's own exit 70, inside a sandbox that started, is a failed attempt"
  assert_ok "test -e '$pv/argv'" "($v's CLI did run)"
done
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

# An adapter reached without FM_POLICY - by hand, or by a caller that does
# not know about one - takes the engine's own policy for its role, never none
unset FM_POLICY
for v in claude codex cursor-agent gemini; do
  printf '#!/usr/bin/env bash\ncat > /dev/null\nprintf "%%s\\n" "$@" > "%s/argv"\nprintf "ran\\n"\nexit 0\n' \
    "$pv" > "$pv/fakebin/$v"; chmod +x "$pv/fakebin/$v"
  rm -f "$pv/argv" "$pk/profile.sb"
  FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$pk/sandbox-exec" PATH="$pv/fakebin:/usr/bin:/bin" \
    "$ROOT/bin/adapters/$v.sh" run "$pv/prompt" "$pv/tree" "$pv/log" >/dev/null 2>"$pv/err"
  assert_eq "0" "$?" "$v with no FM_POLICY still runs, under the engine's own policy"
  assert_contains "$(cat "$pk/profile.sb" 2>/dev/null)" "(subpath \"$(cd "$HOME" && pwd -P)/.ssh\")" \
    "and that policy's profile keeps ~/.ssh out of reach"
done
# and a policy file that is named but missing refuses the round
FM_POLICY="$pv/no-such-policy.json" FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$pk/sandbox-exec" \
  PATH="$pv/fakebin:/usr/bin:/bin" "$ROOT/bin/adapters/claude.sh" run "$pv/prompt" "$pv/tree" "$pv/log" \
  >/dev/null 2>"$pv/err"
assert_eq "65" "$?" "a named policy that is not there refuses the round"
assert_contains "$(cat "$pv/err")" "no policy at" "and says so"
rm -rf "$pv" "$pk"
unset FM_POLICY FM_SANDBOX_OS FM_SANDBOX_TOOL

# --- the verdict itself, on the transcripts that actually caused trouble ---
# shellcheck source=bin/adapters/_lib.sh
. "$ROOT/bin/adapters/_lib.sh"

# the one rule on which hosts a run-mode sandbox may reach, shared by
# fm-review.sh and every adapter: plain domain names, never GitHub's
for gh_host in github.com GITHUB.COM api.github.com github.io x.github.io github.dev \
               raw.githubusercontent.com githubusercontent.com githubassets.com githubapp.com ghcr.io; do
  assert_contains "$(fm_review_host_refusal "$gh_host")" "GitHub host" "$gh_host is refused as a GitHub host"
done
for ok_host in registry.npmjs.org notgithub.com github.com.example.org cdn.playwright.dev; do
  assert_eq "" "$(fm_review_host_refusal "$ok_host")" "$ok_host is not a GitHub host"
done
for bad_host in '*' '*.com' '.github.com' 'github.com.' 'a..b' 'x.org","*' ''; do
  assert_contains "$(fm_review_host_refusal "$bad_host")" "not a plain domain name" "'$bad_host' is not a plain domain name"
done
assert_eq "ghcr.io, which is a GitHub host; a run-mode reviewer may not reach GitHub" \
  "$(fm_review_network_refusal "registry.npmjs.org ghcr.io raw.githubusercontent.com")" \
  "a network list names the first host it may not reach"
assert_eq "" "$(fm_review_network_refusal "registry.npmjs.org cdn.playwright.dev")" "and nothing for one it may"
assert_eq "" "$(fm_review_network_refusal "")" "and nothing for an empty one"

v="$(mktemp -d)"
verdict() { # <log contents> <rc> -> the verdict
  printf '%s' "$1" > "$v/log"
  fm_adapter_verdict "$2" "$v/log" 0; printf '%s' "$?"
}

# cursor-agent, verbatim: an auth error on exit 0
assert_eq "2" "$(verdict "Error: Authentication required. Please run 'agent login' first, or set CURSOR_API_KEY environment variable." 0)" \
  "an auth error on exit 0 is the vendor being unavailable"

# gemini, verbatim: a long stack trace, but the error is the first thing said
gem="Loaded cached credentials.
Error authenticating: IneligibleTierError: This client is no longer supported
    at throwIneligibleOrProjectIdError (file:///x/setup.js:192:15)
    at _doSetupUser (file:///x/setup.js:182:9)
    at process.processTicksAndRejections (node:internal/process/task_queues:95:5) {
  ineligibleTiers: [ { reasonCode: 'UNSUPPORTED_CLIENT' } ]
}"
# a real CLI prints a banner first, so the failure is not on line one
gem="Checking for updates...
Update available: 1.2.3
$gem"
assert_eq "2" "$(verdict "$gem" 0)" "a long stack trace is still an outage when the error leads"

# --- and what actually settles it: the caller's evidence -----------------
# shellcheck source=bin/fm-config.sh
. "$ROOT/bin/fm-config.sh"
e="$(mktemp -d)"; mkdir -p "$e/ad" "$e/out"; echo p > "$e/prompt"
# an adapter whose CLI wrote a review that quotes the words an outage uses
cat > "$e/ad/one.sh" <<'A'
#!/usr/bin/env bash
printf 'The authentication signature is matched anywhere in the output, so a\nreview discussing authentication reads as an outage.\nREJECT:T-Z\n' >> "$4"
exit 2   # what the wording test makes of it, which is what is under test
A
cat > "$e/ad/two.sh" <<'A'
#!/usr/bin/env bash
printf 'the second vendor also ran\n' >> "$4"
exit 0
A
chmod +x "$e/ad"/*.sh
signed() { grep -q 'REJECT:T-Z' "$e/log" 2>/dev/null; }
: > "$e/log"
fm_run_chain "$e/ad" "one two" "$e/prompt" "$e/out" "$e/log" signed
assert_eq "0" "$?" "work beats a signature: a signed review is not an outage"
assert_eq "one" "$FM_VENDOR_MISREAD" "and the chain says which vendor was misread"
assert_fail "grep -q 'second vendor' '$e/log'" "and stops rather than running the next one"

# with no evidence to show, the same output falls through to the next vendor
: > "$e/log"
nothing() { false; }
fm_run_chain "$e/ad" "one two" "$e/prompt" "$e/out" "$e/log" nothing
assert_ok "grep -q 'second vendor' '$e/log'" "with nothing to show, the chain moves on"

# A typo at the head of the chain is a configuration error, and it has to be
# found BEFORE anything runs: the caller's exit 65 would otherwise throw away
# work a later vendor had already done.
: > "$e/log"
fm_run_chain "$e/ad" "nosuchvendor two" "$e/prompt" "$e/out" "$e/log" nothing
assert_eq "65" "$?" "an unknown head comes straight back as a configuration error"
assert_eq "nosuchvendor" "$FM_VENDOR_UNKNOWN" "and it is named"
assert_eq "" "$(cat "$e/log")" "and no vendor was run, even a working fallback"

# a fallback entry with no adapter is a different thing: just skip it
: > "$e/log"
fm_run_chain "$e/ad" "two nosuchvendor" "$e/prompt" "$e/out" "$e/log" nothing
assert_eq "" "$FM_VENDOR_UNKNOWN" "a fallback entry with no adapter is just skipped"
assert_ok "grep -q 'second vendor' '$e/log'" "and the working head still ran"

# each attempt gets its own output directory when the caller asks, so a
# vendor that dies half way through cannot sign on the next one's behalf
: > "$e/log"
cat > "$e/ad/half.sh" <<'A'
#!/usr/bin/env bash
printf 'REJECT:T-Z
' > "$3/partial.md"
exit 2
A
chmod +x "$e/ad/half.sh"
saw_marker() { grep -qr 'REJECT:T-Z' "$FM_RUN_OUTDIR" 2>/dev/null; }
fm_run_chain "$e/ad" "half two" "$e/prompt" "$e/out" "$e/log" saw_marker per-vendor
assert_eq "half" "$FM_VENDOR_MISREAD" "the vendor that wrote it is the one credited"
: > "$e/log"; rm -rf "$e/out"; mkdir -p "$e/out"
cat > "$e/ad/half.sh" <<'A'
#!/usr/bin/env bash
printf 'REJECT:T-Z
' > "$3/partial.md"
exit 2
A
chmod +x "$e/ad/half.sh"
never() { false; }
fm_run_chain "$e/ad" "half two" "$e/prompt" "$e/out" "$e/log" never per-vendor
assert_ok "test -f '$e/out/half/partial.md'" "a dead vendor's bytes stay in its own directory"
assert_fail "test -f '$e/out/two/partial.md'" "and are not found in the next vendor's"

# a run-mode round's chain holds only adapters that can confine it (T-066)
printf '#!/usr/bin/env bash\n# fm:review-run\nexit 0\n' > "$e/ad/boxed.sh"; chmod +x "$e/ad/boxed.sh"
assert_eq "boxed
nosuchvendor" "$(fm_review_run_chain "$e/ad" "boxed two nosuchvendor half")" \
  "a fallback that cannot confine the round is dropped; a name with no adapter is left for the chain to report"
fm_review_run_chain "$e/ad" "two boxed" >/dev/null
assert_eq "1" "$?" "a head that cannot confine the round is refused, not replaced"
# the chain is split, never globbed: a `*` in the head's place became the
# file names beside it, and `boxed` among them was taken for the reviewer
mkdir -p "$e/globdir"; : > "$e/globdir/boxed"
assert_eq "*" "$(cd "$e/globdir" && fm_review_run_chain "$e/ad" "*")" \
  "a chain entry of '*' is read as itself, not as the file names around it"
rm -rf "$e"
claude_marker="$(grep -c '^# fm:review-run' "$ROOT/bin/adapters/claude.sh")"
assert_eq "1" "$claude_marker" "claude, the configured reviewer, can confine a run-mode review"
# Every alternative in the list has to be shaped like a failure. A bare noun
# is what a healthy run prints on its way up - gemini says "Loaded cached
# credentials." before it does anything - and a `credentials?` alternative
# turned every successful gemini run into a reported outage.
for healthy in "Loaded cached credentials." \
               "Authenticated as benjamin. Ready." \
               "Added rate limiting: the handler now returns 429 with Retry-After." \
               "Implemented the login flow; credentials are read from the keyring."; do
  assert_eq "0" "$(verdict "$healthy" 0)" "a healthy run that says \"${healthy%% *}...\" is done"
done
# and every alternative in the list is read against a real failure that
# carries it. The completeness check below fails if one is added without a
# transcript, because an alternative nobody has seen match is one nobody
# knows the shape of - which is how `credentials?` got in.
broken_lines="Error: Authentication required. Please run 'agent login' first
Error authenticating: IneligibleTierError
authentication failed for this account
authentication error: token rejected
authenticate failed for this key
you are not authenticated
Error: 401 Unauthorized
403 Forbidden
403 Forbidden: this key may not use that model
429 Too Many Requests
status 429 returned by the gateway
status 401 from the provider
status 403 from the provider
Too many requests, slow down
you are not logged in
please use gcloud auth login first
please run claude login first
login required before running non-interactively
invalid api key
missing api key
missing credentials
no api key was supplied
expired api key
api key not configured for this project
api key not set in the environment
api key not found
api key not valid. Please pass a valid API key.
invalid credentials
expired credentials
credentials could not be read
Error: quota exceeded for this organisation
you are out of quota until tomorrow
quota exhausted for this key
rate limit exceeded, retry after 30s
rate-limited by the upstream provider
rate limited by the upstream provider
rate limit reached
network error: could not reach the api
network error while streaming the response
network unreachable
network failure reported by the transport
fetch failed
getaddrinfo ENOTFOUND api.example.com
connect ECONNREFUSED 127.0.0.1:443
connect ETIMEDOUT 10.0.0.1:443
getaddrinfo EAI_AGAIN api.example.com"
while IFS= read -r broken; do
  [ -n "$broken" ] || continue
  assert_eq "2" "$(verdict "$broken" 0)" "an outage reading \"$(printf '%.38s' "$broken")...\""
done <<< "$broken_lines"

# completeness: pull the alternatives out of the library and require each one
# to be matched by at least one of those transcripts
sig="$(sed -n "s/^_FM_SIG='\(.*\)'$/\1/p" "$ROOT/bin/adapters/_lib.sh")"
assert_ne "" "$sig" "the signature list was found"
unread=''
saved_ifs="$IFS"; IFS='|'
for alt in $sig; do
  printf '%s\n' "$broken_lines" | grep -qiE "$alt" || unread="$unread [$alt]"
done
IFS="$saved_ifs"
assert_eq "" "$unread" "every signature has a transcript that carries it"

# and none of them fires on a healthy one
for healthy in "Loaded cached credentials." "Authenticated as benjamin. Ready." \
               "Added rate limiting: the handler now returns 429 with Retry-After." \
               "Implemented the login flow; credentials are read from the keyring." \
               "Reviewed the network error handling and the retry budget."; do
  assert_eq "0" "$(verdict "$healthy" 0)" "and none of them fires on \"$(printf '%.30s' "$healthy")...\""
done
# A big transcript with its signature at the front. The hazard this guards
# is `producer | grep -q`: grep exits on the match, the producer takes
# SIGPIPE, and under pipefail the pipeline reports failure even though the
# match happened. Measured here: with bash's builtin printf as the producer
# it does not reproduce even at 5 MB, but with an external one it does -
# `yes MATCH | grep -qi match` returns 141 - and fm-review hit it for real
# with `cat`. So the fix is the shape, not a size, and the shape is
# asserted by the lint in bin/ci.sh. This is the behavioural regression
# test that goes with it.
huge="Error: Authentication required$(printf '%*s' 200000 '' | tr ' ' 'n')"
assert_eq "2" "$(verdict "$huge" 0)" \
  "a signature at the front of a very large transcript still counts"

assert_eq "1" "$(verdict "" 0)" "exit 0 with nothing said is unfit"
# the shape a review actually has. The wording test condemns it, and that is
# expected now: what rescues it is the caller's evidence, asserted below.
assert_eq "2" "$(verdict "REJECT:T-025
1. The rate limit path is unauthorized to retry, and the credentials check
   is never exercised." 0)" "even a real review trips the wording test"
assert_eq "1" "$(verdict "it did not manage it" 1)" "a plain failure stays a plain failure"
assert_eq "2" "$(verdict "it did not manage it" 69)" "an unavailable exit code still counts"

# a failed run's signatures only name the reason, so both lists are searched
# over the whole output. The old code searched one list and called an
# outage on line eight a model that could not do the job.
assert_eq "2" "$(verdict "working on it
line two
line three
line four
line five
line six
line seven
Error: ENOTFOUND api.example.com" 1)" "a failure that names a network outage is an outage"
assert_eq "2" "$(verdict "$(printf 'padding\n%.0s' $(seq 1 400))
the request was unauthorized" 1)" "and so is one that names it far past the opening"
assert_eq "1" "$(verdict "$(printf 'padding\n%.0s' $(seq 1 400))
I could not work out how to do this" 1)" "a failure with no such reason stays a plain failure"
assert_eq "2" "$(verdict "$(printf 'padding\n%.0s' $(seq 1 400))
getaddrinfo ENOTFOUND api.example.com" 1)" \
  "and both signature lists are searched, not just the one a model might write"

# there is no window at all now: a banner of any length cannot bury it, on
# either exit code. The 2000-byte opening was the last constant fitted to a
# fixture, and this is what replaces it.
assert_eq "2" "$(verdict "$(printf 'notice\n%.0s' $(seq 1 30))
Error: quota exceeded for this organisation" 0)" "a banner does not bury the outage"
assert_eq "2" "$(verdict "$(printf 'chatter\n%.0s' $(seq 1 600))
Error: quota exceeded for this organisation" 0)" \
  "and neither does four kilobytes of it, on exit 0"

# the fallback chain shares one log: a verdict reads only its own bytes
printf '%s' "Error: Authentication required" > "$v/log"
off="$(fm_adapter_mark "$v/log")"
printf '%s' "the second vendor reviewed it fine" >> "$v/log"
fm_adapter_verdict 0 "$v/log" "$off"
assert_eq "0" "$?" "the previous vendor's auth error does not condemn the next"
rm -rf "$v"

assert_ok "test -f '$ROOT/bin/adapters/_contract.md'" "the contract is written down"
assert_contains "$(cat "$ROOT/bin/adapters/_contract.md")" "must not: run git or gh" \
  "the contract states the git prohibition"
finish
