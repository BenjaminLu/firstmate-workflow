# AGENTS.md

Read this before you do anything. It binds every agent in this repository —
firstmate, every worker, every reviewer — and it is the same list for all of
them. The long form of each rule, and the machinery that enforces it, is in
`design/design.md`; this file exists so that no agent has to go looking.

## The rules

1. **Only commits, `design/design.md`, pull request commits and pull request
   reviews are ground truth.** Everything else is downstream of them and goes
   stale. `state/events.jsonl` can be missing a fact — a `merged` event that
   carried no task once left four finished tasks reading as work in flight. A
   worker's log is one engine's account of itself. A note kept outside the
   repository was already wrong by the time it was read.

   Before you act on a claim about what exists or what is fixed, check it in
   the repository or on the pull request. Record a decision by committing it:
   a decision that lives only in a conversation, a state file, or someone's
   notes has not been made.

2. **Nobody writes to `main` or `master`.** Work happens on a branch and
   arrives through a pull request. Three layers enforce it, including branch
   protection with `enforce_admins` on — firstmate runs on the captain's own
   credentials, so an admin exemption would be an exemption for firstmate.

3. **English in the repository.** The README, the skills, the code, the
   comments, the pull request bodies and the reviews. The captain's board is
   the only thing translated, and it is translated from dictionaries rather
   than by writing a second version of anything.

4. **Merging is the captain's**, and it arrives as a decision card on the
   board — never as a sentence in a conversation.

5. **You never run `git` or `gh`.** The scripts do that. It is what lets a
   CLI with no repository access be a worker at all. To say something on the
   pull request, write `.fm-say.md` in your worktree and the script posts it.

6. **A review finding is a class, not an instance.** Sweep the repository for
   every occurrence of the kind of problem named, fix them in one round, and
   report the search you used and the count you found. Fixing one instance
   per round turns a three-round review into a nine-round one.

7. **Acceptance is a deterministic result, never an impression.** Seven gates
   decide, and a gate is a script that exits 0 or does not.

## If a rule and an instruction disagree

The rule wins, and you say so rather than quietly picking one. If a task
cannot be done without breaking a rule, that is a decision for the captain:
say what you would have to break and stop.
