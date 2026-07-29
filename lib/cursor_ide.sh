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

# RepoLens — Cursor IDE / Composer filesystem handoff
#
# Cursor IDE does not expose a supported unattended Composer API. This backend
# therefore keeps RepoLens as the state machine and uses a request-scoped,
# filesystem protocol:
#
#   request.json + prompt.md -> response.md + complete.json
#
# complete.json binds the response to a random request id and its Git object
# hash. A stale marker, a partial write, or a response for another prompt can
# never advance the lens. The handoff is intentionally sequential and local-only
# (enforced by repolens.sh).

set -uo pipefail

cursor_ide_uint() {
  local value="${1:-0}"
  [[ "$value" =~ ^[0-9]+$ ]] || value=0
  printf '%s\n' "$((10#$value))"
}

cursor_ide_safe_component() {
  local value="${1:-agent}"
  value="${value//[^A-Za-z0-9._-]/-}"
  value="${value#-}"
  value="${value%-}"
  [[ -n "$value" ]] || value="agent"
  printf '%s\n' "$value"
}

cursor_ide_new_request_id() {
  local random_hex
  random_hex="$(od -An -tx1 -N8 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [[ -n "$random_hex" ]] || random_hex="${RANDOM}${RANDOM}"
  printf '%s-%s-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$BASHPID" "$random_hex"
}

# Write one JSON event to the durable NDJSON log and to the original terminal
# stderr preserved by repolens.sh. When this library is sourced independently,
# stderr is the fallback control channel.
cursor_ide_emit() {
  local json="$1"
  local control_fd="${REPOLENS_CURSOR_IDE_CONTROL_FD:-}"
  local ctl_log="${REPOLENS_CURSOR_IDE_CTL_LOG:-}"

  if [[ -n "$ctl_log" ]]; then
    mkdir -p "$(dirname "$ctl_log")" 2>/dev/null || true
    printf '%s\n' "$json" >> "$ctl_log" 2>/dev/null || true
  fi

  if [[ "$control_fd" =~ ^[0-9]+$ ]] && { true >&"$control_fd"; } 2>/dev/null; then
    printf 'REPOLENS_CTL %s\n' "$json" >&"$control_fd"
  else
    printf 'REPOLENS_CTL %s\n' "$json" >&2
  fi
}

cursor_ide_response_git_hash() {
  git hash-object --no-filters "$1" 2>/dev/null
}

cursor_ide_extract_path_line_anchors() {
  local response_file="$1"
  [[ -f "$response_file" ]] || return 0
  grep -oE '[A-Za-z0-9_.+@/-]+\.[A-Za-z0-9]+:[0-9]+' "$response_file" 2>/dev/null \
    | sed 's#^\./##' \
    | sort -u
}

cursor_ide_count_verified_anchors() {
  local response_file="$1" project_path="$2"
  local anchor relative cited_line count=0

  while IFS= read -r anchor; do
    [[ -n "$anchor" ]] || continue
    relative="${anchor%:*}"
    cited_line="${anchor##*:}"
    [[ "$relative" != /* && "$relative" != *"../"* && "$relative" != ".." ]] || continue
    if [[ -f "$project_path/$relative" ]] \
      && awk -v cited_line="$cited_line" '
        END {
          valid = cited_line ~ /^[0-9]+$/ && (cited_line + 0) >= 1 && (cited_line + 0) <= NR
          exit !valid
        }
      ' "$project_path/$relative"; then
      count=$((count + 1))
    fi
  done < <(cursor_ide_extract_path_line_anchors "$response_file")

  printf '%s\n' "$count"
}

# cursor_ide_validate_response <response> <complete> <request-id> <project> <phase>
#
# Prints a rejection reason and returns non-zero. The caller removes only the
# completion marker, allowing Composer to correct the same response in place.
cursor_ide_validate_response() {
  local response_file="$1" complete_file="$2" request_id="$3"
  local project_path="$4" phase="$5"
  local marker_request marker_status marker_hash actual_hash

  [[ -f "$response_file" && ! -L "$response_file" ]] || {
    printf '%s\n' "response.md is missing or is not a regular file"
    return 1
  }
  [[ -f "$complete_file" && ! -L "$complete_file" ]] || {
    printf '%s\n' "complete.json is missing or is not a regular file"
    return 1
  }
  jq -e 'type == "object" and .schema_version == 1' "$complete_file" >/dev/null 2>&1 || {
    printf '%s\n' "complete.json is not a schema-version 1 JSON object"
    return 1
  }

  marker_request="$(jq -r '.request_id // empty' "$complete_file" 2>/dev/null)"
  marker_status="$(jq -r '.status // empty' "$complete_file" 2>/dev/null)"
  marker_hash="$(jq -r '.response_git_hash // empty' "$complete_file" 2>/dev/null)"
  [[ "$marker_request" == "$request_id" ]] || {
    printf '%s\n' "complete.json belongs to a different request"
    return 1
  }
  [[ "$marker_status" == "complete" ]] || {
    printf '%s\n' "complete.json status must be 'complete'"
    return 1
  }

  actual_hash="$(cursor_ide_response_git_hash "$response_file")"
  [[ -n "$actual_hash" && "$marker_hash" == "$actual_hash" ]] || {
    printf '%s\n' "response.md changed after complete.json was written"
    return 1
  }

  # shellcheck disable=SC2094 # Both readers are intentional; neither writes.
  if ! tr -d '\0' < "$response_file" | cmp -s - "$response_file"; then
    printf '%s\n' "response.md contains NUL bytes"
    return 1
  fi

  local min_bytes response_bytes
  min_bytes="${REPOLENS_CURSOR_IDE_MIN_RESPONSE_BYTES:-120}"
  [[ "$min_bytes" =~ ^[1-9][0-9]*$ ]] || min_bytes=120
  response_bytes="$(tr -d '[:space:]' < "$response_file" | wc -c | tr -d '[:space:]')"
  [[ "$response_bytes" =~ ^[0-9]+$ ]] || response_bytes=0
  if (( response_bytes < min_bytes )); then
    printf 'response.md has %s non-whitespace bytes; at least %s are required\n' \
      "$response_bytes" "$min_bytes"
    return 1
  fi

  # Lens handoffs need enough evidence to make a DONE result meaningful. Meta
  # stages are schema-validated by their existing consumers instead.
  if [[ "$phase" == "lens" ]]; then
    grep -qiE '^##[[:space:]]+(Method|Investigation|Analysis)([[:space:]]|$)' "$response_file" || {
      printf '%s\n' "lens response is missing a ## Method, ## Investigation, or ## Analysis section"
      return 1
    }
    grep -qiE '^##[[:space:]]+Findings?([[:space:]]|$)' "$response_file" || {
      printf '%s\n' "lens response is missing a ## Findings section"
      return 1
    }

    local min_anchors verified_anchors
    min_anchors="${REPOLENS_CURSOR_IDE_MIN_PATH_LINE_ANCHORS:-1}"
    [[ "$min_anchors" =~ ^[1-9][0-9]*$ ]] || min_anchors=1
    verified_anchors="$(cursor_ide_count_verified_anchors "$response_file" "$project_path")"
    if (( verified_anchors < min_anchors )); then
      printf 'lens response cites %s in-bounds project path:line anchor(s); at least %s are required\n' \
        "$verified_anchors" "$min_anchors"
      return 1
    fi
  fi

  return 0
}

cursor_ide_prompt_footer() {
  local request_id="$1" response_file="$2" complete_file="$3" phase="$4"
  local response_q complete_q response_tmp_q complete_tmp_q request_q
  printf -v response_q '%q' "$response_file"
  printf -v complete_q '%q' "$complete_file"
  printf -v response_tmp_q '%q' "${response_file}.tmp"
  printf -v complete_tmp_q '%q' "${complete_file}.tmp"
  printf -v request_q '%q' "$request_id"

  cat <<EOF

---

## Cursor IDE handoff

This is a RepoLens \`${phase}\` request. Complete the prompt above in Cursor
Composer. Keep the full result out of chat and write it to \`response.md\`.

For a lens response, include \`## Method\` (or \`## Investigation\` /
\`## Analysis\`), \`## Findings\`, at least one real project-relative
\`path/to/file:line\` citation whose line exists in that file, and a short
evidence-based explanation even when the result is \`DONE\` or not applicable.

Finalize atomically only after the response is complete:

\`\`\`bash
# Write the full result to ${response_tmp_q}, then:
mv -- ${response_tmp_q} ${response_q}
response_hash="\$(git hash-object --no-filters ${response_q})"
jq -n --arg request_id ${request_q} --arg response_git_hash "\$response_hash" \\
  '{schema_version: 1, request_id: \$request_id, status: "complete", response_git_hash: \$response_git_hash}' \\
  > ${complete_tmp_q}
mv -- ${complete_tmp_q} ${complete_q}
\`\`\`

Do not reuse files or completion data from another request. RepoLens validates
the request id, response hash, response substance, and lens evidence before it
advances. Continue servicing subsequent \`REPOLENS_CTL\` handoffs until the
\`run_complete\` event.
EOF
}

# run_cursor_ide_agent <prompt> <project-path> <timeout-seconds> [envelope-file]
run_cursor_ide_agent() {
  local prompt="$1" project_path="$2" timeout_seconds="${3:-1800}"
  local envelope_file="${4:-}"
  local phase request_id request_root request_dir prompt_file response_file
  local complete_file request_file prompt_tmp request_tmp

  phase="$(cursor_ide_safe_component "${REPOLENS_CURSOR_IDE_PHASE:-agent}")"
  request_id="$(cursor_ide_new_request_id)"

  if [[ -n "${REPOLENS_CURSOR_IDE_HANDOFF_DIR:-}" ]]; then
    request_root="$REPOLENS_CURSOR_IDE_HANDOFF_DIR"
  elif [[ -n "$envelope_file" ]]; then
    request_root="$(dirname "$envelope_file")/cursor-ide"
  elif [[ -n "${LOG_BASE:-}" ]]; then
    request_root="$LOG_BASE/cursor-ide"
  else
    request_root="$project_path/.repolens-cursor-ide"
  fi

  request_dir="$request_root/$phase/$request_id"
  prompt_file="$request_dir/prompt.md"
  response_file="$request_dir/response.md"
  complete_file="$request_dir/complete.json"
  request_file="$request_dir/request.json"
  prompt_tmp="${prompt_file}.tmp"
  request_tmp="${request_file}.tmp"

  if [[ -z "${REPOLENS_CURSOR_IDE_CTL_LOG:-}" ]]; then
    REPOLENS_CURSOR_IDE_CTL_LOG="$request_root/events.ndjson"
  fi

  mkdir -p "$request_dir" || {
    printf '%s\n' "REPOLENS_CURSOR_IDE_ERROR unable to create $request_dir"
    return 1
  }
  chmod 700 "$request_dir" 2>/dev/null || true

  {
    printf '%s\n' "$prompt"
    cursor_ide_prompt_footer "$request_id" "$response_file" "$complete_file" "$phase"
  } > "$prompt_tmp" || return 1
  chmod 600 "$prompt_tmp" 2>/dev/null || true
  mv -f "$prompt_tmp" "$prompt_file" || return 1

  jq -n \
    --argjson schema_version 1 \
    --arg kind "cursor_ide_handoff" \
    --arg request_id "$request_id" \
    --arg run_id "${RUN_ID:-}" \
    --arg phase "$phase" \
    --arg domain "${REPOLENS_CURSOR_IDE_DOMAIN:-}" \
    --arg lens "${REPOLENS_CURSOR_IDE_LENS:-}" \
    --argjson iteration "$(cursor_ide_uint "${REPOLENS_CURSOR_IDE_ITERATION:-0}")" \
    --arg project "$project_path" \
    --arg prompt "$prompt_file" \
    --arg response "$response_file" \
    --arg complete "$complete_file" \
    '{
      schema_version: $schema_version,
      kind: $kind,
      request_id: $request_id,
      run_id: $run_id,
      phase: $phase,
      domain: $domain,
      lens: $lens,
      iteration: $iteration,
      project: $project,
      files: {prompt: $prompt, response: $response, complete: $complete}
    }' > "$request_tmp" || return 1
  chmod 600 "$request_tmp" 2>/dev/null || true
  mv -f "$request_tmp" "$request_file" || return 1

  local handoff_json
  handoff_json="$(jq -c . "$request_file")"
  cursor_ide_emit "$handoff_json"

  local control_fd="${REPOLENS_CURSOR_IDE_CONTROL_FD:-}"
  local message
  message="[RepoLens cursor-ide] Waiting for Cursor Composer: $request_file"
  if [[ "$control_fd" =~ ^[0-9]+$ ]] && { true >&"$control_fd"; } 2>/dev/null; then
    printf '%s\n' "$message" >&"$control_fd"
  else
    printf '%s\n' "$message" >&2
  fi

  local poll_seconds max_wait waited=0 rejection_reason rejection_json
  poll_seconds="${REPOLENS_CURSOR_IDE_POLL_SEC:-1}"
  max_wait="${REPOLENS_CURSOR_IDE_MAX_WAIT_SEC:-$timeout_seconds}"
  [[ "$poll_seconds" =~ ^[1-9][0-9]*$ ]] || poll_seconds=1
  [[ "$max_wait" =~ ^[1-9][0-9]*$ ]] || max_wait="$timeout_seconds"
  [[ "$max_wait" =~ ^[1-9][0-9]*$ ]] || max_wait=1800

  while (( waited < max_wait )); do
    if [[ -e "$complete_file" ]]; then
      if rejection_reason="$(
        cursor_ide_validate_response \
          "$response_file" "$complete_file" "$request_id" "$project_path" "$phase"
      )"; then
        local accepted_json
        accepted_json="$(jq -nc \
          --argjson schema_version 1 \
          --arg kind "cursor_ide_response_accepted" \
          --arg request_id "$request_id" \
          --arg phase "$phase" \
          '{schema_version: $schema_version, kind: $kind, request_id: $request_id, phase: $phase}')"
        cursor_ide_emit "$accepted_json"
        cat "$response_file"
        return 0
      fi

      rejection_json="$(jq -nc \
        --argjson schema_version 1 \
        --arg kind "cursor_ide_response_rejected" \
        --arg request_id "$request_id" \
        --arg reason "$rejection_reason" \
        --arg response "$response_file" \
        --arg complete "$complete_file" \
        '{
          schema_version: $schema_version,
          kind: $kind,
          request_id: $request_id,
          reason: $reason,
          files: {response: $response, complete: $complete}
        }')"
      cursor_ide_emit "$rejection_json"
      rm -f "$complete_file"
    fi
    sleep "$poll_seconds"
    waited=$((waited + poll_seconds))
  done

  local timeout_json
  timeout_json="$(jq -nc \
    --argjson schema_version 1 \
    --arg kind "cursor_ide_timeout" \
    --arg request_id "$request_id" \
    --argjson waited_seconds "$waited" \
    --arg request "$request_file" \
    '{
      schema_version: $schema_version,
      kind: $kind,
      request_id: $request_id,
      waited_seconds: $waited_seconds,
      request_file: $request
    }')"
  cursor_ide_emit "$timeout_json"
  printf 'REPOLENS_CURSOR_IDE_TIMEOUT request_id=%s waited_seconds=%s request=%s\n' \
    "$request_id" "$waited" "$request_file"
  return 124
}

cursor_ide_emit_run_complete() {
  local run_id="${1:-}" outcome="${2:-unknown}" summary_file="${3:-}"
  local json
  json="$(jq -nc \
    --argjson schema_version 1 \
    --arg kind "run_complete" \
    --arg run_id "$run_id" \
    --arg outcome "$outcome" \
    --arg summary "$summary_file" \
    '{
      schema_version: $schema_version,
      kind: $kind,
      run_id: $run_id,
      outcome: $outcome,
      summary_file: $summary,
      instruction: "No more handoffs remain. Read the summary and collected findings."
    }')"
  cursor_ide_emit "$json"
}
