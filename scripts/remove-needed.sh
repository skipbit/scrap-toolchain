#!/usr/bin/env bash
# remove-needed.sh — Remove a DT_NEEDED entry that an ELF file does not use
#
# Usage: remove-needed.sh <ingot-directory> <file> <library>
#
# <file> is the path of an ELF file relative to the ingot directory (e.g.
# lib/x86_64-unknown-linux-gnu/libc++.so.1.0) and <library> a name in its
# DT_NEEDED (e.g. libatomic.so.1). The entry is removed only when the file
# takes no symbol from the library: no undefined symbol of the file is
# defined by the library installed on this machine, and no symbol version of
# the library is required. Afterwards the entry must be gone.
#
# Exit codes:
#   0 = Removed
#   2 = Validation error (file not an ELF file, library not in DT_NEEDED,
#       symbols taken from the library, entry still present)
#   3 = Internal error (missing tools, library not installed)

set -euo pipefail

INGOT_DIR="${1:?Usage: remove-needed.sh <ingot-directory> <file> <library>}"
FILE="${2:?Usage: remove-needed.sh <ingot-directory> <file> <library>}"
LIBRARY="${3:?Usage: remove-needed.sh <ingot-directory> <file> <library>}"
INGOT_DIR="${INGOT_DIR%/}"

invalid() { echo "ERROR: $1" >&2; exit 2; }
internal() { echo "ERROR: $1" >&2; exit 3; }

for cmd in readelf nm patchelf ldconfig; do
    command -v "$cmd" > /dev/null || internal "${cmd} is required"
done

if [[ "$FILE" == /* || "$FILE" == ../* || "$FILE" == */../* || \
      "$FILE" == */.. || "$FILE" == .. ]]; then
    invalid "${FILE} contains traversal or is absolute"
fi
TARGET="${INGOT_DIR}/${FILE}"
[[ -f "$TARGET" && ! -L "$TARGET" ]] || invalid "${FILE} is not a regular file in ${INGOT_DIR}"
[[ "$(head -c 4 "$TARGET" | tr -d '\0')" == $'\x7fELF' ]] || invalid "${FILE} is not an ELF file"

# Prints the DT_NEEDED entries of an ELF file, one per line.
needed_of() {
    local dynamic
    dynamic=$(readelf -d -W "$1") || internal "cannot read ${1}"
    { grep -F '(NEEDED)' <<< "$dynamic" || true; } | sed 's/.*\[\(.*\)\]$/\1/'
}

NEEDED=$(needed_of "$TARGET")
grep -qxF "$LIBRARY" <<< "$NEEDED" || invalid "${LIBRARY} is not in the DT_NEEDED of ${FILE}"

VERSION_INFO=$(readelf -V -W "$TARGET") || internal "cannot read ${FILE}"
if awk -v lib="$LIBRARY" '{ for (i = 1; i < NF; i++) if ($i == "File:" && $(i + 1) == lib) found = 1 }
        END { exit !found }' <<< "$VERSION_INFO"; then
    invalid "${FILE} requires a symbol version of ${LIBRARY}"
fi

# ldconfig tags each library with the machine it is built for.
HEADER=$(readelf -h "$TARGET") || internal "cannot read ${FILE}"
case "$HEADER" in
    *"Machine:"*"X86-64"*) TAG="x86-64" ;;
    *"Machine:"*"AArch64"*) TAG="AArch64" ;;
    *) internal "unsupported machine of ${FILE}" ;;
esac
CACHE=$(ldconfig -p) || internal "cannot read the ldconfig cache"
LIBRARY_PATH=$({ grep -F "	${LIBRARY} (" <<< "$CACHE" | grep -F "${TAG}" || true; } \
    | head -1 | sed 's/.* => //')
[[ -n "$LIBRARY_PATH" ]] || internal "${LIBRARY} for ${TAG} is not installed on this machine"

# Prints the dynamic symbols nm lists with <option>, without their versions.
symbols_of() {
    local listing
    listing=$(nm -D "$1" "$2") || internal "cannot list the symbols of ${2}"
    awk 'NF { print $NF }' <<< "$listing" | sed 's/@.*//' | sort -u
}

UNDEFINED=$(symbols_of --undefined-only "$TARGET")
DEFINED=$(symbols_of --defined-only "$LIBRARY_PATH")
TAKEN=$(comm -12 <(echo "$UNDEFINED") <(echo "$DEFINED"))
if [[ -n "$TAKEN" ]]; then
    echo "${FILE} takes these symbols from ${LIBRARY_PATH}:" >&2
    echo "$TAKEN" >&2
    invalid "${LIBRARY} is used by ${FILE}"
fi

patchelf --remove-needed "$LIBRARY" "$TARGET" || internal "patchelf failed on ${FILE}"

NEEDED=$(needed_of "$TARGET")
if grep -qxF "$LIBRARY" <<< "$NEEDED"; then
    invalid "${LIBRARY} is still in the DT_NEEDED of ${FILE}"
fi
echo "Removed ${LIBRARY} from ${FILE} (no symbol taken from ${LIBRARY_PATH})"
