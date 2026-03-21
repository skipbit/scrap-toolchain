#!/usr/bin/env bash
# generate-index.sh — Generate index.toml from mold definitions and ingot metadata
#
# Usage: generate-index.sh
#   Run from the repository root directory.
#
# Environment variables:
#   ARTIFACT_DIR      — Directory containing package-manifest and ingot-metadata
#                       JSON files (primary data source for build-type ingots)
#   GITHUB_TOKEN      — GitHub token for OCI Registry API authentication (optional;
#                       anonymous access is used for public packages if unset)
#   GITHUB_REPOSITORY — GitHub repository in owner/repo format (e.g., skipbit/scrap-toolchain)
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
trap '[[ -n "$TMPDIR_INDEX" && -d "$TMPDIR_INDEX" ]] && rm -rf "$TMPDIR_INDEX"' EXIT

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

# OCI Registry API fallback is available when curl exists and repository is known.
# GITHUB_TOKEN is optional — anonymous access works for public packages.
OCI_API_AVAILABLE=false
if [[ -n "$GITHUB_REPOSITORY" ]]; then
    if ! [[ "$GITHUB_REPOSITORY" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
        warn "Invalid GITHUB_REPOSITORY format: ${GITHUB_REPOSITORY}"
    elif command -v curl &>/dev/null; then
        OCI_API_AVAILABLE=true
    else
        warn "curl not available; OCI Registry API fallback disabled"
    fi
fi

if [[ -z "$ARTIFACT_DIR" && "$OCI_API_AVAILABLE" != "true" ]]; then
    warn "Neither ARTIFACT_DIR nor OCI Registry API available"
    warn "Index will include toolchain metadata only (no ingot download information for build type)"
fi

pass "Prerequisites satisfied"
echo ""

add_summary "## generate-index"
add_summary ""

# --- OCI Registry API helpers ---

# Acquire an OCI bearer token for the given repository scope.
# Args: $1 = OCI repository path (e.g., skipbit/scrap-toolchain/gcc)
# Output: bearer token on stdout (empty on failure)
oci_get_token() {
    local repo="$1"
    local auth_args=()
    if [[ -n "$GITHUB_TOKEN" ]]; then
        auth_args=(-u "_:${GITHUB_TOKEN}")
    fi

    local token
    token=$(curl -s --max-time 15 "${auth_args[@]}" \
        "https://ghcr.io/token?scope=repository:${repo}:pull" 2>/dev/null \
        | jq -r '.token // empty') || true
    echo "$token"
}

# Call the OCI Distribution API with retry logic.
# Args: $1 = OCI repository path, $2 = endpoint (e.g., tags/list, manifests/{ref})
#        $3 = Accept header (optional, defaults to OCI Index media type)
# Returns: response body on stdout, exit 0 on success, exit 1 on failure
oci_api_call() {
    local repo="$1"
    local endpoint="$2"
    local accept="${3:-application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json}"

    local token
    token=$(oci_get_token "$repo")
    if [[ -z "$token" ]]; then
        return 1
    fi

    local body_file
    body_file=$(mktemp "${TMPDIR_INDEX}/oci_body.XXXXXX")

    local attempt http_code
    for ((attempt = 1; attempt <= MAX_API_RETRIES; attempt++)); do
        http_code=$(curl -s --max-time 30 -o "$body_file" -w "%{http_code}" \
            -H "Authorization: Bearer ${token}" \
            -H "Accept: ${accept}" \
            "https://ghcr.io/v2/${repo}/${endpoint}" 2>/dev/null) || true

        # Re-acquire token on 401 (expired or invalid)
        if [[ "$http_code" == "401" && "$attempt" -lt "$MAX_API_RETRIES" ]]; then
            warn "OCI API ${repo}/${endpoint} returned 401, re-acquiring token..."
            token=$(oci_get_token "$repo")
            [[ -z "$token" ]] && break
            sleep 1
            continue
        fi

        if [[ "$http_code" =~ ^2 ]] && jq empty "$body_file" 2>/dev/null; then
            cat "$body_file"
            rm -f "$body_file"
            return 0
        fi

        if [[ "$attempt" -lt "$MAX_API_RETRIES" ]]; then
            warn "OCI API ${repo}/${endpoint} returned HTTP ${http_code}, retry ${attempt}/${MAX_API_RETRIES}..."
            sleep 2
        fi
    done
    rm -f "$body_file"
    return 1
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

# --- Resolve OCI tag for a build-type mold ---
# Finds the OCI tag for a family-version pair.
# Checks ARTIFACT_DIR first, then falls back to OCI Registry API tag listing.
# Args: $1 = family, $2 = version
# Output: OCI tag on stdout (e.g., "gcc:14.2.0" or "gcc:14.2.0-r2")
resolve_oci_tag() {
    local family="$1" version="$2"

    # Priority 1: package-manifest in ARTIFACT_DIR
    if [[ -n "$ARTIFACT_DIR" ]]; then
        local manifest="${ARTIFACT_DIR}/package-manifest-${family}-${version}.json"
        if [[ -f "$manifest" ]]; then
            local tag
            tag=$(jq -r '.oci_tag // empty' "$manifest" 2>/dev/null)
            if [[ -n "$tag" ]]; then
                echo "$tag"
                return 0
            fi
        fi
    fi

    # Fallback: OCI Registry API tag listing
    if [[ "$OCI_API_AVAILABLE" == "true" ]]; then
        local repo_path="${GITHUB_REPOSITORY}/${family}"
        local tags_json
        if tags_json=$(oci_api_call "$repo_path" "tags/list" "application/json"); then
            # Find the latest revision tag matching this version
            local version_re
            version_re=$(printf '%s' "$version" | sed 's/[.]/\\./g')
            # Find the latest revision tag using numeric sort (lexicographic
            # sort would rank -r9 after -r10, producing incorrect results).
            local latest_tag
            latest_tag=$(jq -r --arg re "^${version_re}(-r[0-9]+)?$" \
                '[.tags[]? | select(test($re))][]' <<< "$tags_json" \
                | sort -t'-' -k2 -n | tail -1)
            if [[ -n "$latest_tag" ]]; then
                echo "${family}:${latest_tag}"
                return 0
            fi
        fi
    fi

    # No existing tag found; use default (initial version)
    echo "${family}:${version}"
    return 0
}

# --- Collect build-type ingots from package-manifest + ingot-metadata ---
# Produces OCI reference entries (registry, tag, digest) for build-type molds.
# Checks ARTIFACT_DIR first, then falls back to OCI Registry API.
# Args: $1 = family, $2 = version, $3 = oci_tag (e.g., "gcc:14.2.0")
# Output: JSON array of ingot objects on stdout
collect_build_ingots() {
    local family="$1" version="$2" oci_tag="$3"
    local ingots="[]"
    local registry="ghcr.io/${GITHUB_REPOSITORY}"

    # Priority 1: package-manifest + ingot-metadata in ARTIFACT_DIR
    if [[ -n "$ARTIFACT_DIR" ]]; then
        local manifest="${ARTIFACT_DIR}/package-manifest-${family}-${version}.json"
        if [[ -f "$manifest" ]]; then
            local asset_count
            asset_count=$(jq '.assets | length' "$manifest" 2>/dev/null) || asset_count=0

            local i
            for ((i = 0; i < asset_count; i++)); do
                local platform arch digest
                read -r platform arch digest < <(
                    jq -r --argjson i "$i" \
                        '[.assets[$i].platform, .assets[$i].arch, .assets[$i].digest] | @tsv' \
                        "$manifest"
                )

                if [[ -z "$platform" || -z "$arch" || -z "$digest" ]]; then
                    warn "Incomplete asset entry in package-manifest (platform=${platform}, arch=${arch}, digest=${digest}); skipping"
                    continue
                fi

                # Get glibc_version from ingot-metadata (build-time detection)
                local glibc_version=""
                local meta_file="${ARTIFACT_DIR}/ingot-metadata-${family}-${version}-${platform}-${arch}.json"
                if [[ -f "$meta_file" ]]; then
                    glibc_version=$(jq -r '.glibc_version // empty' "$meta_file" 2>/dev/null)
                fi

                local entry
                entry=$(jq -n \
                    --arg registry "$registry" \
                    --arg tag "$oci_tag" \
                    --arg digest "$digest" \
                    --arg platform "$platform" \
                    --arg arch "$arch" \
                    --arg glibc "$glibc_version" \
                    '{registry: $registry, tag: $tag, digest: $digest, platform: $platform, arch: $arch}
                    + if $glibc != "" then {glibc_version: $glibc} else {} end')

                ingots=$(jq --argjson entry "$entry" '. + [$entry]' <<< "$ingots")
            done
        fi
    fi

    # Fallback: OCI Registry API — resolve tag to get per-platform digests
    local ingot_count_fb
    ingot_count_fb=$(jq 'length' <<< "$ingots" 2>/dev/null) || ingot_count_fb=0
    if [[ "$ingot_count_fb" -eq 0 && "$OCI_API_AVAILABLE" == "true" ]]; then
        local repo_path="${GITHUB_REPOSITORY}/${family}"
        # Extract just the version portion from oci_tag (e.g., "gcc:14.2.0" -> "14.2.0")
        local tag_version="${oci_tag#*:}"

        # Get the OCI Index manifest for this tag
        local index_manifest
        if index_manifest=$(oci_api_call "$repo_path" "manifests/${tag_version}"); then
            # Verify this is an OCI Index (has .manifests array), not a single manifest.
            # A single-platform manifest has .config + .layers but no .manifests.
            if ! jq -e 'has("manifests")' <<< "$index_manifest" >/dev/null 2>&1; then
                warn "OCI manifest for ${family}:${tag_version} is not an Index; cannot extract per-platform digests"
            else
            local manifest_count
            manifest_count=$(jq '.manifests | length' <<< "$index_manifest" 2>/dev/null) || manifest_count=0

            for ((i = 0; i < manifest_count; i++)); do
                local digest platform arch
                read -r digest platform arch < <(
                    jq -r --argjson i "$i" \
                        '[.manifests[$i].digest, (.manifests[$i].platform.os // ""), (.manifests[$i].platform.architecture // "")] | @tsv' \
                        <<< "$index_manifest"
                )

                [[ -z "$digest" || -z "$platform" ]] && continue

                # Map OCI arch names back to scrap naming convention
                case "$arch" in
                    amd64) arch="x86_64" ;;
                    arm64) arch="aarch64" ;;
                esac

                local entry
                entry=$(jq -n \
                    --arg registry "$registry" \
                    --arg tag "$oci_tag" \
                    --arg digest "$digest" \
                    --arg platform "$platform" \
                    --arg arch "$arch" \
                    '{registry: $registry, tag: $tag, digest: $digest, platform: $platform, arch: $arch}')

                ingots=$(jq --argjson entry "$entry" '. + [$entry]' <<< "$ingots")
            done
            fi  # has("manifests") check
        fi
    fi

    echo "$ingots"
}

# --- Collect fetch-type ingots from mold.toml ---
# Reads source.binaries[] directly from the parsed mold JSON.
# No CI artifacts or API calls needed — mold.toml is the single source of truth.
# Args: $1 = mold JSON (parsed mold.toml as JSON string)
# Output: JSON array of ingot objects on stdout
collect_fetch_ingots() {
    local mold_json="$1"
    local glibc_min
    glibc_min=$(jq -r '.source.glibc_min // empty' <<< "$mold_json")

    jq --arg glibc_min "$glibc_min" '
        [.source.binaries[] | {
            platform,
            arch,
            url,
            sha256
        } + if (.platform == "linux" and $glibc_min != "") then {glibc_version: $glibc_min} else {} end]
    ' <<< "$mold_json"
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
    if ! EXISTING_INDEX_JSON=$(python3 -c "
try:
    import tomllib
except ImportError:
    import tomli as tomllib
import json, sys
with open(sys.argv[1], 'rb') as f:
    data = tomllib.load(f)
json.dump(data, sys.stdout)
" "$INDEX_FILE" 2>/dev/null); then
        EXISTING_INDEX_JSON=""
    fi
fi

# Accumulate toolchain data as a JSON array
TOOLCHAINS_JSON="[]"
MOLD_ERRORS=0
MOLD_PROCESSED=0
MOLD_SKIPPED=0

for mold_path in "${MOLD_PATHS[@]}"; do
    # Parse mold.toml
    if ! mold_json=$(python3 -c "
try:
    import tomllib
except ImportError:
    import tomli as tomllib
import json, sys
with open(sys.argv[1], 'rb') as f:
    data = tomllib.load(f)
json.dump(data, sys.stdout)
" "$mold_path" 2>/dev/null); then
        warn "Failed to parse ${mold_path}; skipping"
        MOLD_ERRORS=$((MOLD_ERRORS + 1))
        continue
    fi

    if [[ -z "$mold_json" ]]; then
        warn "Empty parse result for ${mold_path}; skipping"
        MOLD_ERRORS=$((MOLD_ERRORS + 1))
        continue
    fi

    # Check status
    status=$(jq -r '.metadata.status // "active"' <<< "$mold_json")
    if [[ "$status" == "disabled" ]]; then
        info "Skipping disabled mold: ${mold_path}"
        MOLD_SKIPPED=$((MOLD_SKIPPED + 1))
        continue
    fi

    # Extract metadata
    family=$(jq -r '.metadata.family // empty' <<< "$mold_json")
    version=$(jq -r '.metadata.version // empty' <<< "$mold_json")

    if [[ -z "$family" || -z "$version" ]]; then
        warn "Missing family or version in ${mold_path}; skipping"
        MOLD_ERRORS=$((MOLD_ERRORS + 1))
        continue
    fi

    license_val=$(jq -r '.metadata.license // empty' <<< "$mold_json")
    source_type=$(jq -r '.source.type // empty' <<< "$mold_json")
    compiler=$(jq -r '.metadata.components.compiler // empty' <<< "$mold_json")
    min_scrap=$(jq -r '.metadata.min_scrap_version // empty' <<< "$mold_json")

    info "Processing: ${family} ${version} (${source_type}, ${status})"

    # Collect ingots based on source type
    origin=""
    if [[ "$source_type" == "fetch" ]]; then
        # Fetch type: read directly from mold.toml (mold is single source of truth)
        ingots=$(collect_fetch_ingots "$mold_json")
        origin="upstream"
        info "Fetch type: reading upstream URLs from mold.toml"
    elif [[ "$source_type" == "build" ]]; then
        # Build type: resolve OCI tag and collect OCI references
        oci_tag=$(resolve_oci_tag "$family" "$version")
        info "OCI tag: ${oci_tag}"
        ingots=$(collect_build_ingots "$family" "$version" "$oci_tag")
        origin="scrap-release"

        # Build type: preserve existing entries on API failure
        ingot_count=$(jq 'length' <<< "$ingots" 2>/dev/null) || ingot_count=0
        if [[ "$ingot_count" -eq 0 && -n "$EXISTING_INDEX_JSON" ]]; then
            existing_ingots=$(jq --arg f "$family" --arg v "$version" \
                '[.toolchains[]? | select(.family == $f and .version == $v) | .ingots[]?] // []' \
                <<< "$EXISTING_INDEX_JSON" 2>/dev/null) || true
            existing_count=$(jq 'length' <<< "$existing_ingots" 2>/dev/null) || existing_count=0
            if [[ -n "$existing_ingots" && "$existing_count" -gt 0 ]]; then
                ingots="$existing_ingots"
                info "Preserved existing ingot(s) from current index"
            fi
        fi
    else
        warn "Unknown source type '${source_type}' in ${mold_path}; skipping"
        MOLD_ERRORS=$((MOLD_ERRORS + 1))
        continue
    fi

    ingot_count=$(jq 'length' <<< "$ingots" 2>/dev/null) || ingot_count=0

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

    TOOLCHAINS_JSON=$(jq --argjson tc "$tc_entry" '. + [$tc]' <<< "$TOOLCHAINS_JSON")
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

python3 -c "
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

        if 'registry' in ingot:
            # Build type: OCI reference (registry + tag + digest)
            lines.append(f'registry = \"{esc(ingot[\"registry\"])}\"')
            lines.append(f'tag = \"{esc(ingot[\"tag\"])}\"')
            lines.append(f'digest = \"{esc(ingot[\"digest\"])}\"')
        else:
            # Fetch type: direct URL
            lines.append(f'url = \"{esc(ingot[\"url\"])}\"')
            lines.append(f'sha256 = \"{esc(ingot[\"sha256\"])}\"')

        if ingot.get('glibc_version'):
            lines.append(f'glibc_version = \"{esc(ingot[\"glibc_version\"])}\"')

print('\n'.join(lines) + '\n')
" <<< "$TOOLCHAINS_JSON" > "${TMPDIR_INDEX}/index.toml"

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
