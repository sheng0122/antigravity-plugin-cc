---
description: Stop a running Antigravity (agy) background job
argument-hint: "<job-id>"
allowed-tools: Bash(bash:*)
---

Stop the job the user named. agy gets an interrupt first, so it finishes
cleanly and keeps any partial answer; it is force-killed only if it does not
exit within 20 seconds.

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" stop <job-id>
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" result <job-id>
```

Job id: `$ARGUMENTS`

If no id was given, run `status` (no id) to list jobs and ask which one to
stop. After stopping, show the partial answer from `result`, if any.
