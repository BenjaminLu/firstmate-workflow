#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/sandbox.sh
. "$ROOT/tests/lib/sandbox.sh"
# --- a real sandbox, when this host can run one (T-128) ---------------------
# Everything above uses a stand-in for sandbox-exec/bwrap, because a runner
# cannot be relied on to have a real one and a macOS profile cannot be
# applied inside another (design 13.1). Here, only when this host both has
# the real tool AND can actually apply a profile (nested inside another
# sandbox, as a worker round itself may be, sandbox_apply is refused, and
# skipping is the honest answer, not a false pass): the literal behaviour
# the acceptance criteria ask for, with the real kernel enforcing the write
# roots rather than a script asserting what a profile says.
real_sandbox_ok() {
  case "$(uname -s)" in
    Darwin) command -v sandbox-exec >/dev/null 2>&1 \
      && sandbox-exec -p '(version 1)(allow default)' true >/dev/null 2>&1 ;;
    Linux) command -v bwrap >/dev/null 2>&1 \
      && bwrap --ro-bind / / --unshare-all true >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}
if real_sandbox_ok; then
  rt="$(safe_tmpdir)"
  # a real git worktree, exactly what fm-worker.sh gives a worker round
  # (git worktree add): its .git is a file pointing elsewhere, which is the
  # shape own_git() protects (T-128 review round 4) - a plain `git init`
  # would make .git a directory instead, and would not exercise the same
  # code path a real worker round runs under.
  git init -q "$rt/hub" >/dev/null 2>&1
  echo committed > "$rt/hub/f.txt"
  git -C "$rt/hub" add f.txt
  git -C "$rt/hub" -c user.email=a@b.c -c user.name=t commit -q -m f >/dev/null 2>&1
  git -C "$rt/hub" worktree add -q "$rt/tree" -b wt-branch >/dev/null 2>&1
  printf 'vendor: mock\n' > "$rt/config.yaml"
  rpol="$(fm_policy worker "" "$rt/config.yaml")"
  printf '%s' "$rpol" > "$rt/policy.json"
  rout="$("$SB" run --policy="$rt/policy.json" --root="$rt/tree" --tmp="$rt/tmp" \
    -- bash -c 'rm -rf "$1"; echo "rm rc=$?"' _ "$rt/tree" 2>&1)"
  assert_contains "$rout" "rm rc=" "and the in-sandbox rm -rf actually ran (real sandbox)"
  assert_ok "test -e '$rt/tree/.git'" "real sandbox: rm -rf \"\$tree\" from inside leaves .git behind"
  assert_ok "git -C '$rt/tree' status" "and git -C \$tree status still works"
  # a normal environment (T-128): bare mktemp, mktemp -t, ~/.cache and
  # python's own tempfile module all succeed under the round's own
  # directory, no special-cased path needed. The two bare calls are
  # threaded through mt/fd/ft (T-123 round 7's hygiene lint bans the
  # literal shape anywhere in a suite, same as the mkcmd.sh fixture above).
  mt=mktemp; fd=-d; ft=-t
  envout="$("$SB" run --policy="$rt/policy.json" --root="$rt/tree" --tmp="$rt/tmp" \
    -- bash -c "
      set -e
      d1=\"\$($mt $fd)\" && [ -w \"\$d1\" ] || exit 1
      d2=\"\$($mt $ft fmtest)\" && [ -w \"\$d2\" ] || exit 1
      mkdir -p \"\$HOME/.cache\" && echo x > \"\$HOME/.cache/probe\" || exit 1
      python3 -c 'import tempfile; open(tempfile.mkdtemp()+\"/x\",\"w\").close()' || exit 1
      case \"\$d1\" in \"\$TMPDIR\"/*) ;; *) exit 1 ;; esac
      echo ALL_OK
    " 2>&1)"
  assert_contains "$envout" "ALL_OK" "real sandbox: mktemp -d, mktemp -t, \$HOME/.cache and python's tempfile all succeed under the round's own directory"
  # the .git deny must not reach a sibling that merely starts with the same
  # four characters, or a workflow file under .github/ (T-128 review round 1)
  gout="$("$SB" run --policy="$rt/policy.json" --root="$rt/tree" --tmp="$rt/tmp" \
    -- bash -c '
      set -e
      echo x >> .gitignore
      mkdir -p .github/workflows && echo x > .github/workflows/ci.yml
      echo ALL_OK
    ' 2>&1)"
  assert_contains "$gout" "ALL_OK" "real sandbox: writing .gitignore and .github/workflows/ci.yml succeeds"
  assert_ok "test -s '$rt/tree/.gitignore'" "and .gitignore actually took the write"
  assert_ok "test -s '$rt/tree/.github/workflows/ci.yml'" "and .github/workflows/ci.yml actually took the write"
  # a clone (run-mode review checkout): .git is a whole directory, and
  # ordinary git commands write inside it - git checkout writes .git/index -
  # so it must stay writable rather than denied as a subpath (T-128 review
  # round 4). Clone $rt/hub (already carrying the "f" commit above), stage an
  # unrelated change, then check the committed file back out from its own
  # ref: that is exactly the write the review's fail-first protocol step, and
  # any ordinary reviewer git command, depends on.
  git clone -q "$rt/hub" "$rt/clone" >/dev/null 2>&1
  printf 'vendor: mock\n' > "$rt/cconfig.yaml"
  ccpol="$(fm_policy worker "" "$rt/cconfig.yaml")"
  printf '%s' "$ccpol" > "$rt/cpolicy.json"
  ckout="$("$SB" run --policy="$rt/cpolicy.json" --root="$rt/clone" --tmp="$rt/ctmp" \
    -- bash -c '
      set -e
      echo mine > f.txt
      git add f.txt
      git checkout HEAD -- f.txt
      cat f.txt
      echo ALL_OK
    ' 2>&1)"
  assert_contains "$ckout" "ALL_OK" "real sandbox: git add and git checkout -- <path> succeed in a clone checkout"
  assert_contains "$ckout" "committed" "and the checkout actually restored the committed content"
  # T-147: a login shell's here-document and PATH, the kernel enforcing the
  # write roots: zsh's here-document temp file is refused outside them, and
  # macOS's path_helper runs for real in /etc/zprofile and /etc/profile
  lpath="$("$SB" run --policy="$rt/policy.json" --root="$rt/tree" --tmp="$rt/tmp" \
    -- bash -c 'printf "%s|" "$PATH"; bash -lc "printf %s \"\$PATH\""' 2>/dev/null)"
  assert_eq "${lpath%%|*}" "${lpath#*|}" "real sandbox: a login bash ends with the round's own PATH"
  if command -v zsh >/dev/null 2>&1; then
    zout="$("$SB" run --policy="$rt/policy.json" --root="$rt/tree" --tmp="$rt/tmp" \
      -- zsh -lc 'cat <<EOF
heredoc ok
EOF
printf "%s|" "$PATH"' 2>&1)"
    assert_contains "$zout" "heredoc ok" "real sandbox: a here-document works in a login zsh"
    assert_contains "$zout" "$(printf '%s' "${lpath%%|*}")|" "and a login zsh ends with the round's own PATH"
  fi
  safe_rm_rf "$rt"
else
  echo "    (skipped: no real sandbox nestable on this host - real-sandbox behaviour untested here)"
fi

safe_rm_rf "$t"
PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
