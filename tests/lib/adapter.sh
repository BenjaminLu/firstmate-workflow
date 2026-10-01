# shellcheck shell=bash
# Caller/consumer globals are checked when linting the feature suites.
# shellcheck disable=SC2034
# One contract, every adapter. This is what keeps the system from quietly
# growing a dependency on whichever vendor happened to be configured.
set -uo pipefail
# A live managed worker exports FM_RUN_DIR / FM_ENTRY_* / FM_WORKER_TASK_LOCK_FD
# and Herdr pane ids into this shell. Suites must not inherit them or freeze,
# identity, locks and pushes bind to the outer run instead of the fixture.
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
# This suite exercises the direct CLI transport; managed cases supply fake Herdr.
export HERDR_ENV=0 FM_TRANSPORT=direct
unset FM_RUN_DIR FM_ROLE FM_TASK FM_ACTOR FM_CODE_ROOT FM_CONTEXT_READY FM_ATTEMPT_DIR FM_FINAL_PATH FM_CLI_EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=tests/lib/path.sh
. "$ROOT/tests/lib/path.sh"
closed_path="$(safe_tmpdir)"
fixture_path "$closed_path" 'claude codex gemini cursor-agent agent gh security secret-tool' || exit 1

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
pk="$(safe_tmpdir)"
# codex's and gemini's round sign in with a copy of their subscription login
# file, and every variable they read as a login instead is one the round
# sheds unless config.yaml's billing: chose it (T-121). So the suite's
# policies are resolved against a home of its own holding those two files,
# never the runner's, and never an ambient key the round would drop.
mkdir -p "$pk/home/.codex" "$pk/home/.gemini"
printf '{"OPENAI_API_KEY":null,"tokens":{"id_token":"id-suite","access_token":"at-suite","refresh_token":"rt-suite","account_id":"acct"}}' \
  > "$pk/home/.codex/auth.json"
printf '{"access_token":"at-suite","refresh_token":"rt-suite","expiry_date":%s}' \
  "$(( ($(date +%s) + 86400) * 1000 ))" > "$pk/home/.gemini/oauth_creds.json"
# the home every policy below resolves "~" against, so what a profile or a
# settings file must keep out of reach is under it, not the runner's
phome="$(cd "$pk/home" && pwd -P)"
(
  export HOME="$pk/home"
  # shellcheck source=bin/fm-config.sh
  . "$ROOT/bin/fm-config.sh"
  printf 'vendor: mock\n' > "$pk/none.yaml"
  fm_policy worker "" "$pk/none.yaml" > "$pk/none.json"
  printf 'vendor: mock\npolicy:\n  network: registry.npmjs.org cdn.playwright.dev\n' > "$pk/net.yaml"
  fm_policy reviewer "" "$pk/net.yaml" > "$pk/net.json"
)
cat > "$pk/sandbox-exec" <<S
#!/usr/bin/env bash
[ "\$1" = -f ] || exit 99
# It applies no profile, so it answers fm-sandbox's loopback check before the
# round the way a profile that holds does: run behind it, the check would
# bind and connect on the machine running the suite, the board's port
# included (T-153). tests/sandbox.test.sh's loopback cases test the check.
case " \$* " in *" fm-loopback-check "*) echo checked; exit 0 ;; esac
printf '%s\n' "\$2" > "$pk/profile.path"
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
# Every vendor's round needs a login fm can hand in (T-117), and this
# runner has none: claude's crew token and cursor-agent's key are the
# variables fm hands in, so these say one is already in the environment,
# and codex and gemini read the suite home's login files above; nothing of
# the runner's keychain or home is read. What fm reads when none is set
# is tests/sandbox.test.sh's and the login-file cases below, and the case
# with no login at all is below too.
unset CODEX_API_KEY OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY
export CLAUDE_CODE_OAUTH_TOKEN=fm-suite-token CURSOR_API_KEY=fm-suite-key

