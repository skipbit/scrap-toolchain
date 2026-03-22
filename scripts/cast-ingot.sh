#!/usr/bin/env bash
# cast-ingot.sh — Build or validate a toolchain mold definition
#
# For fetch-type molds: downloads the upstream binary, verifies integrity
# (SHA256), checks layout, license files, glibc compatibility, and runs
# a smoke test. No ingot archive is produced.
#
# For build-type molds: downloads source, builds from source, creates an
# ingot archive (tar.xz) with metadata. Supports 3-stage splitting for
# CI pipeline use (configure / make / package).
#
# Usage: cast-ingot.sh <mold-directory> <platform> <arch>
#
# Environment variables:
#   WORK_DIR           — Base directory for temporary files (default: /tmp/cast-ingot)
#   OUTPUT_DIR         — Output directory for ingot artifacts (default: ./output)
#   CAST_STAGE         — Build stage for build-type 3-stage mode:
#                          configure — Steps 2-7 (download through configure)
#                          make      — Steps 8-9 (make and make install)
#                          package   — Steps 10-16 (layout through metadata output)
#                        Unset or empty runs all stages sequentially.
#   STAGE_ARTIFACT_DIR — Directory for intermediate stage artifacts.
#                        Required when CAST_STAGE is set.
#
# Exit codes:
#   0 = Success (validation passed / ingot created)
#   1 = Test error (smoke test failure, build failure)
#   2 = Validation error (SHA256 mismatch, missing license, unsupported platform)
#   3 = Internal error (missing tools, invalid configuration)

set -euo pipefail

MOLD_DIR="${1:?Usage: cast-ingot.sh <mold-directory> <platform> <arch>}"
PLATFORM="${2:?Usage: cast-ingot.sh <mold-directory> <platform> <arch>}"
ARCH="${3:?Usage: cast-ingot.sh <mold-directory> <platform> <arch>}"
MOLD_DIR="${MOLD_DIR%/}"

BASE_WORK_DIR="${WORK_DIR:-/tmp/cast-ingot}"
OUTPUT_DIR="${OUTPUT_DIR:-./output}"
CAST_STAGE="${CAST_STAGE:-}"
STAGE_ARTIFACT_DIR="${STAGE_ARTIFACT_DIR:-}"

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

# Internal prefix for configure --prefix (build type only).
# The final ingot layout (bin/, lib/, etc.) is extracted from
# DESTDIR + this prefix after make install.
INSTALL_PREFIX="/opt/toolchain"

# --- Validate CAST_STAGE ---
if [[ -n "$CAST_STAGE" ]]; then
    case "$CAST_STAGE" in
        configure|make|package) ;;
        *)
            echo "Error: Invalid CAST_STAGE value: ${CAST_STAGE}"
            echo "Valid values: configure, make, package (or unset for full flow)"
            exit 3
            ;;
    esac
    if [[ -z "$STAGE_ARTIFACT_DIR" ]]; then
        echo "Error: STAGE_ARTIFACT_DIR is required when CAST_STAGE is set"
        exit 3
    fi
    mkdir -p "$STAGE_ARTIFACT_DIR"
fi

# Returns true if the current execution should include the given stage.
# In full mode (CAST_STAGE unset), all stages run.
in_stage() {
    [[ -z "$CAST_STAGE" || "$CAST_STAGE" == "$1" ]]
}

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

# Install build prerequisites from mold.toml.
# Called in every stage (configure, make, package) because each CI
# stage uses a separate container that starts without mold-specific
# dependencies. apt-get install is idempotent so repeated calls are safe.
install_prerequisites() {
    local mold_json="$1"
    local platform="$2"
    local run_dir="$3"

    local -a apt_packages=()
    while IFS= read -r _pkg; do
        [[ -n "$_pkg" ]] && apt_packages+=("$_pkg")
    done < <(jq -r '.source.build.prerequisites.apt // [] | .[]' "$mold_json")

    if [[ ${#apt_packages[@]} -eq 0 ]]; then
        info "No prerequisites defined"
        return 0
    fi

    if [[ "$platform" == "linux" ]]; then
        info "Installing: ${apt_packages[*]}"

        local apt_prefix=""
        if [[ "$(id -u)" -ne 0 ]]; then
            if command -v sudo &>/dev/null; then
                apt_prefix="sudo"
            else
                fail "Not running as root and sudo is not available"
                return 3
            fi
        fi

        set +e
        $apt_prefix apt-get update -qq 2>"${run_dir}/apt_stderr"
        $apt_prefix apt-get install -y -qq "${apt_packages[@]}" 2>>"${run_dir}/apt_stderr"
        local apt_exit=$?
        set -e

        if [[ "$apt_exit" -ne 0 ]]; then
            local apt_error
            apt_error=$(cat "${run_dir}/apt_stderr")
            fail "Failed to install prerequisites: ${apt_error}"
            return 3
        fi

        pass "Prerequisites installed"
    else
        # macOS: apt is not available. Check that build dependencies
        # can be found in standard Homebrew locations.
        warn "apt prerequisites not available on ${platform}; checking for pre-installed libraries"

        local -a missing_deps=()
        local pkg
        for pkg in "${apt_packages[@]}"; do
            case "$pkg" in
                libgmp-dev)
                    [[ -f /opt/homebrew/include/gmp.h || -f /usr/local/include/gmp.h ]] \
                        || missing_deps+=("gmp")
                    ;;
                libmpfr-dev)
                    [[ -f /opt/homebrew/include/mpfr.h || -f /usr/local/include/mpfr.h ]] \
                        || missing_deps+=("mpfr")
                    ;;
                libmpc-dev)
                    [[ -f /opt/homebrew/include/mpc.h || -f /usr/local/include/mpc.h ]] \
                        || missing_deps+=("libmpc")
                    ;;
                libisl-dev)
                    [[ -f /opt/homebrew/include/isl/ctx.h || -f /usr/local/include/isl/ctx.h ]] \
                        || missing_deps+=("isl")
                    ;;
                *)
                    warn "Cannot verify macOS availability of: ${pkg}"
                    ;;
            esac
        done

        if [[ ${#missing_deps[@]} -gt 0 ]]; then
            fail "Missing build dependencies on macOS: ${missing_deps[*]}"
            info "Install with: brew install ${missing_deps[*]}"
            return 3
        fi
        pass "Build dependencies verified on macOS"
    fi
}

# Resolve a path to its canonical form (resolves symlinks).
# Portable across Linux and macOS via Python.
resolve_path() {
    python3 -c "import os, sys; print(os.path.realpath(sys.argv[1]))" "$1"
}

# Get the number of available CPU cores (portable across Linux and macOS).
get_nproc() {
    nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 1
}

SUMMARY_MD=""
add_summary() { SUMMARY_MD+="$1"$'\n'; }

# Cleanup on exit
RUN_DIR=""
trap '[[ -n "$RUN_DIR" && -d "$RUN_DIR" ]] && rm -rf "$RUN_DIR"' EXIT

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

# Validate FAMILY, VERSION, PLATFORM, ARCH contain only safe characters
# to prevent path traversal in output filenames and OCI tags.
for _field_name in FAMILY VERSION; do
    _field_val="${!_field_name}"
    if ! [[ "$_field_val" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        fail "Invalid ${_field_name} value (unsafe characters): ${_field_val}"
        exit 3
    fi
done
for _field_name in PLATFORM ARCH; do
    _field_val="${!_field_name}"
    if ! [[ "$_field_val" =~ ^[a-z0-9_]+$ ]]; then
        fail "Invalid ${_field_name} value (unsafe characters): ${_field_val}"
        exit 3
    fi
done

pass "Parsed: ${FAMILY} ${VERSION} (source.type = ${SOURCE_TYPE})"
echo ""

# =============================================================================
# Source type routing
# =============================================================================

if [[ "$SOURCE_TYPE" == "fetch" ]]; then

    # CAST_STAGE is only valid for build type
    if [[ -n "$CAST_STAGE" ]]; then
        fail "CAST_STAGE is only supported for build-type molds"
        exit 3
    fi

    # --- Fetch type flow (validation only, no ingot produced) ---

    # Reject fetch-type molds with patches defined (patches not supported for fetch type)
    PATCHES_COUNT=$(jq '.patches // [] | length' "$MOLD_JSON")
    if [[ "$PATCHES_COUNT" -gt 0 ]]; then
        fail "Fetch-type molds must not define patches"
        exit 2
    fi

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
            if ! printf '%s\n' "$LICENSE_FILES_LIST" | grep -qxF "$NOTICE_BASENAME"; then
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

    # --- Fetch Summary ---
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

elif [[ "$SOURCE_TYPE" == "build" ]]; then

    # =========================================================================
    # Build type flow (ingot production with 3-stage support)
    # =========================================================================

    # Additional pre-flight checks for build type
    for cmd in make patch; do
        if ! command -v "$cmd" &>/dev/null; then
            fail "Build type requires '${cmd}' but it is not installed"
            exit 3
        fi
    done

    # Read build configuration from mold.toml
    SOURCE_URL=$(jq -r '.source.build.source_url // empty' "$MOLD_JSON")
    SOURCE_SHA=$(jq -r '.source.build.source_sha256 // empty' "$MOLD_JSON")

    if [[ -z "$SOURCE_URL" || -z "$SOURCE_SHA" ]]; then
        fail "Build type requires source.build.source_url and source.build.source_sha256"
        exit 3
    fi

    CONFIGURE_ARGS=()
    while IFS= read -r _arg; do
        [[ -n "$_arg" ]] && CONFIGURE_ARGS+=("$_arg")
    done < <(jq -r '.source.build.configure_args // [] | .[]' "$MOLD_JSON")

    MAKE_ARGS=()
    while IFS= read -r _arg; do
        [[ -n "$_arg" ]] && MAKE_ARGS+=("$_arg")
    done < <(jq -r '.source.build.make_args // [] | .[]' "$MOLD_JSON")

    # Default make parallelism if not specified in mold.toml
    if [[ ${#MAKE_ARGS[@]} -eq 0 ]]; then
        MAKE_ARGS=("-j$(get_nproc)")
    else
        # Replace $(nproc) placeholder with actual core count.
        # Using explicit substitution instead of eval for safety.
        NPROC_VAL=$(get_nproc)
        for i in "${!MAKE_ARGS[@]}"; do
            MAKE_ARGS[i]="${MAKE_ARGS[i]//\$(nproc)/$NPROC_VAL}"
        done
    fi

    PATCHES_COUNT=$(jq '.patches // [] | length' "$MOLD_JSON")

    # Build directories use fixed paths under BASE_WORK_DIR so that
    # absolute paths in generated Makefiles remain valid across stages.
    # NOTE: This means concurrent builds sharing the same WORK_DIR will
    # collide. CI runners provide isolation; for local use, set WORK_DIR
    # to a unique directory per build.
    SOURCE_DIR="${BASE_WORK_DIR}/source"
    BUILD_DIR="${BASE_WORK_DIR}/build"
    DESTDIR_ROOT="${BASE_WORK_DIR}/destdir"
    STAGING_DIR="${DESTDIR_ROOT}${INSTALL_PREFIX}"

    # =====================================================================
    # Stage 1: Configure (Steps 2-7)
    # Input:  mold.toml, source URL
    # Output: configured source + build tree (tar.gz in STAGE_ARTIFACT_DIR)
    # =====================================================================

    if in_stage configure; then

        # Clean previous build state for a fresh start
        rm -rf "$SOURCE_DIR" "$BUILD_DIR" "$DESTDIR_ROOT"

        # --- Step 2: Download source archive ---
        echo -e "${BOLD}2. Download source archive${RESET}"

        DL_FILE="${RUN_DIR}/source-archive"
        DL_FILENAME=$(basename "${SOURCE_URL%%\?*}")
        info "Downloading: ${DL_FILENAME}"

        DL_SUCCESS=false
        for attempt in $(seq 1 "$MAX_DL_RETRIES"); do
            set +e
            curl -fSL --max-time 600 -o "$DL_FILE" "$SOURCE_URL" 2>"${RUN_DIR}/dl_stderr"
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
            add_summary "- :x: Download failed: ${SOURCE_URL}"
            exit 2
        fi

        DL_SIZE=$(wc -c < "$DL_FILE" | tr -d ' ')
        pass "Downloaded (${DL_SIZE} bytes)"
        echo ""

        # --- Step 3: SHA256 verification ---
        echo -e "${BOLD}3. SHA256 verification${RESET}"

        ACTUAL_SHA=$(compute_sha256 "$DL_FILE")
        if [[ "$ACTUAL_SHA" != "$SOURCE_SHA" ]]; then
            fail "SHA256 mismatch: expected=${SOURCE_SHA} actual=${ACTUAL_SHA}"
            add_summary "- :x: SHA256 mismatch"
            exit 2
        fi

        pass "SHA256 verified"
        echo ""

        # --- Step 4: Extract source ---
        echo -e "${BOLD}4. Extract source${RESET}"

        mkdir -p "$SOURCE_DIR"

        case "$DL_FILENAME" in
            *.tar.xz | *.txz)
                tar -xJf "$DL_FILE" --strip-components=1 -C "$SOURCE_DIR"
                ;;
            *.tar.gz | *.tgz)
                tar -xzf "$DL_FILE" --strip-components=1 -C "$SOURCE_DIR"
                ;;
            *.tar.bz2 | *.tbz2)
                tar -xjf "$DL_FILE" --strip-components=1 -C "$SOURCE_DIR"
                ;;
            *.tar)
                tar -xf "$DL_FILE" --strip-components=1 -C "$SOURCE_DIR"
                ;;
            *)
                fail "Unsupported archive format: ${DL_FILENAME}"
                exit 3
                ;;
        esac

        pass "Extracted to ${SOURCE_DIR}"
        echo ""

        # --- Step 5: Apply patches ---
        echo -e "${BOLD}5. Apply patches${RESET}"

        if [[ "$PATCHES_COUNT" -gt 0 ]]; then
            for idx in $(seq 0 $((PATCHES_COUNT - 1))); do
                PATCH_FILE=$(jq -r ".patches[$idx].file // empty" "$MOLD_JSON")
                PATCH_DESC=$(jq -r ".patches[$idx].description // \"(no description)\"" "$MOLD_JSON")

                if [[ -z "$PATCH_FILE" ]]; then
                    fail "Patch entry ${idx} has no file field"
                    exit 2
                fi

                # Reject path traversal
                if [[ "$PATCH_FILE" == /* || "$PATCH_FILE" == ../* || \
                      "$PATCH_FILE" == */../* || "$PATCH_FILE" == */.. || \
                      "$PATCH_FILE" == .. ]]; then
                    fail "Patch file path contains traversal: ${PATCH_FILE}"
                    exit 2
                fi

                PATCH_PATH="${MOLD_DIR}/${PATCH_FILE}"
                if [[ ! -f "$PATCH_PATH" ]]; then
                    fail "Patch file not found: ${PATCH_PATH}"
                    exit 2
                fi

                set +e
                patch -p1 -d "$SOURCE_DIR" < "$PATCH_PATH" 2>"${RUN_DIR}/patch_stderr"
                PATCH_EXIT=$?
                set -e

                if [[ "$PATCH_EXIT" -ne 0 ]]; then
                    PATCH_ERROR=$(cat "${RUN_DIR}/patch_stderr")
                    fail "Patch failed: ${PATCH_FILE}: ${PATCH_ERROR}"
                    exit 2
                fi

                info "Applied: ${PATCH_FILE} — ${PATCH_DESC}"
            done
            pass "All ${PATCHES_COUNT} patches applied"
        else
            info "No patches to apply"
        fi
        echo ""

        # --- Step 6: Install prerequisites ---
        echo -e "${BOLD}6. Install prerequisites${RESET}"
        install_prerequisites "$MOLD_JSON" "$PLATFORM" "$RUN_DIR" || exit $?

        APT_PACKAGES=()
        while IFS= read -r _pkg; do
            [[ -n "$_pkg" ]] && APT_PACKAGES+=("$_pkg")
        done < <(jq -r '.source.build.prerequisites.apt // [] | .[]' "$MOLD_JSON")

        # --- Step 6b: Inject Homebrew paths (configure stage, macOS only) ---
        if [[ ${#APT_PACKAGES[@]} -gt 0 ]] && [[ "$PLATFORM" != "linux" ]]; then
            # GNU build systems (autoconf) need explicit --with-xxx paths to
            # find libraries installed via Homebrew because /opt/homebrew is
            # not in the default search path.
            # NOTE: Only applies to autoconf (./configure). CMake projects
            # require different variable names (e.g. -DGMP_ROOT).
            HB_PREFIX=""
            if command -v brew &>/dev/null; then
                HB_PREFIX="$(brew --prefix 2>/dev/null || true)"
            fi
            if [[ -z "$HB_PREFIX" ]] && [[ -d /opt/homebrew ]]; then
                HB_PREFIX="/opt/homebrew"
            elif [[ -z "$HB_PREFIX" ]] && [[ -d /usr/local/Cellar ]]; then
                HB_PREFIX="/usr/local"
            fi

            if [[ -n "$HB_PREFIX" ]] && [[ -x "${SOURCE_DIR}/configure" ]]; then
                for pkg in "${APT_PACKAGES[@]}"; do
                    _flag_name=""
                    case "$pkg" in
                        libgmp-dev)  _flag_name="gmp" ;;
                        libmpfr-dev) _flag_name="mpfr" ;;
                        libmpc-dev)  _flag_name="mpc" ;;
                        libisl-dev)  _flag_name="isl" ;;
                    esac

                    if [[ -z "$_flag_name" ]]; then
                        continue
                    fi

                    # Skip if mold already specifies --with-xxx or --without-xxx
                    _skip=0
                    for _arg in "${CONFIGURE_ARGS[@]}"; do
                        case "$_arg" in
                            --with-${_flag_name}=*|--with-${_flag_name}|--without-${_flag_name}|--without-${_flag_name}=*)
                                _skip=1
                                break
                                ;;
                        esac
                    done

                    if [[ $_skip -eq 0 ]]; then
                        CONFIGURE_ARGS+=("--with-${_flag_name}=${HB_PREFIX}")
                        info "macOS: injected --with-${_flag_name}=${HB_PREFIX}"
                    fi
                done
            fi
        fi
        echo ""

        # --- Step 7: Configure ---
        echo -e "${BOLD}7. Configure${RESET}"

        mkdir -p "$BUILD_DIR"

        info "prefix: ${INSTALL_PREFIX}"
        if [[ ${#CONFIGURE_ARGS[@]} -gt 0 ]]; then
            info "configure_args: ${CONFIGURE_ARGS[*]}"
        fi

        # Support autoconf (./configure) and CMake (CMakeLists.txt).
        # NOTE: --prefix is set first so configure_args cannot accidentally
        # override it. If a mold's configure_args contains --prefix, the
        # later value takes precedence in autoconf, which would cause the
        # STAGING_DIR check in Step 9 to fail. Mold reviewers must ensure
        # configure_args does not include --prefix.
        if [[ -x "${SOURCE_DIR}/configure" ]]; then
            set +e
            (
                cd "$BUILD_DIR"
                "${SOURCE_DIR}/configure" \
                    --prefix="$INSTALL_PREFIX" \
                    "${CONFIGURE_ARGS[@]}" \
                    2>&1 | tee "${RUN_DIR}/configure.log" | tail -5
            )
            CONFIGURE_EXIT=$?
            set -e
        elif [[ -f "${SOURCE_DIR}/CMakeLists.txt" ]]; then
            if ! command -v cmake &>/dev/null; then
                fail "CMake project detected but cmake is not installed"
                exit 3
            fi
            set +e
            cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
                -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
                "${CONFIGURE_ARGS[@]}" \
                2>&1 | tee "${RUN_DIR}/configure.log" | tail -5
            CONFIGURE_EXIT=$?
            set -e
        else
            fail "No configure script or CMakeLists.txt found in source"
            exit 3
        fi

        if [[ "$CONFIGURE_EXIT" -ne 0 ]]; then
            fail "Configure failed (exit code: ${CONFIGURE_EXIT})"
            info "See configure.log for details"
            add_summary "- :x: Configure failed"
            exit 2
        fi

        pass "Configure succeeded"
        echo ""

        # Create stage artifact if in configure-only mode
        if [[ "$CAST_STAGE" == "configure" ]]; then
            echo -e "${BOLD}Creating stage artifact${RESET}"
            tar -czf "${STAGE_ARTIFACT_DIR}/configure-tree.tar.gz" \
                -C "$BASE_WORK_DIR" source build
            ARTIFACT_SIZE=$(wc -c < "${STAGE_ARTIFACT_DIR}/configure-tree.tar.gz" | tr -d ' ')
            pass "Stage artifact: configure-tree.tar.gz (${ARTIFACT_SIZE} bytes)"

            add_summary ""
            add_summary "- :white_check_mark: Source downloaded and SHA256 verified"
            add_summary "- :white_check_mark: ${PATCHES_COUNT} patches applied"
            add_summary "- :white_check_mark: Prerequisites installed"
            add_summary "- :white_check_mark: Configure succeeded"
            add_summary ""
            add_summary "**Result: :white_check_mark: Configure stage completed**"

            if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
                echo "$SUMMARY_MD" >> "$GITHUB_STEP_SUMMARY"
            fi
            exit 0
        fi
    fi

    # =====================================================================
    # Stage 2: Make (Steps 8-9)
    # Input:  configured source + build tree
    # Output: installed tree with license files (tar.gz in STAGE_ARTIFACT_DIR)
    # =====================================================================

    if in_stage make; then

        # Load configure stage artifact if in stage mode
        if [[ "$CAST_STAGE" == "make" ]]; then
            echo -e "${BOLD}Loading configure stage artifact${RESET}"
            if [[ ! -f "${STAGE_ARTIFACT_DIR}/configure-tree.tar.gz" ]]; then
                fail "Stage artifact not found: ${STAGE_ARTIFACT_DIR}/configure-tree.tar.gz"
                exit 3
            fi
            rm -rf "$SOURCE_DIR" "$BUILD_DIR"
            tar -xzf "${STAGE_ARTIFACT_DIR}/configure-tree.tar.gz" -C "$BASE_WORK_DIR"
            pass "Configure stage artifact loaded"

            # Install prerequisites in make stage container
            echo -e "${BOLD}6. Install prerequisites${RESET}"
            install_prerequisites "$MOLD_JSON" "$PLATFORM" "$RUN_DIR" || exit $?
            echo ""
        fi

        # --- Step 8: Make ---
        echo -e "${BOLD}8. Make${RESET}"

        info "make_args: ${MAKE_ARGS[*]}"

        set +e
        (
            cd "$BUILD_DIR"
            make "${MAKE_ARGS[@]}" 2>&1 | tail -20
        )
        MAKE_EXIT=$?
        set -e

        if [[ "$MAKE_EXIT" -ne 0 ]]; then
            fail "Make failed (exit code: ${MAKE_EXIT})"
            add_summary "- :x: Make failed"
            exit 1
        fi

        pass "Make succeeded"
        echo ""

        # --- Step 9: Make install ---
        echo -e "${BOLD}9. Make install${RESET}"

        # Clean previous install state to prevent stale files
        rm -rf "$DESTDIR_ROOT"
        mkdir -p "$DESTDIR_ROOT"

        set +e
        (
            cd "$BUILD_DIR"
            make install DESTDIR="$DESTDIR_ROOT" 2>&1 | tail -10
        )
        INSTALL_EXIT=$?
        set -e

        if [[ "$INSTALL_EXIT" -ne 0 ]]; then
            fail "Make install failed (exit code: ${INSTALL_EXIT})"
            add_summary "- :x: Make install failed"
            exit 1
        fi

        # Verify the installation produced the expected prefix directory
        if [[ ! -d "$STAGING_DIR" ]]; then
            fail "Installation did not produce expected directory: ${STAGING_DIR}"
            exit 2
        fi

        pass "Make install succeeded"
        echo ""

        # Copy license files from source tree to the installed tree.
        # License files (e.g., COPYING, COPYING.RUNTIME) live in the source
        # root and are typically not installed by make install.
        echo -e "${BOLD}Preparing license files for packaging${RESET}"

        LICENSE_COUNT=$(jq '.metadata.license_files // [] | length' "$MOLD_JSON")
        if [[ "$LICENSE_COUNT" -gt 0 ]]; then
        for idx in $(seq 0 $((LICENSE_COUNT - 1))); do
            LIC_FILE=$(jq -r ".metadata.license_files[$idx]" "$MOLD_JSON")
            if [[ -f "${SOURCE_DIR}/${LIC_FILE}" ]]; then
                cp "${SOURCE_DIR}/${LIC_FILE}" "${STAGING_DIR}/${LIC_FILE}"
                info "Copied from source: ${LIC_FILE}"
            elif [[ -f "${STAGING_DIR}/${LIC_FILE}" ]]; then
                info "Already installed: ${LIC_FILE}"
            else
                warn "License file not found in source or install tree: ${LIC_FILE}"
            fi
        done
        fi
        echo ""

        # Create stage artifact if in make-only mode
        if [[ "$CAST_STAGE" == "make" ]]; then
            echo -e "${BOLD}Creating stage artifact${RESET}"
            tar -czf "${STAGE_ARTIFACT_DIR}/installed-tree.tar.gz" \
                -C "$STAGING_DIR" .
            ARTIFACT_SIZE=$(wc -c < "${STAGE_ARTIFACT_DIR}/installed-tree.tar.gz" | tr -d ' ')
            pass "Stage artifact: installed-tree.tar.gz (${ARTIFACT_SIZE} bytes)"

            add_summary ""
            add_summary "- :white_check_mark: Make succeeded"
            add_summary "- :white_check_mark: Make install succeeded"
            add_summary "- :white_check_mark: License files prepared"
            add_summary ""
            add_summary "**Result: :white_check_mark: Make stage completed**"

            if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
                echo "$SUMMARY_MD" >> "$GITHUB_STEP_SUMMARY"
            fi
            exit 0
        fi
    fi

    # =====================================================================
    # Stage 3: Package (Steps 10-16)
    # Input:  installed tree with license files
    # Output: ingot tar.xz + ingot-metadata JSON (in OUTPUT_DIR)
    # =====================================================================

    if in_stage package; then

        # Load make stage artifact if in stage mode
        if [[ "$CAST_STAGE" == "package" ]]; then
            echo -e "${BOLD}Loading make stage artifact${RESET}"
            if [[ ! -f "${STAGE_ARTIFACT_DIR}/installed-tree.tar.gz" ]]; then
                fail "Stage artifact not found: ${STAGE_ARTIFACT_DIR}/installed-tree.tar.gz"
                exit 3
            fi
            rm -rf "$DESTDIR_ROOT"
            mkdir -p "$STAGING_DIR"
            tar -xzf "${STAGE_ARTIFACT_DIR}/installed-tree.tar.gz" -C "$STAGING_DIR"
            pass "Make stage artifact loaded"

            # Install prerequisites in package stage container
            echo -e "${BOLD}6. Install prerequisites${RESET}"
            install_prerequisites "$MOLD_JSON" "$PLATFORM" "$RUN_DIR" || exit $?
            echo ""
        fi

        # --- Step 10: Layout conversion ---
        echo -e "${BOLD}10. Layout conversion${RESET}"

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

        # --- Step 11: License file inclusion ---
        echo -e "${BOLD}11. License file inclusion${RESET}"

        LICENSE_COUNT=$(jq '.metadata.license_files // [] | length' "$MOLD_JSON")

        if [[ "$LICENSE_COUNT" -eq 0 ]]; then
            fail "No license_files defined in metadata"
            exit 2
        fi

        for idx in $(seq 0 $((LICENSE_COUNT - 1))); do
            LIC_FILE=$(jq -r ".metadata.license_files[$idx]" "$MOLD_JSON")

            # Reject path traversal
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
        echo ""

        # --- Step 12: glibc compatibility check ---
        echo -e "${BOLD}12. glibc compatibility check${RESET}"

        GLIBC_VERSION=""

        if [[ "$PLATFORM" != "linux" ]]; then
            info "Skipped (non-Linux platform)"
        elif [[ "$READELF_AVAILABLE" != "true" ]]; then
            warn "readelf not available; skipping glibc check"
        else
            MAX_GLIBC=""
            for binary in "${STAGING_DIR}/bin"/*; do
                [[ -f "$binary" && -x "$binary" ]] || continue

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

        # --- Step 13: Generate metadata.toml ---
        echo -e "${BOLD}13. Generate metadata.toml${RESET}"

        BUILT_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        {
            echo "[metadata]"
            echo "family = \"${FAMILY}\""
            echo "version = \"${VERSION}\""
            echo "platform = \"${PLATFORM}\""
            echo "arch = \"${ARCH}\""
            echo "source_type = \"build\""
            if [[ -n "$GLIBC_VERSION" ]]; then
                echo "glibc_version = \"${GLIBC_VERSION}\""
            fi
            echo "built_at = \"${BUILT_AT}\""
        } > "${STAGING_DIR}/metadata.toml"

        pass "Generated metadata.toml (built_at: ${BUILT_AT})"
        echo ""

        # --- Step 14: Create ingot archive + SHA256 ---
        echo -e "${BOLD}14. Create ingot archive${RESET}"

        INGOT_FILENAME="${FAMILY}-${VERSION}-${PLATFORM}-${ARCH}.tar.xz"
        INGOT_PATH="${OUTPUT_DIR}/${INGOT_FILENAME}"

        tar -cJf "$INGOT_PATH" -C "$STAGING_DIR" .

        INGOT_SHA=$(compute_sha256 "$INGOT_PATH")
        INGOT_SIZE=$(wc -c < "$INGOT_PATH" | tr -d ' ')

        pass "Created: ${INGOT_FILENAME} (${INGOT_SIZE} bytes)"
        info "SHA256: ${INGOT_SHA}"
        echo ""

        # --- Step 15: Smoke test ---
        echo -e "${BOLD}15. Smoke test${RESET}"

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

        # --- Step 16: Output ingot-metadata JSON ---
        echo -e "${BOLD}16. Output ingot metadata${RESET}"

        METADATA_FILENAME="ingot-metadata-${FAMILY}-${VERSION}-${PLATFORM}-${ARCH}.json"
        METADATA_PATH="${OUTPUT_DIR}/${METADATA_FILENAME}"

        jq -n \
            --arg family "$FAMILY" \
            --arg version "$VERSION" \
            --arg platform "$PLATFORM" \
            --arg arch "$ARCH" \
            --arg ingot_file "$INGOT_FILENAME" \
            --arg sha256 "$INGOT_SHA" \
            --arg glibc_version "${GLIBC_VERSION:-}" \
            --arg built_at "$BUILT_AT" \
            '{
                family: $family,
                version: $version,
                platform: $platform,
                arch: $arch,
                ingot_file: $ingot_file,
                sha256: $sha256,
                source_type: "build",
                built_at: $built_at
            } + (if $glibc_version != "" then {glibc_version: $glibc_version} else {} end)' \
            > "$METADATA_PATH"

        pass "Written: ${METADATA_FILENAME}"
        echo ""

        # --- Build Summary ---
        echo -e "${BOLD}Summary${RESET}"
        echo -e "  ${GREEN}Build completed successfully.${RESET}"

        add_summary ""
        add_summary "- :white_check_mark: Source downloaded and SHA256 verified"
        add_summary "- :white_check_mark: ${PATCHES_COUNT} patches applied"
        add_summary "- :white_check_mark: Build succeeded"
        add_summary "- :white_check_mark: Layout verified: ${LAYOUT_DIRS[*]}"
        if [[ -n "$GLIBC_VERSION" ]]; then
            add_summary "- :white_check_mark: glibc requirement: ${GLIBC_VERSION}"
        fi
        add_summary "- :white_check_mark: Smoke test passed"
        add_summary "- :white_check_mark: Ingot: ${INGOT_FILENAME} (${INGOT_SIZE} bytes)"
        add_summary ""
        add_summary "**Result: :white_check_mark: Build completed**"

        if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
            echo "$SUMMARY_MD" >> "$GITHUB_STEP_SUMMARY"
        fi
    fi

else
    fail "Unknown source type: ${SOURCE_TYPE}"
    exit 3
fi

exit 0
