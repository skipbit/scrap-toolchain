#!/usr/bin/env bash
# check-scrap-runs-toolchains.sh — Check that scrap installs toolchains and
# runs what it builds with them, on macOS
#
# Usage: check-scrap-runs-toolchains.sh <scrap> <specifier>...
#
# For each specifier, installs the toolchain into an empty SCRAP_HOME,
# builds a project that throws and catches an exception and uses RTTI,
# and runs it with `scrap run` and on its own. The program must print
# ok=2 and exit with 0 both times, and on its own it must load libc++,
# libc++abi and libunwind from the toolchain. The toolchain is removed
# before the next one.
#
# scrap reads the index that SCRAP_TOOLCHAIN_INDEX names, if it is set.
#
# Exit codes:
#   0 = Every toolchain passed
#   1 = A toolchain failed
#   2 = Usage or internal error (wrong platform, scrap cannot run)

set -uo pipefail

[[ $# -ge 2 ]] || { echo "Usage: check-scrap-runs-toolchains.sh <scrap> <specifier>..."; exit 2; }
SCRAP="$1"
shift

PROJECT="throwcheck"
LIBRARIES=(libc++ libc++abi libunwind)

[[ "$(uname -s)" == "Darwin" ]] || { echo "Error: this check runs on macOS"; exit 2; }
VERSION=$("$SCRAP" --version) || { echo "Error: ${SCRAP} cannot run"; exit 2; }
echo "${VERSION}, macOS $(sw_vers -productVersion), $(uname -m)"

# The real path, since dyld reports libraries by it.
WORK_DIR=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK_DIR"' EXIT

LOG="${WORK_DIR}/log"
export SCRAP_HOME="${WORK_DIR}/home"

# Prints the path of each library dyld loads for a program.
loaded_libraries() {
    DYLD_PRINT_LIBRARIES=1 "$1" 2>&1 > /dev/null | sed -n 's/^dyld\[[0-9]*\]: [^ ]* //p'
}

# Prints a failed step of a toolchain and the log of the step.
fail() {
    echo "FAIL: $1: $2"
    sed 's/^/  /' "$LOG"
}

# Writes a program that throws and catches an exception and uses RTTI.
write_program() {
    cat > "$1" <<'EOF'
#include <cstdio>
#include <stdexcept>
#include <typeinfo>

struct Base {
    virtual ~Base() = default;
};
struct Derived : Base {};

int main() {
    int ok = 0;
    try {
        throw std::runtime_error("thrown");
    } catch (const std::exception&) {
        ok += 1;
    }
    Derived derived;
    Base* base = &derived;
    if (dynamic_cast<Derived*>(base) != nullptr && typeid(*base) == typeid(Derived)) {
        ok += 1;
    }
    std::printf("ok=%d\n", ok);
    return ok == 2 ? 0 : 1;
}
EOF
}

# Checks one toolchain. Prints a line for each step and returns 1 on the
# first failure.
check() {
    local spec="$1" root rc program loaded name path
    rm -rf "$SCRAP_HOME" "${WORK_DIR:?}/${PROJECT}"
    echo "${spec}:"

    if ! "$SCRAP" toolchain install "$spec" > "$LOG" 2>&1; then
        fail "$spec" install; return 1
    fi
    "$SCRAP" toolchain info "$spec" > "$LOG" 2>&1
    echo "  source: $(sed -n 's/^source: *//p' "$LOG")"
    root=$(sed -n 's/^directory: *//p' "$LOG")
    [[ -n "$root" ]] || { fail "$spec" "no directory in toolchain info"; return 1; }

    (cd "$WORK_DIR" && "$SCRAP" new "$PROJECT") > "$LOG" 2>&1 \
        || { fail "$spec" new; return 1; }
    write_program "${WORK_DIR}/${PROJECT}/src/main.cpp"

    (cd "${WORK_DIR}/${PROJECT}" && SCRAP_TOOLCHAIN="$spec" "$SCRAP" run) > "$LOG" 2>&1
    rc=$?
    if [[ "$rc" -ne 0 || "$(tail -n 1 "$LOG")" != "ok=2" ]]; then
        fail "$spec" "scrap run (exit code: ${rc})"; return 1
    fi
    echo "  scrap run: ok=2"

    program="${WORK_DIR}/${PROJECT}/build/debug/bin/${PROJECT}"
    "$program" > "$LOG" 2>&1
    rc=$?
    if [[ "$rc" -ne 0 || "$(cat "$LOG")" != "ok=2" ]]; then
        fail "$spec" "direct run (exit code: ${rc})"; return 1
    fi
    echo "  direct run: ok=2"

    loaded=$(loaded_libraries "$program")
    for name in "${LIBRARIES[@]}"; do
        path=$(grep -m 1 "/${name}\.[0-9.]*dylib\$" <<< "$loaded")
        if [[ "$path" != "${root}/"* ]]; then
            echo "FAIL: ${spec}: ${name} is not loaded from the toolchain: ${path:-not loaded}"; return 1
        fi
    done
    echo "  loaded from the toolchain: ${LIBRARIES[*]}"

    "$SCRAP" toolchain uninstall "$spec" > "$LOG" 2>&1 \
        || { fail "$spec" uninstall; return 1; }
    echo "PASS: ${spec}"
}

FAILED=()
for spec in "$@"; do
    check "$spec" || FAILED+=("$spec")
done

echo "=== $(( $# - ${#FAILED[@]} )) passed, ${#FAILED[@]} failed ==="
if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo "Failed: ${FAILED[*]}"
    exit 1
fi
