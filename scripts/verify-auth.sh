#!/usr/bin/env bash
# verify-auth.sh — Verify CI authentication and permissions configuration
#
# Prerequisites: gh CLI authenticated with admin access to the repository
#
# Exit codes:
#   0 = All checks passed
#   1 = One or more checks failed
#   2 = Internal error (missing tools, auth issues)

set -euo pipefail

# --- Configuration ---
REPO="${GITHUB_REPOSITORY:-skipbit/scrap-toolchain}"
REQUIRED_SECRETS=("APP_ID" "APP_PRIVATE_KEY")
PROTECTED_BRANCH="main"
# Set to a specific App slug (e.g., "scrap-toolchain-ci") to verify only that App.
# When empty, any App with contents: write will pass the check.
EXPECTED_APP_SLUG=""

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
fail() { echo -e "  ${RED}FAIL${RESET}: $1"; FAILURES=$((FAILURES + 1)); }
warn() { echo -e "  ${YELLOW}WARN${RESET}: $1"; }
info() { echo -e "  ${BOLD}INFO${RESET}: $1"; }

FAILURES=0

# --- Pre-flight checks ---
echo -e "${BOLD}Pre-flight checks${RESET}"

if ! command -v gh &>/dev/null; then
    echo "Error: gh CLI is not installed. Install from https://cli.github.com/"
    exit 2
fi

if ! command -v jq &>/dev/null; then
    echo "Error: jq is not installed. Install from https://jqlang.github.io/jq/"
    exit 2
fi

if ! gh auth status &>/dev/null; then
    echo "Error: gh CLI is not authenticated. Run 'gh auth login' first."
    exit 2
fi

# Verify repository access
if ! gh repo view "$REPO" --json name &>/dev/null; then
    echo "Error: Cannot access repository $REPO"
    exit 2
fi

pass "gh CLI authenticated and repository accessible"
echo ""

# --- Check 1: Repository secrets ---
echo -e "${BOLD}1. Repository secrets${RESET}"

SECRETS_JSON=""
if SECRETS_JSON=$(gh secret list --repo "$REPO" --json name 2>/dev/null); then
    for secret_name in "${REQUIRED_SECRETS[@]}"; do
        if echo "$SECRETS_JSON" | jq -e --arg n "$secret_name" '.[] | select(.name == $n)' > /dev/null 2>&1; then
            pass "Secret '$secret_name' is configured"
        else
            fail "Secret '$secret_name' is not configured"
        fi
    done
else
    warn "Could not list repository secrets (possible insufficient permissions)"
    info "Ensure the token has admin access to list secrets"
fi
echo ""

# --- Check 2: Branch protection rules ---
echo -e "${BOLD}2. Branch protection for '$PROTECTED_BRANCH'${RESET}"

BRANCH_PROTECTED=false

# Try legacy branch protection API first with proper HTTP status handling
BP_RESPONSE=$(gh api "repos/$REPO/branches/$PROTECTED_BRANCH/protection" \
    --include 2>/dev/null || true)

# Extract HTTP status code from the response headers
BP_HTTP_STATUS=$(echo "$BP_RESPONSE" | head -1 | grep -oE '[0-9]{3}' | head -1)
BP_JSON=$(echo "$BP_RESPONSE" | sed '1,/^\r*$/d')

if [[ "$BP_HTTP_STATUS" =~ ^2 ]]; then
    # Legacy branch protection is configured
    BRANCH_PROTECTED=true
    pass "Branch protection is enabled for '$PROTECTED_BRANCH' (legacy rules)"

    # Check require PR reviews
    REQUIRE_PR=$(echo "$BP_JSON" | jq '.required_pull_request_reviews // empty' 2>/dev/null || echo "")
    if [[ -n "$REQUIRE_PR" ]]; then
        pass "Pull request reviews are required"
    else
        fail "Pull request reviews are not required"
    fi

    # Check require status checks
    STATUS_CHECKS=$(echo "$BP_JSON" | jq '.required_status_checks // empty' 2>/dev/null || echo "")
    if [[ -n "$STATUS_CHECKS" ]]; then
        pass "Status checks are required"
    else
        warn "Status checks are not yet required (configure after workflows are created)"
    fi
elif [[ "$BP_HTTP_STATUS" == "404" ]]; then
    # Legacy API returned 404 — try Rulesets API (GitHub repository rules)
    RULESETS_JSON=$(gh api "repos/$REPO/rulesets" 2>/dev/null || echo "[]")
    RULESET_COUNT=$(echo "$RULESETS_JSON" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$RULESET_COUNT" -gt 0 ]]; then
        # Find active rulesets and filter by branch target
        ACTIVE_IDS=$(echo "$RULESETS_JSON" | jq -r '[.[] | select(.enforcement == "active") | .id] | .[]' 2>/dev/null || echo "")

        # Filter active rulesets to only those targeting the protected branch
        MATCHING_IDS=""
        for ruleset_id in $ACTIVE_IDS; do
            RULESET_DETAIL=$(gh api "repos/$REPO/rulesets/$ruleset_id" 2>/dev/null || echo "")
            if [[ -z "$RULESET_DETAIL" ]]; then
                continue
            fi

            # Check if the ruleset targets the protected branch via conditions.ref_name.include
            INCLUDE_PATTERNS=$(echo "$RULESET_DETAIL" | jq -r '
                .conditions.ref_name.include // [] | .[]
            ' 2>/dev/null || echo "")

            TARGETS_BRANCH=false

            if [[ -z "$INCLUDE_PATTERNS" ]]; then
                # Empty include array means all branches are targeted
                TARGETS_BRANCH=true
            else
                for pattern in $INCLUDE_PATTERNS; do
                    case "$pattern" in
                        "refs/heads/$PROTECTED_BRANCH" | "~DEFAULT_BRANCH" | "~ALL")
                            TARGETS_BRANCH=true
                            break
                            ;;
                    esac
                done
            fi

            if [[ "$TARGETS_BRANCH" == "true" ]]; then
                MATCHING_IDS="$MATCHING_IDS $ruleset_id"
            fi
        done

        # Trim leading space
        MATCHING_IDS=$(echo "$MATCHING_IDS" | xargs)

        if [[ -z "$MATCHING_IDS" ]]; then
            fail "Rulesets exist but none target '$PROTECTED_BRANCH' or are actively enforced"
        else
            pass "Branch protection is enabled for '$PROTECTED_BRANCH' (rulesets)"
            BRANCH_PROTECTED=true

            # Check each matching ruleset for pull_request rule
            PR_REVIEW_FOUND=false
            for ruleset_id in $MATCHING_IDS; do
                RULESET_DETAIL=$(gh api "repos/$REPO/rulesets/$ruleset_id" 2>/dev/null || echo "")
                if [[ -z "$RULESET_DETAIL" ]]; then
                    continue
                fi

                HAS_PR_RULE=$(echo "$RULESET_DETAIL" | jq '[.rules[] | select(.type == "pull_request")] | length' 2>/dev/null || echo "0")
                if [[ "$HAS_PR_RULE" -gt 0 ]]; then
                    PR_REVIEW_FOUND=true
                    RULESET_NAME=$(echo "$RULESET_DETAIL" | jq -r '.name // "unnamed"' 2>/dev/null || echo "unnamed")
                    pass "Pull request reviews are required (ruleset: $RULESET_NAME)"
                    break
                fi
            done

            if [[ "$PR_REVIEW_FOUND" == "false" ]]; then
                fail "Pull request reviews are not required in any active ruleset"
            fi

            # Status checks are often configured later
            STATUS_CHECK_FOUND=false
            for ruleset_id in $MATCHING_IDS; do
                RULESET_DETAIL=$(gh api "repos/$REPO/rulesets/$ruleset_id" 2>/dev/null || echo "")
                if [[ -z "$RULESET_DETAIL" ]]; then
                    continue
                fi

                HAS_STATUS_RULE=$(echo "$RULESET_DETAIL" | jq '[.rules[] | select(.type == "required_status_checks")] | length' 2>/dev/null || echo "0")
                if [[ "$HAS_STATUS_RULE" -gt 0 ]]; then
                    STATUS_CHECK_FOUND=true
                    break
                fi
            done

            if [[ "$STATUS_CHECK_FOUND" == "true" ]]; then
                pass "Status checks are required"
            else
                warn "Status checks are not yet required (configure after workflows are created)"
            fi
        fi
    else
        fail "No branch protection rules or rulesets found for '$PROTECTED_BRANCH'"
    fi
elif [[ "$BP_HTTP_STATUS" == "401" || "$BP_HTTP_STATUS" == "403" ]]; then
    warn "Cannot check branch protection: HTTP $BP_HTTP_STATUS (insufficient permissions)"
    info "Re-run with a token that has admin access to check branch protection"
elif [[ "$BP_HTTP_STATUS" =~ ^5 ]]; then
    warn "Cannot check branch protection: GitHub API returned HTTP $BP_HTTP_STATUS (server error)"
    info "Retry later or check GitHub status at https://www.githubstatus.com/"
else
    warn "Cannot check branch protection: unexpected HTTP status $BP_HTTP_STATUS"
fi
echo ""

# --- Check 3: GitHub App installation ---
echo -e "${BOLD}3. GitHub App installation${RESET}"

# Try the installations endpoint (accessible with user tokens that have admin access)
INSTALLATIONS_RAW=$(gh api "repos/$REPO/installations" 2>/dev/null || echo "")
INSTALLATIONS=$(echo "$INSTALLATIONS_RAW" | jq '.installations // [] | length' 2>/dev/null || echo "0")

if [[ "$INSTALLATIONS" -gt 0 ]]; then
    # Scan all installations for one with contents: write
    CONTENTS_WRITE_FOUND=false
    CONTENTS_WRITE_SLUG=""
    INSTALLED_SLUGS=""

    for idx in $(seq 0 $((INSTALLATIONS - 1))); do
        SLUG=$(echo "$INSTALLATIONS_RAW" | jq -r ".installations[$idx].app_slug // \"unknown\"" 2>/dev/null || echo "unknown")
        PERM=$(echo "$INSTALLATIONS_RAW" | jq -r ".installations[$idx].permissions.contents // \"none\"" 2>/dev/null || echo "none")
        INSTALLED_SLUGS="$INSTALLED_SLUGS $SLUG"

        if [[ "$PERM" == "write" ]]; then
            if [[ -z "$EXPECTED_APP_SLUG" || "$SLUG" == "$EXPECTED_APP_SLUG" ]]; then
                CONTENTS_WRITE_FOUND=true
                CONTENTS_WRITE_SLUG="$SLUG"
            fi
        fi
    done

    INSTALLED_SLUGS=$(echo "$INSTALLED_SLUGS" | xargs)
    info "Installed GitHub Apps: $INSTALLED_SLUGS"

    if [[ "$CONTENTS_WRITE_FOUND" == "true" ]]; then
        pass "App '$CONTENTS_WRITE_SLUG' has 'contents: write' permission"
    else
        if [[ -n "$EXPECTED_APP_SLUG" ]]; then
            fail "Expected App '$EXPECTED_APP_SLUG' not found or does not have 'contents: write' permission"
        else
            fail "No installed App has 'contents: write' permission"
        fi
    fi
else
    # Cannot verify App installation with current token — degrade to WARN
    warn "Cannot verify GitHub App installation with current credentials"
    info "If APP_ID and APP_PRIVATE_KEY secrets are configured, the App will be verified at workflow runtime"
fi
echo ""

# --- Check 4: Default GITHUB_TOKEN permissions ---
echo -e "${BOLD}4. Repository workflow permissions${RESET}"

REPO_SETTINGS=$(gh api "repos/$REPO" --jq '.permissions' 2>/dev/null || echo "{}")

# Check default workflow permissions via Actions settings
ACTIONS_PERMS=$(gh api "repos/$REPO/actions/permissions/workflow" 2>/dev/null || echo "")
if [[ -n "$ACTIONS_PERMS" ]]; then
    DEFAULT_PERM=$(echo "$ACTIONS_PERMS" | jq -r '.default_workflow_permissions // "unknown"' 2>/dev/null || echo "unknown")
    CAN_APPROVE=$(echo "$ACTIONS_PERMS" | jq -r '.can_approve_pull_request_reviews // false' 2>/dev/null || echo "false")

    info "Default workflow token permissions: $DEFAULT_PERM"
    info "Workflows can approve PRs: $CAN_APPROVE"

    # For this pipeline, we need write permissions for ingot-cast
    # (or we set it per-workflow with 'permissions:' key)
    if [[ "$DEFAULT_PERM" == "write" ]]; then
        pass "Default token has write permissions (sufficient for ingot-cast.yml)"
    else
        info "Default token has '$DEFAULT_PERM' permissions — workflows must declare 'permissions: contents: write' explicitly"
        pass "Acceptable: per-workflow permissions will be declared in YAML"
    fi
else
    warn "Could not read workflow permissions (may require admin access)"
fi
echo ""

# --- Summary ---
echo -e "${BOLD}Summary${RESET}"
if [[ $FAILURES -eq 0 ]]; then
    echo -e "  ${GREEN}All checks passed.${RESET}"
    exit 0
else
    echo -e "  ${RED}$FAILURES check(s) failed.${RESET} See details above."
    exit 1
fi
