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

# Regression tests for issue #222: a run directory is a single-writer state
# container. A second same-run --resume must fail fast, while crash recovery,
# different run IDs, and read-only status rendering continue to work.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
# shellcheck source=tests/status_test_lib.sh
source "$SCRIPT_DIR/tests/status_test_lib.sh"

RUN_PIDS=()
STARTED_PID=""

# --resume requires an existing, real (non-symlink) logs/<run-id> directory
# before it will open any artifact below it. Every scenario here resumes a
# freshly minted run id, so the directory has to be created up front — without
# it repolens.sh dies during argument handling and never reaches the lock
# semantics these tests are about.
register_run_dir() {
  local id="$1"
  status_register_run_id "$id"
  mkdir -p "$STATUS_TEST_ROOT/logs/$id"
}

# shellcheck disable=SC2329  # Invoked indirectly by the EXIT trap.
cleanup() {
  local pid
  for pid in "${RUN_PIDS[@]:-}"; do
    terminate_run_group "$pid"
  done
  status_cleanup
}
trap cleanup EXIT

assert_nonzero() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then
    record_pass "$desc"
  else
    record_fail "$desc" "expected non-zero exit status"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    record_fail "$desc" "unexpected needle='$needle'"
  else
    record_pass "$desc"
  fi
}

assert_eventually_file() {
  local desc="$1" file="$2" attempts="${3:-80}" detail="${4:-}"
  local i
  TOTAL=$((TOTAL + 1))
  for ((i = 0; i < attempts; i++)); do
    if [[ -f "$file" ]]; then
      record_pass "$desc"
      return 0
    fi
    sleep 0.1
  done
  record_fail "$desc" "$detail"
  return 1
}

kill_run_group_now() {
  local pid="$1"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}

run_repolens_foreground() {
  local run_id="$1" out_file="$2" mode="${3:-quick}" ready_file="${4:-}" fd_report="${5:-}"
  env \
    PATH="$FAKE_BIN:$PATH" \
    REPOLENS_TEST_CODEX_MODE="$mode" \
    REPOLENS_TEST_READY="$ready_file" \
    REPOLENS_TEST_FD_REPORT="$fd_report" \
    REPOLENS_TEST_SLEEP=20 \
    REPOLENS_STATUS_INTERVAL=1 \
    REPOLENS_LENS_HEARTBEAT_INTERVAL=1 \
    REPOLENS_AGENT_TIMEOUT=30 \
    bash "$STATUS_TEST_ROOT/repolens.sh" \
      --project "$PROJECT" \
      --agent codex \
      --resume "$run_id" \
      --focus i18n-strings \
      --change "run-dir lock test" \
      --local \
      --yes \
      >"$out_file" 2>&1
}

start_repolens_background() {
  local run_id="$1" out_file="$2" ready_file="$3" fd_report="${4:-}"
  setsid env \
    PATH="$FAKE_BIN:$PATH" \
    REPOLENS_TEST_CODEX_MODE=sleep \
    REPOLENS_TEST_READY="$ready_file" \
    REPOLENS_TEST_FD_REPORT="$fd_report" \
    REPOLENS_TEST_SLEEP=20 \
    REPOLENS_STATUS_INTERVAL=1 \
    REPOLENS_LENS_HEARTBEAT_INTERVAL=1 \
    REPOLENS_AGENT_TIMEOUT=30 \
    bash "$STATUS_TEST_ROOT/repolens.sh" \
      --project "$PROJECT" \
      --agent codex \
      --resume "$run_id" \
      --focus i18n-strings \
      --change "run-dir lock test" \
      --local \
      --yes \
      >"$out_file" 2>&1 &
  STARTED_PID=$!
  RUN_PIDS+=("$STARTED_PID")
}

echo "=== run directory lock semantics (issue #222) ==="
status_require_jq

PROJECT="$STATUS_TEST_TMPDIR/project"
FAKE_BIN="$STATUS_TEST_TMPDIR/bin"
mkdir -p "$FAKE_BIN"
status_setup_project "$PROJECT"

cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
ready="${REPOLENS_TEST_READY:-}"
fd_report="${REPOLENS_TEST_FD_REPORT:-}"
if [[ -n "$fd_report" ]]; then
  lock_fd="none"
  if [[ -d "/proc/$$/fd" ]]; then
    for fd_path in /proc/$$/fd/*; do
      target="$(readlink "$fd_path" 2>/dev/null || true)"
      if [[ "$target" == */.repolens.flock ]]; then
        lock_fd="${fd_path##*/}:$target"
        break
      fi
    done
  fi
  printf 'env=%s lock_fd=%s\n' "${REPOLENS_RUN_LOCK_FD:-unset}" "$lock_fd" > "$fd_report"
fi
if [[ "${REPOLENS_TEST_CODEX_MODE:-quick}" == "sleep" ]]; then
  [[ -n "$ready" ]] && printf 'ready\n' > "$ready"
  sleep "${REPOLENS_TEST_SLEEP:-20}"
else
  [[ -n "$ready" ]] && printf 'ready\n' > "$ready"
fi

echo "Analysis complete. No findings."
echo "DONE"
exit 0
SH
chmod +x "$FAKE_BIN/codex"

# ---------------------------------------------------------------------------
# 1. A second process resuming the same run must fail fast and clearly while
#    the first process is still inside the public agent execution path.
# ---------------------------------------------------------------------------
RUN_ID="test-run-dir-lock-same-$$-$RANDOM"
register_run_dir "$RUN_ID"
FIRST_READY="$STATUS_TEST_TMPDIR/first.ready"
FIRST_OUT="$STATUS_TEST_TMPDIR/first.out"
SECOND_OUT="$STATUS_TEST_TMPDIR/second.out"

start_repolens_background "$RUN_ID" "$FIRST_OUT" "$FIRST_READY"
FIRST_PID="$STARTED_PID"
assert_eventually_file "First same-run resume reaches the fake agent" \
  "$FIRST_READY" 80 "$(cat "$FIRST_OUT" 2>/dev/null || true)"

set +e
run_repolens_foreground "$RUN_ID" "$SECOND_OUT" quick
second_rc=$?
set +e
second_output="$(cat "$SECOND_OUT" 2>/dev/null || true)"

assert_nonzero "Concurrent same-run resume exits non-zero" "$second_rc"
assert_contains "Concurrent same-run resume reports the owning run" \
  "already owns run $RUN_ID" "$second_output"
kill_run_group_now "$FIRST_PID"

# ---------------------------------------------------------------------------
# 2. A SIGKILLed owner must not leave a stale manual lock behind. The next
#    resume of the same run should acquire ownership and proceed normally.
# ---------------------------------------------------------------------------
RUN_ID="test-run-dir-lock-crash-$$-$RANDOM"
register_run_dir "$RUN_ID"
CRASH_READY="$STATUS_TEST_TMPDIR/crash.ready"
CRASH_OUT="$STATUS_TEST_TMPDIR/crash.out"
RECLAIM_OUT="$STATUS_TEST_TMPDIR/reclaim.out"

start_repolens_background "$RUN_ID" "$CRASH_OUT" "$CRASH_READY"
CRASH_PID="$STARTED_PID"
assert_eventually_file "Crash-reclaim owner reaches the fake agent" \
  "$CRASH_READY" 80 "$(cat "$CRASH_OUT" 2>/dev/null || true)"
kill_run_group_now "$CRASH_PID"

set +e
run_repolens_foreground "$RUN_ID" "$RECLAIM_OUT" quick
reclaim_rc=$?
set +e
reclaim_output="$(cat "$RECLAIM_OUT" 2>/dev/null || true)"

assert_eq "Resume after SIGKILL can reclaim the run" "0" "$reclaim_rc"
assert_not_contains "Resume after SIGKILL does not report an owned run" \
  "already owns run $RUN_ID" "$reclaim_output"

# ---------------------------------------------------------------------------
# 3. External agent commands must not inherit the run-lock FD. Otherwise a
#    surviving agent child could keep a killed orchestrator's lock alive.
# ---------------------------------------------------------------------------
RUN_ID="test-run-dir-lock-agent-fd-$$-$RANDOM"
register_run_dir "$RUN_ID"
AGENT_FD_OUT="$STATUS_TEST_TMPDIR/agent-fd.out"
AGENT_FD_REPORT="$STATUS_TEST_TMPDIR/agent-fd.report"

set +e
run_repolens_foreground "$RUN_ID" "$AGENT_FD_OUT" quick "" "$AGENT_FD_REPORT"
agent_fd_rc=$?
set +e
agent_fd_report="$(cat "$AGENT_FD_REPORT" 2>/dev/null || true)"

assert_eq "Agent FD cleanup run exits successfully" "0" "$agent_fd_rc"
assert_contains "Agent subprocess does not inherit the run-lock FD" \
  "env=unset lock_fd=none" "$agent_fd_report"

# ---------------------------------------------------------------------------
# 4. The ownership boundary is per run ID, not global.
# ---------------------------------------------------------------------------
RUN_ID_A="test-run-dir-lock-a-$$-$RANDOM"
RUN_ID_B="test-run-dir-lock-b-$$-$RANDOM"
register_run_dir "$RUN_ID_A"
register_run_dir "$RUN_ID_B"
READY_A="$STATUS_TEST_TMPDIR/a.ready"
READY_B="$STATUS_TEST_TMPDIR/b.ready"
OUT_A="$STATUS_TEST_TMPDIR/a.out"
OUT_B="$STATUS_TEST_TMPDIR/b.out"

start_repolens_background "$RUN_ID_A" "$OUT_A" "$READY_A"
PID_A="$STARTED_PID"
start_repolens_background "$RUN_ID_B" "$OUT_B" "$READY_B"
PID_B="$STARTED_PID"

TOTAL=$((TOTAL + 1))
if assert_eventually_file "Different run ID A reaches the fake agent" "$READY_A" 80 \
    "$(cat "$OUT_A" 2>/dev/null || true)" \
    && assert_eventually_file "Different run ID B reaches the fake agent" "$READY_B" 80 \
      "$(cat "$OUT_B" 2>/dev/null || true)"; then
  record_pass "Different run IDs can execute concurrently"
else
  record_fail "Different run IDs can execute concurrently" \
    "run A: $(cat "$OUT_A" 2>/dev/null || true) run B: $(cat "$OUT_B" 2>/dev/null || true)"
fi
kill_run_group_now "$PID_A"
kill_run_group_now "$PID_B"

# ---------------------------------------------------------------------------
# 5. Read-only status rendering must remain available while an audit process
#    owns the run directory.
# ---------------------------------------------------------------------------
RUN_ID="test-run-dir-lock-status-$$-$RANDOM"
RUN_DIR="$STATUS_TEST_ROOT/logs/$RUN_ID"
STATUS_READY="$STATUS_TEST_TMPDIR/status.ready"
STATUS_RUN_OUT="$STATUS_TEST_TMPDIR/status-run.out"
STATUS_OUT="$STATUS_TEST_TMPDIR/status.out"
STATUS_ERR="$STATUS_TEST_TMPDIR/status.err"
mkdir -p "$RUN_DIR"
register_run_dir "$RUN_ID"
jq --arg run "$RUN_ID" '.run_id = $run' \
  "$STATUS_TEST_ROOT/tests/fixtures/status_active.json" > "$RUN_DIR/status.json"

start_repolens_background "$RUN_ID" "$STATUS_RUN_OUT" "$STATUS_READY"
STATUS_PID="$STARTED_PID"
assert_eventually_file "Status guard owner reaches the fake agent" \
  "$STATUS_READY" 80 "$(cat "$STATUS_RUN_OUT" 2>/dev/null || true)"

bash "$STATUS_TEST_ROOT/repolens.sh" status "$RUN_ID" --no-color >"$STATUS_OUT" 2>"$STATUS_ERR"
status_rc=$?
status_output="$(cat "$STATUS_OUT" 2>/dev/null || true)$(cat "$STATUS_ERR" 2>/dev/null || true)"

assert_eq "Status command can read a locked run" "0" "$status_rc"
assert_contains "Status command renders the locked run id" "RepoLens run $RUN_ID" "$status_output"
assert_not_contains "Status command does not report lock ownership" "already owns run $RUN_ID" "$status_output"
kill_run_group_now "$STATUS_PID"

status_finish
