#!/usr/bin/env bash
# One contract, every adapter. This is what keeps the system from quietly
# growing a dependency on whichever vendor happened to be configured.
set -uo pipefail
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

for adapter in "$ROOT"/bin/adapters/*.sh; do
  name="$(basename "$adapter" .sh)"
  case "$name" in _*) continue ;; esac   # shared library, not an adapter
  printf '  %s\n' "$name"

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
    # scripted verdicts are a contract too
    FM_MOCK_EXIT=0 FM_MOCK_BODY="written" PATH="$d/fakebin:$PATH" \
      "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
    assert_ok "test -s '$d/log'" "mock never reports done without saying anything"
    FM_MOCK_EXIT=2 PATH="$d/fakebin:$PATH" "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
    assert_fail "test -f '$d/tree/unwanted.txt'" "an unavailable mock changes nothing in the worktree"
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
                "You are not logged in." \
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
    printf '#!/usr/bin/env bash\ncat >> "%s/got" 2>/dev/null\nprintf " ARGV:%%s" "$*" >> "%s/got"\nprintf "ran\\n"\nexit 0\n' \
      "$d" "$d" > "$d/fakebin/$name"
    chmod +x "$d/fakebin/$name"
    : > "$d/got"
    PATH="$d/fakebin:/usr/bin:/bin" "$adapter" run "$d/prompt" "$d/tree" "$d/log" >/dev/null 2>&1
    assert_contains "$(cat "$d/got")" "do the thing" "$name delivers the prompt to its CLI"
    argv="$(sed -n 's/.*ARGV://p' "$d/got")"
    case "$name" in
      # -p here means "print mode", a bare flag: stdin carries the prompt
      claude|cursor-agent) assert_contains " $argv " " -p " "$name asks for print mode" ;;
      # gemini's -p takes the prompt as its VALUE. A bare -p leaves the flag
      # dangling and the prompt is never delivered: "Not enough arguments
      # following: p". Piped stdin is what makes it headless.
      gemini) assert_fail "printf '%s' ' $argv ' | grep -q ' -p '" "$name passes no dangling -p" ;;
      # codex reads stdin only when the last argument is the marker "-"
      codex) assert_eq "-" "${argv##* }" "$name keeps the stdin marker last" ;;
    esac

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

# --- the verdict itself, on the transcripts that actually caused trouble ---
# shellcheck source=bin/adapters/_lib.sh
. "$ROOT/bin/adapters/_lib.sh"
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
gem="$gem$(printf '%*s' 2600 '' | tr ' ' 'x')"
assert_eq "2" "$(verdict "$gem" 0)" "a long stack trace is still an outage when the error leads"

# and the one that broke: a real review that talks about authentication
rev="The verdict: three problems, one of them load-bearing.

1. The authentication signature in _lib.sh is matched anywhere in the output,
   so a review discussing authentication is read as an outage. That is not a
   hypothetical - it is what happened to this review.
2. fm_vendor_chain dedupes only the head against the fallback list.
3. The prompt is never delivered when FM_ADAPTER_ARGS is empty."
rev="$rev$(printf '%*s' 2200 '' | tr ' ' 'y')"
assert_eq "0" "$(verdict "$rev" 0)" "a long review that discusses authentication is work, not an outage"
# the task itself can be about logins and rate limits. Completed work must
# not be thrown away because the model wrote the words down.
for job in "Added rate limiting: the handler now returns 429 with Retry-After." \
           "Implemented the login flow; credentials are read from the keyring." \
           "The authentication middleware rejects an unauthorized token."; do
  assert_eq "0" "$(verdict "$job" 0)" "a finished job that mentions ${job%% *} is done, not an outage"
done
assert_eq "2" "$(verdict "Error: rate limit reached, try again later" 0)" \
  "but the same words led by an error on exit 0 are an outage"
big="$(printf '%*s' 4600 '' | tr ' ' 'z')"
assert_eq "0" "$(verdict "Error handling for authentication is wrong.
$big" 0)" "and a long answer is never an outage, however it opens"
assert_eq "1" "$(verdict "" 0)" "exit 0 with nothing said is unfit"
assert_eq "1" "$(verdict "it did not manage it" 1)" "a plain failure stays a plain failure"
assert_eq "2" "$(verdict "it did not manage it" 69)" "an unavailable exit code still counts"

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
