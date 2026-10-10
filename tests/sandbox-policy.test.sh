#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/sandbox.sh
. "$ROOT/tests/lib/sandbox.sh"
# Fixed usrmerge observations are injected only inside this fixture process.
python3 - "$ROOT" <<'PYALIASES'
import sys
from unittest.mock import patch
sys.path.insert(0, sys.argv[1] + '/bin/lib')
import fm_sandbox_policy as policy

pairs = [('/bin', '/usr/bin'), ('/sbin', '/usr/sbin'), ('/lib', '/usr/lib'),
         ('/lib32', '/usr/lib32'), ('/lib64', '/usr/lib64')]
def profile(reads, denied=(), links=None, dirs=None):
    links = dict(pairs) if links is None else links
    dirs = set(dict(pairs).values()) if dirs is None else dirs
    with patch.object(policy.os.path, 'islink', side_effect=lambda p: p in links), \
         patch.object(policy.os.path, 'realpath', side_effect=lambda p: links.get(p, p)), \
         patch.object(policy.os.path, 'isdir', side_effect=lambda p: p in dirs), \
         patch.object(policy.os.path, 'exists', return_value=False), \
         patch.object(policy, 'pinned_of', return_value=None), \
         patch.object(policy, 'own_git', return_value=None):
        return policy.linux({'never_read': list(denied), 'repo_config': ['.private']},
                            ['/checkout', '/round'], reads, {}, '').splitlines()
def aliases(argv):
    return [(argv[i+1], argv[i+2]) for i, v in enumerate(argv) if v == '--symlink']
argv = profile(['/usr', '/usr'])
assert aliases(argv) == [(target, alias) for alias, target in pairs], 'missing-loader-alias: fixed granted usrmerge aliases must exist'
assert argv.index('--symlink') < argv.index('--ro-bind-try'), 'aliases precede canonical binds'
assert argv.count('--symlink') == 5, 'duplicate reads do not duplicate aliases'
for alias, target in pairs:
    for grant in (alias, alias + '/tool'):
        bound = profile(['/usr', grant])
        assert (target, alias) not in aliases(bound), 'bound-alias-conflict: read grants at or below an alias must suppress its symlink'
        assert any(bound[i:i+3] == ['--ro-bind-try', grant, grant]
                   for i in range(len(bound))), 'existing alias read bind remains'
        assert aliases(bound) == [(other_target, other_alias)
                                 for other_alias, other_target in pairs if other_alias != alias], 'unbound toolchain aliases remain'
for alias, target in pairs:
    assert aliases(profile([target])) == [(target, alias)], 'exact canonical target grant'
    for label, links, dirs in [('absent', {}, {target}), ('non-symlink', {}, {alias, target}),
                               ('wrong target', {alias: '/opt/tools'}, {'/opt/tools'}),
                               ('private target', {alias: '/private/tools'}, {'/private/tools'}),
                               ('missing target', {alias: target}, set())]:
        assert not aliases(profile(['/usr'], links=links, dirs=dirs)), label
    assert not aliases(profile(['/opt'], links={alias: target}, dirs={target})), 'read grant absent'
    for denied in (alias, target, '/', '/usr', alias + '/secret', target + '/secret'):
        assert (target, alias) not in aliases(profile(['/usr'], [denied])), 'never_read intersection: ' + denied
assert not aliases(profile(['/usr'], links={}, dirs={'/bin', '/lib', '/usr'})), 'non-usrmerge layout'
assert not aliases(profile(['/usr'], links={'/custom': '/usr/bin'})), 'no arbitrary aliases'
masked = profile(['/usr'], ['/usr/lib/secret'], dirs=set(dict(pairs).values()) | {'/usr/lib/secret'})
assert masked.index('--tmpfs', masked.index('--ro-bind-try')) > masked.index('--ro-bind-try'), 'denial masking remains after binds'
print('fixed usrmerge alias behavioral assertions passed')
PYALIASES
assert_eq "0" "$?" "Linux fixed usrmerge alias admission and denial matrix"

# Linux supplies device and process mounts itself; host read binds must not
# replace them with nodev mounts. Prefix siblings remain ordinary reads.
python3 - "$ROOT" <<'PYMOUNTS'
import sys
from unittest.mock import patch
sys.path.insert(0, sys.argv[1] + '/bin/lib')
import fm_sandbox_policy as policy
reads = ['/dev', '/dev/null', '/dev/pts/0', '/proc', '/proc/self/status',
         '/device-tools', '/process-tools', '/usr']
with patch.object(policy, 'pinned_of', return_value=None), \
     patch.object(policy, 'own_git', return_value=None):
    argv = policy.linux({'never_read': [], 'repo_config': []},
                        ['/checkout', '/round'], reads, {}, '').splitlines()
assert argv.count('--dev') == 1 and argv[argv.index('--dev') + 1] == '/dev'
assert argv.count('--proc') == 1 and argv[argv.index('--proc') + 1] == '/proc'
binds = [(argv[i+1], argv[i+2]) for i, arg in enumerate(argv) if arg == '--ro-bind-try']
assert binds == [(r, r) for r in ['/device-tools', '/process-tools', '/usr']], \
    'native-device-process-mounts: no host read bind may replace /dev or /proc or their descendants'
PYMOUNTS
assert_eq "0" "$?" "Linux native device and process mounts survive toolchain reads"

# T-284: a spec preflight pins the card and the pull-request draft beside the
# spec; pinned_of() admits each only with the hash the launcher exported.
pinned_case() {  # pinned_case <card hash: match|wrong|unset>; prints the path or the error
  python3 - "$ROOT" "$1" <<'PYPINNED'
import hashlib, os, shutil, sys, tempfile
sys.path.insert(0, sys.argv[1] + '/bin/lib')
import fm_sandbox_policy as policy
base = os.path.realpath(tempfile.mkdtemp())
path = os.path.join(base, 'pinned')
os.mkdir(path, 0o755)
try:
    for name, body in (('spec.json', b'{"id":"T-1"}'), ('card.json', b'{"title":"card"}'),
                       ('pr-authoring.json', b'{"subject":"Add it"}')):
        with open(os.path.join(path, name), 'wb') as handle:
            handle.write(body)
        os.chmod(os.path.join(path, name), 0o444)
        os.environ[{'card.json': 'FM_SPEC_PREFLIGHT_CARD', 'pr-authoring.json': 'FM_SPEC_PREFLIGHT_PR_AUTHORING',
                    'spec.json': 'FM_SPEC_PREFLIGHT'}[name]] = hashlib.sha256(body).hexdigest()
    os.environ['FM_PINNED_DIR'] = path
    os.environ.pop('FM_RUN_DIR', None)
    if sys.argv[2] == 'wrong':
        os.environ['FM_SPEC_PREFLIGHT_CARD'] = '0' * 64
    elif sys.argv[2] == 'unset':
        del os.environ['FM_SPEC_PREFLIGHT_CARD']
    try:
        print('ok' if policy.pinned_of() == path else 'wrong path')
    except ValueError as error:
        print(error)
finally:
    for name in os.listdir(path):
        os.chmod(os.path.join(path, name), 0o644)
    shutil.rmtree(base)
PYPINNED
}
assert_eq "ok" "$(pinned_case match)" "pinned card and draft accepted with matching hashes"
assert_eq "pinned file does not match its preflight hash" "$(pinned_case wrong)" "pinned card with a wrong hash refused"
assert_eq "invalid pinned folder contents" "$(pinned_case unset)" "pinned card without its variable refused"

# --- fm_policy: one policy per role ------------------------------------------
pol worker 'vendor: mock
'
assert_eq "0" "$?" "a config.yaml with no policy block still resolves one"
w="$t/worker.json"
assert_eq "worker" "$(jq -r .role "$w")" "for the role asked"
assert_eq "write read network sockets env repo-config refuse ulimit" "$(jq -r '.dimensions|join(" ")' "$w")" \
  "naming every dimension a round is confined in"
assert_eq '["{root}","{tmp}"]' "$(jq -c .write "$w")" \
  "writes go to the worktree or checkout and the round's own temp directory - never the shared /tmp"
assert_eq "[]" "$(jq -c .network "$w")" "and no registry is reachable unless one is declared"
# git's own credential stores (T-117): design 13.1 names ~/.git-credentials
# and ~/.netrc as how git's credentials stay out of reach, and ~/.gnupg
# holds the signing keys
for never in "$home/.ssh" "$home/.config/gh" "$home/.aws" "$home/.claude" "$home/.claude.json" "$home/.codex" \
             "$home/.cursor" "$home/.gemini" "$home/.config/herdr" "$t/state" \
             "$home/.git-credentials" "$home/.netrc" "$home/.gnupg" "$home/.config/firstmate"; do
  assert_eq "true" "$(jq --arg p "$never" '.never_read | index($p) != null' "$w")" \
    "never readable: ${never#"$home"/}"
done
for op in "git push" gh herdr browser mcp; do
  assert_eq "true" "$(jq --arg op "$op" '.refuse | index($op) != null' "$w")" "refused: $op"
done
for name in GH_TOKEN GITHUB_TOKEN SSH_AUTH_SOCK GOOGLE_APPLICATION_CREDENTIALS FM_CREW_UNSANDBOXED FM_ROUND_UNSANDBOXED; do
  assert_eq "true" "$(jq --arg n "$name" '.env_scrub.names | index($n) != null' "$w")" "scrubbed: $name"
done
assert_eq "true" "$(jq '.env_scrub.prefixes | index("AWS_") != null and index("AZURE_") != null' "$w")" \
  "and every AWS_ and AZURE_ variable"
assert_eq '[".claude",".mcp.json",".cursor","GEMINI.md"]' "$(jq -c .repo_config "$w")" \
  "the repository's own agent configuration is not loaded"
assert_eq "none" "$(jq -r .sockets "$w")" "no unix sockets"
assert_eq "2048 14400" "$(jq -r '"\(.procs) \(.cpu)"' "$w")" "and a process and CPU ulimit"
# Every vendor's login file holds a refresh token (T-117 round 2), so none
# is read in place: fm reads it and hands in its access token, or a copy
# with the refresh token emptied
assert_eq "[]" "$(jq -c '[.vendors[].auth[]]' "$w")" "no vendor's round reads its login file in place"
assert_eq "[]" "$(jq -c '[.vendors | to_entries[] | select((.value.login.file // []) | length > 0)
    | select((.value.login.copy // "") == "" and ((.value.login.to // "") | startswith("env:") | not)) | .key]' "$w")" \
  "every login read from a file goes in as a token or a copy, never as the file"
assert_eq "[]" "$(jq -c '[.vendors | to_entries[] | select(.value.login.copy) | select((.value.login.drop // []) | length == 0) | .key]' "$w")" \
  "and every copy names the refresh token it empties"
assert_eq "codex-home/auth.json tokens.refresh_token|gemini-home/.gemini/oauth_creds.json refresh_token" \
  "$(jq -r '[.vendors.codex, .vendors.gemini] | map("\(.login.copy) \(.login.drop | join(","))") | join("|")' "$w")" \
  "codex's and gemini's login files each go in as a copy, less the refresh token"
assert_eq '["codex","gemini"]' "$(jq -c '[.vendors | to_entries[] | select(.value.login.copy) | .key]' "$w")" \
  "and no other vendor's login goes in as a file"
# a vendor's session state is writable; its settings are not state
for v in codex cursor-agent gemini; do
  assert_ne "0" "$(jq --arg v "$v" '.vendors[$v].state | length' "$w")" "$v names the session state its CLI writes"
done
assert_eq "[]" "$(jq -c '[.vendors[] | (.state + .auth)[] | select(test("settings|config\\.toml|mcp\\.json|/skills|/hooks|CLAUDE\\.md|GEMINI\\.md"))]' "$w")" \
  "no vendor's settings, hooks, skills or MCP servers are among its auth or state"
# claude (T-117): a config directory of the round's own, so nothing of the
# operator's ~/.claude is opened; the one directory it keeps under /tmp
# whatever TMPDIR says; and its login read outside the round
assert_eq "[] []" "$(jq -r '"\(.vendors.claude.auth | tojson) \(.vendors.claude.state | tojson)"' "$w")" \
  "claude's round opens no file of the operator's ~/.claude or ~/.claude.json"
assert_eq "[\"$(cd /tmp && pwd -P)/claude-$(id -u)\"]" "$(jq -c .vendors.claude.tmp "$w")" \
  "claude's temp directory under /tmp is its one there, for this user"
assert_eq "[]" "$(jq -c '[.vendors | to_entries[] | select(.key != "claude") | .value.tmp[]]' "$w")" \
  "and no other vendor has one"
# claude (T-126): the crew's own long-lived token first - a keychain item
# of fm's own, or a file only the operator may read - handed in the same
# way cursor-agent's Cursor key is; only its `fallback` names the operator's
# own interactive login, the way claude's login worked before T-126
assert_eq "firstmate-claude-token $me env:CLAUDE_CODE_OAUTH_TOKEN true" \
  "$(jq -r '.vendors.claude.login | "\(.keychain[0].service) \(.keychain[0].account) \(.to) \(.private)"' "$w")" \
  "claude's login is the crew's own token, handed in as an access token"
assert_eq "firstmate-claude-token $me" \
  "$(jq -r '.vendors.claude.login | "\(.secret[0].service) \(.secret[0].account)"' "$w")" \
  "or, off macOS, the same item through libsecret (T-126 round 2)"
assert_eq "$home/.config/firstmate/claude-token" "$(jq -r '.vendors.claude.login.file[0]' "$w")" \
  "or a file only the operator may read where there is neither"
assert_eq "Claude Code-credentials $me claudeAiOauth.accessToken" \
  "$(jq -r '.vendors.claude.login.fallback | "\(.keychain[0].service) \(.keychain[0].account) \(.field)"' "$w")" \
  "and only with none of those, its fallback is the operator's own interactive login"
assert_eq "$home/.claude/.credentials.json" "$(jq -r '.vendors.claude.login.fallback.file[0]' "$w")" \
  "or its credentials file where there is no keychain"
# cursor-agent reads `agent login`'s token through the keychain API, which
# no round reaches (the canary, 2026-09-26), so its round signs in with a
# Cursor API key the operator keeps for the crew in fm's own item or file
assert_eq "firstmate-cursor-api-key $me env:CURSOR_API_KEY" \
  "$(jq -r '.vendors."cursor-agent".login | "\(.keychain[0].service) \(.keychain[0].account) \(.to)"' "$w")" \
  "cursor-agent's login is the crew's Cursor API key, handed in as CURSOR_API_KEY"
assert_eq "[\"$home/.config/firstmate/cursor-api-key\"] true" \
  "$(jq -r '.vendors."cursor-agent".login | "\(.file | tojson) \(.private)"' "$w")" \
  "or a file of fm's that only the operator may read"
assert_eq "[]" "$(jq -c '[.vendors."cursor-agent".login | (.keychain // [])[].service, (.file // [])[] | select(test("cursor-access-token|cursor-refresh-token|\\.config/cursor"))]' "$w")" \
  "and never agent login's own items or files, which hold its refresh token"
assert_eq '[]' "$(jq -c '[.vendors[].login | select(.to) | .to | select(startswith("env:") | not)]' "$w")" \
  "every login read outside the round goes in as a variable or a copy, nothing served from inside it"
# no vendor's login is anyone else's: gh's token, git's credential helper
assert_eq "[]" "$(jq -c '[.vendors[].login | (.keychain // []) + (.fallback.keychain // []) | .[].service
    | select(test("^gh:|github|git|refresh"; "i"))]' "$w")" \
  "no login, or fallback login, names gh's, git's or a refresh token's keychain item"

# the layers: top-level, then the project, flat keys then the role's own
cfg='vendor: mock
reviewer:
  network: legacy.example.org
policy:
  network: top.example.org
  read: /opt/extra
  worker:
    procs: 900
  reviewer:
    cpu: 60
default_project: app
projects:
  app:
    repo: .
    github: o/app
    base: main
    required_check: ci
    policy:
      never_read: ~/private
      reviewer:
        network: registry.npmjs.org cdn.playwright.dev
'
pol worker "$cfg"; assert_eq "0" "$?" "a project override resolves"
assert_eq '["top.example.org"]' "$(jq -c .network "$t/worker.json")" "a worker takes the top-level network"
assert_eq "900 14400" "$(jq -r '"\(.procs) \(.cpu)"' "$t/worker.json")" "and its own role's limits"
assert_eq "true" "$(jq '.read | index("/opt/extra") != null and index("/usr") != null' "$t/worker.json")" \
  "a layer's read adds to the toolchain rather than replacing it"
assert_eq "true" "$(jq --arg p "$home/private" --arg s "$home/.ssh" \
  '.never_read | index($p) != null and index($s) != null' "$t/worker.json")" \
  "the project's never_read adds to the floor"
assert_eq "app" "$(jq -r .project "$t/worker.json")" "and the project is named"
pol reviewer "$cfg"
assert_eq '["registry.npmjs.org","cdn.playwright.dev"]' "$(jq -c .network "$t/reviewer.json")" \
  "the project's reviewer network replaces the top-level one for a reviewer"
assert_eq "2048 60" "$(jq -r '"\(.procs) \(.cpu)"' "$t/reviewer.json")" "and the reviewer keeps its own limits"
# the pre-T-105 place for the reviewer's hosts still counts, for a reviewer only
pol reviewer 'vendor: mock
reviewer:
  mode: run
  network: registry.npmjs.org   # what setup needs
'
assert_eq '["registry.npmjs.org"]' "$(jq -c .network "$t/reviewer.json")" "reviewer: network: still reaches a reviewer's policy"
pol worker 'vendor: mock
reviewer:
  network: registry.npmjs.org
'
assert_eq "[]" "$(jq -c .network "$t/worker.json")" "and never a worker's"

# Host-policy refusal cases live in adapter-contract.test.sh.
# nor OpenAI's user file store (T-147): the captain refused it to every
# vendor, as an upload channel no round's conversation needs
out="$(pol worker 'policy:
  network: registry.npmjs.org sdmntprsouthcentralus.oaiusercontent.com
' 2>&1)"
assert_eq "65" "$?" "a policy cannot declare OpenAI's user file store"
assert_contains "$out" "OpenAI's user file store" "and is told what it is"
pol worker 'vendor: codex
' >/dev/null 2>&1
assert_contains "$(jq -r '.known_refused[].pattern' "$t/worker.json" 2>/dev/null)" "oaiusercontent" \
  "and every policy carries the known refusals, for the proxy and the report to read"
# nor turn the sandbox off: the escape hatch is the operator's shell's, and
# a branch can change config.yaml
for bad in 'policy:
  sockets: all
' 'policy:
  worker:
    write: /
' 'policy:
  procs: many
' 'policy:
  read: relative/path
' 'policy:
  read: /a(b)
' 'policy:
  worker: yes
' 'policy:
  sandbox: off
' 'policy:
  unsandboxed: 1
'; do
  pol worker "$bad" >/dev/null 2>&1
  assert_eq "65" "$?" "a policy that does not read is refused: $(printf '%s' "$bad" | tr '\n' ' ')"
done
fm_policy captain "" "$t/config.yaml" >/dev/null 2>&1
assert_eq "65" "$?" "the roles are worker and reviewer"


safe_rm_rf "$t"
PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
