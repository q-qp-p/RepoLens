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

# Hermetic contract tests for the Cursor IDE / Composer handoff. No model or
# Cursor binary is invoked.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS="$SCRIPT_DIR/repolens.sh"
TMPDIR="$(mktemp -d)"
RUN_IDS=()
PASS=0
FAIL=0
TOTAL=0

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
  FAIL=$((FAIL + 1))
  printf '  FAIL: %s\n' "$1"
  [[ -z "${2:-}" ]] || printf '    %s\n' "$2"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
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

assert_file_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "missing file: $path"
  fi
}

assert_file_missing() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -e "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "unexpected path: $path"
  fi
}

wait_for_request() {
  local root="$1" attempts="${2:-100}" request=""
  local i
  for ((i = 0; i < attempts; i++)); do
    request="$(find "$root" -type f -name request.json 2>/dev/null | sort | tail -1)"
    if [[ -n "$request" && -f "$request" ]]; then
      printf '%s\n' "$request"
      return 0
    fi
    sleep 0.05
  done
  return 1
}

write_response_body() {
  local request_file="$1" anchor="${2:-src/app.sh:1}"
  local response response_tmp
  response="$(jq -r '.files.response' "$request_file")"
  response_tmp="${response}.tmp"

  {
    printf '%s\n' "## Method"
    printf 'Inspected %s and traced the only command from its entry point through the local fixture.\n' "$anchor"
    printf '%s\n' "The request-specific review found no injection sink and did not rely on a previous response."
    printf '\n%s\n' "## Findings"
    printf '%s\n' "No fileable injection finding remains. The fixture uses a constant command and contains no user-controlled data."
    printf '%s\n' "This evidence is specific to the current prompt and project state."
    printf '\n%s\n' "DONE"
  } > "$response_tmp"
  mv "$response_tmp" "$response"
}

write_valid_response() {
  local request_file="$1" anchor="${2:-src/app.sh:1}"
  local response complete request_id complete_tmp response_hash
  response="$(jq -r '.files.response' "$request_file")"
  complete="$(jq -r '.files.complete' "$request_file")"
  request_id="$(jq -r '.request_id' "$request_file")"
  complete_tmp="${complete}.tmp"

  write_response_body "$request_file" "$anchor"
  response_hash="$(git hash-object --no-filters "$response")"
  jq -n \
    --arg request_id "$request_id" \
    --arg response_git_hash "$response_hash" \
    '{schema_version: 1, request_id: $request_id, status: "complete", response_git_hash: $response_git_hash}' \
    > "$complete_tmp"
  mv "$complete_tmp" "$complete"
}

record_run_id() {
  local output_file="$1" run_id
  run_id="$(sed -n 's/.*RepoLens run \([^ ]*\) starting.*/\1/p' "$output_file" | head -1)"
  printf '%s\n' "$run_id"
}

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/core.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/cursor_ide.sh"

printf '%s\n' "=== Cursor IDE validation and dependency contract ==="

out="$(validate_agent cursor-ide 2>&1)"
assert_eq "validate_agent accepts cursor-ide" "0" "$?"

empty_path="$TMPDIR/empty-bin"
mkdir -p "$empty_path"
out="$(PATH="$empty_path" require_agent_cmd cursor-ide 2>&1)"
assert_eq "cursor-ide requires no external CLI" "0" "$?"

out="$(REPOLENS_AGENT_TIMEOUT_CURSOR=19 resolve_agent_timeout audit cursor-ide)"
assert_eq "cursor-ide uses the Cursor timeout class" "19" "$out"

printf '\n%s\n' "=== Request binding, rejection, and acceptance ==="

project="$TMPDIR/project"
mkdir -p "$project/src"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" safe' > "$project/src/app.sh"
git -C "$project" init -q
git -C "$project" add src/app.sh
git -C "$project" \
  -c user.name='RepoLens Test' \
  -c user.email='repolens@example.invalid' \
  commit -q -m 'fixture'

handoff_root="$TMPDIR/direct-handoffs"
ctl_log="$TMPDIR/direct-events.ndjson"
direct_out="$TMPDIR/direct.out"
direct_err="$TMPDIR/direct.err"
(
  REPOLENS_CURSOR_IDE_PHASE=lens \
  REPOLENS_CURSOR_IDE_DOMAIN=security \
  REPOLENS_CURSOR_IDE_LENS=injection \
  REPOLENS_CURSOR_IDE_ITERATION=1 \
  REPOLENS_CURSOR_IDE_HANDOFF_DIR="$handoff_root" \
  REPOLENS_CURSOR_IDE_CTL_LOG="$ctl_log" \
  REPOLENS_CURSOR_IDE_POLL_SEC=1 \
  REPOLENS_CURSOR_IDE_MAX_WAIT_SEC=8 \
    run_agent cursor-ide "AUDIT THIS PROJECT" "$project" 8 1
) > "$direct_out" 2> "$direct_err" &
direct_pid=$!

request_file="$(wait_for_request "$handoff_root" 120)"
assert_file_exists "handoff publishes request.json" "$request_file"
prompt_file="$(jq -r '.files.prompt' "$request_file")"
response_file="$(jq -r '.files.response' "$request_file")"
complete_file="$(jq -r '.files.complete' "$request_file")"
request_id="$(jq -r '.request_id' "$request_file")"
assert_file_exists "handoff publishes the complete prompt" "$prompt_file"
assert_contains "prompt carries the original RepoLens prompt" "AUDIT THIS PROJECT" "$(cat "$prompt_file")"
assert_contains "prompt documents atomic completion" "response_git_hash" "$(cat "$prompt_file")"

# Publish a marker for another request. It must be rejected and removed.
write_response_body "$request_file"
response_hash="$(git hash-object --no-filters "$response_file")"
jq -n \
  --arg request_id "stale-request" \
  --arg response_git_hash "$response_hash" \
  '{schema_version: 1, request_id: $request_id, status: "complete", response_git_hash: $response_git_hash}' \
  > "$complete_file"
for _ in {1..60}; do
  [[ ! -e "$complete_file" ]] && break
  sleep 0.05
done
assert_file_missing "cross-request completion marker is rejected" "$complete_file"

# Publish a marker whose digest no longer matches. It must also be rejected.
response_hash="$(git hash-object --no-filters "$response_file")"
jq -n \
  --arg request_id "$request_id" \
  --arg response_git_hash "$response_hash" \
  '{schema_version: 1, request_id: $request_id, status: "complete", response_git_hash: $response_git_hash}' \
  > "$complete_file"
printf '%s\n' "mutated after completion" >> "$response_file"
for _ in {1..60}; do
  [[ ! -e "$complete_file" ]] && break
  sleep 0.05
done
assert_file_missing "post-completion response mutation is rejected" "$complete_file"

# A syntactically valid citation to a real file must not pass when the cited
# line is beyond EOF. The fixture has exactly two lines.
write_response_body "$request_file" "src/app.sh:3"
response_hash="$(git hash-object --no-filters "$response_file")"
jq -n \
  --arg request_id "$request_id" \
  --arg response_git_hash "$response_hash" \
  '{schema_version: 1, request_id: $request_id, status: "complete", response_git_hash: $response_git_hash}' \
  > "$complete_file"
for _ in {1..60}; do
  [[ ! -e "$complete_file" ]] && break
  sleep 0.05
done
assert_file_missing "out-of-bounds path:line citation is rejected" "$complete_file"
assert_contains "out-of-bounds rejection explains the line-bound requirement" \
  "in-bounds project path:line" \
  "$(jq -r 'select(.kind == "cursor_ide_response_rejected") | .reason' "$ctl_log" | tail -1)"

write_valid_response "$request_file"
wait "$direct_pid"
direct_rc=$?
assert_eq "valid bound response completes the handoff" "0" "$direct_rc"
assert_contains "accepted output reaches RepoLens" "No fileable injection finding remains" "$(cat "$direct_out")"
assert_eq "protocol records all rejected markers" "3" \
  "$(jq -s '[.[] | select(.kind == "cursor_ide_response_rejected")] | length' "$ctl_log")"
assert_eq "protocol records one accepted response" "1" \
  "$(jq -s '[.[] | select(.kind == "cursor_ide_response_accepted")] | length' "$ctl_log")"

printf '\n%s\n' "=== Timeout and public CLI policy ==="

timeout_root="$TMPDIR/timeout-handoffs"
timeout_out="$(
  REPOLENS_CURSOR_IDE_PHASE=lens \
  REPOLENS_CURSOR_IDE_HANDOFF_DIR="$timeout_root" \
  REPOLENS_CURSOR_IDE_POLL_SEC=1 \
  REPOLENS_CURSOR_IDE_MAX_WAIT_SEC=1 \
    run_agent cursor-ide "WAIT FOREVER" "$project" 5 1 2>&1
)"
timeout_rc=$?
assert_eq "unanswered Composer handoff returns timeout status" "124" "$timeout_rc"
assert_contains "timeout is explicit and machine-detectable" "REPOLENS_CURSOR_IDE_TIMEOUT" "$timeout_out"

nonlocal_out="$(bash "$REPOLENS" --project "$SCRIPT_DIR" --agent cursor-ide --focus injection --dry-run 2>&1)"
nonlocal_rc=$?
if (( nonlocal_rc != 0 )); then
  pass_with "cursor-ide rejects non-local runs"
  TOTAL=$((TOTAL + 1))
else
  fail_with "cursor-ide rejects non-local runs" "expected non-zero exit"
  TOTAL=$((TOTAL + 1))
fi
assert_contains "non-local error distinguishes the Cursor CLI backend" \
  "use --agent cursor for unattended Cursor CLI runs" "$nonlocal_out"

dry_out="$(bash "$REPOLENS" --project "$SCRIPT_DIR" --agent cursor-ide --local --parallel --focus injection --dry-run --yes 2>&1)"
dry_rc=$?
assert_eq "cursor-ide reaches dry-run without cursor-agent" "0" "$dry_rc"
assert_contains "parallel IDE request is downgraded explicitly" "forcing sequential execution" "$dry_out"
assert_contains "cursor-ide receives subscription costing" "Cursor Subscription" "$dry_out"
dry_run_id="$(record_run_id <(printf '%s\n' "$dry_out"))"
[[ -z "$dry_run_id" ]] || RUN_IDS+=("$dry_run_id")

help_out="$(bash "$REPOLENS" --help 2>&1)"
assert_contains "help distinguishes the cursor-ide backend" "cursor-ide" "$help_out"
assert_contains "help documents the IDE wait control" "REPOLENS_CURSOR_IDE_MAX_WAIT_SEC" "$help_out"
assert_contains "README links the full handoff guide" "docs/cursor-ide.md" "$(cat "$SCRIPT_DIR/README.md")"

printf '\n%s\n' "=== End-to-end CLI completion and resume ==="

fake_bin="$TMPDIR/fake-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/cursor-agent" <<'SHIM'
#!/usr/bin/env bash
touch "${CURSOR_AGENT_WAS_CALLED:?}"
exit 99
SHIM
chmod +x "$fake_bin/cursor-agent"
export CURSOR_AGENT_WAS_CALLED="$TMPDIR/cursor-agent-called"

e2e_root="$TMPDIR/e2e-handoffs"
e2e_out="$TMPDIR/e2e.out"
(
  request="$(wait_for_request "$e2e_root" 400)" || exit 1
  write_valid_response "$request"
) &
responder_pid=$!

PATH="$fake_bin:$PATH" \
REPOLENS_CURSOR_IDE_HANDOFF_DIR="$e2e_root" \
REPOLENS_CURSOR_IDE_MAX_WAIT_SEC=10 \
  bash "$REPOLENS" \
    --project "$project" \
    --agent cursor-ide \
    --local \
    --focus injection \
    --depth 1 \
    --yes > "$e2e_out" 2>&1
e2e_rc=$?
wait "$responder_pid"
responder_rc=$?
assert_eq "hermetic cursor-ide CLI run completes" "0" "$e2e_rc"
assert_eq "hermetic Composer responder completes" "0" "$responder_rc"
assert_file_missing "cursor-ide never invokes cursor-agent" "$CURSOR_AGENT_WAS_CALLED"

e2e_run_id="$(record_run_id "$e2e_out")"
[[ -z "$e2e_run_id" ]] || RUN_IDS+=("$e2e_run_id")
assert_file_exists "end-to-end run writes summary state" "$SCRIPT_DIR/logs/$e2e_run_id/summary.json"
assert_eq "accepted lens is marked completed" "security/injection" \
  "$(tail -1 "$SCRIPT_DIR/logs/$e2e_run_id/.completed")"
assert_eq "control stream terminates with run_complete" "run_complete" \
  "$(jq -r 'select(.kind != null) | .kind' "$SCRIPT_DIR/logs/$e2e_run_id/cursor-ide/events.ndjson" | tail -1)"

# First attempt times out, then the same parent run resumes and finishes.
resume_root_1="$TMPDIR/resume-handoffs-1"
resume_out_1="$TMPDIR/resume-1.out"
PATH="$fake_bin:$PATH" \
REPOLENS_CURSOR_IDE_HANDOFF_DIR="$resume_root_1" \
REPOLENS_CURSOR_IDE_MAX_WAIT_SEC=1 \
  bash "$REPOLENS" \
    --project "$project" \
    --agent cursor-ide \
    --local \
    --focus injection \
    --depth 1 \
    --yes > "$resume_out_1" 2>&1
resume_rc_1=$?
if (( resume_rc_1 != 0 )); then
  pass_with "timed-out CLI attempt exits non-zero"
  TOTAL=$((TOTAL + 1))
else
  fail_with "timed-out CLI attempt exits non-zero" "expected non-zero exit"
  TOTAL=$((TOTAL + 1))
fi
resume_run_id="$(record_run_id "$resume_out_1")"
[[ -z "$resume_run_id" ]] || RUN_IDS+=("$resume_run_id")
assert_eq "timeout is recorded as resumable no-progress" "agent-no-progress" \
  "$(jq -r '.lenses[-1].status' "$SCRIPT_DIR/logs/$resume_run_id/summary.json")"
if grep -qxF security/injection "$SCRIPT_DIR/logs/$resume_run_id/.completed" 2>/dev/null; then
  fail_with "timed-out lens remains incomplete"
  TOTAL=$((TOTAL + 1))
else
  pass_with "timed-out lens remains incomplete"
  TOTAL=$((TOTAL + 1))
fi

resume_root_2="$TMPDIR/resume-handoffs-2"
resume_out_2="$TMPDIR/resume-2.out"
(
  request="$(wait_for_request "$resume_root_2" 400)" || exit 1
  write_valid_response "$request"
) &
resume_responder_pid=$!
PATH="$fake_bin:$PATH" \
REPOLENS_CURSOR_IDE_HANDOFF_DIR="$resume_root_2" \
REPOLENS_CURSOR_IDE_MAX_WAIT_SEC=10 \
  bash "$REPOLENS" \
    --project "$project" \
    --agent cursor-ide \
    --local \
    --focus injection \
    --depth 1 \
    --resume "$resume_run_id" \
    --yes > "$resume_out_2" 2>&1
resume_rc_2=$?
wait "$resume_responder_pid"
assert_eq "resume completes the previously timed-out parent run" "0" "$resume_rc_2"
assert_eq "resumed lens enters completed state" "security/injection" \
  "$(tail -1 "$SCRIPT_DIR/logs/$resume_run_id/.completed")"
assert_eq "resume appends a second parent-run attempt" "2" \
  "$(jq 'length' "$SCRIPT_DIR/logs/$resume_run_id/attempts.json")"

printf '\n=== Results: %d/%d passed, %d failed ===\n' "$PASS" "$TOTAL" "$FAIL"
exit "$FAIL"
