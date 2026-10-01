#!/usr/bin/env bash
# codex adapter. Hands the prompt to codex and maps its outcome onto the
# contract in _contract.md. It must never touch git or gh: the scripts above
# do all of that, which is what lets a CLI with no repository access still be
# a worker.
#
# The invocation is the non-interactive one on purpose. An adapter that opens
# a REPL hangs a dispatch until something kills it, and looks like a model
# thinking rather than a script waiting for a human who is not there.
#
#   codex.sh run <prompt> <worktree> <log>
#   codex.sh dimensions     -> which policy dimensions codex's own flags enforce here
# fm:review-run
set -uo pipefail
_fm_alib="$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
[ -r "$_fm_alib" ] || { echo "codex: missing $_fm_alib" >&2; exit 70; }
# shellcheck source=bin/adapters/_lib.sh
. "$_fm_alib"

# What codex's own flags enforce of the round's policy (T-105). On Linux
# its workspace-write sandbox confines the commands' writes to the working
# directory and the temp directories. Its network switch is on: codex has
# only on and off, the OS sandbox is what limits the network to the
# declared registries, and with it off the commands could not reach the
# proxy that names a refused host. On macOS its sandbox is a seatbelt,
# which cannot start inside sandbox-exec: there it is off and the outer one
# confines the commands instead. Everywhere: approval never, since nobody
# is there to approve; the commands' environment drops the policy's scrub
# list; MCP servers are emptied; and CODEX_HOME is a directory of the
# round's own holding only a copy of the login less its refresh token, so
# the operator's config.toml and profiles are not read. None of the repository files the
# policy keeps unloaded is one codex reads. Reading is not among them.
#
# codex runs every command as `$SHELL -lc <command>`, the operator's login
# shell (T-147). What that shell needs is fm-sandbox.sh's, for every vendor:
# TMPPREFIX inside the round's own TMPDIR for zsh's here-documents, and a
# login profile in the round's own HOME that puts the round's PATH back
# after the system's (macOS's path_helper puts Apple's xcrun shims first),
# so no codex flag is needed for either.
codex_native() {
  if [ "${FM_OUTER_OS:-}" = darwin ]; then
    echo "repo-config env ulimit"
  else
    echo "write repo-config env ulimit"
  fi
}
if [ "${1-}" = "dimensions" ]; then
  fm_adapter_policy; read -r -a native <<<"$(codex_native)"
  fm_adapter_dimensions "${native[@]}"; exit 0
fi

[ "${1-}" = "run" ] || { echo "usage: codex.sh run <prompt> <worktree> <log>" >&2; exit 64; }
prompt="${2-}"; tree="${3-}"; log="${4-}"
[ -f "$prompt" ] || { echo "codex: no prompt at $prompt" >&2; exit 64; }
[ -d "$tree" ]   || { echo "codex: no worktree at $tree" >&2; exit 64; }
fm_adapter_context "$0"
if [ "${FM_RUN_REVIEW:-}" = 1 ]; then
  tree="$(fm_adapter_codex_review_context)" || exit 64
fi

command -v codex >/dev/null 2>&1 || {
  # stderr, not the log: the log is what the VENDOR said, and a caller that
  # asks "did anything run?" must not be answered by the adapter's own
  # notice that nothing could
  echo "codex: codex is not installed - vendor unavailable" >&2; exit 2; }

# FM_ADAPTER_ARGS is deliberately unquoted: it carries whatever extra
# arguments the operator configured, and they have to split into words.
off="$(fm_adapter_mark "$log")"
# Review invocation policy is closed: the model comes from config.yaml and
# there are no additional operator flags needed to review. This also refuses
# attached short options, profiles, cwd changes and output redirection.
if [ "${FM_RUN_REVIEW:-}" = 1 ] && [ -n "${FM_ADAPTER_ARGS:-}" ]; then
  echo "codex: run-mode review does not accept FM_ADAPTER_ARGS" >&2; exit 64
fi
# an operator argument after these would win, and undo the policy
case " ${FM_ADAPTER_ARGS:-} " in
  *--sandbox*|*" -s "*|*--dangerously*|*--full-auto*|*--yolo*|*" -c "*|*--config*|*--add-dir*)
    echo "codex: FM_ADAPTER_ARGS changes permissions; refusing the round" >&2; exit 64 ;;
  # config.yaml's model is the one place a model is chosen (T-127)
  *" -m "*|*--model*)
    echo "codex: FM_ADAPTER_ARGS names a model; config.yaml is the one place a model is chosen; refusing the round" >&2; exit 64 ;;
esac
fm_adapter_policy
if [ "${FM_RUN_REVIEW:-}" = 1 ]; then
  case "$FM_OUTER_OS" in darwin|linux) ;; *) echo "codex: review requires the outer OS sandbox" >&2; exit 64 ;; esac
  [ -z "$FM_UNSANDBOXED" ] || { echo "codex: review requires the outer OS sandbox" >&2; exit 64; }
  python3 - "$FM_POLICY" "$FM_ROUND_CTL/review-policy.json" <<'PY' || exit 64
import json, sys
p = json.load(open(sys.argv[1]))
if p.get('role') != 'reviewer' or p.get('write') != ['{root}', '{tmp}']:
    sys.exit('codex: malformed reviewer policy')
p['review_git_readonly'] = True
p['repo_config'] = list(dict.fromkeys(p.get('repo_config', []) + ['.codex']))
with open(sys.argv[2], 'w') as f: json.dump(p, f)
PY
  FM_POLICY="$FM_ROUND_CTL/review-policy.json"
fi
if [ "${FM_OUTER_OS:-}" = darwin ]; then
  # sandbox-exec around codex confines every command it runs
  policy_args=(--sandbox danger-full-access)
else
  policy_args=(--sandbox workspace-write -c "sandbox_workspace_write.network_access=true")
fi
# the scrub list as codex's own globs, for the commands it runs
excl="$(python3 -c 'import json,sys
s = json.load(open(sys.argv[1]))["env_scrub"]
print(json.dumps(s["names"] + [p + "*" for p in s["prefixes"]], separators=(",", ":")))' "$FM_POLICY")" || {
  echo "codex: the policy at $FM_POLICY does not read" >&2; exit 65; }
policy_args+=(-c 'approval_policy="never"' -c 'mcp_servers={}'
              -c "shell_environment_policy.exclude=$excl")
if [ "${FM_ROLE:-}" = reviewer ]; then
  policy_args+=(-c 'project_doc_max_bytes=0')
fi
# no user profile: a CODEX_HOME of the round's own, in its temp directory.
# fm-sandbox.sh writes the login into it as it starts the round: a copy of
# the operator's auth.json with the refresh token emptied (T-117), never
# the file itself, which the round cannot read
codex_home="$FM_ROUND_TMP/codex-home"; mkdir -p "$codex_home" || exit 70
export CODEX_HOME="$codex_home"
# The credentials that outrank the ChatGPT-plan login CODEX_HOME's copy
# carries (T-121): codex documents OPENAI_API_KEY as switching it to
# API-key billing, and CODEX_API_KEY is the same alternative for fm's own
# login lookup (bin/fm-config.sh's VENDORS). Either, ambient in the
# operator's own shell, would silently bill a round to it instead of the
# subscription; shed unless the operator named codex in config.yaml's
# billing: block.
CODEX_OUTRANKING=(); while IFS= read -r w; do CODEX_OUTRANKING+=("$w"); done < <(fm_adapter_outranking codex)
launch=()
while IFS= read -r w; do launch+=("$w"); done < <(fm_adapter_env_words codex "${CODEX_OUTRANKING[@]}")
# the trailing "-" is codex's read-the-prompt-from-stdin marker and has to
# be the last argument, so FM_ADAPTER_ARGS goes before it
final_args=()
# Managed reviews derive their final answer outside the sandbox from the CLI
# event stream. They never grant the model write access to transport records.
if [ "${FM_ROLE:-}" != reviewer ]; then
  [ -z "${FM_FINAL_PATH:-}" ] || final_args=(--output-last-message "$FM_FINAL_PATH")
fi
# --json for a transcript the round's model comes back in (T-127), and
# config.yaml's model applied with codex's own flag
final_args+=(--json)
model_args=(); while IFS= read -r _fm_ma; do model_args+=("$_fm_ma"); done \
  < <(fm_adapter_model_args -m)
read -r -a native <<<"$(codex_native)"
fm_adapter_confine codex "$tree" "${native[@]}"
if [ -n "${FM_ATTEMPT_DIR:-}" ]; then
  ( cd "$tree" && "${FM_LAUNCH[@]}" ${launch[@]+"${launch[@]}"} codex exec --skip-git-repo-check "${policy_args[@]}" \
    ${final_args[@]+"${final_args[@]}"} ${model_args[@]+"${model_args[@]}"} ${FM_ADAPTER_ARGS:-} - < "$prompt" ) 2>&1 | tee -a "$log"
  fm_adapter_pipeline_status "${PIPESTATUS[@]}"
else
  ( cd "$tree" && "${FM_LAUNCH[@]}" ${launch[@]+"${launch[@]}"} codex exec --skip-git-repo-check "${policy_args[@]}" \
    ${final_args[@]+"${final_args[@]}"} ${model_args[@]+"${model_args[@]}"} ${FM_ADAPTER_ARGS:-} - < "$prompt" ) >> "$log" 2>&1
fi
rc=$?
msg="$(fm_adapter_model_refusal codex "${FM_MODEL:-}" "$log" "$off" "$rc")" && {
  echo "$msg; refusing the round" >&2
  [ -z "${FM_MODEL_REFUSED:-}" ] || printf 'codex\t%s\t%s\n' "$FM_MODEL" "$msg" >> "$FM_MODEL_REFUSED"
  exit 64
}
fm_adapter_verdict "$rc" "$log" "$off"
exit $?
