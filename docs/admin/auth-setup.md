# Authentication & Permissions Setup

This document describes the authentication and permissions configuration required for the scrap-toolchain CI/CD pipeline.

## Overview

The pipeline has three workflows with distinct permission requirements:

| Workflow | Trigger | Token Type | Permissions |
|----------|---------|------------|-------------|
| `pr-validation.yml` | `pull_request` | Default `GITHUB_TOKEN` | `contents: read`, `pull-requests: write` <!-- Required for posting validation failure comments on PRs --> |
| `ingot-cast.yml` | `push` to main / `workflow_dispatch` | Default `GITHUB_TOKEN` | `contents: write` |
| `index-update.yml` | `workflow_run` / `workflow_dispatch` | **GitHub App token** | `contents: write` |

### Why index-update needs a GitHub App token

The default `GITHUB_TOKEN` has two limitations that prevent its use in `index-update.yml`:

1. **No workflow trigger propagation** — Pushes made with the default `GITHUB_TOKEN` do not trigger subsequent GitHub Actions workflows. If `index-update.yml` commits and pushes `index.toml` with the default token, no downstream workflows (e.g., future CI checks on main) would run.
2. **Branch protection bypass** — The default `GITHUB_TOKEN` cannot push to branches protected by rulesets that require status checks or PR reviews.

A **GitHub App installation token** solves both issues: pushes made with an App token trigger workflows normally, and the App can be added as a bypass actor in rulesets.

A **deploy key** is another alternative. Deploy keys can push to protected branches (when added as a bypass actor) and pushes made with a deploy key **do** trigger workflows. However, deploy keys lack the fine-grained permission model that GitHub Apps provide — a deploy key grants broad read/write access to the repository without the ability to scope permissions (e.g., `contents: write` only) or to manage bypass rules at the App level. A GitHub App also provides short-lived tokens (1 hour) rather than a long-lived SSH key.

## Decision: GitHub App Token

**Chosen approach**: GitHub App token via the [`actions/create-github-app-token`](https://github.com/actions/create-github-app-token) action.

**Rationale**:
- Fine-grained permissions (only `contents: write` on this repository)
- Pushes trigger subsequent workflows (unlike `GITHUB_TOKEN`)
- Can be added as a bypass actor in rulesets for controlled direct pushes
- Short-lived tokens (1 hour expiry) — no long-lived PAT or SSH key to manage
- Official GitHub-maintained action with first-party support

## Setup Instructions

### Step 1: Create a GitHub App

1. Go to **GitHub Organization Settings** > **Developer settings** > **GitHub Apps** > **New GitHub App**
2. Configure the App:
   - **Name**: `scrap-toolchain-ci` (or similar unique name — note that GitHub App names must be globally unique across all of GitHub)
   - **Homepage URL**: `https://github.com/skipbit/scrap-toolchain`
   - **Webhook**: Uncheck "Active" (no webhook needed)
   - **Permissions**:
     - Repository permissions:
       - **Contents**: Read & write (for git push)
     - No organization permissions needed
   - **Where can this GitHub App be installed?**: Only on this account
3. Click **Create GitHub App**
4. Note the **App ID** displayed on the App settings page

### Step 2: Generate a Private Key

1. On the GitHub App settings page, scroll to **Private keys**
2. Click **Generate a private key**
3. A `.pem` file will be downloaded — keep this secure
4. This key will be stored as a repository secret

### Step 3: Install the App

1. On the GitHub App settings page, click **Install App** in the sidebar
2. Select the **skipbit** organization
3. Choose **Only select repositories** and select `scrap-toolchain`
4. Click **Install**

### Step 4: Configure Repository Secrets

Go to **Repository Settings** > **Secrets and variables** > **Actions** and add:

| Secret Name | Value | Description |
|-------------|-------|-------------|
| `APP_ID` | The App ID from Step 1 | GitHub App identifier |
| `APP_PRIVATE_KEY` | Contents of the `.pem` file from Step 2 | GitHub App private key (PEM format) |

### Step 5: Configure Repository Rulesets

Go to **Repository Settings** > **Rules** > **Rulesets** > **New ruleset** > **New branch ruleset**:

- **Ruleset name**: `main branch protection`
- **Enforcement status**: Active
- **Target branches**: Add target > Include default branch (`main`)
- **Bypass list**:
  - Click **Add bypass** > select the GitHub App (`scrap-toolchain-ci`) > set mode to **Always**
  - This allows `index-update.yml` to push directly to `main` using the App token
- **Branch rules**:
  - [x] Restrict deletions
  - [x] Require a pull request before merging
    - Required approvals: 1
    - [x] Dismiss stale pull request approvals when new commits are pushed
  - [x] Require status checks to pass
    - Add required checks (after workflows are created):
      - `validate` (from `pr-validation.yml`)
      - **Note**: The check name will not appear in the GitHub UI until the workflow has run at least once.
    - [x] Require branches to be up to date before merging
  - [x] Block force pushes
  - [ ] Require signed commits (not required for now)
  - [ ] Require linear history (not required; merge commits are acceptable)

### Step 6: Verify Configuration

**Prerequisites**: The verification script requires the following:
- [`gh` CLI](https://cli.github.com/) — authenticated with admin access to the repository
- [`jq`](https://jqlang.github.io/jq/) — for JSON processing

Run the verification script to confirm the setup:

```bash
scripts/verify-auth.sh
```

This script checks:
- Repository secrets are configured (names only, not values)
- Ruleset configuration is in place
- GitHub App installation is accessible
- Repository workflow token permissions

## Usage in Workflows

### index-update.yml

```yaml
jobs:
  update-index:
    steps:
      - name: Generate token
        id: app-token
        uses: actions/create-github-app-token@v2
        with:
          app-id: ${{ secrets.APP_ID }}
          private-key: ${{ secrets.APP_PRIVATE_KEY }}

      - name: Checkout
        uses: actions/checkout@v4
        with:
          token: ${{ steps.app-token.outputs.token }}

      # ... generate index.toml ...

      - name: Commit and push
        env:
          GITHUB_TOKEN: ${{ steps.app-token.outputs.token }}
        run: |
          git config user.name "scrap-toolchain-ci[bot]"
          # Replace <BOT_USER_ID> with the App's bot user ID (not the App ID secret).
          # Find it via: https://api.github.com/users/scrap-toolchain-ci%5Bbot%5D
          git config user.email "<BOT_USER_ID>+scrap-toolchain-ci[bot]@users.noreply.github.com"
          git add index.toml
          git commit -m "update index.toml"
          git push
```

### ingot-cast.yml

Uses the default `GITHUB_TOKEN` — no additional secrets needed:

```yaml
permissions:
  contents: write

jobs:
  upload-release:
    steps:
      - name: Create release
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh release create "${TAG}" ./artifacts/*.tar.xz ./artifacts/*.sha256
```

### pr-validation.yml

Uses the default `GITHUB_TOKEN` — no additional secrets needed:

```yaml
permissions:
  contents: read
  pull-requests: write
```

## Security Considerations

- The GitHub App private key is stored as a repository secret and never exposed in logs
- App tokens are short-lived (1 hour expiry) and scoped to this repository only
- The App has minimal permissions: only `contents: write`
- `pr-validation.yml` runs on `pull_request` events (not `pull_request_target`), so fork PRs cannot access secrets or write to the repository
- `ingot-cast.yml` and `index-update.yml` only run after merge to `main`, ensuring only reviewed code executes with write permissions

## Troubleshooting

### "Resource not accessible by integration"
- Verify the GitHub App is installed on the `scrap-toolchain` repository
- Check that the App has `contents: write` permission
- Ensure secrets `APP_ID` and `APP_PRIVATE_KEY` are correctly set

### index-update push rejected by branch protection
- Add the GitHub App to the ruleset bypass list
- Go to **Settings** > **Rules** > **Rulesets** > select the `main branch protection` ruleset > **Bypass list** > **Add bypass** > select the App > set mode to **Always**

### Token generation fails
- Verify the private key PEM format (starts with `-----BEGIN RSA PRIVATE KEY-----` or `-----BEGIN PRIVATE KEY-----`)
- Ensure the App ID matches the installed App
- Check that the App installation has not been suspended
