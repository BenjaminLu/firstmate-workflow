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
# $S/down makes every call fail the way gh does when GitHub cannot be reached:
# a message on stderr, nothing on stdout, exit 1
if [ -f "$S/down" ]; then
  echo 'error connecting to api.github.com' >&2
  exit 1
fi

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
        # gate 7 read an approval that was sitting right there as nothing.
        # Each comment carries every field `gh pr view --json comments`
        # returns, oldest first as gh lists them, so a caller that picks
        # fields or relies on the order is tested against what gh sends.
        {
        printf '{"comments":['
        first=1; i=0
        while IFS=$'\t' read -r who body; do
          [ -n "$who" ] || continue
          [ "$first" = 1 ] || printf ','; first=0; i=$(( i + 1 ))
          jq -cn --arg who "$who" --arg body "$(printf '%s' "$body" | tr '\r' '\n')" \
            --argjson i "$i" --arg n "$n" '{
              id: ("IC_kwDOstub" + ($i|tostring)),
              author: {login: $who},
              authorAssociation: "OWNER",
              body: $body,
              createdAt: ("2026-01-01T00:" + (if $i < 10 then "0" else "" end) + ($i|tostring) + ":00Z"),
              includesCreatedEdit: false,
              isMinimized: false,
              minimizedReason: "",
              reactionGroups: [],
              url: ("https://github.com/o/r/pull/" + $n + "#issuecomment-" + ($i|tostring)),
              viewerDidAuthor: false
            }'
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
    # one line per comment on disk, so the newlines in a review body are
    # encoded here and decoded where the JSON is built - the two halves are
    # the only places that may know about it
    printf '%s\t%s\n' "${GH_AS:-reviewer-1}" "$(printf '%s' "$body" | tr '\n' '\r')" >> "$S/comments.$n"
    ;;
  pr:merge)
    n="$3"
    tmp="$(mktemp)"; awk -F'\t' -v OFS='\t' -v n="$n" '{if($1==n)$4="MERGED"; print}' "$S/prs" > "$tmp"
    mv "$tmp" "$S/prs"; echo "merged $n"
    ;;
  *) exit 0 ;;
esac
