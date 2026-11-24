#!/usr/bin/env bash
# agy-run.sh — Claude Code wrapper around Google Antigravity CLI (`agy`).
# Subcommands: check | ask | review | image | help.
# `--model` (on ask) resolves an alias against `agy models` and passes the
# result to agy's own --model flag for that call only.

set -euo pipefail

AGY_SETTINGS_FILE="${HOME}/.gemini/antigravity-cli/settings.json"
AGY_SETTINGS_LOCKDIR="${HOME}/.gemini/antigravity-cli/.agy-plugin.lock"
AGY_SETTINGS_BACKUP="${HOME}/.gemini/antigravity-cli/settings.json.agy-plugin.bak"
AGY_SETTINGS_SENTINEL="${HOME}/.gemini/antigravity-cli/.agy-plugin.patched"

find_agy() {
  if command -v agy >/dev/null 2>&1; then
    command -v agy
    return 0
  fi
  for candidate in \
      "$HOME/.local/bin/agy" \
      "/opt/antigravity/bin/agy" \
      "/usr/local/bin/agy"; do
    if [ -x "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

auth_status() {
  if [ -n "${ANTIGRAVITY_API_KEY:-}" ] || [ -n "${GEMINI_API_KEY:-}" ]; then
    echo "api-key"
  elif [ -n "${AGY_ADC_AUTH:-}" ]; then
    echo "adc"
  elif [ -d "$HOME/.config/antigravity" ] || [ -d "$HOME/.gemini/antigravity-cli" ]; then
    echo "oauth"
  else
    echo "missing"
  fi
}

j_esc() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

cmd_check() {
  if ! path="$(find_agy | head -n1)"; then
    cat <<JSON
{ "installed": false, "path": "", "version": "", "auth": "unknown",
  "error": "agy binary not found; install with: curl -fsSL https://antigravity.google/cli/install.sh | bash" }
JSON
    return 0
  fi
  version="$("$path" --version </dev/null 2>/dev/null | head -n1 || echo unknown)"
  auth="$(auth_status)"
  printf '{ "installed": true, "path": "%s", "version": "%s", "auth": "%s", "error": "" }\n' \
    "$(j_esc "$path")" "$(j_esc "$version")" "$(j_esc "$auth")"
}

require_ready() {
  if ! path="$(find_agy)"; then
    echo "error: agy is not installed." >&2
    echo "       install: curl -fsSL https://antigravity.google/cli/install.sh | bash" >&2
    exit 127
  fi
  if [ "$(auth_status)" = "missing" ]; then
    echo "error: agy is not authenticated." >&2
    echo "       run \`agy\` once interactively, or export ANTIGRAVITY_API_KEY" >&2
    exit 1
  fi
  echo "$path"
}

# Each row: comma-separated aliases | ERE matched against the lowercased
# display name from `agy models` | ERE that wins a version tie (may be
# empty) | description shown when no listing is available. Aliases pick the
# newest version in their family.
MODEL_ALIASES='flash-low|^gemini [0-9.]+ flash [(]low[)]$||newest Gemini Flash (Low)
flash-medium,flash-med|^gemini [0-9.]+ flash [(]medium[)]$||newest Gemini Flash (Medium)
flash,flash-high|^gemini [0-9.]+ flash [(]high[)]$||newest Gemini Flash (High)
pro-low|^gemini [0-9.]+ hydrogen [(]low[)]$||newest Gemini Hydrogen (Low)
pro,pro-high,hydrogen|^gemini [0-9.]+ hydrogen [(]high[)]$||newest Gemini Hydrogen (High)
neon|^gemini [0-9.]+ neon [(]high[)]$||newest Gemini Neon (High)
carbon|^gemini [0-9.]+ carbon [(]high[)]$||newest Gemini Carbon (High)
argon|^gemini [0-9.]+ argon [(]high[)]$||newest Gemini Argon (High)
orchestrator|^orchestrator [(]carbon[)]$||Orchestrator (Carbon plans, Hydrogen executes)
sonnet,claude-sonnet|^claude sonnet [0-9.]+( [(].*[)])?$|[(]high[)]$|newest Claude Sonnet (High)
opus,claude-opus|^claude opus [0-9.]+( [(].*[)])?$|[(]high[)]$|newest Claude Opus (High)
gpt-oss,gpt-oss-120b|^gpt-oss 120b( [(].*[)])?$|[(]medium[)]$|GPT-OSS 120B'

# Older agy builds lack --model, ignore it in -p runs, or hang in
# `agy models` on an open stdin.
MIN_AGY_VERSION="1.2.0"

TAB="$(printf '\t')"

# Since agy 1.5.7 print mode defaults to `auto`, which edits workspace files
# without asking. Deny rules apply in every mode; both are needed because the
# agent falls back to shell commands when write_file is denied.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS_DIR="${AGY_PLUGIN_JOBS_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agy-plugin/jobs}"
# Optional language for the wrapper's own built-in instructions (e.g. review);
# unset means agy answers in whatever language the request is in.
REPLY_LANG="${AGY_PLUGIN_REPLY_LANG:-}"

# Print-mode runs have no time limit by default; a hung run would block the
# caller forever. Override per call with --timeout, or with AGY_PLUGIN_TIMEOUT.
PRINT_TIMEOUT="${AGY_PLUGIN_TIMEOUT:-30m}"
# Review diffs are passed as one argv string; Linux caps a single argument at
# 128 KiB, so stay below that.
MAX_DIFF_BYTES="${AGY_PLUGIN_MAX_DIFF_BYTES:-100000}"

# agy accepts Go durations ("90s", "15m", "1h30m"; "0" = no limit) but prints
# its usage and exits 0 on a bad one, so validate here.
check_duration() {
  [[ "$1" =~ ^(0|([0-9]+([.][0-9]+)?(ns|us|ms|s|m|h))+)$ ]] && return 0
  echo "error: invalid timeout '$1' (use e.g. 90s, 15m, 1h30m, or 0 for no limit)" >&2
  exit 64
}

check_effort() {
  case "$1" in low|medium|high|xhigh|max) return 0 ;; esac
  echo "error: invalid --effort '$1' (use low|medium|high|xhigh|max)" >&2
  exit 64
}

READ_ONLY_SETTINGS='{"permissions":{"deny":["write_file(*)","command(*)"]}}'

AWK_VERSION_NEWER='
function newer(a, b,    x, y, na, nb, n, i) {
  na = split(a, x, "."); nb = split(b, y, ".")
  n = na > nb ? na : nb
  for (i = 1; i <= n; i++) {
    if (x[i] + 0 > y[i] + 0) return 1
    if (x[i] + 0 < y[i] + 0) return 0
  }
  return 0
}'

require_model_support() {
  local path="$1" raw version
  raw="$("$path" --version </dev/null 2>/dev/null || true)"
  version="$(printf '%s\n' "$raw" | grep -oE '[0-9]+[.][0-9]+([.][0-9]+)?' | head -n1 || true)"
  if [ -z "$version" ]; then
    echo "[wrapper] note: could not read the agy version; assuming --model works" >&2
    return 0
  fi
  if [ "$(awk -v a="$MIN_AGY_VERSION" -v b="$version" "$AWK_VERSION_NEWER"'
      BEGIN { print newer(a, b) }')" = 1 ]; then
    echo "error: agy $version is too old for --model (needs $MIN_AGY_VERSION or newer)." >&2
    echo "       update it with \`agy update\`." >&2
    exit 1
  fi
}

# Prints "id<TAB>display name" per model. Some agy builds print names only,
# in which case the id column is empty.
list_models() {
  local path="$1" raw
  raw="$("$path" models </dev/null 2>/dev/null)" || return 1
  printf '%s\n' "$raw" | awk '
    { sub(/\r$/, "") }
    /^[[:space:]]*$/ || /:[[:space:]]*$/ || /^Fetching / { next }
    {
      tab = index($0, "\t")
      if (tab > 0) { id = substr($0, 1, tab - 1); name = substr($0, tab + 1) }
      else { id = ""; name = $0 }
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name != "") print id "\t" name
    }'
}

# Line of $1 (list_models output) whose name matches ERE $2 and has the
# newest version. On a version tie, a name matching ERE $3 wins.
_newest_match() {
  printf '%s\n' "$1" | PATTERN="$2" PREFER="${3:-}" awk -F '\t' "$AWK_VERSION_NEWER"'
    NF >= 2 && tolower($2) ~ ENVIRON["PATTERN"] {
      version = ""
      count = split(tolower($2), word, " ")
      for (i = 1; i <= count; i++) if (word[i] ~ /^[0-9]+([.][0-9]+)*$/) { version = word[i]; break }
      preferred = ENVIRON["PREFER"] != "" && tolower($2) ~ ENVIRON["PREFER"]
      if (best == "" || newer(version, best_version) ||
          (!newer(best_version, version) && preferred && !best_preferred)) {
        best = $0; best_version = version; best_preferred = preferred
      }
    }
    END { if (best != "") print best }'
}

# Line of $1 whose id or name equals $2, ignoring case.
_exact_match() {
  printf '%s\n' "$1" | WANT="$2" awk -F '\t' '
    NF >= 2 && (tolower($1) == tolower(ENVIRON["WANT"]) || tolower($2) == tolower(ENVIRON["WANT"])) { print; exit }'
}

_model_name() {
  printf '%s' "${1#*"$TAB"}"
}

# The id when the listing has one, otherwise the display name.
_model_arg() {
  local id="${1%%"$TAB"*}"
  if [ -n "$id" ]; then
    printf '%s' "$id"
  else
    _model_name "$1"
  fi
}

# Prints "pattern|prefer|description" for alias $1 (already lowercased).
_alias_row() {
  local want="$1" aliases pattern prefer description
  case "$want" in ""|*,*) return 1 ;; esac
  while IFS='|' read -r aliases pattern prefer description; do
    case ",$aliases," in
      *",$want,"*) printf '%s|%s|%s' "$pattern" "$prefer" "$description"; return 0 ;;
    esac
  done <<<"$MODEL_ALIASES"
  return 1
}

# $1 = output fd, $2 = list_models output (may be empty).
print_model_table() {
  local fd="${1:-2}" models="${2:-}"
  {
    if [ -n "$models" ]; then
      echo "Aliases (case-insensitive), resolved against \`agy models\`:"
    else
      echo "Aliases (case-insensitive). \`agy models\` could not be read, so they are shown unresolved:"
    fi
    local aliases pattern prefer description match target
    while IFS='|' read -r aliases pattern prefer description; do
      target="$description"
      if [ -n "$models" ]; then
        match="$(_newest_match "$models" "$pattern" "$prefer")"
        if [ -n "$match" ]; then
          target="$(_model_name "$match")"
        else
          target="(not available: $description)"
        fi
      fi
      printf '  %-28s  -> %s\n' "$(printf '%s' "$aliases" | sed 's/,/, /g')" "$target"
    done <<<"$MODEL_ALIASES"
    if [ -n "$models" ]; then
      echo
      echo "Available models (names and ids are accepted verbatim, case-insensitive):"
      printf '%s\n' "$models" | awk -F '\t' '{ if ($1 != "") printf "  %-32s  %s\n", $2, $1; else printf "  %s\n", $2 }'
    fi
  } >&"$fd"
}

_current_default_model() {
  [ -f "$AGY_SETTINGS_FILE" ] || return 1
  grep -oE '"model"[[:space:]]*:[[:space:]]*"[^"]*"' "$AGY_SETTINGS_FILE" 2>/dev/null \
    | sed -E 's/.*"model"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' \
    | head -n1
}

model_value_error() {
  echo "error: --model requires a non-empty value (e.g. --model pro)" >&2
  local path models=""
  if path="$(find_agy)"; then
    models="$(list_models "$path" || true)"
  fi
  print_model_table 2 "$models"
  local current; current="$(_current_default_model 2>/dev/null || true)"
  if [ -n "$current" ]; then
    echo >&2
    echo "Tip: omit --model to use your current default (\"$current\")." >&2
  fi
  exit 64
}

# Model names carry their effort tier ("Claude Opus 5.5 (High)") and agy
# rejects a conflicting --effort, so with both given, switch to the same
# family's tier named by the effort. $1 = list_models output, $2 = resolved
# --model value (id or name), $3 = effort. Prints the new value, or fails with
# the tiers that exist. Untiered names (e.g. Orchestrator) are left alone.
is_tiered() {
  local tier; tier="$(printf '%s' "${1##* (}" | tr '[:upper:]' '[:lower:]')"
  case "$1" in *" ("*")") ;; *) return 1 ;; esac
  case "$tier" in "low)"|"medium)"|"high)"|"xhigh)"|"max)") return 0 ;; esac
  return 1
}

apply_effort_tier() {
  local models="$1" model="$2" effort="$3" line name base tiers
  line="$(_exact_match "$models" "$model")"
  [ -n "$line" ] || { printf '%s' "$model"; return 0; }
  name="$(_model_name "$line")"
  is_tiered "$name" || { printf '%s' "$model"; return 0; }
  base="${name% (*}"
  line="$(_exact_match "$models" "$base ($effort)")"
  if [ -n "$line" ]; then
    _model_arg "$line"
    return 0
  fi
  tiers="$(printf '%s\n' "$models" | BASE="$base" awk -F '\t' '
    index(tolower($2), tolower(ENVIRON["BASE"]) " (") == 1 {
      t = substr($2, length(ENVIRON["BASE"]) + 3); sub(/[)]$/, "", t); out = out (out ? ", " : "") tolower(t)
    } END { print out }')"
  echo "error: $base has no '$effort' tier (available: ${tiers:-none})." >&2
  return 64
}

# Prints the value for `agy --model`: the id when `agy models` lists one,
# otherwise the display name.
resolve_model() {
  local path="$1" input="$2"
  local lc; lc="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')"
  local row=""; row="$(_alias_row "$lc" || true)"
  local models
  if ! models="$(list_models "$path")" || [ -z "$models" ]; then
    if [ -n "$row" ]; then
      echo "error: could not list models with \`agy models\` (run it directly to see why)." >&2
      echo "       aliases need that list; pass the full model name instead." >&2
      exit 1
    fi
    echo "[wrapper] note: could not list models; passing '$input' to agy unchecked" >&2
    printf '%s' "$input"
    return 0
  fi
  local match pattern prefer description
  match="$(_exact_match "$models" "$input")"
  if [ -z "$match" ] && [ -n "$row" ]; then
    IFS='|' read -r pattern prefer description <<<"$row"
    match="$(_newest_match "$models" "$pattern" "$prefer")"
    [ -n "$match" ] || echo "error: alias '$input' has no matching model in \`agy models\` (expected: $description)" >&2
  elif [ -z "$match" ]; then
    echo "error: unknown model '$input' (not an alias and not listed by \`agy models\`)" >&2
  fi
  if [ -n "$match" ]; then
    _model_arg "$match"
    return 0
  fi
  print_model_table 2 "$models"
  exit 64
}

# Recovers settings.json left patched by a killed 0.4.x run, which swapped
# the model in place instead of passing --model.
restore_orphaned_backup() {
  [ -f "$AGY_SETTINGS_SENTINEL" ] || {
    if [ -f "$AGY_SETTINGS_BACKUP" ]; then
      echo "[wrapper] note: stale backup with no sentinel; removing $AGY_SETTINGS_BACKUP" >&2
      rm -f "$AGY_SETTINGS_BACKUP"
    fi
    return 0
  }
  local pid; pid="$(head -n1 "$AGY_SETTINGS_SENTINEL" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  if [ -f "$AGY_SETTINGS_BACKUP" ]; then
    mv "$AGY_SETTINGS_BACKUP" "$AGY_SETTINGS_FILE"
    echo "[wrapper] recovered orphaned settings backup from PID ${pid:-unknown}" >&2
  fi
  rm -f "$AGY_SETTINGS_SENTINEL"
  rm -rf "$AGY_SETTINGS_LOCKDIR"
}

# Runs agy in print mode with JSON output, prints the response, and reports
# the conversation id on stderr so a later call can --resume it. Falls back
# to plain passthrough when the caller chose --output-format or no python3.
run_print() {
  local a has_timeout=0 own_format=0
  for a in "$@"; do
    case "$a" in
      --output-format|--output-format=*) own_format=1 ;;
      --print-timeout|--print-timeout=*) has_timeout=1 ;;
    esac
  done
  [ "$has_timeout" -eq 1 ] || set -- "$@" --print-timeout "$PRINT_TIMEOUT"
  if [ "$own_format" -eq 1 ] || ! command -v python3 >/dev/null 2>&1; then
    "$@"; return
  fi
  local out rc=0 prc=0
  out="$("$@" --output-format json)" || rc=$?
  printf '%s' "$out" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw.strip().splitlines()[-1])
except Exception:
    sys.stdout.write(raw); sys.exit(0)
sys.stdout.write(d.get("response", ""))
cid, st = d.get("conversation_id"), d.get("status")
if cid:
    print("\n[wrapper] conversation: %s (follow up with --resume %s)" % (cid, cid), file=sys.stderr)
denied = d.get("denied_actions") or []
if denied:
    names = ", ".join("%s(%s)" % (x.get("action", "?"), x.get("display_name", "?")) for x in denied)
    print("[wrapper] WARNING: %d action(s) were blocked and skipped: %s" % (len(denied), names), file=sys.stderr)
    print("[wrapper] the answer may be incomplete; rerun with --write, or add allow rules in agy settings", file=sys.stderr)
if st and st != "SUCCESS":
    print("[wrapper] status: %s %s" % (st, d.get("error", "")), file=sys.stderr)
    if d.get("finished_reason") == "print_timeout" and cid:
        print("[wrapper] timed out; raise --timeout or continue with --resume %s" % cid, file=sys.stderr)
    sys.exit(1)
' || prc=$?
  # Keep agy's own exit code (e.g. 3 on timeout); fall back to the parser's.
  [ "$rc" -ne 0 ] || rc="$prc"
  return "$rc"
}

# Starts "$@" (an agy command line) as a detached background job; see agy-jobs.py.
run_job() {
  local kind="$1" label="$2"; shift 2
  local a
  for a in "$@"; do
    case "$a" in --output-format|--output-format=*)
      echo "error: background jobs always use --output-format stream-json; drop --output-format" >&2
      exit 64 ;;
    esac
  done
  local id
  id="$(python3 -I "$SCRIPT_DIR/agy-jobs.py" start "$JOBS_DIR" "$kind" "$label" "$@")" || exit 1
  echo "[wrapper] job started: $id"
  echo "[wrapper] follow it:  bash \"$SCRIPT_DIR/agy-run.sh\" watch $id   (no time limit; exits when done or stalled)"
  echo "[wrapper] check/stop: bash \"$SCRIPT_DIR/agy-run.sh\" status $id | stop $id"
}

require_python() {
  command -v python3 >/dev/null 2>&1 || { echo "error: background jobs need python3" >&2; exit 1; }
}

cmd_ask() {
  local model_alias=""
  local model_flag_seen=0
  local effort=()
  local resume=()
  local readonly_flag=()
  local agent=()
  local write=0 timeout_set=0
  local job="${AGY_JOB:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --model)
        model_flag_seen=1
        # `shift 2` on a one-arg list would `set -e`-exit silently; handle
        # the empty case so model_value_error prints the real error.
        if [ $# -ge 2 ]; then
          model_alias="$2"; shift 2
        else
          shift
        fi ;;
      --model=*)
        model_flag_seen=1
        model_alias="${1#--model=}"
        shift ;;
      --effort)
        [ $# -ge 2 ] || { echo "error: --effort requires low|medium|high|xhigh|max" >&2; exit 64; }
        check_effort "$2"; effort=(--effort "$2"); shift 2 ;;
      --effort=*)
        check_effort "${1#--effort=}"; effort=(--effort "${1#--effort=}"); shift ;;
      --timeout)
        [ $# -ge 2 ] || { echo "error: --timeout requires a duration (e.g. 15m)" >&2; exit 64; }
        check_duration "$2"; PRINT_TIMEOUT="$2"; timeout_set=1; shift 2 ;;
      --timeout=*)
        check_duration "${1#--timeout=}"; PRINT_TIMEOUT="${1#--timeout=}"; timeout_set=1; shift ;;
      --agent)
        [ $# -ge 2 ] && [ -n "$2" ] || { echo "error: --agent requires a name (see \`agy agents\`)" >&2; exit 64; }
        agent=(--agent "$2"); shift 2 ;;
      --agent=*)
        [ -n "${1#--agent=}" ] || { echo "error: --agent= requires a name" >&2; exit 64; }
        agent=(--agent "${1#--agent=}"); shift ;;
      --read-only)
        readonly_flag=(--settings "$READ_ONLY_SETTINGS"); write=0; shift ;;
      --write)
        write=1; readonly_flag=(); shift ;;
      --resume)
        [ $# -ge 2 ] && [ -n "$2" ] || { echo "error: --resume requires a conversation id" >&2; exit 64; }
        resume=(--conversation "$2"); shift 2 ;;
      --resume=*)
        [ -n "${1#--resume=}" ] || { echo "error: --resume= requires a conversation id" >&2; exit 64; }
        resume=(--conversation "${1#--resume=}"); shift ;;
      --)        shift; break ;;
      *)         break ;;
    esac
  done
  # Check the value before the prompt so `ask --model` reports the flag.
  if [ "$model_flag_seen" -eq 1 ] && [ -z "$model_alias" ]; then
    model_value_error
  fi
  local prompt="${1:-}"
  shift || true
  if [ -z "$prompt" ]; then
    echo "error: ask requires a prompt argument" >&2
    exit 64
  fi
  local label="$prompt"
  [ -n "${AGY_SWARM:-}" ] && prompt="/swarm $prompt"
  # Quick asks default to read-only (agy print mode is `auto` and edits files);
  # background jobs (delegate, swarm) may edit unless --read-only is given.
  if [ -z "$job" ] && [ "$write" -eq 0 ]; then
    readonly_flag=(--settings "$READ_ONLY_SETTINGS")
  fi
  # Jobs have no time limit unless one is asked for; watch monitors them.
  local job_timeout=()
  if [ -n "$job" ]; then
    require_python
    [ "$timeout_set" -eq 1 ] && [ "$PRINT_TIMEOUT" != 0 ] && job_timeout=(--print-timeout "$PRINT_TIMEOUT")
  fi
  local path
  path="$(require_ready)"
  if [ "$model_flag_seen" -eq 1 ]; then
    require_model_support "$path"
    local model
    model="$(resolve_model "$path" "$model_alias")"
    if [ ${#effort[@]} -gt 0 ]; then
      local models
      if models="$(list_models "$path")" && [ -n "$models" ]; then
        model="$(apply_effort_tier "$models" "$model" "${effort[1]}")" || exit 64
        # The tier is now in the model name; a separate --effort would conflict.
        is_tiered "$(_model_name "$(_exact_match "$models" "$model")")" && effort=()
      fi
    fi
    set -- --model "$model" ${effort[@]+"${effort[@]}"} ${resume[@]+"${resume[@]}"} ${readonly_flag[@]+"${readonly_flag[@]}"} ${agent[@]+"${agent[@]}"} -p "$prompt" "$@"
  else
    set -- ${effort[@]+"${effort[@]}"} ${resume[@]+"${resume[@]}"} ${readonly_flag[@]+"${readonly_flag[@]}"} ${agent[@]+"${agent[@]}"} -p "$prompt" "$@"
  fi
  if [ -n "$job" ]; then
    local kind=task; [ -n "${AGY_SWARM:-}" ] && kind=swarm
    run_job "$kind" "$label" "$path" ${job_timeout[@]+"${job_timeout[@]}"} "$@"
  else
    run_print "$path" "$@"
  fi
}

cmd_review() {
  local focus="${1:-Please review the following diff for correctness, edge cases, security issues, and style.}"
  [ -z "$REPLY_LANG" ] || focus+=$'\n'"Reply in $REPLY_LANG unless the request above asks for another language."
  local path
  path="$(require_ready)"
  local repo_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
  if ! git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: $repo_dir is not inside a git repository." >&2
    exit 1
  fi
  local diff
  if git -C "$repo_dir" rev-parse --verify -q HEAD >/dev/null; then
    diff="$(git -C "$repo_dir" diff HEAD 2>/dev/null || true)"
  else
    # No commits yet: staged plus unstaged changes.
    diff="$(git -C "$repo_dir" diff --cached 2>/dev/null || true)$(git -C "$repo_dir" diff 2>/dev/null || true)"
  fi
  # -z keeps non-ASCII and odd file names intact (no core.quotePath escaping).
  # Each untracked file gets its own share of the budget so one big file
  # (a log, a dump) cannot crowd every other file out of the review.
  local f one untracked="" names="" per_file=$((MAX_DIFF_BYTES / 5)) count=0 skipped=0
  while IFS= read -r -d '' f; do
    # A repo without .gitignore can hold thousands of untracked files.
    count=$((count + 1))
    if [ "$count" -gt 200 ]; then skipped=$((skipped + 1)); continue; fi
    names+="  $f (untracked)"$'\n'
    one="$(git -C "$repo_dir" diff --no-index -- /dev/null "$f" 2>/dev/null || true)"
    if [ "$(printf '%s' "$one" | wc -c)" -gt "$per_file" ]; then
      one="$(printf '%s' "$one" | head -c "$per_file" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null || true)"$'\n'"[untracked file truncated by the wrapper]"
    fi
    untracked+="$one"$'\n'
  done < <(git -C "$repo_dir" ls-files -z --others --exclude-standard 2>/dev/null || true)
  diff+="${untracked:+$'\n'$untracked}"
  if [ "$skipped" -gt 0 ]; then
    names+="  ... and $skipped more untracked files not included"$'\n'
    echo "[wrapper] $count untracked files; only the first 200 are included. Add a .gitignore or commit to narrow the review." >&2
  fi
  # List every changed file up front, so truncation never hides that a file exists.
  local tracked_names
  if git -C "$repo_dir" rev-parse --verify -q HEAD >/dev/null; then
    tracked_names="$(git -C "$repo_dir" -c core.quotePath=false diff --name-only HEAD 2>/dev/null || true)"
  else
    tracked_names="$(git -C "$repo_dir" -c core.quotePath=false diff --cached --name-only 2>/dev/null || true)"
  fi
  [ -z "$tracked_names" ] || names="$(printf '%s\n' "$tracked_names" | sed 's/^/  /')"$'\n'"$names"
  # Not ${diff//[[:space:]]/}: bash pattern substitution is quadratic on big
  # multibyte strings and hangs for minutes on a ~200 KB diff.
  if [ -z "$(printf '%s' "$diff" | tr -d '[:space:]' | head -c 1)" ]; then
    echo "error: no git diff found in $repo_dir. Stage or make changes first." >&2
    exit 1
  fi
  local bytes
  bytes="$(printf '%s' "$diff" | wc -c | tr -d ' ')"
  if [ "$bytes" -gt "$MAX_DIFF_BYTES" ]; then
    # iconv -c drops a UTF-8 character cut in half by head -c.
    diff="$(printf '%s' "$diff" | head -c "$MAX_DIFF_BYTES" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null || true)"
    diff+=$'\n'"[diff truncated by the wrapper: showing the first $MAX_DIFF_BYTES of $bytes bytes]"
    echo "[wrapper] diff is $bytes bytes; truncated to $MAX_DIFF_BYTES. Commit or narrow the changes for a full review." >&2
  fi
  local full
  full=$(printf '%s\n\nChanged files:\n%s\nDiff:\n```diff\n%s\n```\n' "$focus" "$names" "$diff")
  run_print "$path" --settings "$READ_ONLY_SETTINGS" -p "$full"
}

cmd_image() {
  local description=""
  local name=""
  local output=""
  local positional=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)
        if [ $# -ge 2 ]; then
          name="$2"; shift 2
        else
          echo "error: --name requires a value (e.g. --name coffee_cup)" >&2
          exit 64
        fi ;;
      --name=*)
        name="${1#--name=}"
        if [ -z "$name" ]; then
          echo "error: --name= requires a non-empty value" >&2
          exit 64
        fi
        shift ;;
      --output)
        if [ $# -ge 2 ]; then
          output="$2"; shift 2
        else
          echo "error: --output requires a path (e.g. --output /tmp/out.png)" >&2
          exit 64
        fi ;;
      --output=*)
        output="${1#--output=}"
        if [ -z "$output" ]; then
          echo "error: --output= requires a non-empty path" >&2
          exit 64
        fi
        shift ;;
      --)        shift; positional+=("$@"); break ;;
      *)         positional+=("$1"); shift ;;
    esac
  done
  description="${positional[*]:-}"
  if [ -z "$description" ]; then
    echo "error: image requires a description" >&2
    exit 64
  fi
  local agy_path
  agy_path="$(require_ready)"

  local name_clause=""
  if [ -n "$name" ]; then
    name_clause=" Save the image with name \"${name}\"."
  fi
  local prompt
  prompt="Use your built-in generate_image tool to create the following image. Description: ${description}.${name_clause}

After the tool returns, you MUST end your reply with a single line in this exact format (no quotes, no markdown, nothing after it):
IMAGE_PATH: <absolute filesystem path to the saved image>

The IMAGE_PATH line is required — the calling wrapper parses it to locate the file."

  local response rc
  response="$("$agy_path" --print-timeout "$PRINT_TIMEOUT" -p "$prompt" 2>&1)" || rc=$?
  rc="${rc:-0}"
  printf '%s\n' "$response"

  local src
  src="$(printf '%s' "$response" \
    | sed -n 's/^[[:space:]]*IMAGE_PATH:[[:space:]]*//p' \
    | tail -n1)"

  # Fallback when the model skips the marker line.
  if [ -z "$src" ] || [ ! -f "$src" ]; then
    src="$(printf '%s' "$response" \
      | grep -oE '/[^[:space:]]+\.(png|jpg|jpeg|webp)' \
      | head -n1 || true)"
  fi

  if [ -n "$src" ] && [ -f "$src" ]; then
    echo
    echo "[wrapper] generated: $src"
    if [ -n "$output" ]; then
      local src_ext out_ext
      src_ext="$(printf '%s' "${src##*.}" | tr '[:upper:]' '[:lower:]')"
      out_ext="$(printf '%s' "${output##*.}" | tr '[:upper:]' '[:lower:]')"
      [ "$src_ext" = jpeg ] && src_ext=jpg
      [ "$out_ext" = jpeg ] && out_ext=jpg
      if [ "$out_ext" = "$src_ext" ] || [ "$output" = "${output%.*}" ]; then
        cp "$src" "$output"
        echo "[wrapper] copied to: $output"
      elif command -v sips >/dev/null 2>&1 && sips -s format "$( [ "$out_ext" = jpg ] && echo jpeg || echo "$out_ext")" \
          "$src" --out "$output" >/dev/null 2>&1; then
        echo "[wrapper] converted $src_ext to $out_ext: $output"
      else
        output="${output%.*}.$src_ext"
        cp "$src" "$output"
        echo "[wrapper] agy produced a .$src_ext image; saved as $output to keep the extension honest" >&2
      fi
    fi
  else
    echo
    echo "[wrapper] warning: agy did not include an IMAGE_PATH line and no image path was found in its reply." >&2
    echo "[wrapper]          if --output was requested, the copy was skipped." >&2
  fi
  return "$rc"
}

cmd_help() {
  cat <<'HELP'
/agy:* commands (Claude Code plugin for the Antigravity CLI)

Slash commands
  /agy:setup                            Verify agy install + auth. Offers install if missing.
  /agy:ask [flags] <prompt>             Quick question, read-only by default (--write to allow edits).
  /agy:delegate [flags] <task>          Background job, no time limit, may edit files.
  /agy:research [flags] <topic>         Read-only research as a background job.
  /agy:review [focus]                   Send current changes (incl. untracked files) to agy for a read-only review.
  /agy:swarm [flags] <task>             Swarm (preview) as a background job: coordinator + parallel workers.
                                        Uses much more quota.
  /agy:status [job]                     Progress of background jobs (members and board posts for swarms).
  /agy:stop <job>                       Stop a background job, keeping any partial answer.
  /agy:image [--name S] [--output P] <description>
                                        Generate an image via agy's built-in tool.
  /agy:help                             This help.

Flags (before the prompt)
  --model A        model alias, name or id (table below)
  --effort E       low|medium|high|xhigh|max; with --model, picks that tier
  --timeout D      run limit, e.g. 90s, 15m, 1h; 0 = none
                   (ask/review default 30m; background jobs default none)
  --resume ID      continue an earlier conversation
  --agent NAME     run as an agent from `agy agents`
  --read-only      block file writes and terminal commands (default for ask)
  --write          allow them (default for delegate and swarm)

Background jobs (delegate, research, swarm) run detached with no time limit.
`watch <job>` follows one and exits when it finishes, or when nothing has
changed for 15 minutes (it then reports a stall; the job keeps running).
Job files live in ~/.local/state/agy-plugin/jobs and are pruned after 14 days.

Set AGY_PLUGIN_REPLY_LANG (e.g. "Traditional Chinese (Taiwan)") to make the
wrapper's built-in instructions, such as a bare /agy:review, ask for that language.

Every ask/delegate/swarm call ends with "[wrapper] conversation: <id>" on
stderr; pass --resume <id> to continue that conversation. agy-native flags
placed after the prompt (--add-dir DIR, --sandbox, --mode plan, --json-schema)
are forwarded as-is.

Model selection (--model)
HELP
  local path models=""
  if path="$(find_agy)"; then
    models="$(list_models "$path" || true)"
  fi
  print_model_table 1 "$models"
  cat <<'HELP'

How --model works
  The wrapper reads the model list from `agy models` at call time, resolves
  the alias to the newest matching version, and passes it to agy as
  `--model <id>` (or the display name when the list has no ids) for that
  call only. The default model you picked in the agy TUI is left untouched.

  Names or ids that `agy models` does not list fail with exit 64, and so do
  aliases whose model family your account does not offer. When Google
  rotates model versions, aliases follow without a plugin update.

  Requires agy 1.2.0 or newer.

Underlying CLI
  Run `agy --help` for agy's own flags and `agy models` for the models
  available to your account.
HELP
}

main() {
  restore_orphaned_backup 2>/dev/null || true
  check_duration "$PRINT_TIMEOUT"
  [[ "$MAX_DIFF_BYTES" =~ ^[1-9][0-9]*$ ]] || { echo "error: AGY_PLUGIN_MAX_DIFF_BYTES must be a positive integer" >&2; exit 64; }

  case "${1:-}" in
    check)              cmd_check ;;
    ask)     shift;     cmd_ask "$@" ;;
    review)  shift;     cmd_review "$@" ;;
    swarm)   shift;     AGY_JOB=1 AGY_SWARM=1 cmd_ask "$@" ;;
    start)   shift;     AGY_JOB=1 cmd_ask "$@" ;;
    watch|status|stop|result)
      require_python
      local sub="$1"; shift
      python3 -I "$SCRIPT_DIR/agy-jobs.py" "$sub" "$JOBS_DIR" "$@" ;;
    jobs)               require_python; python3 -I "$SCRIPT_DIR/agy-jobs.py" status "$JOBS_DIR" ;;
    image)   shift;     cmd_image "$@" ;;
    help|-h|--help|"")  cmd_help ;;
    *)                  echo "error: unknown subcommand '$1'" >&2; cmd_help >&2; exit 64 ;;
  esac
}

# Skip dispatch when sourced (lets unit tests call functions directly).
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  main "$@"
fi
