# shellcheck shell=bash
# Seed a trusted legacy approval bound to a fixture's real branch.
seed_local_approval() { # <repo> <task> <branch> <actor>
  local head base patch
  head="$(git -C "$1" rev-parse "$3")"
  base="$(git -C "$1" merge-base main "$3")"
  patch="$(git -C "$1" diff-tree -r -p --no-renames "$base" "$head" | git patch-id --stable | cut -d' ' -f1)"
  python3 "$ROOT/tests/lib/evidence.py" "$ROOT" "$1/state" "$2" "$4" \
    "APPROVE:$2
REVIEWED:$2 verdict=APPROVE head=$head base=$base patch=$patch files=[]"
}
