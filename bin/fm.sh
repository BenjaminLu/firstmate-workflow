#!/usr/bin/env bash
# fm:skills-writer
# The bounded syntactic lint permits this writer only under skills/vendor/.
# It is a review aid, not an enforcement boundary for arbitrary programs.
#
# Self-update, and the import of somebody else's skills.
#
#   fm.sh self-update --skill worker --why "..."   propose a skill change
#   fm.sh self-update --adopt SK-001               after the captain says yes
#   fm.sh sync-skills <dir> [--name NAME]          import external skills
#   fm.sh lint                                     the two skill lints
#   fm.sh tasks                                    the task table, on demand
#   fm.sh tasks split [ID]                         design/tasks.json -> one file each
#   fm.sh roster [init] [--redraw]                 the installation's crew
#   fm.sh stop <task>                              end the task's live crew runs
#
# The system defines its own behaviour in skills/, which makes editing a
# skill the one thing it must not be able to do quietly. So self-update
# writes no skill: it writes a task and a decision card, and the change
# travels the branch, the pull request and the gates that every other
# change travels. There is deliberately no flag that applies one.
#
# `--adopt` is the other half of that sentence, and it exists because the
# first cut of this script stopped at printing instructions for a human to
# paste. A card the captain answers with nothing downstream reading the
# answer is decoration: --adopt reads state/decisions/D-<id>.json, refuses
# unless the captain approved it, and only then writes the task into its own
# file, design/tasks/<id>.json - the list fm-dispatch.sh and bin/ci.sh
# actually read (T-090). It still writes no skill.
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
# the one reader and writer of the task list (fm_tasks, fm_tasks_write)
[ -f "$HERE/fm-config.sh" ] || { echo "fm: missing $HERE/fm-config.sh" >&2; exit 70; }
# shellcheck source=bin/fm-config.sh
. "$HERE/fm-config.sh"

TAB="$(printf '\t')"
die() { printf 'fm: %s\n' "$1" >&2; exit "${2:-64}"; }
# All value-taking options reject missing/option-shaped values before shift.
need() {
  [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"
  case "$2" in -*) die "$1 requires a value, got $2" ;; esac
}

# Reject links before touching a cache. This includes dangling links and
# linked metadata or old staging paths. No linked content is supported.
no_links() {
  local links
  [ ! -L "$1" ] || die "sync-skills: symlink is not allowed: $1"
  [ -e "$1" ] || return 0
  links="$(find "$1" -type l -print 2>/dev/null)" \
    || die "sync-skills: cannot inspect $1" 70
  [ -z "$links" ] || die "sync-skills: symlink is not allowed: $links"
}

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
        through a pull request, under the same gates.

  self-update --adopt <SK-id> [--repo DIR]
        The captain answered the card yes. Copy the proposal into its own
        task file, design/tasks/<SK-id>.json, so the dispatcher can pick
        it up. Refuses while the card is unanswered or answered no. Still
        edits no skill.

  tasks [--repo DIR]
        Print the task table from design/tasks/, grouped by milestone:
        id, title and dependencies. Nothing generated is committed.

  tasks split [ID] [--repo DIR]
        Move entries of the old one-array task list, design/tasks.json,
        into design/tasks/<id>.json. Given an ID, move that entry alone
        and overwrite its file: a branch bringing its own task over.
        Without one, an existing file that differs is refused.

  roster [init] [--redraw] [--repo DIR]
        Print this installation's worker and reviewer rosters. `init`
        draws them, 24 names each, if they are missing and refuses to
        redraw an existing crew; `--redraw` draws a new one, and ranks
        and service records keyed by the old names stay with those names.

  board [--repo DIR]
        Open or reopen the captain's board: start it or reuse it, then
        send the browser to a one-time sign-in address (good once, for
        60 seconds). Only a tab opened this way can answer cards, move
        tasks or open files; any other tab is read-only.

  stop <task> [--repo DIR]
        End the task's live worker and reviewer runs and every process
        they own, their process groups included: TERM, then KILL for
        whatever is still there after FM_STOP_GRACE seconds (10). The
        stop is recorded in each run's stopped.json and under
        state/stops/, and a stopped reviewer posts no verdict.

  sync-skills <source-dir> [--name NAME] [--repo DIR]
        Import external skills into skills/vendor/, read-only. One way:
        the source is never written to, and a local edit to an imported
        copy is discarded by the next import.

  lint [--repo DIR]
        Two checks. Detect supported literal skill writes in programs, and
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

# -------------------------------------------------------------------------
# the writer lint
#
# Walk the repository without a directory allowlist, then select executables,
# shebang files and recognised program names below. Unrecognised languages,
# prose, and dynamically evaluated source remain outside this bounded lint.
#
# Pruned, with a reason each: .git and node_modules are not ours,
# skills/vendor is imported and read-only by construction, state/ is runtime
# data that git ignores and nothing in it is ever committed.
corpus() {
  local repo="$1"
  find "$repo" \
    \( -name .git -o -name node_modules -o -name test-results -o -name playwright-report \
       -o -path "$repo/skills/vendor" -o -path "$repo/state" \) -prune -o \
    -type f -print 2>/dev/null | LC_ALL=C sort
}

# A program is a file with a shebang, the executable bit, or a name that says
# which language it is. Prose is not a program - which is a limitation worth
# saying out loud rather than hiding: a SKILL.md that tells an agent in
# English to edit a skill is a path this lint cannot see. The reviewer and
# the gates are what catch that one.
is_program() {
  local first=''
  # what it is beats what it is called: the executable bit and the shebang
  # are read first, so a hook with no suffix and a `python3 thing` with no
  # bit are both in the corpus
  [ -x "$1" ] && return 0
  IFS= read -r first < "$1" 2>/dev/null || true
  case "$first" in '#!'*) return 0 ;; esac
  case "$1" in
    *.sh|*.bash|*.zsh|*.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.py|*.rb|*.pl|*.php|*.lua) return 0 ;;
    *.yml|*.yaml|Makefile|makefile|GNUmakefile|*.mk) return 0 ;;
    # html only when something in it runs. A document that happens to be
    # html is prose, and prose quoting a shell line is how a lint starts
    # crying wolf at its own documentation.
    *.html) grep -q '<script' "$1" 2>/dev/null && return 0; return 1 ;;
  esac
  return 1
}

# write_targets <file> <mode> ; prints "line<TAB>normalised<TAB>as written"
# for every destination under skills/ the file writes to.
#
# It is a reader, not a shell: it finds redirects, the commands that write
# their arguments, the commands that write only their last argument, the
# in-place editors, git's write subcommands, and the host-language calls.
# Then it normalises the destination - "$X/skills/vendor/../worker" is
# skills/worker, and comparing strings instead of paths is what let the last
# round's declared writer climb out of skills/vendor.
#
# Limits: this does not evaluate variables, aliases, computed paths, language
# syntax, heredoc execution, or general working-directory changes. Counting
# declarations does not close those gaps or prove arbitrary programs cannot write skills. Review and the
# PR gates remain required. Unknown variable roots in tests are treated as
# fixture paths; that convention is not a proof of temporary provenance.
# Tests are checked for literal relative paths and known checkout roots.
write_targets() {
  awk -v mode="$2" '
  function endtok(s) {
    return (s == ";" || s == "|" || s == "&" || s == "&&" || s == "||" ||
            s == ")" || s == "}" || s == "then" || s == "do" || s == "else" ||
            s == "fi" || s == "done" || substr(s, 1, 1) == ">" || substr(s, 1, 1) == "<")
  }
  function norm(p,   n, i, parts, out, k, res) {
    n = split(p, parts, "/"); k = 0
    for (i = 1; i <= n; i++) {
      if (parts[i] == "" || parts[i] == ".") continue
      if (parts[i] == "..") { if (k > 0 && out[k] != "..") { k-- } else { out[++k] = ".." }; continue }
      out[++k] = parts[i]
    }
    res = ""
    for (i = 1; i <= k; i++) res = (res == "" ? out[i] : res "/" out[i])
    return res
  }
  # index(), not a regex with an anchor inside an alternation: the runner
  # awk is mawk and this has to read the same there as it does here
  function skillpath(d,   s, p) {
    s = d; gsub(QUOTES, "", s)
    s = "/" s
    p = index(s, "/skills/")
    if (p > 0) return norm(substr(s, p + 1))
    if (length(s) >= 7 && substr(s, length(s) - 6) == "/skills") return "skills"
    return ""
  }
  function rooted(raw,   s, v) {
    s = raw; gsub(QUOTES, "", s)
    sub(/^[ \t]+/, "", s)
    if (substr(s, 1, 1) != "$") return (substr(s, 1, 1) != "/" && !fixture_cwd)
    v = substr(s, 2); sub("^\\{", "", v); sub("[/}].*$", "", v)
    return (v in roots)
  }
  function record(ln, raw, p, key) {
    p = skillpath(raw)
    if (p == "") return
    if (mode == "tests" && !rooted(raw)) return
    key = ln "\t" p
    if (key in seen) return
    seen[key] = 1
    print ln "\t" p "\t" raw
  }
  function scan(ln, line,   s, m, pre, t, n, j, k, cmd, last, inplace, sub_, a) {
    if (line ~ /^[ \t]*#/) return
    # Recognise the narrow fixture idiom: mktemp assignment, derived path,
    # then cd to that variable. Reset at function boundaries. This is not
    # general shell dataflow or working-directory analysis.
    if (mode == "tests") {
      if (line ~ /^[ \t]*}/ || line ~ /^[A-Za-z_][A-Za-z_0-9]*\(\)/) fixture_cwd = 0
      s = line
      while (match(s, /[A-Za-z_][A-Za-z_0-9]*=[^;]+/)) {
        a = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        cmd = a; sub(/=.*/, "", cmd)
        sub(/^[^=]*=/, "", a); gsub(QUOTES, "", a)
        if (a ~ /^\$\(mktemp -d\)/) temps[cmd] = 1
        else { sub(/^\$/, "", a); sub(/[\/ \t].*/, "", a); if (a in temps) temps[cmd] = 1 }
      }
      if (match(line, /(^|[; \t])cd[ \t]+[^; \t]+/)) {
        a = substr(line, RSTART, RLENGTH); sub(/^.*cd[ \t]+/, "", a)
        gsub(QUOTES, "", a); sub(/^\$/, "", a); sub(/\{/, "", a); sub(/[\/}].*/, "", a)
        fixture_cwd = (a in temps)
      }
    }
    s = line
    while (match(s, />>?[ \t]*[^ \t;|&()<>]+/)) {
      m = substr(s, RSTART, RLENGTH)
      pre = (RSTART > 1) ? substr(s, RSTART - 1, 1) : ""
      s = substr(s, RSTART + RLENGTH)
      if (pre == "-" || pre == "=" || pre == "<" || pre == ">") continue
      sub(/^>>?[ \t]*/, "", m)
      record(ln, m)
    }
    n = split(line, t, /[ \t]+/)
    for (j = 1; j <= n; j++) {
      cmd = t[j]; gsub(QUOTES, "", cmd); sub(/^[({;&|]+/, "", cmd)
      if (cmd in lastarg) {
        last = ""
        for (k = j + 1; k <= n; k++) {
          if (endtok(t[k])) break
          if (substr(t[k], 1, 1) != "-") last = t[k]
        }
        if (last != "") record(ln, last)
      } else if (cmd in allargs) {
        for (k = j + 1; k <= n; k++) {
          if (endtok(t[k])) break
          if (substr(t[k], 1, 1) != "-") record(ln, t[k])
        }
      } else if (cmd == "sed" || cmd == "perl" || cmd == "ruby") {
        inplace = 0
        for (k = j + 1; k <= n; k++) { if (endtok(t[k])) break; if (t[k] ~ /^-[A-Za-z]*i/) inplace = 1 }
        if (inplace)
          for (k = j + 1; k <= n; k++) {
            if (endtok(t[k])) break
            if (substr(t[k], 1, 1) != "-") record(ln, t[k])
          }
      } else if (cmd == "git") {
        sub_ = 0
        for (k = j + 1; k <= n; k++) {
          if (endtok(t[k])) break
          if (sub_) { if (substr(t[k], 1, 1) != "-") record(ln, t[k]); continue }
          if (t[k] == "checkout" || t[k] == "restore" || t[k] == "apply" ||
              t[k] == "rm" || t[k] == "mv" || t[k] == "clean") sub_ = 1
        }
      }
    }
    s = line
    while (match(s, /(writeFileSync|writeFile|appendFileSync|appendFile|outputFile|createWriteStream|copyFileSync|copyFile|renameSync|rename|mkdirSync|rmSync|unlinkSync|Bun\.write)[ \t]*\(/)) {
      cmd = substr(s, RSTART, RLENGTH)
      s = substr(s, RSTART + RLENGTH)
      a = s; sub(/[,)].*$/, "", a)
      if (cmd !~ /^copyFile/) record(ln, a)
      if (cmd ~ /^(copyFile|rename)/) {
        a = s; sub(/^[^,]*,[ \t]*/, "", a)
        sub(/[,)].*$/, "", a); record(ln, a)
      }
    }
    if (line ~ /open[ \t]*\(/ && line ~ ("[\"" Q "][wax]")) {
      a = line; sub(/^.*open[ \t]*\(/, "", a); sub(/[,)].*$/, "", a); record(ln, a)
    }
  }
  BEGIN {
    # quotes and backslashes are noise around a path, not part of it: a
    # python one-liner inside a shell string reaches the file as
    # open(\"skills/...\") and the backslash is what hid it last time
    Q = sprintf("%c", 39); QUOTES = "[\"" Q "\\\\]"
    split("cp install ln rsync", x, " ");                for (i in x) lastarg[x[i]] = 1
    split("mv rm rmdir mkdir touch tee truncate patch sponge unlink shred dd", x, " ")
    for (i in x) allargs[x[i]] = 1
    nl = 0
  }
  {
    if (heredoc != "") { if ($0 == heredoc) heredoc = ""; next }
    nl++; L[nl] = $0; lineno[nl] = NR
    if (match($0, /<<[ \t]*[\042\047]?[A-Za-z_][A-Za-z_0-9]*[\042\047]?/)) {
      heredoc = substr($0, RSTART, RLENGTH)
      sub(/^<<[ \t]*/, "", heredoc); gsub(QUOTES, "", heredoc)
    }
  }
  END {
    if (mode == "tests") {
      roots["FM_ROOT"] = 1
      for (i = 1; i <= nl; i++)
        if ((L[i] ~ /BASH_SOURCE/ || L[i] ~ /FM_ROOT/) &&
            match(L[i], /^[ \t]*[A-Za-z_][A-Za-z_0-9]*=/)) {
          v = substr(L[i], RSTART, RLENGTH - 1); sub(/^[ \t]*/, "", v); roots[v] = 1
        }
    }
    for (i = 1; i <= nl; i++) scan(lineno[i], L[i])
  }' "$1"
}

# One repository, one declared writer. Without this, "the marker licenses
# this file" quietly becomes "the marker licenses any file that adds a
# comment line" - and the last round printed the count without ever reading
# it, which is the same thing as not counting.
declared_writers() {
  local repo="$1" f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    is_program "$f" || continue
    grep -q '^# fm:skills-writer' "$f" 2>/dev/null || continue
    printf '%s\n' "${f#"$repo"/}"
  done <<< "$(corpus "$repo")"
}

# lint_writers <repo> ; prints one line per violation
lint_writers() {
  local repo="$1" f rel mode out ln p raw declares
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    is_program "$f" || continue
    rel="${f#"$repo"/}"
    declares=0
    grep -q '^# fm:skills-writer' "$f" 2>/dev/null && declares=1
    mode=all
    case "$rel" in tests/*|*/tests/*) mode=tests ;; esac
    out="$(write_targets "$f" "$mode")" || { printf "%s: writer analysis failed\n" "$rel"; continue; }
    [ -n "$out" ] || continue
    while IFS="$TAB" read -r ln p raw; do
      [ -n "$ln" ] || continue
      if [ "$mode" = tests ]; then
        printf '%s:%s: a suite writes into the checkout it runs from (%s)\n' "$rel" "$ln" "$raw"
      elif [ "$declares" -eq 0 ]; then
        printf '%s:%s: writes under skills/ and is not the declared writer (%s)\n' "$rel" "$ln" "$p"
      else
        case "$p" in
          skills/vendor|skills/vendor/*) ;;
          *) printf '%s:%s: the declared writer may only write skills/vendor/, this writes %s\n' "$rel" "$ln" "$p" ;;
        esac
      fi
    done <<< "$out"
  done <<< "$(corpus "$repo")"
}

cmd_lint() {
  local repo="$REPO" bad w v n writers nwriters
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) need "$@"; repo="${2-}"; shift 2 ;;
      *) die "lint: unknown argument $1" ;;
    esac
  done
  repo="$(abs "$repo")" || die "no repo at $repo"
  bad=0

  w="$(lint_writers "$repo")"
  writers="$(declared_writers "$repo")"
  nwriters=0
  [ -z "$writers" ] || nwriters="$(printf '%s\n' "$writers" | wc -l | tr -d ' ')"
  if [ -n "$w" ]; then
    printf 'fm lint: detected a prohibited literal skill write:\n'
    printf '%s\n' "$w" | sed 's/^/  x /'
    bad=1
  elif [ "$nwriters" -gt 1 ]; then
    printf 'fm lint: %s files declare themselves the skills writer:\n' "$nwriters"
    printf '%s\n' "$writers" | sed 's/^/  x /'
    bad=1
  else
    printf '  + no prohibited literal skill writes detected (%s declared writer)\n' "$nwriters"
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
      --repo) need "$@"; repo="${2-}"; shift 2 ;;
      --name) need "$@"; name="${2-}"; shift 2 ;;
      -*) die "sync-skills: unknown argument $1" ;;
      *) [ -z "$src" ] || die "sync-skills: one source directory at a time"; src="$1"; shift ;;
    esac
  done
  [ -n "$src" ] || { usage >&2; die "sync-skills: a source directory is required"; }
  repo="$(abs "$repo")" || die "no repo at $repo"
  src="$(abs "$src")" || die "sync-skills: no directory at $src"
  # Neither tree may contain the other. A source containing the repository
  # would be mutated by staging and could recursively copy its own output.
  # Both paths are physical absolute paths; slash boundaries allow siblings
  # with a shared name prefix. Handle the filesystem root explicitly.
  case "$src" in "$repo"|"$repo"/*) die "sync-skills: $src is inside this repository" ;; esac
  case "$repo" in "$src"/*) die "sync-skills: $src contains this repository" ;; esac
  [ "$src" != / ] && [ "$repo" != / ] || die "sync-skills: source and repository overlap"

  # Check source and destination ancestors before the first write. Reject all
  # imported links rather than retain references into the external source.
  no_links "$src"
  [ ! -L "$repo/skills" ] || die "sync-skills: skills is a symlink"
  vendor="$repo/skills/vendor"
  no_links "$vendor"
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

    stage="$(mktemp -d "$vendor/.staging.XXXXXXXX")" || die "sync-skills: cannot allocate staging" 70
    mkdir -p "$stage/$n" || die "sync-skills: cannot stage $n" 70
    cp -R "$s/." "$stage/$n/" 2>/dev/null || { rmtree "$stage"; die "sync-skills: cannot read $s" 1; }

    # lint before it lands, never after: an import that fails the lint would
    # leave skills/ red with a file nobody here may edit. Half a skill is
    # worse than none, so an offending file skips the whole skill.
    no_links "$stage/$n"
    local bad; bad="$(lint_markdown "$stage/$n" "$n/")"
    if [ -n "$bad" ]; then
      printf 'fm sync-skills: skipping %s, it is written for one vendor:\n' "$n"
      printf '%s\n' "$bad" | sed 's/^/  x /'
      skipped="$skipped $n"; nskipped=$((nskipped + 1))
      rmtree "$stage"
      continue
    fi

    rmtree "$dest" || { rmtree "$stage"; die "sync-skills: cannot remove $n" 70; }
    mv "$stage/$n" "$dest" || { rmtree "$stage"; die "sync-skills: cannot place $n" 70; }
    rmtree "$stage"
    # read-only, because the copy is not ours to edit: an edit here is lost
    # at the next import, and making that visible beats making it surprising.
    # The directories too, not only the files: a tree whose files are locked
    # and whose directories are not is a tree you can still add a file to,
    # and that file sits there until the next import quietly deletes it.
    chmod -R a-w "$dest" 2>/dev/null || die "sync-skills: cannot lock $n" 70
    manifest_put "$vendor" "$n" "$s" "$dest" || die "sync-skills: cannot persist manifest" 70
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
  local repo="$REPO" skill='' why='' adopt='' dir id spec
  while [ $# -gt 0 ]; do
    case "$1" in
      --skill) need "$@"; skill="${2-}"; shift 2 ;;
      --why)   need "$@"; why="${2-}";   shift 2 ;;
      --adopt) need "$@"; adopt="${2-}"; shift 2 ;;
      --repo)  need "$@"; repo="${2-}";  shift 2 ;;
      *) die "self-update: unknown argument $1" ;;
    esac
  done
  if [ -n "$adopt" ]; then
    repo="$(abs "$repo")" || die "no repo at $repo"
    adopt_proposal "$repo" "$adopt"
    return
  fi
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
  id="$(next_id "$dir" "$repo/design/tasks")" \
    || die "self-update: the task list in design/tasks/ does not read; no id is taken" 65

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
    --title "skill-update: $skill - $why (A adopt it, B leave it)" >/dev/null </dev/null \
    || die "self-update: could not put $id in front of the captain" 70

  spec="$(cat "$dir/$id.json")"
  printf 'fm self-update: %s proposed. Nothing under skills/ has changed.\n\n' "$id"
  printf '%s\n\n' "$spec"
  printf 'When the captain answers D-%s with A, run:\n\n' "$id"
  printf '    bin/fm.sh self-update --adopt %s\n\n' "$id"
  printf '%s\n' "$dir/$id.json"
}

# The other half: a card nobody reads the answer to is decoration. This is
# the only thing that turns an approved D-SK-* into work the dispatcher can
# see, and it refuses to run until the captain has actually said yes.
#
# It writes design/tasks/<id>.json, which is to say it writes the plan. It
# does not write a skill: the skill is changed on a branch, by a worker,
# through the pull request the adopted task produces.
adopt_proposal() {
  local repo="$1" id="$2" spec answer chosen tasks
  [[ "$id" =~ ^SK-[0-9]{3,}$ ]] || die "self-update: $id is not a proposal id (SK-001)"
  spec="$repo/state/skill-updates/$id.json"
  [ -f "$spec" ] || die "self-update: no proposal at state/skill-updates/$id.json"

  answer="$repo/state/decisions/D-$id.json"
  [ -f "$answer" ] || die "self-update: D-$id is still in front of the captain" 1
  chosen="$(jq -r '.chosen // empty' "$answer" 2>/dev/null)"
  [ "$chosen" = "A" ] || die "self-update: the captain answered D-$id with ${chosen:-nothing}, not A" 1

  tasks="$repo/design/tasks"
  [ -d "$tasks" ] || die "self-update: no design/tasks/ to adopt into"
  [ -x "$repo/bin/fm-emit.sh" ] || die "self-update: bin/fm-emit.sh is missing" 70

  # one file of its own: adopting touches no other task's text, and there is
  # no table to keep in step - `fm.sh tasks` prints one on demand
  if fm_task "$id" "$tasks" >/dev/null; then
    printf 'fm self-update: %s is already design/tasks/%s.json\n' "$id" "$id"
  else
    # written beside the list and renamed in, so a failed write leaves no
    # half-written task for the dispatcher to read
    rm -rf "$tasks/.adopt.$id"
    fm_tasks_write "$spec" "$tasks/.adopt.$id" \
      && mv "$tasks/.adopt.$id/$id.json" "$tasks/$id.json" \
      || { rm -rf "$tasks/.adopt.$id"; die "self-update: could not write design/tasks/$id.json" 70; }
    rm -rf "$tasks/.adopt.$id"
    printf 'fm self-update: %s added as design/tasks/%s.json\n' "$id" "$id"
  fi

  [ -x "$repo/bin/fm-emit.sh" ] && FM_ROOT="$repo" "$repo/bin/fm-emit.sh" \
    --actor firstmate --type greenlit --task "$id" \
    --en "${id} adopted into the plan" --tw "${id} 已納入計畫" >/dev/null </dev/null \
    || die "self-update: could not emit greenlit for $id; retry adoption" 70
  printf 'fm self-update: %s is now an ordinary task. Nothing under skills/ has changed.\n' "$id"
}

# the next free SK id, counting both the proposals already made and any that
# have since been adopted into the task list. 1 when the task list does not
# read: an id counted from half the list may be one already taken.
next_id() {
  local dir="$1" tasks="$2" cur max=0 all
  all="$(fm_tasks "$tasks")" || return 1
  while IFS= read -r cur; do
    [ -n "$cur" ] || continue
    cur=$((10#$cur))
    [ "$cur" -gt "$max" ] && max="$cur"
  done <<< "$( { ls "$dir" 2>/dev/null | sed -n 's/^SK-\([0-9][0-9]*\)\.json$/\1/p'
                 printf '%s' "$all" | jq -r '.id // empty' 2>/dev/null \
                   | sed -n 's/^SK-\([0-9][0-9]*\)$/\1/p'; } )"
  printf 'SK-%03d' "$((max + 1))"
}

# =========================================================================
# tasks: the table, printed rather than kept
# =========================================================================
# design.md held a hand-kept copy of the task list, and every pull request
# edited it, so every merge conflicted with every other open pull request
# (T-090). The table is now printed on demand from design/tasks/ and never
# committed, so there is nothing to conflict.
cmd_tasks() {
  local repo="$REPO" sub=''
  case "${1:-}" in split) sub='split'; shift ;; esac
  if [ "$sub" = split ]; then cmd_tasks_split "$@"; return; fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) need "$@"; repo="${2-}"; shift 2 ;;
      *) die "tasks: unknown argument $1" ;;
    esac
  done
  repo="$(abs "$repo")" || die "no repo at $repo"
  [ -d "$repo/design/tasks" ] || die "tasks: no design/tasks/ in $repo" 65
  local all
  all="$(fm_tasks "$repo/design/tasks")" || die "tasks: a task file in design/tasks/ does not parse" 65
  # grouped by milestone in milestone order, file order within one; a title
  # that holds a | is escaped so the row stays a row
  printf '%s\n' "$all" | jq -rs '
    def cell: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
    group_by(.milestone // "") | .[] |
      "### \(.[0].milestone // "(no milestone)")\n\n| id | title | depends on |\n|---|---|---|",
      (.[] | "| \(.id | cell) | \(.title // "" | cell) | \(if ((.depends_on // []) | length) == 0
             then "—" else (.depends_on | map(cell) | join(", ")) end) |"),
      ""'
}

# The migration, and how a branch opened before it comes over: entries of
# design/tasks.json move out of the one array into files of their own. Named
# by id, a single entry moves and overwrites its file - the branch's own
# task, which is the branch's to say. Without one every entry moves, and a
# file that already says something different is refused, not overwritten.
# The id is positional: tests/option-loop.test.sh pins fm.sh's flags.
cmd_tasks_split() {
  local repo="$REPO" from only='' tmp id
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) need "$@"; repo="${2-}"; shift 2 ;;
      -*) die "tasks split: unknown argument $1" ;;
      *) [ -z "$only" ] || die "tasks split: one id at most, got $only and $1"
         only="$1"; shift ;;
    esac
  done
  repo="$(abs "$repo")" || die "no repo at $repo"
  from="$repo/design/tasks.json"
  [ -f "$from" ] || die "tasks split: no $from to split" 65
  jq -e '.tasks | type == "array"' "$from" >/dev/null 2>&1 \
    || die "tasks split: $from holds no {\"tasks\": [...]}" 65
  tmp="$(mktemp -d)" || die "tasks split: no scratch directory" 70
  if [ -n "$only" ]; then
    jq -e --arg id "$only" '[.tasks[] | select(.id == $id)] | length == 1' "$from" >/dev/null 2>&1 \
      || { rm -rf "$tmp"; die "tasks split: $from holds no single entry $only" 65; }
    jq --arg id "$only" '.tasks | map(select(.id == $id))' "$from" > "$tmp/in.json"
  else
    jq '.tasks' "$from" > "$tmp/in.json"
  fi
  fm_tasks_write "$tmp/in.json" "$tmp/out" || { rm -rf "$tmp"; die "tasks split: could not split $from" 65; }
  if [ -z "$only" ]; then
    for id in "$tmp"/out/*.json; do
      [ -f "$id" ] || continue
      id="${id##*/}"
      if [ -f "$repo/design/tasks/$id" ] \
         && [ "$(jq -cS . "$repo/design/tasks/$id")" != "$(jq -cS . "$tmp/out/$id")" ]; then
        rm -rf "$tmp"; die "tasks split: design/tasks/$id already says something else; move your own entry by its id" 1
      fi
    done
  fi
  mkdir -p "$repo/design/tasks" || { rm -rf "$tmp"; die "tasks split: cannot create design/tasks/" 70; }
  for id in "$tmp"/out/*.json; do
    [ -f "$id" ] || continue
    mv "$id" "$repo/design/tasks/${id##*/}" || { rm -rf "$tmp"; die "tasks split: could not write ${id##*/}" 70; }
    printf 'fm tasks split: design/tasks/%s\n' "${id##*/}"
  done
  rm -rf "$tmp"
  printf 'fm tasks split: done; git rm design/tasks.json once nothing else in it is yours\n'
}

# The installation's crew (T-104): 24 worker and 24 reviewer names, drawn once
# into state/crew/rosters.json by bin/fm-herdr.py, which also keeps the pool.
cmd_roster() {
  local repo="$REPO" action=show redraw=''
  while [ $# -gt 0 ]; do
    case "$1" in
      init) action=init; shift ;;
      --redraw) redraw=1; shift ;;
      --repo) need "$@"; repo="${2-}"; shift 2 ;;
      *) die "roster: unknown argument $1" ;;
    esac
  done
  repo="$(abs "$repo")" || die "no repo at $repo"
  python3 "$HERE/fm-herdr.py" roster "$repo" "$action" "$redraw"
}

# Open, or reopen, the captain's board (T-122): start or reuse the board for
# this root, then send the browser to a one-time sign-in address, the only
# way a tab comes to hold the credential that lets it write. The address is
# never printed; bin/fm-herdr.py hands it to the browser and records only the
# board's plain URL.
cmd_board() {
  local repo="$REPO"
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) need "$@"; repo="${2-}"; shift 2 ;;
      *) die "board: unknown argument $1" ;;
    esac
  done
  repo="$(abs "$repo")" || die "no repo at $repo"
  python3 "$HERE/fm-herdr.py" board "$repo"
}

# A stopped round takes its crew with it (T-107). Killing a round's launcher
# left its engine running: a worker kept editing to a superseded spec, and a
# reviewer posted a verdict on a stale head. The work is bin/fm-herdr.py's,
# which keeps the run records it reads.
cmd_stop() {
  local repo="$REPO" task=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) need "$@"; repo="${2-}"; shift 2 ;;
      -*) die "stop: unknown argument $1" ;;
      *) [ -z "$task" ] || die "stop: one task at a time, got $task and $1"
         task="$1"; shift ;;
    esac
  done
  [ -n "$task" ] || die "stop: which task? fm.sh stop <task>"
  repo="$(abs "$repo")" || die "no repo at $repo"
  python3 "$HERE/fm-herdr.py" stop "$repo" "$task"
}

# =========================================================================
cmd="${1:-help}"
[ $# -eq 0 ] || shift
case "$cmd" in
  self-update) cmd_selfupdate "$@" ;;
  sync-skills) cmd_sync "$@" ;;
  lint)        cmd_lint "$@" ;;
  tasks)       cmd_tasks "$@" ;;
  roster)      cmd_roster "$@" ;;
  board)       cmd_board "$@" ;;
  stop)        cmd_stop "$@" ;;
  help|-h|--help) usage ;;
  *) usage >&2; die "unknown command: $cmd" ;;
esac
