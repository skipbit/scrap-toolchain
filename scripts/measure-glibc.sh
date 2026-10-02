#!/usr/bin/env bash
# measure-glibc.sh — Report the glibc version an ingot needs
#
# Usage: measure-glibc.sh <ingot-directory> [excluded-path ...]
#
# Reads the GLIBC symbol versions of every ELF file in the ingot: executables
# in bin/ and libexec/ as well as shared libraries and runtimes in lib*/.
# Files given by their path relative to the ingot directory (e.g.
# bin/llvm-exegesis) are left out of the measurement; each must be a file in
# the ingot, so that an exclusion does not outlive the file it was written
# for.
#
# Output: the highest required glibc version on stdout (e.g. 2.34); the files
#         that require it on stderr
#
# Exit codes:
#   0 = Measured
#   2 = Internal error (missing tools, excluded path absent, no ELF file
#       requiring glibc)

set -euo pipefail

INGOT_DIR="${1:?Usage: measure-glibc.sh <ingot-directory> [excluded-path ...]}"
INGOT_DIR="${INGOT_DIR%/}"
shift
EXCLUDED=("$@")

die() { echo "ERROR: $1" >&2; exit 2; }

command -v readelf > /dev/null || die "readelf is required"
[[ -d "$INGOT_DIR" ]] || die "${INGOT_DIR} is not a directory"

declare -A IS_EXCLUDED=()
for path in "${EXCLUDED[@]}"; do
    [[ -f "${INGOT_DIR}/${path}" ]] || die "excluded path ${path} is not a file in ${INGOT_DIR}"
    IS_EXCLUDED["$path"]=1
done

# The file list goes through a file rather than process substitution, so
# that a failed find stops the script.
FILE_LIST=$(mktemp)
trap 'rm -f "$FILE_LIST"' EXIT
find "$INGOT_DIR" -type f -print0 > "$FILE_LIST" || die "cannot list ${INGOT_DIR}"

# "<version> <path>" per ELF file that requires glibc
REQUIREMENTS=""
while IFS= read -r -d '' file; do
    rel="${file#"${INGOT_DIR}"/}"
    [[ -z "${IS_EXCLUDED[$rel]:-}" ]] || continue
    [[ "$(head -c 4 "$file" | tr -d '\0')" == $'\x7fELF' ]] || continue
    info=$(readelf --version-info -W "$file") || die "cannot read ${rel}"
    need=$({ grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' <<< "$info" || true; } \
        | sed 's/^GLIBC_//' | sort -uV | tail -1)
    [[ -n "$need" ]] || continue
    REQUIREMENTS+="${need} ${rel}"$'\n'
done < "$FILE_LIST"

[[ -n "$REQUIREMENTS" ]] || die "no ELF file in ${INGOT_DIR} requires glibc"

max=$(cut -d' ' -f1 <<< "${REQUIREMENTS%$'\n'}" | sort -V | tail -1)
grep "^${max//./\\.} " <<< "$REQUIREMENTS" | cut -d' ' -f2- | sort | sed "s/^/${max}: /" >&2
echo "$max"
