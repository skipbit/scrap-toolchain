#!/usr/bin/env bash
# measure-glibc.sh — Report the glibc version an LLVM release archive needs
#
# Usage: measure-glibc.sh <archive-url>
#
# Streams a .tar.xz release archive, extracts only the clang and lld
# executables, and reads the GLIBC symbol versions they require. Other tools
# in the archive may require a newer glibc; they are not what a compiler
# toolchain is used for, so they are not measured.
#
# Requires GNU tar (for the --wildcards option).
#
# Output: the highest required glibc version on stdout (e.g. 2.34); the
#         version per executable on stderr
#
# Exit codes:
#   0 = Measured
#   2 = Internal error (missing tools, download failure, executables absent)

set -euo pipefail

URL="${1:?Usage: measure-glibc.sh <archive-url>}"

die() { echo "ERROR: $1" >&2; exit 2; }

for cmd in curl tar xz readelf; do
    command -v "$cmd" > /dev/null || die "$cmd is required"
done

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fsSL --retry 3 "$URL" \
    | tar -xJ -C "$TMP_DIR" --wildcards '*/bin/clang-[0-9]*' '*/bin/lld' \
    || die "cannot extract clang and lld from ${URL}"

max=""
count=0
while IFS= read -r -d '' exe; do
    need=$(readelf --version-info -W "$exe" \
        | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' | sed 's/^GLIBC_//' | sort -uV | tail -1 || true)
    [[ -n "$need" ]] || die "no GLIBC version found in ${exe##*/}"
    echo "${exe##*/}: ${need}" >&2
    max=$(printf '%s\n%s\n' "$max" "$need" | sed '/^$/d' | sort -V | tail -1)
    count=$((count + 1))
done < <(find "$TMP_DIR" -type f -print0)

[[ "$count" -ge 2 ]] || die "expected clang and lld in ${URL}, found ${count} executable(s)"
echo "$max"
