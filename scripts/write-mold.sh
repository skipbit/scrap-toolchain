#!/usr/bin/env bash
# write-mold.sh — Write the mold of a new release from the mold of an earlier one
#
# Usage: write-mold.sh <base-mold-directory> <version> [missing-file ...]
#   Run from the repository root directory.
#
# Copies the base mold and changes only the version, the download URLs and
# their checksums; everything else is carried over for review. Binaries whose
# file names are given as missing-file are left out.
#
# Checksums of GitHub release assets come from the digest GitHub records for
# them. Anything else is downloaded and hashed.
#
# Output: the new mold directory on stdout
#
# Environment variables:
#   GH_TOKEN — GitHub token for the release API (optional locally when gh is
#              logged in)
#
# Exit codes:
#   0 = Mold written
#   2 = Internal error (missing tools, mold already present, checksum
#       unavailable, unexpected base mold layout)

set -euo pipefail

BASE_DIR="${1:?Usage: write-mold.sh <base-mold-directory> <version> [missing-file ...]}"
BASE_DIR="${BASE_DIR%/}"
VERSION="${2:?Usage: write-mold.sh <base-mold-directory> <version> [missing-file ...]}"
shift 2
MISSING=("$@")

log() { echo "$1" >&2; }
die() { echo "ERROR: $1" >&2; exit 2; }

for cmd in gh jq curl python3 sha256sum; do
    command -v "$cmd" > /dev/null || die "$cmd is required"
done

BASE_VERSION=$(basename "$BASE_DIR")
FAMILY=$(basename "$(dirname "$BASE_DIR")")
NEW_DIR="$(dirname "$BASE_DIR")/${VERSION}"
[[ -f "${BASE_DIR}/mold.toml" ]] || die "${BASE_DIR}/mold.toml not found"
[[ ! -e "$NEW_DIR" ]] || die "${NEW_DIR} already exists"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Args: $1 = URL. Output: sha256 hex digest
checksum() {
    local url="$1" digest=""
    if [[ "$url" =~ ^https://github\.com/([^/]+/[^/]+)/releases/download/([^/]+)/([^/]+)$ ]]; then
        # A failed lookup falls through to downloading, which is slower but
        # gives the same answer.
        digest=$(gh api "repos/${BASH_REMATCH[1]}/releases/tags/${BASH_REMATCH[2]}" \
            | jq -r --arg name "${BASH_REMATCH[3]}" \
                '.assets[] | select(.name == $name) | .digest // empty' || true)
        digest="${digest#sha256:}"
    fi
    if [[ -z "$digest" ]]; then
        log "  downloading ${url##*/} to hash it"
        curl -fsSL --retry 3 -o "${TMP_DIR}/download" "$url" || die "cannot download ${url}"
        digest=$(sha256sum "${TMP_DIR}/download" | cut -d' ' -f1)
        rm -f "${TMP_DIR}/download"
    fi
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "no sha256 for ${url}"
    echo "$digest"
}

# The new URLs are the base URLs with the version replaced.
NEW_URLS=$(python3 - "${BASE_DIR}/mold.toml" "$BASE_VERSION" "$VERSION" <<'EOF'
import sys, tomllib
path, old, new = sys.argv[1:]
with open(path, 'rb') as f:
    source = tomllib.load(f)['source']
urls = [b['url'] for b in source.get('binaries', [])]
if 'build' in source:
    urls.append(source['build']['source_url'])
for url in urls:
    if old not in url:
        sys.exit(f'{url} does not contain {old}')
    print(url.replace(old, new))
EOF
) || die "cannot derive the new URLs from ${BASE_DIR}/mold.toml"

CHECKSUMS='{}'
while read -r url; do
    name="${url##*/}"
    if [[ " ${MISSING[*]} " == *" ${name} "* ]]; then
        continue
    fi
    log "${FAMILY} ${VERSION}: ${name}"
    digest=$(checksum "$url")
    CHECKSUMS=$(jq --arg u "$url" --arg d "$digest" '. + {($u): $d}' <<< "$CHECKSUMS")
done <<< "$NEW_URLS"

mkdir -p "$NEW_DIR"
python3 - "${BASE_DIR}/mold.toml" "${NEW_DIR}/mold.toml" "$BASE_VERSION" "$VERSION" \
    "$CHECKSUMS" "${MISSING[@]}" <<'EOF' || { rm -rf "$NEW_DIR"; die "cannot write ${NEW_DIR}/mold.toml"; }
import json, re, sys, tomllib
src, dst, old, new, checksums, *missing = sys.argv[1:]
checksums = json.loads(checksums)

# Edits the text rather than re-serializing, so that comments and layout
# carry over. A block runs from a header line (or the start of the file) to
# the next header line, and is decided on its own: version first, then its
# own url line (not one carried over from an earlier block).
def process_block(block):
    out, url = [], None
    for line in block:
        m = re.match(r'(\s*version\s*=\s*)"(.*)"', line)
        if m and m.group(2) == old:
            line = f'{m.group(1)}"{new}"\n'
        m = re.match(r'(\s*(?:url|source_url)\s*=\s*)"(.*)"', line)
        if m:
            url = m.group(2).replace(old, new)
        out.append(line)
    if url is None:
        return out
    if url.rsplit('/', 1)[1] in missing:
        return []
    if url not in checksums:
        sys.exit(f'no checksum for {url}; this URL key is not supported')
    result = []
    for line in out:
        m = re.match(r'(\s*(?:url|source_url)\s*=\s*)"(.*)"', line)
        if m:
            line = f'{m.group(1)}"{url}"\n'
        m = re.match(r'(\s*(?:sha256|source_sha256)\s*=\s*)"(.*)"', line)
        if m:
            line = f'{m.group(1)}"{checksums[url]}"\n'
        result.append(line)
    return result

lines = open(src).read().splitlines(keepends=True)
blocks, current = [], []
for line in lines:
    if line.startswith('[') and current:
        blocks.append(current)
        current = []
    current.append(line)
blocks.append(current)

out = []
for block in blocks:
    out += process_block(block)
open(dst, 'w').write(''.join(out))

# The result must parse, name the new version, and every binary and build
# source must match the checksums exactly.
with open(dst, 'rb') as f:
    mold = tomllib.load(f)
source = mold['source']
pairs = [(b['url'], b['sha256']) for b in source.get('binaries', [])]
if 'build' in source:
    pairs.append((source['build']['source_url'], source['build']['source_sha256']))
if mold['metadata']['version'] != new:
    sys.exit(f'version not replaced: expected {new}')
for url, sha256 in pairs:
    if not re.fullmatch(r'[0-9a-f]{64}', sha256):
        sys.exit(f'{url} has no valid checksum')
    if checksums.get(url) != sha256:
        sys.exit(f'{url} does not have the expected checksum')
if sorted(u for u, _ in pairs) != sorted(checksums):
    sys.exit('URLs do not match the checksums')
EOF

echo "$NEW_DIR"
