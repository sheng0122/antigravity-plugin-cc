---
description: Start an Antigravity swarm (preview) — a coordinator plus parallel workers — as a monitored background job with no fixed time limit
argument-hint: "[--model <alias>] [--effort <level>] [--read-only] <task>"
allowed-tools: Bash(bash:*)
---

Run the user's task as an agy swarm: agy becomes a coordinator that adds
worker agents, which work in parallel and talk on a shared message board.
Swarms use far more quota than one agent; only run one when the user invoked
this command. Workers may edit files unless `--read-only` is given.

The user's task (opaque text):

```
$ARGUMENTS
```

## Run it as a monitored background job (no fixed time limit)

1. Start the job with the `Bash` tool (returns immediately):
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" swarm [flags] "<text>"
   ```
   Note the job id from the `[wrapper] job started: <id>` line and tell the
   user in one line that it is running and how to check it (`/agy:status <id>`).
2. Follow it with the `Bash` tool **with `run_in_background: true`**:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" watch <id>
   ```
   It prints a progress line whenever something changes and exits by itself.
   Do not poll; you are notified when it exits. Then read its output:
   - exit `0` — finished: give the user agy's answer verbatim, plus the
     `[wrapper] conversation: <id>` line and any `WARNING` about blocked actions.
   - exit `2` — stalled: no activity for 15 minutes, but the job is still
     running. Show the user `status <id>` output and ask whether to keep
     waiting (run `watch <id>` again in the background) or stop it
     (`stop <id>`). Never stop a job without the user's go-ahead.
   - exit `1` — failed or died: relay the error lines verbatim.
3. If the user asks for progress meanwhile, run `status <id>` and summarise it.

`watch` accepts `--stall <dur>` (default `15m`) and `--interval <dur>`
(default `20s`) after the id.

For swarms, `watch` and `status` also report the members and the latest
message-board posts, and count any member's activity as progress, so a
coordinator that is quietly waiting on its workers is not mistaken for a stall.

## Flags (place them **before** the prompt; lift them out of the user's text)

- `--model <alias|name|id>` — aliases: `flash-low`, `flash-medium`, `flash`,
  `pro-low`, `pro` (= Gemini Hydrogen), `neon`, `carbon`, `argon`,
  `orchestrator`, `sonnet`, `opus`, `gpt-oss`. `/agy:help` shows the table.
- `--effort <low|medium|high|xhigh|max>` — with `--model`, picks that tier of
  the model (e.g. `--model opus --effort low` → Claude Opus (Low)).
- `--resume <conversation-id>` — continue an earlier agy conversation.
- `--agent <name>` — run as an agent listed by `agy agents`.
- `--timeout <dur>` — e.g. `90s`, `15m`, `1h`; `0` = no limit.
- `--read-only` / `--write` — block, or allow, file writes and terminal commands.

agy-native flags may follow the prompt and are forwarded as-is (`--add-dir
<dir>`, `--sandbox`, `--json-schema '<schema>'`).

Pass the user's text as **one** shell-safe argument (quote it so `"`, `$`,
`;`, backticks and newlines cannot break out); never splice it into the
command.

If the wrapper reports `agy is not installed` or `not authenticated`, stop and
tell the user to run `/agy:setup`.

If the task is empty, ask what the swarm should work on.
