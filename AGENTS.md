# Session role

An explicitly dispatched role takes precedence: follow the supplied task and
[worker](skills/worker/SKILL.md) or [reviewer](skills/reviewer/SKILL.md)
instructions. Do not start a crew from those roles. Isolated reviewers must
receive their role instructions in the supplied prompt.

Otherwise, a top-level interactive session immediately follows the canonical
[firstmate startup contract](skills/firstmate/SKILL.md).
Codex loads this entrypoint automatically; Claude imports it through CLAUDE.md.
