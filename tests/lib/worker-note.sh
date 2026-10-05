# shellcheck shell=bash
# GitHub-shaped note transport shared by ordinary and rebuilt worker rounds.
note_gh() {
  mkdir -p "$1/stub"
  cat > "$1/stub/gh" <<'G'
#!/usr/bin/env bash
place="$(dirname "$0")/.."
printf '%s\n' "$*" >> "$place/ghcalls"
case "$1 $2" in
  "api repos/{owner}/{repo}/issues/${NOTE_PR:-9}/comments")
    [ "$*" = "api repos/{owner}/{repo}/issues/${NOTE_PR:-9}/comments --paginate --jq .[].body" ] || exit 64
    case "${NOTE_MODE:-always}" in
      lookup-fails) exit 1 ;;
      landed) tail -1 "$place/body" ;;
    esac
    exit 0 ;;
  'api '*) echo '{}'; exit 0 ;;
  'pr comment')
    if [ "${4:-}" != --body-file ]; then exit 0; fi
    cp "$5" "$place/body"
    count=$(grep -c '^pr comment .*--body-file' "$place/ghcalls")
    [ "${NOTE_MODE:-always}" != once ] || [ "$count" -le 1 ] || exit 0
    echo 'GraphQL: Something went wrong while executing your query on 2026-10-04T17:11:07Z. Please include `C81F:1B67BD:77CAE6:96A060:6AC288AB` when reporting this issue.' >&2
    exit 1 ;;
  'pr list') echo null; exit 0 ;;
esac
echo https://example.invalid/pull/42
G
  chmod +x "$1/stub/gh"
}
