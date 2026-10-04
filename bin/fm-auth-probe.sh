#!/usr/bin/env bash
# One way to ask whether the login a crew round would get actually works
# here (T-121). A crew round that starts on a login nobody checked is how
# codex ran out of quota mid-round on 2026-09-26 and gemini's expired OAuth
# was found only when a canary round failed.
#
# The login asked about is the round's, never the operator's own session
# (T-121). It is resolved by fm-sandbox.sh's own lookup
# (`fm-sandbox.sh login-env`, the same code `run` hands a round its login
# with): claude's crew token, or the interactive fallback; cursor-agent's
# firstmate-cursor-api-key item or ~/.config/firstmate/cursor-api-key as
# CURSOR_API_KEY; codex's auth.json copy, less its refresh token. A variable
# the round sheds (fm_adapter_shed: ANTHROPIC_API_KEY and the rest, unless
# config.yaml's billing: chose it) is neither counted as a login nor handed
# to the probe. No login a round could use is `unauthenticated` (or
# `expired`) before the vendor's CLI is asked anything.
#
# The probe: a fixed argv (never FM_ADAPTER_ARGS or anything else the
# operator configured), stdin closed, an environment of HOME, PATH, TMPDIR,
# USER and LOGNAME - HOME and TMPDIR the probe's own, as a round's are
# (T-128) - plus exactly the credentials the round would get and the
# vendor's own config directory pointed where the adapter points it, and a
# time limit (FM_AUTH_PROBE_TIMEOUT, default 20s). Prints exactly one word
# on its own line - authenticated, unauthenticated, expired,
# quota-exhausted, keychain-blocked, indeterminate, timeout, unavailable - the vendor's CLI
# version it probed, and a one-line reason in English and Traditional
# Chinese. It never prints the vendor CLI's own output or a secret.
#
# gemini has no non-interactive status command in its docs or in any
# transcript this repository carries, so nothing of gemini's but --version
# runs here: with a login present its answer is `indeterminate`, which is
# never read as authenticated - a gemini round is refused until its login
# can be verified (fm_auth_refuses).
#
#   bin/fm-auth-probe.sh <claude|codex|cursor-agent|gemini>
set -uo pipefail
exec < /dev/null

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# _lib.sh: the shed list and the billing choice (fm_adapter_shed), and
# through it fm-config.sh's fm_policy - one reading of each, not a copy
_fm_alib="$HERE/adapters/_lib.sh"
[ -r "$_fm_alib" ] || { echo "fm-auth-probe: missing $_fm_alib" >&2; exit 70; }
# shellcheck source=bin/adapters/_lib.sh
. "$_fm_alib"

vendor="${1:-}"
[ -n "$vendor" ] || { echo "usage: fm-auth-probe.sh <$(fm_vendors | paste -sd "|" -)>" >&2; exit 64; }
grep -qxF -- "$vendor" <<<"$(fm_vendors)" || { echo "fm-auth-probe: unknown vendor: $vendor" >&2; exit 64; }

print_result() {  # print_result <status> <version> <en> <tw>
  printf 'status: %s\n' "$1"
  printf 'vendor: %s\n' "$vendor"
  printf 'version: %s\n' "${2:-unknown}"
  printf 'en: %s\n' "$3"
  printf 'tw: %s\n' "$4"
}

if ! command -v "$vendor" >/dev/null 2>&1; then
  print_result unavailable "" "$vendor is not installed" "尚未安裝 $vendor"
  exit 0
fi
version="$("$vendor" --version </dev/null 2>/dev/null | head -1)"
version="${version:-unknown}"

# --- the round's own login, resolved the way the round resolves it --------
work="$(mktemp -d "${TMPDIR:-/tmp}/fm-auth-probe.XXXXXX")" || exit 70
# shellcheck disable=SC2064  # the path is fixed now
trap "rm -rf '$work'" EXIT
# a signal exits, and the EXIT trap then cleans up (tests/traps.test.sh)
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
mkdir -p "$work/tmp/home" "$work/ctl" || exit 70
chmod 700 "$work/ctl"
policy="${FM_POLICY:-}"
if [ -z "$policy" ] || [ ! -r "$policy" ]; then
  policy="$work/policy.json"
  if ! fm_policy "${FM_ROLE:-worker}" "" "$(fm_adapter_config)" > "$policy" 2>/dev/null; then
    print_result indeterminate "$version" \
      "the crew policy does not read, so the round's login could not be resolved" \
      "crew 政策無法讀取，無法解析本回合的登入"
    exit 0
  fi
fi
shed=(); while IFS= read -r s; do [ -n "$s" ] && shed+=(--shed="$s"); done < <(fm_adapter_shed "$vendor")
"$HERE/fm-sandbox.sh" login-env --policy="$policy" --vendor="$vendor" --tmp="$work/tmp" --ctl="$work/ctl" \
  ${shed[@]+"${shed[@]}"} > "$work/source" 2> "$work/login.err"
login_rc=$?
# fm-sandbox.sh's own refusal: fm's words about where it looked, never the
# login itself
why="$(sed -n "s/^fm-sandbox: $vendor is not logged in: //p" "$work/login.err" | head -1)"
# claude's and cursor-agent's refusals already carry the policy's own hint
# (how to keep a crew token or key); codex and gemini have none there
login_fix_en=''; login_fix_tw=''
case "$vendor" in
  codex)  login_fix_en="; run \`codex login\` outside a round"
          login_fix_tw="；請在回合外執行 \`codex login\`" ;;
  gemini) login_fix_en="; start gemini once outside a round and sign in"
          login_fix_tw="；請在回合外啟動一次 gemini 並登入" ;;
esac
if [ "$login_rc" -eq 77 ]; then
  case "$why" in
    *'has expired'*)
      print_result expired "$version" \
        "the login a $vendor round would get has expired: ${why:-no reason given}$login_fix_en" \
        "$vendor 回合會拿到的登入已過期：${why:-未說明原因}$login_fix_tw" ;;
    *)
      print_result unauthenticated "$version" \
        "$vendor has no login a round could use: ${why:-no reason given}$login_fix_en" \
        "$vendor 沒有回合可用的登入：${why:-未說明原因}$login_fix_tw" ;;
  esac
  exit 0
elif [ "$login_rc" -ne 0 ]; then
  print_result indeterminate "$version" \
    "the round's login for $vendor could not be resolved (fm-sandbox.sh exit $login_rc)" \
    "無法解析 $vendor 回合的登入（fm-sandbox.sh 結束碼 ${login_rc}）"
  exit 0
fi

if [ "$vendor" = gemini ]; then
  print_result indeterminate "$version" \
    "gemini's login cannot be verified, so rounds on it are refused: gemini has no documented non-interactive status command" \
    "gemini 的登入無法驗證，因此拒絕在其上執行回合：gemini 沒有已記載的非互動登入狀態檢查指令"
  exit 0
fi

# The vendor's own status check, fixed: an operator argument or a config
# default must never reach this argv.
case "$vendor" in
  claude)       argv=(claude auth status) ;;
  codex)        argv=(codex login status) ;;
  cursor-agent) argv=(cursor-agent status) ;;
esac

# Resolve these before run_probe scrubs exported FM_* variables. Only the
# Darwin cursor status check needs the secret-service boundary (T-188).
probe_os="${FM_SANDBOX_OS:-$(uname -s | tr '[:upper:]' '[:lower:]')}"
probe_tool="${FM_SANDBOX_TOOL:-sandbox-exec}"
probe_confined=''
if [ "$vendor" = cursor-agent ] && [ "$probe_os" = darwin ]; then
  probe_confined=1
  if ! probe_profile="$(python3 "$HERE/lib/fm_sandbox_policy.py" auth-probe-profile)"; then
    print_result keychain-blocked "$version" \
      "could not confine cursor-agent's keychain access" \
      "無法限制 cursor-agent 的鑰匙圈存取"
    exit 0
  fi
  # No unconfined fallback: a missing tool or refused profile never starts
  # cursor. The marker distinguishes wrapper failure from cursor's answer.
  # shellcheck disable=SC2016  # expanded by the confined shell, not this probe
  argv=("$probe_tool" -p "$probe_profile" /bin/sh -c
        'touch "$1"; shift 1; exec "$@"' _ "$work/started" "${argv[@]}")
fi

# Where the adapter points the vendor's own configuration, so the probe
# reads the round's login and never the operator's ~/.claude or ~/.codex.
vendor_env=()
case "$vendor" in
  claude) mkdir -p "$work/tmp/claude-config" || exit 70
          vendor_env=(CLAUDE_CONFIG_DIR="$work/tmp/claude-config") ;;
  codex)  mkdir -p "$work/tmp/codex-home" || exit 70
          vendor_env=(CODEX_HOME="$work/tmp/codex-home") ;;
esac

# The time limit. No `timeout(1)` is assumed to exist (it does not ship
# with macOS), and the status check is never put in the background and
# watched by polling its pid (T-151): it runs in the foreground under a
# small runner of its own, which blocks until the first of three things the
# kernel reports - the check exits, the limit passes, or this probe dies
# (bin/lib/fm_lifeline.py's ProcessExit: kqueue on macOS, a pidfd on
# Linux). On the last two it ends the check's whole process group, SIGTERM
# then SIGKILL a second later, before it exits itself; a check that exits
# first has whatever it left in its group ended too. So nothing the check
# started outlives the probe, even a probe killed outright (SIGKILL, where
# no trap runs). A probe sent SIGTERM alone runs its trap once the runner
# returns, which is at most the limit later, and the check is gone by then.
timeout_secs="${FM_AUTH_PROBE_TIMEOUT:-20}"
probe_out=''
probe_rc=0
probe_timedout=''
# shellcheck disable=SC2016  # Python, not shell
_fm_probe_runner='
import os, select, signal, subprocess, sys, time
sys.path.insert(0, sys.argv[1])
from fm_lifeline import ProcessExit, OwnerGone
limit, out, mark, argv = float(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5:]
try:
    owner = ProcessExit(os.getppid())
except (OwnerGone, RuntimeError):
    sys.exit(70)
wake_r, wake_w = os.pipe()
os.set_blocking(wake_r, False); os.set_blocking(wake_w, False)
signal.set_wakeup_fd(wake_w)
signal.signal(signal.SIGCHLD, lambda *_: None)
stop = []
for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(signum, lambda signum, _frame: stop.append(signum))
group = dict(process_group=0) if sys.version_info >= (3, 11) else dict(preexec_fn=os.setpgrp)
with open(out, "wb") as f:
    try:
        child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=f,
                                 stderr=subprocess.STDOUT, **group)
    except OSError:
        sys.exit(127)
def signal_group(signum):
    try:
        os.killpg(child.pid, signum)
    except (ProcessLookupError, PermissionError):
        pass
def end_group():
    signal_group(signal.SIGTERM)
    try:
        child.wait(1)
    except subprocess.TimeoutExpired:
        pass
    signal_group(signal.SIGKILL)
    child.wait()
deadline = time.monotonic() + limit
why = None
while why is None:
    left = deadline - time.monotonic()
    try:
        ready, _, _ = select.select([owner, wake_r], [], [], max(0.0, left))
    except InterruptedError:
        ready = []
    try:
        while os.read(wake_r, 512):
            pass
    except BlockingIOError:
        pass
    if child.poll() is not None:
        why = "exited"
    elif stop:
        why = "stopped"
    elif owner in ready and owner.gone():
        why = "owner"
    elif time.monotonic() >= deadline:
        why = "timeout"
if why == "exited":
    code = child.returncode
    signal_group(signal.SIGKILL)   # whatever the check left in its group
    sys.exit(code if code >= 0 else 128 - code)
end_group()
if why == "timeout":
    open(mark, "w").close()
    sys.exit(124)
sys.exit(128 + stop[0] if stop else 129)
'
run_probe() {
  local out="$work/out" keep="HOME PATH TMPDIR USER LOGNAME" n kv
  rm -f "$work/timedout"
  (
    # the environment is emptied but for these, and the round's credentials
    # are exported, never put on a command line, where ps would show them
    home="$work/tmp/home" tmpd="$work/tmp" path="$PATH" user="${USER:-}" logname="${LOGNAME:-}"
    for n in $(compgen -e); do
      case " $keep " in *" $n "*) ;; *) unset "$n" 2>/dev/null ;; esac
    done
    export HOME="$home" TMPDIR="$tmpd" PATH="$path" USER="$user" LOGNAME="$logname"
    if [ -f "$work/ctl/env" ]; then
      while IFS= read -r kv; do [ -n "$kv" ] && export "${kv?}"; done < "$work/ctl/env"
      rm -f "$work/ctl/env"
    fi
    for kv in ${vendor_env[@]+"${vendor_env[@]}"}; do export "${kv?}"; done
    # exec: the runner's parent is this probe itself, the owner it watches
    exec python3 -c "$_fm_probe_runner" "$HERE/lib" "$timeout_secs" "$out" "$work/timedout" "${argv[@]}"
  ) </dev/null >/dev/null 2>&1
  probe_rc=$?
  [ ! -e "$work/timedout" ] || probe_timedout=1
  probe_out="$(cat "$out" 2>/dev/null)"
}
run_probe 2>/dev/null
rm -f "$work/ctl/env"

# Never printed: read only to classify, by the same signatures the adapters
# use to tell a live outage from a working run (bin/adapters/_lib.sh),
# narrowed to what a status check itself says.
_FM_QUOTA='quota exceeded|quota exhausted|out of quota|rate limit exceeded|rate limit reached|rate-limited|rate limited|429 too many requests|too many requests,|status 429'
_FM_EXPIRED='expired|token has expired|please log in again|session expired'
_FM_UNAUTH='not authenticated|not logged in|no credentials|please run [a-z0-9 ._-]{0,30}login|please use [a-z0-9 ._-]{0,30}login|login required|authentication required|authentication failed|unauthori[sz]ed|401 unauthorized|403 forbidden|status 401|status 403|invalid api key|missing api key|no api key found|set an auth method|no auth method|specify one of the following environment variables'

# claude auth status, verified live against the installed CLI, prints
# exactly one JSON object with a boolean loggedIn - a machine-readable
# answer, so it is parsed rather than pattern-matched. It says whether a
# credential is there (a CLAUDE_CODE_OAUTH_TOKEN reads loggedIn:true
# without being checked against the service), not whether the service takes
# it; that part is left to the round's own outage signatures. codex and
# cursor-agent, verified the same way, answer in plain text ("Not logged
# in"), which the shared signatures below already catch.
claude_json=''
if [ "$vendor" = claude ] && [ -z "$probe_timedout" ]; then
  claude_json="$(python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except ValueError:
    raise SystemExit
v = d.get("loggedIn")
if v is True: print("authenticated")
elif v is False: print("unauthenticated")
' <<<"$probe_out" 2>/dev/null)"
fi

status=''
if [ -n "$probe_timedout" ]; then
  status=timeout
elif [ -n "$probe_confined" ] && [ ! -e "$work/started" ]; then
  status=keychain-blocked
elif [ -n "$claude_json" ]; then
  status="$claude_json"
elif grep -qiE "$_FM_QUOTA" <<<"$probe_out"; then
  status=quota-exhausted
elif grep -qiE "$_FM_EXPIRED" <<<"$probe_out"; then
  status=expired
elif [ "$vendor" = cursor-agent ] && [ "$probe_rc" -eq 0 ] && grep -q 'Logged in' <<<"$probe_out"; then
  status=authenticated
elif [ "$vendor" = cursor-agent ] && grep -qi keychain <<<"$probe_out"; then
  status=keychain-blocked
elif grep -qiE "$_FM_UNAUTH" <<<"$probe_out"; then
  status=unauthenticated
elif [ "$probe_rc" -eq 0 ] && [ -n "$probe_out" ]; then
  status=authenticated
else
  # exit 0 with nothing to show, or a nonzero exit with no signature this
  # probe recognises: neither counts as an answer either way
  status=indeterminate
fi

# The fix is for the round's login, not the operator's own: a round never
# sees `claude` or `cursor-agent login`'s session.
fix_en=''; fix_tw=''
case "$vendor" in
  claude)
    fix_en="make a crew token with \`claude setup-token\` and keep it as fm doctor says, or set claude: api-key in config.yaml's billing block"
    fix_tw="請以 \`claude setup-token\` 建立 crew token 並依 fm doctor 所示保存，或在 config.yaml 的 billing 區塊設定 claude: api-key" ;;
  codex)
    fix_en="run \`codex login\` outside a round"
    fix_tw="請在回合外執行 \`codex login\`" ;;
  cursor-agent)
    fix_en="replace the crew Cursor API key (security add-generic-password -s firstmate-cursor-api-key -a \"\$USER\" -w)"
    fix_tw="請更換 crew 的 Cursor API key（security add-generic-password -s firstmate-cursor-api-key -a \"\$USER\" -w）" ;;
esac
case "$status" in unauthenticated|expired) ;; *) fix_en=''; fix_tw='' ;; esac

case "$status" in
  authenticated)
    print_result authenticated "$version" \
      "$vendor's own status check confirms the login a round would get" \
      "$vendor 自身的登入狀態檢查確認回合會拿到的登入有效" ;;
  unauthenticated)
    print_result unauthenticated "$version" \
      "$vendor says the login a round would get is not signed in${fix_en:+; $fix_en}" \
      "$vendor 表示回合會拿到的登入尚未登入${fix_tw:+；$fix_tw}" ;;
  expired)
    print_result expired "$version" \
      "the login a $vendor round would get has expired${fix_en:+; $fix_en}" \
      "$vendor 回合會拿到的登入已過期${fix_tw:+；$fix_tw}" ;;
  quota-exhausted)
    print_result quota-exhausted "$version" \
      "$vendor says its quota is exhausted; check the vendor's own dashboard for when it resets" \
      "$vendor 表示額度已用盡；請至該廠商的後台查看重置時間" ;;
  keychain-blocked)
    if [ -n "$probe_confined" ] && [ ! -e "$work/started" ]; then
      print_result keychain-blocked "$version" \
        "could not confine cursor-agent's keychain access" \
        "無法限制 cursor-agent 的鑰匙圈存取"
    else
      print_result keychain-blocked "$version" \
        "cursor-agent needs keychain storage, which crew rounds deny" \
        "cursor-agent 需要鑰匙圈儲存，而 crew 回合禁止存取鑰匙圈"
    fi ;;
  timeout)
    print_result timeout "$version" \
      "$vendor's status check did not answer within ${timeout_secs}s, so its login cannot be verified and rounds on it are refused" \
      "$vendor 的登入狀態檢查在 ${timeout_secs} 秒內未回應，因此無法驗證登入，拒絕在其上執行回合" ;;
  indeterminate)
    print_result indeterminate "$version" \
      "$vendor's status check answered in a way this probe does not recognise, so its login cannot be verified and rounds on it are refused" \
      "$vendor 的登入狀態檢查回應無法辨識，因此無法驗證登入，拒絕在其上執行回合" ;;
esac
exit 0
