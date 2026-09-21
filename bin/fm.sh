#!/usr/bin/env bash
# fm:skills-writer  # the one script allowed to write under skills/, and only
#                   # ever under skills/vendor/. `fm.sh lint` enforces both
#                   # halves of that sentence against bin/ and board/.
#
# Self-update, and the import of somebody else's skills.
#
#   fm.sh self-update --skill worker --why "..."   propose a skill change
#   fm.sh sync-skills <dir> [--name NAME]          import external skills
#   fm.sh lint                                     the two skill lints
#
# The system defines its own behaviour in skills/, which makes editing a
# skill the one thing it must not be able to do quietly. So self-update
# writes no skill: it writes a task and a decision card, and the change
# travels the branch, the pull request and the seven gates that every other
# change travels. There is deliberately no flag that applies one.
#
# `fm.sh lint` runs in CI today through tests/selfupdate.test.sh, which
# asserts it against this repository and which bin/ci.sh runs like any other
# suite. Calling it from bin/ci.sh directly would read better and needs that
# file, which is outside this task's scope.
set -uo pipefail
# Nothing below may read standard input. A dispatched child inherits it, and
# a child that reads it blocks the caller waiting for a human who is not
# there. One guarantee, in one place; bin/ci.sh fails if a script that
# dispatches is missing it.
exec < /dev/null

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${FM_ROOT:-$(cd "$HERE/.." && pwd)}"

die() { printf 'fm: %s\n' "$1" >&2; exit "${2:-64}"; }
abs() { ( cd "$1" 2>/dev/null && pwd -P ) || return 1; }
# an imported tree is read-only on purpose, so removing one needs the bit back
rmtree() { [ -e "$1" ] || return 0; chmod -R u+w "$1" 2>/dev/null; rm -rf "$1"; }

usage() {
  cat <<'EOF'
usage: fm.sh <command> [options]

  self-update --skill <name> --why <text> [--repo DIR]
        Propose a change to skills/<name>. Writes a task spec under
        state/skill-updates/ and puts a decision card in front of the
        captain. It never edits the skill: that happens on a branch,
        through a pull request, under the same seven gates.

  sync-skills <source-dir> [--name NAME] [--repo DIR]
        Import external skills into skills/vendor/, read-only. One way:
        the source is never written to, and a local edit to an imported
        copy is discarded by the next import.

  lint [--repo DIR]
        Two checks. Nothing under bin/ or board/ writes a skill, and
        nothing under skills/ is written in one vendor's syntax.
EOF
}

# =========================================================================
# the lints
# =========================================================================

# One table, read by `fm.sh lint` and again by sync-skills before it lets an
# import land, so skills/ can never come to hold something the lint rejects.
# Fields are separated by ^^ - a pattern may start with ^ but never with ^^.
#
# V4 in the design: skills are plain Markdown and the adapter translates. A
# skill that names one vendor's markup is a skill that only runs on that
# vendor, which is the whole thing the adapter contract exists to prevent.
vendor_patterns() {
  cat <<'EOF'
<function_calls>|<invoke name=|</antml^^a Claude tool-call block
<tool_call>|<tool_use>|```tool_code^^another vendor's tool-call block
(^|[^A-Za-z])(CLAUDE|GEMINI|AGENTS)\.md|\.cursorrules|\.cursor/rules^^a vendor's own rule file
(^|[^A-Za-z-])(claude|codex|gemini)[[:space:]]+(-p|exec|--print)|cursor-agent[[:space:]]^^a vendor CLI invocation
@anthropic-ai/|@openai/|cursor://^^a vendor package or url scheme
^(allowed-tools|argument-hint|model):^^a vendor-only frontmatter key
EOF
}

# lint_markdown <dir> <display-prefix> ; prints one line per violation
lint_markdown() {
  local dir="$1" prefix="$2" f rel spec pat label hit
  [ -d "$dir" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="$prefix${f#"$dir"/}"
    while IFS= read -r spec; do
      [ -n "$spec" ] || continue
      pat="${spec%%^^*}"; label="${spec##*^^}"
      while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        printf '%s:%s: %s\n' "$rel" "${hit%%:*}" "$label"
      done <<< "$(grep -nE "$pat" "$f" 2>/dev/null || true)"
    done <<< "$(vendor_patterns)"
  done <<< "$(find "$dir" -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)"
}

# Lines that write to a path under skills/.
#
# What it catches: a literal skills/ path on a line that writes - a redirect,
# a copy, a remove, an in-place edit, a write from the board. What it does
# not catch: a destination assembled out of variables. That is the same limit
# bin/ci.sh's single-writer lint has, and the same answer holds: one script
# declares itself the writer, and no other script has a reason to go near it.
WRITE_RE='>>?[[:space:]]*"?[^"|]*skills/'
WRITE_RE="$WRITE_RE"'|(^|[[:space:]])(cp|mv|rm|rmdir|mkdir|touch|tee|install|ln|dd|truncate|patch)([[:space:]]+-[^[:space:]]+)*[[:space:]]+[^|]*skills/'
WRITE_RE="$WRITE_RE"'|sed[[:space:]]+-i[^|]*skills/'
WRITE_RE="$WRITE_RE"'|(writeFile|writeFileSync|appendFile|Bun\.write)[^|]*skills/'

# lint_writers <repo> ; prints one line per violation, and the writer count
# on file descriptor 3 is not worth the trouble - the caller recounts.
lint_writers() {
  local repo="$1" f rel hits hit text declares
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$repo"/}"
    hits="$(grep -nE "$WRITE_RE" "$f" 2>/dev/null | grep -v '^[0-9]*:[[:space:]]*#' || true)"
    [ -n "$hits" ] || continue
    declares=0
    grep -q '^# fm:skills-writer' "$f" && declares=1
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      text="${hit#*:}"
      if [ "$declares" -eq 0 ]; then
        printf '%s:%s: writes under skills/ and is not the declared writer\n' "$rel" "${hit%%:*}"
      else
        # the marker says "I am the one writer", not "I may write anywhere":
        # strike the one allowed destination out and see what is left
        case "${text//skills\/vendor/}" in
          *skills/*) printf '%s:%s: the declared writer may only write skills/vendor/\n' "$rel" "${hit%%:*}" ;;
        esac
      fi
    done <<< "$hits"
  done <<< "$(find "$repo/bin" "$repo/board" -type f \
      \( -name '*.sh' -o -name '*.ts' -o -name '*.js' -o -name '*.mjs' -o -name '*.html' \) \
      2>/dev/null | grep -v node_modules | LC_ALL=C sort)"
}

cmd_lint() {
  local repo="$REPO" bad w v n
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="${2-}"; shift 2 ;;
      *) die "lint: unknown argument $1" ;;
    esac
  done
  repo="$(abs "$repo")" || die "no repo at $repo"
  bad=0

  w="$(lint_writers "$repo")"
  if [ -n "$w" ]; then
    printf 'fm lint: something other than a pull request can edit a skill:\n'
    printf '%s\n' "$w" | sed 's/^/  x /'
    bad=1
  else
    n="$(grep -lE '^# fm:skills-writer' "$repo"/bin/*.sh 2>/dev/null | wc -l | tr -d ' ')"
    printf '  + nothing writes a skill outside skills/vendor/ (%s declared writer)\n' "$n"
  fi

  v="$(lint_markdown "$repo/skills" "skills/")"
  if [ -n "$v" ]; then
    printf 'fm lint: a skill is written in one vendor'"'"'s syntax:\n'
    printf '%s\n' "$v" | sed 's/^/  x /'
    bad=1
  else
    n="$(find "$repo/skills" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
    printf '  + %s skill documents are portable markdown\n' "$n"
  fi
  return "$bad"
}

# =========================================================================
# sync-skills: one way, into skills/vendor/, never back
# =========================================================================
cmd_sync() {
  local repo="$REPO" src='' name='' vendor vreal dest stage n s imported=0 nskipped=0 skipped=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="${2-}"; shift 2 ;;
      --name) name="${2-}"; shift 2 ;;
      -*) die "sync-skills: unknown argument $1" ;;
      *) [ -z "$src" ] || die "sync-skills: one source directory at a time"; src="$1"; shift ;;
    esac
  done
  [ -n "$src" ] || { usage >&2; die "sync-skills: a source directory is required"; }
  repo="$(abs "$repo")" || die "no repo at $repo"
  src="$(abs "$src")" || die "sync-skills: no directory at $src"
  # importing from yourself is not an import, and it would let a role skill
  # be copied over an imported one and back again
  case "$src" in "$repo"|"$repo"/*) die "sync-skills: $src is inside this repository" ;; esac

  vendor="$repo/skills/vendor"
  mkdir -p "$vendor" || die "sync-skills: cannot create $vendor" 70
  vreal="$(abs "$vendor")" || die "sync-skills: cannot resolve $vendor" 70
  # imports are not this repository's code. They are read-only copies of
  # somebody else's, they never travel a pull request, and section 13 of the
  # design says a public repository carries no local paths - the manifest
  # below records one.
  [ -f "$vendor/.gitignore" ] || printf '%s\n' \
    '# Imported by `bin/fm.sh sync-skills`. Read-only copies of external' \
    '# skills: they are not part of this repository and never travel a' \
    '# pull request. Delete the directory and import again.' \
    '*' '!.gitignore' > "$vendor/.gitignore"

  # a source directory is either one skill or a directory of them
  if [ -f "$src/SKILL.md" ]; then
    set -- "$src"
  else
    local list; list="$(find "$src" -mindepth 2 -maxdepth 2 -name SKILL.md 2>/dev/null | LC_ALL=C sort)"
    set --
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      set -- "$@" "$(dirname "$s")"
    done <<< "$list"
  fi
  [ "$#" -gt 0 ] && [ -n "${1:-}" ] || die "sync-skills: no SKILL.md under $src" 1
  [ "$#" -eq 1 ] || [ -z "$name" ] || die "sync-skills: --name takes one skill, found $#"

  for s in "$@"; do
    n="${name:-$(basename "$s")}"
    case "$n" in
      ''|.*|*/*|*[!A-Za-z0-9._-]*) die "sync-skills: $n is not a usable skill name" ;;
    esac
    dest="$vendor/$n"
    # boring about the destination, the way fm-cleanup.sh is boring about
    # what it deletes: the check is on the resolved parent, not the string
    [ "$(abs "$(dirname "$dest")")" = "$vreal" ] || die "sync-skills: $dest is not inside $vreal"

    stage="$vendor/.staging.$$"
    rmtree "$stage"; mkdir -p "$stage/$n" || die "sync-skills: cannot stage $n" 70
    cp -R "$s/." "$stage/$n/" 2>/dev/null || { rmtree "$stage"; die "sync-skills: cannot read $s" 1; }

    # lint before it lands, never after: an import that fails the lint would
    # leave skills/ red with a file nobody here may edit. Half a skill is
    # worse than none, so an offending file skips the whole skill.
    local bad; bad="$(lint_markdown "$stage/$n" "$n/")"
    if [ -n "$bad" ]; then
      printf 'fm sync-skills: skipping %s, it is written for one vendor:\n' "$n"
      printf '%s\n' "$bad" | sed 's/^/  x /'
      skipped="$skipped $n"; nskipped=$((nskipped + 1))
      rmtree "$stage"
      continue
    fi

    rmtree "$dest"
    mv "$stage/$n" "$dest" || { rmtree "$stage"; die "sync-skills: cannot place $n" 70; }
    rmtree "$stage"
    # read-only, because the copy is not ours to edit: an edit here is lost
    # at the next import, and making that visible beats making it surprising
    find "$dest" -type f -exec chmod a-w {} + 2>/dev/null
    manifest_put "$vendor" "$n" "$s" "$dest"
    imported=$((imported + 1))
    printf 'fm sync-skills: imported %s\n' "$n"
  done

  printf 'fm sync-skills: %s imported, %s skipped%s (from %s)\n' \
    "$imported" "$nskipped" "$skipped" "$src"
  [ "$imported" -gt 0 ] || return 1
  return 0
}

# name, source, file count, checksum, when. It lives inside skills/vendor/,
# which git ignores, so the local path it records never enters the repository.
manifest_put() {
  local vendor="$1" n="$2" src="$3" dest="$4" count sum keep tab m
  m="$vendor/MANIFEST.tsv"
  tab="$(printf '\t')"
  count="$(find "$dest" -type f 2>/dev/null | wc -l | tr -d ' ')"
  sum="$(find "$dest" -type f 2>/dev/null | LC_ALL=C sort \
    | while IFS= read -r f; do cksum < "$f"; done | cksum | awk '{print $1}')"
  keep="$(grep -v "^$n$tab" "$m" 2>/dev/null || true)"
  { [ -n "$keep" ] && printf '%s\n' "$keep"
    printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$src" "$count" "$sum" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$m.new" && mv "$m.new" "$m"
}

# =========================================================================
# self-update: a proposal, not an edit
# =========================================================================
cmd_selfupdate() {
  local repo="$REPO" skill='' why='' dir id spec
  while [ $# -gt 0 ]; do
    case "$1" in
      --skill) skill="${2-}"; shift 2 ;;
      --why)   why="${2-}";   shift 2 ;;
      --repo)  repo="${2-}";  shift 2 ;;
      *) die "self-update: unknown argument $1" ;;
    esac
  done
  [ -n "$skill" ] || { usage >&2; die "self-update: --skill is required"; }
  # a change nobody can state a reason for is a change no reviewer can judge,
  # and the reason is the whole of what the captain rules on
  [ -n "$why" ] || die "self-update: --why is required, the captain rules on the reason"
  repo="$(abs "$repo")" || die "no repo at $repo"
  case "$skill" in
    vendor|vendor/*) die "self-update: skills/vendor is imported and read-only; change it upstream" ;;
    */*|*[!A-Za-z0-9._-]*) die "self-update: $skill is not a skill name" ;;
  esac
  [ -f "$repo/skills/$skill/SKILL.md" ] || die "self-update: no skill at skills/$skill/SKILL.md"
  [ -x "$repo/bin/fm-decide.sh" ] || die "self-update: bin/fm-decide.sh is missing" 70

  dir="$repo/state/skill-updates"
  mkdir -p "$dir" || die "self-update: cannot create $dir" 70
  id="$(next_id "$dir" "$repo/design/tasks.json")"

  # An ordinary task spec, and ordinary is the point: fm-dispatch reads it,
  # fm-worker branches from it, fm-gate gates it. The scope reaches the skill
  # and the test that proves it, and nothing else - a skill-update that could
  # touch bin/ would be a way for the system to rewrite its own law.
  jq -n --arg id "$id" --arg skill "$skill" --arg why "$why" '{
    id: $id,
    milestone: "M2",
    bootstrap: false,
    depends_on: [],
    title: ("skill-update: " + $skill),
    why: $why,
    scope: [("skills/" + $skill + "/**"), "tests/skills.test.sh"],
    acceptance: [
      ("skills/" + $skill + "/SKILL.md says it, in English, in plain markdown"),
      "tests/skills.test.sh asserts the sentence that carries it",
      ("reverting skills/" + $skill + "/SKILL.md turns that assertion red"),
      "no file outside the declared scope is touched"
    ]
  }' > "$dir/$id.json" || die "self-update: could not write the proposal" 70

  # the captain sees it as a card, through the same script every other
  # decision goes through. Nothing is dispatched: a greenlit event is the
  # eighth gate and it is not ours to emit.
  "$repo/bin/fm-decide.sh" --request "D-$id" --task "$id" --kind choice --repo "$repo" \
    --title "skill-update: $skill - $why" >/dev/null </dev/null \
    || die "self-update: could not put $id in front of the captain" 70

  spec="$(cat "$dir/$id.json")"
  printf 'fm self-update: %s proposed. Nothing under skills/ has changed.\n\n' "$id"
  printf 'Add this to design/tasks.json once the captain green-lights it:\n\n%s\n\n' "$spec"
  printf 'and this row to section 14 of design/design.md, which bin/ci.sh checks:\n\n'
  printf '| %s | skill-update: %s | - |\n\n' "$id" "$skill"
  printf '%s\n' "$dir/$id.json"
}

# the next free SK id, counting both the proposals already made and any that
# have since been adopted into the task file
next_id() {
  local dir="$1" tasks="$2" cur max=0
  while IFS= read -r cur; do
    [ -n "$cur" ] || continue
    cur=$((10#$cur))
    [ "$cur" -gt "$max" ] && max="$cur"
  done <<< "$( { ls "$dir" 2>/dev/null | sed -n 's/^SK-\([0-9][0-9]*\)\.json$/\1/p'
                 jq -r '.tasks[]?.id // empty' "$tasks" 2>/dev/null \
                   | sed -n 's/^SK-\([0-9][0-9]*\)$/\1/p'; } )"
  printf 'SK-%03d' "$((max + 1))"
}

# =========================================================================
cmd="${1:-help}"
[ $# -eq 0 ] || shift
case "$cmd" in
  self-update) cmd_selfupdate "$@" ;;
  sync-skills) cmd_sync "$@" ;;
  lint)        cmd_lint "$@" ;;
  help|-h|--help) usage ;;
  *) usage >&2; die "unknown command: $cmd" ;;
esac
