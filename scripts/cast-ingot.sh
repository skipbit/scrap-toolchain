#!/usr/bin/env bash
# cast-ingot.sh — Validate a mold definition by downloading and verifying the binary
#
# For fetch-type molds, this script downloads the upstream binary, verifies its
# integrity (SHA256), checks the layout, license files, glibc compatibility,
# and runs a smoke test. No ingot archive is produced.
#
# For build-type molds, ingot production is handled separately.
#
# Usage: cast-ingot.sh <mold-directory> <platform> <arch>
#
# Environment variables:
#   WORK_DIR    — Base directory for temporary files (default: /tmp/cast-ingot)
#   OUTPUT_DIR  — Output directory for ingot artifacts (default: ./output)
#
# Exit codes:
#   0 = Validation passed
#   1 = Test error (smoke test failure)
#   2 = Validation error (SHA256 mismatch, missing license, unsupported platform)
#   3 = Internal error (missing tools, unsupported source type)

set -euo pipefail

MOLD_DIR="${1:?Usage: cast-ingot.sh <mold-directory> <platform> <arch>}"
PLATFORM="${2:?Usage: cast-ingot.sh <mold-directory> <platform> <arch>}"
ARCH="${3:?Usage: cast-ingot.sh <mold-directory> <platform> <arch>}"
MOLD_DIR="${MOLD_DIR%/}"

BASE_WORK_DIR="${WORK_DIR:-/tmp/cast-ingot}"
OUTPUT_DIR="${OUTPUT_DIR:-./output}"

MAX_DL_RETRIES=3
GLIBC_BASELINE=$(python3 -c "
try:
    import tomllib
except ImportError:
    import tomli as tomllib
import sys
with open(sys.argv[1], 'rb') as f:
    data = tomllib.load(f)
print(data.get('source', {}).get('glibc_min', '2.31'))
" "${MOLD_DIR}/mold.toml" 2>/dev/null || echo "2.31")

# --- Colors (disabled if not a terminal) ---
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BOLD=''
    RESET=''
fi

pass() { echo -e "  ${GREEN}PASS${RESET}: $1"; }
fail() { echo -e "  ${RED}FAIL${RESET}: $1"; }
warn() { echo -e "  ${YELLOW}WARN${RESET}: $1"; }
info() { echo -e "  ${BOLD}INFO${RESET}: $1"; }

compute_sha256() {
    if command -v sha256sum &>/dev/null; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# Resolve a path to its canonical form (resolves symlinks).
# Portable across Linux and macOS via Python.
resolve_path() {
    python3 -c "import os, sys; print(os.path.realpath(sys.argv[1]))" "$1"
}

SUMMARY_MD=""
add_summary() { SUMMARY_MD+="$1"$'\n'; }

# Cleanup on exit
RUN_DIR=""
cleanup() {
    if [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]]; then
        rm -rf "$RUN_DIR"
    fi
}
trap cleanup EXIT

mkdir -p "$BASE_WORK_DIR" "$OUTPUT_DIR"
RUN_DIR=$(mktemp -d "${BASE_WORK_DIR}/run-XXXXXXXX")

# --- Pre-flight checks ---
echo -e "${BOLD}Pre-flight checks${RESET}"

for cmd in python3 curl jq tar xz; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: $cmd is not installed"
        exit 3
    fi
done

if ! command -v sha256sum &>/dev/null && ! command -v shasum &>/dev/null; then
    echo "Error: sha256sum or shasum is required"
    exit 3
fi

if ! python3 -c "try:
    import tomllib
except ImportError:
    import tomli" 2>/dev/null; then
    echo "Error: Python 3.11+ (tomllib) or tomli package is required"
    exit 3
fi

READELF_AVAILABLE=false
if [[ "$PLATFORM" == "linux" ]]; then
    if command -v readelf &>/dev/null; then
        READELF_AVAILABLE=true
    else
        warn "readelf is not available; glibc compatibility check will be skipped"
    fi
fi

MOLD_TOML="${MOLD_DIR}/mold.toml"
if [[ ! -f "$MOLD_TOML" ]]; then
    echo "Error: ${MOLD_TOML} not found"
    exit 3
fi

pass "Prerequisites satisfied"
echo ""

add_summary "## cast-ingot: ${MOLD_DIR} (${PLATFORM}-${ARCH})"
add_summary ""

# --- Step 1: Parse mold.toml ---
echo -e "${BOLD}1. Parse mold.toml${RESET}"

MOLD_JSON="${RUN_DIR}/mold.json"

set +e
python3 -c "
try:
    import tomllib
except ImportError:
    import tomli as tomllib
import json, sys
with open(sys.argv[1], 'rb') as f:
    data = tomllib.load(f)
with open(sys.argv[2], 'w') as out:
    json.dump(data, out)
" "$MOLD_TOML" "$MOLD_JSON" 2>"${RUN_DIR}/parse_stderr"
PARSE_EXIT=$?
set -e

if [[ "$PARSE_EXIT" -ne 0 ]]; then
    PARSE_ERROR=$(cat "${RUN_DIR}/parse_stderr")
    fail "Failed to parse mold.toml: ${PARSE_ERROR}"
    exit 3
fi

SOURCE_TYPE=$(jq -r '.source.type // empty' "$MOLD_JSON")
FAMILY=$(jq -r '.metadata.family // empty' "$MOLD_JSON")
VERSION=$(jq -r '.metadata.version // empty' "$MOLD_JSON")

if [[ -z "$FAMILY" || -z "$VERSION" ]]; then
    fail "Missing metadata.family or metadata.version"
    exit 3
fi

if [[ "$SOURCE_TYPE" == "build" ]]; then
    fail "Build type is not supported in this version"
    exit 3
fi

if [[ "$SOURCE_TYPE" != "fetch" ]]; then
    fail "Unknown source type: ${SOURCE_TYPE}"
    exit 3
fi

# Reject fetch-type molds with patches defined (patches not supported for fetch type)
PATCHES_COUNT=$(jq '.patches // [] | length' "$MOLD_JSON")
if [[ "$PATCHES_COUNT" -gt 0 ]]; then
    fail "Fetch-type molds must not define patches"
    exit 2
fi

pass "Parsed: ${FAMILY} ${VERSION} (source.type = ${SOURCE_TYPE})"
echo ""

# --- Step 2: Find binary entry for platform/arch ---
echo -e "${BOLD}2. Find binary entry for ${PLATFORM}-${ARCH}${RESET}"

BINARY_ENTRY=$(jq -c --arg p "$PLATFORM" --arg a "$ARCH" \
    '[.source.binaries[] | select(.platform == $p and .arch == $a)] | first // empty' \
    "$MOLD_JSON" 2>/dev/null)

if [[ -z "$BINARY_ENTRY" ]]; then
    BF_ENABLED=$(jq -r '.source.build_fallback.enabled // false' "$MOLD_JSON")
    if [[ "$BF_ENABLED" == "true" ]]; then
        fail "No binary for ${PLATFORM}-${ARCH}; build_fallback is not yet supported"
        exit 3
    fi
    fail "No binary entry found for ${PLATFORM}-${ARCH}"
    exit 2
fi

DL_URL=$(echo "$BINARY_ENTRY" | jq -r '.url')
EXPECTED_SHA=$(echo "$BINARY_ENTRY" | jq -r '.sha256')
STRIP_COMPONENTS=$(echo "$BINARY_ENTRY" | jq -r '.strip_components // 1')
ROOT_DIR=$(echo "$BINARY_ENTRY" | jq -r '.root_dir // empty')

if [[ -z "$DL_URL" || "$DL_URL" == "null" || -z "$EXPECTED_SHA" || "$EXPECTED_SHA" == "null" ]]; then
    fail "Incomplete binary entry: missing url or sha256"
    exit 2
fi

# Validate strip_components is a non-negative integer
if ! [[ "$STRIP_COMPONENTS" =~ ^[0-9]+$ ]]; then
    fail "Invalid strip_components value: ${STRIP_COMPONENTS}"
    exit 2
fi

pass "Binary found: ${DL_URL}"
info "SHA256: ${EXPECTED_SHA}"
info "strip_components: ${STRIP_COMPONENTS}"
[[ -n "$ROOT_DIR" ]] && info "root_dir: ${ROOT_DIR}"
echo ""

# --- Step 3: Download archive ---
echo -e "${BOLD}3. Download archive${RESET}"

DL_FILE="${RUN_DIR}/archive"
# Extract filename from URL (strip query parameters)
DL_FILENAME=$(basename "${DL_URL%%\?*}")
info "Downloading: ${DL_FILENAME}"

DL_SUCCESS=false
for attempt in $(seq 1 "$MAX_DL_RETRIES"); do
    set +e
    curl -fSL --max-time 600 -o "$DL_FILE" "$DL_URL" 2>"${RUN_DIR}/dl_stderr"
    DL_EXIT=$?
    set -e

    if [[ "$DL_EXIT" -eq 0 && -f "$DL_FILE" ]]; then
        DL_SUCCESS=true
        break
    fi

    if [[ "$attempt" -lt "$MAX_DL_RETRIES" ]]; then
        DL_ERROR=$(cat "${RUN_DIR}/dl_stderr")
        warn "Download attempt ${attempt}/${MAX_DL_RETRIES} failed: ${DL_ERROR}"
        sleep 5
    fi
done

if [[ "$DL_SUCCESS" != "true" ]]; then
    fail "Download failed after ${MAX_DL_RETRIES} attempts"
    add_summary "- :x: Download failed: ${DL_URL}"
    exit 2
fi

DL_SIZE=$(wc -c < "$DL_FILE" | tr -d ' ')
pass "Downloaded (${DL_SIZE} bytes)"
echo ""

# --- Step 4: SHA256 verification ---
echo -e "${BOLD}4. SHA256 verification${RESET}"

ACTUAL_SHA=$(compute_sha256 "$DL_FILE")
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
    fail "SHA256 mismatch: expected=${EXPECTED_SHA} actual=${ACTUAL_SHA}"
    add_summary "- :x: SHA256 mismatch"
    exit 2
fi

pass "SHA256 verified"
echo ""

# --- Step 5: Extract archive ---
echo -e "${BOLD}5. Extract archive${RESET}"

EXTRACT_DIR="${RUN_DIR}/extract"
mkdir -p "$EXTRACT_DIR"

case "$DL_FILENAME" in
    *.tar.xz | *.txz)
        tar -xJf "$DL_FILE" --strip-components="$STRIP_COMPONENTS" -C "$EXTRACT_DIR"
        ;;
    *.tar.gz | *.tgz)
        tar -xzf "$DL_FILE" --strip-components="$STRIP_COMPONENTS" -C "$EXTRACT_DIR"
        ;;
    *.tar.bz2 | *.tbz2)
        tar -xjf "$DL_FILE" --strip-components="$STRIP_COMPONENTS" -C "$EXTRACT_DIR"
        ;;
    *.tar)
        tar -xf "$DL_FILE" --strip-components="$STRIP_COMPONENTS" -C "$EXTRACT_DIR"
        ;;
    *)
        fail "Unsupported archive format: ${DL_FILENAME}"
        exit 3
        ;;
esac

# Apply root_dir if specified
CONTENT_DIR="$EXTRACT_DIR"
if [[ -n "$ROOT_DIR" ]]; then
    # Reject path traversal in root_dir
    if [[ "$ROOT_DIR" == /* || "$ROOT_DIR" == ../* || \
          "$ROOT_DIR" == */../* || "$ROOT_DIR" == */.. || \
          "$ROOT_DIR" == .. ]]; then
        fail "root_dir contains traversal or is absolute: ${ROOT_DIR}"
        exit 2
    fi
    if [[ -d "${EXTRACT_DIR}/${ROOT_DIR}" ]]; then
        # Verify canonical path is within the extraction directory
        ROOT_REAL=$(resolve_path "${EXTRACT_DIR}/${ROOT_DIR}")
        EXTRACT_REAL=$(resolve_path "$EXTRACT_DIR")
        if [[ "$ROOT_REAL" != "${EXTRACT_REAL}"* ]]; then
            fail "root_dir resolves outside extraction directory: ${ROOT_DIR}"
            exit 2
        fi
        CONTENT_DIR="${EXTRACT_DIR}/${ROOT_DIR}"
    else
        fail "root_dir '${ROOT_DIR}' not found after extraction"
        exit 2
    fi
fi

pass "Extracted to working directory"
echo ""

# --- Step 6: Layout conversion ---
echo -e "${BOLD}6. Layout conversion${RESET}"

STAGING_DIR="${RUN_DIR}/staging"
mkdir -p "$STAGING_DIR"

# Copy content to staging directory
cp -a "$CONTENT_DIR"/. "$STAGING_DIR/"

# Verify minimum layout: bin/ is required for a toolchain ingot
if [[ ! -d "${STAGING_DIR}/bin" ]]; then
    fail "Standard layout missing: bin/ directory not found"
    exit 2
fi

LAYOUT_DIRS=()
for dir in bin lib include share; do
    [[ -d "${STAGING_DIR}/${dir}" ]] && LAYOUT_DIRS+=("$dir")
done

pass "Layout verified: ${LAYOUT_DIRS[*]}"
echo ""

# --- Step 7: License file inclusion ---
echo -e "${BOLD}7. License file inclusion${RESET}"

LICENSE_COUNT=$(jq '.metadata.license_files // [] | length' "$MOLD_JSON")

if [[ "$LICENSE_COUNT" -eq 0 ]]; then
    fail "No license_files defined in metadata"
    exit 2
fi

for idx in $(seq 0 $((LICENSE_COUNT - 1))); do
    LIC_FILE=$(jq -r ".metadata.license_files[$idx]" "$MOLD_JSON")

    # Reject path traversal in license file names
    if [[ "$LIC_FILE" == /* || "$LIC_FILE" == ../* || \
          "$LIC_FILE" == */../* || "$LIC_FILE" == */.. || \
          "$LIC_FILE" == .. ]]; then
        fail "License file path contains traversal or is absolute: ${LIC_FILE}"
        exit 2
    fi

    if [[ -f "${STAGING_DIR}/${LIC_FILE}" ]]; then
        pass "License file present: ${LIC_FILE}"
    else
        # Search in the staging directory tree
        LIC_BASENAME=$(basename "$LIC_FILE")
        FOUND_LIC=$(find "$STAGING_DIR" -name "$LIC_BASENAME" -type f 2>/dev/null | head -1)
        if [[ -n "$FOUND_LIC" ]]; then
            cp "$FOUND_LIC" "${STAGING_DIR}/${LIC_FILE}"
            pass "License file found and copied to root: ${LIC_FILE}"
        else
            fail "License file not found: ${LIC_FILE}"
            add_summary "- :x: Missing license file: ${LIC_FILE}"
            exit 2
        fi
    fi
done

# Check for NOTICE files (Apache 2.0 Section 4(d) compliance)
LICENSE_FILES_LIST=$(jq -r '.metadata.license_files // [] | .[]' "$MOLD_JSON")
for notice_name in NOTICE NOTICE.txt NOTICE.md; do
    NOTICE_PATH=$(find "$STAGING_DIR" -maxdepth 2 -name "$notice_name" -type f 2>/dev/null | head -1)
    if [[ -n "$NOTICE_PATH" ]]; then
        NOTICE_BASENAME=$(basename "$NOTICE_PATH")
        if ! echo "$LICENSE_FILES_LIST" | grep -qxF "$NOTICE_BASENAME"; then
            warn "NOTICE file found (${NOTICE_BASENAME}) but not listed in metadata.license_files"
            add_summary "- :warning: NOTICE file found but not in license_files: ${NOTICE_BASENAME}"
        fi
    fi
done
echo ""

# --- Step 8: glibc compatibility check ---
echo -e "${BOLD}8. glibc compatibility check${RESET}"

GLIBC_VERSION=""

if [[ "$PLATFORM" != "linux" ]]; then
    info "Skipped (non-Linux platform)"
elif [[ "$READELF_AVAILABLE" != "true" ]]; then
    warn "readelf not available; skipping glibc check"
else
    MAX_GLIBC=""
    for binary in "${STAGING_DIR}/bin"/*; do
        [[ -f "$binary" && -x "$binary" ]] || continue

        # Check if it is an ELF binary
        if ! file "$binary" 2>/dev/null | grep -q "ELF"; then
            continue
        fi

        BIN_GLIBC=$(readelf --version-info "$binary" 2>/dev/null \
            | grep -o 'GLIBC_[0-9.]*' \
            | sed 's/GLIBC_//' \
            | sort -V \
            | tail -1) || true

        if [[ -n "$BIN_GLIBC" ]]; then
            if [[ -z "$MAX_GLIBC" ]]; then
                MAX_GLIBC="$BIN_GLIBC"
            else
                HIGHER=$(printf '%s\n%s' "$MAX_GLIBC" "$BIN_GLIBC" | sort -V | tail -1)
                MAX_GLIBC="$HIGHER"
            fi
        fi
    done

    if [[ -n "$MAX_GLIBC" ]]; then
        GLIBC_VERSION="$MAX_GLIBC"
        BASELINE_CHECK=$(printf '%s\n%s' "$GLIBC_BASELINE" "$MAX_GLIBC" | sort -V | tail -1)
        if [[ "$BASELINE_CHECK" != "$GLIBC_BASELINE" ]]; then
            warn "Required glibc ${MAX_GLIBC} exceeds baseline ${GLIBC_BASELINE}"
            add_summary "- :warning: glibc ${MAX_GLIBC} > baseline ${GLIBC_BASELINE}"
        else
            pass "glibc requirement: ${MAX_GLIBC} (<= ${GLIBC_BASELINE})"
        fi
    else
        info "No glibc version requirements detected"
    fi
fi
echo ""

# --- Step 9: Smoke test ---
echo -e "${BOLD}9. Smoke test${RESET}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMOKE_TEST="${SCRIPT_DIR}/smoke-test.sh"

if [[ ! -x "$SMOKE_TEST" ]]; then
    fail "smoke-test.sh not found: ${SMOKE_TEST}"
    exit 3
fi

set +e
"$SMOKE_TEST" "$STAGING_DIR" "$MOLD_DIR"
SMOKE_EXIT=$?
set -e

if [[ "$SMOKE_EXIT" -ne 0 ]]; then
    fail "Smoke test failed (exit code: ${SMOKE_EXIT})"
    add_summary "- :x: Smoke test failed"
    exit 1
fi

pass "Smoke test passed"
echo ""

# --- Summary ---
echo -e "${BOLD}Summary${RESET}"
echo -e "  ${GREEN}Validation passed.${RESET}"

add_summary ""
add_summary "- :white_check_mark: SHA256 verified"
add_summary "- :white_check_mark: Layout verified: ${LAYOUT_DIRS[*]}"
if [[ -n "$GLIBC_VERSION" ]]; then
    add_summary "- :white_check_mark: glibc requirement: ${GLIBC_VERSION}"
fi
add_summary "- :white_check_mark: Smoke test passed"
add_summary ""
add_summary "**Result: :white_check_mark: Validation passed**"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    echo "$SUMMARY_MD" >> "$GITHUB_STEP_SUMMARY"
fi

exit 0
