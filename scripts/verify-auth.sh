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

BP_JSON=$(gh api "repos/$REPO/branches/$PROTECTED_BRANCH/protection" 2>/dev/null || echo "")

if [[ -z "$BP_JSON" ]]; then
    fail "No branch protection rules found for '$PROTECTED_BRANCH'"
else
    pass "Branch protection is enabled for '$PROTECTED_BRANCH'"

    # Check require PR reviews
    REQUIRE_PR=$(echo "$BP_JSON" | gh api --input - --jq '.required_pull_request_reviews // empty' 2>/dev/null || echo "")
    if [[ -n "$REQUIRE_PR" ]]; then
        pass "Pull request reviews are required"
    else
        fail "Pull request reviews are not required"
    fi

    # Check require status checks
    STATUS_CHECKS=$(echo "$BP_JSON" | gh api --input - --jq '.required_status_checks // empty' 2>/dev/null || echo "")
    if [[ -n "$STATUS_CHECKS" ]]; then
        pass "Status checks are required"
    else
        warn "Status checks are not yet required (configure after workflows are created)"
    fi
fi
echo ""

# --- Check 3: GitHub App installation ---
echo -e "${BOLD}3. GitHub App installation${RESET}"

INSTALLATIONS=$(gh api "repos/$REPO/installation" 2>/dev/null || echo "")

if [[ -z "$INSTALLATIONS" ]]; then
    warn "No GitHub App installation detected on this repository"
    info "Install the GitHub App and run this check again after setup"
else
    APP_SLUG=$(echo "$INSTALLATIONS" | gh api --input - --jq '.app_slug // "unknown"' 2>/dev/null || echo "unknown")
    PERMISSIONS=$(echo "$INSTALLATIONS" | gh api --input - --jq '.permissions // {}' 2>/dev/null || echo "{}")

    pass "GitHub App '$APP_SLUG' is installed"

    # Check contents permission
    CONTENTS_PERM=$(echo "$PERMISSIONS" | gh api --input - --jq '.contents // "none"' 2>/dev/null || echo "none")
    if [[ "$CONTENTS_PERM" == "write" ]]; then
        pass "App has 'contents: write' permission"
    else
        fail "App has 'contents: $CONTENTS_PERM' (expected 'write')"
    fi
fi
echo ""

# --- Check 4: Default GITHUB_TOKEN permissions ---
echo -e "${BOLD}4. Repository workflow permissions${RESET}"

REPO_SETTINGS=$(gh api "repos/$REPO" --jq '.permissions' 2>/dev/null || echo "{}")

# Check default workflow permissions via Actions settings
ACTIONS_PERMS=$(gh api "repos/$REPO/actions/permissions/workflow" 2>/dev/null || echo "")
if [[ -n "$ACTIONS_PERMS" ]]; then
    DEFAULT_PERM=$(echo "$ACTIONS_PERMS" | gh api --input - --jq '.default_workflow_permissions // "unknown"' 2>/dev/null || echo "unknown")
    CAN_APPROVE=$(echo "$ACTIONS_PERMS" | gh api --input - --jq '.can_approve_pull_request_reviews // false' 2>/dev/null || echo "false")

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
