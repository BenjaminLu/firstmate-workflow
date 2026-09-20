#!/usr/bin/env bash
# A gh that remembers. Backed by $GHSTATE so a whole dispatch-to-merge loop can
# run with no network: pull requests get numbers, comments accumulate, checks
# answer, and a merge sticks.
set -uo pipefail
S="${GHSTATE:?GHSTATE must be set}"
mkdir -p "$S"
[ -f "$S/next" ] || echo 100 > "$S/next"

arg() { local want="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = "$want" ] && { printf '%s' "${2-}"; return; }; shift; done; }
# real gh applies --jq to its own output; a stub that ignores it lets a caller
# see raw JSON and mistake "non-empty" for "matched"
JQ="$(arg --jq "$@")"
emit_json() { if [ -n "$JQ" ]; then jq -r "$JQ"; else cat; fi; }

case "${1-}:${2-}" in
  pr:create)
    n="$(cat "$S/next")"; echo $(( n + 1 )) > "$S/next"
    head="$(arg --head "$@")"; title="$(arg --title "$@")"
    printf '%s\t%s\t%s\tOPEN\n' "$n" "$head" "$title" >> "$S/prs"
    : > "$S/comments.$n"
    echo "https://example.invalid/pull/$n"
    ;;
  pr:list)
    printf '[' > "$S/out"; first=1
    while IFS=$'\t' read -r n head title state; do
      [ -n "$n" ] || continue
      [ "$first" = 1 ] || printf ',' >> "$S/out"; first=0
      printf '{"number":%s,"state":"%s","title":"%s","headRefName":"%s","mergedAt":null}' \
        "$n" "$state" "$title" "$head" >> "$S/out"
    done < "$S/prs"
    printf ']\n' >> "$S/out"; emit_json < "$S/out"
    ;;
  pr:view)
    # real gh resolves a branch name to its pull request, so the stub must too
    ref="$3"
    n="$(awk -F'\t' -v x="$ref" '$1==x||$2==x{print $1}' "$S/prs" | tail -1)"
    [ -n "$n" ] || n="$ref"
    state="$(awk -F'\t' -v n="$n" '$1==n{print $4}' "$S/prs" | tail -1)"
    case " $* " in
      *" comments "*)
        # jq builds the JSON, because a real review body has newlines and
        # quotes in it: interpolating one into a string by hand produced a
        # raw control character, the whole document failed to parse, and
        # gate 7 read an approval that was sitting right there as nothing
        {
        printf '{"comments":['
        first=1
        while IFS=$'\t' read -r who body; do
          [ -n "$who" ] || continue
          [ "$first" = 1 ] || printf ','; first=0
          jq -cn --arg who "$who" --arg body "$(printf '%s' "$body" | tr '\r' '\n')" \
            '{author:{login:$who},body:$body}'
        done < "$S/comments.$n" 2>/dev/null
        printf ']}\n'
        } | emit_json
        ;;
      *) printf '{"state":"%s"}\n' "${state:-OPEN}" | emit_json ;;
    esac
    ;;
  pr:checks)  [ -f "$S/red" ] && exit 1; echo "ci pass"; exit 0 ;;
  pr:comment)
    n="$3"; body="$(arg --body "$@")"
    printf '%s\t%s\n' "${GH_AS:-reviewer-1}" "$(printf '%s' "$body" | tr '\n' '\r')" >> "$S/comments.$n"
    ;;
  pr:merge)
    n="$3"
    tmp="$(mktemp)"; awk -F'\t' -v OFS='\t' -v n="$n" '{if($1==n)$4="MERGED"; print}' "$S/prs" > "$tmp"
    mv "$tmp" "$S/prs"; echo "merged $n"
    ;;
  *) exit 0 ;;
esac
