# fm:sourced  # this file is sourced; see the repository lint's stdin stage
# fm:lint-source  # and it now HOLDS the option-loop corpus rule, so it
# quotes `shift 2` without having one; T-030 makes this marker per-line
# shellcheck shell=bash
# One reader for config.yaml. There were five copies of the same sed
# expression and every one of them kept the trailing comment, so
# "concurrency: 3  # workers in flight" arithmetic-errored the dispatcher the
# first time anyone ran it for real. One place to be wrong is the fix.
#
#   . bin/fm-config.sh
#   fm_cfg vendor                 -> claude
#   fm_cfg_in reviewer vendor     -> cursor-agent
#   fm_cfg_list fallback          -> one per line

_fm_clean() {   # strip an inline comment, surrounding quotes, and stray space
  sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' \
      -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

fm_default_repo() {
  if [ -n "${FM_ROOT:-}" ]; then
    printf '%s\n' "$FM_ROOT"
  elif _fm_pwd="$(pwd -P 2>/dev/null)"; then
    printf '%s\n' "$_fm_pwd"
  else
    printf '\n'
  fi
}

fm_cfg() {      # fm_cfg <key> [file]
  local f="${2:-${FM_CONFIG:-config.yaml}}"
  [ -f "$f" ] || return 1
  sed -n "s/^$1:[[:space:]]*//p" "$f" | head -1 | _fm_clean
}

fm_cfg_in() {   # fm_cfg_in <section> <key> [file]
  local f="${3:-${FM_CONFIG:-config.yaml}}"
  [ -f "$f" ] || return 1
  sed -n "/^$1:/,/^[^[:space:]#]/p" "$f" \
    | sed -n "s/^[[:space:]][[:space:]]*$2:[[:space:]]*//p" | head -1 | _fm_clean
}

fm_cfg_list() { # fm_cfg_list <section> [file]
  local f="${2:-${FM_CONFIG:-config.yaml}}"
  [ -f "$f" ] || return 1
  sed -n "/^$1:/,/^[^[:space:]#-]/p" "$f" \
    | sed -n 's/^[[:space:]]*-[[:space:]]*//p' | _fm_clean
}

# Board settings share one reader across the CLI, wizard and server (T-154).
# Configured ports are stable addresses; FM_PORT=0 is reserved for test servers.
fm_board_port() {
  local value source min=1
  if [ "${FM_PORT+x}" = x ]; then
    value="$FM_PORT"; source=FM_PORT; min=0
  else
    value="$(fm_cfg_in board port "${1:-${FM_CONFIG:-config.yaml}}" 2>/dev/null || true)"
    value="${value:-4173}"; source=board.port
  fi
  if [[ ! "$value" =~ ^[0-9]{1,5}$ ]] || [ "$((10#$value))" -lt "$min" ] || [ "$((10#$value))" -gt 65535 ]; then
    echo "fm-config: $source is not a port: '$value'" >&2; return 64
  fi
  printf '%s\n' "$((10#$value))"
}

fm_language() {
  local value
  value="$(fm_cfg language "${1:-${FM_CONFIG:-config.yaml}}" 2>/dev/null || true)"
  value="${value:-en}"
  case "$value" in
    en|zh-TW) printf '%s\n' "$value" ;;
    *) echo "fm-config: language must be en or zh-TW: '$value'" >&2; return 64 ;;
  esac
}

# The one writer (T-121), for fm setup: fm_cfg_set <dotted.key> <value> [file].
# It patches lines, it never rewrites the file: the key's own line is
# replaced, every block along the dotted path is created when missing,
# and every other line - comments, policy:, project:, projects: - is left
# exactly as it was. A file that does not exist yet is created.
fm_cfg_set() {
  local key="$1" value="$2" f="${3:-${FM_CONFIG:-config.yaml}}"
  python3 -c '
import re, sys
path, value, f = sys.argv[1].split("."), sys.argv[2], sys.argv[3]
try:
    with open(f) as fh:
        lines = fh.readlines()
except FileNotFoundError:
    lines = []
if lines and not lines[-1].endswith("\n"):
    lines[-1] += "\n"

def indent(s):
    return len(s) - len(s.lstrip(" "))

def blank(s):
    return s.strip() == "" or s.lstrip().startswith("#")

start, end, ind = 0, len(lines), 0
for depth, name in enumerate(path):
    last = depth == len(path) - 1
    found = None
    for j in range(start, end):
        if blank(lines[j]) or indent(lines[j]) != ind:
            continue
        m = re.match(r"^ *([A-Za-z0-9_.-]+):", lines[j])
        if m and m.group(1) == name:
            found = j
            break
    if found is None:
        at = start
        for j in range(start, end):
            if not blank(lines[j]):
                at = j + 1
        if start == 0 and depth == 0:
            at = len(lines)
        lines.insert(at, " " * ind + name + (": " + value if last else ":") + "\n")
        found, end = at, end + 1
    elif last:
        # only the value changes: the key'"'"'s own spacing and trailing
        # comment stay, and a value that is already this one is not touched
        m = re.match(r"^( *[A-Za-z0-9_.-]+:[ \t]*)(.*?)([ \t]+#.*)?$", lines[found].rstrip("\n"))
        if m.group(2) != value:
            lines[found] = m.group(1) + value + (m.group(3) or "") + "\n"
    if last:
        break
    start, end, ind = found + 1, found + 1, ind + 2
    while end < len(lines) and (blank(lines[end]) or indent(lines[end]) >= ind):
        end += 1
with open(f, "w") as fh:
    fh.writelines(lines)
' "$key" "$value" "$f" || return 65
}

# The vendor CLIs firstmate can crew (T-121), one per line, in the order a
# first run recommends them. One list: fm doctor, fm setup, the login probe
# and the chain's login check read it rather than each spelling it out.
fm_vendors() { printf '%s\n' claude codex cursor-agent gemini; }

_fm_code_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# The project contract: config.yaml's `project:` block, which the target
# project fills in so that nothing here has to know its toolchain.
#
#   fm_project setup|check|test [file]  -> the command, exactly as declared
#   fm_project tests|docs [file]        -> one glob per line
#   fm_project check_env [file]         -> NAME=value, each ending in NUL
#   fm_project keys [file]              -> the declared keys, one per line
#
# Values are opaque shell command strings. They are printed, never evaluated:
# quotes, `&&`, `$(...)` and `{file}` come back as written. An absent key
# prints nothing and succeeds; a malformed block, an unknown key or a `test`
# without `{file}` exits 65, because a typo that silently read as "nothing
# declared" would skip a stage and still look green. The parser is the one
# `fm-session.sh start` uses, so the two cannot disagree about the block.
fm_project() {  # fm_project <field> [file]
  python3 "$_fm_code_dir/fm-herdr.py" project "${2:-${FM_CONFIG:-config.yaml}}" "$1"
}

# The project registry (design section 15): config.yaml's `default_project`
# and `projects:` map. The directory holding config.yaml is the engine root.
#
#   fm_projects [file]                     -> registered names, one per line
#   fm_project_resolve [explicit] [file]   -> the project this run is for
#   fm_project_get <name> <field> [file]   -> repo github base required_check
#                                             design tasks, or root; tasks is
#                                             a directory (see fm_tasks)
#   fm_project_contract <name> <field> [file] -> as fm_project, for a project
#   fm_project_use [explicit] [file]       -> exports FM_PROJECT, FM_PROJECT_ROOT
#
# The project is named, never inferred: an explicit `--project` value wins,
# then FM_PROJECT, then default_project. Nothing here looks at the current
# directory, a git remote or a worktree - a run must not change project
# because a shell was somewhere else. `root` is the engine root for `repo: .`
# and FM_HOME/projects/<name>/repo otherwise.
#
# Every lookup validates the whole registry first and exits 65 naming the
# project and the field: an unregistered or malformed name, a `repo` other
# than `.`, a `github` not shaped owner/repo, a missing base or
# required_check. A config.yaml with no `projects:` map registers nothing.
#
# The contract has one source during the transition to T-050: the self entry
# (`repo: .`) resolves to T-043's top-level `project:` block, whole, read by
# the same parser fm_project uses. A self entry carrying its own `project:`
# as well as the top-level block is refused, so the two cannot disagree.
fm_projects()         { _fm_registry "${1:-${FM_CONFIG:-config.yaml}}" names; }

# The crew's permission policy (T-105, T-117): what every crew round may do,
# per role, whichever vendor runs it. The operator's own CLI settings are
# not part of it - a worker used to inherit whatever the captain's machine
# allowed, and cursor-agent ran with -f and no sandbox at all.
#
#   fm_policy worker|reviewer [project] [file] -> the resolved policy, JSON
#
# config.yaml's `policy:` block holds it, and a project's own
# `projects.<name>.policy:` overrides it; both take the same keys, flat for
# both roles or under `worker:` / `reviewer:` for one:
#
#   network:     the registries the round's commands may reach (default
#                none); a later layer replaces an earlier one
#   read:        more paths readable besides the write roots and the
#                toolchain; added to, never replacing
#   never_read:  more paths no round may read; added to
#   procs, cpu:  the process and CPU-seconds ulimits
#
# What is not a key cannot be loosened by one: the write roots (the round's
# worktree or checkout, and a TMPDIR of its own), the never-readable floor
# (~/.ssh, ~/.config/gh, cloud credentials, every vendor's home but for its
# own auth and session state, fm's state/ and the other worktrees in it),
# the refused operations
# (git push, gh, herdr, browsers, MCP), no unix sockets, the environment
# scrub, and the repository's own .claude/, .mcp.json, .cursor/ and
# GEMINI.md staying unloaded. GitHub and loopback are never a registry: a
# network naming one is refused (65), as is any key or value that does not
# read. The project is named the way fm_project_resolve names it; with no
# project registered, only the top-level block applies. Before T-105 the
# reviewer's hosts were `reviewer: network:`, which still counts when no
# policy layer declares a network.
#
# There is deliberately no key that turns the OS sandbox off: a branch can
# change config.yaml. The one escape hatch for a sandbox regression is
# FM_CREW_UNSANDBOXED=1 in the operator's own shell (fm-worker.sh,
# fm-review.sh; design 13.1).
fm_policy() { _fm_registry "${3:-${FM_CONFIG:-config.yaml}}" policy "$1" "${2:-}"; }

# fm_crew_hatch <script> -> 0, with FM_ROUND_UNSANDBOXED=1 exported, when the
#   operator's own shell set FM_CREW_UNSANDBOXED=1 and this is not a crew
#   round; 1 otherwise, with FM_ROUND_UNSANDBOXED unset whatever the caller
#   inherited. The escape hatch for a sandbox regression (T-117): the
#   adapters then run the round without the OS sandbox. It is loud on
#   stderr here; the caller says so in the round's log and on the board.
#   fm-sandbox.sh marks every round FM_IN_ROUND=1 and scrubs both names, so
#   a round - or an fm script a round starts - never takes it.
fm_crew_hatch() {
  unset FM_ROUND_UNSANDBOXED
  [ "${FM_CREW_UNSANDBOXED:-}" = 1 ] || return 1
  if [ -n "${FM_IN_ROUND:-}" ]; then
    echo "$1: FM_CREW_UNSANDBOXED is set inside a crew round; the escape hatch is the operator's, not a round's - ignoring it" >&2
    return 1
  fi
  FM_ROUND_UNSANDBOXED=1; export FM_ROUND_UNSANDBOXED
  echo "$1: !!! FM_CREW_UNSANDBOXED=1: this round runs WITHOUT the OS sandbox; unset it once the sandbox is fixed !!!" >&2
}

# --- Apple's xcrun shims (T-147) ---------------------------------------------
# On macOS /usr/bin/git, /usr/bin/python3 and the other developer tools are
# not the tools: each is a small launcher, linked against libxcselect, that
# asks xcrun for the real one in the active developer directory. Inside a
# round it cannot work. xcrun writes its cache (xcrun_db-*) under the
# per-user temp directory confstr names, which no round may write, and with
# the Xcode licence not accepted it then stops on that (the codex rounds of
# T-146 and T-157, 2026-09-29/30). fm-sandbox.sh asks these, outside the
# round, for each tool a round would reach first on its PATH; `fm doctor`
# reports a machine whose first git or python3 on PATH is a shim.
# shellcheck disable=SC2034  # read by the scripts that source this file
FM_XCRUN_TOOLS="git python3 pip3 make cc clang"

# fm_xcrun_shim <file> -> 0 when <file> is one of Apple's xcrun shims
fm_xcrun_shim() { [ -f "${1:-}" ] && LC_ALL=C grep -q libxcselect "$1" 2>/dev/null; }

# fm_path_tool <tool> <PATH> -> the first executable <tool> on that PATH, as
# a shell would find it; 1 when there is none
fm_path_tool() {
  local rest="${2-}:" d
  while [ -n "$rest" ]; do
    d="${rest%%:*}"; rest="${rest#*:}"
    [ -n "$d" ] && [ -f "$d/$1" ] && [ -x "$d/$1" ] && { printf '%s\n' "$d/$1"; return 0; }
  done
  return 1
}

# fm_xcrun_resolve <tool> -> `real<TAB><path>`: the tool the shim would run,
#   found by xcrun itself, outside any round, so it can be run directly; or
#   `none<TAB><why>` (exit 1) when there is none to run - no developer
#   directory at all (asked of xcode-select first, which never opens the
#   installer dialog a shim would), or what xcrun said, the licence
#   refusal included. FM_XCODE_SELECT and FM_XCRUN name stand-ins for the
#   suites.
fm_xcrun_resolve() {
  local xs="${FM_XCODE_SELECT:-/usr/bin/xcode-select}" xc="${FM_XCRUN:-/usr/bin/xcrun}" out real why
  if ! "$xs" -p </dev/null >/dev/null 2>&1; then
    printf 'none\tno Xcode or Command Line Tools is installed, so the shim has no %s to run\n' "$1"
    return 1
  fi
  out="$("$xc" --find "$1" </dev/null 2>&1)"
  real="$(printf '%s\n' "$out" | grep '^/' | tail -1)"
  if [ -n "$real" ] && [ -f "$real" ] && [ -x "$real" ] && ! fm_xcrun_shim "$real"; then
    printf 'real\t%s\n' "$real"; return 0
  fi
  why="$(printf '%s\n' "$out" | grep -v '^/' | grep -v '^[[:space:]]*$' | tail -1 | tr '\t' ' ')"
  why="${why%.}"
  printf 'none\txcrun cannot find it: %s\n' "${why:-it named no $1}"
  return 1
}

# fm_xcrun_fix <tool> -> how the operator gives a round a real <tool>
fm_xcrun_fix() {
  local pkg="$1"
  case "$1" in python3|pip3) pkg=python ;; cc|clang) pkg=llvm ;; esac
  printf 'install %s ahead of /usr/bin on PATH (brew install %s), or accept the Xcode licence outside the round (sudo xcodebuild -license)\n' "$1" "$pkg"
}

# fm_policy_blocked <file> -> each host a round's proxy refused, once
fm_policy_blocked() { [ -s "${1:-}" ] || return 0; awk 'NF && !seen[$0]++' "$1"; }

# fm_policy_report <repo> <role> <task> <actor> <file> [policy] -> the
#   refused hosts, on one line, and one record of them appended to
#   state/policy/blocked-hosts.jsonl. A round is never given a host it was
#   refused: firstmate reads the record and raises a choice card to add it
#   to the project's `policy: network:`, and only the captain's answer
#   changes the policy. One JSON object per line:
#     at        when the round ended, UTC
#     task, role, actor
#     project   the project whose policy the round ran under ('' for none)
#     hosts     each refused host once, in the order it was first refused
#     declared  the registries the round had
#     add_to    the config.yaml key a card would add a host to:
#               projects.<name>.policy.network, or policy.network
#     source    proxy: fm's own proxy refused them (design 13.1 names what
#               it cannot see)
#     expected  the refused hosts the policy's known_refused list names
#               (T-147): refused to every round by the captain's decision,
#               so never a card; kept apart from hosts
# A host on the policy's known_refused list is not an unexplained refusal:
# it is said once, on stderr, as a known and expected one, and is left out
# of the hosts printed and of the record's hosts, so no card offers it.
fm_policy_report() {
  local all hosts='' expected='' project='' declared='[]' known='[]' kind h what
  all="$(fm_policy_blocked "$5" | tr '\n' ' ' | sed 's/ $//')"
  [ -n "$all" ] || return 0
  if [ -n "${6:-}" ] && [ -r "$6" ]; then
    project="$(jq -r '.project // ""' "$6" 2>/dev/null)"
    declared="$(jq -c '.network // []' "$6" 2>/dev/null)" || declared='[]'
    known="$(jq -c '.known_refused // []' "$6" 2>/dev/null)" || known='[]'
  fi
  # one line per round for each kind of known refusal, however many of its
  # hosts the round was refused. A policy that does not classify leaves
  # every host undeclared, as before.
  while IFS='|' read -r kind h what; do
    case "$kind" in
      undeclared) hosts="${hosts:+$hosts }$h" ;;
      known)
        expected="${expected:+$expected }${h//,/}"
        printf 'fm: known refusal, expected: %s - %s; refused for every vendor, nothing to add\n' \
          "$h" "$what" >&2 ;;
    esac
  done < <(jq -rn --arg all "$all" --argjson k "${known:-[]}" '
    [$all | split(" ")[] | . as $h
     | {h: $h, what: (first($k[] | select(.pattern as $p | $h | ascii_downcase | test("^(" + $p + ")$")) | .what) // "")}]
    | (.[] | select(.what == "") | "undeclared|" + .h),
      (map(select(.what != "")) | group_by(.what)[] | "known|" + (map(.h) | join(", ")) + "|" + .[0].what)' \
    2>/dev/null || printf '%s\n' "$all" | tr ' ' '\n' | sed 's/^/undeclared|/')
  [ -n "$hosts" ] || return 0
  mkdir -p "${FM_STATE_DIR:-$1/state}/policy" &&
    jq -cn --arg role "$2" --arg task "$3" --arg actor "$4" --arg hosts "$hosts" \
      --arg expected "$expected" \
      --arg project "$project" --argjson declared "${declared:-[]}" \
      --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{at:$at, task:$task, role:$role, actor:$actor, project:$project,
        hosts:($hosts | split(" ")), declared:$declared,
        add_to:(if $project == "" then "policy.network" else "projects.\($project).policy.network" end),
        source:"proxy", expected:($expected | split(" ") | map(select(. != "")))}' \
      >> "${FM_STATE_DIR:-$1/state}/policy/blocked-hosts.jsonl"
  printf '%s\n' "$hosts"
}
fm_project_resolve()  { _fm_registry "${2:-${FM_CONFIG:-config.yaml}}" resolve "${1:-}"; }
fm_project_get()      { _fm_registry "${3:-${FM_CONFIG:-config.yaml}}" field "$1" "$2"; }
fm_project_contract() { _fm_registry "${3:-${FM_CONFIG:-config.yaml}}" contract "$1" "$2"; }
fm_project_use() {
  local name root
  name="$(fm_project_resolve "${1:-}" "${2:-${FM_CONFIG:-config.yaml}}")" || return
  root="$(fm_project_get "$name" root "${2:-${FM_CONFIG:-config.yaml}}")" || return
  FM_PROJECT="$name"; FM_PROJECT_ROOT="$root"
  export FM_PROJECT FM_PROJECT_ROOT
}

_fm_registry() {  # _fm_registry <file> <mode> [args...]
  python3 - "$_fm_code_dir/fm-herdr.py" "$@" <<'PY'
import getpass, importlib.util, json, os, re, sys, tempfile
from pathlib import Path

herdr_path, config, mode, *args = sys.argv[1:]
# the one scalar and contract parser, fm_project's; needed only when there is a
# config to parse, so a tree with no config.yaml registers nothing without it
herdr = None
if Path(config).is_file():
    if not Path(herdr_path).is_file():
        print('fm-config: cannot read the registry: no fm-herdr.py beside fm-config.sh (%s)' % herdr_path,
              file=sys.stderr); sys.exit(65)
    spec = importlib.util.spec_from_file_location('fm_herdr', herdr_path)
    herdr = importlib.util.module_from_spec(spec); spec.loader.exec_module(herdr)
FIELDS = ('repo', 'github', 'base', 'required_check', 'design', 'tasks', 'project', 'policy')
NAME = re.compile(r'[a-z0-9-]{1,24}$')
GITHUB = re.compile(r'[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?/[A-Za-z0-9._-]+$')


class Refused(Exception):
    pass


def refuse(name, field, why):
    raise Refused('project %s: %s %s' % (name, field, why))


def indent(line):
    return len(line) - len(line.lstrip(' '))


def top_block(lines, key):
    """The lines under a column-0 `key:`; None when the key is absent."""
    block, inside, found = [], False, None
    for raw in lines:
        if not inside:
            if re.match(re.escape(key) + r':\s*(#.*)?$', raw):
                inside, found = True, block
            continue
        if not raw.strip() or raw.lstrip().startswith('#'): continue
        if not raw[:1].isspace(): break
        block.append(raw.expandtabs(8))
    return found


def contract_of(name, lines, key):
    """An entry's nested project: block, read by fm_project's parser."""
    with tempfile.NamedTemporaryFile('w', suffix='.yaml') as block:
        block.write('project:\n' + ''.join(line + '\n' for line in lines))
        block.flush()
        try:
            return herdr.project_field(block.name, key) if key else herdr.project_contract(block.name)
        except ValueError as error:
            refuse(name, 'project', str(error).replace('config.yaml ', ''))


def load(path):
    path = Path(path)
    if not path.is_file(): return None, {}, False
    lines = path.read_text().splitlines()
    default = None
    for raw in lines:
        found = re.match(r'default_project:(?:\s+(.*))?$', raw)
        if found:
            default = herdr._project_scalar(found.group(1) or '', 'config.yaml default_project')
            break
    block = top_block(lines, 'projects') or []
    projects, order, i = {}, [], 0
    level = indent(block[0]) if block else 0
    while i < len(block):
        line = block[i]
        found = re.match(r'\s*([^\s:#][^:]*):\s*(#.*)?$', line)
        if indent(line) != level or not found:
            raise Refused('projects: cannot read line: ' + line.strip())
        name = found.group(1).strip()
        if not NAME.match(name):
            refuse(name, 'name', 'must be [a-z0-9-], at most 24 characters')
        if name in projects: refuse(name, 'name', 'is registered twice')
        entry, i = {}, i + 1
        children = []
        while i < len(block) and indent(block[i]) > level:
            children.append(block[i]); i += 1
        j = 0
        while j < len(children):
            line = children[j]; own = indent(line)
            found = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*):(?:\s+(.*))?$', line)
            if not found: refuse(name, 'entry', 'cannot read line: ' + line.strip())
            key, value = found.group(1), (found.group(2) or '').strip()
            if key not in FIELDS: refuse(name, key, 'is not a registry field (known: ' + ', '.join(FIELDS) + ')')
            if key in entry: refuse(name, key, 'is given twice')
            nested = []
            j += 1
            while j < len(children) and indent(children[j]) > own:
                nested.append(children[j]); j += 1
            if key in ('project', 'policy'):
                if value and not value.startswith('#'): refuse(name, key, 'must be a block, as in T-043')
                entry[key] = nested
            else:
                if nested: refuse(name, key, 'must be a one-line value')
                entry[key] = herdr._project_scalar(value, 'config.yaml projects.%s.%s' % (name, key))
        projects[name] = entry; order.append(name)
    has_top = top_block(lines, 'project') is not None
    for name in order:
        entry = projects[name]
        if 'repo' in entry and entry['repo'] != '.':
            refuse(name, 'repo', "must be . or absent (a committed local path would publish it), not '%s'" % entry['repo'])
        if not GITHUB.match(entry.get('github', '')) or entry['github'].split('/')[1] in ('.', '..'):
            refuse(name, 'github', "must be shaped owner/repo, not '%s'" % entry.get('github', ''))
        for key in ('base', 'required_check'):
            if not entry.get(key): refuse(name, key, 'is required')
        for key in ('design', 'tasks'):
            value = entry.get(key)
            if value is None: continue
            if not value or value.startswith('/') or '..' in Path(value).parts:
                refuse(name, key, "must be a path relative to the engine root, not '%s'" % value)
        if has_top and entry.get('repo') == '.' and 'project' in entry:
            refuse(name, 'project', 'is also declared by the top-level project: block; '
                   'until T-050 the contract lives only there')
        if 'project' in entry: contract_of(name, entry['project'], None)
        if 'policy' in entry: policy_layer(entry['policy'], 'projects.%s.policy' % name)
    selves = [name for name in order if projects[name].get('repo') == '.']
    if len(selves) > 1:
        refuse(selves[1], 'repo', 'is . for %s as well; only one project is the engine itself' % selves[0])
    return default, projects, has_top


# --- the crew's permission policy (T-105, T-117; see fm_policy above) -----
ROLES = ('worker', 'reviewer')
POLICY_KEYS = ('network', 'read', 'never_read', 'procs', 'cpu')
# every dimension a round is confined in; an adapter enforces some with its
# CLI's own flags and bin/fm-sandbox.sh the rest, or the adapter refuses
DIMENSIONS = ['write', 'read', 'network', 'sockets', 'env', 'repo-config', 'refuse', 'ulimit']
# readable besides the write roots: what running a toolchain needs, and no
# home directory as a whole
TOOLCHAIN = ['/usr', '/bin', '/sbin', '/opt', '/etc', '/private/etc', '/dev', '/System',
             '/Library/Developer', '/Library/Frameworks', '/Library/Java', '/Library/Apple',
             '/Applications/Xcode.app', '/private/var/db/timezone', '/private/var/select',
             '/lib', '/lib32', '/lib64', '/nix', '/snap',
             '~/.local/bin', '~/.local/share/claude', '~/.local/share/cursor-agent',
             '~/.bun/bin', '~/.nvm', '~/.volta', '~/.cargo/bin', '~/.rustup', '~/.pyenv',
             '~/.local/share/mise', '~/.deno/bin', '~/go/bin']
# never readable, whatever a layer adds to `read`. {state} is fm's state/,
# which holds every other worktree; the round's own worktree is a write
# root and stays reachable
NEVER_READ = ['~/.ssh', '~/.gnupg', '~/.netrc', '~/.git-credentials', '~/.config/gh',
              '~/.aws', '~/.azure', '~/.config/gcloud', '~/.docker', '~/.kube',
              '~/.npmrc', '~/.pypirc', '~/.config/herdr',
              '~/.claude', '~/.claude.json', '~/.codex', '~/.cursor', '~/.config/cursor',
              '~/.gemini', '~/.config/firstmate', '{state}']
# Each vendor's home is never readable as a whole: it holds the operator's
# settings, hooks, skills and MCP servers as well as the login. Its round
# gets back only what it needs to start and sign in (design 13.1 names each
# one and why):
#
#   auth   files readable only, in place. No vendor has one: every login
#          file holds a refresh token, so fm reads it and hands in a copy
#          without one (login.copy below)
#   state  what the CLI writes as it runs - session files, logs, caches and
#          the one config file it rewrites - readable and writable, each
#          entry a prefix, so a file rewritten through x.tmp.123 or x.lock
#          stays writable too. None of it is a credential or a setting.
#   tmp    directories the CLI keeps under the system's /tmp whatever
#          TMPDIR says, readable and writable. Only macOS needs them: on
#          Linux the round's /tmp is a fresh one of its own.
#   login  the login fm reads OUTSIDE the round and hands in, because the
#          round cannot reach where the operator's login keeps it (T-117):
#            keychain  generic-password items, by service and account,
#                      read on macOS with security(1); the keychain itself
#                      stays out of every round's reach
#            secret    libsecret items, by service and account, read with
#                      secret-tool(1) when it is on the operator's PATH -
#                      the keychain's rough equivalent off macOS (T-126);
#                      tried only when no keychain item answered, and
#                      skipped, not refused, when secret-tool is absent
#            file      files read when neither a keychain nor a secret
#                      item is there
#            private   the file must be the operator's alone (no group or
#                      other bits), or it is no login
#            field     the JSON field of the value that is the token; none,
#                      and the whole value is
#            expires   the JSON field saying when it expires, in ms; a
#                      login past it is no login
#            given     variables that, set in the operator's environment,
#                      already carry a login, so nothing is read
#            to        env:<NAME>, the token handed in as that variable
#            hint      what the operator does once when there is no login,
#                      said with the refusal
#            copy     for a login read from a file: the path, under the
#                      round's own temp directory, where fm writes that
#                      file with `drop` emptied, for the adapter to point
#                      the CLI at (T-117 round 2)
#            drop      the JSON fields of that file that are its refresh
#                      token, emptied in the copy
#            fallback  a second tier, tried only when this one names
#                      nothing at all - no keychain item, no file - never
#                      when it is refused for a reason (a locked-down
#                      file, an expired or malformed token, which stop the
#                      round rather than quietly trying something weaker).
#                      Its own keychain/file/field/expires/private, same
#                      meaning; it shares this tier's `to`. Used, it warns
#                      (T-126): claude's round has no crew token of its
#                      own and so signs in with the operator's own
#                      interactive login instead, which that operator's
#                      own Claude sessions can revoke out from under a
#                      round still holding it by refreshing their login -
#                      exactly what killed T-125's worker and T-123's
#                      reviewer on 2026-09-27.
#          Only an access token is handed in, never a refresh token: a
#          round that refreshed a login would rotate the operator's out
#          from under them, and one that could not write the refreshed
#          login back would leave the operator's spent. fm-sandbox.sh
#          refuses a copy that still holds any refresh_token field.
#   hosts  the vendor's own service: the whole CLI runs inside the OS
#          sandbox, so its API has to be reachable through the round's proxy
#
# {uid} and {user} are the operator's.
VENDORS = {
    # A round's claude has a config directory of its own (CLAUDE_CONFIG_DIR,
    # in the round's temp directory), so ~/.claude and ~/.claude.json are
    # not opened at all. Its login (T-126) is, in order: a
    # CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY already in the
    # operator's environment, used as is; else the crew's own long-lived
    # token, made once with `claude setup-token`
    # (https://code.claude.com/docs/en/authentication) and kept the way
    # T-117 keeps cursor-agent's Cursor key - a keychain item of fm's own
    # on macOS, a libsecret item of fm's own where secret-tool is present
    # (Linux, T-126 round 2), else a file only the operator can read; only
    # when none of those exists does it fall back to the access token of
    # the operator's own interactive login, with a warning (see `fallback`
    # above) that this can die when that login refreshes.
    'claude': dict(auth=[], state=[], tmp=['/tmp/claude-{uid}'],
                   login=dict(keychain=[dict(service='firstmate-claude-token', account='{user}')],
                              secret=[dict(service='firstmate-claude-token', account='{user}')],
                              file=['~/.config/firstmate/claude-token'], private=True,
                              given=['CLAUDE_CODE_OAUTH_TOKEN', 'ANTHROPIC_API_KEY'],
                              to='env:CLAUDE_CODE_OAUTH_TOKEN',
                              hint='make a long-lived crew token (claude setup-token; one year, model '
                                   'requests only, https://code.claude.com/docs/en/authentication) and keep '
                                   'it for the crew once, outside any round: security add-generic-password '
                                   '-s firstmate-claude-token -a "$USER" -w on macOS (it asks for the token), '
                                   'secret-tool store --label=firstmate-claude-token service '
                                   'firstmate-claude-token account "$USER" on Linux with libsecret, or write '
                                   'it to ~/.config/firstmate/claude-token with mode 600; revoke it at '
                                   'claude.ai, Settings, Claude Code',
                              fallback=dict(keychain=[dict(service='Claude Code-credentials', account='{user}')],
                                            file=['~/.claude/.credentials.json'],
                                            field='claudeAiOauth.accessToken',
                                            expires='claudeAiOauth.expiresAt')),
                   hosts=['anthropic.com', 'claude.ai']),
    # codex's login file holds its refresh token beside the access token.
    # The round's CODEX_HOME is its own, and holds a copy without it.
    'codex': dict(auth=[],
                  state=['~/.codex/sessions', '~/.codex/log', '~/.codex/history.jsonl',
                         '~/.codex/version.json', '~/.codex/models_cache.json'],
                  tmp=[],
                  login=dict(file=['~/.codex/auth.json'], field=['tokens.access_token', 'OPENAI_API_KEY'],
                             drop=['tokens.refresh_token'], given=['CODEX_API_KEY'],
                             copy='codex-home/auth.json'),
                  hosts=['openai.com', 'chatgpt.com']),
    # cursor-agent reads `agent login`'s token through the keychain API,
    # which no round reaches and nothing on the round's PATH can answer for
    # (the canary, 2026-09-26: a security(1) stand-in was never asked). So
    # its round signs in with a Cursor API key the operator makes once for
    # the crew, kept by fm outside every round - a keychain item of fm's own
    # on macOS, else a file only the operator can read - and handed in as
    # CURSOR_API_KEY, the variable cursor-agent documents. Neither `agent
    # login`'s items nor ~/.config/cursor are read, so no refresh token of
    # cursor's is anywhere near a round.
    'cursor-agent': dict(auth=[],
                         state=['~/.cursor/chats', '~/.cursor/projects', '~/.cursor/cli-config.json',
                                '~/.cursor/statsig-cache.json'],
                         tmp=[],
                         login=dict(keychain=[dict(service='firstmate-cursor-api-key', account='{user}')],
                                    file=['~/.config/firstmate/cursor-api-key'], private=True,
                                    given=['CURSOR_API_KEY'], to='env:CURSOR_API_KEY',
                                    hint='make a Cursor API key (cursor.com, Settings, API keys) and keep it '
                                         'for the crew once, outside any round: '
                                         'security add-generic-password -s firstmate-cursor-api-key '
                                         '-a "$USER" -w (it asks for the key), or write it to '
                                         '~/.config/firstmate/cursor-api-key with mode 600'),
                         hosts=['cursor.sh', 'cursor.com']),
    # gemini's login file holds its refresh token too. The round's gemini
    # runs with a HOME of its own, whose .gemini holds a copy without it.
    'gemini': dict(auth=[],
                   state=['~/.gemini/tmp', '~/.gemini/history', '~/.gemini/google_accounts.json',
                          '~/.gemini/installation_id', '~/.gemini/user_id'],
                   tmp=[],
                   login=dict(file=['~/.gemini/oauth_creds.json'], field='access_token', expires='expiry_date',
                              drop=['refresh_token'], given=['GEMINI_API_KEY', 'GOOGLE_API_KEY'],
                              copy='gemini-home/.gemini/oauth_creds.json'),
                   hosts=['googleapis.com']),
}
REFUSE = ['git push', 'gh', 'herdr', 'browser', 'mcp']
# FM_CREW_UNSANDBOXED and FM_ROUND_UNSANDBOXED are the operator's escape
# hatch (design 13.1): never a round's, so a nested fm run inside one
# cannot switch its own sandbox off
SCRUB = dict(names=['GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN',
                    'SSH_AUTH_SOCK', 'SSH_AGENT_PID', 'GOOGLE_APPLICATION_CREDENTIALS',
                    'DISPLAY', 'WAYLAND_DISPLAY', 'DBUS_SESSION_BUS_ADDRESS', 'BROWSER',
                    'FM_CREW_UNSANDBOXED', 'FM_ROUND_UNSANDBOXED'],
             prefixes=['AWS_', 'AZURE_', 'ARM_', 'CLOUDSDK_', 'GCLOUD_', 'DIGITALOCEAN_', 'HERDR_'])
REPO_CONFIG = ['.claude', '.mcp.json', '.cursor', 'GEMINI.md']
GITHUB_DOMAINS = ('github.com', 'github.io', 'github.dev', 'githubusercontent.com', 'githubassets.com',
                  'githubapp.com', 'githubcopilot.com', 'ghcr.io', 'ghe.com')
# Hosts refused to every round, for every vendor, whatever a policy
# declares, because the captain decided what they are (T-147, 2026-09-29).
# Each is a full-match regex and what the host is. The list rides in the
# policy as `known_refused`, so the round's proxy (bin/fm-sandbox.sh) and
# the report of what it refused (fm_policy_report) read this one list.
#   sdmntpr<region>.oaiusercontent.com is OpenAI's user file store: paths
#   under files/, which the Codex SDK and ChatGPT's file features use. A
#   round's model conversation does not need it - the codex round it was
#   refused to on 2026-09-29 exited 0 and talked to the model - and it
#   would be an upload channel out of the round.
KNOWN_REFUSED = [
    dict(pattern=r'sdmntpr[a-z0-9-]*\.oaiusercontent\.com',
         what="OpenAI's user file store, which no round needs and which would be an upload channel "
              "out of it (design 13.1, T-147)"),
]


def known_refusal(host):
    """What <host> is, when it is one every round is refused, or None."""
    h = host.lower().rstrip('.')
    for k in KNOWN_REFUSED:
        if re.fullmatch(k['pattern'], h):
            return k['what']
    return None


def host_refusal(host):
    """Why a round may not reach <host>, or None. The same rule as
    fm_review_host_refusal in bin/adapters/_lib.sh, plus loopback: a plain
    domain name, never GitHub's, never localhost, never an address."""
    if not re.match(r'[A-Za-z0-9.-]+$', host) or host.startswith('.') or host.endswith('.') or '..' in host:
        return 'is not a plain domain name'
    h = host.lower()
    for d in GITHUB_DOMAINS:
        if h == d or h.endswith('.' + d):
            return 'is a GitHub host; a crew round may not reach GitHub'
    if h == 'localhost' or h.endswith('.localhost'):
        return 'is loopback; a crew round may not reach loopback'
    if re.match(r'[0-9.]+$', h):
        return 'is an address; a registry is named, and loopback is never one'
    what = known_refusal(h)
    if what:
        return 'is %s; it is refused for every vendor' % what
    return None


def policy_map(lines, where):
    """A nested block of `key: value` lines -> a dict; comments already gone."""
    out, i = {}, 0
    level = indent(lines[0]) if lines else 0
    while i < len(lines):
        line = lines[i]
        found = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*):(?:\s+(.*))?$', line)
        if indent(line) != level or not found:
            raise Refused('%s: cannot read line: %s' % (where, line.strip()))
        key = found.group(1)
        value = re.sub(r'(^|\s)#.*$', '', found.group(2) or '').strip()
        if key in out: raise Refused('%s: %s is given twice' % (where, key))
        i += 1; kids = []
        while i < len(lines) and indent(lines[i]) > level:
            kids.append(lines[i]); i += 1
        if kids and value: raise Refused('%s: %s has a value and a block' % (where, key))
        out[key] = policy_map(kids, where + '.' + key) if kids else value
    return out


def policy_layer(lines, where):
    """One layer, checked: flat keys for both roles, a block per role."""
    layer = policy_map(lines or [], where)
    for key, value in layer.items():
        if key in ROLES:
            if not isinstance(value, dict):
                raise Refused('%s.%s: must be a block of policy keys' % (where, key))
            for sub, v in value.items():
                policy_value(sub, v, '%s.%s' % (where, key))
        else:
            policy_value(key, value, where)
    return layer


def policy_value(key, value, where):
    if key not in POLICY_KEYS:
        raise Refused('%s: %s is not a policy key (known: %s)' % (where, key, ', '.join(POLICY_KEYS)))
    if isinstance(value, dict):
        raise Refused('%s.%s: must be a one-line value' % (where, key))
    if key == 'network':
        for host in value.split():
            why = host_refusal(host)
            if why: raise Refused('%s.network: names %s, which %s' % (where, host, why))
    elif key in ('read', 'never_read'):
        for path in value.split():
            if not (path.startswith('/') or path == '~' or path.startswith('~/')) \
                    or any(c in path for c in '"\\()*?[]'):
                raise Refused("%s.%s: '%s' is not an absolute path a sandbox profile can hold"
                              % (where, key, path))
    elif not re.match(r'[1-9][0-9]*$', value):
        raise Refused("%s.%s: must be a positive whole number, not '%s'" % (where, key, value))


def operator(text):
    return text.replace('{uid}', str(os.getuid())).replace('{user}', getpass.getuser())


def expand(path, engine):
    return os.path.realpath(os.path.expanduser(operator(path).replace('{state}', str(engine / 'state'))))


def vendor_of(d, engine):
    login = dict(d['login'])
    if login:
        login['keychain'] = [dict(service=k['service'], account=operator(k['account']))
                             for k in login.get('keychain', [])]
        login['secret'] = [dict(service=k['service'], account=operator(k['account']))
                           for k in login.get('secret', [])]
        login['file'] = [expand(p, engine) for p in login.get('file', [])]
        if login.get('fallback'):
            fallback = dict(login['fallback'])
            fallback['keychain'] = [dict(service=k['service'], account=operator(k['account']))
                                    for k in fallback.get('keychain', [])]
            fallback['secret'] = [dict(service=k['service'], account=operator(k['account']))
                                  for k in fallback.get('secret', [])]
            fallback['file'] = [expand(p, engine) for p in fallback.get('file', [])]
            login['fallback'] = fallback
    return dict(auth=[expand(p, engine) for p in d['auth']],
                state=[expand(p, engine) for p in d['state']],
                tmp=[expand(p, engine) for p in d['tmp']],
                login=login, hosts=d['hosts'])


def resolve_policy(lines, projects, default, config, role, explicit):
    if role not in ROLES:
        raise Refused("policy: the role is worker or reviewer, not '%s'" % role)
    engine = Path(config).resolve().parent
    name = explicit or os.environ.get('FM_PROJECT', '') or default or ''
    layers = [policy_layer(top_block(lines, 'policy'), 'policy')]
    if name and projects:
        layers.append(policy_layer(registered(projects, name).get('policy', []),
                                   'projects.%s.policy' % name))
    got = dict(read=list(TOOLCHAIN), never_read=list(NEVER_READ), procs='2048', cpu='14400')
    for layer in layers:
        for scope in (layer, layer.get(role) or {}):
            for key, value in scope.items():
                if key in ROLES: continue
                if key in ('read', 'never_read'): got[key] += value.split()
                else: got[key] = value
    if 'network' not in got and role == 'reviewer':
        # the pre-T-105 place for the reviewer's hosts
        legacy = policy_map(top_block(lines, 'reviewer') or [], 'reviewer').get('network', '')
        if isinstance(legacy, str):
            for host in legacy.split():
                why = host_refusal(host)
                if why: raise Refused('reviewer.network: names %s, which %s' % (host, why))
            got['network'] = legacy
    return dict(
        role=role, project=name if projects else '', dimensions=DIMENSIONS,
        # {tmp} is the round's own temp directory, which fm-sandbox.sh
        # makes; never the shared one, and never /tmp
        write=['{root}', '{tmp}'],
        read=[expand(p, engine) for p in got['read']],
        never_read=[expand(p, engine) for p in got['never_read']],
        network=got.get('network', '').split(),
        known_refused=KNOWN_REFUSED,
        refuse=REFUSE, sockets='none', env_scrub=SCRUB, repo_config=REPO_CONFIG,
        procs=int(got['procs']), cpu=int(got['cpu']),
        vendors={v: vendor_of(d, engine) for v, d in VENDORS.items()})


def registered(projects, name):
    if not NAME.match(name): refuse(name, 'name', 'must be [a-z0-9-], at most 24 characters')
    if name not in projects:
        refuse(name, 'name', 'is not registered in config.yaml (registered: %s)'
               % (', '.join(projects) or 'none'))
    return projects[name]


def field(projects, name, key, config):
    entry = registered(projects, name)
    engine = Path(config).resolve().parent
    if key in ('home', 'root', 'state', 'worktrees', 'design', 'tasks', 'conventions'):
        if entry.get('repo') == '.':
            paths = dict(home=str(engine), root=str(engine), state=str(engine / 'state'),
                         worktrees=str(engine / 'state/worktrees'),
                         design=entry.get('design') or 'design/design.md',
                         tasks=entry.get('tasks') or 'design/tasks',
                         conventions=str(engine / 'CONVENTIONS.md'))
            return paths[key]
        path_module = Path(herdr_path).parent / 'lib/fm_project_paths.py'
        spec = importlib.util.spec_from_file_location('fm_project_paths', path_module)
        paths = importlib.util.module_from_spec(spec); spec.loader.exec_module(paths)
        configured = ''
        for raw in Path(config).read_text().splitlines():
            match = re.match(r'home:(?:\s+(.*))?$', raw)
            if match: configured = herdr._project_scalar(match.group(1) or '', 'home')
        home = paths.external_home(engine, name, configured)
        child = dict(home='', root='repo', state='state', worktrees='worktrees',
                     design='design.md', tasks='tasks', conventions='CONVENTIONS.md')[key]
        return str(home / child)
    if key in ('repo', 'github', 'base', 'required_check'):
        return entry.get(key, '')
    refuse(name, key, 'is not a registry field')


try:
    default, projects, has_top = load(config)
    if mode == 'names':
        for name in projects: print(name)
    elif mode == 'resolve':
        explicit = args[0] if args else ''
        name = explicit or os.environ.get('FM_PROJECT', '') or default or ''
        if not name:
            raise Refused('no project named: pass --project, set FM_PROJECT or declare default_project')
        registered(projects, name); print(name)
    elif mode == 'field':
        print(field(projects, args[0], args[1], config))
    elif mode == 'contract':
        name, key = args
        entry = registered(projects, name)
        if entry.get('repo') == '.' and has_top:
            try: rc = herdr.project_field(config, key)
            except ValueError as error:
                refuse(name, 'project', str(error).replace('config.yaml ', ''))
        else:
            rc = contract_of(name, entry.get('project', []), key)
        sys.exit(rc)
    elif mode == 'policy':
        lines = Path(config).read_text().splitlines() if Path(config).is_file() else []
        print(json.dumps(resolve_policy(lines, projects, default, config, args[0], args[1] if len(args) > 1 else ''),
                         indent=1))
    else:
        raise Refused('unknown registry mode ' + mode)
except Refused as error:
    print('fm-config: ' + str(error), file=sys.stderr); sys.exit(65)
except ValueError as error:
    print('fm-config: ' + str(error), file=sys.stderr); sys.exit(65)
PY
}

# The task list (T-090): one file per task, design/tasks/<id>.json, holding
# that task's entry and nothing else. It was one array in design/tasks.json
# plus a hand-kept copy in design.md, so every pull request appended to the
# same two places and every merge made every other open one a conflict.
# Adding a task adds a file; revising one edits only its file. Every reader
# goes through these, the board included.
#
#   fm_tasks [dir] [rev]            -> every task, one compact JSON per line,
#                                      in id order, H-2 before H-10; all or
#                                      nothing: 1, with no list, when any
#                                      file does not read or the directory
#                                      is not there
#   fm_task <id> [dir] [rev]        -> that task's entry; 1 when it has none
#   fm_tasks_write <file> [dir]     -> one file per entry of a {"tasks":[...]},
#                                      an array, or a single task
#   fm_tasks_check [dir]            -> one problem per line; 1 when any
#
# <dir> defaults to design/tasks. <rev> reads a commit or branch instead of
# the working copy: the gate, the worker and the reviewer read the branch
# under test, which is how a task defined on its own branch is seen at all.
# A name starting with a dot (.DS_Store, a scratch directory) is not a task.
_fm_task_id() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; }

# One task file's text -> its entry on one line; 1 unless it is exactly
# one JSON object. An empty file is not an empty task.
_fm_task_line() { jq -cs 'if length == 1 and (.[0] | type) == "object" then .[0] else error("not one task") end' 2>/dev/null; }

fm_tasks() {
  local dir="${1:-design/tasks}" rev="${2:-}" f names out='' line
  if [ -n "$rev" ]; then
    names="$(git ls-tree --name-only --full-tree "$rev" -- "$dir/" 2>/dev/null)" \
      || { echo "fm-config: cannot read $dir/ on $rev" >&2; return 1; }
    [ -n "$names" ] || { echo "fm-config: $rev has no $dir/" >&2; return 1; }
  else
    [ -d "$dir" ] || { echo "fm-config: $dir is not a directory" >&2; return 1; }
    names="$(find "$dir" -maxdepth 1 -type f -name '*.json' ! -name '.*' 2>/dev/null)" \
      || { echo "fm-config: cannot list $dir" >&2; return 1; }
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "${f##*/}" in .*) continue ;; *.json) ;; *) continue ;; esac
    # read into a string first: `git show | jq` hides a show that failed
    # behind jq's success on empty input, and a task would just vanish
    if [ -n "$rev" ]; then
      line="$(git show "$rev:$f" 2>/dev/null)" && line="$(printf '%s' "$line" | _fm_task_line)"
    else
      line="$(_fm_task_line < "$f")"
    fi || { echo "fm-config: $f does not read as one task; no task list" >&2; return 1; }
    out="$out$line
"
  done <<< "$(printf '%s\n' "$names" | LC_ALL=C sort -V)"
  printf '%s' "$out"
}

# Read only the task's own file, on the requested revision or working tree.
fm_task() {
  local id="${1:-}" dir="${2:-design/tasks}" rev="${3:-}" j
  _fm_task_id "$id" || return 1
  if [ -n "$rev" ]; then
    j="$(git show "$rev:$dir/$id.json" 2>/dev/null)" || return 1
  else
    j="$(cat "$dir/$id.json" 2>/dev/null)" || return 1
  fi
  # a file whose id is another task's is not this task
  j="$(printf '%s' "$j" | jq --arg id "$id" 'select(type=="object" and .id==$id)' 2>/dev/null)"
  [ -n "$j" ] || return 1
  printf '%s\n' "$j"
}

fm_tasks_write() {
  local src="$1" dir="${2:-design/tasks}" all line id
  all="$(jq -c 'if type=="array" then .[] elif has("tasks") then .tasks[] else . end' "$src")" \
    || { echo "fm-config: $src is not a task list" >&2; return 65; }
  mkdir -p "$dir" || return 70
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id="$(printf '%s' "$line" | jq -r '.id // empty')"
    _fm_task_id "$id" || { echo "fm-config: a task with no usable id: $line" >&2; return 65; }
    printf '%s' "$line" | jq . > "$dir/$id.json" || return 70
  done <<< "$all"
}

fm_tasks_check() {
  python3 - "${1:-design/tasks}" <<'PY'
import json, sys
from pathlib import Path

d = Path(sys.argv[1])
problems, tasks = [], {}
legacy = d.parent / (d.name + '.json')
if legacy.exists():
    problems.append('%s is still here: each entry belongs in its own file under %s/' % (legacy, d))
if not d.is_dir():
    problems.append('%s is not a directory' % d)
    files = []
else:
    files = sorted(d.iterdir())
for f in files:
    # .DS_Store, an interrupted --adopt's scratch: not a task, as fm_tasks says
    if f.name.startswith('.'):
        continue
    if f.suffix != '.json' or not f.is_file():
        problems.append('%s: not a task file (<id>.json)' % f.name); continue
    try:
        task = json.loads(f.read_text())
    except (OSError, ValueError) as error:
        problems.append('%s: does not parse: %s' % (f.name, error)); continue
    if not isinstance(task, dict) or task.get('id') != f.stem:
        problems.append('%s: its id is %s, not %s' % (f.name, json.dumps(task.get('id') if isinstance(task, dict) else None), f.stem))
        continue
    tasks[f.stem] = task
deps = {}
for name, task in tasks.items():
    wants = task.get('depends_on', [])
    if not isinstance(wants, list) or not all(isinstance(x, str) for x in wants):
        problems.append('%s: depends_on is not a list of ids' % name); wants = []
    for dep in wants:
        if dep not in tasks: problems.append('%s: depends on %s, which has no task file' % (name, dep))
    deps[name] = [dep for dep in wants if dep in tasks]
# a cycle is a task that waits, however indirectly, on itself: nothing in it
# can ever be dispatched. Each cycle is printed once, from its first task.
state, seen = {}, set()
def visit(node, path):
    state[node] = 'open'; path.append(node)
    for dep in deps[node]:
        if state.get(dep) == 'open':
            cycle = path[path.index(dep):] + [dep]
            key = frozenset(cycle)
            if key not in seen:
                seen.add(key); problems.append('a cycle: ' + ' -> '.join(cycle))
        elif dep not in state:
            visit(dep, path)
    path.pop(); state[node] = 'done'
for name in sorted(deps):
    if name not in state: visit(name, [])
for problem in problems: print(problem)
sys.exit(1 if problems else 0)
PY
}

# Freeze before doing work. A nested entrypoint uses the parent's frozen code,
# while a newly invoked session takes a new snapshot. Explicit roles win.
# Ignore SIGHUP so a background launch from an agent shell that exits does not
# orphan the caller-side wait for result.json / PR publish. Pane-child also
# ignores hangup and publishes last-result / close itself.
trap '' HUP
fm_freeze() {
  local script="$1"
  if [ "${FM_ENTRY_PID:-}" != "$$" ] || [ "${FM_ENTRY_SCRIPT:-}" != "${script##*/}" ]; then
    exec python3 "$_fm_code_dir/fm-herdr.py" launch "$_fm_code_dir/${script##*/}" "${@:2}"
  fi
}

fm_identity() {
  local role="$1" task="$2" alias="$3"
  # Recursion guards belong to one adapter invocation, never a new role run.
  unset FM_CONTEXT_READY FM_ATTEMPT_DIR FM_FINAL_PATH FM_CLI_EXIT FM_CHAIN_ATTEMPT
  # and a run-mode review's checkout belongs to that one round
  unset FM_RUN_REVIEW FM_REVIEW_CHECKOUT FM_REVIEW_NETWORK FM_REVIEW_HEAD FM_REVIEW_BASE FM_REVIEW_PATCH FM_CHAIN_VENDOR
  FM_RUN_DIR="$(python3 "${FM_CODE_ROOT:-$REPO}/bin/fm-herdr.py" allocate "$REPO" "$role" "$task" "$alias")" || return 70
  NAME="${FM_RUN_DIR##*/}"
  export FM_RUN_DIR FM_ROLE="$role" FM_TASK="$task" FM_ACTOR="$NAME" FM_ROOT="$REPO"
  printf '%s: canonical actor %s (requested alias: %s)\n' "$role" "$NAME" "${alias:-automatic}" >&2
  python3 - "$FM_RUN_DIR" "$$" "${FM_CODE_ROOT:-$REPO}" <<'PY'
import json, pathlib, sys
run, pid, code = sys.argv[1:]
p = pathlib.Path(run)
identity = json.loads((p / 'identity.json').read_text())
(p / 'process.json').write_text(json.dumps(dict(identity, pid=int(pid), token=code, snapshot=code)))
PY
}

fm_record_end() {
  python3 - "$FM_RUN_DIR" "$1" "${FM_CODE_ROOT:-$REPO}" "${FM_CHAIN_ATTEMPT:-}" "${FM_VENDOR_USED:-}" <<'PY'
import importlib.util, json, pathlib, sys
spec = importlib.util.spec_from_file_location('managed', pathlib.Path(sys.argv[3]) / 'bin/fm-herdr.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
run = pathlib.Path(sys.argv[1])
identity = json.loads((run / 'identity.json').read_text())
last = run / 'last-result.json'
result = json.loads(last.read_text()) if last.exists() else {}
if not sys.argv[4] or result.get('chain_attempt') != sys.argv[4]:
    result = dict(status='unknown', chain_attempt=sys.argv[4], vendor=sys.argv[5])
module.save(run / 'orchestration-result.json', dict(identity, process_exit=int(sys.argv[2]), adapter_result=result))
PY
}

# The order vendors are tried in, and the running of that order. Both the
# worker and the reviewer need it and they must behave identically, so it
# lives here once rather than as a loop in each.
#
# fm_vendor_chain [role] [explicit]
#   An explicit --vendor is the whole chain: the caller asked for that engine,
#   not for whatever the config would fall back to.
fm_vendor_chain() {
  local role="${1:-}" explicit="${2:-}" head=''
  if [ -n "$explicit" ]; then printf '%s\n' "$explicit"; return 0; fi
  head="$(fm_role_vendor "$role")"
  # one run per vendor: a fallback list may name the head, or itself twice
  printf '%s\n' "$head"
  fm_cfg_list fallback | grep -vxF "$head" | awk '!seen[$0]++' || true
}

#   fm_role_vendor [role] [file] -> the vendor a role starts on: its own
#   `vendor:`, else the top-level one, else mock - the head of its chain
fm_role_vendor() {
  local role="${1:-}" f="${2:-${FM_CONFIG:-config.yaml}}" v=''
  [ -n "$role" ] && v="$(fm_cfg_in "$role" vendor "$f")"
  [ -n "$v" ] || v="$(fm_cfg vendor "$f")"
  [ -n "$v" ] || v=mock
  printf '%s\n' "$v"
}

# The model config.yaml names, per vendor (T-146; T-127 named one per role).
# A model name belongs to one vendor: handing claude's name to codex, which
# a fallback or `--vendor` used to do, is a round the vendor refuses. So a
# round on <vendor> takes, in order:
#
#   1. the role's own `model:` (worker.model / reviewer.model), only when
#      <vendor> is the role's own vendor - the override the role names is
#      for the engine the role names;
#   2. `models.<vendor>`, the vendor's own model;
#   3. the top-level `model:`, only when <vendor> is the top-level vendor
#      (a config written before `models:` existed);
#
# and nothing otherwise: a vendor with no model named runs on its CLI's own
# default, which the round then records from the transcript. Never a value
# fm invents.
#
#   fm_model_for <role> <vendor> [file] -> that vendor's model, or empty
#   fm_model <role> [file]              -> the model of the role's own vendor
fm_model_for() {
  local role="${1:-}" vendor="${2:-}" f="${3:-${FM_CONFIG:-config.yaml}}" m=''
  [ -n "$vendor" ] || vendor="$(fm_role_vendor "$role" "$f")"
  if [ -n "$role" ] && [ "$vendor" = "$(fm_role_vendor "$role" "$f")" ]; then
    m="$(fm_cfg_in "$role" model "$f")"
  fi
  [ -n "$m" ] || m="$(fm_cfg_in models "$vendor" "$f")"
  if [ -z "$m" ] && [ "$vendor" = "$(fm_role_vendor '' "$f")" ]; then
    m="$(fm_cfg model "$f")"
  fi
  printf '%s\n' "$m"
}
fm_model() { fm_model_for "${1:-}" '' "${2:-${FM_CONFIG:-config.yaml}}"; }

# identity.json from a round's start (T-146): the vendor it starts on and
# the model config.yaml names for that vendor, beside the six T-116 fields,
# so the board shows them from the first event and not only once the round
# has ended. fm_run_chain records each fallback vendor the same way.
#
#   fm_record_requested <vendor> <model> [run-dir]
fm_record_requested() {
  local run="${3:-${FM_RUN_DIR:-}}"
  [ -n "$run" ] && [ -f "$run/identity.json" ] || return 0
  python3 "$_fm_code_dir/fm-herdr.py" record-requested "$run" "$1" "$2" >/dev/null 2>&1 || true
}

# Every field a crew payload's data.identity carries (T-116, T-127, T-146),
# read fresh from identity.json each time, so every event a round emits -
# crew_status included - says the same thing about who it is and what it
# runs on. `null` for a run with no identity.json.
fm_crew_identity() {
  local run="${1:-${FM_RUN_DIR:-}}" out=''
  [ -n "$run" ] && out="$(jq -c '{name,role,project,task,round,attempt,
    vendor,model_requested,model,cli_version,model_mismatch}' "$run/identity.json" 2>/dev/null)"
  printf '%s\n' "${out:-null}"
}

# What a vendor's own transcript says it ran on (T-127, T-146), from the
# slice of the log this attempt wrote, read in the shape each vendor records:
#
#   - claude's result message names no "model"; it names the models the run
#     used as the keys of `modelUsage` (T-146: the T-127 reading found no
#     "model" field in it and recorded "unknown"). Of those keys the one the
#     round asked for wins when it is there; otherwise the one that wrote the
#     most output tokens, since claude also runs a small model on the side.
#   - claude's stream init event, `{"type":"system","subtype":"init",
#     "model":...}`, names it before any result - read when no result came.
#   - the other vendors' JSON (bin/adapters/_contract.md names each shape)
#     carries a literal `"model":"..."`; the last one wins, so a later
#     report - a fallback model the CLI itself chose - wins over an earlier
#     one. An escaped `\"model\"` inside an answer's text is not one.
#
# Empty when the transcript says nothing; the caller records "unknown",
# never a guess.
#
#   fm_vendor_model <log> [offset] [requested]
fm_vendor_model() {
  local log="$1" off="${2:-0}" requested="${3:-}"
  [ -f "$log" ] || return 0
  tail -c "+$((off + 1))" "$log" 2>/dev/null | python3 -c '
import json, re, sys
requested = sys.argv[1]
usage, said = None, None
decoder = json.JSONDecoder()
for line in sys.stdin.read().splitlines():
    for f in re.finditer(r"\"model\"\s*:\s*\"([^\"]*)\"", line): said = f.group(1)
    start = line.find("{")
    while start != -1:
        try: obj, end = decoder.raw_decode(line, start)
        except ValueError: start = line.find("{", start + 1); continue
        if isinstance(obj, dict) and isinstance(obj.get("modelUsage"), dict) and obj["modelUsage"]:
            usage = obj["modelUsage"]
        start = line.find("{", end)
def out_tokens(v):
    n = v.get("outputTokens") if isinstance(v, dict) else None
    return n if isinstance(n, (int, float)) else 0
if usage:
    keys = list(usage)
    print(requested if requested in keys else max(keys, key=lambda k: out_tokens(usage[k])))
elif said: print(said)
' "$requested" 2>/dev/null
}

# A name claude accepts, offline (T-127): the CLI itself is the final word
# (fm_adapter_model_refusal reads its own `unrecognized_model` answer at
# round time), but `fm-session.sh`'s config check runs before any round, with
# no CLI to ask, so it checks against this list - the names anthropic
# documents and their short aliases - and says so of anything else, the way
# it already says so of a model left unset. Not exhaustive by design: a name
# added upstream and not yet here is still caught by the CLI at round time.
_FM_CLAUDE_MODELS="claude-opus-5-5 opus claude-sonnet-5 sonnet claude-haiku-4-5-20251001 haiku claude-fable-5-1 fable"
# cursor-agent has no offline list of its own - it can only name its models
# by asking `cursor-agent --list-models`, which needs the operator's own
# login (design/design.md, "the configured model" section) and so cannot run
# from this config check, which runs with no CLI session at all. Its own
# round-time preflight (bin/adapters/cursor-agent.sh,
# fm_adapter_model_listcheck) asks the CLI directly, once it is authenticated;
# this offline check stays uncatalogued (2) for it, the same as codex and
# gemini, which document no listing command at all.
fm_model_known() {   # fm_model_known <vendor> <model> -> 0 known, 1 not, 2 no catalogue for this vendor
  local vendor="$1" model="$2" m
  [ -n "$model" ] || return 1
  case "$vendor" in
    claude)
      for m in $_FM_CLAUDE_MODELS; do [ "$m" = "$model" ] && return 0; done
      return 1 ;;
    *) return 2 ;;
  esac
}

# The CLI's own version string (T-127), read directly from the vendor's
# binary - never out of the transcript, which may say nothing of it. Missing
# or silent is "unknown", never a guess; the canary and the crew's records
# both read it this same way.
fm_vendor_cli_version() {
  local cmd="$1" v=''
  command -v "$cmd" >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  # A bare version probe, never the round: the caller's shell still carries
  # the round's own FM_ACTOR/FM_ROLE/FM_TASK/FM_RUN_DIR (fm_identity exports
  # them for the whole process, for emit() and its kin), and hands the CLI a
  # closed stdin rather than let it read whatever the caller's happens to be
  # - both would otherwise let a CLI, or a test fixture standing in for one,
  # mistake this probe for another attempt of the round that just ran.
  v="$(env -u FM_ACTOR -u FM_ROLE -u FM_TASK -u FM_RUN_DIR "$cmd" --version \
       < /dev/null 2>/dev/null | head -1 | tr -d '\r')"
  printf '%s\n' "${v:-unknown}"
}

# fm_review_run_chain <adapters-dir> <chain>
#   The part of a reviewer chain that may take a run-mode round: an adapter
#   declares it can confine one with a `# fm:review-run` line, which it may
#   carry only if its CLI's own permission flags keep the engine inside the
#   checkout and away from push. The rest is dropped, and a head that cannot
#   is refused (1) rather than quietly replaced by a fallback. A name with no
#   adapter is kept, so fm_run_chain still reports a typo as a typo.
fm_review_run_chain() {
  local dir="$1" v first=1 kept='' names=()
  # split on blanks and newlines as the chain is, but never globbed: an
  # unquoted expansion would read a `*` as the file names around it
  read -r -d '' -a names <<<"$2" || true
  for v in ${names[@]+"${names[@]}"}; do
    if [ -x "$dir/$v.sh" ] && ! grep -q '^# fm:review-run' "$dir/$v.sh"; then
      [ "$first" = 1 ] && return 1
    else
      kept="${kept:+$kept
}$v"
    fi
    first=0
  done
  printf '%s\n' "$kept"
}

# fm_run_chain <adapters-dir> <chain> <prompt> <tree> <log> [evidence] [outmode] [prepare]
#   Returns the adapter's own exit code, or 2 if every vendor was unavailable.
#   Sets FM_VENDOR_USED and FM_VENDOR_SKIPPED so the caller can say what it did,
#   and FM_VENDOR_MODEL, the model the last attempt was handed (T-146).
#
#   <evidence> is a command that answers "did that run produce work?". An
#   adapter decides "unavailable" by reading text, and text can lie in both
#   directions, so the caller gets the last word: a worker asks whether the
#   worktree changed, a reviewer whether the output carries a verdict marker.
#   Work beats a signature, and the chain stops there. FM_VENDOR_MISREAD names
#   the vendor this happened to, so the caller can say so.
#
#   FM_VENDOR_SPOKE is 1 when some attempt produced output of its own -
#   bytes appended to the log, or, in per-vendor mode only, a file in its
#   own directory. In shared mode the directory is the caller's artefact and
#   was not empty to begin with, so it cannot answer the question and is not
#   consulted. With
#   the return code it is the whole of what a caller needs: rc 2 with
#   nothing said is a vendor that was not there; rc 2 with something said is
#   an engine that ran badly. Neither caller may re-derive this by looking
#   at bytes itself - they disagreed when they did.
#
#   The head of the chain having no adapter is a typo in config.yaml, not an
#   outage: nothing is run at all, FM_VENDOR_UNKNOWN names it and 65 comes
#   straight back, so the caller's own exit 65 cannot discard work a later
#   vendor had already done.
#
#   <outmode> "per-vendor" gives each attempt its own directory under <tree>
#   and names it in FM_RUN_OUTDIR (in shared mode that is <tree> itself,
#   shared by every attempt); the default shares <tree>, which is what
#   a worker wants because the worktree IS the artefact. FM_RUN_LOG_OFF is
#   where this attempt's bytes start in the shared log, so an evidence
#   predicate can read its own output and no one else's.
#   Optional prepare is a caller-owned function taking the next vendor. A
#   refusal stops the chain before launch (70), without accepting an old result.
# shellcheck disable=SC2034  # these are read by the callers, not here
fm_run_chain() {
  local dir="$1" chain="$2" prompt="$3" tree="$4" log="$5" evidence="${6:-}" \
        outmode="${7:-shared}" prepare="${8:-}" v rc=2 head='' out='' after=0
  # every output of this function, including the two that say where an
  # attempt's bytes are: leaving those set means a caller on the
  # configuration-error path reads the PREVIOUS call's attempt, which is the
  # exact confusion the offsets exist to prevent
  FM_VENDOR_USED=''; FM_VENDOR_SKIPPED=''; FM_VENDOR_MISREAD=''; FM_VENDOR_UNKNOWN=''
  FM_RUN_OUTDIR=''; FM_RUN_LOG_OFF=0; FM_VENDOR_SPOKE=0; FM_VENDOR_MODEL=''
  export FM_CHAIN_ATTEMPT='' FM_CHAIN_VENDOR=''
  # before anything runs. A typo at the head of the chain used to be found
  # after a real vendor had already worked, and the caller's exit 65 then
  # threw that work away.
  # unquoted on purpose: a chain arrives space-separated or newline-separated
  # and the head is the first word either way. SC2086 is info-level and the
  # gate runs at warning, so there is no directive here to go stale - the
  # adapters rely on the same deliberate splitting for FM_ADAPTER_ARGS.
  head="$(printf '%s\n' $chain | head -1)"
  if [ -n "$head" ] && [ ! -x "$dir/$head.sh" ]; then
    FM_VENDOR_UNKNOWN="$head"; return 65
  fi
  for v in $chain; do
    [ -x "$dir/$v.sh" ] || continue
    # each vendor reads only what it wrote. The chain shares one log, and a
    # vendor that dies half way through must not have its bytes read as the
    # next one's answer - so the caller is told where this attempt's output
    # begins, and where it went.
    FM_RUN_LOG_OFF="$(wc -c "$log" 2>/dev/null | awk '{print $1}')"
    [ -n "$FM_RUN_LOG_OFF" ] || FM_RUN_LOG_OFF=0
    if [ "$outmode" = "per-vendor" ]; then
      out="$tree/$v"; mkdir -p "$out"
    else
      out="$tree"
    fi
    FM_RUN_OUTDIR="$out"
    # This vendor's own model (T-146), never the head vendor's: a caller
    # that names its role in FM_MODEL_ROLE has each attempt handed the model
    # config.yaml names for the vendor it runs, and the run's identity.json
    # says which vendor and model it is on now. Without FM_MODEL_ROLE,
    # FM_MODEL is left as the caller set it.
    if [ -n "${FM_MODEL_ROLE:-}" ]; then
      FM_MODEL="$(fm_model_for "$FM_MODEL_ROLE" "$v" "${FM_MODEL_CONFIG:-config.yaml}")"
      export FM_MODEL
      fm_record_requested "$v" "$FM_MODEL"
    fi
    FM_VENDOR_MODEL="${FM_MODEL:-}"
    # Bind every receipt reader to this invocation, including custom fallbacks
    # that never create managed receipts. Keep previous receipts as evidence.
    FM_CHAIN_ATTEMPT="$(python3 -c 'import uuid; print(uuid.uuid4().hex)')" || return 70
    export FM_CHAIN_ATTEMPT FM_CHAIN_VENDOR="$v"
    # A launcher-owned preparation callback runs before every vendor attempt,
    # including fallback. Failure is terminal and cannot reuse old evidence.
    if [ -n "$prepare" ]; then
      "$prepare" "$v" || return 70
    fi
    "$dir/$v.sh" run "$prompt" "$out" "$log"; rc=$?
    # did this vendor say anything of its own? The callers need to tell an
    # engine that ran badly from one that was not there, and this is the
    # only place that can answer it - an adapter's notice about a missing
    # CLI goes to stderr precisely so it does not count here.
    #
    # In shared mode the directory IS the artefact and is never empty, so
    # only the log slice can answer this; the per-vendor directory starts
    # empty and anything in it was written by this attempt. The meaning is
    # the same in both modes: bytes this attempt produced.
    after="$(wc -c "$log" 2>/dev/null | awk '{print $1}')"; [ -n "$after" ] || after=0
    [ "$after" != "$FM_RUN_LOG_OFF" ] && FM_VENDOR_SPOKE=1
    if [ "$outmode" = "per-vendor" ] && [ -n "$(ls -A "$out" 2>/dev/null)" ]; then
      FM_VENDOR_SPOKE=1
    fi
    if [ "$rc" = 2 ] && [ -n "$evidence" ] && $evidence; then
      FM_VENDOR_USED="$v"; FM_VENDOR_MISREAD="$v"; return 0
    fi
    if [ "$rc" = 2 ]; then FM_VENDOR_SKIPPED="${FM_VENDOR_SKIPPED:+$FM_VENDOR_SKIPPED }$v"; continue; fi
    FM_VENDOR_USED="$v"; return "$rc"
  done
  return "$rc"
}

# `shift 2` with one argument left does not shift: it returns 1 and leaves
# $@ alone, so `while [ $# -gt 0 ]` spins on the same flag for ever -
# `bin/fm-emit.sh --type` was a busy loop rather than an error. Every
# flag that takes a value checks before it shifts, in the same case
# branch, and exits 64. The repository lint fails on a `shift 2` that has not
# checked, and tests/option-loop.test.sh runs every flag of every script
# with nothing after it - under an alarm, because a test for a hang that
# simply calls the script hangs the gate instead of failing it.
#
# The scripts that deliberately depend on nothing carry a two-line copy
# that points back here. How many there are is pinned in
# tests/option-loop.test.sh - by an assertion that greps for the local
# definition, which is new: the sentence claiming it was pinned was
# there a round before the assertion was. A count in a comment is only
# true on the day it is typed, and a claim that a count is checked
# somewhere else is worth no more than the check.
fm_need() { [ "$#" -ge 3 ] || { echo "$1: $2 needs a value" >&2; exit 64; }; }

# Commits that land on GitHub must use the operator's configured identity
# (user.name / user.email), not a synthetic firstmate@local that GitHub
# cannot link to an account. Override with FM_GIT_NAME / FM_GIT_EMAIL when
# a bot identity is intentional.
#
# The lookup asks the worktree being committed to, not the caller's cwd:
# fm-checkpoint --dir never cd's into the repo, so a cwd lookup saw only
# whatever identity happened to be ambient - the operator's own config at
# a terminal, and nothing at all on a CI runner, where a repo that does
# configure an identity locally was refused a commit anyway.
fm_git_name()  { printf '%s' "${FM_GIT_NAME:-$(git -C "${1:-.}" config user.name 2>/dev/null || true)}"; }
fm_git_email() { printf '%s' "${FM_GIT_EMAIL:-$(git -C "${1:-.}" config user.email 2>/dev/null || true)}"; }
fm_git_commit() {  # fm_git_commit <worktree> <message>
  local dir="$1" msg="$2" n e
  n="$(fm_git_name "$dir")"; e="$(fm_git_email "$dir")"
  if [ -z "$n" ] || [ -z "$e" ]; then
    echo "fm: set git user.name and user.email (or FM_GIT_NAME / FM_GIT_EMAIL) before committing" >&2
    return 70
  fi
  git -C "$dir" -c user.name="$n" -c user.email="$e" commit -q -m "$msg"
}

# A round needs no terminal host (T-144): it runs headless, as a process group
# fm supervises, and a host (Herdr, cmux, tmux) is only a window onto it. So no
# transport is a bypass of anything and nothing is refused here; the function
# stays because the entrypoints call it. FM_TRANSPORT=direct now only asks for
# a round with no window.
fm_refuse_herdr_bypass() { return 0; }

# --- what counts as a script, and what counts as a comment ---------------
#
# One definition, because there were four and three of them were the
# broken one. The gate lints an option loop; tests/option-loop.test.sh
# sweeps for a script the gate should have linted and did not. Two
# processes, so they cannot share a variable - but they can share these,
# and a sweep written out by hand at the call site is a sweep that drifts
# from the one it is supposed to be checking.
#
# The stripper cuts at a `#` that STARTS A WORD. `sed 's/#.*$//'` also
# cuts `${1#--}` and `"#"`, and a `shift 2` sharing a line with either
# then disappears - out of the lint, and out of the sweep that exists to
# notice the lint missing something, both blind the same way.
# Managed Herdr sessions refresh mid-run activity through the same crew_status
# path as fm-worker.sh / fm-review.sh (T-036).
# Equals-form long opts on purpose: traps.sweep_unarmed matches `--actor VALUE`
# (space form) on lifecycle scripts. This is a library helper, not an emitter
# that boards a crewman, so space-form would false-positive the unarmed sweep.
fm_herdr_emit_status() {  # fm_herdr_emit_status <root> <actor> <task> <en> <tw> [role [done total]]
  local root="$1" actor="$2" task="$3" en="$4" tw="$5" role="${6:-worker}"
  local done_n="${7-}" total_n="${8-}" py="${root}/bin/fm-herdr.py"
  command -v python3 >/dev/null 2>&1 || return 2
  [ -f "$py" ] || return 2
  if [ -n "$done_n" ] && [ -n "$total_n" ]; then
    python3 "$py" emit-status --root="$root" --actor="$actor" --task="$task" \
      --role="$role" --en="$en" --tw="$tw" --done="$done_n" --total="$total_n"
  else
    python3 "$py" emit-status --root="$root" --actor="$actor" --task="$task" \
      --role="$role" --en="$en" --tw="$tw"
  fi
}

# The wake (T-137): the writer of an event that needs firstmate pushes it -
# onto state/session/wake.jsonl, then a ring of every doorbell - so nothing
# has to watch for it. <line> is the short reason firstmate is woken with,
# `finished: T-134 worker-mira-t134-r1 ok`. Best effort, like a progress
# line: the round's own agent_finished is the record, the wake a courtesy
# on top, and a push that fails says so on stderr and changes nothing else.
fm_wake_push() {   # fm_wake_push <root> <id> <reason> <line> [json]
  python3 "$_fm_code_dir/lib/fm_lifeline.py" push "$@" >/dev/null </dev/null \
    || echo "fm: the wake for $2 was not pushed; the event log still records it" >&2
}

fm_strip_comments() { sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#.*$//' "$1"; }

# It descends: `bin/*.sh` misses a subdirectory, and bin/adapters has
# been there all along.
fm_shell_corpus() { find "${1:-bin}" -type f -name '*.sh' | sort; }

# A file declares itself a lint source when it quotes the shapes it
# forbids, rather than being on a list somewhere else.
fm_is_lint_source() { grep -q '^# fm:lint-source' "$1"; }

# Every script with an option loop, which is the corpus both the gate and
# the suite judge.
fm_loop_corpus() {   # fm_loop_corpus [dir]
  local f
  while IFS= read -r f; do
    fm_is_lint_source "$f" && continue
    # a here-string, not a pipe: grep -q leaves on the match, the
    # producer takes SIGPIPE, and under pipefail that reads as "no
    # match" - it dropped the two longest scripts on the runner
    grep -q 'shift 2' <<< "$(fm_strip_comments "$f")" || continue
    printf '%s\n' "$f"
  done < <(fm_shell_corpus "${1:-bin}")
}

# Which flags an option loop consumes a value for. This lived in
# tests/option-loop.test.sh, hand-rolled, which made it a THIRD idea of
# what a line of an option loop is in the file whose argument is that
# there must be one - and it was the idea the pinned counts are derived
# from. It reads comments off first (a flag named in a comment inside
# the loop used to invent one) and takes the whole case pattern rather
# than one flag from it, so `--x|--y)` is two.
fm_loop_flags() {   # fm_loop_flags <file>
  fm_strip_comments "$1" \
    | sed -n '/while .*$# -gt 0/,/^done/p' \
    | grep 'shift 2' \
    | sed 's/).*$//' \
    | grep -oE '\-\-[A-Za-z][A-Za-z0-9-]*' \
    | sort -u
}

# Resolve configuration, checkout, and private records independently. Call
# before writing anything; a missing registry preserves pre-registry self use.
fm_storage_init() {
  local engine="$1" explicit="${2:-${FM_PROJECT:-}}" names name
  engine="$(cd "$engine" && pwd -P)" || return 65
  if [ "${FM_EXTERNAL:-0}" = 1 ]; then unset GH_REPO; fi
  FM_ENGINE_ROOT="$engine"; FM_CONFIG="$engine/config.yaml"
  FM_STATE_DIR="$engine/state"; FM_WORKTREES="$engine/state/worktrees"
  FM_TASKS_DIR="$engine/design/tasks"; FM_DESIGN="$engine/design/design.md"
  FM_TARGET_ROOT="$engine"; FM_EXTERNAL=0
  # Pre-registry and degraded self callers do not need a usable registry.
  if ! names="$(fm_projects "$FM_CONFIG")"; then
    [ -z "$explicit" ] || [ "$explicit" = firstmate-workflow ] || return 65
    names=''
  fi
  if [ -n "$names" ]; then
    name="$explicit"
    if [ -z "$name" ]; then
      name="$(fm_cfg default_project "$FM_CONFIG" || true)"
      if [ -z "$name" ]; then
        for name in $names; do
          [ "$(fm_project_get "$name" repo "$FM_CONFIG")" != . ] || break
        done
        [ "$(fm_project_get "$name" repo "$FM_CONFIG")" = . ] || name=''
      fi
    fi
    # No default and no self entry: an unnamed legacy caller stays local.
    if [ -z "$name" ]; then
      export FM_ENGINE_ROOT FM_CONFIG FM_STATE_DIR FM_WORKTREES FM_TASKS_DIR FM_DESIGN
      export FM_TARGET_ROOT FM_EXTERNAL
      return 0
    fi
    name="$(fm_project_resolve "$name" "$FM_CONFIG")" || return 65
    FM_PROJECT="$name"
    FM_TARGET_ROOT="$(fm_project_get "$name" root "$FM_CONFIG")" || return 65
    if [ "$(fm_project_get "$name" repo "$FM_CONFIG")" != . ]; then
      if [ -e "$engine/state/projects/$name" ] || [ -L "$engine/state/projects/$name" ]; then
        echo "fm-config: legacy project $name requires approved fm project sync --migrate" >&2
        return 65
      fi
      FM_EXTERNAL=1
      FM_STATE_DIR="$(fm_project_get "$name" state "$FM_CONFIG")" || return 65
      FM_WORKTREES="$(fm_project_get "$name" worktrees "$FM_CONFIG")" || return 65
      FM_TASKS_DIR="$(fm_project_get "$name" tasks "$FM_CONFIG")" || return 65
      FM_DESIGN="$(fm_project_get "$name" design "$FM_CONFIG")" || return 65
      GH_REPO="$(fm_project_get "$name" github "$FM_CONFIG")" || return 65
      FM_BASE="$(fm_project_get "$name" base "$FM_CONFIG")" || return 65
      export GH_REPO FM_BASE
    fi
  fi
  export FM_ENGINE_ROOT FM_CONFIG FM_STATE_DIR FM_WORKTREES FM_TASKS_DIR FM_DESIGN
  export FM_TARGET_ROOT FM_EXTERNAL FM_PROJECT
}

fm_target_validate() {
  [ "$FM_EXTERNAL" = 1 ] || return 0
  local actual expected
  [ -d "$FM_TARGET_ROOT/.git" ] && [ ! -L "$FM_TARGET_ROOT/.git" ] || return 65
  actual="$(git -C "$FM_TARGET_ROOT" rev-parse --show-toplevel 2>/dev/null)" || return 65
  [ "$actual" = "$FM_TARGET_ROOT" ] || return 65
  expected="${FM_GITHUB_URL:-https://github.com}/$GH_REPO.git"
  actual="$(git -C "$FM_TARGET_ROOT" remote get-url origin 2>/dev/null)" || return 65
  [ "$actual" = "$expected" ] && [ "$(git -C "$FM_TARGET_ROOT" remote get-url --push origin 2>/dev/null)" = "$expected" ] || {
    echo "fm-config: managed clone origin does not match project $FM_PROJECT" >&2; return 65; }
}
