---
description: Ask the Antigravity CLI (agy) a quick question and return its answer verbatim (read-only by default)
argument-hint: "[--model <alias>] [--effort <level>] [--resume <id>] [--agent <name>] [--write] <prompt>"
allowed-tools: Bash(bash:*)
---

Run a quick, synchronous prompt through `agy` and return its response
verbatim — no paraphrase or commentary.

The user's request (opaque text):

```
$ARGUMENTS
```

Use the `Bash` tool:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" ask [flags] "<prompt>"
```

`ask` is **read-only by default**: agy cannot write files or run terminal
commands. Add `--write` only when the user wants agy to change things. It is
capped at 30 minutes; for anything long or open-ended use `/agy:delegate`,
which runs as a monitored background job instead.

Show the `[wrapper] conversation: <id>` line so the user can follow up with
`--resume <id>`, and pass on any `[wrapper] WARNING` about blocked actions.

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

If the request is empty, ask what they want to ask Antigravity.
