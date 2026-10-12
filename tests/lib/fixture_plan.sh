#!/usr/bin/env bash
# T-302: put a fixture task past its plan, as firstmate does outside a round.
# The steps live in bin/lib/fm-fixture-plan.sh, shared with bin/fm-canary.sh;
# tests/worker-plan-first.test.sh never calls this.
#
#   tests/lib/fixture_plan.sh <code root> <repo> <task> [round] [head]
#
# Consumers: tests/lib/herdr.py tests/lib/self_pr_authoring.py
set -uo pipefail
[ $# -ge 3 ] || { echo "usage: fixture_plan.sh <code root> <repo> <task> [round] [head]" >&2; exit 64; }
exec bash "$1/bin/lib/fm-fixture-plan.sh" "$@"
