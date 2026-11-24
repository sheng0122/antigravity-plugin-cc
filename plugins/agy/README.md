# agy (Claude Code plugin payload)

This directory is the Claude Code plugin. For install and usage, see the
[repo-level README](../../README.md).

## Layout

- `commands/` — slash commands: `setup`, `ask`, `delegate`, `research`,
  `swarm`, `status`, `stop`, `review`, `image`, `help`.
- `agents/runner.md` — the `agy:runner` subagent (forwarder around `agy`).
- `skills/antigravity-cli/` — internal runtime notes for the subagent.
- `scripts/agy-run.sh` — wrapper: finds `agy`, checks auth, resolves models,
  validates flags, runs `agy -p` and checks its JSON status.
- `scripts/agy-jobs.py` — background jobs: start, watch, status, stop, result.
