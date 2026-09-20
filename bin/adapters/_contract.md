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

The separation matters: if a model producing bad work looked the same as an
outage, an outage would look like the model failing and the crew would burn a
review round on nothing.

Every adapter passes `tests/adapter-contract.test.sh`. Add a vendor by adding a
file here and a line to `config.yaml`; nothing else in the system changes.
