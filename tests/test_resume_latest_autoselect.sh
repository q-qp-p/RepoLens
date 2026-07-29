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

# Behavioral tests for issue #373: `--resume` with no following id auto-selects
# the newest *resumable* run under logs/ and resumes it (the dir is reused).
#
# These tests assert the OBSERVABLE contract from the issue's acceptance
# criteria — they do NOT couple to the internal selector helper name or call
# sites:
#   AC1  `--resume` (no id) auto-selects the newest incomplete run; the chosen
#        run id is logged ("Auto-resuming latest interrupted run: <id>") and the
#        run reuses that dir (no fresh timestamped dir is created).
#   AC2  with two incomplete runs, the newer (by dir mtime) is chosen.
#   AC3  completed / clean runs are NOT auto-selected.
#   AC4  no incomplete run present -> clear `die`, non-zero exit, no new dir.
#   AC5  explicit `--resume <id>` is unchanged (does not divert to auto-select).
#   AC6  the `--resume --dry-run` token ordering honors --dry-run instead of
#        swallowing it as the run id (the latent parse footgun the research
#        flagged).
#   AC7  the full test suite stays green (covered by the suite as a whole).
#
# Reuses the symlink-farm pattern from tests/clean_test_lib.sh: repolens.sh
# derives SCRIPT_DIR (and thus logs/) from its own location, so a farm that
# symlinks repolens.sh / lib / config / prompts but owns its own logs/ gives a
# fully isolated logs tree. `make_run <name> <state> [stopped] [age_days]`
# builds genuine run dirs and stamps the *dir* mtime last — exactly the basis
# the auto-selector keys off.
#
# NO real model is ever invoked: a fake `codex` that only prints DONE is the
# sole "agent". Every selection assertion is driven through `--dry-run`, which
# exits right after run-id resolution (the point where auto-select happens), so
# the tests are fast and never execute lens work.

set -uo pipefail

# shellcheck disable=SC1091
# shellcheck source=tests/clean_test_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/clean_test_lib.sh"

# Shared, read-only project + fake agent live OUTSIDE the per-scenario farm so
# they survive clean_cleanup between scenarios.
SHARED_DIR="$(mktemp -d)"
SHARED_PROJECT="$SHARED_DIR/project"
SHARED_BIN="$SHARED_DIR/bin"

# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup_all() {
  clean_cleanup
  [[ -n "${SHARED_DIR:-}" && -d "$SHARED_DIR" ]] && rm -rf "$SHARED_DIR"
}
trap cleanup_all EXIT

mkdir -p "$SHARED_PROJECT" "$SHARED_BIN"
git -C "$SHARED_PROJECT" init -q 2>/dev/null || true
printf '# resume-autoselect fixture\n' > "$SHARED_PROJECT/README.md"
# A DONE-only fake agent: in the green phase no agent runs (every selection case
# is --dry-run); it only matters for the AC6 footgun red-phase, where the
# pre-fix code would mis-parse `--resume --dry-run` into a real run — DONE keeps
# that bounded and instant.
cat > "$SHARED_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'DONE\n'
EOF
chmod +x "$SHARED_BIN/codex"

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc" "unexpected needle='$needle' found"
  fi
}

assert_nonzero() {
  local desc="$1" rc="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$rc" -ne 0 ]]; then
    record_pass "$desc"
  else
    record_fail "$desc" "rc=$rc (expected non-zero)"
  fi
}

# Count genuine top-level run dirs in the isolated logs tree, excluding any
# `latest` symlink. Used to prove auto-select reuses an existing dir and that a
# no-candidate die leaks no new dir.
count_run_dirs() {
  local d n=0
  shopt -s nullglob
  for d in "$CLEAN_TEST_LOGS"/*; do
    [[ -d "$d" && ! -L "$d" ]] && n=$((n + 1))
  done
  shopt -u nullglob
  printf '%s' "$n"
}

# The "RepoLens run <id> starting" banner (log_info -> stdout) reveals which run
# id the invocation actually used — the resumed dir, never a fresh one.
parse_banner_run_id() {
  printf '%s\n' "$RESUME_OUT" \
    | grep -oE 'RepoLens run [^ ]+ starting' | head -1 | awk '{print $3}'
}

# resume_run <extra repolens args...> — invoke the real repolens.sh against the
# isolated farm with a git project + fake codex. stdout/stderr captured
# separately (the auto-resume line goes to stdout via log_info; the no-candidate
# die goes to stderr). Wrapped in timeout so a regression can never wedge the
# suite. stdin is /dev/null so nothing ever blocks on a prompt.
RESUME_OUT=""
RESUME_ERR=""
RESUME_RC=0
resume_run() {
  local out err
  out="$(mktemp)"
  err="$(mktemp)"
  timeout 120 env PATH="$SHARED_BIN:$PATH" \
    REPOLENS_AGENT_TIMEOUT=10 \
    bash "$CLEAN_TEST_FARM/repolens.sh" \
      --project "$SHARED_PROJECT" \
      --agent codex \
      --focus i18n-strings \
      --mode audit \
      --local \
      --yes \
      "$@" </dev/null >"$out" 2>"$err"
  RESUME_RC=$?
  RESUME_OUT="$(cat "$out")"
  RESUME_ERR="$(cat "$err")"
  rm -f "$out" "$err"
}

# ---------------------------------------------------------------------------
# Scenario 1 (AC1 + AC3): completeness beats recency.
#
# The NEWEST run by mtime is a clean `finished` run; an OLDER run is incomplete
# (rate-limit abort sentinel — the reported pain). `--resume` (no id) must skip
# the newer clean run and resume the older incomplete one, log the selection,
# and reuse that dir (no new top-level run dir appears).
# ---------------------------------------------------------------------------
echo "=== Scenario 1: auto-resume picks the incomplete run over a newer clean run ==="

clean_setup_farm
make_run "20260601T120000Z-newerdone" "finished" "" 1 >/dev/null
older_dir="$(make_run "20260601T100000Z-olderintr" "finished" "" 5)"
: > "$older_dir/.rate-limit-abort"
# Writing the sentinel bumps the dir mtime to "now"; re-stamp it old so the
# clean NEWER run remains the most-recent dir (mtime stamped LAST — see make_run).
touch -d "@$(epoch_days_ago 5)" "$older_dir"

dirs_before="$(count_run_dirs)"
resume_run --dry-run --resume
dirs_after="$(count_run_dirs)"

assert_contains "auto-resume selects the incomplete run" \
  "Auto-resuming latest interrupted run: 20260601T100000Z-olderintr" "$RESUME_OUT"
assert_not_contains "the newer clean run is NOT auto-selected" \
  "20260601T120000Z-newerdone" "$RESUME_OUT"
assert_eq "auto-resume dry-run exits 0" "0" "$RESUME_RC"
assert_eq "banner run id is the auto-selected incomplete dir (dir reused)" \
  "20260601T100000Z-olderintr" "$(parse_banner_run_id)"
assert_eq "no fresh run dir created (incomplete dir reused)" "$dirs_before" "$dirs_after"

# ---------------------------------------------------------------------------
# Scenario 2 (AC2): with two incomplete runs, the newer (by dir mtime) wins.
# ---------------------------------------------------------------------------
echo ""
echo "=== Scenario 2: newer of two incomplete runs is auto-selected ==="

clean_cleanup
clean_setup_farm
make_run "20260601T100000Z-incolder0" "interrupted" "" 5 >/dev/null
make_run "20260601T140000Z-incnewer0" "interrupted" "" 2 >/dev/null

resume_run --dry-run --resume

assert_contains "the newer incomplete run is auto-selected" \
  "Auto-resuming latest interrupted run: 20260601T140000Z-incnewer0" "$RESUME_OUT"
assert_not_contains "the older incomplete run is NOT auto-selected" \
  "20260601T100000Z-incolder0" "$RESUME_OUT"
assert_eq "two-incompletes dry-run exits 0" "0" "$RESUME_RC"

# ---------------------------------------------------------------------------
# Scenario 3 (AC3 + AC4): only a completed run present -> no auto-select, a
# clear die on stderr, non-zero exit, and no new run dir leaked.
#
# A clean `finished` run is the only candidate. It must NOT be auto-selected,
# so `--resume` (no id) must die before any dir is created.
# ---------------------------------------------------------------------------
echo ""
echo "=== Scenario 3: no incomplete run -> clean die, non-zero exit, no dir leak ==="

clean_cleanup
clean_setup_farm
make_run "20260601T100000Z-onlyfinis" "finished" "" 3 >/dev/null

dirs_before="$(count_run_dirs)"
resume_run --dry-run --resume
dirs_after="$(count_run_dirs)"

assert_not_contains "completed-only logs trigger no auto-resume line" \
  "Auto-resuming latest interrupted run:" "$RESUME_OUT"
assert_contains "no-candidate resume dies with a clear message on stderr" \
  "No interrupted run found to resume" "$RESUME_ERR"
assert_nonzero "no-candidate resume exits non-zero" "$RESUME_RC"
assert_eq "no new run dir created on the no-candidate die" "$dirs_before" "$dirs_after"

# ---------------------------------------------------------------------------
# Scenario 4 (AC5): explicit `--resume <id>` is unchanged — it resumes exactly
# that id and does NOT divert to auto-select, even when a NEWER incomplete run
# (a decoy @latest would pick) exists.
# ---------------------------------------------------------------------------
echo ""
echo "=== Scenario 4: explicit --resume <id> resumes that exact id (no divert) ==="

clean_cleanup
clean_setup_farm
make_run "20260601T100000Z-explicit0" "finished" "" 3 >/dev/null
make_run "20260601T140000Z-decoyinc0" "interrupted" "" 1 >/dev/null

resume_run --dry-run --resume "20260601T100000Z-explicit0"

assert_not_contains "explicit --resume <id> does not log an auto-resume line" \
  "Auto-resuming latest interrupted run:" "$RESUME_OUT"
assert_eq "explicit --resume <id> resumes exactly that id (not the newer decoy)" \
  "20260601T100000Z-explicit0" "$(parse_banner_run_id)"
assert_eq "explicit resume dry-run exits 0" "0" "$RESUME_RC"

# ---------------------------------------------------------------------------
# Scenario 5 (AC6): `--resume --dry-run` token ordering honors --dry-run.
#
# The pre-fix parser required an argument after --resume and would swallow the
# following `--dry-run` as the run id, silently turning a dry run into a real
# run. The fix must instead treat a `--`-prefixed next token as "no id" and
# auto-select. Observable: a real dry-run preview ("Dry run complete") AND the
# auto-resume line both appear.
# ---------------------------------------------------------------------------
echo ""
echo "=== Scenario 5: --resume --dry-run is honored as a dry run, not swallowed ==="

clean_cleanup
clean_setup_farm
make_run "20260601T140000Z-footinc00" "interrupted" "" 1 >/dev/null

resume_run --resume --dry-run

assert_contains "--resume --dry-run still produces a dry-run preview" \
  "Dry run complete" "$RESUME_OUT"
assert_contains "--resume --dry-run auto-selects the incomplete run" \
  "Auto-resuming latest interrupted run: 20260601T140000Z-footinc00" "$RESUME_OUT"
assert_eq "footgun-order resume dry-run exits 0" "0" "$RESUME_RC"

# ---------------------------------------------------------------------------
# Scenario 6 (selector guard — `.superseded`): a deliberately retired run is
# NEVER auto-picked, even when it is the NEWEST incomplete run. The selector
# must skip it (matching status_latest_file, which also refuses superseded
# dirs) and fall through to the older, non-superseded incomplete run. No other
# assertion exercises the `_clean_is_superseded` branch of the selector, so a
# regression dropping it would pass all the cases above while resurrecting a
# retired run.
# ---------------------------------------------------------------------------
echo ""
echo "=== Scenario 6: a superseded incomplete run is skipped for an older one ==="

clean_cleanup
clean_setup_farm
make_run "20260601T100000Z-keepme000" "interrupted" "" 5 >/dev/null
sup_dir="$(make_run "20260601T140000Z-supersed00" "interrupted" "" 1)"
# Retire the NEWER incomplete run. Writing the marker bumps the dir mtime to
# "now"; re-stamp it old so the superseded run stays the most-recent dir —
# proving the skip is driven by the `.superseded` marker, not by recency.
: > "$sup_dir/.superseded"
touch -d "@$(epoch_days_ago 1)" "$sup_dir"

resume_run --dry-run --resume

assert_contains "the older non-superseded incomplete run is auto-selected" \
  "Auto-resuming latest interrupted run: 20260601T100000Z-keepme000" "$RESUME_OUT"
assert_not_contains "the newer superseded run is NOT auto-selected" \
  "Auto-resuming latest interrupted run: 20260601T140000Z-supersed00" "$RESUME_OUT"
assert_eq "superseded-skip dry-run exits 0" "0" "$RESUME_RC"

# ---------------------------------------------------------------------------
# Scenario 7 (selector guard — `_clean_is_run_dir`): AutoDev state dirs and
# partials are excluded even when they carry an incomplete signal and are the
# NEWEST dirs present. Two decoys exercise the two halves of the run-dir gate:
#   - `issues` — an AutoDev-shaped name (not run-id-shaped) with a `running`
#     status.json (a real incomplete signal); rejected on the name regex.
#   - a run-id-shaped *partial* with only an abort sentinel and no
#     status/summary.json (the newest dir of all); rejected because neither
#     file exists.
# Auto-select must skip both and resume the genuine, older incomplete run. No
# other assertion exercises the `_clean_is_run_dir` pairing in the selector, so
# dropping it would let a stray AutoDev dir become the resumed run id.
# ---------------------------------------------------------------------------
echo ""
echo "=== Scenario 7: AutoDev/partial dirs are excluded; the genuine run wins ==="

clean_cleanup
clean_setup_farm
make_run "20260601T100000Z-genuine000" "interrupted" "" 5 >/dev/null
# AutoDev state dir mirror: non-run-id name + an incomplete status.json, newer
# than the genuine run — would win if the name-regex gate were dropped.
make_run "issues" "running" "" 1 >/dev/null
# A run-id-shaped partial: only an abort sentinel, no status/summary — the
# newest dir of all, so it would win if the file-presence gate were dropped.
partial_dir="$CLEAN_TEST_LOGS/20260601T160000Z-partial000"
mkdir -p "$partial_dir"
: > "$partial_dir/.rate-limit-abort"
touch -d "@$(epoch_days_ago 0)" "$partial_dir"

resume_run --dry-run --resume

assert_contains "the genuine incomplete run is auto-selected" \
  "Auto-resuming latest interrupted run: 20260601T100000Z-genuine000" "$RESUME_OUT"
assert_not_contains "the AutoDev-shaped 'issues' dir is NOT auto-selected" \
  "Auto-resuming latest interrupted run: issues" "$RESUME_OUT"
assert_not_contains "the run-id-shaped partial is NOT auto-selected" \
  "Auto-resuming latest interrupted run: 20260601T160000Z-partial000" "$RESUME_OUT"
assert_eq "genuine run id is used (banner reflects the reused dir)" \
  "20260601T100000Z-genuine000" "$(parse_banner_run_id)"
assert_eq "exclude-decoys dry-run exits 0" "0" "$RESUME_RC"

# ---------------------------------------------------------------------------
# Scenario 8 (parent-path trust): a run-id-shaped symlink must be skipped before
# selector predicates inspect status.json or summary.json beneath it. Otherwise
# auto-selection can read attacker-chosen files outside logs/ and select an id
# that only the later explicit-resume gate rejects.
# ---------------------------------------------------------------------------
echo ""
echo "=== Scenario 8: auto-resume skips symlinked run-directory escapes ==="

clean_cleanup
clean_setup_farm
make_run "20260601T100000Z-realrun000" "interrupted" "" 5 >/dev/null
escaped_dir="$CLEAN_TEST_FARM/outside-run"
mkdir -p "$escaped_dir"
printf '%s\n' '{"state":"interrupted"}' > "$escaped_dir/status.json"
printf '%s\n' '{"stopped_reason":"interrupted"}' > "$escaped_dir/summary.json"
touch -d "@$(epoch_days_ago 0)" "$escaped_dir"
ln -s "$escaped_dir" "$CLEAN_TEST_LOGS/20260601T170000Z-symlink000"

resume_run --dry-run --resume

assert_contains "auto-resume selects the genuine contained run" \
  "Auto-resuming latest interrupted run: 20260601T100000Z-realrun000" "$RESUME_OUT"
assert_not_contains "auto-resume never selects the symlink escape" \
  "Auto-resuming latest interrupted run: 20260601T170000Z-symlink000" "$RESUME_OUT"
assert_eq "symlink-parent decoy does not break auto-resume" "0" "$RESUME_RC"

clean_finish
