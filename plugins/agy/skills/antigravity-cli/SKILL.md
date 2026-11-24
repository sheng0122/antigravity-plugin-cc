---
name: antigravity-cli
description: Internal runtime contract for invoking the Antigravity CLI (`agy`) from the `agy` subagent. Not user-invocable.
user-invocable: false
---

# Antigravity CLI runtime

Use this skill only inside the `agy` subagent.

## Helpers

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" ask   [flags] "<prompt>" [agy-flags...]
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" start [flags] "<task>"   [agy-flags...]
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" watch|status|stop|result <job-id>
```

- `ask` runs synchronously, **read-only by default** (`--write` allows file
  writes and commands), capped at 30 minutes.
- `start` launches a detached background job with no time limit that may
  edit files (`--read-only` blocks that). `watch <id>` follows it and exits
  `0` done, `1` failed, `2` stalled (still running, no activity for 15m).
- Wrapper flags go **before** the prompt: `--model`, `--effort`, `--resume`,
  `--agent`, `--timeout`, `--read-only`, `--write`. agy-native flags
  (`--add-dir`, `--sandbox`, `--json-schema`) go after it.
- `--model` aliases resolve against `agy models` at call time; with
  `--effort`, the wrapper picks that tier of the model. Run
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" help` for the table.

## Rules of engagement

Keep the user's task text intact and let `agy` do the work. Never stop a
background job unless the user asked for it.

## What this skill does NOT do

- Does not install or authenticate `agy`. That is `/agy:setup`'s job.
- Does not retry, summarize, or post-process `agy`'s output.

## Error handling

If the wrapper exits non-zero, return its stderr verbatim:

- `127` — `agy` binary not found.
- `1` — not authenticated, run failed, no diff (`review`), or an agy status
  other than `SUCCESS`.
- `3` — agy's own print timeout (the conversation id is printed for `--resume`).
- `64` — bad wrapper usage (unknown model, bad duration or effort, empty value).
