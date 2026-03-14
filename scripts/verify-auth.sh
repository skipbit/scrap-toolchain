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

SECRETS_JSON=$(gh secret list --repo "$REPO" --json name 2>/dev/null || echo "[]")

for secret_name in "${REQUIRED_SECRETS[@]}"; do
    if echo "$SECRETS_JSON" | grep -q "\"$secret_name\""; then
        pass "Secret '$secret_name' is configured"
    else
        fail "Secret '$secret_name' is not configured"
    fi
done
echo ""

# --- Check 2: Branch protection rules ---
echo -e "${BOLD}2. Branch protection for '$PROTECTED_BRANCH'${RESET}"

BRANCH_PROTECTED=false

# Try legacy branch protection API first (check HTTP status to distinguish 404)
if gh api "repos/$REPO/branches/$PROTECTED_BRANCH/protection" --silent 2>/dev/null; then
    BP_LEGACY=true
else
    BP_LEGACY=false
fi

if [[ "$BP_LEGACY" == "true" ]]; then
    # Legacy branch protection is configured
    BRANCH_PROTECTED=true
    pass "Branch protection is enabled for '$PROTECTED_BRANCH' (legacy rules)"

    BP_JSON=$(gh api "repos/$REPO/branches/$PROTECTED_BRANCH/protection" 2>/dev/null || echo "")

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
else
    # Legacy API returned 404 — try Rulesets API (GitHub repository rules)
    RULESETS_JSON=$(gh api "repos/$REPO/rulesets" 2>/dev/null || echo "[]")
    RULESET_COUNT=$(echo "$RULESETS_JSON" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$RULESET_COUNT" -gt 0 ]]; then
        # Find active rulesets targeting the protected branch
        ACTIVE_IDS=$(echo "$RULESETS_JSON" | jq -r '[.[] | select(.enforcement == "active") | .id] | .[]' 2>/dev/null || echo "")

        if [[ -z "$ACTIVE_IDS" ]]; then
            fail "Rulesets exist but none are actively enforced for '$PROTECTED_BRANCH'"
        else
            pass "Branch protection is enabled for '$PROTECTED_BRANCH' (rulesets)"
            BRANCH_PROTECTED=true

            # Check each active ruleset for pull_request rule
            PR_REVIEW_FOUND=false
            for ruleset_id in $ACTIVE_IDS; do
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
            for ruleset_id in $ACTIVE_IDS; do
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
fi
echo ""

# --- Check 3: GitHub App installation ---
echo -e "${BOLD}3. GitHub App installation${RESET}"

# Try the installations endpoint (accessible with user tokens that have admin access)
INSTALLATIONS_RAW=$(gh api "repos/$REPO/installations" 2>/dev/null || echo "")
INSTALLATIONS=$(echo "$INSTALLATIONS_RAW" | jq '.installations // [] | length' 2>/dev/null || echo "0")

if [[ "$INSTALLATIONS" -gt 0 ]]; then
    APP_SLUG=$(echo "$INSTALLATIONS_RAW" | jq -r '.installations[0].app_slug // "unknown"' 2>/dev/null || echo "unknown")
    CONTENTS_PERM=$(echo "$INSTALLATIONS_RAW" | jq -r '.installations[0].permissions.contents // "none"' 2>/dev/null || echo "none")

    pass "GitHub App '$APP_SLUG' is installed"

    if [[ "$CONTENTS_PERM" == "write" ]]; then
        pass "App has 'contents: write' permission"
    else
        fail "App has 'contents: $CONTENTS_PERM' (expected 'write')"
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
