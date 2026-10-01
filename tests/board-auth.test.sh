#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/board.sh
. "$ROOT/tests/lib/board.sh"
XDG_CONFIG_HOME="$(safe_tmpdir)"; export XDG_CONFIG_HOME
# --- T-122: only the captain's browser, or a script holding the secret, writes ---
# A crew round can reach the board's port (the macOS sandbox cannot keep it
# off one loopback port), and so can any page in the captain's browser. Every
# route that writes or starts a program is refused to both, and nothing either
# can read hands them what it would take.
k="$(safe_tmpdir)"; mkdir -p "$k/bin" "$k/state/pending" "$k/design" "$k/board/public" "$k/src"
cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-herdr.py" "$k/bin/"
cp -R "$ROOT/bin/lib" "$k/bin/"   # the lifeline the board starts merges and rounds under (T-151)
cp "$ROOT/board/server.ts" "$k/board/"
cp "$ROOT/board/public/index.html" "$ROOT/board/public/ship.js" "$ROOT/board/public/diagram.js" "$k/board/public/"
fm_tasks_write /dev/stdin "$k/design/tasks" <<'J'
{"tasks":[{"id":"T-K1","title":"ready work","milestone":"M2","depends_on":[]},
          {"id":"T-K2","title":"awaiting its merge","milestone":"M2","depends_on":[]}]}
J
FM_ROOT="$k" "$k/bin/fm-emit.sh" --actor captain --type greenlit --en "go" --tw "開工" >/dev/null
jq -cn '{id:"D-900",kind:"merge",task:"T-K2",pr:9,title:"merge it"}' > "$k/state/pending/D-900.json"
# The merge helper records how it was called and answers as bin/fm-merge.sh
# does on a merge GitHub took: one line, `fm-merge: merged #<pr>`, exit 0.
# The editor records the path and, like `code <file>`, says nothing.
cat > "$k/bin/fm-merge.sh" <<'S'
#!/usr/bin/env bash
root="$(cd "$(dirname "$0")/.." && pwd)"
printf '%s\n' "$*" >> "$root/merge-calls"
pr=''
while [ $# -gt 0 ]; do
  case "$1" in --pr) pr="${2-}"; shift 2 ;; *) shift ;; esac
done
echo "fm-merge: merged #$pr"
S
printf '#!/usr/bin/env bash\necho "$*" >> "%s/opened"\n' "$k" > "$k/fake-editor"
chmod +x "$k/bin/fm-merge.sh" "$k/fake-editor"
printf 'editor: %s/fake-editor\n' "$k" > "$k/config.yaml"
echo "inside the repo" > "$k/src/visible"
# An empty port is refused here, never handed on (T-153): on 2026-09-29 a
# restart given an empty PORTK - an earlier board_port that found nothing -
# bound the operator's own 4173 while the captain's board was down.
given_port() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
start_k() {   # start_k <port>: the board on $k, its pid in pidk and port in PORTK
  given_port "$1" || {
    assert_eq "a port" "[$1]" "start_k is handed a port, never an empty one"; PORTK=''; return 1; }
  FM_ROOT="$k" FM_PORT="$1" bun run "$k/board/server.ts" > "$k/out" 2>&1 < /dev/null &
  pidk=$!
  PORTK="$(board_port "$k/out" "$pidk")" || PORTK=''
  [ -n "$PORTK" ] || { assert_eq "a port" "[]" "the fixture board on $k said which port it bound"; return 1; }
  wait_for 60 curl -sf "http://127.0.0.1:$PORTK/api/state"
}
assert_eq "1 1 0" "$(given_port ''; a=$?; given_port 41x; b=$?; given_port 0; echo "$a $b $?")" \
  "the suite's board helper refuses an empty or non-numeric port and takes a real one"
# FM_PORT set but not a port is refused by the board itself (64), never read
# as unset: Bun drops an empty variable from process.env, so `FM_PORT=` was
# the operator's 4173. A board that does start is stopped the moment it says
# where it listens, so this never leaves one bound.
port_refusal() {   # port_refusal <FM_PORT value> -> the board's exit code, or "started"
  FM_ROOT="$k" FM_PORT="$1" bun run "$k/board/server.ts" > "$k/port.out" 2>&1 < /dev/null &
  local p=$! n=0
  while kill -0 "$p" 2>/dev/null && [ "$n" -lt 300 ]; do
    grep -q '^board on ' "$k/port.out" 2>/dev/null && break
    sleep 0.1; n=$((n + 1))
  done
  if kill -0 "$p" 2>/dev/null; then kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; echo started
  else wait "$p"; echo "$?"; fi
}
for bad in '' ' ' abc 70000; do
  assert_eq "64" "$(port_refusal "$bad")" "a board given FM_PORT='$bad' refuses to start (64)"
  assert_contains "$(cat "$k/port.out" 2>/dev/null)" "FM_PORT is set but is not a port" \
    "and says why (FM_PORT='$bad')"
done
start_k 0
uk="http://127.0.0.1:$PORTK"
key="$XDG_CONFIG_HOME/firstmate/board-$PORTK.secret"
lines_k() { wc -l < "$k/state/events.jsonl" | tr -d ' '; }

# (4) the secret: made at start, 0600, outside the repository, 256 bits or more
assert_ok "test -f '$key'" "the board made its secret file under the config directory"
assert_eq "600" "$(perl -e 'printf "%o", (stat shift)[2] & 07777' "$key")" "the secret file is mode 0600"
case "$(cd "$(dirname "$key")" && pwd -P)/" in "$(cd "$k" && pwd -P)/"*) inrepo=yes ;; *) inrepo=no ;; esac
assert_eq "no" "$inrepo" "the secret file is outside the repository"
secret="$(cat "$key")"
assert_ok "grep -Eq '^[0-9a-f]{64,}$' '$key'" "the secret is at least 256 bits of hex"

# mint <origin> <port>: a one-time code the way the opener makes one
# (bin/fm-herdr.py board_login_url), printed as the part after /login#
mint() {
  PYTHONDONTWRITEBYTECODE=1 python3 -c '
import importlib.util, sys
s = importlib.util.spec_from_file_location("m", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.board_login_url(sys.argv[2], int(sys.argv[3])).split("#", 1)[1])' "$k/bin/fm-herdr.py" "$1" "$2"
}
login() {   # login <code> [curl args...]: the status; the body in $k/login-body, headers in $k/login-headers
  local body status; body="$(jq -cn --arg c "$1" '{code:$c}')"; shift
  status="$(curl -s -o "$k/login-body" -D "$k/login-headers" -w '%{http_code}' -X POST \
    -H 'content-type: application/json' "$@" -d "$body" "$uk/login")"
  cat "$k/login-headers" >> "$k/all-headers"
  printf '%s' "$status"
}
# the files holding a Set-Cookie among every response header this part keeps
# (each login's, and every read's below): there must be none
cookies_set() { grep -il '^set-cookie:' "$k/all-headers" "$k/reads" 2>/dev/null || true; }

# (2) the one-time code: works once, then never again; expired or wrong is refused
assert_eq "false" "$(curl -sf "$uk/api/session" | jq -r .writable)" "a tab with no token is not writable"
code1="$(mint "$uk" "$PORTK")"
assert_matches "$code1" '^[0-9]{13}\.[0-9a-f]{32}\.[0-9a-f]{64}$' "the opener mints a code of the board's shape"
assert_eq "403" "$(login "$code1")" "a code posted with no Origin is refused"
assert_eq "403" "$(login "$code1" -H 'Origin: http://evil.example')" "and one posted from another origin"
assert_eq "200" "$(login "$code1" -H "Origin: $uk")" "the code posted from the board's own page is taken"
# the tab's token comes back in the body, for the page to keep in its own
# sessionStorage, and never as a cookie: a browser sends a cookie for
# 127.0.0.1 to every port on it
token="$(jq -r '.token // empty' "$k/login-body")"
assert_matches "$token" '^[0-9a-f]{64}$' "it answers with the tab's token"
assert_ne "$secret" "$token" "which is not the secret itself"
assert_eq "" "$(cookies_set)" "and sets no cookie"
assert_eq "true" "$(curl -sf -H "Authorization: Bearer $token" "$uk/api/session" | jq -r .writable)" \
  "with the token the tab is writable"
assert_eq "403" "$(login "$code1" -H "Origin: $uk")" "the same code a second time is refused"
assert_eq "" "$(jq -r '.token // empty' "$k/login-body")" "and gives no token"
# (expiry is tested on its own below, on a board whose codes last half a second:
# a code 61 seconds old here was also issued before this board started)
# a fresh code with the last digit of its signature changed
good="$(mint "$uk" "$PORTK")"
case "$good" in *0) flipped="${good%?}1" ;; *) flipped="${good%?}0" ;; esac
assert_eq "403" "$(login "$flipped" -H "Origin: $uk")" "a code whose signature is wrong is refused"
assert_eq "403" "$(login "not-a-code" -H "Origin: $uk")" "and so is one that is not a code"
assert_eq "loginRefused" "$(jq -r .code "$k/login-body")" "with a code the page translates"
assert_eq "200" "$(login "$good" -H "Origin: $uk")" "the control: the same code unaltered is taken"

# (1) the refusals: every writing route, every missing or wrong part, 403 and nothing done
dec="$(jq -cn '{id:"D-900",chosen:"A"}')"
tsk="$(jq -cn '{task:"T-K1",action:"park"}')"
opn="$(jq -cn '{path:"src/visible"}')"
postk() {   # postk <route> <body> <curl args...>: the status; the body in $k/resp
  local route="$1" body="$2"; shift 2
  curl -s -o "$k/resp" -w '%{http_code}' -X POST "$@" -d "$body" "$uk$route"
}
zeros="$(printf '%064d' 0)"
n0="$(lines_k)"
for route in /decisions /tasks /open; do
  case "$route" in /decisions) body="$dec" ;; /tasks) body="$tsk" ;; *) body="$opn" ;; esac
  assert_eq "403" "$(postk "$route" "$body" -H "Origin: $uk" -H 'content-type: application/json')" \
    "$route with no credential is refused"
  assert_eq "writeCredential" "$(jq -r .code "$k/resp")" "$route says the tab has no credential"
  assert_eq "403" "$(postk "$route" "$body" -H "Origin: $uk" -H 'content-type: application/json' \
    -H "Authorization: Bearer $zeros")" "$route with a wrong bearer is refused"
  # what a cookie session would have held, sent as a cookie: the board reads
  # no cookie, so a server on another loopback port that caught one has nothing
  assert_eq "403" "$(postk "$route" "$body" -H "Origin: $uk" -H 'content-type: application/json' \
    -b "firstmate_board_$PORTK=$token")" "$route with the token only as a cookie is refused"
  assert_eq "writeCredential" "$(jq -r .code "$k/resp")" "$route says a cookie is no credential"
  assert_eq "403" "$(postk "$route" "$body" -H 'Origin: http://127.0.0.1:1' -H 'content-type: application/json' \
    -H "Authorization: Bearer $token")" "$route with a valid token from another loopback origin is refused"
  assert_eq "writeOrigin" "$(jq -r .code "$k/resp")" "$route says the request is not the board's own"
  assert_eq "403" "$(postk "$route" "$body" -H 'Origin: http://evil.example' -H 'content-type: application/json' \
    -H "Authorization: Bearer $token")" "$route with a valid token from another site is refused"
  assert_eq "writeOrigin" "$(jq -r .code "$k/resp")" "$route says so for the other site"
  assert_eq "403" "$(postk "$route" "$body" -H 'content-type: application/json' -H "Authorization: Bearer $token")" \
    "$route with a valid token and no Origin is refused"
  assert_eq "writeOrigin" "$(jq -r .code "$k/resp")" "$route says so with no Origin"
  assert_eq "403" "$(postk "$route" "$body" -H "Origin: $uk" -H 'content-type: text/plain' -H "Authorization: Bearer $token")" \
    "$route with a valid token and a text/plain body is refused"
  assert_eq "writeJson" "$(jq -r .code "$k/resp")" "$route says it takes JSON only"
  assert_eq "403" "$(wcurl "$PORTK" -s -o "$k/resp" -w '%{http_code}' -X POST -H 'content-type: text/plain' \
    -d "$body" "$uk$route")" "$route with the bearer and a text/plain body is refused"
  assert_eq "writeJson" "$(jq -r .code "$k/resp")" "$route says so to the bearer too"
done
# Refusals return synchronously before any helper can be launched.
assert_eq "$n0" "$(lines_k)" "no refusal emitted an event"
assert_fail "test -e '$k/state/decisions/D-900.json'" "no refusal recorded an answer"
assert_ok "test -e '$k/state/pending/D-900.json'" "and the card is still pending"
assert_fail "test -e '$k/merge-calls'" "no refusal ran the merge helper"
assert_fail "test -e '$k/opened'" "no refusal started the editor"

# (3) nothing read hands out the credential: every read route, from a tab
# holding the token, grepped for the secret, the token and a code not yet used
unused="$(mint "$uk" "$PORTK")"
: > "$k/reads"
for path in / /index.html /ship.js /diagram.js /api/state /api/i18n /api/session /login \
            "/file?path=src/visible" /open "/open?path=src/visible" /no-such-file; do
  curl -s -i -H "Authorization: Bearer $token" "$uk$path" >> "$k/reads"
done
curl -s -i -m 2 -H "Authorization: Bearer $token" "$uk/events" >> "$k/reads" || true
for route in /decisions /tasks /open /login; do
  curl -s -i -X POST -H "Origin: $uk" -H 'content-type: application/json' -d '{}' "$uk$route" >> "$k/reads"
done
assert_ok "grep -q '\"crew\"' '$k/reads'" "the reads were made (the control)"
assert_fail "grep -qF '$secret' '$k/reads'" "no response carries the secret"
assert_fail "grep -qF '$token' '$k/reads'" "no read carries the tab's token"
assert_fail "grep -qF '${unused##*.}' '$k/reads'" "no response carries a valid code"
assert_fail "grep -qF 'board-$PORTK.secret' '$k/reads'" "no response names the secret file"

# the secret sits outside the repository, so no path the board reads reaches it
ln -s "$key" "$k/src/key"
assert_eq "403" "$(curl -s -o "$k/resp" -w '%{http_code}' "$uk/file?path=src/key")" \
  "a symlink in the repository pointing at the secret is refused by /file"
assert_fail "grep -qF '$secret' '$k/resp'" "and does not leak it"
ln -s "$key" "$k/board/public/key.txt"
assert_eq "404" "$(curl -s -o "$k/resp" -w '%{http_code}' "$uk/key.txt")" \
  "and a symlink among the page's own files is not served either"
assert_fail "grep -qF '$secret' '$k/resp'" "nor leaked"
rm -f "$k/src/key" "$k/board/public/key.txt"

# (6) GET /open starts nothing, credential or not
assert_eq "405" "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" "$uk/open?path=src/visible")" \
  "GET /open is not a way to start the editor"
assert_fail "test -e '$k/opened'" "and it started nothing"

# with the credential, the board works as before
tabk() { postk "$@" -H "Origin: $uk" -H 'content-type: application/json' -H "Authorization: Bearer $token"; }
assert_eq "200" "$(tabk /tasks "$tsk")" "the captain's tab parks a task"
assert_eq "parked captain T-K1" "$(tail -1 "$k/state/events.jsonl" | jq -r '"\(.type) \(.actor) \(.task)"')" \
  "and the park is the captain's event"
assert_eq "200" "$(tabk /open "$opn")" "the captain's tab opens a file"
wait_for 10 test -s "$k/opened"
assert_contains "$(cat "$k/opened" 2>/dev/null)" "src/visible" "and the editor was handed it"
assert_eq "200" "$(wcurl "$PORTK" -s -o "$k/resp" -w '%{http_code}' -X POST -H 'content-type: application/json' \
  -d "$dec" "$uk/decisions")" "a script with the bearer answers the merge card"
wait_for 10 test -s "$k/merge-calls"
assert_contains "$(cat "$k/merge-calls" 2>/dev/null)" "--pr 9" "and the merge helper ran for it"
wait_for 20 jq -e '.merge == "merged"' "$k/state/decisions/D-900.json"
assert_eq "merged" "$(jq -r .merge "$k/state/decisions/D-900.json" 2>/dev/null)" \
  "and the decision settles as merged when the helper says it merged"

# (4) the secret's path and value appear nowhere under state/ or in the log
assert_eq "" "$(grep -rlF "board-$PORTK.secret" "$k/state" "$k/out" 2>/dev/null || true)" \
  "no state file or log names the secret file"
assert_eq "" "$(grep -rlF "$secret" "$k/state" "$k/out" 2>/dev/null || true)" \
  "and none holds the secret"
assert_eq "" "$(grep -rlF "$token" "$k/state" "$k/out" 2>/dev/null || true)" \
  "nor the tab's token"

# the secret survives a restart, so an open tab keeps working
kill "$pidk" 2>/dev/null; wait "$pidk" 2>/dev/null || true
start_k "$PORTK"
assert_eq "$secret" "$(cat "$key")" "a restart keeps the secret it found"
assert_eq "true" "$(curl -sf -H "Authorization: Bearer $token" "$uk/api/session" | jq -r .writable)" \
  "and the board still takes the tab's token after the restart"
assert_eq "200" "$(tabk /tasks "$(jq -cn '{task:"T-K1",action:"unpark"}')")" \
  "which still writes: the tab unparks the task"
assert_eq "unparked captain T-K1" "$(tail -1 "$k/state/events.jsonl" | jq -r '"\(.type) \(.actor) \(.task)"')" \
  "and the unpark is the captain's event"
# $unused was minted seconds ago and never redeemed: only the restart stands
# between it and a token
assert_eq "403" "$(login "$unused" -H "Origin: $uk")" "a code minted before the restart is not taken by the new board"
kill "$pidk" 2>/dev/null; wait "$pidk" 2>/dev/null || true

# expiry on its own: codes last half a second on this board, and each code here is
# issued after it started, correctly signed, from its own origin and unused,
# so the clock is the only rule that can refuse the first
FM_BOARD_CODE_TTL_MS=500 start_k "$PORTK"
late="$(mint "$uk" "$PORTK")"
sleep 0.6
assert_eq "403" "$(login "$late" -H "Origin: $uk")" "a code older than its lifetime is refused"
assert_eq "loginRefused" "$(jq -r .code "$k/login-body")" "with the code the page translates"
assert_eq "" "$(jq -r '.token // empty' "$k/login-body")" "and gives no token"
assert_eq "200" "$(login "$(mint "$uk" "$PORTK")" -H "Origin: $uk")" \
  "the control: a code minted the same way and used at once is taken"
kill "$pidk" 2>/dev/null; wait "$pidk" 2>/dev/null || true

# no response this part kept, each login's among them, set a cookie
assert_ok "grep -qi '^content-type:' '$k/all-headers'" "the login headers were kept (the control)"
assert_eq "" "$(cookies_set)" "no response the board sent set a cookie"

# revocation: remove the secret file and restart the board, and every token
# and bearer made from the old secret is refused
rm -f "$key"
start_k "$PORTK"
assert_ne "$secret" "$(cat "$key")" "a board restarted without its secret file makes a new one"
assert_eq "403" "$(tabk /tasks "$tsk")" "and the old tab's token no longer writes"
assert_eq "writeCredential" "$(jq -r .code "$k/resp")" "the tab is told it holds no credential"
assert_eq "403" "$(postk /tasks "$tsk" -H "Origin: $uk" -H 'content-type: application/json' \
  -H "Authorization: Bearer $secret")" "nor does the old secret as a bearer"
kill "$pidk" 2>/dev/null; wait "$pidk" 2>/dev/null || true

# --- T-145: a read-only tab signs in again from the page ---------------------
# POST /relogin makes the board run the opener fm.sh board runs (bin/
# fm-herdr.py board-login), so the one-time code goes to the browser and
# nowhere else. The browser here is a recorder standing in for osascript (macOS)
# and xdg-open / open (elsewhere), first on the board's PATH: what it is handed
# is what the captain's browser would be, and nothing is opened for real.
fb="$k/fake-browser"; mkdir -p "$fb"
cat > "$fb/osascript" <<S
#!/usr/bin/env bash
{ printf '%s\n' "\$*"; cat; } >> "$k/browser"
S
cat > "$fb/xdg-open" <<S
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$k/browser"
S
cp "$fb/xdg-open" "$fb/open"; chmod +x "$fb/osascript" "$fb/xdg-open" "$fb/open"
: > "$k/browser"; : > "$k/relogin-all"
relogin() {   # relogin [curl args...]: the status; the body in $k/rl-body; every answer kept in $k/relogin-all
  local status
  status="$(curl -s -o "$k/rl-body" -D "$k/rl-headers" -w '%{http_code}' -X POST "$@" "$uk/relogin")"
  cat "$k/rl-headers" "$k/rl-body" >> "$k/relogin-all"
  printf '%s' "$status"
}
addresses() { grep -oE '/login#[0-9]{13}\.[0-9a-f]{32}\.[0-9a-f]{64}' "$k/browser" | sed 's|^/login#||' | sort -u; }
PATH="$fb:$PATH" start_k 0
uk="http://127.0.0.1:$PORTK"
assert_eq "405" "$(curl -s -o /dev/null -w '%{http_code}' "$uk/relogin")" "GET /relogin opens nothing"
assert_eq "403" "$(relogin -H 'content-type: application/json' -d '{}')" "a re-login with no Origin is refused"
assert_eq "writeOrigin" "$(jq -r .code "$k/rl-body")" "and says the request is not the board's own"
assert_eq "403" "$(relogin -H 'Origin: http://evil.example' -H 'content-type: application/json' -d '{}')" \
  "a re-login from another site is refused"
assert_eq "403" "$(relogin -H 'Origin: http://127.0.0.1:1' -H 'content-type: application/json' -d '{}')" \
  "and one from another loopback port"
assert_eq "403" "$(relogin -H "Origin: $uk" -H 'content-type: text/plain' -d '{}')" \
  "a re-login that is not JSON is refused, as a cross-site form's would be"
assert_eq "writeJson" "$(jq -r .code "$k/rl-body")" "and says it takes JSON only"
assert_eq "400" "$(relogin -H "Origin: $uk" -H 'content-type: application/json' -d 'not json')" \
  "a body that does not parse is refused"
assert_eq "" "$(cat "$k/browser")" "no refusal sent the browser anywhere"
# the one the page makes: its own Origin, a JSON body, and no credential
assert_eq "200" "$(relogin -H "Origin: $uk" -H 'content-type: application/json' -d '{}')" \
  "the board's own page asks for a sign-in, with no credential, and is answered"
assert_eq "true new" "$(jq -r '"\(.ok) \(.tab)"' "$k/rl-body")" "and told a new tab was opened (no board tab was found)"
code="$(addresses)"
assert_eq "1" "$(grep -c . <<<"$code")" "the browser was handed one sign-in address"
assert_contains "$(cat "$k/browser")" "$uk/login#$code" "on this board's own address"
# a burst is refused, and opens nothing more
assert_eq "429" "$(relogin -H "Origin: $uk" -H 'content-type: application/json' -d '{}')" \
  "a second re-login within 10 seconds is refused"
assert_eq "reloginTooSoon" "$(jq -r .code "$k/rl-body")" "with a code the page translates"
assert_ok "grep -qi '^retry-after: [0-9]' '$k/rl-headers'" "and says when to try again"
assert_eq "429" "$(relogin -H "Origin: $uk" -H 'content-type: application/json' \
  -H "Authorization: Bearer $(secret_of "$PORTK")" -d '{}')" "the credential does not lift the limit"
assert_eq "1" "$(grep -c . <<<"$(addresses)")" "the burst sent the browser nowhere"
# the code went to the browser and to no answer, header, log or state file
assert_ok "grep -q '\"ok\":true' '$k/relogin-all'" "the answers were kept (the control)"
assert_fail "grep -qF '$code' '$k/relogin-all'" "no answer of the route carries the code"
assert_fail "grep -qF '/login#' '$k/relogin-all'" "nor any sign-in address"
assert_eq "" "$(grep -rlF "$code" "$k/state" "$k/out" 2>/dev/null || true)" "no state file or board log holds the code"
# and it was a real code: the browser's tab trades it for the token
assert_eq "200" "$(login "$code" -H "Origin: $uk")" "the address the browser got signs its tab in"
kill "$pidk" 2>/dev/null; wait "$pidk" 2>/dev/null || true
# the hourly cap, on a board whose gap is shortened to reach it: 12, then no more
: > "$k/browser"
PATH="$fb:$PATH" FM_BOARD_RELOGIN_GAP_MS=1 start_k 0
uk="http://127.0.0.1:$PORTK"
took=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  [ "$(relogin -H "Origin: $uk" -H 'content-type: application/json' -d '{}')" = 200 ] && took=$((took + 1))
  sleep 0.05
done
assert_eq "12" "$took" "twelve re-logins an hour are taken"
assert_eq "429" "$(relogin -H "Origin: $uk" -H 'content-type: application/json' -d '{}')" "the thirteenth is refused"
assert_eq "reloginHourly" "$(jq -r .code "$k/rl-body")" "and says the hourly cap was reached"
assert_eq "12" "$(grep -c . <<<"$(addresses)")" "the browser was sent to twelve sign-ins, not thirteen"
assert_fail "grep -qF '/login#' '$k/relogin-all'" "and no answer carried an address"
kill "$pidk" 2>/dev/null; wait "$pidk" 2>/dev/null || true
# a browser that never answers: the route stops the opener at its bound, and
# every process the opener started ends with it - none outlives the route
sb="$k/slow-browser"; mkdir -p "$sb"; : > "$k/slow-pids"
for b in osascript xdg-open open; do
  printf '#!/usr/bin/env bash\necho $$ >> %q\nexec sleep 30\n' "$k/slow-pids" > "$sb/$b"; chmod +x "$sb/$b"
done
PATH="$sb:$PATH" FM_BOARD_RELOGIN_TIMEOUT_MS=1500 start_k 0
uk="http://127.0.0.1:$PORTK"
assert_eq "502" "$(relogin -H "Origin: $uk" -H 'content-type: application/json' -d '{}')" \
  "a browser that never answers is given up on at the route's bound"
assert_eq "reloginFailed" "$(jq -r .code "$k/rl-body")" "and the page is told the sign-in did not open"
slow_left() { local p; for p in $(cat "$k/slow-pids"); do kill -0 "$p" 2>/dev/null && return 0; done; return 1; }
assert_ok "[ -s '$k/slow-pids' ]" "the opener had reached the browser (the control)"
assert_ok "wait_for 10 eval '! slow_left'" "and no process the opener started outlives the route"
kill "$pidk" 2>/dev/null; wait "$pidk" 2>/dev/null || true


safe_rm_rf "$k" "$XDG_CONFIG_HOME"
finish
