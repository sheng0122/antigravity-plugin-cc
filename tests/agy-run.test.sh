#!/usr/bin/env bash
# Tests for plugins/agy/scripts/agy-run.sh, run against a stub `agy` binary.
# Usage: bash tests/agy-run.test.sh

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT/plugins/agy/scripts/agy-run.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/agy" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "${STUB_VERSION:-agy 1.4.10}"; exit 0 ;;
  models)
    echo "Fetching available models..." >&2
    if [ -n "${STUB_MODELS_FAIL:-}" ]; then
      echo "error: unknown command \"models\"" >&2
      exit 2
    fi
    cat "$STUB_MODELS_FILE"
    exit 0 ;;
esac
printf '%s\n' "$@" > "$STUB_ARGS_FILE"
if printf '%s\n' "$@" | grep -qx stream-json; then
  # Background-job mode: replay $STUB_STREAM ("sleep N" lines pause, others
  # are printed as events). SIGINT emits an INTERRUPTED result, like agy.
  trap 'echo "{\"event\":\"result\",\"result\":{\"conversation_id\":\"c-s\",\"status\":\"INTERRUPTED\",\"error\":\"interrupted\",\"response\":\"partial answer\"}}"; exit 1' INT
  if [ -n "${STUB_STREAM:-}" ]; then
    while IFS= read -r line; do
      case "$line" in
        "sleep "*) sleep "${line#sleep }" & wait $! ;;
        *) echo "$line" ;;
      esac
    done < "$STUB_STREAM"
  fi
  exit "${STUB_RC:-0}"
fi
if [ -n "${STUB_JSON:-}" ]; then echo "$STUB_JSON"; elif [ -z "${STUB_SILENT:-}" ]; then echo "stub-response"; fi
exit "${STUB_RC:-0}"
STUB
chmod +x "$WORK/bin/agy"

MODELS_NAMES="$WORK/models-names.txt"
cat > "$MODELS_NAMES" <<'EOF'
Gemini 3.8 Flash (High)
Gemini 3.8 Flash (Medium)
Gemini 3.8 Flash (Low)
Gemini 3.7 Flash (High)
Gemini 3.7 Flash (Medium)
Gemini 3.7 Flash (Low)
Gemini 3.6 Flash (High)
Gemini 3.6 Flash (Medium)
Gemini 3.6 Flash (Low)
Gemini 3.1 Hydrogen (High)
Gemini 3.1 Hydrogen (Low)
Claude Sonnet 4.6 (High)
Claude Opus 4.6 (High)
GPT-OSS 120B (Medium)
EOF

MODELS_IDS="$WORK/models-ids.txt"
printf '%s\t%s\n' \
  "gemini-3.8-flash-high" "Gemini 3.8 Flash (High)" \
  "gemini-3.8-flash-medium" "Gemini 3.8 Flash (Medium)" \
  "gemini-3.8-flash-low" "Gemini 3.8 Flash (Low)" \
  "claude-sonnet-4-6" "Claude Sonnet 4.6 (High)" \
  "claude-opus-4-6-thinking" "Claude Opus 4.6 (High)" \
  "gpt-oss-120b-medium" "GPT-OSS 120B (Medium)" > "$MODELS_IDS"

# Mirrors a real `agy models` listing (agy 1.5.16, 2026-11).
MODELS_REAL="$WORK/models-real.txt"
printf '%s\t%s\n' \
  "gemini-4-neon-high" "Gemini 4 Neon (High)" "gemini-4-neon-xhigh" "Gemini 4 Neon (XHigh)" \
  "gemini-4-neon-medium" "Gemini 4 Neon (Medium)" "gemini-4-neon-low" "Gemini 4 Neon (Low)" \
  "gemini-4-hydrogen-high" "Gemini 4 Hydrogen (High)" "gemini-4-hydrogen-low" "Gemini 4 Hydrogen (Low)" \
  "gemini-pro-orchestrator" "Orchestrator (Carbon)" \
  "gemini-3.8-flash-high" "Gemini 3.8 Flash (High)" "gemini-3.8-flash-low" "Gemini 3.8 Flash (Low)" \
  "claude-opus-5-5-low" "Claude Opus 5.5 (Low)" "claude-opus-5-5-medium" "Claude Opus 5.5 (Medium)" \
  "claude-opus-5-5-high" "Claude Opus 5.5 (High)" > "$MODELS_REAL"

MODELS_CRLF="$WORK/models-crlf.txt"
sed 's/$/\r/' "$MODELS_IDS" > "$MODELS_CRLF"

MODELS_TIES="$WORK/models-ties.txt"
cat > "$MODELS_TIES" <<'EOF'
Claude Opus 4.6 (Low)
Claude Opus 4.6
Claude Opus 4.6 (High)
Claude Opus 4.6 (Medium)
GPT-OSS 120B (Low)
GPT-OSS 120B (Medium)
EOF

MODELS_NEWER="$WORK/models-newer.txt"
cat > "$MODELS_NEWER" <<'EOF'
Gemini 3.9 Flash (High)
Gemini 3.10 Flash (High)
Gemini 3.2 Hydrogen (High)
Gemini 3.1 Hydrogen (High)
Claude Opus 4.6 (High)
Claude Opus 5 (High)
EOF

PASS=0
FAIL=0
OUT=""
ERR=""
RC=0

run_wrapper() {
  local home="$WORK/home"
  rm -rf "$home" "$WORK/args"
  mkdir -p "$home/.gemini/antigravity-cli"
  printf '{\n  "model": "Gemini 3.8 Flash (Medium)"\n}\n' > "$home/.gemini/antigravity-cli/settings.json"
  [ -z "${SETUP_HOME:-}" ] || "$SETUP_HOME" "$home/.gemini/antigravity-cli"
  [ -z "${NO_AUTH:-}" ] || rm -rf "$home/.gemini"
  local key=test; [ -z "${NO_AUTH:-}" ] || key=""
  RC=0
  OUT="$(cd "${RUN_DIR:-$WORK}" && env -u GEMINI_API_KEY -u AGY_ADC_AUTH -u CLAUDE_PROJECT_DIR \
    HOME="$home" PATH="${RUN_PATH:-$WORK/bin:$PATH}" ANTIGRAVITY_API_KEY="$key" \
    AGY_PLUGIN_TIMEOUT="${PLUGIN_TIMEOUT:-30m}" AGY_PLUGIN_MAX_DIFF_BYTES="${MAX_DIFF:-100000}" \
    STUB_RC="${AGY_RC:-0}" STUB_SILENT="${SILENT:-}" STUB_STREAM="${STREAM:-}" \
    AGY_PLUGIN_JOBS_DIR="$WORK/jobs" AGY_HOME="$WORK/agyhome" AGY_PLUGIN_REPLY_LANG="${REPLY_LANG_ENV:-}" \
    STUB_ARGS_FILE="$WORK/args" STUB_MODELS_FILE="${MODELS_FILE:-$MODELS_NAMES}" \
    STUB_VERSION="${AGY_VERSION:-agy 1.4.10}" STUB_MODELS_FAIL="${MODELS_FAIL:-}" STUB_JSON="${JSON:-}" \
    bash "$WRAPPER" "$@" 2>"$WORK/stderr")" || RC=$?
  ERR="$(cat "$WORK/stderr")"
}

# The wrapper always appends --output-format json and --print-timeout <d>;
# strip them so tests can compare the meaningful arguments exactly.
RO='{"permissions":{"deny":["write_file(*)","command(*)"]}}'

# Also strips the read-only --settings pair that ask adds by default; tests
# check it explicitly with is_read_only.
passed_args() {
  [ -f "$WORK/args" ] && awk -v ro="$RO" '
    skip { skip = 0; next }
    $0 == "--output-format" || $0 == "--print-timeout" { skip = 1; next }
    $0 == "--settings" { getline v; if (v == ro) next; print; print v; next }
    { print }' "$WORK/args"
}

is_read_only() {
  arg_pair --settings "$RO"
}

raw_args() {
  [ -f "$WORK/args" ] && cat "$WORK/args"
}

# True when the raw agy argv has "$1" immediately followed by "$2".
arg_pair() {
  raw_args | awk -v a="$1" -v b="$2" 'prev == a && $0 == b { found = 1 } { prev = $0 } END { exit !found }'
}

count_arg() {
  raw_args | grep -cx -- "$1"
}

git_q() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }

new_repo() {
  local d="$WORK/repo-$1"
  rm -rf "$d"; mkdir -p "$d"
  git_q -C "$d" init -q
  printf '%s' "$d"
}

check() {
  local name="$1"; shift
  if "$@"; then
    PASS=$((PASS + 1))
    echo "ok   - $name"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - $name"
    echo "       rc=$RC"
    echo "       stdout: $(printf '%s' "$OUT" | head -n 5 | tr '\n' '|')"
    echo "       stderr: $(printf '%s' "$ERR" | head -n 5 | tr '\n' '|')"
    echo "       agy args: $(passed_args | tr '\n' '|' | cut -c1-400)"
  fi
}

called_with_model() {
  local expected="$1"
  [ "$RC" -eq 0 ] || return 1
  [ "$(passed_args)" = "$(printf '%s\n' --model "$expected" -p "hello")" ]
}

not_called() {
  [ ! -f "$WORK/args" ]
}

exited() {
  [ "$RC" -eq "$1" ]
}

stderr_has() {
  case "$ERR" in *"$1"*) return 0 ;; esac
  return 1
}

stdout_has() {
  case "$OUT" in *"$1"*) return 0 ;; esac
  return 1
}

stdout_lacks() {
  case "$OUT" in *"$1"*) return 1 ;; esac
  return 0
}

test_flash_resolves_to_newest_listed_version() {
  run_wrapper ask --model flash hello
  called_with_model "Gemini 3.8 Flash (High)"
}

test_flash_tiers_resolve() {
  run_wrapper ask --model flash-low hello
  called_with_model "Gemini 3.8 Flash (Low)" || return 1
  run_wrapper ask --model FLASH-MED hello
  called_with_model "Gemini 3.8 Flash (Medium)"
}

test_tab_separated_listing_passes_id() {
  MODELS_FILE="$MODELS_IDS" run_wrapper ask --model opus hello
  called_with_model "claude-opus-4-6-thinking"
}

test_crlf_listing() {
  MODELS_FILE="$MODELS_CRLF" run_wrapper ask --model sonnet hello
  called_with_model "claude-sonnet-4-6"
}

test_ties_prefer_high_and_medium() {
  MODELS_FILE="$MODELS_TIES" run_wrapper ask --model opus hello
  called_with_model "Claude Opus 4.6 (High)" || return 1
  MODELS_FILE="$MODELS_TIES" run_wrapper ask --model gpt-oss hello
  called_with_model "GPT-OSS 120B (Medium)"
}

test_versions_compare_numerically() {
  MODELS_FILE="$MODELS_NEWER" run_wrapper ask --model flash hello
  called_with_model "Gemini 3.10 Flash (High)" || return 1
  MODELS_FILE="$MODELS_NEWER" run_wrapper ask --model pro hello
  called_with_model "Gemini 3.2 Hydrogen (High)" || return 1
  MODELS_FILE="$MODELS_NEWER" run_wrapper ask --model opus hello
  called_with_model "Claude Opus 5 (High)"
}

test_effort_and_swarm() {
  run_wrapper ask --effort high --model flash hello
  [ "$RC" -eq 0 ] && [ "$(passed_args)" = "$(printf '%s\n' --model "Gemini 3.8 Flash (High)" -p hello)" ] || return 1
}

test_json_response_and_resume() {
  JSON='{"conversation_id":"c-123","status":"SUCCESS","response":"hi there"}' run_wrapper ask --resume c-0 hello
  [ "$RC" -eq 0 ] && [ "$OUT" = "hi there" ] && grep -q 'conversation: c-123' "$WORK/stderr" || return 1
  grep -qx -- '--output-format' "$WORK/args" && [ "$(passed_args)" = "$(printf '%s\n' --conversation c-0 -p hello)" ] || return 1
  JSON='{"conversation_id":"c-9","status":"ERROR","error":"quota","response":""}' run_wrapper ask hello
  [ "$RC" -eq 1 ] && grep -q 'status: ERROR quota' "$WORK/stderr"
}

test_read_only_flag() {
  run_wrapper ask --read-only hello
  [ "$RC" -eq 0 ] && is_read_only && [ "$(passed_args)" = "$(printf '%s\n' -p hello)" ]
}

test_ask_is_read_only_by_default_and_write_opts_out() {
  run_wrapper ask hello
  is_read_only || return 1
  run_wrapper ask --write hello
  exited 0 && ! is_read_only && [ "$(passed_args)" = "$(printf '%s\n' -p hello)" ] || return 1
  run_wrapper ask --write --read-only hello
  is_read_only
}

test_display_name_passes_through() {
  run_wrapper ask --model "Gemini 3.7 Flash (Low)" hello
  called_with_model "Gemini 3.7 Flash (Low)"
}

test_display_name_is_case_insensitive() {
  run_wrapper ask --model "claude opus 4.6 (high)" hello
  called_with_model "Claude Opus 4.6 (High)"
}

test_model_id_passes_through() {
  MODELS_FILE="$MODELS_IDS" run_wrapper ask --model GEMINI-3.8-FLASH-HIGH hello
  called_with_model "gemini-3.8-flash-high"
}

test_display_name_maps_to_id() {
  MODELS_FILE="$MODELS_IDS" run_wrapper ask --model "Gemini 3.8 Flash (Low)" hello
  called_with_model "gemini-3.8-flash-low"
}

test_backslash_escapes_are_literal() {
  run_wrapper ask --model 'Gemini 3.8 Flash \050High\051' hello
  exited 64 && not_called
}

test_equals_form() {
  run_wrapper ask --model=pro-low hello
  called_with_model "Gemini 3.1 Hydrogen (Low)"
}

test_retired_model_is_rejected() {
  run_wrapper ask --model "Gemini 3.5 Flash (High)" hello
  exited 64 && not_called && stderr_has "Gemini 3.8 Flash (High)"
}

test_unknown_alias_is_rejected() {
  run_wrapper ask --model flsh hello
  exited 64 && not_called && stderr_has "flsh"
}

test_alias_list_is_not_an_alias() {
  run_wrapper ask --model flash,flash-high hello
  exited 64 && not_called
}

test_alias_without_listed_model_is_rejected() {
  MODELS_FILE="$MODELS_IDS" run_wrapper ask --model pro hello
  exited 64 && not_called && stderr_has "pro"
}

test_empty_model_value_is_rejected() {
  run_wrapper ask --model= hello
  exited 64 && not_called && stderr_has "non-empty" || return 1
  run_wrapper ask --model
  exited 64 && not_called && stderr_has "non-empty"
}

test_no_model_flag_calls_agy_plainly() {
  run_wrapper ask hello
  exited 0 && [ "$(passed_args)" = "$(printf '%s\n' -p hello)" ]
}

test_extra_args_follow_prompt() {
  run_wrapper ask --model flash hello --sandbox
  exited 0 && [ "$(passed_args)" = "$(printf '%s\n' --model "Gemini 3.8 Flash (High)" -p hello --sandbox)" ]
}

test_settings_file_is_not_modified() {
  run_wrapper ask --model opus hello
  exited 0 || return 1
  [ "$(cat "$WORK/home/.gemini/antigravity-cli/settings.json")" = "$(printf '{\n  "model": "Gemini 3.8 Flash (Medium)"\n}')" ] \
    && [ ! -e "$WORK/home/.gemini/antigravity-cli/settings.json.agy-plugin.bak" ]
}

test_agy_older_than_1_2_is_rejected() {
  AGY_VERSION="1.1.9" run_wrapper ask --model flash hello
  exited 1 && not_called && stderr_has "agy update" && stderr_has "1.1.9"
}

test_agy_1_2_and_newer_are_accepted() {
  AGY_VERSION="1.2.0" run_wrapper ask --model flash hello
  called_with_model "Gemini 3.8 Flash (High)" || return 1
  AGY_VERSION="agy version 1.10.0 (build abc)" run_wrapper ask --model flash hello
  called_with_model "Gemini 3.8 Flash (High)"
}

test_unparseable_version_is_not_blocking() {
  AGY_VERSION="dev" run_wrapper ask --model flash hello
  called_with_model "Gemini 3.8 Flash (High)"
}

test_listing_failure_rejects_alias() {
  MODELS_FAIL=1 run_wrapper ask --model flash hello
  exited 1 && not_called && stderr_has "agy models"
}

test_listing_failure_passes_full_name_through() {
  MODELS_FAIL=1 run_wrapper ask --model "Gemini 3.9 Flash (High)" hello
  called_with_model "Gemini 3.9 Flash (High)"
}

test_help_shows_live_resolution() {
  MODELS_FILE="$MODELS_IDS" run_wrapper help
  exited 0 \
    && stdout_has "Gemini 3.8 Flash (High)" \
    && stdout_has "gemini-3.8-flash-high" \
    && stdout_lacks "3.5 Flash" \
    && stdout_lacks "settings.json"
}

test_image_without_description() {
  run_wrapper image
  exited 64 && stderr_has "image requires a description"
}

leave_dead_patch() {
  cp "$1/settings.json" "$1/settings.json.agy-plugin.bak"
  printf '{\n  "model": "Claude Opus 4.6 (High)"\n}\n' > "$1/settings.json"
  printf '%s\n%s\n' 2147483646 "Claude Opus 4.6 (High)" > "$1/.agy-plugin.patched"
  mkdir -p "$1/.agy-plugin.lock"
}

leave_live_patch() {
  leave_dead_patch "$1"
  printf '%s\n%s\n' "$$" "Claude Opus 4.6 (High)" > "$1/.agy-plugin.patched"
}

leave_backup_only() {
  printf 'stale\n' > "$1/settings.json.agy-plugin.bak"
}

settings_model_is() {
  grep -q "\"model\": \"$1\"" "$WORK/home/.gemini/antigravity-cli/settings.json"
}

test_recovers_settings_from_killed_0_4_run() {
  local dir="$WORK/home/.gemini/antigravity-cli"
  SETUP_HOME=leave_dead_patch run_wrapper ask hello
  exited 0 && settings_model_is "Gemini 3.8 Flash (Medium)" \
    && [ ! -e "$dir/settings.json.agy-plugin.bak" ] \
    && [ ! -e "$dir/.agy-plugin.patched" ] \
    && [ ! -e "$dir/.agy-plugin.lock" ]
}

test_leaves_settings_of_running_0_4_call() {
  local dir="$WORK/home/.gemini/antigravity-cli"
  SETUP_HOME=leave_live_patch run_wrapper ask hello
  exited 0 && settings_model_is "Claude Opus 4.6 (High)" \
    && [ -e "$dir/settings.json.agy-plugin.bak" ] \
    && [ -e "$dir/.agy-plugin.patched" ]
}

test_removes_backup_without_sentinel() {
  SETUP_HOME=leave_backup_only run_wrapper ask hello
  exited 0 && settings_model_is "Gemini 3.8 Flash (Medium)" \
    && [ ! -e "$WORK/home/.gemini/antigravity-cli/settings.json.agy-plugin.bak" ]
}

test_help_without_listing() {
  MODELS_FAIL=1 run_wrapper help
  exited 0 && stdout_has "flash" && stdout_has "agy models" && stdout_lacks "3.5 Flash"
}

# --- time limit -----------------------------------------------------------

test_default_timeout_is_added() {
  run_wrapper ask hello
  exited 0 && arg_pair --print-timeout 30m && arg_pair --output-format json
}

test_timeout_flag_forms() {
  run_wrapper ask --timeout 0 hello
  arg_pair --print-timeout 0 || return 1
  run_wrapper ask --timeout=1h30m hello
  arg_pair --print-timeout 1h30m && [ "$(passed_args)" = "$(printf '%s\n' -p hello)" ]
}

test_env_timeout() {
  PLUGIN_TIMEOUT=5m run_wrapper ask hello
  arg_pair --print-timeout 5m
}

test_invalid_timeouts_rejected() {
  run_wrapper ask --timeout abc hello
  exited 64 && not_called && stderr_has "invalid timeout" || return 1
  run_wrapper ask --timeout 10 hello
  exited 64 && not_called || return 1
  run_wrapper ask --timeout
  exited 64 && not_called || return 1
  PLUGIN_TIMEOUT=forever run_wrapper ask hello
  exited 64 && not_called
}

test_caller_print_timeout_wins() {
  run_wrapper ask hello --print-timeout 10s
  [ "$(count_arg --print-timeout)" = 1 ] && arg_pair --print-timeout 10s
}

test_timeout_keeps_exit_code_and_reports_resume() {
  AGY_RC=3 JSON='{"conversation_id":"c-t","status":"ERROR","error":"print timeout after 3s","response":"","finished_reason":"print_timeout"}' run_wrapper ask hello
  exited 3 && stderr_has "timed out" && stderr_has "--resume c-t"
}

# --- agent, effort, resume validation --------------------------------------

test_agent_flag() {
  run_wrapper ask --agent reviewer hello
  [ "$(passed_args)" = "$(printf '%s\n' --agent reviewer -p hello)" ] || return 1
  run_wrapper ask --agent=self hello
  [ "$(passed_args)" = "$(printf '%s\n' --agent self -p hello)" ]
}

test_empty_flag_values_rejected() {
  local args
  for args in "--agent" "--agent=" "--resume" "--resume=" "--effort"; do
    run_wrapper ask $args
    exited 64 && not_called || { echo "       case: $args"; return 1; }
  done
}

test_invalid_effort_rejected() {
  run_wrapper ask --effort extreme hello
  exited 64 && not_called && stderr_has "invalid --effort" || return 1
  run_wrapper ask --effort=max hello
  exited 0 && [ "$(passed_args)" = "$(printf '%s\n' --effort max -p hello)" ]
}

test_all_flags_combined_any_order() {
  run_wrapper ask --read-only --agent a --resume r1 --timeout 5m --effort low --model flash hello --add-dir /x
  exited 0 && arg_pair --print-timeout 5m &&
    is_read_only && [ "$(passed_args)" = "$(printf '%s\n' --model "Gemini 3.8 Flash (Low)" --conversation r1 \
      --agent a -p hello --add-dir /x)" ]
}

# --- model + effort -------------------------------------------------------

test_effort_switches_alias_tier() {
  MODELS_FILE="$MODELS_REAL" run_wrapper ask --model opus --effort low hello
  exited 0 && [ "$(passed_args)" = "$(printf '%s\n' --model claude-opus-5-5-low -p hello)" ]
}

test_effort_switches_full_id_tier() {
  MODELS_FILE="$MODELS_REAL" run_wrapper ask --model gemini-4-neon-high --effort xhigh hello
  exited 0 && [ "$(passed_args)" = "$(printf '%s\n' --model gemini-4-neon-xhigh -p hello)" ]
}

test_effort_missing_tier_lists_available() {
  MODELS_FILE="$MODELS_REAL" run_wrapper ask --model flash --effort xhigh hello
  exited 64 && not_called && stderr_has "no 'xhigh' tier" && stderr_has "high, low"
}

test_effort_untiered_model_keeps_flag() {
  MODELS_FILE="$MODELS_REAL" run_wrapper ask --model orchestrator --effort high hello
  exited 0 && [ "$(passed_args)" = "$(printf '%s\n' --model gemini-pro-orchestrator --effort high -p hello)" ]
}

test_effort_without_model_passes_through() {
  run_wrapper ask --effort medium hello
  exited 0 && [ "$(passed_args)" = "$(printf '%s\n' --effort medium -p hello)" ]
}

# --- prompt edge cases -----------------------------------------------------

test_prompt_special_characters_verbatim() {
  local p='a "b" $HOME `id` \e; rm -rf x && echo
second line 中文'
  run_wrapper ask "$p"
  exited 0 && [ "$(passed_args)" = "$(printf '%s\n' -p "$p")" ]
}

test_double_dash_allows_flag_like_prompt() {
  run_wrapper ask -- "--model is a word here"
  exited 0 && [ "$(passed_args)" = "$(printf '%s\n' -p "--model is a word here")" ]
}

test_empty_prompts_rejected() {
  run_wrapper ask ""
  exited 64 && not_called || return 1
  run_wrapper swarm --effort low
  exited 64 && not_called
}

# --- JSON envelope handling ------------------------------------------------

test_waiting_status_is_failure() {
  JSON='{"conversation_id":"c-w","status":"WAITING","response":"partial"}' run_wrapper ask hello
  exited 1 && stdout_has partial && stderr_has "status: WAITING"
}

test_non_json_output_passes_through() {
  JSON='not json {' run_wrapper ask hello
  exited 0 && [ "$OUT" = "not json {" ]
}

test_silent_failure_keeps_exit_code() {
  AGY_RC=5 SILENT=1 run_wrapper ask hello
  exited 5 && [ -z "$OUT" ]
}

test_unicode_response() {
  JSON='{"conversation_id":"c-u","status":"SUCCESS","response":"中文 ✓ é\n"}' run_wrapper ask hello
  exited 0 && [ "$OUT" = "中文 ✓ é" ]
}

test_caller_output_format_disables_wrapping() {
  run_wrapper ask hello --output-format text
  exited 0 && [ "$(count_arg --output-format)" = 1 ] && arg_pair --output-format text && [ "$OUT" = stub-response ]
}

# --- environment problems --------------------------------------------------

test_missing_agy() {
  RUN_PATH="/usr/bin:/bin" run_wrapper ask hello
  exited 127 && stderr_has "not installed"
}

test_missing_auth() {
  NO_AUTH=1 run_wrapper ask hello
  exited 1 && not_called && stderr_has "not authenticated"
}

# --- review ----------------------------------------------------------------

test_review_outside_git_repo() {
  mkdir -p "$WORK/plain"
  RUN_DIR="$WORK/plain" run_wrapper review
  exited 1 && not_called && stderr_has "not inside a git repository"
}

test_review_clean_repo() {
  local d; d="$(new_repo clean)"
  echo a > "$d/a.txt"; git_q -C "$d" add a.txt; git_q -C "$d" commit -qm i
  RUN_DIR="$d" run_wrapper review
  exited 1 && not_called && stderr_has "no git diff"
}

test_review_includes_odd_untracked_names_and_skips_ignored() {
  local d; d="$(new_repo odd)"
  echo a > "$d/a.txt"; printf 'secret.log\n' > "$d/.gitignore"
  git_q -C "$d" add .; git_q -C "$d" commit -qm i
  echo zh_content > "$d/新檔案.py"; echo sp_content > "$d/with space.txt"; echo hidden > "$d/secret.log"
  RUN_DIR="$d" run_wrapper review
  exited 0 && raw_args | grep -q zh_content && raw_args | grep -q sp_content && ! raw_args | grep -q hidden
}

test_review_repo_without_commits() {
  local d; d="$(new_repo nohead)"
  echo staged_content > "$d/s.txt"; git_q -C "$d" add s.txt
  RUN_DIR="$d" run_wrapper review
  exited 0 && raw_args | grep -q staged_content
}

test_review_is_read_only_and_timed() {
  local d; d="$(new_repo ro)"
  echo x > "$d/x.txt"
  RUN_DIR="$d" run_wrapper review "focus here"
  exited 0 && is_read_only && arg_pair --print-timeout 30m && raw_args | grep -q "focus here" \
    && ! raw_args | grep -q "Reply in" || return 1
  REPLY_LANG_ENV="Traditional Chinese (Taiwan)" RUN_DIR="$d" run_wrapper review
  raw_args | grep -q "Reply in Traditional Chinese (Taiwan)"
}

test_review_truncates_large_diff() {
  local d; d="$(new_repo big)"
  # Eight files, each over its per-file share, push the total over the cap.
  local i n; for n in 1 2 3 4 5 6 7 8; do
    for i in $(seq 1 50); do echo "檔$n 第 $i 行 中文內容"; done > "$d/f$n.txt"
  done
  MAX_DIFF=500 RUN_DIR="$d" run_wrapper review
  exited 0 && stderr_has "truncated to 500" && raw_args | grep -q "diff truncated by the wrapper" \
    && raw_args | grep -q "f8.txt (untracked)" && ! raw_args | grep -q "第 50 行" && [ "$(raw_args | wc -c)" -lt 2000 ]
}

test_review_big_file_does_not_hide_others() {
  local d; d="$(new_repo starve)"
  echo a > "$d/a.txt"; git_q -C "$d" add a.txt; git_q -C "$d" commit -qm i
  echo changed >> "$d/a.txt"
  local i; for i in $(seq 1 3000); do echo "noise $i 中文"; done > "$d/aaa-big.log"
  echo small_file_content > "$d/zzz-小檔.py"
  MAX_DIFF=20000 RUN_DIR="$d" run_wrapper review
  exited 0 && raw_args | grep -q small_file_content && raw_args | grep -q "zzz-小檔.py (untracked)" \
    && raw_args | grep -qx "  a.txt" && raw_args | grep -q "untracked file truncated"
}

test_review_caps_untracked_file_count() {
  local d; d="$(new_repo many)"
  mkdir -p "$d/node_modules"
  local i; for i in $(seq 1 260); do echo "m$i" > "$d/node_modules/f$i.js"; done
  RUN_DIR="$d" run_wrapper review
  exited 0 && stderr_has "260 untracked files" && raw_args | grep -q "and 60 more untracked files" \
    && [ "$(raw_args | grep -c '(untracked)$')" = 200 ]
}

test_review_huge_multibyte_diff_is_fast() {
  local d; d="$(new_repo huge)"
  local i; for i in $(seq 1 8000); do echo "log line $i 中文內容填充資料測試"; done > "$d/big.log"
  local start=$SECONDS
  RUN_DIR="$d" run_wrapper review
  exited 0 && [ $((SECONDS - start)) -lt 15 ] && raw_args | grep -q "untracked file truncated" \
    && [ "$(raw_args | wc -c)" -lt 110000 ]
}

# --- background jobs --------------------------------------------------------

stream_file() {
  local f="$WORK/stream-$1.txt"; shift
  printf '%s\n' "$@" > "$f"
  printf '%s' "$f"
}

job_id() {
  printf '%s' "$OUT" | sed -n 's/.*job started: //p'
}

# Waits for the detached stub to record its argv (job start is asynchronous).
wait_args() {
  local i; for i in $(seq 1 50); do [ -s "$WORK/args" ] && return 0; sleep 0.1; done
  return 1
}

EV_INIT='{"event":"init","conversation_id":"c-1","init":{}}'
EV_TOOL='{"event":"step_update","step_update":{"conversation_id":"c-1","state":"DONE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"npm test"}}}}'
EV_OK='{"event":"result","result":{"conversation_id":"c-1","status":"SUCCESS","response":"all done 完成","duration_seconds":2,"usage":{"total_tokens":42},"denied_actions":[{"action":"command","display_name":"Bash"}]}}'

test_job_starts_fast_and_watch_returns_result() {
  local st=$SECONDS
  STREAM="$(stream_file ok "$EV_INIT" "$EV_TOOL" "sleep 1" "$EV_OK")" run_wrapper start --model flash "do the thing"
  local id; id="$(job_id)"
  exited 0 && [ -n "$id" ] && [ $((SECONDS - st)) -lt 3 ] && wait_args || return 1
  # Jobs may edit (no read-only), have no time limit, and stream events.
  ! is_read_only && [ "$(count_arg --print-timeout)" = 0 ] && arg_pair --output-format stream-json \
    && [ "$(passed_args)" = "$(printf '%s\n' --model "Gemini 3.8 Flash (High)" -p "do the thing")" ] || return 1
  run_wrapper watch "$id" --interval 200ms
  exited 0 && stdout_has "all done 完成" && stdout_has "run_command npm test" \
    && stderr_has "1 action(s) were blocked" && stderr_has "conversation: c-1" && stderr_has "42 tokens"
}

test_job_flags_read_only_and_timeout() {
  STREAM="$(stream_file ro "$EV_INIT" "$EV_OK")" run_wrapper start --read-only --timeout 5m task
  exited 0 && wait_args && is_read_only && arg_pair --print-timeout 5m
}

test_job_rejects_output_format() {
  run_wrapper start task --output-format json
  exited 64 && stderr_has "always use --output-format stream-json"
}

test_watch_reports_stall_then_stop_keeps_partial() {
  STREAM="$(stream_file stall "$EV_INIT" "sleep 30")" run_wrapper start task
  local id; id="$(job_id)"; wait_args || return 1
  run_wrapper watch "$id" --interval 200ms --stall 1s
  exited 2 && stdout_has "STALLED" || return 1
  run_wrapper status "$id"
  exited 0 && stdout_has "running" || return 1
  run_wrapper stop "$id"
  exited 0 && stdout_has "stopped" || return 1
  run_wrapper result "$id"
  exited 1 && stdout_has "partial answer" && stderr_has "INTERRUPTED" || return 1
  run_wrapper status "$id"
  stdout_has "stopped"
}

test_watch_reports_died_job() {
  STREAM="$(stream_file died "$EV_INIT")" AGY_RC=7 run_wrapper start task
  local id; id="$(job_id)"; wait_args || return 1
  run_wrapper watch "$id" --interval 200ms
  exited 1 && stderr_has "without a result"
}

test_result_while_running() {
  STREAM="$(stream_file running "$EV_INIT" "sleep 30")" run_wrapper start task
  local id; id="$(job_id)"; wait_args || return 1
  run_wrapper result "$id"
  local rc=$RC
  run_wrapper stop "$id"
  [ "$rc" -eq 3 ]
}

test_swarm_job_reports_members_and_counts_their_activity() {
  local sw="$WORK/agyhome/brain/c-sw/.system_generated/swarm" db="$WORK/agyhome/conversations/c-w1.db"
  mkdir -p "$sw" "$WORK/agyhome/conversations"
  printf '%s' '{"members":{"coordinator":{"conversation_id":"c-sw","role":"coordinator"},"tw":{"conversation_id":"c-w1","role":"worker"},"jp":{"conversation_id":"c-w2","role":"worker"}}}' > "$sw/members.json"
  printf '%s\n' '{"seq":1,"agent":"coordinator","text":"@tw go"}' '{"seq":2,"agent":"tw","text":"@coordinator [done] 臺北"}' > "$sw/board.jsonl"
  local res='{"event":"result","result":{"conversation_id":"c-sw","status":"SUCCESS","response":"merged"}}'
  STREAM="$(stream_file swarm '{"event":"init","conversation_id":"c-sw","init":{}}' "sleep 3" "$res")" run_wrapper swarm --effort low "split work"
  local id; id="$(job_id)"; wait_args || return 1
  raw_args | grep -qx -- "/swarm split work" || return 1
  run_wrapper status "$id"
  stdout_has "members: jp, tw" && stdout_has "board #2 tw" && stdout_has "swarm" || return 1
  # The coordinator stays silent for 3s, but a worker keeps writing: not a stall.
  ( for _ in $(seq 1 15); do touch "$db"; sleep 0.2; done ) &
  run_wrapper watch "$id" --interval 200ms --stall 1s
  wait
  exited 0 && stdout_has "merged" && ! stdout_has "STALLED"
}

test_status_lists_jobs_and_validates_ids() {
  STREAM="$(stream_file list "$EV_INIT" "$EV_OK")" run_wrapper start "listed task"
  local id; id="$(job_id)"; wait_args || return 1
  run_wrapper status
  exited 0 && stdout_has "$id" && stdout_has "listed task" || return 1
  run_wrapper watch "../../etc"
  exited 64 && stderr_has "invalid job id" || return 1
  run_wrapper watch "20990101-000000-dead"
  exited 1 && stderr_has "no such job" || return 1
  run_wrapper watch "$id" --bogus
  exited 64
}

test_old_finished_jobs_are_pruned() {
  mkdir -p "$WORK/jobs/old-job"
  printf '%s' '{"id":"old-job","pid":999999,"started":0,"kind":"task","label":"x"}' > "$WORK/jobs/old-job/meta.json"
  STREAM="$(stream_file prune "$EV_INIT" "$EV_OK")" run_wrapper start task
  exited 0 && [ ! -d "$WORK/jobs/old-job" ]
}

# --- without python3 ---------------------------------------------------------

nopy_path() {
  local d="$WORK/nopy" t
  if [ ! -d "$d" ]; then
    mkdir -p "$d"; ln -s "$WORK/bin/agy" "$d/agy"
    for t in bash sh git awk sed grep head tail tr wc cat iconv cp mv rm mkdir ps sleep env dirname date seq sort cut; do
      [ -x "$(command -v "$t")" ] && ln -s "$(command -v "$t")" "$d/$t"
    done
  fi
  printf '%s' "$d"
}

test_without_python_ask_passes_through_and_jobs_refuse() {
  RUN_PATH="$(nopy_path)" run_wrapper ask hello
  exited 0 && [ "$OUT" = stub-response ] && is_read_only && arg_pair --print-timeout 30m || return 1
  RUN_PATH="$(nopy_path)" run_wrapper start task
  exited 1 && stderr_has "need python3"
}

# --- image ----------------------------------------------------------------

test_image_has_timeout_and_warns_without_path() {
  run_wrapper image "a red cube"
  exited 0 && arg_pair --print-timeout 30m && stderr_has "did not include an IMAGE_PATH"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  check "${t#test_}" "$t"
done

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
