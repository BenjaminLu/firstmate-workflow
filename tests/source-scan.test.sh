#!/usr/bin/env bash
# tests/lib/source_scan.py reads a source file the way its own parser does
# (T-279): Python through ast, shell through the bash that runs the suite.
# The suites' sweeps (tests/decide.test.sh, tests/gate.test.sh) lean on it to
# tell code from comments and a real Herdr guard from text that looks like one.
# Helpers: tests/lib/source_scan.py
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# Its samples name card-raising scripts, so the card-guard sweep holds it to a
# guard like any suite that reaches one: nothing inherited from a session.
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k"
done
scan() { python3 "$ROOT/tests/lib/source_scan.py" "$@"; }
work="$(safe_tmpdir)"
trap 'safe_rm_rf "$work"' EXIT

# --- code: comments go, strings stay -------------------------------------
cat > "$work/doc.py" <<'PY'
"""Runs bin/fm.sh for the captain."""
import subprocess


def run():
    """Calls bin/fm.sh once."""
    subprocess.run(['bin/fm.sh', 'tasks'])  # bin/fm.sh in a comment
PY
out="$(scan code --bash "$BASH" "$work/doc.py")"
assert_lacks "$out" "Runs bin/fm.sh" "code drops a Python module docstring that names bin/fm.sh"
assert_lacks "$out" "Calls bin/fm.sh" "and a function docstring"
assert_lacks "$out" "in a comment" "and a comment"
assert_contains "$out" "['bin/fm.sh', 'tasks']" "but keeps a string argument with the same text"

cat > "$work/doc.sh" <<'SH'
#!/usr/bin/env bash
run bin/fm.sh  # a trailing comment
cat <<'EOF'
heredoc body # with a hash
EOF
SH
out="$(scan code --bash "$BASH" "$work/doc.sh")"
assert_lacks "$out" "a trailing comment" "code drops a shell trailing comment"
assert_contains "$out" "run bin/fm.sh" "and keeps the command"
assert_contains "$out" "heredoc body # with a hash" "and keeps a heredoc body as written"

# --- heredoc_split: a script a file writes, apart from the file's code ---
cat > "$work/writes.sh" <<'SH'
cat > fwd <<'EOF'
run fm-decide --request
EOF
x='first
fm-decide --request'
SH
assert_contains "$(scan code --bash "$BASH" "$work/writes.sh")" "run fm-decide --request" \
  "code keeps a heredoc body that names a call"
split() {
  python3 - "$ROOT/tests/lib" "$BASH" "$1" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import source_scan
rest, bodies = source_scan.heredoc_split(sys.argv[2], sys.argv[3])
print(rest)
print('--bodies', bodies)
PY
}
out="$(split "$work/writes.sh")"
assert_contains "$out" "--bodies ['run fm-decide --request\\n']" "heredoc_split returns each heredoc body apart"
assert_lacks "${out%%--bodies*}" "run fm-decide --request" "and leaves it out of the file's code"
assert_contains "${out%%--bodies*}" $'\nfm-decide --request' "but keeps a multi-line string, which is not a script"
assert_contains "${out%%--bodies*}" "cat > fwd" "and the command that writes the heredoc"

# --- sh-guard: a top-level export in the shell running the suite --------
sh_guard_case() {  # sh_guard_case <want 0|1> <source> <name>
  printf '%s\n' "$2" > "$work/guard.sh"
  scan sh-guard --bash "$BASH" "$work/guard.sh" >/dev/null 2>&1
  assert_eq "$1" "$?" "$3"
}
sh_guard_case 0 'set -e; export HERDR_ENV=0' "set -e; export HERDR_ENV=0 is a top-level shell guard"
sh_guard_case 0 'export HERDR_ENV=0 FM_TRANSPORT=direct' "an export of several names that sets HERDR_ENV=0 is a guard"
sh_guard_case 1 $'if true; then\nexport HERDR_ENV=0\nfi' "an export inside if is not a guard, even at column 0"
sh_guard_case 1 $'f() {\nexport HERDR_ENV=0\n}' "an export inside a function is not a guard"
sh_guard_case 1 $'case x in\nx) export HERDR_ENV=0 ;;\nesac' "an export inside case is not a guard"
sh_guard_case 1 $'for i in 1; do\nexport HERDR_ENV=0\ndone' "an export inside a loop is not a guard"
sh_guard_case 1 'true && export HERDR_ENV=0' "an export joined by && is not a guard"
sh_guard_case 1 'false || export HERDR_ENV=0' "an export joined by || is not a guard"
sh_guard_case 1 'export HERDR_ENV=0 | cat' "an export in a pipeline is not a guard"
sh_guard_case 1 'export HERDR_ENV=0 &' "an export in the background is not a guard"
sh_guard_case 1 '( export HERDR_ENV=0 )' "an export in a subshell is not a guard"
sh_guard_case 1 '{ export HERDR_ENV=0; }' "an export in a group is not a guard"
sh_guard_case 1 'export HERDR_ENV=1' "an export of HERDR_ENV=1 is not a guard"
sh_guard_case 1 $'cat <<EOF\nexport HERDR_ENV=0\nEOF' "a heredoc line is not a guard"
sh_guard_case 1 '# export HERDR_ENV=0' "a comment is not a guard"

# --- a literal's text is neither a guard nor rewritten -------------------
# bash prints a literal as written, so a line of it can look like a top-level
# command; each form below holds the line "    export HERDR_ENV=0" as data.
literal_case() {  # literal_case <file> <form>
  scan sh-guard --bash "$BASH" "$work/$1" >/dev/null 2>&1
  assert_eq 1 "$?" "an export line inside $2 is not a guard"
  assert_contains "$(scan code --bash "$BASH" "$work/$1")" $'\n    export HERDR_ENV=0\n' \
    "and code keeps that line of $2 byte for byte"
}
cat > "$work/lit-digits.sh" <<'SH'
cat <<123
    export HERDR_ENV=0
123
SH
literal_case lit-digits.sh "a heredoc whose delimiter is digits"
cat > "$work/lit-quoted.sh" <<'SH'
cat <<"END OF"
    export HERDR_ENV=0
END OF
SH
literal_case lit-quoted.sh "a heredoc whose quoted delimiter holds a space"
cat > "$work/lit-single.sh" <<'SH'
printf '%s\n' 'first
    export HERDR_ENV=0
last'
SH
literal_case lit-single.sh "a multiline single-quoted string"
cat > "$work/lit-double.sh" <<'SH'
printf '%s\n' "first
    export HERDR_ENV=0
last"
SH
literal_case lit-double.sh "a multiline double-quoted string"
cat > "$work/lit-ansi.sh" <<'SH'
x=$'first
    export HERDR_ENV=0
last'
SH
literal_case lit-ansi.sh "a multiline \$'...' string"
cat > "$work/lit-same-line.sh" <<'SH'
cat <<A; echo 'first
    export HERDR_ENV=0
last'
body
A
SH
literal_case lit-same-line.sh "a string that opens on a heredoc's line"
cat > "$work/lit-subst.sh" <<'SH'
x=$(
    export HERDR_ENV=0
)
SH
scan sh-guard --bash "$BASH" "$work/lit-subst.sh" >/dev/null 2>&1
assert_eq 1 "$?" "an export inside a multiline \$(...) is not a guard"
printf '%s\n' "x=\"\${y:+ a #\$z}\"" 'export HERDR_ENV=0' > "$work/lit-hash.sh"
scan sh-guard --bash "$BASH" "$work/lit-hash.sh" >/dev/null 2>&1
assert_eq 0 "$?" "a # inside \${...} starts no comment, so the export after it is still a guard"
printf '%s\n' 'cat <<123' 'body' '123' 'export HERDR_ENV=0' > "$work/lit-after.sh"
scan sh-guard --bash "$BASH" "$work/lit-after.sh" >/dev/null 2>&1
assert_eq 0 "$?" "a top-level export after a closed heredoc is still a guard"
printf '%s\n' 'x=1' '(( x << 2 ))' 'export HERDR_ENV=0' > "$work/lit-shift.sh"
scan sh-guard --bash "$BASH" "$work/lit-shift.sh" >/dev/null 2>&1
assert_eq 0 "$?" "a << inside an arithmetic command is a shift, not a heredoc, so the export after it is still a guard"

# --- py-guard: an assignment in the module body itself ------------------
py_guard_case() {  # py_guard_case <want 0|1> <source> <name>
  printf '%s\n' "$2" > "$work/guard.py"
  scan py-guard "$work/guard.py" >/dev/null 2>&1
  assert_eq "$1" "$?" "$3"
}
py_guard_case 0 $'import os\nos.environ["HERDR_ENV"]="0"' "a top-level Python guard with double quotes and no spaces is found"
py_guard_case 1 $'import os\nif FLAG:\n    os.environ[\'HERDR_ENV\'] = \'0\'' "a Python guard inside if FLAG: is not a guard"
py_guard_case 1 $'import os\ndef f():\n    os.environ[\'HERDR_ENV\'] = \'0\'' "a Python guard inside a function is not a guard"
py_guard_case 1 $'import os\nos.environ[\'HERDR_ENV\'] = \'1\'' "a Python assignment of 1 is not a guard"

# --- refusals -----------------------------------------------------------
printf 'if true; then\n' > "$work/broken.sh"
out="$(scan code --bash "$BASH" "$work/broken.sh" 2>&1)"; rc=$?
assert_ne 0 "$rc" "a shell file that does not parse exits non-zero"
assert_contains "$out" "$work/broken.sh" "naming the file"
printf 'def broken(:\n' > "$work/broken.py"
out="$(scan code --bash "$BASH" "$work/broken.py" 2>&1)"; rc=$?
assert_ne 0 "$rc" "a Python file that does not parse exits non-zero"
assert_contains "$out" "$work/broken.py" "naming the file"
out="$(scan code "$work/doc.sh" 2>&1)"; rc=$?
assert_ne 0 "$rc" "code without --bash exits non-zero"
assert_contains "$out" "needs --bash" "and says so; it never picks a bash itself"
out="$(scan sh-guard --bash "$work/doc.sh" "$work/doc.sh" 2>&1)"; rc=$?
assert_ne 0 "$rc" "a --bash that is not executable exits non-zero"
assert_contains "$out" "is not an executable file" "and says so"

# --- the given bash parses, and runs none of the file -------------------
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s\nexec %s "$@"\n' "$work/bash.log" "$BASH" > "$work/logging-bash"
chmod +x "$work/logging-bash"
out="$(scan code --bash "$work/logging-bash" "$work/doc.sh")"
assert_contains "$out" "run bin/fm.sh" "a logging stub bash gives the same reading"
assert_contains "$(cat "$work/bash.log" 2>/dev/null)" "-n $work/doc.sh" "and it is the bash that checked the syntax"
touch_bin="$(command -v touch)"
printf '%s %s\n' "$touch_bin" "$work/marker-top" > "$work/runs.sh"
scan code --bash "$BASH" "$work/runs.sh" >/dev/null 2>&1
assert_fail "[ -e '$work/marker-top' ]" "scanning a file whose top level runs touch runs none of it"
printf '}\n%s %s\n' "$touch_bin" "$work/marker-close" > "$work/close.sh"
scan code --bash "$BASH" "$work/close.sh" >/dev/null 2>&1
assert_fail "[ -e '$work/marker-close' ]" "a file that closes the wrapper early with } runs nothing either"
printf '}\n%s %s\n__fm_again() {\n' "$touch_bin" "$work/marker-reopen" > "$work/reopen.sh"
scan code --bash "$BASH" "$work/reopen.sh" >/dev/null 2>&1
assert_fail "[ -e '$work/marker-reopen' ]" "nor one that closes it and opens another"

finish
