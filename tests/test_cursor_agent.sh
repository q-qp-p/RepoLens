#!/usr/bin/env bash
# Copyright 2025-2026 Bootstrap Academy
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Behavioural contract for issue #390: native Cursor CLI support.
#
# No real model is invoked. PATH contains hermetic cursor-agent, codex, and
# (for the run_agent unit checks only) timeout shims. The end-to-end checks use
# the real timeout(1) wrapper and drive the full RepoLens lens loop.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$SCRIPT_DIR/lib/core.sh"
REPOLENS="$SCRIPT_DIR/repolens.sh"
PRICING="$SCRIPT_DIR/config/agent-pricing.json"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
RUN_IDS=()

# shellcheck disable=SC2329 # Invoked through the EXIT trap.
cleanup() {
  local run_id
  rm -rf "$TMPDIR"
  for run_id in "${RUN_IDS[@]:-}"; do
    [[ -z "$run_id" ]] || rm -rf "$SCRIPT_DIR/logs/$run_id"
  done
}
trap cleanup EXIT

pass_with() {
  PASS=$((PASS + 1))
  printf '  PASS: %s\n' "$1"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  printf '  FAIL: %s\n' "$desc"
  [[ -z "$detail" ]] || printf '    %s\n' "$detail"
}

assert_success() {
  local desc="$1" rc="$2"
  TOTAL=$((TOTAL + 1))
  if (( rc == 0 )); then
    pass_with "$desc"
  else
    fail_with "$desc" "expected exit 0, got $rc"
  fi
}

assert_failure() {
  local desc="$1" rc="$2"
  TOTAL=$((TOTAL + 1))
  if (( rc != 0 )); then
    pass_with "$desc"
  else
    fail_with "$desc" "expected non-zero exit, got 0"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" == "$expected" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "expected='$expected' actual='$actual'"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "missing '$needle'"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "unexpected '$needle'"
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "missing file '$path'"
  fi
}

assert_file_not_contains() {
  local desc="$1" needle="$2" path="$3"
  TOTAL=$((TOTAL + 1))
  if [[ ! -f "$path" ]] || ! grep -qF "$needle" "$path"; then
    pass_with "$desc"
  else
    fail_with "$desc" "unexpected '$needle' in '$path'"
  fi
}

record_run_id_from() {
  local out_file="$1" run_id
  run_id="$(sed -n 's/.*Run ID:[[:space:]]*//p' "$out_file" | head -1)"
  if [[ -z "$run_id" ]]; then
    run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$out_file" 2>/dev/null | head -1 | awk '{print $3}')"
  fi
  [[ -z "$run_id" ]] || RUN_IDS+=("$run_id")
}

# shellcheck disable=SC1090
source "$CORE"

printf '%s\n' "=== Cursor agent validation and dependency mapping ==="

out="$(validate_agent cursor 2>&1)"
rc=$?
assert_success "validate_agent accepts cursor" "$rc"

out="$(validate_agent cursor/gpt-5 2>&1)"
rc=$?
assert_success "validate_agent accepts cursor/<model>" "$rc"

out="$(validate_agent cursor/ 2>&1)"
rc=$?
assert_failure "validate_agent rejects an empty Cursor model" "$rc"
assert_contains "empty Cursor model has an actionable error" "missing model" "$out"

FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"

# Records the timeout wrapper, then executes the wrapped command.
cat > "$FAKE_BIN/timeout" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${CURSOR_TIMEOUT_ARGS:?}"
shift 2
exec "$@"
SHIM
chmod +x "$FAKE_BIN/timeout"

# Records Cursor argv, cwd and stdin state; emits the documented terminal JSON
# result envelope used by `cursor-agent --print --output-format json`.
cat > "$FAKE_BIN/cursor-agent" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${CURSOR_ARGS:?}"
pwd > "${CURSOR_PWD:?}"
if IFS= read -r _line; then
  printf '%s\n' "open" > "${CURSOR_STDIN:?}"
else
  printf '%s\n' "closed" > "${CURSOR_STDIN:?}"
fi
case "${CURSOR_OUTPUT_MODE:-success}" in
  success)
    jq -cn \
      --arg result "${CURSOR_OUTPUT:-DONE}" \
      '{
        type: "result",
        subtype: "success",
        is_error: false,
        duration_ms: 12,
        duration_api_ms: 9,
        result: $result,
        session_id: "cursor-unit-session",
        request_id: "cursor-unit-request"
      }'
    ;;
  malformed)
    printf '%s\n' '{"type":"result","result":'
    ;;
  unsuccessful)
    printf '%s\n' \
      '{"type":"result","subtype":"error","is_error":true,"result":"DONE","session_id":"cursor-unit-session"}'
    ;;
esac
exit "${CURSOR_EXIT_CODE:-0}"
SHIM
chmod +x "$FAKE_BIN/cursor-agent"

# Dependency-only shim for the mixed routed-cost dry run below.
cat > "$FAKE_BIN/codex" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "DONE"
SHIM
chmod +x "$FAKE_BIN/codex"

out="$(PATH="$FAKE_BIN:$PATH" require_agent_cmd cursor 2>&1)"
rc=$?
assert_success "require_agent_cmd maps cursor to cursor-agent" "$rc"

NO_CURSOR_BIN="$TMPDIR/no-cursor"
mkdir -p "$NO_CURSOR_BIN"
out="$(PATH="$NO_CURSOR_BIN" require_agent_cmd cursor 2>&1)"
rc=$?
assert_failure "require_agent_cmd fails when cursor-agent is missing" "$rc"
assert_contains "missing dependency names cursor-agent" "Missing required command: cursor-agent" "$out"

printf '\n%s\n' "=== Cursor timeout and dispatch ==="

out="$(REPOLENS_AGENT_TIMEOUT_CURSOR=17 REPOLENS_AGENT_TIMEOUT=99 resolve_agent_timeout audit cursor)"
assert_eq "Cursor-specific timeout wins over global timeout" "17" "$out"

out="$(REPOLENS_AGENT_TIMEOUT_CURSOR=18 resolve_agent_timeout audit cursor/gpt-5)"
assert_eq "Cursor model variants share the Cursor timeout" "18" "$out"

PROJECT="$TMPDIR/project"
mkdir -p "$PROJECT"
CURSOR_ARGS="$TMPDIR/cursor-args"
CURSOR_TIMEOUT_ARGS="$TMPDIR/timeout-args"
CURSOR_PWD="$TMPDIR/cursor-pwd"
CURSOR_STDIN="$TMPDIR/cursor-stdin"
CURSOR_ENVELOPE="$TMPDIR/cursor-envelope.json"
export CURSOR_ARGS CURSOR_TIMEOUT_ARGS CURSOR_PWD CURSOR_STDIN

out="$(PATH="$FAKE_BIN:$PATH" run_agent cursor "AUDIT PROMPT" "$PROJECT" 23 7 "$CURSOR_ENVELOPE")"
rc=$?
assert_success "run_agent cursor propagates success" "$rc"
assert_eq "Cursor terminal result is extracted as plain text" "DONE" "$out"
assert_file_exists "Cursor terminal JSON envelope is persisted" "$CURSOR_ENVELOPE"
assert_eq "persisted Cursor envelope retains its result type" "result" \
  "$(jq -r '.type' "$CURSOR_ENVELOPE")"
assert_eq "persisted Cursor envelope retains the unwrapped result" "DONE" \
  "$(jq -r '.result' "$CURSOR_ENVELOPE")"
assert_eq "Cursor runs from the audited project" "$PROJECT" "$(cat "$CURSOR_PWD")"
assert_eq "Cursor stdin is closed for unattended execution" "closed" "$(cat "$CURSOR_STDIN")"
assert_eq "timeout receives kill grace" "--kill-after=7s" "$(sed -n '1p' "$CURSOR_TIMEOUT_ARGS")"
assert_eq "timeout receives invocation budget" "23s" "$(sed -n '2p' "$CURSOR_TIMEOUT_ARGS")"
assert_eq "timeout wraps cursor-agent" "cursor-agent" "$(sed -n '3p' "$CURSOR_TIMEOUT_ARGS")"

mapfile -t bare_args < "$CURSOR_ARGS"
assert_eq "bare Cursor enables unattended command approval" "--force" "${bare_args[0]:-}"
assert_eq "bare Cursor uses non-interactive print mode" "--print" "${bare_args[1]:-}"
assert_eq "bare Cursor requests structured output" "--output-format" "${bare_args[2]:-}"
assert_eq "bare Cursor output format is terminal JSON" "json" "${bare_args[3]:-}"
assert_eq "prompt remains one argv item" "AUDIT PROMPT" "${bare_args[4]:-}"
assert_eq "bare Cursor omits model selection for native routing" "5" "${#bare_args[@]}"
assert_not_contains "bare Cursor never synthesizes an Auto model name" \
  "--model" "$(tr '\n' ' ' < "$CURSOR_ARGS")"

out="$(PATH="$FAKE_BIN:$PATH" run_agent cursor/claude-4-sonnet "MODEL PROMPT" "$PROJECT" 23 7)"
rc=$?
assert_success "run_agent cursor/<model> propagates success" "$rc"
mapfile -t model_args < "$CURSOR_ARGS"
assert_eq "Cursor model suffix is passed through unchanged" "claude-4-sonnet" "${model_args[5]:-}"
assert_eq "model prompt remains one argv item" "MODEL PROMPT" "${model_args[6]:-}"

out="$(PATH="$FAKE_BIN:$PATH" CURSOR_EXIT_CODE=42 run_agent cursor "FAIL PROMPT" "$PROJECT" 23 7 2>&1)"
rc=$?
assert_eq "Cursor CLI rejects and propagates a non-zero result" "42" "$rc"
assert_contains "non-zero Cursor output remains diagnostic JSON instead of an accepted result" \
  '"type":"result"' "$out"

MALFORMED_ENVELOPE="$TMPDIR/cursor-malformed-envelope.json"
out="$(
  PATH="$FAKE_BIN:$PATH" CURSOR_OUTPUT_MODE=malformed \
    run_agent cursor "MALFORMED PROMPT" "$PROJECT" 23 7 "$MALFORMED_ENVELOPE" 2>&1
)"
rc=$?
assert_failure "Cursor CLI rejects malformed JSON at exit zero" "$rc"
assert_contains "malformed Cursor JSON has an actionable diagnostic" \
  "malformed or unsuccessful JSON result envelope" "$out"
assert_eq "malformed Cursor output is still persisted for diagnosis" \
  '{"type":"result","result":' "$(cat "$MALFORMED_ENVELOPE")"

out="$(
  PATH="$FAKE_BIN:$PATH" CURSOR_OUTPUT_MODE=unsuccessful \
    run_agent cursor "ERROR ENVELOPE" "$PROJECT" 23 7 2>&1
)"
rc=$?
assert_failure "Cursor CLI rejects an unsuccessful JSON envelope at exit zero" "$rc"

printf '\n%s\n' "=== Cursor end-to-end lens-loop integration ==="

# Unlike the run_agent calls above, these cases invoke repolens.sh without
# --dry-run. The cursor-agent shim records dispatch and emits scenario-specific
# output while GNU timeout remains in the execution path.
E2E_BIN="$TMPDIR/e2e-bin"
E2E_PROJECT="$TMPDIR/e2e-project"
E2E_INVOKE_LOG="$TMPDIR/e2e-invocations.log"
mkdir -p "$E2E_BIN" "$E2E_PROJECT"
git -C "$E2E_PROJECT" init -q
git -C "$E2E_PROJECT" config user.email test@example.com
git -C "$E2E_PROJECT" config user.name "Cursor test"
printf '# Cursor end-to-end fixture\n' > "$E2E_PROJECT/README.md"
git -C "$E2E_PROJECT" add README.md
git -C "$E2E_PROJECT" commit -q -m init

cat > "$E2E_BIN/cursor-agent" <<'SHIM'
#!/usr/bin/env bash
set -uo pipefail

{
  printf 'cursor-agent'
  printf '\t%s' "$@"
  printf '\n'
} >> "${CURSOR_E2E_INVOKE_LOG:?}"

case "${CURSOR_E2E_MODE:-success}" in
  success)
    jq -cn \
      --arg result $'Cursor loop payload reached the iteration capture.\nDONE\n' \
      '{
        type: "result",
        subtype: "success",
        is_error: false,
        duration_ms: 24,
        duration_api_ms: 20,
        result: $result,
        session_id: "cursor-e2e-session",
        request_id: "cursor-e2e-request"
      }'
    ;;
  auth-expired)
    printf 'Not logged in · Please run /login\n' >&2
    exit 1
    ;;
  timeout)
    sleep 10
    jq -cn \
      --arg result 'DONE' \
      '{type: "result", subtype: "success", is_error: false, result: $result, session_id: "late"}'
    ;;
  *)
    printf 'Unknown Cursor test mode: %s\n' "${CURSOR_E2E_MODE:-}" >&2
    exit 2
    ;;
esac
SHIM
chmod +x "$E2E_BIN/cursor-agent"

cat > "$E2E_BIN/codex" <<'SHIM'
#!/usr/bin/env bash
set -uo pipefail
printf 'codex\n' >> "${CURSOR_E2E_INVOKE_LOG:?}"
printf 'DONE\n'
SHIM
chmod +x "$E2E_BIN/codex"

# Bare Cursor: prove the terminal JSON envelope is persisted, only its result
# reaches the iteration output, DONE advances the real streak, and both the
# per-lens completion marker and terminal state are written.
: > "$E2E_INVOKE_LOG"
E2E_BARE_OUT="$TMPDIR/e2e-bare.out"
PATH="$E2E_BIN:$PATH" \
  CURSOR_E2E_INVOKE_LOG="$E2E_INVOKE_LOG" \
  CURSOR_E2E_MODE=success \
  REPOLENS_AGENT_TIMEOUT_CURSOR=5 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  bash "$REPOLENS" \
    --project "$E2E_PROJECT" \
    --agent cursor \
    --mode audit \
    --depth 1 \
    --local \
    --yes \
    --focus authorization \
    --output "$TMPDIR/e2e-bare-issues" \
    >"$E2E_BARE_OUT" 2>&1
rc=$?
record_run_id_from "$E2E_BARE_OUT"
e2e_bare_run_id="$(sed -n 's/.*Run ID:[[:space:]]*//p' "$E2E_BARE_OUT" | head -1)"
[[ -n "$e2e_bare_run_id" ]] || e2e_bare_run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$E2E_BARE_OUT" | head -1 | awk '{print $3}')"
e2e_bare_dir="$SCRIPT_DIR/logs/$e2e_bare_run_id"
e2e_bare_iteration="$(find "$e2e_bare_dir/security/authorization" -maxdepth 1 -name 'iteration-1-*.txt' -print -quit 2>/dev/null)"
e2e_bare_envelope="${e2e_bare_iteration}.envelope.json"
assert_success "bare Cursor completes a non-dry-run lens" "$rc"
assert_contains "bare Cursor is dispatched by the real lens loop" "cursor-agent" "$(cat "$E2E_INVOKE_LOG")"
assert_contains "bare Cursor requests JSON output end to end" \
  $'\t--output-format\tjson\t' "$(cat "$E2E_INVOKE_LOG")"
assert_not_contains "bare Cursor leaves model routing to Cursor end to end" \
  $'\t--model\t' "$(cat "$E2E_INVOKE_LOG")"
assert_contains "Cursor backend output reaches the iteration capture" \
  "Cursor loop payload reached the iteration capture." "$(cat "$e2e_bare_iteration" 2>/dev/null)"
assert_not_contains "iteration capture contains no JSON envelope metadata" \
  '"session_id"' "$(cat "$e2e_bare_iteration" 2>/dev/null)"
assert_file_exists "real lens loop persists the Cursor JSON envelope" "$e2e_bare_envelope"
assert_eq "real lens loop envelope retains Cursor session metadata" "cursor-e2e-session" \
  "$(jq -r '.session_id' "$e2e_bare_envelope")"
assert_contains "real lens loop envelope retains the terminal result" \
  "Cursor loop payload reached the iteration capture." \
  "$(jq -r '.result' "$e2e_bare_envelope")"
assert_contains "Cursor output advances DONE detection" \
  "DONE detected (1/1 consecutive)" "$(cat "$E2E_BARE_OUT")"
assert_contains "Cursor output completes the DONE streak" \
  "DONE x1 — lens complete." "$(cat "$E2E_BARE_OUT")"
assert_contains "the completed Cursor lens is persisted in .completed" \
  "security/authorization" "$(cat "$e2e_bare_dir/.completed" 2>/dev/null)"
assert_eq "the completed Cursor lens has completed summary status" "completed" \
  "$(jq -r '.lenses[] | select(.domain == "security" and .lens == "authorization") | .status' "$e2e_bare_dir/summary.json")"
assert_contains "the successful Cursor run publishes a terminal finished state" "finished" \
  "$(jq -r '.state' "$e2e_bare_dir/status.json")"

# Pinned Cursor through a lens override: this is the full
# parse -> override resolution -> run_agent cursor/<model> -> DONE path.
: > "$E2E_INVOKE_LOG"
E2E_OVERRIDE_OUT="$TMPDIR/e2e-override.out"
PATH="$E2E_BIN:$PATH" \
  CURSOR_E2E_INVOKE_LOG="$E2E_INVOKE_LOG" \
  CURSOR_E2E_MODE=success \
  REPOLENS_AGENT_TIMEOUT_CURSOR=5 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  bash "$REPOLENS" \
    --project "$E2E_PROJECT" \
    --agent codex \
    --agent-override security/authorization=cursor/claude-4-sonnet \
    --mode audit \
    --depth 1 \
    --local \
    --yes \
    --focus authorization \
    --output "$TMPDIR/e2e-override-issues" \
    >"$E2E_OVERRIDE_OUT" 2>&1
rc=$?
record_run_id_from "$E2E_OVERRIDE_OUT"
e2e_override_run_id="$(sed -n 's/.*Run ID:[[:space:]]*//p' "$E2E_OVERRIDE_OUT" | head -1)"
[[ -n "$e2e_override_run_id" ]] || e2e_override_run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$E2E_OVERRIDE_OUT" | head -1 | awk '{print $3}')"
e2e_override_dir="$SCRIPT_DIR/logs/$e2e_override_run_id"
e2e_override_invocations="$(cat "$E2E_INVOKE_LOG")"
assert_success "cursor/<model> override completes a non-dry-run lens" "$rc"
assert_contains "the override dispatches Cursor instead of the global backend" \
  "cursor-agent" "$e2e_override_invocations"
assert_not_contains "the global Codex backend does not run the overridden lens" \
  "codex" "$e2e_override_invocations"
assert_contains "the pinned Cursor model reaches cursor-agent unchanged" \
  $'\t--model\tclaude-4-sonnet\t' "$e2e_override_invocations"
assert_contains "the real loop logs the Cursor override decision" \
  "Routed to agent 'cursor/claude-4-sonnet'" "$(cat "$E2E_OVERRIDE_OUT")"
assert_contains "the overridden Cursor lens writes its completion marker" \
  "security/authorization" "$(cat "$e2e_override_dir/.completed" 2>/dev/null)"

# Persistent failure classification must consume Cursor's captured output just
# like every other text backend. A classified failure aborts after one attempt
# and must never mark the lens complete.
: > "$E2E_INVOKE_LOG"
E2E_AUTH_OUT="$TMPDIR/e2e-auth.out"
PATH="$E2E_BIN:$PATH" \
  CURSOR_E2E_INVOKE_LOG="$E2E_INVOKE_LOG" \
  CURSOR_E2E_MODE=auth-expired \
  REPOLENS_AGENT_TIMEOUT_CURSOR=5 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  bash "$REPOLENS" \
    --project "$E2E_PROJECT" \
    --agent cursor \
    --mode audit \
    --depth 1 \
    --local \
    --yes \
    --focus authorization \
    --output "$TMPDIR/e2e-auth-issues" \
    >"$E2E_AUTH_OUT" 2>&1
rc=$?
record_run_id_from "$E2E_AUTH_OUT"
e2e_auth_run_id="$(sed -n 's/.*Run ID:[[:space:]]*//p' "$E2E_AUTH_OUT" | head -1)"
[[ -n "$e2e_auth_run_id" ]] || e2e_auth_run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$E2E_AUTH_OUT" | head -1 | awk '{print $3}')"
e2e_auth_dir="$SCRIPT_DIR/logs/$e2e_auth_run_id"
assert_failure "a classified Cursor authentication failure exits non-zero" "$rc"
assert_contains "Cursor output is classified as auth-expired" \
  "Persistent agent failure: auth-expired" "$(cat "$E2E_AUTH_OUT")"
assert_eq "Cursor classification reaches summary stopped_reason" "auth-expired" \
  "$(jq -r '.stopped_reason' "$e2e_auth_dir/summary.json")"
assert_eq "the failed Cursor lens records its exact class" "auth-expired" \
  "$(jq -r '.lenses[] | select(.domain == "security" and .lens == "authorization") | .status' "$e2e_auth_dir/summary.json")"
assert_file_exists "Cursor classification writes the systemic-failure marker" \
  "$e2e_auth_dir/.systemic-failure-abort"
assert_file_not_contains "a classified Cursor failure is not marked complete" \
  "security/authorization" "$e2e_auth_dir/.completed"

# Exercise GNU timeout around cursor/<model> from inside the real loop. A short
# watchdog and one-iteration no-progress threshold keep the test hermetic and
# fast while proving timeout rc=124 is logged, classified as degraded progress,
# persisted in summary state, and excluded from completion.
: > "$E2E_INVOKE_LOG"
E2E_TIMEOUT_OUT="$TMPDIR/e2e-timeout.out"
PATH="$E2E_BIN:$PATH" \
  CURSOR_E2E_INVOKE_LOG="$E2E_INVOKE_LOG" \
  CURSOR_E2E_MODE=timeout \
  REPOLENS_AGENT_TIMEOUT_CURSOR=1 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  REPOLENS_LENS_MAX_WALL=5 \
  REPOLENS_NO_PROGRESS_LIMIT=1 \
  bash "$REPOLENS" \
    --project "$E2E_PROJECT" \
    --agent cursor/slow-test-model \
    --mode audit \
    --depth 1 \
    --local \
    --yes \
    --focus authorization \
    --output "$TMPDIR/e2e-timeout-issues" \
    >"$E2E_TIMEOUT_OUT" 2>&1
rc=$?
record_run_id_from "$E2E_TIMEOUT_OUT"
e2e_timeout_run_id="$(sed -n 's/.*Run ID:[[:space:]]*//p' "$E2E_TIMEOUT_OUT" | head -1)"
[[ -n "$e2e_timeout_run_id" ]] || e2e_timeout_run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$E2E_TIMEOUT_OUT" | head -1 | awk '{print $3}')"
e2e_timeout_dir="$SCRIPT_DIR/logs/$e2e_timeout_run_id"
assert_failure "a timed-out Cursor lens fails the run" "$rc"
assert_contains "Cursor-specific watchdog expiry is reported by the real loop" \
  "agent timed out after 1s" "$(cat "$E2E_TIMEOUT_OUT")"
assert_contains "the timed-out pinned model was dispatched before expiry" \
  $'\t--model\tslow-test-model\t' "$(cat "$E2E_INVOKE_LOG")"
assert_eq "a timed-out Cursor lens records agent-no-progress" "agent-no-progress" \
  "$(jq -r '.lenses[] | select(.domain == "security" and .lens == "authorization") | .status' "$e2e_timeout_dir/summary.json")"
assert_file_not_contains "a timed-out Cursor lens is not marked complete" \
  "security/authorization" "$e2e_timeout_dir/.completed"

printf '\n%s\n' "=== CLI, pricing, and documentation contracts ==="

assert_eq "Cursor Auto pricing has no marginal token charge" "true" \
  "$(jq -r '.models[.agent_default_model.cursor].input_per_mtok == 0' "$PRICING")"
assert_contains "pricing metadata explains all Cursor variants are subscription-backed" \
  "Cursor and cursor/<model>" "$(jq -r '._comment' "$PRICING")"

HELP_OUT="$(bash "$REPOLENS" --help 2>&1)"
assert_contains "--help advertises cursor" "cursor" "$HELP_OUT"
assert_contains "--help advertises cursor/<model>" "cursor/<model>" "$HELP_OUT"

DRY_OUT="$TMPDIR/dry-run.out"
PATH="$FAKE_BIN:$PATH" bash "$REPOLENS" \
  --project "$SCRIPT_DIR" \
  --agent cursor \
  --local \
  --focus injection \
  --dry-run \
  --yes > "$DRY_OUT" 2>&1
rc=$?
assert_success "--agent cursor reaches a hermetic dry run" "$rc"
record_run_id_from "$DRY_OUT"
dry_output="$(cat "$DRY_OUT")"
assert_contains "dry run reports the Cursor agent" "Agent:        cursor" "$dry_output"
assert_contains "bare Cursor defaults to the subscription cost view" "Cursor Subscription" "$dry_output"
assert_contains "bare Cursor reports expected request consumption" "Total expected requests" "$dry_output"
assert_contains "bare Cursor reports plan quota rather than an API bill" "Cursor plan request/model quota" "$dry_output"
assert_not_contains "bare Cursor suppresses token-rate pricing" "per MTok" "$dry_output"
assert_not_contains "bare Cursor suppresses the pay-as-you-go multiplier" "2-5x" "$dry_output"
assert_not_contains "bare Cursor emits no pay-as-you-go billing language" \
  "pay-as-you-go" "$dry_output"

MODEL_DRY_OUT="$TMPDIR/model-dry-run.out"
PATH="$FAKE_BIN:$PATH" REPOLENS_FLAT_RATE=false bash "$REPOLENS" \
  --project "$SCRIPT_DIR" \
  --agent cursor/claude-4-sonnet \
  --local \
  --focus injection \
  --dry-run \
  --yes > "$MODEL_DRY_OUT" 2>&1
rc=$?
assert_success "--agent cursor/<model> reaches a hermetic dry run" "$rc"
record_run_id_from "$MODEL_DRY_OUT"
model_dry_output="$(cat "$MODEL_DRY_OUT")"
assert_contains "pinned Cursor reports the selected agent" \
  "Agent:        cursor/claude-4-sonnet" "$model_dry_output"
assert_contains "pinned Cursor defaults to the subscription cost view" \
  "Cursor Subscription" "$model_dry_output"
assert_contains "pinned Cursor reports expected request consumption" \
  "Total expected requests" "$model_dry_output"
assert_not_contains "pinned Cursor never inherits generic model token prices" \
  "per MTok" "$model_dry_output"
assert_not_contains "REPOLENS_FLAT_RATE=false cannot misclassify Cursor as pay-as-you-go" \
  "2-5x" "$model_dry_output"
assert_not_contains "pinned Cursor emits no pay-as-you-go billing language" \
  "pay-as-you-go" "$model_dry_output"

MIXED_DRY_OUT="$TMPDIR/mixed-dry-run.out"
PATH="$FAKE_BIN:$PATH" bash "$REPOLENS" \
  --project "$SCRIPT_DIR" \
  --agent codex \
  --agent-override security/injection=cursor/claude-4-sonnet \
  --local \
  --domain security \
  --dry-run \
  --yes > "$MIXED_DRY_OUT" 2>&1
rc=$?
assert_success "a mixed token/subscription routed estimate succeeds" "$rc"
record_run_id_from "$MIXED_DRY_OUT"
mixed_dry_output="$(cat "$MIXED_DRY_OUT")"
assert_contains "mixed routing limits the dollar estimate to billed lenses" \
  "Estimated pay-as-you-go portion" "$mixed_dry_output"
assert_contains "mixed routing gives the Cursor group its own subscription block" \
  "agent 'cursor/claude-4-sonnet'" "$mixed_dry_output"
assert_contains "mixed routing reports Cursor request consumption" \
  "Cursor Subscription" "$mixed_dry_output"
assert_not_contains "mixed routing does not assign Cursor a generic model class" \
  "generic pro class" "$mixed_dry_output"

FLAT_DRY_OUT="$TMPDIR/flat-dry-run.out"
PATH="$FAKE_BIN:$PATH" bash "$REPOLENS" \
  --project "$SCRIPT_DIR" \
  --agent cursor/claude-4-sonnet \
  --local \
  --focus injection \
  --flat-rate \
  --dry-run \
  --yes > "$FLAT_DRY_OUT" 2>&1
rc=$?
assert_success "explicit --flat-rate stays valid for Cursor" "$rc"
record_run_id_from "$FLAT_DRY_OUT"
flat_dry_output="$(cat "$FLAT_DRY_OUT")"
assert_contains "explicit --flat-rate keeps the generic subscription/free-tier view" \
  "Flat-Rate / Subscription / Free Tier" "$flat_dry_output"
assert_contains "explicit --flat-rate still reports expected requests" \
  "Total expected requests" "$flat_dry_output"
assert_not_contains "explicit --flat-rate suppresses pay-as-you-go language" \
  "2-5x" "$flat_dry_output"

assert_contains "README lists Cursor CLI installation" "curl -fsSL https://cursor.com/install" "$(cat "$SCRIPT_DIR/README.md")"
assert_contains "README documents subscription authentication" "Cursor subscription" "$(cat "$SCRIPT_DIR/README.md")"
assert_contains "README documents automatic Cursor quota costing" \
  "quota-oriented behavior automatically" "$(cat "$SCRIPT_DIR/README.md")"

printf '\n=== Results: %d/%d passed, %d failed ===\n' "$PASS" "$TOTAL" "$FAIL"
exit "$FAIL"
