#!/usr/bin/env bash
# rebuild-libunwind.sh — Replace the libunwind of an LLVM ingot on macOS
#
# Usage: rebuild-libunwind.sh <ingot-directory> <llvm-source-directory>
#
# Builds libunwind from the LLVM source with the clang of the ingot and
# the linker of the system, for the same minimum macOS as the
# lib/libunwind.1.0.dylib of the ingot, and puts it in place of that
# file. The new file must be linked by Apple's ld and keep the install
# name, the minimum macOS and the exported symbols of the one it replaces.
#
# Exit codes:
#   0 = Replaced
#   2 = Validation error (no libunwind in the ingot, build failed, result
#       differs from the file it replaces)
#   3 = Internal error (missing tools)

set -euo pipefail

INGOT_DIR="${1:?Usage: rebuild-libunwind.sh <ingot-directory> <llvm-source-directory>}"
SOURCE_DIR="${2:?Usage: rebuild-libunwind.sh <ingot-directory> <llvm-source-directory>}"
INGOT_DIR="${INGOT_DIR%/}"
SOURCE_DIR="${SOURCE_DIR%/}"

LIBRARY="lib/libunwind.1.0.dylib"
# LC_BUILD_VERSION names the linker as tool 3 for Apple's ld.
APPLE_LD_TOOL=3

invalid() { echo "ERROR: $1" >&2; exit 2; }
internal() { echo "ERROR: $1" >&2; exit 3; }

for cmd in cmake otool nm xcrun; do
    command -v "$cmd" > /dev/null || internal "${cmd} is required"
done

TARGET="${INGOT_DIR}/${LIBRARY}"
[[ -f "$TARGET" && ! -L "$TARGET" ]] || invalid "${LIBRARY} is not a regular file in ${INGOT_DIR}"
[[ -d "${SOURCE_DIR}/runtimes" && -d "${SOURCE_DIR}/libunwind" ]] \
    || invalid "${SOURCE_DIR} is not an LLVM source tree"

# Prints "<tool> <minos>" from the LC_BUILD_VERSION of a Mach-O file.
build_version_of() {
    local commands
    commands=$(otool -l "$1") || internal "cannot read ${1}"
    awk '/cmd LC_BUILD_VERSION/ { b = 1 }
         b && $1 == "minos" { minos = $2 }
         b && $1 == "tool" { tool = $2 }
         b && $1 == "version" && tool != "" { print tool, minos; exit }' <<< "$commands"
}

# Prints the install name of a dylib.
install_name_of() {
    local listing
    listing=$(otool -D "$1") || internal "cannot read ${1}"
    sed -n 2p <<< "$listing"
}

# Prints the names of the exported symbols of a dylib.
exported_of() {
    local listing
    listing=$(nm -gU "$1") || internal "cannot list the symbols of ${1}"
    awk 'NF { print $NF }' <<< "$listing" | sort -u
}

TARGET_VERSION=$(build_version_of "$TARGET")
read -r _ MINOS <<< "$TARGET_VERSION"
[[ -n "$MINOS" ]] || invalid "${LIBRARY} has no minimum macOS"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path)}"
export SDKROOT
cmake -S "${SOURCE_DIR}/runtimes" -B "${WORK}/build" \
    -DLLVM_ENABLE_RUNTIMES=libunwind \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MINOS" \
    -DCMAKE_C_COMPILER="${INGOT_DIR}/bin/clang" \
    -DCMAKE_CXX_COMPILER="${INGOT_DIR}/bin/clang++" \
    -DLIBUNWIND_ENABLE_STATIC=OFF \
    -DLIBUNWIND_INCLUDE_TESTS=OFF \
    -DLIBUNWIND_INCLUDE_DOCS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    > "${WORK}/configure.log" 2>&1 \
    || { tail -40 "${WORK}/configure.log" >&2; invalid "cannot configure libunwind"; }
cmake --build "${WORK}/build" --target unwind_shared -j "$(sysctl -n hw.ncpu)" \
    > "${WORK}/build.log" 2>&1 \
    || { tail -40 "${WORK}/build.log" >&2; invalid "cannot build libunwind"; }

BUILT=$(find "${WORK}/build" -name "$(basename "$LIBRARY")" -type f -print -quit)
[[ -n "$BUILT" ]] || invalid "the build made no $(basename "$LIBRARY")"

BUILT_VERSION=$(build_version_of "$BUILT")
read -r BUILT_TOOL BUILT_MINOS <<< "$BUILT_VERSION"
[[ "$BUILT_TOOL" == "$APPLE_LD_TOOL" ]] \
    || invalid "the new libunwind is linked by tool ${BUILT_TOOL}, not Apple's ld"
[[ "$BUILT_MINOS" == "$MINOS" ]] \
    || invalid "the new libunwind is for macOS ${BUILT_MINOS}, not ${MINOS}"

TARGET_NAME=$(install_name_of "$TARGET")
BUILT_NAME=$(install_name_of "$BUILT")
[[ -n "$TARGET_NAME" ]] || invalid "${LIBRARY} has no install name"
[[ "$BUILT_NAME" == "$TARGET_NAME" ]] \
    || invalid "the install name differs: ${BUILT_NAME} instead of ${TARGET_NAME}"

TARGET_EXPORTED=$(exported_of "$TARGET")
BUILT_EXPORTED=$(exported_of "$BUILT")
if ! diff <(echo "$TARGET_EXPORTED") <(echo "$BUILT_EXPORTED") >&2; then
    invalid "the exported symbols differ (< ingot, > new)"
fi
EXPORTED=$(wc -l <<< "$BUILT_EXPORTED" | tr -d ' ')

cp "$BUILT" "$TARGET"
echo "Replaced ${LIBRARY}: Apple's ld, macOS ${MINOS}, ${TARGET_NAME}, ${EXPORTED} exported symbols"
