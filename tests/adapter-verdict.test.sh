#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/adapter.sh
. "$ROOT/tests/lib/adapter.sh"
unset FM_POLICY FM_SANDBOX_OS FM_SANDBOX_TOOL CLAUDE_CODE_OAUTH_TOKEN CURSOR_API_KEY CODEX_API_KEY GEMINI_API_KEY

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

v="$(safe_tmpdir)"
verdict() { # <log contents> <rc> -> the verdict
  printf '%s' "$1" > "$v/log"
  fm_adapter_verdict "$2" "$v/log" 0; printf '%s' "$?"
}

# cursor-agent, verbatim: an auth error on exit 0
assert_eq "2" "$(verdict "Error: Authentication required. Please run 'agent login' first, or set CURSOR_API_KEY environment variable." 0)" \
  "an auth error on exit 0 is the vendor being unavailable"

# Gemini error wording in a constructed stack trace with placeholder paths;
# this is not a verbatim transcript. The error is the first thing said.
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
e="$(safe_tmpdir)"; mkdir -p "$e/ad" "$e/out"; echo p > "$e/prompt"
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

# Unavailable attempts are skipped, but a real failing verdict stands.
cat > "$e/ad/failed.sh" <<'A'
#!/usr/bin/env bash
exit 1
A
chmod +x "$e/ad/failed.sh"
fm_run_chain "$e/ad" "one failed" "$e/prompt" "$e/out" "$e/log" nothing
assert_eq "1 failed one" "$? $FM_VENDOR_USED $FM_VENDOR_SKIPPED" "unavailable vendors are skipped, the next verdict stands"
fm_run_chain "$e/ad" "one" "$e/prompt" "$e/out" "$e/log" nothing
assert_eq "2" "$?" "every vendor unavailable is itself unavailable"

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
safe_rm_rf "$e"
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
getaddrinfo EAI_AGAIN api.example.com
You’ve hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Oct 10th, 2026 7:58 AM."
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
  # a here-string, not a pipe: under pipefail grep -q leaving on the match
  # let printf die of SIGPIPE, and a signature that matched was reported
  # unread - a different one each CI run (T-103)
  grep -qiE "$alt" <<<"$broken_lines" || unread="$unread [$alt]"
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
safe_rm_rf "$v"

assert_ok "test -f '$ROOT/bin/adapters/_contract.md'" "the contract is written down"
assert_contains "$(cat "$ROOT/bin/adapters/_contract.md")" "must not: run git or gh" \
  "the contract states the git prohibition"

safe_rm_rf "$pk" "$closed_path"
finish
