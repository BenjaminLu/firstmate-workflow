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
    case "$name" in
      # -p here means "print mode", a bare flag: stdin carries the prompt
      claude|cursor-agent) assert_contains " $argv " " -p " "$name asks for print mode" ;;
      # gemini's -p takes the prompt as its VALUE. The documented headless
      # form is a piped stdin and no -p at all: a bare -p leaves the flag
      # dangling and the prompt is never delivered.
      gemini) assert_eq "" "$argv" "$name uses the documented headless form"
              assert_lacks " $argv " " -p " "$name passes no dangling -p" ;;
      # codex reads stdin only when the last argument is the marker "-"
      # codex reads a prompt only as `codex exec ... -`: the subcommand, the
      # flag that lets it run outside a repository, and the stdin marker
      # last. Asserting only the marker let the rest drift.
      codex) assert_eq "exec" "${argv%% *}" "$name asks for the non-interactive subcommand"
             assert_contains " $argv " " --skip-git-repo-check " "$name does not require a repository"
             assert_eq "-" "${argv##* }" "$name keeps the stdin marker last" ;;
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
rm -rf "$e"
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
