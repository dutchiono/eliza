#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELECTROBUN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ELECTROBUN_DIR/artifacts}"
BUILD_DIR="${BUILD_DIR:-$ELECTROBUN_DIR/build}"

declare -a SEARCH_DIRS=()
if [[ -d "$ARTIFACTS_DIR" ]]; then
  SEARCH_DIRS+=("$ARTIFACTS_DIR")
fi
if [[ -d "$BUILD_DIR" ]]; then
  SEARCH_DIRS+=("$BUILD_DIR")
fi

if [[ ${#SEARCH_DIRS[@]} -eq 0 ]]; then
  echo "::error::No output directories found (checked $ARTIFACTS_DIR and $BUILD_DIR)."
  exit 1
fi

echo "============================================================"
echo " Eliza Home Electrobun Linux Smoke Test"
echo " Search dirs: ${SEARCH_DIRS[*]}"
echo "============================================================"
echo ""
echo "Artifact inventory:"
find "${SEARCH_DIRS[@]}" -type f | sort || true
echo ""

find_first_by_pattern() {
  local pattern="$1"
  local excluded_pattern="${2:-}"
  local candidate=""
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if [[ -n "$excluded_pattern" && "$(basename "$candidate")" == $excluded_pattern ]]; then
      continue
    fi
    if [[ -s "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done < <(find "${SEARCH_DIRS[@]}" -type f -name "$pattern" 2>/dev/null | sort)
  return 1
}

SELECTED_ARTIFACT=""
SELECTED_KIND=""

if SELECTED_ARTIFACT="$(find_first_by_pattern "*.AppImage")"; then
  SELECTED_KIND="appimage"
elif SELECTED_ARTIFACT="$(find_first_by_pattern "*.tar.zst" "*Setup*")"; then
  SELECTED_KIND="archive"
elif SELECTED_ARTIFACT="$(find_first_by_pattern "*.tar.gz" "*Setup*")"; then
  SELECTED_KIND="archive"
elif SELECTED_ARTIFACT="$(find_first_by_pattern "*Setup*.tar.zst")"; then
  SELECTED_KIND="setup-archive"
elif SELECTED_ARTIFACT="$(find_first_by_pattern "*Setup*.tar.gz")"; then
  SELECTED_KIND="setup-archive"
else
  echo "::error::No Linux launchable artifact found (.AppImage, *Setup*.tar.{zst,gz}, or *.tar.{zst,gz})."
  exit 1
fi

echo "Selected artifact kind : $SELECTED_KIND"
echo "Selected artifact path : $SELECTED_ARTIFACT"

if [[ "$SELECTED_KIND" == "appimage" ]]; then
  echo "Linux smoke check PASSED with AppImage artifact."
  exit 0
fi

if [[ "$SELECTED_ARTIFACT" == *.tar.zst ]]; then
  list_cmd=(tar --zstd -tf "$SELECTED_ARTIFACT")
else
  list_cmd=(tar -tzf "$SELECTED_ARTIFACT")
fi

mapfile -t archive_members < <("${list_cmd[@]}")
if [[ ${#archive_members[@]} -eq 0 ]]; then
  echo "::error::Selected archive is empty or unreadable: $SELECTED_ARTIFACT"
  exit 1
fi

member_blob="$(printf '%s\n' "${archive_members[@]}")"

has_member_regex() {
  local regex="$1"
  grep -Eq "$regex" <<<"$member_blob"
}

require_member_regex() {
  local regex="$1"
  local description="$2"
  if ! has_member_regex "$regex"; then
    echo "::error::Missing ${description} in $SELECTED_ARTIFACT"
    exit 1
  fi
}

if [[ "$SELECTED_KIND" == "setup-archive" ]]; then
  require_member_regex '(^|/)(launcher|launcher\.exe)$' "packaged launcher binary"
  require_member_regex '(^|/)(resources/)?app/.+|(^|/)Resources/.+|(^|/).+\.desktop$' "packaged app payload markers"
  echo "Linux smoke check PASSED with setup archive artifact."
  exit 0
fi

if has_member_regex '(^|/)(renderer/)?index\.html$' &&
  has_member_regex '(^|/)(renderer/)?assets/.+\.(js|css)$' &&
  has_member_regex '(^|/)home-dist/(bin\.js|entry\.js|packages/autonomous/src/bin\.js)$' &&
  has_member_regex '(^|/)home-dist/node_modules/@elizaos/core/package\.json$' &&
  has_member_regex '(^|/)home-dist/node_modules/@elizaos/core/dist/node/index\.node\.js$'; then
  echo "Linux smoke check PASSED with direct runtime archive artifact."
  exit 0
fi

if has_member_regex '(^|/)bin/launcher$' &&
  has_member_regex '(^|/)(Resources|resources)/.+\.tar\.zst$' &&
  has_member_regex '(^|/)(Resources|resources)/version\.json$'; then
  echo "Linux smoke check PASSED with wrapper archive artifact."
  exit 0
fi

echo "::error::Linux archive did not match expected direct runtime or wrapper archive layout: $SELECTED_ARTIFACT"
echo "First 80 archive entries for diagnostics:"
printf '%s\n' "${archive_members[@]}" | sed -n '1,80p'
exit 1
