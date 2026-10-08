# shellcheck shell=bash
# fm:sourced

# A task is T-<3+ digits> (the plan's) or SK-<3+ digits> (a skill update's);
# those are the only prefixes design/tasks/, the log and the branches use.
# Digits are spelled out: a bracket range follows the locale's collation.
FM_TASK_DIG=0123456789
FM_TASK_UP=ABCDEFGHIJKLMNOPQRSTUVWXYZ; FM_TASK_LOW=abcdefghijklmnopqrstuvwxyz
FM_TASK_ID="^(T|SK)-[${FM_TASK_DIG}]{3,}$"
fm_task_is() { [[ "${1-}" =~ $FM_TASK_ID ]]; }   # fm_task_is <id>
# A branch is named after its task, prefix in either case: t-117-… is T-117,
# sk-001-… is SK-001. The hyphen after the prefix may be missing, as in the
# earliest t004-… branches; the number is the whole run of digits, so
# t-1170-… is T-1170, never T-117. One leading [A-Za-z0-9._-]+/
# segment is allowed, e.g. feature/t-117-x. Two segments name no task.
fm_task_of_branch() {   # fm_task_of_branch <branch> -> the task, or 1
  local re="^([${FM_TASK_UP}${FM_TASK_LOW}${FM_TASK_DIG}._-]+/)?([tT]|[sS][kK])-?([${FM_TASK_DIG}]{3,})(-.*)?$" p
  [[ "${1-}" =~ $re ]] || return 1
  p="${BASH_REMATCH[2]}"
  case "$p" in t|T) p=T ;; *) p=SK ;; esac
  printf '%s-%s' "$p" "${BASH_REMATCH[3]}"
}
# A pull request's title leads with its task and a colon, exactly as every
# worker opens one: "T-117: …", "SK-001: …". GitHub's 'Revert "T-105: …"'
# leads with no task, and so names none.
fm_task_of_title() {    # fm_task_of_title <title> -> the task, or 1
  local re="^((T|SK)-[${FM_TASK_DIG}]{3,}):"
  [[ "${1-}" =~ $re ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}
# The task a pull request belongs to: its branch's, and its title's only
# when the branch names none.
fm_task_of_pr() {       # fm_task_of_pr <branch> <title> -> the task, or 1
  fm_task_of_branch "${1-}" || fm_task_of_title "${2-}"
}
