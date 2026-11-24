# agy — Antigravity CLI plugin for Claude Code

Use Google's [Antigravity CLI (`agy`)](https://antigravity.google/) from
inside Claude Code: quick questions, delegated tasks, research, code review,
image generation, and **swarms** (a coordinator plus parallel workers) — with
long runs monitored in the background instead of cut off by a timeout.

> Fork of [`simplybychris/antigravity-plugin-cc`](https://github.com/simplybychris/antigravity-plugin-cc)
> (MIT), extended and tested against `agy` 1.5.16. See
> [What changed from upstream](#what-changed-from-upstream).

## What you get

| Command | What it does |
|---|---|
| `/agy:ask [flags] <prompt>` | Quick question. **Read-only by default** (`--write` to allow edits). |
| `/agy:delegate [flags] <task>` | Background job with no time limit; agy may edit files. |
| `/agy:research [flags] <topic>` | Read-only research as a background job. |
| `/agy:swarm [flags] <task>` | agy swarm (preview) as a background job: coordinator + parallel workers. |
| `/agy:status [job]` · `/agy:stop <job>` | Progress of background jobs; stop one (partial answer kept). |
| `/agy:review [focus]` | Read-only review of your uncommitted changes, untracked files included. |
| `/agy:image [--name S] [--output P] <description>` | Image via agy's built-in `generate_image`. |
| `/agy:setup` · `/agy:help` | Check install and auth; list flags, aliases and your models. |

Claude can also use it on its own: the `agy:runner` subagent forwards tasks
to agy when you say things like "ask agy to review this".

## Requirements

- Claude Code with plugin support.
- `agy` 1.2.0+ (1.5.x recommended), signed in once interactively. `/agy:setup`
  can install it.
- Bash, git and python3 (python3 for JSON parsing and background jobs).
  macOS, Linux or WSL.

## Install

```text
/plugin marketplace add sheng0122/antigravity-plugin-cc
/plugin install agy@antigravity-cc
/reload-plugins
/agy:setup
```

Both this fork and upstream name their marketplace `antigravity-cc`; remove
the upstream one first (`/plugin marketplace remove antigravity-cc`) if you
have it.

## Flags

Place them before the prompt. agy-native flags (`--add-dir`, `--sandbox`,
`--json-schema '<schema>'`) can follow the prompt and are passed through.

| Flag | Meaning |
|---|---|
| `--model A` | Alias, display name or id from `agy models` (see below). |
| `--effort E` | `low`·`medium`·`high`·`xhigh`·`max`. With `--model`, switches to that tier of the model (`--model opus --effort low` → Claude Opus (Low)). |
| `--resume ID` | Continue an earlier conversation. Every run prints its id. |
| `--agent NAME` | Run as an agent from `agy agents`. |
| `--timeout D` | `90s`, `15m`, `1h`; `0` = none. Default 30m for ask/review, none for jobs. |
| `--read-only` / `--write` | Block / allow file writes and terminal commands. |

**Model aliases** resolve at call time against `agy models`, picking the newest
version: `flash`, `flash-medium`, `flash-low`, `pro` (= Gemini Hydrogen),
`pro-low`, `neon`, `carbon`, `argon`, `orchestrator`, `opus`, `sonnet`
(High tier), `gpt-oss`. `/agy:help` shows what each one maps to on your account.

**agy skills**: start the prompt with `/<skill-name>`, e.g.
`/agy:ask /my-skill do the thing`. `/agy:ask /skills` lists the skills agy sees.

## Background jobs and swarms

`delegate`, `research` and `swarm` start a detached `agy` run and return at
once. Claude then follows it with `watch`, which:

- prints a progress line whenever something changes (steps, latest tool or
  text; for swarms the members and the latest message-board post);
- exits when the job finishes, and Claude relays the answer;
- exits with a **stall** notice after 15 minutes without any activity — the
  job keeps running and Claude asks you whether to keep waiting or stop it.
  For swarms, activity of any member counts, so a coordinator quietly waiting
  on its workers is not a stall.

There is no fixed time limit. `/agy:status` shows progress at any time;
`/agy:stop` interrupts agy so it finishes cleanly with a partial answer.
Job files live in `~/.local/state/agy-plugin/jobs` and are pruned after 14 days.

## Safety defaults

Since agy 1.5.7, print mode (`agy -p`) defaults to `auto` mode, which **edits
workspace files without asking**. So:

- `ask`, `review` and `research` are read-only: deny rules block file writes
  and terminal commands (blocking writes alone is not enough — agy falls back
  to shell commands).
- `delegate` and `swarm` may edit files; pass `--read-only` to prevent it.
- Actions agy wanted but could not get approval for are reported as a
  `WARNING`, instead of silently looking like success.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `AGY_PLUGIN_REPLY_LANG` | unset | Language for the plugin's built-in instructions, e.g. `Traditional Chinese (Taiwan)`. Unset: agy follows your request's language. |
| `AGY_PLUGIN_TIMEOUT` | `30m` | Default limit for ask/review. |
| `AGY_PLUGIN_MAX_DIFF_BYTES` | `100000` | Review size cap (stays under Linux's 128 KiB per-argument limit). |
| `AGY_PLUGIN_JOBS_DIR` | `~/.local/state/agy-plugin/jobs` | Where background jobs are kept. |

To set one for Claude Code, add it under `"env"` in `~/.claude/settings.json`.

## What changed from upstream

- **Background jobs** for delegate/research/swarm with live monitoring and
  stall detection instead of a fixed timeout; `/agy:swarm`, `/agy:status`,
  `/agy:stop`.
- **Model aliases fixed** for Gemini 4 (no "Pro" line any more) and
  tiered Claude models (they used to pick the Low tier); `--effort` with an
  alias picks the matching tier instead of being rejected by agy.
- **Read-only by default** where it matters (see Safety defaults).
- **Review**: untracked files with non-ASCII names, repos without commits,
  per-file and total size caps, a list of all changed files, and a 200-file cap.
  Fixed a multi-minute hang on large multibyte diffs.
- New flags `--effort`, `--resume`, `--agent`, `--timeout`, `--read-only`,
  `--write`; JSON status checking; blocked-action warnings.
- `/agy:image`: no longer exits silently when no image path is found; converts
  to the requested `--output` format.
- Auth detection for `GEMINI_API_KEY` and `AGY_ADC_AUTH`.

Full history: [CHANGELOG.md](./CHANGELOG.md).

## Development

```bash
bash tests/agy-run.test.sh
```

80 tests run the wrapper against a stub `agy` in a temporary `HOME`, covering
alias resolution, flag validation, prompt quoting, JSON handling, review edge
cases and background jobs (start, watch, stall, stop, swarm activity). They
never touch your real install.

## License

[MIT](./LICENSE). Original work © simplybychris; modifications © sheng0122.
