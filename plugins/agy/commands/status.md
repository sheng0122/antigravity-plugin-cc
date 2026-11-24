---
description: Show progress of Antigravity (agy) background jobs — delegate, research and swarm runs
argument-hint: "[job-id]"
allowed-tools: Bash(bash:*)
---

With a job id, show that job's progress; without one, list recent jobs.

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" status [<job-id>]
```

Job id (may be empty): `$ARGUMENTS`

Summarise the output for the user in a few lines (state, elapsed time, steps,
latest activity; for swarms the members and latest board posts). If the job
has finished, fetch the full answer with `result <job-id>` and give it
verbatim.
