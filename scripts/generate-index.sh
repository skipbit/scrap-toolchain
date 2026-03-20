#!/usr/bin/env bash
# generate-index.sh — Generate index.toml from mold definitions and ingot metadata
#
# Usage: generate-index.sh
#   Run from the repository root directory.
#
# Environment variables:
#   ARTIFACT_DIR      — Directory containing release-manifest and ingot-metadata
#                       JSON files (primary data source)
#   GITHUB_TOKEN      — GitHub API token for Releases API access (fallback)
#   GITHUB_REPOSITORY — GitHub repository in owner/repo format (fallback)
#
# Exit codes:
#   0 = Index generated successfully
#   1 = Generation error (all molds failed to resolve ingot data)
#   2 = Internal error (missing tools, unexpected failures)

set -euo pipefail

ARTIFACT_DIR="${ARTIFACT_DIR:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"

MAX_API_RETRIES=3
MOLDS_DIR="molds"
INDEX_FILE="index.toml"

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

SUMMARY_MD=""
add_summary() { SUMMARY_MD+="$1"$'\n'; }

# Cleanup on exit
TMPDIR_INDEX=""
cleanup() {
    if [[ -n "$TMPDIR_INDEX" && -d "$TMPDIR_INDEX" ]]; then
        rm -rf "$TMPDIR_INDEX"
    fi
}
trap cleanup EXIT

TMPDIR_INDEX=$(mktemp -d)

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

API_AVAILABLE=false
if [[ -n "$GITHUB_TOKEN" && -n "$GITHUB_REPOSITORY" ]]; then
    # Validate repository format (owner/repo)
    if ! [[ "$GITHUB_REPOSITORY" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
        warn "Invalid GITHUB_REPOSITORY format: ${GITHUB_REPOSITORY}"
    elif command -v curl &>/dev/null; then
        API_AVAILABLE=true
    else
        warn "curl not available; Releases API fallback disabled"
    fi
fi

if [[ -z "$ARTIFACT_DIR" && "$API_AVAILABLE" != "true" ]]; then
    warn "Neither ARTIFACT_DIR nor GitHub API credentials configured"
    warn "Index will include toolchain metadata only (no ingot download information)"
fi

pass "Prerequisites satisfied"
echo ""

add_summary "## generate-index"
add_summary ""

# --- GitHub API helper ---
# Calls the GitHub REST API with retry logic.
# Args: $1 = endpoint (relative to https://api.github.com/)
# Returns: JSON body on stdout, exit 0 on success, exit 1 on failure
api_call() {
    local endpoint="$1"
    local attempt
    local body_file="${TMPDIR_INDEX}/api_body"
    for attempt in $(seq 1 "$MAX_API_RETRIES"); do
        local http_code
        http_code=$(curl -s --max-time 30 -o "$body_file" -w "%{http_code}" \
            -H "Authorization: token ${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/${endpoint}" 2>/dev/null) || true

        if [[ "$http_code" =~ ^2 ]]; then
            cat "$body_file"
            return 0
        fi

        if [[ "$attempt" -lt "$MAX_API_RETRIES" ]]; then
            warn "API ${endpoint} returned HTTP ${http_code}, retry ${attempt}/${MAX_API_RETRIES}..."
            sleep 2
        fi
    done
    return 1
}

# --- Resolve release tag ---
# Finds the latest release tag for a family-version pair.
# Checks ARTIFACT_DIR first, then falls back to GitHub API tag scan.
# Args: $1 = family, $2 = version
# Output: release tag on stdout (empty if none found)
resolve_release_tag() {
    local family="$1" version="$2"
    local tag_prefix="${family}-${version}"

    # Priority 1: release-manifest in ARTIFACT_DIR
    if [[ -n "$ARTIFACT_DIR" ]]; then
        local manifest="${ARTIFACT_DIR}/release-manifest-${family}-${version}.json"
        if [[ -f "$manifest" ]]; then
            local tag
            tag=$(jq -r '.release_tag // empty' "$manifest" 2>/dev/null)
            if [[ -n "$tag" ]]; then
                echo "$tag"
                return 0
            fi
        fi
    fi

    # Fallback: GitHub API tag scan
    if [[ "$API_AVAILABLE" == "true" ]]; then
        local tags
        set +e
        tags=$(api_call "repos/${GITHUB_REPOSITORY}/tags?per_page=100" 2>/dev/null \
            | jq -r --arg prefix "$tag_prefix" '[.[].name | select(startswith($prefix))] | sort | .[]' \
            )
        set -e

        if [[ -n "$tags" ]]; then
            echo "$tags" | tail -1
            return 0
        fi
    fi

    # No tag found; use default pattern (initial release)
    echo "${tag_prefix}"
    return 0
}

# --- Generate empty index ---
# Writes a valid but empty index.toml
write_empty_index() {
    python3 -c "
from datetime import datetime, timezone
ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
print('[index]')
print('schema_version = 1')
print(f'generated_at = \"{ts}\"')
print('generator = \"scripts/generate-index.sh\"')
" > "$INDEX_FILE"
}

# --- Collect ingot metadata ---
# Gathers ingot metadata for a family-version pair.
# Checks ARTIFACT_DIR first, then falls back to GitHub Releases API.
# Args: $1 = family, $2 = version, $3 = release_tag
# Output: JSON array of ingot objects on stdout
collect_ingots() {
    local family="$1" version="$2" release_tag="$3"
    local ingots="[]"

    # Priority 1: ingot-metadata JSON files in ARTIFACT_DIR
    if [[ -n "$ARTIFACT_DIR" ]]; then
        local meta_files
        meta_files=$(find "$ARTIFACT_DIR" -name "ingot-metadata-${family}-${version}-*.json" \
            -type f 2>/dev/null | sort) || true

        if [[ -n "$meta_files" ]]; then
            while IFS= read -r meta_file; do
                [[ -n "$meta_file" && -f "$meta_file" ]] || continue
                local meta
                meta=$(cat "$meta_file" 2>/dev/null) || continue

                # Validate required fields
                local has_required
                has_required=$(echo "$meta" | jq 'has("platform") and has("arch") and has("sha256") and has("ingot_file")' 2>/dev/null)
                if [[ "$has_required" != "true" ]]; then
                    warn "Incomplete ingot-metadata: $(basename "$meta_file"); skipping"
                    continue
                fi

                # Build ingot entry with download URL
                if [[ -z "$GITHUB_REPOSITORY" ]]; then
                    warn "GITHUB_REPOSITORY not set; cannot build download URL for $(basename "$meta_file")"
                    continue
                fi
                local ingot_url
                ingot_url="https://github.com/${GITHUB_REPOSITORY}/releases/download/${release_tag}/$(echo "$meta" | jq -r '.ingot_file')"
                local ingot_entry
                ingot_entry=$(echo "$meta" | jq --arg url "$ingot_url" \
                    '{platform, arch, url: $url, sha256} + if .glibc_version then {glibc_version} else {} end')
                ingots=$(echo "$ingots" | jq --argjson entry "$ingot_entry" '. + [$entry]')
            done <<< "$meta_files"
        fi
    fi

    # Fallback: GitHub Releases API
    if [[ $(echo "$ingots" | jq 'length') -eq 0 && "$API_AVAILABLE" == "true" ]]; then
        local release_data
        set +e
        release_data=$(api_call "repos/${GITHUB_REPOSITORY}/releases/tags/${release_tag}" 2>/dev/null)
        local api_exit=$?
        set -e

        if [[ "$api_exit" -eq 0 && -n "$release_data" ]]; then
            # Parse assets to find ingot tar.xz files
            local asset_names
            asset_names=$(echo "$release_data" | jq -r '.assets[].name' 2>/dev/null) || true

            while IFS= read -r asset_name; do
                [[ -n "$asset_name" ]] || continue
                local platform="" arch=""
                case "$asset_name" in
                    "${family}-${version}-linux-x86_64.tar.xz")
                        platform="linux"; arch="x86_64" ;;
                    "${family}-${version}-linux-aarch64.tar.xz")
                        platform="linux"; arch="aarch64" ;;
                    "${family}-${version}-darwin-aarch64.tar.xz")
                        platform="darwin"; arch="aarch64" ;;
                    "${family}-${version}-darwin-x86_64.tar.xz")
                        platform="darwin"; arch="x86_64" ;;
                    *)
                        continue ;;
                esac

                # Download .sha256 sidecar file
                local sha256_url="https://github.com/${GITHUB_REPOSITORY}/releases/download/${release_tag}/${asset_name}.sha256"
                local sha256=""
                set +e
                sha256=$(curl -fsSL --max-time 30 "$sha256_url" 2>/dev/null | awk '{print $1}' | head -1)
                set -e

                if [[ -z "$sha256" || ${#sha256} -ne 64 ]]; then
                    warn "Could not retrieve SHA256 for ${asset_name}; skipping"
                    continue
                fi

                local download_url="https://github.com/${GITHUB_REPOSITORY}/releases/download/${release_tag}/${asset_name}"
                local entry
                entry=$(jq -n \
                    --arg platform "$platform" \
                    --arg arch "$arch" \
                    --arg url "$download_url" \
                    --arg sha256 "$sha256" \
                    '{platform: $platform, arch: $arch, url: $url, sha256: $sha256}')

                # Add glibc_version for Linux platforms if available
                # (not available from API fallback; omitted)

                ingots=$(echo "$ingots" | jq --argjson entry "$entry" '. + [$entry]')
            done <<< "$asset_names"
        fi
    fi

    echo "$ingots"
}

# --- Collect fetch-type ingots from mold.toml ---
# Reads source.binaries[] directly from the parsed mold JSON (ADR-0035).
# No CI artifacts or API calls needed — mold.toml is the single source of truth.
# Args: $1 = mold JSON (parsed mold.toml as JSON string)
# Output: JSON array of ingot objects on stdout
collect_fetch_ingots() {
    local mold_json="$1"
    local glibc_min
    glibc_min=$(echo "$mold_json" | jq -r '.source.glibc_min // empty')

    echo "$mold_json" | jq --arg glibc_min "$glibc_min" '
        [.source.binaries[] | {
            platform,
            arch,
            url,
            sha256
        } + if (.platform == "linux" and $glibc_min != "") then {glibc_version: $glibc_min} else {} end]
    '
}

# --- Step 1: Scan molds ---
echo -e "${BOLD}1. Scan molds${RESET}"

if [[ ! -d "$MOLDS_DIR" ]]; then
    info "No molds/ directory found; generating empty index"
    write_empty_index
    pass "Generated empty ${INDEX_FILE}"
    add_summary "- :white_check_mark: Empty index generated (no molds/)"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        echo "$SUMMARY_MD" >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 0
fi

MOLD_PATHS=()
while IFS= read -r mold_path; do
    [[ -n "$mold_path" ]] && MOLD_PATHS+=("$mold_path")
done < <(find "$MOLDS_DIR" -name "mold.toml" -type f 2>/dev/null | sort)

if [[ ${#MOLD_PATHS[@]} -eq 0 ]]; then
    info "No mold.toml files found; generating empty index"
    write_empty_index
    pass "Generated empty ${INDEX_FILE}"
    add_summary "- :white_check_mark: Empty index generated (no molds found)"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        echo "$SUMMARY_MD" >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 0
fi

pass "Found ${#MOLD_PATHS[@]} mold(s)"
echo ""

# --- Step 2: Process each mold ---
echo -e "${BOLD}2. Process molds${RESET}"

# Read existing index.toml for fallback (preserve entries on API failure)
EXISTING_INDEX_JSON=""
if [[ -f "$INDEX_FILE" ]]; then
    set +e
    EXISTING_INDEX_JSON=$(python3 -c "
try:
    import tomllib
except ImportError:
    import tomli as tomllib
import json, sys
with open(sys.argv[1], 'rb') as f:
    data = tomllib.load(f)
json.dump(data, sys.stdout)
" "$INDEX_FILE" 2>/dev/null)
    set -e
fi

# Accumulate toolchain data as a JSON array
TOOLCHAINS_JSON="[]"
MOLD_ERRORS=0
MOLD_PROCESSED=0
MOLD_SKIPPED=0

for mold_path in "${MOLD_PATHS[@]}"; do
    # Parse mold.toml
    set +e
    mold_json=$(python3 -c "
try:
    import tomllib
except ImportError:
    import tomli as tomllib
import json, sys
with open(sys.argv[1], 'rb') as f:
    data = tomllib.load(f)
json.dump(data, sys.stdout)
" "$mold_path" 2>/dev/null)
    parse_exit=$?
    set -e

    if [[ "$parse_exit" -ne 0 || -z "$mold_json" ]]; then
        warn "Failed to parse ${mold_path}; skipping"
        MOLD_ERRORS=$((MOLD_ERRORS + 1))
        continue
    fi

    # Check status
    status=$(echo "$mold_json" | jq -r '.metadata.status // "active"')
    if [[ "$status" == "disabled" ]]; then
        info "Skipping disabled mold: ${mold_path}"
        MOLD_SKIPPED=$((MOLD_SKIPPED + 1))
        continue
    fi

    # Extract metadata
    family=$(echo "$mold_json" | jq -r '.metadata.family // empty')
    version=$(echo "$mold_json" | jq -r '.metadata.version // empty')

    if [[ -z "$family" || -z "$version" ]]; then
        warn "Missing family or version in ${mold_path}; skipping"
        MOLD_ERRORS=$((MOLD_ERRORS + 1))
        continue
    fi

    license_val=$(echo "$mold_json" | jq -r '.metadata.license // empty')
    source_type=$(echo "$mold_json" | jq -r '.source.type // empty')
    compiler=$(echo "$mold_json" | jq -r '.metadata.components.compiler // empty')
    min_scrap=$(echo "$mold_json" | jq -r '.metadata.min_scrap_version // empty')

    info "Processing: ${family} ${version} (${source_type}, ${status})"

    # Collect ingots based on source type (ADR-0035)
    origin=""
    if [[ "$source_type" == "fetch" ]]; then
        # Fetch type: read directly from mold.toml (mold is SSoT)
        ingots=$(collect_fetch_ingots "$mold_json")
        origin="upstream"
        info "Fetch type: reading upstream URLs from mold.toml"
    elif [[ "$source_type" == "build" ]]; then
        # Build type: resolve from CI artifacts or GitHub API
        release_tag=$(resolve_release_tag "$family" "$version")
        info "Release tag: ${release_tag}"
        ingots=$(collect_ingots "$family" "$version" "$release_tag")
        origin="scrap-release"

        # Build type: preserve existing entries on API failure
        ingot_count=$(echo "$ingots" | jq 'length')
        if [[ "$ingot_count" -eq 0 && -n "$EXISTING_INDEX_JSON" ]]; then
            existing_ingots=$(echo "$EXISTING_INDEX_JSON" | jq --arg f "$family" --arg v "$version" \
                '[.toolchains[]? | select(.family == $f and .version == $v) | .ingots[]?] // []' 2>/dev/null) || true
            if [[ -n "$existing_ingots" && $(echo "$existing_ingots" | jq 'length') -gt 0 ]]; then
                ingots="$existing_ingots"
                info "Preserved existing ingot(s) from current index"
            fi
        fi
    else
        warn "Unknown source type '${source_type}' in ${mold_path}; skipping"
        MOLD_ERRORS=$((MOLD_ERRORS + 1))
        continue
    fi

    ingot_count=$(echo "$ingots" | jq 'length')

    if [[ "$ingot_count" -gt 0 ]]; then
        pass "${family} ${version}: ${ingot_count} ingot(s)"
    else
        info "${family} ${version}: no ingots available"
    fi

    # Build toolchain JSON entry
    tc_entry=$(jq -n \
        --arg family "$family" \
        --arg version "$version" \
        --arg status "$status" \
        --arg license "$license_val" \
        --arg source_type "$source_type" \
        --arg compiler "$compiler" \
        --arg min_scrap "$min_scrap" \
        --arg origin "$origin" \
        --argjson ingots "$ingots" \
        '{
            family: $family,
            version: $version,
            status: $status,
            license: $license,
            source_type: $source_type,
            compiler: $compiler,
            origin: $origin
        }
        + if $min_scrap != "" then {min_scrap_version: $min_scrap} else {} end
        + {ingots: $ingots}')

    TOOLCHAINS_JSON=$(echo "$TOOLCHAINS_JSON" | jq --argjson tc "$tc_entry" '. + [$tc]')
    MOLD_PROCESSED=$((MOLD_PROCESSED + 1))
done
echo ""

# Check if all molds failed
TOTAL_ATTEMPTED=$((MOLD_PROCESSED + MOLD_ERRORS))
if [[ "$TOTAL_ATTEMPTED" -gt 0 && "$MOLD_PROCESSED" -eq 0 ]]; then
    fail "All molds failed to process; index.toml not updated"
    add_summary "- :x: All molds failed"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        echo "$SUMMARY_MD" >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 1
fi

# --- Step 3: Generate index.toml ---
echo -e "${BOLD}3. Generate index.toml${RESET}"

echo "$TOOLCHAINS_JSON" | python3 -c "
import json, sys
from datetime import datetime, timezone

toolchains = json.load(sys.stdin)

def esc(val):
    \"\"\"Escape a string value for TOML basic strings.\"\"\"
    return str(val).replace('\\\\', '\\\\\\\\').replace('\"', '\\\\\"').replace('\\n', '\\\\n')

# Sort toolchains by family, then version
toolchains.sort(key=lambda tc: (tc['family'], tc['version']))

lines = []
lines.append('[index]')
lines.append('schema_version = 1')
ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
lines.append(f'generated_at = \"{ts}\"')
lines.append('generator = \"scripts/generate-index.sh\"')

for tc in toolchains:
    lines.append('')
    lines.append('[[toolchains]]')
    lines.append(f'family = \"{esc(tc[\"family\"])}\"')
    lines.append(f'version = \"{esc(tc[\"version\"])}\"')
    lines.append(f'status = \"{esc(tc[\"status\"])}\"')
    lines.append(f'license = \"{esc(tc[\"license\"])}\"')
    lines.append(f'source_type = \"{esc(tc[\"source_type\"])}\"')
    lines.append(f'compiler = \"{esc(tc[\"compiler\"])}\"')
    if tc.get('origin'):
        lines.append(f'origin = \"{esc(tc[\"origin\"])}\"')
    if tc.get('min_scrap_version'):
        lines.append(f'min_scrap_version = \"{esc(tc[\"min_scrap_version\"])}\"')

    # Sort ingots by platform, then arch
    ingots = sorted(tc.get('ingots', []), key=lambda i: (i['platform'], i['arch']))
    for ingot in ingots:
        lines.append('')
        lines.append('[[toolchains.ingots]]')
        lines.append(f'platform = \"{esc(ingot[\"platform\"])}\"')
        lines.append(f'arch = \"{esc(ingot[\"arch\"])}\"')
        lines.append(f'url = \"{esc(ingot[\"url\"])}\"')
        lines.append(f'sha256 = \"{esc(ingot[\"sha256\"])}\"')
        if ingot.get('glibc_version'):
            lines.append(f'glibc_version = \"{esc(ingot[\"glibc_version\"])}\"')

print('\n'.join(lines) + '\n')
" > "${TMPDIR_INDEX}/index.toml"

# Move temp file to final location
mv "${TMPDIR_INDEX}/index.toml" "$INDEX_FILE"

pass "Generated ${INDEX_FILE}"
info "Toolchains: ${MOLD_PROCESSED}, Skipped (disabled): ${MOLD_SKIPPED}, Errors: ${MOLD_ERRORS}"
echo ""

# --- Summary ---
echo -e "${BOLD}Summary${RESET}"
echo -e "  ${GREEN}Index generated successfully.${RESET}"

add_summary ""
add_summary "- :white_check_mark: Index generated: ${MOLD_PROCESSED} toolchain(s)"
if [[ "$MOLD_SKIPPED" -gt 0 ]]; then
    add_summary "- :information_source: Skipped: ${MOLD_SKIPPED} disabled mold(s)"
fi
if [[ "$MOLD_ERRORS" -gt 0 ]]; then
    add_summary "- :warning: Errors: ${MOLD_ERRORS} mold(s) failed to parse"
fi
add_summary ""
add_summary "**Result: :white_check_mark: Index generated successfully**"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    echo "$SUMMARY_MD" >> "$GITHUB_STEP_SUMMARY"
fi

exit 0
