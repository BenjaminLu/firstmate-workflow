# The adapter contract

An adapter is the only place a vendor's name appears. Everything above it —
dispatch, gates, review, merge — is vendor-agnostic, and stays that way because
an adapter is allowed to do exactly one thing.

```
usage:    <vendor>.sh run <prompt-file> <worktree-dir> <log-file>
does:     hands the prompt to that vendor's CLI and lets it edit files in <worktree-dir>
must not: run git or gh
must not: write anywhere outside <worktree-dir> and <log-file>
exits:    0  done
          1  ran, but did not achieve it (the model gave up, the output is unfit)
          2  vendor unavailable (CLI missing, not logged in, out of quota, network down)
```

Only `2` falls back to the next vendor in `config.yaml`. A `1` is a normal
failed attempt and goes to the gates and the reviewer like any other.

**The exit code is not the verdict.** `cursor-agent` prints
`Authentication required` and exits `0`; a vendor that is out of quota or off
the network can do the same. An adapter that trusted the exit code would
report done, the gates would run against an untouched worktree, and the
reviewer would spend a round on nothing. So the verdict is decided by what
the CLI *said*, in `_lib.sh`, in one place for every adapter:

- the run's own output matches an unavailability signature -> `2`, whatever it exited
- the exit code is one vendors use for unavailable (`2 4 41 69 75`) -> `2`
- a non-zero exit -> `1`
- exit `0` having said nothing at all -> `1`
- otherwise -> `0`

The fallback chain appends to one log, so a verdict only ever reads the bytes
its own run added - the previous vendor's auth error must not condemn the
next one.

`fm_vendor_chain` builds the order and `fm_run_chain` runs it, both in
`bin/fm-config.sh`, so the worker and the reviewer fall back identically.

The separation matters: if a model producing bad work looked the same as an
outage, an outage would look like the model failing and the crew would burn a
review round on nothing.

Every adapter passes `tests/adapter-contract.test.sh`. Add a vendor by adding a
file here and a line to `config.yaml`; nothing else in the system changes.
