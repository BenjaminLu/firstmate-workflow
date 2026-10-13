# shellcheck shell=bash
# Caller/consumer globals are checked when linting the feature suites.
# shellcheck disable=SC2034,SC2154
# The plant cache shared by tests/ci-lints.test.sh and
# tests/ci-lints-hygiene.test.sh: both plant into their own fixture $q.
# One gate run per fixture STATE, not one per assertion: every plant used
# to run a full nested gate, and the stage that measures the gate's own
# budget was mostly measuring that.
#
# The cache invalidates itself off a signature of the fixture rather than
# off the author remembering to clear it. The first version needed a
# `replant` call after every write, one was missed, and the assertion read
# the previous run - green for an assertion that tested nothing, which is
# the class this suite exists to catch.
planted=''; planted_sig=''; planted_runs=0
# The content, not the metadata. `ls -ld` prints the mtime to the minute
# on the BSD tools this runs on, so rewriting a file with different
# content of the same size seconds later produced an identical signature -
# and the assertion then read the PREVIOUS fixture's gate run and passed.
# A plant that creates or deletes a file was safe; one that edits in place
# was not, and those are the ones this suite added.
fixture_sig() { find "$q" ${external_home:+"$external_home"} -type f -exec shasum {} + 2>/dev/null | sort | shasum | cut -c1-40; }
plant() {   # plant <label> <expected fragment> [stage, default fast]
  local label="$1" want="$2" stage="${3:-fast}" sig
  sig="$stage:$(fixture_sig)"
  if [ "$sig" != "$planted_sig" ]; then
    planted="$(FM_ROOT="$q" bash "$q/bin/ci.sh" --stage "$stage" 2>&1)"
    planted_sig="$sig"
    planted_runs=$((planted_runs + 1))
  fi
  assert_contains "$planted" "$want" "$label"
}
