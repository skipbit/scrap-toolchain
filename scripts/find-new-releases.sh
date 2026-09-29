#!/usr/bin/env bash
# find-new-releases.sh — List upstream releases that have no mold yet
#
# Usage: find-new-releases.sh
#   Run from the repository root directory.
#
# For each family under molds/, lists the stable upstream releases newer
# than the newest registered version. Older releases are not listed.
#
# Upstream uploads release files some hours after tagging, and occasionally
# never uploads one of them. A release with files missing is left for a
# later run until it is GRACE_DAYS old, and listed with what it has after
# that. A release with none of its files is never listed.
#
# Output: JSON array on stdout, one object per release:
#   {"id": "llvm-23.1.0", "family": "llvm", "version": "23.1.0",
#    "base": "molds/llvm/22.1.0",
#    "missing": ["LLVM-23.1.0-macOS-ARM64.tar.xz"]}
# where base is the mold the new one is derived from, and missing lists the
# files of the base mold that this release does not have.
#
# Environment variables:
#   GH_TOKEN — GitHub token for the release API (optional locally when gh is
#              logged in)
#
# Exit codes:
#   0 = Listed (possibly empty)
#   2 = Internal error (missing tools, unknown family, upstream unreachable)

set -euo pipefail

MOLDS_DIR="molds"
GNU_GCC_URL="https://ftp.gnu.org/gnu/gcc/"
GRACE_DAYS=7

log() { echo "$1" >&2; }
die() { echo "ERROR: $1" >&2; exit 2; }

for cmd in gh jq curl python3; do
    command -v "$cmd" > /dev/null || die "$cmd is required"
done

# Stable versions are plain X.Y.Z; release candidates never match.
STABLE_RE='^[0-9]+\.[0-9]+\.[0-9]+$'

# Prints the file names the base mold downloads, with its version replaced.
# Args: $1 = base mold dir, $2 = base version, $3 = new version
expected_files() {
    python3 - "$1/mold.toml" "$2" "$3" <<'EOF'
import sys, tomllib
path, old, new = sys.argv[1:]
with open(path, 'rb') as f:
    source = tomllib.load(f)['source']
urls = [b['url'] for b in source.get('binaries', [])]
if 'build' in source:
    urls.append(source['build']['source_url'])
for url in urls:
    print(url.rsplit('/', 1)[1].replace(old, new))
EOF
}

# Args: none
# Output: "<version>\t<published at>\t<space-separated asset names>" per release
llvm_releases() {
    gh api --paginate 'repos/llvm/llvm-project/releases?per_page=100' \
        --jq '.[] | select(.draft == false and .prerelease == false)
              | select(.tag_name | startswith("llvmorg-"))
              | "\(.tag_name | ltrimstr("llvmorg-"))\t\(.published_at)\t\([.assets[].name] | join(" "))"' \
        || die "cannot list LLVM releases"
}

# Args: none
# Output: one version per line. The GNU mirror has no release date, and a
# release has a single file, so the date is never needed.
gcc_versions() {
    local listing
    listing=$(curl -fsSL --retry 3 "$GNU_GCC_URL") || die "cannot list $GNU_GCC_URL"
    grep -oE 'href="gcc-[0-9]+\.[0-9]+\.[0-9]+/"' <<< "$listing" \
        | sed -E 's/^href="gcc-//; s|/"$||' | sort -uV
}

# Args: $1 = version, $2 = file name. Succeeds when the GNU mirror has it.
gcc_file_published() {
    curl -fsSI --retry 3 -o /dev/null "${GNU_GCC_URL}gcc-$1/$2"
}

# Args: $1 = version a, $2 = version b. Succeeds when a > b.
version_gt() {
    [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

RESULT='[]'

# Args: $1 = release date (ISO 8601). Succeeds when older than GRACE_DAYS.
past_grace() {
    [[ -n "$1" ]] || return 1
    python3 - "$1" "$GRACE_DAYS" <<'EOF'
import sys
from datetime import datetime, timedelta, timezone
published = datetime.fromisoformat(sys.argv[1].replace('Z', '+00:00'))
grace = timedelta(days=int(sys.argv[2]))
sys.exit(0 if datetime.now(timezone.utc) - published > grace else 1)
EOF
}

# Args: $1 = family, $2 = version, $3 = base mold dir, $4.. = missing files
add_release() {
    local family="$1" version="$2" base="$3"
    shift 3
    RESULT=$(jq --arg f "$family" --arg v "$version" --arg b "$base" \
        --args '. + [{id: "\($f)-\($v)", family: $f, version: $v, base: $b,
                      missing: $ARGS.positional}]' "$@" <<< "$RESULT")
}

# Upstream listings are read into variables rather than through process
# substitution, so that a failed request stops the script instead of
# looking like an empty listing.
for family_dir in "$MOLDS_DIR"/*/; do
    family=$(basename "$family_dir")
    newest=$(find "$family_dir" -mindepth 2 -maxdepth 2 -name mold.toml \
        | sed -E 's|.*/([^/]+)/mold\.toml$|\1|' | sort -V | tail -1)
    [[ -n "$newest" ]] || continue
    base="${MOLDS_DIR}/${family}/${newest}"
    log "${family}: newest registered is ${newest}"

    case "$family" in
        llvm) releases=$(llvm_releases) ;;
        gcc)  releases=$(gcc_versions) ;;
        *)    die "no upstream is known for family '${family}'" ;;
    esac

    while IFS=$'\t' read -r version published assets; do
        [[ "$version" =~ $STABLE_RE ]] || continue
        version_gt "$version" "$newest" || continue
        files=$(expected_files "$base" "$newest" "$version")
        missing=()
        while read -r file; do
            case "$family" in
                llvm) [[ " $assets " == *" $file "* ]] ;;
                gcc)  gcc_file_published "$version" "$file" ;;
            esac || missing+=("$file")
        done <<< "$files"
        if [[ ${#missing[@]} -gt 0 ]]; then
            if [[ ${#missing[@]} -eq $(wc -l <<< "$files") ]] || ! past_grace "$published"; then
                log "${family}: ${version} is missing ${missing[*]}; skipped"
                continue
            fi
            log "${family}: ${version} is missing ${missing[*]}; listed without them"
        fi
        add_release "$family" "$version" "$base" "${missing[@]}"
    done <<< "$releases"
done

jq 'sort_by(.family, (.version | split(".") | map(tonumber)))' <<< "$RESULT"
