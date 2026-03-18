#!/usr/bin/env bash
set -euo pipefail

REAL_HDIUTIL="${ELECTROBUN_REAL_HDIUTIL:-/usr/bin/hdiutil}"

cleanup_create_state() {
  local volume_name=""
  local target_path=""
  local args=("$@")
  local index=0

  while [[ $index -lt ${#args[@]} ]]; do
    local arg="${args[$index]}"
    case "$arg" in
      -volname)
        ((index += 1))
        if [[ $index -lt ${#args[@]} ]]; then
          volume_name="${args[$index]}"
        fi
        ;;
    esac
    ((index += 1))
  done

  if [[ ${#args[@]} -gt 0 ]]; then
    local last_index=$((${#args[@]} - 1))
    target_path="${args[$last_index]}"
  fi

  if [[ -n "$target_path" ]]; then
    rm -f "$target_path" 2>/dev/null || true
  fi

  if [[ -n "$volume_name" ]]; then
    "$REAL_HDIUTIL" detach "/Volumes/$volume_name" >/dev/null 2>&1 || true
  fi
}

if [[ "${1:-}" == "create" ]]; then
  attempts=5
  delay=5
  last_status=0
  last_output=""

  for ((attempt=1; attempt<=attempts; attempt++)); do
    cleanup_create_state "$@"
    if output="$("$REAL_HDIUTIL" "$@" 2>&1)"; then
      [[ -n "$output" ]] && printf '%s\n' "$output"
      exit 0
    fi

    last_status=$?
    last_output="$output"
    printf '%s\n' "$output" >&2

    if [[ "$output" != *"Resource busy"* || "$attempt" -eq "$attempts" ]]; then
      break
    fi

    echo "hdiutil create attempt $attempt/$attempts failed with Resource busy; retrying in ${delay}s..." >&2
    sleep "$delay"
  done

  exit "$last_status"
fi

exec "$REAL_HDIUTIL" "$@"
