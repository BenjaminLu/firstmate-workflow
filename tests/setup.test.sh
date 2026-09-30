#!/usr/bin/env bash
# fm setup (T-121): the first-run wizard asks only what it cannot find out,
# each with a default Enter accepts, and writes config.yaml.
set -uo pipefail
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

SETUP="$ROOT/bin/fm-setup.sh"
assert_ok "test -x '$SETUP'" "fm-setup.sh is executable"

d="$(safe_tmpdir)"
fakebin="$d/fakebin"; mkdir -p "$fakebin"
# the real python3, resolved before $PATH is ever restricted: fm_cfg_set,
# the one config.yaml writer, runs on it, and a fixed PATH of just /usr/bin:/bin may have none
# that runs, e.g. an unlicensed Xcode stub
REAL_PYTHON3="$(command -v python3)"
printf '#!/usr/bin/env bash\nexec %s "$@"\n' "$(printf '%q' "$REAL_PYTHON3")" > "$fakebin/python3"
chmod +x "$fakebin/python3"
# gh: signed in, and reports write access on any repo asked about
printf '#!/usr/bin/env bash\ncase "$1 $2" in\n  "auth status") exit 0 ;;\n  "repo view") echo WRITE ;;\nesac\n' \
  > "$fakebin/gh"
chmod +x "$fakebin/gh"
# a doctor stand-in, so this suite is testing the wizard's own writes, not
# the real fm-doctor.sh --sandbox it calls last (that is doctor.test.sh's)
mkdir -p "$d/bin"
cp "$ROOT/bin/fm-setup.sh" "$ROOT/bin/fm-config.sh" "$d/bin/"
# the adapters, whose `# fm:review-run` line says which reviewer can run a run-mode review
cp -R "$ROOT/bin/adapters" "$d/bin/"
printf '#!/usr/bin/env bash\necho "fm-doctor ran: $*" > "%s/doctor-ran"\nexit 0\n' "$d" > "$d/bin/fm-doctor.sh"
chmod +x "$d/bin/fm-doctor.sh"
SETUP="$d/bin/fm-setup.sh"

repo="$d/repo"; mkdir -p "$repo"
git_stub() {  # a git that answers just enough for the wizard's defaults
  printf '#!/usr/bin/env bash\ncase "$*" in\n' > "$fakebin/git"
  printf '  *"remote get-url origin"*) echo "%s" ;;\n' "${1:-}" >> "$fakebin/git"
  printf '  *"symbolic-ref --short refs/remotes/origin/HEAD"*) echo "%s" ;;\n' "${2:-}" >> "$fakebin/git"
  printf '  *) exit 1 ;;\nesac\n' >> "$fakebin/git"
  chmod +x "$fakebin/git"
}
git_stub "https://github.com/example-org/example-repo.git" "origin/main"

run_setup() { PATH="$fakebin:/usr/bin:/bin" "$SETUP" --repo "$repo" "$@"; }

field_in() { sed -n "s/^[[:space:]]*$2:[[:space:]]*//p" "$1" | head -1 | sed 's/[[:space:]]*#.*$//'; }

# --- every default, no answers file, closed stdin ---------------------------
rm -f "$repo/config.yaml"
run_setup </dev/null >/dev/null 2>&1
assert_ok "test -f '$repo/config.yaml'" "setup writes config.yaml"
assert_eq "claude" "$(field_in "$repo/config.yaml" vendor)" "with no vendor CLI installed, claude is still the recommended default"
# it writes only what it asked or found out (T-121): no model - there is no
# model question - no reviewer mode, and no board port or language, which
# moved to T-154 because nothing reads them yet
assert_lacks "$(cat "$repo/config.yaml")" "model:" "a fresh config.yaml gets no model"
assert_lacks "$(cat "$repo/config.yaml")" "mode:" "nor a reviewer mode"
assert_lacks "$(cat "$repo/config.yaml")" "board_port" "nor a board port"
assert_lacks "$(cat "$repo/config.yaml")" "language" "nor a language"
assert_ok "test -f '$d/doctor-ran'" "and it hands off to fm doctor --sandbox at the end"
assert_contains "$(cat "$d/doctor-ran")" "--sandbox" "asking for the sandbox check"
rm -f "$d/doctor-ran"

# --- recommends a different vendor for review when two are usable ----------
rm -f "$repo/config.yaml"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/claude"; chmod +x "$fakebin/claude"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/gemini"; chmod +x "$fakebin/gemini"
run_setup </dev/null >/dev/null 2>&1
worker="$(field_in "$repo/config.yaml" vendor)"
reviewer="$(sed -n '/^reviewer:/,/^[^ ]/p' "$repo/config.yaml" | sed -n 's/^[[:space:]]*vendor:[[:space:]]*//p' | head -1)"
assert_eq "claude" "$worker" "the first installed vendor is the worker default"
assert_ne "$worker" "$reviewer" "and a different installed vendor is recommended to review"

# usable means the round's login probes authenticated: a probe stand-in
# that confirms only codex puts codex first, ahead of claude
printf 'codex\n' > "$d/authenticated"
printf '#!/usr/bin/env bash\nif grep -qxF -- "$1" %q; then echo "status: authenticated"; else echo "status: indeterminate"; fi\n' \
  "$d/authenticated" > "$d/bin/fm-auth-probe.sh"
chmod +x "$d/bin/fm-auth-probe.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/codex"; chmod +x "$fakebin/codex"
rm -f "$repo/config.yaml"
run_setup </dev/null >/dev/null 2>&1
assert_eq "codex" "$(field_in "$repo/config.yaml" vendor)" "a vendor whose login probes authenticated is recommended first"
reviewer="$(sed -n '/^reviewer:/,/^[^ ]/p' "$repo/config.yaml" | sed -n 's/^[[:space:]]*vendor:[[:space:]]*//p' | head -1)"
assert_eq "claude" "$reviewer" "and a different vendor reviews"
rm -f "$fakebin/claude" "$fakebin/gemini" "$fakebin/codex" "$d/bin/fm-auth-probe.sh"

# --- an answers file drives it non-interactively, with specific choices ----
rm -f "$repo/config.yaml"
answers="$d/answers.txt"
{
  echo "worker_vendor: codex"
  echo "reviewer_vendor: gemini"
  echo "billing_codex: subscription"
  echo "billing_gemini: api-key"
  echo "repo_github: captain/flagship"
  echo "repo_base: trunk"
} > "$answers"
run_setup --answers "$answers" </dev/null >/dev/null 2>&1
assert_eq "codex" "$(field_in "$repo/config.yaml" vendor)" "the answers file names the worker vendor"
assert_contains "$(cat "$repo/config.yaml")" "gemini: api-key" "the chosen api-key billing is recorded per vendor"
assert_lacks "$(cat "$repo/config.yaml")" "codex: api-key" "a vendor left on subscription gets no billing entry"
assert_contains "$(cat "$repo/config.yaml")" "captain/flagship" "the chosen repository is written"
assert_contains "$(cat "$repo/config.yaml")" "base: trunk" "and the chosen base branch"

# --- for a key, it prints the keychain command and asks for no key itself ----
rm -f "$repo/config.yaml"
printf 'worker_vendor: cursor-agent\nreviewer_vendor: cursor-agent\n' > "$answers"
said="$(run_setup --answers "$answers" </dev/null 2>&1 >/dev/null)"
assert_contains "$said" "security add-generic-password -s firstmate-cursor-api-key" \
  "a cursor-agent crew is told the exact keychain command for its key"
assert_contains "$said" "billed to your Cursor account" "and what it bills, said plainly"
assert_lacks "$said" "API key [" "and is never asked for the key itself"

# --- it never asks for or stores a secret ------------------------------------
assert_lacks "$(cat "$repo/config.yaml")" "sk-" "no API key or token literal is ever written to config.yaml"
assert_lacks "$(cat "$repo/config.yaml")" "CURSOR_API_KEY" "nor a credential variable's value"

# --- patching an existing config.yaml leaves what it does not own untouched
existing="$d/existing-config.yaml"
{
  echo "vendor: claude"
  echo "model:  opus-5"
  echo "policy:"
  echo "  worker:"
  echo "    procs: 999"
  echo "concurrency: 7"
} > "$existing"
cp "$existing" "$repo/config.yaml"
{
  echo "worker_vendor: claude"
  echo "reviewer_vendor: claude"
  echo "billing_claude: subscription"
  echo "repo_github:"
} > "$answers"
run_setup --answers "$answers" </dev/null >/dev/null 2>&1
assert_contains "$(cat "$repo/config.yaml")" "procs: 999" "a policy block this wizard does not own survives a re-run"
assert_contains "$(cat "$repo/config.yaml")" "concurrency: 7" "so does an unrelated top-level key"

# --- a re-run keeps the reviewer's mode and every model as they were -------
# no origin to take a repository from, so nothing about projects is written
# and the file can be compared whole
git_stub "" ""
reviewer_field() { sed -n '/^reviewer:/,/^[^ ]/p' "$repo/config.yaml" | sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" | head -1 | sed 's/[[:space:]]*#.*$//'; }
{
  echo "vendor: claude"
  echo "model:  claude-opus-5-5"
  echo "reviewer:"
  echo "  vendor: claude"
  echo "  model:  claude-opus-5-5"
  echo "  mode:   run"
  echo "models:"
  echo "  claude: claude-opus-5-5"
  echo "  codex:  gpt-5-codex"
} > "$repo/config.yaml"
cp "$repo/config.yaml" "$d/before.yaml"
printf 'worker_vendor: claude\nreviewer_vendor: claude\nbilling_claude: subscription\nrepo_github:\n' > "$answers"
run_setup --answers "$answers" </dev/null >/dev/null 2>&1
assert_eq "$(cat "$d/before.yaml")" "$(cat "$repo/config.yaml")" \
  "a re-run with the same answers leaves reviewer.mode, model and models: exactly as they were"

# a reviewer whose adapter cannot confine a run-mode review would make every
# review exit 65 (bin/fm-review.sh), so a kept `run` becomes diff for it -
# and the models are still untouched
for rv in codex gemini cursor-agent; do
  cp "$d/before.yaml" "$repo/config.yaml"
  printf 'worker_vendor: claude\nreviewer_vendor: %s\nbilling_claude: subscription\nbilling_%s: subscription\nrepo_github:\n' \
    "$rv" "$rv" > "$answers"
  said="$(run_setup --answers "$answers" </dev/null 2>&1 >/dev/null)"
  assert_eq "$rv" "$(reviewer_field vendor)" "$rv is written as the reviewer"
  assert_eq "diff" "$(reviewer_field mode)" "and a kept run mode becomes diff, which fm-review.sh accepts for $rv"
  assert_contains "$said" "reviewer.mode is now diff" "and the wizard says why ($rv)"
  assert_contains "$(cat "$repo/config.yaml")" "codex:  gpt-5-codex" "models: is untouched ($rv)"
  assert_contains "$said" "reviewer model 'claude-opus-5-5' was chosen for claude" \
    "a reviewer model chosen for another vendor is said, not changed ($rv)"
  # the same rule fm-review.sh applies (bin/fm-review.sh: run needs the
  # adapter's `# fm:review-run`): diff, or no mode at all, is accepted
  mode="$(reviewer_field mode)"
  assert_ok "[ '${mode:-diff}' = diff ] || grep -q '^# fm:review-run' '$ROOT/bin/adapters/$rv.sh'" \
    "fm-review.sh would accept this reviewer's mode ($rv)"
done
# with no mode at all, none is written, whichever reviewer
printf 'vendor: claude\nreviewer:\n  vendor: claude\n' > "$repo/config.yaml"
printf 'worker_vendor: claude\nreviewer_vendor: codex\nbilling_claude: subscription\nbilling_codex: subscription\nrepo_github:\n' > "$answers"
run_setup --answers "$answers" </dev/null >/dev/null 2>&1
assert_eq "" "$(reviewer_field mode)" "an unset reviewer mode stays unset (diff, fm-review.sh's default)"
# and claude, whose adapter confines a run-mode review, keeps run
cp "$d/before.yaml" "$repo/config.yaml"
printf 'worker_vendor: codex\nreviewer_vendor: claude\nbilling_claude: subscription\nbilling_codex: subscription\nrepo_github:\n' > "$answers"
run_setup --answers "$answers" </dev/null >/dev/null 2>&1
assert_eq "run" "$(reviewer_field mode)" "a claude reviewer keeps run"

# --- usage -------------------------------------------------------------------
"$SETUP" --repo "$d/nowhere-at-all" </dev/null >/dev/null 2>&1
assert_ne "0" "$?" "a nonexistent --repo is refused"
"$SETUP" --answers "$d/no-such-file" --repo "$repo" </dev/null >/dev/null 2>&1
assert_ne "0" "$?" "a named answers file that is not there is refused"

rm -rf "$d"
finish
