#!/usr/bin/env bash
# check-scrap-reads-index.sh — Check that released scrap can read an index
#
# Usage: check-scrap-reads-index.sh <index.toml>
#
# Serves the index on this machine, and has each release of scrap that
# takes SCRAP_TOOLCHAIN_INDEX look in it for a toolchain it cannot list.
# A scrap that read the index answers that nothing matches.
#
# Each release is also given a copy of the index with a status that no
# scrap knows, which it must refuse. This shows that the check can fail.
#
# Requires gh; in GitHub Actions, GH_TOKEN must be set.
#
# Exit codes:
#   0 = Every release read the index and refused the copy
#   1 = A release did not read the index, or did not refuse the copy
#   2 = Internal error (missing tools, a release that cannot be fetched)

set -euo pipefail

INDEX="${1:?Usage: check-scrap-reads-index.sh <index.toml>}"

SCRAP_REPO="skipbit/scrap"
# The first release that reads SCRAP_TOOLCHAIN_INDEX.
FIRST_VERSION="0.4.0"
SPECIFIER="nosuch@1"
READ_LINE="error: no toolchain matches '${SPECIFIER}'"
REFUSED_PATTERN='^error: cannot fetch the toolchain index: line [0-9]+: toolchains\[[0-9]+\]\.status: '

for cmd in gh python3 sha256sum tar timeout; do
    command -v "$cmd" > /dev/null || { echo "Error: ${cmd} is required"; exit 2; }
done

WORK_DIR=$(mktemp -d)
SERVER_PID=""
cleanup() {
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" 2> /dev/null || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

SERVED="${WORK_DIR}/served"
mkdir -p "$SERVED"
cp "$INDEX" "${SERVED}/index.toml"

python3 - "${SERVED}/index.toml" "${SERVED}/refused.toml" <<'EOF' || exit 2
import re, sys
with open(sys.argv[1]) as f:
    text = f.read()
changed, count = re.subn(r'^status = ".*"$', 'status = "unknown-state"', text, count=1, flags=re.M)
if count != 1:
    sys.exit('Error: the index has no status to change')
with open(sys.argv[2], 'w') as f:
    f.write(changed)
EOF

# The server takes a free port and writes it to a file once it listens.
python3 - "$SERVED" "${WORK_DIR}/port" > "${WORK_DIR}/server.log" 2>&1 <<'EOF' &
import functools, http.server, os, sys
served, port_file = sys.argv[1:]
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=served)
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
with open(port_file + '.tmp', 'w') as f:
    f.write(str(server.server_port))
os.rename(port_file + '.tmp', port_file)
server.serve_forever()
EOF
SERVER_PID=$!
for _ in $(seq 50); do
    [[ -f "${WORK_DIR}/port" ]] && break
    sleep 0.2
done
if [[ ! -f "${WORK_DIR}/port" ]]; then
    echo "Error: the index server did not start"
    cat "${WORK_DIR}/server.log"
    exit 2
fi
PORT=$(cat "${WORK_DIR}/port")

if ! TAGS=$(gh release list -R "$SCRAP_REPO" --exclude-drafts --exclude-pre-releases --limit 100 --json tagName --jq '.[].tagName'); then
    echo "Error: cannot list the releases of ${SCRAP_REPO}"
    exit 2
fi
if ! VERSIONS=$(python3 - "$FIRST_VERSION" "$TAGS" <<'EOF'
import re, sys
first = tuple(map(int, sys.argv[1].split('.')))
versions = []
for tag in sys.argv[2].split():
    match = re.fullmatch(r'v(\d+)\.(\d+)\.(\d+)', tag)
    if match and tuple(map(int, match.groups())) >= first:
        versions.append(tuple(map(int, match.groups())))
for version in sorted(versions):
    print('.'.join(map(str, version)))
EOF
); then
    echo "Error: cannot read the release tags of ${SCRAP_REPO}"
    exit 2
fi
if [[ -z "$VERSIONS" ]]; then
    echo "Error: no release of ${SCRAP_REPO} from ${FIRST_VERSION} on"
    exit 2
fi

# Prints the first line scrap writes when it looks in the served file
# for SPECIFIER. Each run starts from an empty SCRAP_HOME, since scrap
# answers from a saved copy when it cannot read the index.
first_line() {
    local scrap="$1" file="$2" home
    home=$(mktemp -d -p "$WORK_DIR")
    # scrap exits with 1 whether or not it read the index.
    set +e
    SCRAP_HOME="$home" SCRAP_TOOLCHAIN_INDEX="http://127.0.0.1:${PORT}/${file}" \
        timeout 60 "$scrap" toolchain install "$SPECIFIER" > "${home}.out" 2>&1
    set -e
    head -n 1 "${home}.out"
}

FAILED=0
while IFS= read -r version; do
    dir="${WORK_DIR}/scrap-${version}"
    archive="scrap-${version}-linux-x86_64.tar.gz"
    mkdir -p "$dir"
    if ! gh release download "v${version}" -R "$SCRAP_REPO" -D "$dir" -p "$archive" -p "${archive}.sha256"; then
        echo "Error: cannot download ${archive}"
        exit 2
    fi
    if ! (cd "$dir" && sha256sum -c "${archive}.sha256"); then
        echo "Error: ${archive} does not match its checksum"
        exit 2
    fi
    if ! tar -xzf "${dir}/${archive}" -C "$dir"; then
        echo "Error: cannot extract ${archive}"
        exit 2
    fi
    scrap="${dir}/scrap-${version}-linux-x86_64/scrap"
    if [[ ! -x "$scrap" ]]; then
        echo "Error: ${archive} has no scrap at scrap-${version}-linux-x86_64/scrap"
        exit 2
    fi

    read_answer=$(first_line "$scrap" index.toml)
    if [[ "$read_answer" == "$READ_LINE" ]]; then
        echo "PASS: scrap ${version} read the index"
    else
        echo "FAIL: scrap ${version} did not read the index: ${read_answer}"
        FAILED=1
    fi

    refused_answer=$(first_line "$scrap" refused.toml)
    if [[ "$refused_answer" =~ $REFUSED_PATTERN ]]; then
        echo "PASS: scrap ${version} refused the copy with an unknown status"
    else
        echo "FAIL: scrap ${version} did not refuse the copy with an unknown status: ${refused_answer}"
        FAILED=1
    fi
done <<< "$VERSIONS"

if [[ "$FAILED" -ne 0 ]]; then
    exit 1
fi
