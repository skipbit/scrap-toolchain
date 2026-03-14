#!/usr/bin/env bash
# validate-mold.sh — Validate a mold definition against schema and verify source integrity
#
# Usage: validate-mold.sh <mold-directory>
#
# Environment variables:
#   SCHEMA_PATH     — Path to mold-v1.schema.json (default: schema/mold-v1.schema.json)
#   RETRY_INTERVAL  — Seconds between URL check retries (default: 60)
#
# Exit codes:
#   0 = All validations passed
#   1 = One or more validation errors
#   2 = Internal error (missing tools, unexpected failures)

set -euo pipefail

MOLD_DIR="${1:?Usage: validate-mold.sh <mold-directory>}"
MOLD_DIR="${MOLD_DIR%/}"
SCHEMA_PATH="${SCHEMA_PATH:-schema/mold-v1.schema.json}"

MAX_RETRIES=3
RETRY_INTERVAL="${RETRY_INTERVAL:-60}"

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
fail() { echo -e "  ${RED}FAIL${RESET}: $1"; FAILURES=$((FAILURES + 1)); }
warn() { echo -e "  ${YELLOW}WARN${RESET}: $1"; }
info() { echo -e "  ${BOLD}INFO${RESET}: $1"; }

FAILURES=0
SUMMARY_MD=""
add_summary() { SUMMARY_MD+="$1"$'\n'; }

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

_HTTP_CODE=""
check_url() {
    local url="$1"
    _HTTP_CODE=""
    local attempt
    for attempt in $(seq 1 "$MAX_RETRIES"); do
        # Try HEAD first
        _HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --head \
            --max-time 30 --location "$url" 2>/dev/null || echo "000")
        if [[ "$_HTTP_CODE" =~ ^2 ]]; then
            return 0
        fi
        # Fall back to GET with minimal download if HEAD is rejected (405/403)
        if [[ "$_HTTP_CODE" == "405" || "$_HTTP_CODE" == "403" ]]; then
            _HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -r 0-0 \
                --max-time 10 --location "$url" 2>/dev/null || echo "000")
            if [[ "$_HTTP_CODE" =~ ^2 ]]; then
                return 0
            fi
        fi
        if [[ "$attempt" -lt "$MAX_RETRIES" ]]; then
            warn "Attempt $attempt/$MAX_RETRIES returned HTTP ${_HTTP_CODE}, retrying in ${RETRY_INTERVAL}s..."
            sleep "$RETRY_INTERVAL"
        fi
    done
    return 1
}

# Cleanup on exit
TMPDIR_VALIDATE=""
cleanup() {
    if [[ -n "$TMPDIR_VALIDATE" && -d "$TMPDIR_VALIDATE" ]]; then
        rm -rf "$TMPDIR_VALIDATE"
    fi
}
trap cleanup EXIT

TMPDIR_VALIDATE=$(mktemp -d)

# --- Pre-flight checks ---
echo -e "${BOLD}Pre-flight checks${RESET}"

for cmd in python3 curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: $cmd is not installed"
        exit 2
    fi
done

if ! command -v sha256sum &>/dev/null && ! command -v shasum &>/dev/null; then
    echo "Error: sha256sum or shasum is required"
    exit 2
fi

if ! python3 -c "import tomllib" 2>/dev/null; then
    echo "Error: Python 3.11+ with tomllib module is required"
    exit 2
fi

if ! python3 -c "import jsonschema" 2>/dev/null; then
    echo "Error: Python jsonschema module is required (pip install jsonschema)"
    exit 2
fi

MOLD_TOML="${MOLD_DIR}/mold.toml"
if [[ ! -f "$MOLD_TOML" ]]; then
    echo "Error: ${MOLD_TOML} not found"
    exit 2
fi

if [[ ! -f "$SCHEMA_PATH" ]]; then
    echo "Error: Schema file ${SCHEMA_PATH} not found"
    exit 2
fi

pass "Prerequisites satisfied"
echo ""

# --- Step 1: TOML syntax check ---
echo -e "${BOLD}1. TOML syntax check${RESET}"
add_summary "## Validation: ${MOLD_DIR}"
add_summary ""

MOLD_JSON_FILE="${TMPDIR_VALIDATE}/mold.json"

set +e
python3 -c "
import tomllib, json, sys
with open(sys.argv[1], 'rb') as f:
    data = tomllib.load(f)
with open(sys.argv[2], 'w') as out:
    json.dump(data, out)
" "$MOLD_TOML" "$MOLD_JSON_FILE" 2>"${TMPDIR_VALIDATE}/parse_stderr"
PARSE_EXIT=$?
set -e

if [[ "$PARSE_EXIT" -eq 0 ]]; then
    pass "TOML syntax is valid"
    add_summary "- :white_check_mark: TOML syntax"
else
    PARSE_ERROR=$(cat "${TMPDIR_VALIDATE}/parse_stderr")
    fail "TOML syntax error: ${PARSE_ERROR}"
    add_summary "- :x: TOML syntax: ${PARSE_ERROR}"
    echo ""
    echo -e "${BOLD}Summary${RESET}"
    echo -e "  ${RED}Aborted: Cannot proceed without valid TOML.${RESET}"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        echo "$SUMMARY_MD" >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 1
fi
echo ""

# --- Step 2: JSON Schema validation ---
echo -e "${BOLD}2. JSON Schema validation${RESET}"

set +e
SCHEMA_RESULT=$(python3 -c "
import json, sys
from jsonschema import Draft202012Validator

with open(sys.argv[1]) as f:
    schema = json.load(f)
with open(sys.argv[2]) as f:
    instance = json.load(f)

validator = Draft202012Validator(schema)
errors = sorted(validator.iter_errors(instance), key=lambda e: list(e.absolute_path))

if not errors:
    print('OK')
else:
    for err in errors:
        path = '.'.join(str(p) for p in err.absolute_path) if err.absolute_path else '(root)'
        print(f'FAIL:{path}: {err.message}')
    sys.exit(1)
" "$SCHEMA_PATH" "$MOLD_JSON_FILE" 2>"${TMPDIR_VALIDATE}/schema_stderr")
SCHEMA_EXIT=$?
set -e

if [[ "$SCHEMA_EXIT" -eq 0 && "$SCHEMA_RESULT" == "OK" ]]; then
    pass "Schema validation passed"
    add_summary "- :white_check_mark: JSON Schema validation"
elif [[ "$SCHEMA_EXIT" -ne 0 ]]; then
    HAS_FAIL_LINES=false
    while IFS= read -r line; do
        if [[ "$line" == FAIL:* ]]; then
            detail="${line#FAIL:}"
            fail "Schema: ${detail}"
            add_summary "- :x: Schema: ${detail}"
            HAS_FAIL_LINES=true
        fi
    done <<< "$SCHEMA_RESULT"
    # If Python crashed without producing FAIL: lines, report the raw error
    if [[ "$HAS_FAIL_LINES" == "false" ]]; then
        SCHEMA_STDERR=$(cat "${TMPDIR_VALIDATE}/schema_stderr")
        fail "Schema validation error: ${SCHEMA_RESULT}${SCHEMA_STDERR:+ (${SCHEMA_STDERR})}"
        add_summary "- :x: Schema validation error"
    fi
else
    # SCHEMA_EXIT == 0 but output is not "OK" — unexpected state
    fail "Schema validation returned unexpected output: ${SCHEMA_RESULT}"
    add_summary "- :x: Schema validation: unexpected output"
fi
echo ""

# --- Step 3: Path consistency ---
echo -e "${BOLD}3. Path consistency${RESET}"

MOLD_FAMILY=$(jq -r '.metadata.family // empty' "$MOLD_JSON_FILE")
MOLD_VERSION=$(jq -r '.metadata.version // empty' "$MOLD_JSON_FILE")

DIR_VERSION=$(basename "$MOLD_DIR")
DIR_FAMILY=$(basename "$(dirname "$MOLD_DIR")")

if [[ -z "$MOLD_FAMILY" || -z "$MOLD_VERSION" ]]; then
    fail "Cannot extract metadata.family or metadata.version from mold.toml"
    add_summary "- :x: Path consistency: missing metadata fields"
else
    CONSISTENCY_OK=true
    if [[ "$DIR_FAMILY" != "$MOLD_FAMILY" ]]; then
        fail "Family mismatch: directory='${DIR_FAMILY}' vs metadata.family='${MOLD_FAMILY}'"
        add_summary "- :x: Family mismatch: dir=${DIR_FAMILY}, mold=${MOLD_FAMILY}"
        CONSISTENCY_OK=false
    fi
    if [[ "$DIR_VERSION" != "$MOLD_VERSION" ]]; then
        fail "Version mismatch: directory='${DIR_VERSION}' vs metadata.version='${MOLD_VERSION}'"
        add_summary "- :x: Version mismatch: dir=${DIR_VERSION}, mold=${MOLD_VERSION}"
        CONSISTENCY_OK=false
    fi
    if [[ "$CONSISTENCY_OK" == "true" ]]; then
        pass "Path matches metadata: ${MOLD_FAMILY}/${MOLD_VERSION}"
        add_summary "- :white_check_mark: Path consistency: ${MOLD_FAMILY}/${MOLD_VERSION}"
    fi
fi
echo ""

# --- Step 4: Source accessibility ---
echo -e "${BOLD}4. Source accessibility${RESET}"

SOURCE_TYPE=$(jq -r '.source.type // empty' "$MOLD_JSON_FILE")
URLS_TO_CHECK=()

if [[ "$SOURCE_TYPE" == "fetch" ]]; then
    while IFS= read -r url; do
        [[ -n "$url" ]] && URLS_TO_CHECK+=("$url")
    done < <(jq -r '.source.binaries[]?.url // empty' "$MOLD_JSON_FILE")

    BF_ENABLED=$(jq -r '.source.build_fallback.enabled // false' "$MOLD_JSON_FILE")
    if [[ "$BF_ENABLED" == "true" ]]; then
        BF_URL=$(jq -r '.source.build_fallback.source_url // empty' "$MOLD_JSON_FILE")
        [[ -n "$BF_URL" ]] && URLS_TO_CHECK+=("$BF_URL")
    fi
elif [[ "$SOURCE_TYPE" == "build" ]]; then
    BUILD_URL=$(jq -r '.source.build.source_url // empty' "$MOLD_JSON_FILE")
    [[ -n "$BUILD_URL" ]] && URLS_TO_CHECK+=("$BUILD_URL")
fi

if [[ ${#URLS_TO_CHECK[@]} -eq 0 ]]; then
    warn "No source URLs found to check"
    add_summary "- :warning: Source accessibility: no URLs"
else
    URL_FAILURES=0
    for url in "${URLS_TO_CHECK[@]}"; do
        if check_url "$url"; then
            pass "URL accessible: ${url}"
        else
            fail "URL unreachable (HTTP ${_HTTP_CODE}): ${url}"
            add_summary "- :x: URL unreachable: ${url} (HTTP ${_HTTP_CODE})"
            URL_FAILURES=$((URL_FAILURES + 1))
        fi
    done
    if [[ "$URL_FAILURES" -eq 0 ]]; then
        add_summary "- :white_check_mark: Source accessibility: ${#URLS_TO_CHECK[@]} URL(s) reachable"
    fi
fi
echo ""

# --- Step 5: SHA256 pre-verification ---
echo -e "${BOLD}5. SHA256 pre-verification${RESET}"

if [[ "$SOURCE_TYPE" == "fetch" ]]; then
    VERIFY_URL=""
    VERIFY_SHA256=""
    VERIFY_LABEL=""

    # Prefer linux-x86_64 (same platform as Light Build Verification)
    VERIFY_URL=$(jq -r '
        .source.binaries[] | select(.platform == "linux" and .arch == "x86_64") | .url
    ' "$MOLD_JSON_FILE" 2>/dev/null | head -1)
    VERIFY_SHA256=$(jq -r '
        .source.binaries[] | select(.platform == "linux" and .arch == "x86_64") | .sha256
    ' "$MOLD_JSON_FILE" 2>/dev/null | head -1)

    if [[ -n "$VERIFY_URL" ]]; then
        VERIFY_LABEL="linux-x86_64"
    else
        VERIFY_URL=$(jq -r '.source.binaries[0].url // empty' "$MOLD_JSON_FILE")
        VERIFY_SHA256=$(jq -r '.source.binaries[0].sha256 // empty' "$MOLD_JSON_FILE")
        VERIFY_PLATFORM=$(jq -r '.source.binaries[0].platform // "unknown"' "$MOLD_JSON_FILE")
        VERIFY_ARCH=$(jq -r '.source.binaries[0].arch // "unknown"' "$MOLD_JSON_FILE")
        VERIFY_LABEL="${VERIFY_PLATFORM}-${VERIFY_ARCH}"
    fi

    if [[ -z "$VERIFY_URL" || -z "$VERIFY_SHA256" ]]; then
        fail "No binary entry found for SHA256 verification"
        add_summary "- :x: SHA256 pre-verification: no binary entry"
    else
        info "Downloading ${VERIFY_LABEL} archive for verification..."
        DL_FILE="${TMPDIR_VALIDATE}/archive"
        set +e
        curl -fsL --max-time 300 --retry 3 -o "$DL_FILE" "$VERIFY_URL" \
            2>"${TMPDIR_VALIDATE}/dl_stderr"
        DL_EXIT=$?
        set -e
        if [[ "$DL_EXIT" -eq 0 && -f "$DL_FILE" ]]; then
            ACTUAL_SHA=$(compute_sha256 "$DL_FILE")
            if [[ "$ACTUAL_SHA" == "$VERIFY_SHA256" ]]; then
                pass "SHA256 verified for ${VERIFY_LABEL}"
                add_summary "- :white_check_mark: SHA256 pre-verification: ${VERIFY_LABEL}"
            else
                fail "SHA256 mismatch for ${VERIFY_LABEL}: expected=${VERIFY_SHA256} actual=${ACTUAL_SHA}"
                add_summary "- :x: SHA256 mismatch for ${VERIFY_LABEL}"
            fi
        else
            fail "Download failed for SHA256 verification: ${VERIFY_URL}"
            add_summary "- :x: SHA256 pre-verification: download failed"
        fi
    fi
elif [[ "$SOURCE_TYPE" == "build" ]]; then
    BUILD_URL=$(jq -r '.source.build.source_url // empty' "$MOLD_JSON_FILE")
    BUILD_SHA=$(jq -r '.source.build.source_sha256 // empty' "$MOLD_JSON_FILE")

    if [[ -z "$BUILD_URL" || -z "$BUILD_SHA" ]]; then
        fail "Missing source_url or source_sha256 for build type"
        add_summary "- :x: SHA256 pre-verification: missing build source fields"
    else
        info "Downloading source archive for verification..."
        DL_FILE="${TMPDIR_VALIDATE}/source"
        set +e
        curl -fsL --max-time 300 --retry 3 -o "$DL_FILE" "$BUILD_URL" \
            2>"${TMPDIR_VALIDATE}/dl_stderr"
        DL_EXIT=$?
        set -e
        if [[ "$DL_EXIT" -eq 0 && -f "$DL_FILE" ]]; then
            ACTUAL_SHA=$(compute_sha256 "$DL_FILE")
            if [[ "$ACTUAL_SHA" == "$BUILD_SHA" ]]; then
                pass "SHA256 verified for source archive"
                add_summary "- :white_check_mark: SHA256 pre-verification: source archive"
            else
                fail "SHA256 mismatch: expected=${BUILD_SHA} actual=${ACTUAL_SHA}"
                add_summary "- :x: SHA256 mismatch for source archive"
            fi
        else
            fail "Download failed: ${BUILD_URL}"
            add_summary "- :x: SHA256 pre-verification: download failed"
        fi
    fi
else
    warn "Unknown source type: ${SOURCE_TYPE}"
    add_summary "- :warning: SHA256 pre-verification: unknown source type"
fi
echo ""

# --- Step 6: Patches existence check ---
echo -e "${BOLD}6. Patches existence check${RESET}"

PATCHES_COUNT=$(jq '.patches // [] | length' "$MOLD_JSON_FILE")

if [[ "$PATCHES_COUNT" -eq 0 ]]; then
    info "No patches defined"
    add_summary "- :white_check_mark: Patches: none defined"
else
    PATCH_FAILURES=0
    # Resolve mold directory to canonical path for traversal check
    MOLD_DIR_REAL=$(resolve_path "$MOLD_DIR")
    for idx in $(seq 0 $((PATCHES_COUNT - 1))); do
        PATCH_FILE=$(jq -r ".patches[$idx].file" "$MOLD_JSON_FILE")
        # Reject absolute paths and ".." as a path component
        if [[ "$PATCH_FILE" == /* || "$PATCH_FILE" == ../* || "$PATCH_FILE" == */../* || "$PATCH_FILE" == */.. || "$PATCH_FILE" == .. ]]; then
            fail "Patch path contains traversal or is absolute: ${PATCH_FILE}"
            add_summary "- :x: Invalid patch path: ${PATCH_FILE}"
            PATCH_FAILURES=$((PATCH_FAILURES + 1))
            continue
        fi
        PATCH_PATH="${MOLD_DIR}/${PATCH_FILE}"
        if [[ -f "$PATCH_PATH" ]]; then
            # Verify canonical path is within the mold directory (catches symlink escapes)
            PATCH_REAL=$(resolve_path "$PATCH_PATH")
            if [[ "$PATCH_REAL" != "${MOLD_DIR_REAL}/"* ]]; then
                fail "Patch path escapes mold directory: ${PATCH_FILE}"
                add_summary "- :x: Patch escapes mold dir: ${PATCH_FILE}"
                PATCH_FAILURES=$((PATCH_FAILURES + 1))
            else
                pass "Patch file exists: ${PATCH_FILE}"
            fi
        else
            fail "Patch file not found: ${PATCH_FILE}"
            add_summary "- :x: Missing patch: ${PATCH_FILE}"
            PATCH_FAILURES=$((PATCH_FAILURES + 1))
        fi
    done
    if [[ "$PATCH_FAILURES" -eq 0 ]]; then
        add_summary "- :white_check_mark: Patches: ${PATCHES_COUNT} file(s) present"
    fi
fi
echo ""

# --- Summary ---
echo -e "${BOLD}Summary${RESET}"
add_summary ""
if [[ $FAILURES -eq 0 ]]; then
    echo -e "  ${GREEN}All validations passed.${RESET}"
    add_summary "**Result: :white_check_mark: All validations passed**"
else
    echo -e "  ${RED}${FAILURES} validation(s) failed.${RESET}"
    add_summary "**Result: :x: ${FAILURES} validation(s) failed**"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    echo "$SUMMARY_MD" >> "$GITHUB_STEP_SUMMARY"
fi

if [[ $FAILURES -gt 0 ]]; then
    exit 1
fi
exit 0
