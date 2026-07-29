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

# RepoLens — multi-file specification bundle helpers.
# Callers provide the option arrays
# SPEC_GLOBS and SPEC_EXCLUDES and receive ordered paths in SPEC_BUNDLE_FILES.
#
# These helpers intentionally do not call die(): library failures populate
# SPEC_BUNDLE_ERROR so the CLI can present one contextual, actionable error.

SPEC_BUNDLE_ERROR=""
SPEC_NORMALIZED_VALUE=""
SPEC_SHA256_VALUE=""
SPEC_RESUME_MODE=""
SPEC_RESUME_ROOT=""
SPEC_RESUME_ENTRY=""
SPEC_RESUME_BASE=""
declare -a SPEC_RESUME_GLOBS=()
declare -a SPEC_RESUME_EXCLUDES=()

# Persist only the data-selection identity needed to resume a directory-spec
# run. Authorization and execution routing (--yes, local vs forge, and local
# output path) deliberately never enter run artifacts: every continuation must
# receive those choices again from the current CLI invocation.
spec_write_resume_metadata() {
  local output="$1" mode="$2" root="$3" entry="$4" spec_base="$5"
  local includes_json excludes_json temp_output

  includes_json="$(jq -cn --args '$ARGS.positional' -- "${SPEC_GLOBS[@]}")" || return 1
  excludes_json="$(jq -cn --args '$ARGS.positional' -- "${SPEC_EXCLUDES[@]}")" || return 1
  temp_output="$(mktemp "${output}.tmp.XXXXXX")" || {
    SPEC_BUNDLE_ERROR="Unable to allocate temporary resume metadata"
    return 1
  }
  if ! jq -n \
    --arg mode "$mode" \
    --arg root "$root" \
    --arg entry "$entry" \
    --arg spec_base "$spec_base" \
    --argjson includes "$includes_json" \
    --argjson excludes "$excludes_json" \
    '{
      schema_version: 3,
      mode: $mode,
      specification: {
        kind: "directory",
        root: $root,
        entry: (if $entry == "" then null else $entry end),
        includes: $includes,
        excludes: $excludes,
        spec_base: $spec_base
      }
    }' > "$temp_output"; then
    rm -f "$temp_output"
    SPEC_BUNDLE_ERROR="Unable to serialize resume metadata"
    return 1
  fi
  mv "$temp_output" "$output"
}

# Load persisted data-selection values. Output is returned through
# SPEC_RESUME_* globals so this remains compatible with the project's Bash 4.0
# minimum (namerefs require a newer Bash). Legacy schemas are readable for
# selection compatibility, but their execution fields are ignored.
spec_load_resume_metadata() {
  local metadata="$1" value schema_version
  SPEC_BUNDLE_ERROR=""
  SPEC_RESUME_MODE=""
  SPEC_RESUME_ROOT=""
  SPEC_RESUME_ENTRY=""
  SPEC_RESUME_BASE=""
  SPEC_RESUME_GLOBS=()
  SPEC_RESUME_EXCLUDES=()

  schema_version="$(jq -r '.schema_version // empty' "$metadata" 2>/dev/null)" || {
    SPEC_BUNDLE_ERROR="Persisted bundle resume metadata is invalid: $metadata"
    return 1
  }
  case "$schema_version" in
    1|2|3) ;;
    *)
      SPEC_BUNDLE_ERROR="Unsupported persisted bundle resume metadata schema version '${schema_version:-<missing>}' in $metadata. Start a new run."
      return 1
      ;;
  esac

  jq -e --argjson schema_version "$schema_version" '
    .schema_version == $schema_version
    and (.mode == "greenfield" or .mode == "spec-change")
    and (.specification.kind == "directory")
    and (.specification.root | type == "string" and length > 0)
    and (.specification.entry == null or (.specification.entry | type == "string"))
    and (.specification.includes | type == "array"
      and all(.[]; type == "string"))
    and (.specification.excludes | type == "array"
      and all(.[]; type == "string"))
    and (.specification.spec_base | type == "string" and length > 0)
    and (
      if $schema_version == 3
      then (keys | sort) == ["mode", "schema_version", "specification"]
      else (.auto_yes | type == "boolean")
      end
    )
    and ($schema_version != 2 or (
      (.execution.boundary == "local" or .execution.boundary == "forge")
      and (.execution.output_dir_explicit | type == "boolean")
      and (
        if .execution.boundary == "local"
        then (.execution.output_dir | type == "string"
          and startswith("/")
          and length > 0)
        else (.execution.output_dir == null
          and .execution.output_dir_explicit == false)
        end
      )
    ))
  ' "$metadata" >/dev/null 2>&1 || {
    SPEC_BUNDLE_ERROR="Persisted bundle resume metadata is invalid: $metadata"
    return 1
  }

  # shellcheck disable=SC2034 # Output consumed by the sourcing CLI.
  IFS= read -r -d '' SPEC_RESUME_MODE \
    < <(jq -j '.mode, "\u0000"' "$metadata") || return 1
  # shellcheck disable=SC2034 # Output consumed by the sourcing CLI.
  IFS= read -r -d '' SPEC_RESUME_ROOT \
    < <(jq -j '.specification.root, "\u0000"' "$metadata") || return 1
  # shellcheck disable=SC2034 # Output consumed by the sourcing CLI.
  IFS= read -r -d '' SPEC_RESUME_ENTRY \
    < <(jq -j '(.specification.entry // ""), "\u0000"' "$metadata") || return 1
  # shellcheck disable=SC2034 # Output consumed by the sourcing CLI.
  IFS= read -r -d '' SPEC_RESUME_BASE \
    < <(jq -j '.specification.spec_base, "\u0000"' "$metadata") || return 1
  while IFS= read -r -d '' value; do
    SPEC_RESUME_GLOBS+=("$value")
  done < <(jq -j '.specification.includes[] | ., "\u0000"' "$metadata")
  while IFS= read -r -d '' value; do
    SPEC_RESUME_EXCLUDES+=("$value")
  done < <(jq -j '.specification.excludes[] | ., "\u0000"' "$metadata")
}

# End offset returned by _spec_validate_bracket_expression. A global keeps this
# helper compatible with the project's Bash 4.0 minimum (namerefs require 4.3).
_SPEC_BRACKET_END=-1

# Validate one Bash/POSIX bracket expression beginning at start_index. POSIX
# character classes, equivalence classes, and collating symbols use a nested
# pair of brackets (for example [[:digit:]], [[=a=]], and [[.a.]]); raw nested
# '[' characters remain invalid so malformed patterns cannot be mistaken for
# literal matches.
_spec_validate_bracket_expression() {
  local pattern="$1" start_index="$2" option_name="$3"
  local length="${#1}" i atom_start atom_end=-1
  local char atom_marker atom_value
  local has_member=false

  _SPEC_BRACKET_END=-1
  i=$((start_index + 1))

  # Bash accepts either marker for a negated bracket expression.
  if ((i < length)) && [[ "${pattern:i:1}" == "!" || "${pattern:i:1}" == "^" ]]; then
    i=$((i + 1))
  fi

  # A closing bracket in the first member position is a literal member, not
  # the end of the expression (for example []] and [!]]).
  if ((i < length)) && [[ "${pattern:i:1}" == "]" ]]; then
    has_member=true
    i=$((i + 1))
  fi

  while ((i < length)); do
    char="${pattern:i:1}"
    case "$char" in
      "]")
        if ! $has_member; then
          SPEC_BUNDLE_ERROR="$option_name contains an empty bracket expression: $pattern"
          return 1
        fi
        _SPEC_BRACKET_END="$i"
        return 0
        ;;
      "[")
        atom_marker="${pattern:i+1:1}"
        # `[[]` is the portable bracket expression for one literal `[`.
        # The nested opener is an ordinary member when immediately followed
        # by the outer closing bracket, not the start of a POSIX atom.
        if [[ "$atom_marker" == "]" ]]; then
          has_member=true
          i=$((i + 1))
          continue
        fi
        case "$atom_marker" in
          :|=|.) ;;
          *)
            SPEC_BUNDLE_ERROR="$option_name contains a nested '[' character: $pattern"
            return 1
            ;;
        esac

        atom_start=$((i + 2))
        atom_end=-1
        for ((i = atom_start; i < length; i++)); do
          char="${pattern:i:1}"
          if [[ "$char" == "/" ]]; then
            SPEC_BUNDLE_ERROR="$option_name contains '/' inside a POSIX bracket atom: $pattern"
            return 1
          fi
          if [[ "$char" == "[" ]]; then
            SPEC_BUNDLE_ERROR="$option_name contains a nested '[' character: $pattern"
            return 1
          fi
          if [[ "$char" == "]" ]]; then
            SPEC_BUNDLE_ERROR="$option_name contains a malformed POSIX bracket atom: $pattern"
            return 1
          fi
          if [[ "$char" == "$atom_marker" ]] \
            && ((i + 1 < length)) \
            && [[ "${pattern:i+1:1}" == "]" ]]; then
            atom_end="$i"
            break
          fi
        done
        if ((atom_end < 0)); then
          SPEC_BUNDLE_ERROR="$option_name contains an unterminated POSIX bracket atom: $pattern"
          return 1
        fi
        atom_value="${pattern:atom_start:atom_end-atom_start}"
        if [[ -z "$atom_value" ]]; then
          SPEC_BUNDLE_ERROR="$option_name contains an empty POSIX bracket atom: $pattern"
          return 1
        fi
        if [[ "$atom_marker" == ":" ]]; then
          case "$atom_value" in
            alnum|alpha|blank|cntrl|digit|graph|lower|print|punct|space|upper|xdigit) ;;
            *)
              SPEC_BUNDLE_ERROR="$option_name contains an unknown POSIX character class '$atom_value': $pattern"
              return 1
              ;;
          esac
        fi
        has_member=true
        i=$((atom_end + 2))
        continue
        ;;
      "/")
        SPEC_BUNDLE_ERROR="$option_name contains '/' inside a bracket expression: $pattern"
        return 1
        ;;
      *)
        has_member=true
        ;;
    esac
    i=$((i + 1))
  done

  SPEC_BUNDLE_ERROR="$option_name contains an unmatched '[' character: $pattern"
  return 1
}

spec_normalize_pattern() {
  local pattern="$1" option_name="${2:-spec pattern}"
  SPEC_BUNDLE_ERROR=""
  SPEC_NORMALIZED_VALUE=""

  while [[ "$pattern" == ./* ]]; do
    pattern="${pattern#./}"
  done

  if [[ -z "$pattern" ]]; then
    SPEC_BUNDLE_ERROR="$option_name must not be empty"
    return 1
  fi
  if [[ "$pattern" == /* ]]; then
    SPEC_BUNDLE_ERROR="$option_name must be relative to --spec-dir: $pattern"
    return 1
  fi
  if [[ "$pattern" == */ || "$pattern" == *//* || "/$pattern/" == */../* ]]; then
    SPEC_BUNDLE_ERROR="$option_name contains an invalid path segment: $pattern"
    return 1
  fi
  if [[ "$pattern" =~ [[:cntrl:]] ]]; then
    SPEC_BUNDLE_ERROR="$option_name must not contain control characters"
    return 1
  fi

  # Bash treats malformed brackets as literals, which hides mistakes behind a
  # zero-match error. Parse them explicitly while retaining Bash's supported
  # POSIX atoms inside otherwise segment-aware glob patterns.
  local i char
  for ((i = 0; i < ${#pattern}; i++)); do
    char="${pattern:i:1}"
    if [[ "$char" == "[" ]]; then
      _spec_validate_bracket_expression "$pattern" "$i" "$option_name" || return 1
      i="$_SPEC_BRACKET_END"
    fi
  done

  SPEC_NORMALIZED_VALUE="$pattern"
}

spec_normalize_entry() {
  local entry="$1"
  SPEC_BUNDLE_ERROR=""
  SPEC_NORMALIZED_VALUE=""

  while [[ "$entry" == ./* ]]; do
    entry="${entry#./}"
  done

  if [[ -z "$entry" ]]; then
    SPEC_BUNDLE_ERROR="--spec-entry must not be empty"
    return 1
  fi
  if [[ "$entry" == /* ]]; then
    SPEC_BUNDLE_ERROR="--spec-entry must be relative to --spec-dir: $entry"
    return 1
  fi
  if [[ "$entry" == */ || "$entry" == *//* || "/$entry/" == */../* ]]; then
    SPEC_BUNDLE_ERROR="--spec-entry contains an invalid path segment: $entry"
    return 1
  fi
  if [[ "$entry" =~ [[:cntrl:]] ]]; then
    SPEC_BUNDLE_ERROR="--spec-entry must not contain control characters"
    return 1
  fi

  # shellcheck disable=SC2034 # Output consumed by callers sourcing this library.
  SPEC_NORMALIZED_VALUE="$entry"
}

spec_validate_resolved_path() {
  local path="$1"
  if [[ -z "$path" || "$path" == /* || "$path" == */ || "$path" == *//* \
    || "/$path/" == */../* || "$path" =~ [[:cntrl:]] ]]; then
    SPEC_BUNDLE_ERROR="Specification filename cannot be represented safely: $path"
    return 1
  fi
}

# Segment-aware glob matching. In contrast with [[ path == pattern ]], a single
# '*' never crosses '/', while a complete '**' segment matches zero or more
# path segments. Character classes and '?' retain Bash's normal glob behavior.
_spec_match_segments() {
  local pattern_index="$1" path_index="$2" next_path_index
  local pattern_count="${#_SPEC_PATTERN_SEGMENTS[@]}"
  local path_count="${#_SPEC_PATH_SEGMENTS[@]}"
  local pattern_segment

  if ((pattern_index == pattern_count)); then
    ((path_index == path_count))
    return
  fi

  pattern_segment="${_SPEC_PATTERN_SEGMENTS[pattern_index]}"
  if [[ "$pattern_segment" == "**" ]]; then
    while ((pattern_index + 1 < pattern_count)) \
      && [[ "${_SPEC_PATTERN_SEGMENTS[pattern_index + 1]}" == "**" ]]; do
      pattern_index=$((pattern_index + 1))
    done
    if ((pattern_index + 1 == pattern_count)); then
      return 0
    fi
    for ((next_path_index = path_index; next_path_index <= path_count; next_path_index++)); do
      _spec_match_segments "$((pattern_index + 1))" "$next_path_index" && return 0
    done
    return 1
  fi

  ((path_index < path_count)) || return 1
  # shellcheck disable=SC2053 # Pattern matching is the purpose of this helper.
  [[ "${_SPEC_PATH_SEGMENTS[path_index]}" == $pattern_segment ]] \
    && _spec_match_segments "$((pattern_index + 1))" "$((path_index + 1))"
}

spec_pattern_matches() {
  local path="$1" pattern="$2"
  IFS='/' read -r -a _SPEC_PATH_SEGMENTS <<< "$path"
  IFS='/' read -r -a _SPEC_PATTERN_SEGMENTS <<< "$pattern"
  _spec_match_segments 0 0
}

spec_is_selected() {
  local path="$1" pattern
  local included=false
  for pattern in "${SPEC_GLOBS[@]}"; do
    if spec_pattern_matches "$path" "$pattern"; then
      included=true
      break
    fi
  done
  $included || return 1
  for pattern in "${SPEC_EXCLUDES[@]}"; do
    spec_pattern_matches "$path" "$pattern" && return 1
  done
  return 0
}

spec_order_paths() {
  local entry="$1" path
  local sorted_file
  shift
  SPEC_BUNDLE_FILES=()

  if [[ -n "$entry" ]]; then
    for path in "$@"; do
      if [[ "$path" == "$entry" ]]; then
        SPEC_BUNDLE_FILES+=("$path")
        break
      fi
    done
  fi

  sorted_file="$(mktemp)" || {
    SPEC_BUNDLE_ERROR="Unable to allocate temporary storage while ordering specification files"
    return 1
  }
  # Resolved paths reject control characters, so newline-delimited sorting is
  # safe here and remains portable to BSD/macOS sort (which lacks GNU -z).
  if ! printf '%s\n' "$@" | LC_ALL=C sort -u > "$sorted_file"; then
    rm -f "$sorted_file"
    SPEC_BUNDLE_ERROR="Unable to sort the resolved specification files"
    return 1
  fi
  while IFS= read -r path; do
    [[ -n "$path" && "$path" != "$entry" ]] && SPEC_BUNDLE_FILES+=("$path")
  done < "$sorted_file"
  rm -f "$sorted_file"
}

spec_resolve_worktree() {
  local root="$1" entry="$2" file rel list_file
  local -a selected=()
  local validation_failed=false
  SPEC_BUNDLE_ERROR=""

  list_file="$(mktemp)" || {
    SPEC_BUNDLE_ERROR="Unable to allocate temporary storage while scanning $root"
    return 1
  }
  if ! find "$root" -type d -name .git -prune -o \( -type f -o -type l \) -print0 > "$list_file"; then
    rm -f "$list_file"
    SPEC_BUNDLE_ERROR="Unable to scan specification directory: $root"
    return 1
  fi
  while IFS= read -r -d '' file; do
    rel="${file#"$root"/}"
    if ! spec_validate_resolved_path "$rel"; then
      validation_failed=true
      break
    fi
    if [[ -L "$file" ]]; then
      if [[ -d "$file" ]]; then
        SPEC_BUNDLE_ERROR="Spec directory tree contains a symlink directory that could hide selected files: $file"
        validation_failed=true
        break
      fi
      if spec_is_selected "$rel"; then
        SPEC_BUNDLE_ERROR="Selected spec bundle member must not be a symlink: $file"
        validation_failed=true
        break
      fi
      continue
    fi
    spec_is_selected "$rel" && selected+=("$rel")
  done < "$list_file"
  rm -f "$list_file"
  $validation_failed && return 1
  spec_order_paths "$entry" "${selected[@]}"
}

spec_resolve_git_tree() {
  local project="$1" root_rel="$2" ref="$3" entry="$4"
  local tracked tracked_metadata tracked_path tracked_mode rel list_file
  local -a selected=()
  local validation_failed=false
  SPEC_BUNDLE_ERROR=""

  list_file="$(mktemp)" || {
    SPEC_BUNDLE_ERROR="Unable to allocate temporary storage while reading Git tree $ref"
    return 1
  }
  if [[ -n "$root_rel" ]]; then
    git -C "$project" ls-tree -rz "$ref" -- ":(literal)$root_rel" > "$list_file" || {
      rm -f "$list_file"
      SPEC_BUNDLE_ERROR="Unable to list specification files from Git tree $ref"
      return 1
    }
  else
    git -C "$project" ls-tree -rz "$ref" > "$list_file" || {
      rm -f "$list_file"
      SPEC_BUNDLE_ERROR="Unable to list specification files from Git tree $ref"
      return 1
    }
  fi

  while IFS= read -r -d '' tracked; do
    [[ -n "$tracked" ]] || continue
    tracked_metadata="${tracked%%$'\t'*}"
    tracked_path="${tracked#*$'\t'}"
    if [[ "$tracked_path" == "$tracked" ]]; then
      SPEC_BUNDLE_ERROR="Unable to parse specification entry from Git tree $ref"
      validation_failed=true
      break
    fi
    tracked_mode="${tracked_metadata%% *}"
    if [[ -n "$root_rel" ]]; then
      rel="${tracked_path#"$root_rel"/}"
      [[ "$rel" != "$tracked_path" ]] || continue
    else
      rel="$tracked_path"
    fi
    if ! spec_validate_resolved_path "$rel"; then
      validation_failed=true
      break
    fi
    if spec_is_selected "$rel"; then
      if [[ "$tracked_mode" == "120000" ]]; then
        SPEC_BUNDLE_ERROR="Selected spec bundle member is a symlink in Git tree $ref: $rel"
        validation_failed=true
        break
      fi
      selected+=("$rel")
    fi
  done < "$list_file"
  rm -f "$list_file"
  $validation_failed && return 1
  spec_order_paths "$entry" "${selected[@]}"
}

spec_file_is_text() {
  local file="$1"
  # shellcheck disable=SC2094 # cmp only reads the file.
  tr -d '\0' < "$file" | cmp -s - "$file"
}

spec_validate_worktree_sources() {
  local root="$1" rel source_file
  SPEC_BUNDLE_ERROR=""
  for rel in "${SPEC_BUNDLE_FILES[@]}"; do
    source_file="$root/$rel"
    if [[ ! -f "$source_file" || -L "$source_file" ]]; then
      SPEC_BUNDLE_ERROR="Spec bundle member is not a regular non-symlink file: $source_file"
      return 1
    fi
    if [[ ! -r "$source_file" ]]; then
      SPEC_BUNDLE_ERROR="Spec file not readable: $source_file"
      return 1
    fi
    if ! spec_file_is_text "$source_file"; then
      SPEC_BUNDLE_ERROR="Spec file appears to be binary: $source_file — only text files are supported."
      return 1
    fi
  done
}

spec_marker_path() {
  printf '%s' "$1" | sed 's/\&/\&amp;/g; s/"/\&quot;/g; s/-->/--\&gt;/g'
}

spec_append_file() {
  local output="$1" rel="$2" source_file="$3" marker bom
  marker="$(spec_marker_path "$rel")" || return 1
  bom=$'\xEF\xBB\xBF'
  printf '<!-- REPOLENS_SPEC_FILE_BEGIN path="%s" -->\n' "$marker" >> "$output" || return 1
  sed "1s/^${bom}//" "$source_file" | tr -d '\r' >> "$output" || return 1
  if [[ -s "$source_file" && "$(tail -c 1 "$source_file" | wc -l)" -ne 1 ]]; then
    printf '\n' >> "$output" || return 1
  fi
  printf '<!-- REPOLENS_SPEC_FILE_END path="%s" -->\n\n' "$marker" >> "$output"
}

spec_compose_worktree() {
  local root="$1" output="$2" rel temp_output
  temp_output="$(mktemp "${output}.tmp.XXXXXX")" || {
    SPEC_BUNDLE_ERROR="Unable to allocate a temporary combined specification"
    return 1
  }
  : > "$temp_output" || return 1
  for rel in "${SPEC_BUNDLE_FILES[@]}"; do
    spec_append_file "$temp_output" "$rel" "$root/$rel" || {
      rm -f "$temp_output"
      SPEC_BUNDLE_ERROR="Unable to compose specification file: $root/$rel"
      return 1
    }
  done
  mv "$temp_output" "$output"
}

spec_compose_git_tree() {
  local project="$1" root_rel="$2" ref="$3" output="$4" rel blob_path temp temp_output
  temp="$(mktemp)" || {
    SPEC_BUNDLE_ERROR="Unable to allocate a temporary Git blob"
    return 1
  }
  temp_output="$(mktemp "${output}.tmp.XXXXXX")" || {
    rm -f "$temp"
    SPEC_BUNDLE_ERROR="Unable to allocate a temporary base specification"
    return 1
  }
  : > "$temp_output" || return 1

  for rel in "${SPEC_BUNDLE_FILES[@]}"; do
    if [[ -n "$root_rel" ]]; then
      blob_path="$root_rel/$rel"
    else
      blob_path="$rel"
    fi
    git -C "$project" show "$ref:$blob_path" > "$temp" || {
      rm -f "$temp" "$temp_output"
      SPEC_BUNDLE_ERROR="Unable to read '$blob_path' from Git tree $ref"
      return 1
    }
    spec_append_file "$temp_output" "$rel" "$temp" || {
      rm -f "$temp" "$temp_output"
      SPEC_BUNDLE_ERROR="Unable to compose '$blob_path' from Git tree $ref"
      return 1
    }
  done
  rm -f "$temp"
  mv "$temp_output" "$output"
}

spec_validate_combined_file() {
  local file="$1" description="${2:-Combined spec bundle}" size
  local max_bytes="${3:-102400}"
  size="$(wc -c < "$file")" || {
    SPEC_BUNDLE_ERROR="Unable to measure $description"
    return 1
  }
  if ((size > max_bytes)); then
    SPEC_BUNDLE_ERROR="$description too large (${size} bytes, max 100KB)"
    return 1
  fi
  if ! spec_file_is_text "$file"; then
    SPEC_BUNDLE_ERROR="$description contains binary content"
    return 1
  fi
}

spec_sha256_file() {
  local file="$1" digest_output=""
  SPEC_BUNDLE_ERROR=""
  SPEC_SHA256_VALUE=""

  if [[ ! -f "$file" || -L "$file" ]]; then
    SPEC_BUNDLE_ERROR="Cannot verify specification artifact because it is not a regular non-symlink file: $file"
    return 1
  fi
  if [[ ! -r "$file" ]]; then
    SPEC_BUNDLE_ERROR="Cannot verify unreadable specification artifact: $file"
    return 1
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    digest_output="$(LC_ALL=C sha256sum "$file")" || {
      SPEC_BUNDLE_ERROR="Unable to compute SHA-256 for specification artifact: $file"
      return 1
    }
    digest_output="${digest_output%%[[:space:]]*}"
  elif command -v shasum >/dev/null 2>&1; then
    digest_output="$(LC_ALL=C shasum -a 256 "$file")" || {
      SPEC_BUNDLE_ERROR="Unable to compute SHA-256 for specification artifact: $file"
      return 1
    }
    digest_output="${digest_output%%[[:space:]]*}"
  elif command -v openssl >/dev/null 2>&1; then
    digest_output="$(LC_ALL=C openssl dgst -sha256 -r "$file")" || {
      SPEC_BUNDLE_ERROR="Unable to compute SHA-256 for specification artifact: $file"
      return 1
    }
    digest_output="${digest_output%%[[:space:]]*}"
  else
    SPEC_BUNDLE_ERROR="SHA-256 verification requires sha256sum, shasum, or openssl"
    return 1
  fi

  digest_output="$(printf '%s' "$digest_output" | tr 'A-F' 'a-f')"
  if [[ ! "$digest_output" =~ ^[0-9a-f]{64}$ ]]; then
    SPEC_BUNDLE_ERROR="SHA-256 tool returned an invalid digest for specification artifact: $file"
    return 1
  fi
  SPEC_SHA256_VALUE="$digest_output"
}

spec_write_manifest() {
  local output="$1" root="$2" entry="$3" combined="$4" rel bytes temp_output
  local combined_bytes combined_sha256
  local files_json='[]'
  local includes_json excludes_json
  local order=0
  for rel in "${SPEC_BUNDLE_FILES[@]}"; do
    bytes="$(wc -c < "$root/$rel")" || {
      SPEC_BUNDLE_ERROR="Unable to measure specification file: $root/$rel"
      return 1
    }
    files_json="$(jq --arg path "$rel" --argjson bytes "$bytes" --argjson order "$order" \
      '. + [{path: $path, bytes: $bytes, order: $order}]' <<<"$files_json")" || return 1
    order=$((order + 1))
  done
  includes_json="$(jq -cn --args '$ARGS.positional' -- "${SPEC_GLOBS[@]}")" || return 1
  excludes_json="$(jq -cn --args '$ARGS.positional' -- "${SPEC_EXCLUDES[@]}")" || return 1
  combined_bytes="$(wc -c < "$combined")" || {
    SPEC_BUNDLE_ERROR="Unable to measure combined specification artifact: $combined"
    return 1
  }
  spec_sha256_file "$combined" || return 1
  combined_sha256="$SPEC_SHA256_VALUE"
  temp_output="$(mktemp "${output}.tmp.XXXXXX")" || {
    SPEC_BUNDLE_ERROR="Unable to allocate a temporary specification manifest"
    return 1
  }
  if ! jq -n \
    --arg root "$root" \
    --arg entry "$entry" \
    --argjson includes "$includes_json" \
    --argjson excludes "$excludes_json" \
    --argjson files "$files_json" \
    --argjson combined_bytes "$combined_bytes" \
    --arg combined_sha256 "$combined_sha256" \
    '{schema_version:3, kind:"directory", root:$root,
      includes:$includes, excludes:$excludes,
      entry:(if $entry == "" then null else $entry end), files:$files,
      combined_bytes:$combined_bytes,
      resume_identity:null,
      artifact_integrity:{
        algorithm:"sha256",
        combined_spec:{
          path:"combined-spec.md",
          bytes:$combined_bytes,
          sha256:$combined_sha256
        },
        base_combined_spec:null,
        spec_diff:null,
        resume_metadata:null
      }}' > "$temp_output"; then
    rm -f "$temp_output"
    SPEC_BUNDLE_ERROR="Unable to serialize specification manifest"
    return 1
  fi
  mv "$temp_output" "$output"
}

spec_manifest_record_artifact() {
  local manifest="$1" key="$2" artifact="$3" persisted_path="$4"
  local bytes sha256 temp_output
  SPEC_BUNDLE_ERROR=""

  case "$key" in
    combined_spec|base_combined_spec|spec_diff) ;;
    *)
      SPEC_BUNDLE_ERROR="Unknown specification integrity artifact key: $key"
      return 1
      ;;
  esac
  if [[ ! -f "$manifest" || -L "$manifest" ]]; then
    SPEC_BUNDLE_ERROR="Cannot update specification integrity metadata through a missing or symlink manifest: $manifest"
    return 1
  fi
  if ! jq -e '
    (.schema_version == 2 or .schema_version == 3)
    and .artifact_integrity.algorithm == "sha256"
  ' "$manifest" >/dev/null 2>&1; then
    SPEC_BUNDLE_ERROR="Cannot update invalid specification integrity manifest: $manifest"
    return 1
  fi

  bytes="$(wc -c < "$artifact")" || {
    SPEC_BUNDLE_ERROR="Unable to measure specification artifact: $artifact"
    return 1
  }
  spec_sha256_file "$artifact" || return 1
  sha256="$SPEC_SHA256_VALUE"
  temp_output="$(mktemp "${manifest}.tmp.XXXXXX")" || {
    SPEC_BUNDLE_ERROR="Unable to allocate a temporary specification manifest"
    return 1
  }
  if ! jq \
    --arg key "$key" \
    --arg path "$persisted_path" \
    --argjson bytes "$bytes" \
    --arg sha256 "$sha256" \
    '.artifact_integrity[$key] = {
      path:$path,
      bytes:$bytes,
      sha256:$sha256
    }' "$manifest" > "$temp_output"; then
    rm -f "$temp_output"
    SPEC_BUNDLE_ERROR="Unable to add $persisted_path integrity metadata to $manifest"
    return 1
  fi
  mv "$temp_output" "$manifest" || {
    rm -f "$temp_output"
    SPEC_BUNDLE_ERROR="Unable to persist $persisted_path integrity metadata to $manifest"
    return 1
  }
}

spec_manifest_verify_artifact() {
  local manifest="$1" key="$2" artifact="$3" persisted_path="$4"
  local description="${5:-$persisted_path}"
  local expected_path expected_bytes expected_sha256 actual_bytes actual_sha256
  SPEC_BUNDLE_ERROR=""

  case "$key" in
    combined_spec|base_combined_spec|spec_diff|resume_metadata) ;;
    *)
      SPEC_BUNDLE_ERROR="Unknown specification integrity artifact key: $key"
      return 1
      ;;
  esac
  if [[ ! -f "$manifest" || -L "$manifest" ]]; then
    SPEC_BUNDLE_ERROR="Persisted specification manifest is missing or is not a regular file: $manifest. Restore the original manifest or start a new run."
    return 1
  fi
  if ! jq -e --arg key "$key" '
    (.schema_version == 2 or .schema_version == 3)
    and .artifact_integrity.algorithm == "sha256"
    and (.artifact_integrity[$key] | type == "object")
    and (.artifact_integrity[$key].path | type == "string")
    and (.artifact_integrity[$key].bytes | type == "number")
    and (.artifact_integrity[$key].sha256
      | type == "string" and test("^[0-9a-f]{64}$"))
  ' "$manifest" >/dev/null 2>&1; then
    SPEC_BUNDLE_ERROR="Persisted specification manifest has no valid SHA-256 integrity metadata for $description; cannot resume safely. Start a new run."
    return 1
  fi

  expected_path="$(jq -r --arg key "$key" '.artifact_integrity[$key].path' "$manifest")"
  if [[ "$expected_path" != "$persisted_path" ]]; then
    SPEC_BUNDLE_ERROR="Persisted specification manifest maps $description to '$expected_path', expected '$persisted_path'; cannot resume safely. Start a new run."
    return 1
  fi
  expected_bytes="$(jq -r --arg key "$key" '.artifact_integrity[$key].bytes' "$manifest")"
  expected_sha256="$(jq -r --arg key "$key" '.artifact_integrity[$key].sha256' "$manifest")"
  if [[ ! -f "$artifact" || -L "$artifact" ]]; then
    SPEC_BUNDLE_ERROR="Persisted $description is missing or is not a regular file: $artifact. Restore the original artifact or start a new run."
    return 1
  fi
  actual_bytes="$(wc -c < "$artifact")" || {
    SPEC_BUNDLE_ERROR="Unable to measure persisted $description: $artifact"
    return 1
  }
  if [[ "$actual_bytes" != "$expected_bytes" ]]; then
    SPEC_BUNDLE_ERROR="Persisted $description is corrupt: byte length changed for $artifact (expected $expected_bytes, got $actual_bytes). Restore the original artifact or start a new run."
    return 1
  fi
  spec_sha256_file "$artifact" || return 1
  actual_sha256="$SPEC_SHA256_VALUE"
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    SPEC_BUNDLE_ERROR="Persisted $description is corrupt: SHA-256 mismatch for $artifact (expected $expected_sha256, got $actual_sha256). Restore the original artifact or start a new run."
    return 1
  fi
}

# Copy a persisted artifact into an invocation-private regular file and verify
# the copied bytes. Downstream consumers use only the verified snapshot, so a
# source replacement after verification cannot change what reaches the model.
spec_snapshot_regular_file() {
  local source="$1" destination="$2" description="${3:-file}" temp_output
  SPEC_BUNDLE_ERROR=""

  if [[ ! -f "$source" || -L "$source" ]]; then
    SPEC_BUNDLE_ERROR="Persisted $description is missing or is not a regular non-symlink file: $source"
    return 1
  fi
  if [[ -e "$destination" || -L "$destination" ]]; then
    SPEC_BUNDLE_ERROR="Refusing to overwrite an existing resume snapshot: $destination"
    return 1
  fi
  temp_output="$(mktemp "${destination}.tmp.XXXXXX")" || {
    SPEC_BUNDLE_ERROR="Unable to allocate a private snapshot for $description"
    return 1
  }
  chmod 600 "$temp_output" || {
    rm -f "$temp_output"
    SPEC_BUNDLE_ERROR="Unable to protect the private snapshot for $description"
    return 1
  }
  if ! cp -- "$source" "$temp_output"; then
    rm -f "$temp_output"
    SPEC_BUNDLE_ERROR="Unable to snapshot persisted $description: $source"
    return 1
  fi
  mv "$temp_output" "$destination" || {
    rm -f "$temp_output"
    SPEC_BUNDLE_ERROR="Unable to publish the private snapshot for $description"
    return 1
  }
}

spec_manifest_snapshot_artifact() {
  local manifest="$1" key="$2" source="$3" persisted_path="$4"
  local destination="$5" description="${6:-$persisted_path}"
  local temp_output
  SPEC_BUNDLE_ERROR=""

  if [[ ! -f "$source" || -L "$source" ]]; then
    SPEC_BUNDLE_ERROR="Persisted $description is missing or is not a regular non-symlink file: $source. Restore the original artifact or start a new run."
    return 1
  fi
  if [[ -e "$destination" || -L "$destination" ]]; then
    SPEC_BUNDLE_ERROR="Refusing to overwrite an existing resume snapshot: $destination"
    return 1
  fi
  temp_output="$(mktemp "${destination}.tmp.XXXXXX")" || {
    SPEC_BUNDLE_ERROR="Unable to allocate a private snapshot for $description"
    return 1
  }
  chmod 600 "$temp_output" || {
    rm -f "$temp_output"
    SPEC_BUNDLE_ERROR="Unable to protect the private snapshot for $description"
    return 1
  }
  if ! cp -- "$source" "$temp_output"; then
    rm -f "$temp_output"
    SPEC_BUNDLE_ERROR="Unable to snapshot persisted $description: $source"
    return 1
  fi
  if ! spec_manifest_verify_artifact \
    "$manifest" "$key" "$temp_output" "$persisted_path" "$description"; then
    rm -f "$temp_output"
    return 1
  fi
  mv "$temp_output" "$destination" || {
    rm -f "$temp_output"
    SPEC_BUNDLE_ERROR="Unable to publish the verified snapshot for $description"
    return 1
  }
}

# Bind the resume selection identity to the content manifest and record the
# exact resume-metadata bytes. This consistency check protects frozen input
# selection from accidental drift; it is not an authorization or execution
# boundary and carries no such fields.
spec_manifest_record_resume_identity() {
  local manifest="$1" metadata="$2"
  local identity metadata_bytes metadata_sha256 temp_output
  SPEC_BUNDLE_ERROR=""

  if [[ ! -f "$manifest" || -L "$manifest" ]]; then
    SPEC_BUNDLE_ERROR="Cannot bind resume identity through a missing or symlink manifest: $manifest"
    return 1
  fi
  if [[ ! -f "$metadata" || -L "$metadata" ]]; then
    SPEC_BUNDLE_ERROR="Cannot bind missing or symlink bundle resume metadata: $metadata"
    return 1
  fi
  if ! jq -e '
    .schema_version == 3
    and .artifact_integrity.algorithm == "sha256"
  ' "$manifest" >/dev/null 2>&1; then
    SPEC_BUNDLE_ERROR="Cannot bind resume identity to an invalid specification manifest: $manifest"
    return 1
  fi
  if ! jq -e '
    .schema_version == 3
    and (keys | sort) == ["mode", "schema_version", "specification"]
    and (.mode == "greenfield" or .mode == "spec-change")
    and (.specification.kind == "directory")
    and (.specification.root | type == "string" and length > 0)
    and (.specification.entry == null or (.specification.entry | type == "string"))
    and (.specification.includes | type == "array"
      and all(.[]; type == "string"))
    and (.specification.excludes | type == "array"
      and all(.[]; type == "string"))
    and (.specification.spec_base | type == "string" and length > 0)
  ' "$metadata" >/dev/null 2>&1; then
    SPEC_BUNDLE_ERROR="Cannot bind invalid bundle resume metadata: $metadata"
    return 1
  fi

  if ! jq -e --slurpfile metadata "$metadata" '
    .root == $metadata[0].specification.root
    and .entry == $metadata[0].specification.entry
    and .includes == $metadata[0].specification.includes
    and .excludes == $metadata[0].specification.excludes
  ' "$manifest" >/dev/null 2>&1; then
    SPEC_BUNDLE_ERROR="Bundle resume metadata does not match the specification manifest selection"
    return 1
  fi

  identity="$(jq -c '{
    mode,
    spec_base:.specification.spec_base
  }' "$metadata")" || return 1
  metadata_bytes="$(wc -c < "$metadata")" || {
    SPEC_BUNDLE_ERROR="Unable to measure bundle resume metadata: $metadata"
    return 1
  }
  spec_sha256_file "$metadata" || return 1
  metadata_sha256="$SPEC_SHA256_VALUE"
  temp_output="$(mktemp "${manifest}.tmp.XXXXXX")" || {
    SPEC_BUNDLE_ERROR="Unable to allocate a temporary specification manifest"
    return 1
  }
  if ! jq \
    --argjson identity "$identity" \
    --argjson bytes "$metadata_bytes" \
    --arg sha256 "$metadata_sha256" \
    '.resume_identity = $identity
      | .artifact_integrity.resume_metadata = {
          path:"resume-metadata.json",
          bytes:$bytes,
          sha256:$sha256
        }' "$manifest" > "$temp_output"; then
    rm -f "$temp_output"
    SPEC_BUNDLE_ERROR="Unable to bind bundle resume identity to $manifest"
    return 1
  fi
  mv "$temp_output" "$manifest" || {
    rm -f "$temp_output"
    SPEC_BUNDLE_ERROR="Unable to persist bundle resume identity in $manifest"
    return 1
  }
}

# Verify and load a schema-3 selection identity. Execution routing and --yes are
# intentionally absent and must be supplied by the current CLI invocation.
# Schema-2 manifests are intentionally handled as legacy by the caller.
spec_manifest_verify_resume_identity() {
  local manifest="$1" metadata="$2"
  local manifest_identity metadata_identity
  SPEC_BUNDLE_ERROR=""

  if [[ ! -f "$manifest" || -L "$manifest" ]]; then
    SPEC_BUNDLE_ERROR="Persisted specification manifest is missing or is a symlink: $manifest. Start a new run."
    return 1
  fi
  if [[ ! -f "$metadata" || -L "$metadata" ]]; then
    SPEC_BUNDLE_ERROR="Persisted bundle resume metadata is missing or is a symlink: $metadata. Start a new run."
    return 1
  fi
  if ! jq -e '.schema_version == 3' "$manifest" >/dev/null 2>&1; then
    SPEC_BUNDLE_ERROR="Persisted specification manifest does not carry integrity-bound resume selection metadata: $manifest"
    return 1
  fi

  spec_manifest_verify_artifact \
    "$manifest" "resume_metadata" "$metadata" "resume-metadata.json" \
    "bundle resume metadata" || return 1
  spec_load_resume_metadata "$metadata" || return 1

  manifest_identity="$(jq -S -c '.resume_identity' "$manifest")" || return 1
  metadata_identity="$(jq -S -c '{
    mode,
    spec_base:.specification.spec_base
  }' "$metadata")" || return 1
  if [[ "$manifest_identity" != "$metadata_identity" ]]; then
    SPEC_BUNDLE_ERROR="Persisted bundle resume selection identity does not match the integrity manifest; cannot resume safely. Start a new run."
    return 1
  fi
  if ! jq -e --slurpfile metadata "$metadata" '
    .root == $metadata[0].specification.root
    and .entry == $metadata[0].specification.entry
    and .includes == $metadata[0].specification.includes
    and .excludes == $metadata[0].specification.excludes
  ' "$manifest" >/dev/null 2>&1; then
    SPEC_BUNDLE_ERROR="Persisted bundle selection metadata does not match the integrity manifest; cannot resume safely. Start a new run."
    return 1
  fi
}

# Validate mode-dependent artifact shape and, when present, the run summary's
# duplicate bundle selection identity. Summary absence is valid for
# interruptions that occurred before the confirmation gates initialized it.
spec_manifest_validate_resume_shape() {
  local manifest="$1" summary="${2:-}" manifest_path="${3:-$1}"
  SPEC_BUNDLE_ERROR=""

  if ! jq -e '
    (.resume_identity.mode == "greenfield"
      and .artifact_integrity.base_combined_spec == null
      and .artifact_integrity.spec_diff == null)
    or
    (.resume_identity.mode == "spec-change"
      and (.artifact_integrity.base_combined_spec | type == "object")
      and (.artifact_integrity.spec_diff | type == "object"))
  ' "$manifest" >/dev/null 2>&1; then
    SPEC_BUNDLE_ERROR="Persisted specification artifacts do not match the resumed mode: $manifest"
    return 1
  fi

  [[ -e "$summary" || -L "$summary" ]] || return 0
  if [[ ! -f "$summary" || -L "$summary" ]]; then
    SPEC_BUNDLE_ERROR="Persisted run summary is not a regular non-symlink file: $summary"
    return 1
  fi
  if ! jq -e \
    --arg manifest_path "$manifest_path" \
    --slurpfile manifest "$manifest" '
      .mode == $manifest[0].resume_identity.mode
      and .spec == null
      and .spec_set.kind == "directory"
      and .spec_set.root == $manifest[0].root
      and .spec_set.manifest == $manifest_path
      and .spec_set.file_count == ($manifest[0].files | length)
      and .spec_set.combined_bytes == $manifest[0].combined_bytes
      and .spec_set.artifact_integrity == $manifest[0].artifact_integrity
  ' "$summary" >/dev/null 2>&1; then
    SPEC_BUNDLE_ERROR="Persisted run summary does not match the frozen bundle selection identity: $summary"
    return 1
  fi
}

spec_manifest_matches_options() {
  local manifest="$1" root="$2" entry="$3"
  local expected_includes expected_excludes persisted_entry schema_version
  SPEC_BUNDLE_ERROR=""

  jq -e '
    .kind == "directory"
    and (.root | type == "string")
    and (.includes | type == "array")
    and (.excludes | type == "array")
    and (.files | type == "array")
    and (.combined_bytes | type == "number")
    and all(.files[];
      (.path | type == "string")
      and (.bytes | type == "number")
      and (.order | type == "number"))
  ' "$manifest" >/dev/null 2>&1 || {
    SPEC_BUNDLE_ERROR="Persisted specification manifest is invalid: $manifest"
    return 1
  }
  if ! jq -e '
    has("schema_version") and has("artifact_integrity")
  ' "$manifest" >/dev/null 2>&1; then
    SPEC_BUNDLE_ERROR="Persisted specification manifest predates SHA-256 artifact integrity metadata and cannot be resumed safely: $manifest. Start a new run."
    return 1
  fi
  schema_version="$(jq -r '.schema_version' "$manifest")"
  if [[ "$schema_version" != "2" && "$schema_version" != "3" ]]; then
    SPEC_BUNDLE_ERROR="Unsupported persisted specification manifest schema version '$schema_version' in $manifest. Start a new run."
    return 1
  fi
  if ! jq -e --argjson schema_version "$schema_version" '
    def artifact:
      type == "object"
      and (.path | type == "string")
      and (.bytes | type == "number" and . >= 0)
      and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"));
    .artifact_integrity.algorithm == "sha256"
    and (.artifact_integrity.combined_spec | artifact)
    and ((.artifact_integrity.base_combined_spec == null)
      or (.artifact_integrity.base_combined_spec | artifact))
    and ((.artifact_integrity.spec_diff == null)
      or (.artifact_integrity.spec_diff | artifact))
    and ($schema_version == 2 or (
      (.artifact_integrity.resume_metadata | artifact)
      and (.resume_identity | type == "object")
      and (.resume_identity.mode == "greenfield"
        or .resume_identity.mode == "spec-change")
      and (.resume_identity.spec_base | type == "string" and length > 0)
      and (.resume_identity | keys | sort) == ["mode", "spec_base"]
    ))
    and (.combined_bytes == .artifact_integrity.combined_spec.bytes)
  ' "$manifest" >/dev/null 2>&1; then
    SPEC_BUNDLE_ERROR="Persisted specification manifest has invalid SHA-256 artifact integrity metadata: $manifest"
    return 1
  fi

  if [[ "$(jq -r '.root' "$manifest")" != "$root" ]]; then
    SPEC_BUNDLE_ERROR="Resume --spec-dir does not match the persisted specification root"
    return 1
  fi
  persisted_entry="$(jq -r '.entry // ""' "$manifest")"
  if [[ "$persisted_entry" != "$entry" ]]; then
    SPEC_BUNDLE_ERROR="Resume --spec-entry does not match the persisted specification manifest"
    return 1
  fi
  expected_includes="$(jq -cn --args '$ARGS.positional' -- "${SPEC_GLOBS[@]}")" || return 1
  expected_excludes="$(jq -cn --args '$ARGS.positional' -- "${SPEC_EXCLUDES[@]}")" || return 1
  if [[ "$(jq -c '.includes' "$manifest")" != "$expected_includes" ]]; then
    SPEC_BUNDLE_ERROR="Resume --spec-glob values do not match the persisted specification manifest"
    return 1
  fi
  if [[ "$(jq -c '.excludes' "$manifest")" != "$expected_excludes" ]]; then
    SPEC_BUNDLE_ERROR="Resume --spec-exclude values do not match the persisted specification manifest"
    return 1
  fi
}

spec_load_manifest_files() {
  local manifest="$1" rel expected_order=0
  SPEC_BUNDLE_FILES=()
  while IFS= read -r -d '' rel; do
    spec_validate_resolved_path "$rel" || return 1
    SPEC_BUNDLE_FILES+=("$rel")
  done < <(jq -j '.files[] | .path, "\u0000"' "$manifest")

  if [[ "${#SPEC_BUNDLE_FILES[@]}" -ne "$(jq -r '.files | length' "$manifest")" ]]; then
    SPEC_BUNDLE_ERROR="Persisted specification manifest contains unreadable file paths"
    return 1
  fi
  while IFS= read -r order; do
    if [[ "$order" != "$expected_order" ]]; then
      # shellcheck disable=SC2034 # Output consumed by callers sourcing this library.
      SPEC_BUNDLE_ERROR="Persisted specification manifest has invalid file ordering"
      return 1
    fi
    expected_order=$((expected_order + 1))
  done < <(jq -r '.files[].order' "$manifest")
}
