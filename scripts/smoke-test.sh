#!/usr/bin/env bash
# smoke-test.sh — Verify an ingot by compiling and running a test program
#
# Usage: smoke-test.sh <ingot-root> <mold-directory>
#
# The mold's test program is built with metadata.components.compiler.
# A C program is then built with metadata.components.c_compiler, so that
# the name the index gives for C sources is checked as well.
#
# On macOS, an ingot that holds libc++ is tested as scrap builds with it:
# linked by the system linker against that libc++, which the program
# must then load.
#
# This script uses a fail-fast approach: each step exits immediately on failure
# rather than accumulating errors, since later steps depend on earlier ones.
#
# Exit codes:
#   0 = Test passed
#   1 = Test failed (compilation error, execution failure, output mismatch)
#   2 = Internal error (missing tools, unexpected failures)

set -euo pipefail

INGOT_ROOT="${1:?Usage: smoke-test.sh <ingot-root> <mold-directory>}"
MOLD_DIR="${2:?Usage: smoke-test.sh <ingot-root> <mold-directory>}"
INGOT_ROOT="${INGOT_ROOT%/}"
MOLD_DIR="${MOLD_DIR%/}"

TIMEOUT=30

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
fail_msg() { echo -e "  ${RED}FAIL${RESET}: $1"; }
warn() { echo -e "  ${YELLOW}WARN${RESET}: $1"; }
info() { echo -e "  ${BOLD}INFO${RESET}: $1"; }

# Resolve a path to its canonical form (resolves symlinks).
# Portable across Linux and macOS via Python.
resolve_path() {
    python3 -c "import os, sys; print(os.path.realpath(sys.argv[1]))" "$1"
}

WORK_DIR=""
cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

# --- Pre-flight checks ---
echo -e "${BOLD}Pre-flight checks${RESET}"

for cmd in python3 jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: $cmd is not installed"
        exit 2
    fi
done

if ! python3 -c "try:
    import tomllib
except ImportError:
    import tomli" 2>/dev/null; then
    echo "Error: Python 3.11+ (tomllib) or tomli package is required"
    exit 2
fi

if [[ ! -d "$INGOT_ROOT" ]]; then
    echo "Error: Ingot root directory not found: ${INGOT_ROOT}"
    exit 2
fi

MOLD_TOML="${MOLD_DIR}/mold.toml"
if [[ ! -f "$MOLD_TOML" ]]; then
    echo "Error: ${MOLD_TOML} not found"
    exit 2
fi

pass "Prerequisites satisfied"
echo ""

# --- Step 1: Parse test configuration and write test files ---
echo -e "${BOLD}1. Parse test configuration${RESET}"

WORK_DIR=$(mktemp -d)

set +e
TEST_DATA=$(python3 -c "
try:
    import tomllib
except ImportError:
    import tomli as tomllib
import json, sys, os

mold_path = sys.argv[1]
work_dir = sys.argv[2]

with open(mold_path, 'rb') as f:
    data = tomllib.load(f)

test = data.get('test')
if not test:
    print('ERROR: [test] section not found in mold.toml', file=sys.stderr)
    sys.exit(1)

components = data.get('metadata', {}).get('components', {})
for name in ('compiler', 'c_compiler'):
    if not components.get(name):
        print(f'ERROR: metadata.components.{name} not found', file=sys.stderr)
        sys.exit(1)

for field in ('hello_world_source', 'compile_command', 'expected_output'):
    if not test.get(field):
        print(f'ERROR: test.{field} is empty or missing', file=sys.stderr)
        sys.exit(1)

with open(os.path.join(work_dir, 'hello.cpp'), 'w') as f:
    f.write(test['hello_world_source'])

with open(os.path.join(work_dir, 'expected'), 'w') as f:
    f.write(test['expected_output'])

json.dump({
    'compile_command': test['compile_command'],
    'compiler': components['compiler'],
    'c_compiler': components['c_compiler'],
}, sys.stdout)
" "$MOLD_TOML" "$WORK_DIR" 2>"${WORK_DIR}/parse_stderr")
PARSE_EXIT=$?
set -e

if [[ "$PARSE_EXIT" -ne 0 ]]; then
    PARSE_ERROR=$(cat "${WORK_DIR}/parse_stderr")
    echo "Error: Failed to parse test configuration: ${PARSE_ERROR}"
    exit 2
fi

COMPILE_CMD=$(echo "$TEST_DATA" | jq -r '.compile_command')
COMPILER_NAME=$(echo "$TEST_DATA" | jq -r '.compiler')
C_COMPILER_NAME=$(echo "$TEST_DATA" | jq -r '.c_compiler')

if [[ -z "$COMPILE_CMD" || -z "$COMPILER_NAME" || -z "$C_COMPILER_NAME" ]]; then
    echo "Error: Incomplete test configuration"
    exit 2
fi

# Reject compiler names that could escape the bin/ directory
check_compiler_name() {
    if [[ "$1" == */* || "$1" == *..* ]]; then
        echo "Error: Invalid compiler name (must not contain '/' or '..'): $1"
        exit 2
    fi
    if ! [[ "$1" =~ ^[A-Za-z0-9._+-]+$ ]]; then
        echo "Error: Invalid compiler name (unexpected characters): $1"
        exit 2
    fi
}
check_compiler_name "$COMPILER_NAME"
check_compiler_name "$C_COMPILER_NAME"

pass "Test configuration parsed: compiler=${COMPILER_NAME}, c_compiler=${C_COMPILER_NAME}"
echo ""

# --- Step 2: Verify compiler exists ---
echo -e "${BOLD}2. Verify compiler${RESET}"

# Fails unless bin/<name> is executable and its canonical path stays
# within the ingot bin/ directory (catches symlink escapes).
verify_in_bin() {
    local key="$1" path="${INGOT_ROOT}/bin/$2" real bin_real
    if [[ ! -x "$path" ]]; then
        fail_msg "${key} not found or not executable: ${path}"
        exit 1
    fi
    real=$(resolve_path "$path")
    bin_real=$(resolve_path "${INGOT_ROOT}/bin")
    if [[ "$real" != "${bin_real}/"* ]]; then
        fail_msg "${key} path resolves outside ingot bin/: ${real}"
        exit 1
    fi
    pass "${key} found: ${path}"
}

COMPILER_PATH="${INGOT_ROOT}/bin/${COMPILER_NAME}"
C_COMPILER_PATH="${INGOT_ROOT}/bin/${C_COMPILER_NAME}"
verify_in_bin compiler "$COMPILER_NAME"
verify_in_bin c_compiler "$C_COMPILER_NAME"
echo ""

# --- Step 3: Expand compile command ---
echo -e "${BOLD}3. Expand compile command${RESET}"

EXPANDED_CMD="${COMPILE_CMD//\{compiler\}/${COMPILER_PATH}}"
info "Command: ${EXPANDED_CMD}"
pass "Placeholders expanded"
echo ""

# --- Step 4: Compile ---
echo -e "${BOLD}4. Compile${RESET}"

# On macOS, pre-built LLVM binaries need the SDK path to find system
# headers (time.h, stdlib.h, etc.). Set SDKROOT if not already set.
if [[ "$(uname -s)" == "Darwin" && -z "${SDKROOT:-}" ]]; then
    if command -v xcrun &>/dev/null; then
        SDKROOT=$(xcrun --show-sdk-path 2>/dev/null || true)
        if [[ -n "$SDKROOT" ]]; then
            export SDKROOT
            info "SDKROOT=${SDKROOT}"
        fi
    fi
fi

# Use word splitting instead of eval to avoid command injection.
# compile_command is expected to be a simple command with arguments
# (e.g., "{compiler} -o hello hello.cpp"), not a shell expression.
read -ra CMD_ARRAY <<< "$EXPANDED_CMD"

# The system linker reads the SDK, which lld may not. libc++ of the
# ingot does not re-export libc++abi.
LIBCXX_DIRS=()
if [[ "$(uname -s)" == "Darwin" ]]; then
    LIBCXX_LIST=$(find "$INGOT_ROOT" -name 'libc++.1.dylib' -exec dirname {} \; | sort -u)
    while IFS= read -r dir; do
        if [[ -n "$dir" ]]; then
            LIBCXX_DIRS+=("$dir")
        fi
    done <<< "$LIBCXX_LIST"
fi
if [[ ${#LIBCXX_DIRS[@]} -gt 0 ]]; then
    SYSTEM_LINKER_CMD=()
    for arg in "${CMD_ARRAY[@]}"; do
        [[ "$arg" == "-fuse-ld=lld" ]] || SYSTEM_LINKER_CMD+=("$arg")
    done
    for dir in "${LIBCXX_DIRS[@]}"; do
        SYSTEM_LINKER_CMD+=(-L "$dir" -Xlinker -rpath -Xlinker "$dir")
    done
    CMD_ARRAY=("${SYSTEM_LINKER_CMD[@]}" -lc++abi)
    info "Command with the system linker: ${CMD_ARRAY[*]}"
fi

set +e
COMPILE_OUTPUT=$(cd "$WORK_DIR" && "${CMD_ARRAY[@]}" 2>&1)
COMPILE_EXIT=$?
set -e

if [[ "$COMPILE_EXIT" -ne 0 ]]; then
    fail_msg "Compilation failed (exit code: ${COMPILE_EXIT})"
    if [[ -n "$COMPILE_OUTPUT" ]]; then
        echo "  --- compiler output ---"
        # shellcheck disable=SC2001  # indents every line of the output
        echo "$COMPILE_OUTPUT" | sed 's/^/  /'
        echo "  ---"
    fi
    exit 1
fi

if [[ ! -x "${WORK_DIR}/hello" ]]; then
    fail_msg "Compiled binary not found: ${WORK_DIR}/hello"
    exit 1
fi

pass "Compilation succeeded"
echo ""

# Bounds the run of the C program (step 5) and the test program (step 6).
TIMEOUT_CMD=""
if command -v timeout &>/dev/null; then
    TIMEOUT_CMD="timeout"
elif command -v gtimeout &>/dev/null; then
    TIMEOUT_CMD="gtimeout"
else
    warn "Neither 'timeout' nor 'gtimeout' found; running without timeout protection"
fi

# --- Step 5: C compiler ---
echo -e "${BOLD}5. C compiler${RESET}"

# Built as the test program is, with the same linker and no other flag,
# and before step 6 adds the ingot lib directories to LD_LIBRARY_PATH.
# It stops at #error when the compiler takes it for C++.
cat > "${WORK_DIR}/hello.c" <<'C_SOURCE'
#ifdef __cplusplus
#error compiled as C++
#endif
#include <stdio.h>
int main(void) {
    printf("Hello, scrap!\n");
    return 0;
}
C_SOURCE
C_FLAGS=()
if [[ " ${CMD_ARRAY[*]} " == *" -fuse-ld=lld "* ]]; then
    C_FLAGS+=(-fuse-ld=lld)
fi
info "Command: ${C_COMPILER_PATH} ${C_FLAGS[*]+${C_FLAGS[*]} }-o hello-c hello.c"

set +e
C_COMPILE_OUTPUT=$(cd "$WORK_DIR" && "$C_COMPILER_PATH" ${C_FLAGS[@]+"${C_FLAGS[@]}"} -o hello-c hello.c 2>&1)
C_COMPILE_EXIT=$?
set -e
if [[ "$C_COMPILE_EXIT" -ne 0 ]]; then
    fail_msg "C compilation failed (exit code: ${C_COMPILE_EXIT})"
    echo "  --- compiler output ---"
    # shellcheck disable=SC2001  # indents every line of the output
    echo "$C_COMPILE_OUTPUT" | sed 's/^/  /'
    echo "  ---"
    exit 1
fi

set +e
if [[ -n "$TIMEOUT_CMD" ]]; then
    C_OUTPUT=$($TIMEOUT_CMD "$TIMEOUT" "${WORK_DIR}/hello-c" 2>&1)
else
    C_OUTPUT=$("${WORK_DIR}/hello-c" 2>&1)
fi
C_RUN_EXIT=$?
set -e
if [[ "$C_RUN_EXIT" -eq 124 && -n "$TIMEOUT_CMD" ]]; then
    fail_msg "C program timed out after ${TIMEOUT} seconds"
    exit 1
fi
if [[ "$C_RUN_EXIT" -ne 0 || "$C_OUTPUT" != "Hello, scrap!" ]]; then
    fail_msg "C program failed (exit code: ${C_RUN_EXIT}, output: ${C_OUTPUT})"
    exit 1
fi

pass "C program compiled with ${C_COMPILER_NAME} and ran"
echo ""

# --- Step 6: Execute ---
echo -e "${BOLD}6. Execute${RESET}"

# On Linux, add ingot lib directories to LD_LIBRARY_PATH so the test
# binary can find libraries shipped with the toolchain (e.g., libstdc++.so
# built by GCC). Without this, the binary may link against the container's
# older libstdc++ and fail with GLIBCXX version errors.
# NOTE: Not set on macOS — DYLD_LIBRARY_PATH conflicts with system
# frameworks and causes crashes. macOS toolchains use @rpath instead.
if [[ "$(uname -s)" == "Linux" ]]; then
    INGOT_LIB="${INGOT_ROOT}/lib"
    INGOT_LIB64="${INGOT_ROOT}/lib64"
    SMOKE_LD_PATH=""
    [[ -d "$INGOT_LIB" ]] && SMOKE_LD_PATH="${INGOT_LIB}"
    [[ -d "$INGOT_LIB64" ]] && SMOKE_LD_PATH="${SMOKE_LD_PATH:+${SMOKE_LD_PATH}:}${INGOT_LIB64}"
    if [[ -n "$SMOKE_LD_PATH" ]]; then
        export LD_LIBRARY_PATH="${SMOKE_LD_PATH}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    fi
fi

set +e
if [[ -n "$TIMEOUT_CMD" ]]; then
    $TIMEOUT_CMD "$TIMEOUT" "${WORK_DIR}/hello" > "${WORK_DIR}/actual" 2>&1
    RUN_EXIT=$?
else
    "${WORK_DIR}/hello" > "${WORK_DIR}/actual" 2>&1
    RUN_EXIT=$?
fi
set -e

# GNU coreutils timeout returns 124 when the command times out
if [[ "$RUN_EXIT" -eq 124 && -n "$TIMEOUT_CMD" ]]; then
    fail_msg "Execution timed out after ${TIMEOUT} seconds"
    exit 1
fi

if [[ "$RUN_EXIT" -ne 0 ]]; then
    fail_msg "Execution failed (exit code: ${RUN_EXIT})"
    if [[ -s "${WORK_DIR}/actual" ]]; then
        echo "  --- program output ---"
        head -20 "${WORK_DIR}/actual" | sed 's/^/  /'
        echo "  ---"
    fi
    exit 1
fi

pass "Execution succeeded"

# dyld prints each library it loads as "dyld[<pid>]: <path>".
if [[ ${#LIBCXX_DIRS[@]} -gt 0 ]]; then
    set +e
    if [[ -n "$TIMEOUT_CMD" ]]; then
        $TIMEOUT_CMD "$TIMEOUT" env DYLD_PRINT_LIBRARIES=1 "${WORK_DIR}/hello" > /dev/null 2> "${WORK_DIR}/dyld"
    else
        DYLD_PRINT_LIBRARIES=1 "${WORK_DIR}/hello" > /dev/null 2> "${WORK_DIR}/dyld"
    fi
    set -e
    if ! LOADED_LIBCXX=$(grep -o '/[^ ]*/libc++\.1\.dylib$' "${WORK_DIR}/dyld"); then
        fail_msg "dyld did not report loading libc++.1.dylib"
        exit 1
    fi
    INGOT_REAL=$(resolve_path "$INGOT_ROOT")
    while IFS= read -r lib; do
        if [[ "$(resolve_path "$lib")" != "${INGOT_REAL}/"* ]]; then
            fail_msg "libc++ loaded from outside the ingot: ${lib} (all loaded: ${LOADED_LIBCXX//$'\n'/, })"
            exit 1
        fi
    done <<< "$LOADED_LIBCXX"
    pass "libc++ loaded from the ingot: ${LOADED_LIBCXX//$'\n'/, }"
fi
echo ""

# --- Step 7: Compare output ---
echo -e "${BOLD}7. Compare output${RESET}"

if diff -q "${WORK_DIR}/expected" "${WORK_DIR}/actual" &>/dev/null; then
    pass "Output matches expected"
else
    fail_msg "Output mismatch"
    echo "  --- diff (expected vs actual) ---"
    diff "${WORK_DIR}/expected" "${WORK_DIR}/actual" | head -20 | sed 's/^/  /'
    echo "  ---"
    exit 1
fi
echo ""

# --- Summary ---
echo -e "${BOLD}Summary${RESET}"
echo -e "  ${GREEN}Smoke test passed.${RESET}"
