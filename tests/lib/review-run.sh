# shellcheck shell=bash
run_fixture() {
  local d; d="$(fixture)"
  ( cd "$d/repo" && git checkout -q work &&
    printf 'vendor: mock\nproject:\n  check: make check-it\n' > config.yaml &&
    git commit -qam "declare a contract" && git checkout -q main ) >/dev/null 2>&1
  printf '%s' "$d"
}
# an engine that says it can be confined, and reports what it was handed
runner_adapter() {   # runner_adapter <repo>
  cat > "$1/bin/adapters/runner.sh" <<'M'
#!/usr/bin/env bash
# fm:review-run
[ "$1" = "run" ] || exit 64
cp "$2" "$FM_SEEN/prompt.md"
ck="${FM_REVIEW_CHECKOUT:-}"
{ printf 'mode=%s\n' "${FM_RUN_REVIEW:-}"
  printf 'checkout=%s\n' "$ck"
  printf 'head=%s\n' "$(git -C "$ck" rev-parse HEAD 2>/dev/null)"
  printf 'base=%s\n' "$(git -C "$ck" rev-parse fm/base 2>/dev/null)"
  printf 'remotes=%s\n' "$(git -C "$ck" remote 2>/dev/null | tr '\n' ' ')"
  printf 'a=%s\n' "$(cat "$ck/src/a" 2>/dev/null)"
  printf 'network=%s\n' "${FM_REVIEW_NETWORK:-}"
  printf 'xdg=%s\nbun=%s\npw=%s\nnpm=%s\n' "${XDG_CACHE_HOME:-}" "${BUN_INSTALL_CACHE_DIR:-}" \
    "${PLAYWRIGHT_BROWSERS_PATH:-}" "${npm_config_cache:-}"
} > "$FM_SEEN/seen"
[ "${FM_RUNNER_SILENT:-}" = 1 ] && { printf 'no verdict\n' > "$3/v.txt"; exit 0; }
printf 'Read: supplied CI evidence\n%s\n' "${FM_VERDICT:-APPROVE:T-Z}" > "$3/v.txt"
exit 0
M
  chmod +x "$1/bin/adapters/runner.sh"
}
# an engine that cannot be confined: it must never be handed a run-mode round
plain_adapter() {   # plain_adapter <repo> <name>
  cat > "$1/bin/adapters/$2.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
: > "$FM_SEEN/plain-ran"
printf 'APPROVE:T-Z\n' > "$3/v.txt"
exit 0
M
  chmod +x "$1/bin/adapters/$2.sh"
}
seen_of() { sed -n "s/^$1=//p" "$2/seen" 2>/dev/null; }

