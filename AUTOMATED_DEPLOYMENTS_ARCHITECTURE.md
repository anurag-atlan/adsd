# Automated Deployments Architecture

> **Status**: Proposal
> **Date**: 2026-02-27
> **Audience**: Engineering team — anyone building, reviewing, or operating this system

---

## The Vision: AI Agents That Build, Deploy, and Fix Apps

The goal is simple: **a developer describes what they want, and an AI agent (Claude Code, Codex, or similar) writes the code, runs tests, deploys it, reads logs, fixes failures, and redeploys — in a loop — with the human only needed for approval or adding context.**

The developer's role shifts from "write code, build image, push, deploy, SSH into cluster, read logs, fix, repeat" to "describe intent, review AI's work, approve deployments."

### Example: Building a Salesforce Connector from Scratch

Here's what this looks like end-to-end for a real app:

```
DEVELOPER: "Build me a Salesforce connector that syncs accounts and
            contacts into Atlan. Use the Salesforce REST API with
            OAuth2. Deploy it to my dev tenant."

CLAUDE CODE:
  ── Step 1: Scaffold the app ──────────────────────────────────────

  > Reads Atlan app documentation and examples
  > Creates project structure:
      salesforce-connector/
      ├── Dockerfile
      ├── app-manifest.yaml        (name: salesforce-connector, type: connector)
      ├── app-config.yaml          (replicas: 1, dapr: {secretstore: true})
      ├── src/
      │   ├── main.py              (FastAPI app + Temporal worker)
      │   ├── workflows/
      │   │   └── sync_workflow.py  (SyncAccountsWorkflow, SyncContactsWorkflow)
      │   ├── activities/
      │   │   ├── salesforce.py     (OAuth2 auth, REST API calls)
      │   │   └── atlan.py          (Push assets to Atlan)
      │   └── models/
      │       └── salesforce.py     (Account, Contact pydantic models)
      ├── tests/
      │   ├── test_salesforce.py
      │   └── test_workflows.py
      ├── requirements.txt
      └── .github/workflows/marketplace-build.yml

  > atlan_app_init(app_name="salesforce-connector", app_type="connector")

  ── Step 2: Run tests locally ─────────────────────────────────────

  > Runs: pytest tests/ -v
  > 2 tests fail — OAuth token refresh not handled
  > Fixes salesforce.py, adds token refresh logic
  > Runs: pytest tests/ -v → 12/12 pass

  ── Step 3: Deploy ────────────────────────────────────────────────

  > atlan_app_deploy(branch="main")
  > Validates app-manifest.yaml + app-config.yaml... OK
  > Polls... building... built... installing...
  > Status: FAILED

  ── Step 4: Read failure, fix, redeploy ───────────────────────────

  > atlan_app_failure(deployment_id="d-456")
  > Pod logs: "ImportError: No module named 'simple_salesforce'"
  >
  > "Missing dependency. Adding to requirements.txt."
  > Adds simple-salesforce to requirements.txt
  > git commit + git push
  >
  > atlan_app_deploy(branch="main")
  > Validates... OK. Polls... building... built... installing...
  > Status: SUCCEEDED

  ── Step 5: Verify runtime behavior ──────────────────────────────

  > atlan_app_workflows(app_id="salesforce-connector", status="failed")
  > 1 failed workflow: "SyncAccountsWorkflow — 401 Unauthorized"
  >
  > atlan_app_logs(app_id="salesforce-connector", tail=50)
  > "ERROR: Salesforce API returned 401. Token: eyJ..."
  >
  > "OAuth client_id is wrong in the env config."
  > Fixes app-config.yaml env section with correct SALESFORCE_CLIENT_ID
  > git commit + git push
  >
  > atlan_app_deploy(branch="main")
  > Status: SUCCEEDED
  > Commit status pushed to GitHub: ✅ "Deployed to dev-01"

  ── Step 6: Confirm it works ──────────────────────────────────────

  > atlan_app_workflows(app_id="salesforce-connector", status="completed")
  > 3 completed: SyncAccountsWorkflow, SyncContactsWorkflow, ...
  >
  > atlan_app_logs(app_id="salesforce-connector", tail=20, since="2m")
  > "INFO: Synced 847 accounts, 2,341 contacts to Atlan"

CLAUDE CODE: "Your Salesforce connector is deployed and running on dev-01.
              It synced 847 accounts and 2,341 contacts. The app is at
              version sha-abc123. Want me to publish this to staging?"

DEVELOPER: "Yes, publish to staging"

CLAUDE CODE:
  > atlan_app_publish(branch="main", channel="staging")
  > "Published. Release is in draft status — needs approval
  >  from an admin in the GM dashboard."
```

**What the developer did**: Described what they wanted. Reviewed Claude's code. Said "yes, publish."

**What Claude did**: Wrote all the code. Ran tests. Fixed test failures. Deployed. Read crash logs. Fixed missing dependency. Redeployed. Read workflow errors. Fixed config. Redeployed. Verified success. Published.

**Total deployments**: 3 (two failed, one succeeded — all handled autonomously).

This is the experience we're building. Everything below describes the architecture that makes it possible.

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Problem Statement](#2-problem-statement)
3. [System Overview](#3-system-overview)
4. [Existing Systems (As-Is)](#4-existing-systems-as-is)
5. [New Components (To-Be)](#5-new-components-to-be)
6. [End-to-End Flows](#6-end-to-end-flows)
7. [Work Stream A: Build & Release Pipeline](#7-work-stream-a-build--release-pipeline)
8. [Work Stream B: Deploy, Observe & Recover](#8-work-stream-b-deploy-observe--recover)
9. [MCP Server Specification](#9-mcp-server-specification)
10. [API Contracts](#10-api-contracts)
11. [Data Models & Storage](#11-data-models--storage)
12. [Failure Handling & Edge Cases](#12-failure-handling--edge-cases)
13. [Security & Access Control](#13-security--access-control)
14. [Migrating Existing Apps](#14-migrating-existing-apps)
15. [Open Questions](#15-open-questions)

---

## 1. Executive Summary

We are building a **developer platform** that exposes build, deploy, and debug capabilities for Atlan apps through an **MCP (Model Context Protocol) server** so that AI agents (Claude Code, Codex, or any MCP-compatible tool) can autonomously write code, run tests, deploy, observe failures, fix code, and redeploy in a loop — with humans only for approval or adding context.

**Key principle**: The MCP server is the sole interface for agents. All MCP tools call **Local Marketplace (LM)** REST APIs via httpx. LM is the per-tenant gateway that proxies build/release requests to the **Global Marketplace (GM)**, the cross-tenant service. All validation (manifest, config, Dockerfile) happens server-side in LM/GM APIs.

### What Changes

| Today | After |
|-------|-------|
| Developers write code, build images, push manually | AI agents write code, MCP tools trigger builds via GitHub Actions |
| Releases created manually in GM admin UI | `atlan_app_deploy` MCP tool triggers build + version + release automatically |
| Developers SSH into vclusters to debug pods | Live log streaming + stored failure snapshots via API |
| No AI-in-the-loop | MCP tools let AI agents deploy → read logs → fix → redeploy autonomously |
| Humans do everything, AI assists | AI does everything, humans approve and add context |

### What Stays the Same

- LM manages installations via Temporal workflows + Flux HelmRelease (unchanged)
- GM manages apps, versions, releases in PostgreSQL (unchanged, extended)
- Reconciliation loop (5 min) auto-upgrades installed apps (unchanged)
- Atlas stores deployment records (AtlanAppDeployment/AtlanAppInstalled entities)

---

## 2. Problem Statement

### For Developers
1. **No standardized build pipeline** — developers build images manually and push to registries.
2. **No programmatic interface for deployment** — install/publish requires manual API calls or admin UI. No MCP tools for AI agents.
3. **Debugging is painful** — developers need vcluster access, find pods manually, read logs manually.
4. **Flux reverts failing pods** — by the time a developer checks, the crashing pod is gone and evidence is lost.
5. **No AI-assisted debugging loop** — even with Claude Code, there's no way for it to see deployment status or pod logs.

### For the Platform
1. **No build audit trail** — no record of what commit produced which image.
2. **No deployment traceability** — can't link a GitHub commit → image → release → deployment.
3. **No observability API** — logs/events are only accessible via direct kubectl access.

---

## 3. System Overview

```
                              Developer's Machine / AI Agent Host
                    ┌──────────────────────────────────────┐
                    │  Claude Code / Codex / MCP Client     │
                    │       │                               │
                    │       ▼                               │
                    │  MCP Server (agent-toolkit-internal)  │
                    │  atlan_app_* tools                    │
                    │  (deploy, publish, status, logs,      │
                    │   events, workflows, failure, info)   │
                    └──────────┬───────────────────────────┘
                               │ Authenticated (JWT / API key via httpx)
                               ▼
            ┌─────────────────────────────────────────────┐
            │  Heracles — Auth Proxy (Per Tenant)          │
            │  - Validates JWT / API key                   │
            │  - Routes authenticated requests to LM       │
            │  - Separate service URL per tenant           │
            └──────────┬──────────────────────────────────┘
                       │ Authenticated (trusted, after Heracles validation)
                       ▼
            ┌─────────────────────────────────────────────┐
            │  Local Marketplace (LM) — Per Tenant         │
            │                                              │
            │  EXISTING:                                   │
            │  ├─ Install/Upgrade/Uninstall (Temporal)     │
            │  ├─ Reconciler (5 min loop)                  │
            │  ├─ Deployment tracking (Atlas)              │
            │  └─ Catalog service (S3 + memory cache)      │
            │                                              │
            │  NEW:                                        │
            │  ├─ Proxy to GM (/deploy, /publish, /builds) │
            │  ├─ Failure snapshot capture (Temporal)       │
            │  ├─ Live log streaming API (kubectl)         │
            │  ├─ K8s events/describe API                  │
            │  └─ App workflow failure query (Temporal)     │
            └──────────┬──────────────────────────────────┘
                       │ Internal (trusted, tenant header)
                       ▼
            ┌─────────────────────────────────────────────┐
            │  Global Marketplace (GM) — Cross Tenant      │
            │                                              │
            │  EXISTING:                                   │
            │  ├─ Apps, Versions, Releases (PostgreSQL)    │
            │  ├─ Tenant catalog API                       │
            │  ├─ Admin UI + Okta SSO                      │
            │  └─ Horizon tenant sync                      │
            │                                              │
            │  NEW:                                        │
            │  ├─ GitHub App integration                   │
            │  ├─ Builds table (tracking)                  │
            │  ├─ Build trigger (workflow_dispatch)         │
            │  ├─ GitHub App webhook handler (workflow_run) │
            │  ├─ Auto version + release creation          │
            │  └─ GitHub Deployment status tracking         │
            └──────────┬──────────────────────────────────┘
                       │ GitHub App (workflow_dispatch + deployments API)
                       ▼
            ┌─────────────────────────────────────────────┐
            │  Developer's GitHub Repo                     │
            │                                              │
            │  Created by `atlan_app_init`:                      │
            │  ├─ Dockerfile                               │
            │  ├─ app-manifest.yaml (metadata)             │
            │  ├─ app-config.yaml (deployment config)            │
            │  └─ .github/workflows/marketplace-build.yml  │
            └──────────┬──────────────────────────────────┘
                       │ Reusable workflow call
                       ▼
            ┌─────────────────────────────────────────────┐
            │  atlanhq/application-sdk (Existing Repo)   │
            │                                              │
            │  └─ .github/workflows/build-app.yml          │
            │      (reusable workflow)                     │
            └─────────────────────────────────────────────┘
```

---

## 4. Existing Systems (As-Is)

### 4.1 Local Marketplace (LM)

**Repo**: `atlanhq/local-marketplace-app`
**Runtime**: FastAPI + Temporal worker, one instance per tenant
**Storage**: Atlan Atlas API (Elasticsearch-backed)

#### Current API Endpoints

| Method | Endpoint | Purpose |
|--------|----------|---------|
| `GET` | `/api/v1/marketplace/apps` | List available apps from catalog |
| `POST` | `/api/v1/marketplace/tenant/default/apps/{app_id}/install` | Install an app |
| `GET` | `/api/v1/marketplace/apps/deployments/{id}` | Deployment status |
| `GET` | `/api/v1/marketplace/apps/deployments/{id}?stream=true` | SSE deployment status |

#### Key Components

| Component | File | Purpose |
|-----------|------|---------|
| `TenantAppsManagerService` | `src/tenant_apps_manager/core/tenant_apps_manager_service.py` | Coordinates install/upgrade/downgrade, submits Temporal workflows |
| `TenantAppsStore` | `src/tenant_apps_manager/store/tenant_app_store.py` | Atlas API CRUD for AtlanAppDeployment and AtlanAppInstalled |
| `ReconciliationService` | `src/reconciller/reconciliation_service.py` | 5-min loop: compares installed vs marketplace versions, triggers updates |
| `AppDeploymentWorkflow` | `src/deployment_orchestrator/deployment_orchestrator.py` | Temporal workflow: trigger_cd → notify_registry |
| `CatalogService` | `src/catalog_service/core/catalog.py` | Fetches apps from GM, caches in memory + S3 |
| `flux_utils` | `src/deployment_orchestrator/flux_utils.py` | Generates HelmRelease YAML, applies via kubectl |
| `config_parser` | `src/deployment_orchestrator/config_parser.py` | Transforms YAML config to Helm chart values |

#### Deployment Flow (Current)

```
POST /install → TenantAppsManagerService.request_app_deploy()
  → log_install_request() in Atlas (AtlanAppDeployment, status=PENDING)
  → Submit Temporal workflow (AppDeploymentWorkflow)
    → Activity: trigger_cd
      → generate_helmrelease_yaml(command)
      → apply_helmrelease_via_kubectl()
      → Wait for pod readiness
    → Activity: notify_registry
      → complete_deployment_success() OR mark_deployment_failure() in Atlas
```

#### Key Data Models (LM)

```python
# src/tenant_apps_manager/models/service.py
class AppDeploymentCommand(BaseModel):
    app_id: str          # UUIDv7
    app_name: str
    version_id: str      # UUIDv7
    version_text: str    # e.g., "1.2.3"
    image_url: str
    force_apply: bool = False
    deployment_id: str = ""
    app_infra: AppInfra = AppInfra.ATLAN_INFRA
    config: str = ""     # YAML config from GM

class InstalledApp(BaseModel):
    app_id: str
    version_id: str
    version_text: str
    installed_at: str    # ISO timestamp string (Temporal sandbox restriction)
    last_modified_on: str
```

#### Atlas Entity Types

| Entity | Key Attributes | Purpose |
|--------|---------------|---------|
| `AtlanAppDeployment` | `atlanAppStatus` (PENDING/COMPLETED/FAILED), `atlanAppOperation` (INSTALL/UPGRADE), `atlanAppVersionUUID` | Tracks deployment requests |
| `AtlanAppInstalled` | `appId`, `atlanAppCurrentVersionUUID` | Final state of installed apps |

### 4.2 Global Marketplace (GM)

**Repo**: `atlanhq/global-marketplace`
**Runtime**: FastAPI + asyncpg
**Storage**: PostgreSQL

#### Current API Endpoints

**Admin API** (`/api/v1/admin/`) — protected by Okta SSO:

| Method | Endpoint | Purpose |
|--------|----------|---------|
| `POST/GET/PUT/DELETE` | `/api/v1/admin/apps/{public_id}` | App CRUD |
| `POST/GET` | `/api/v1/admin/versions` | Version CRUD |
| `POST/GET` | `/api/v1/admin/releases` | Release CRUD |
| `POST` | `/api/v1/admin/releases/{id}/approve` | Approve draft release |
| `DELETE` | `/api/v1/admin/releases/{id}` | Soft-delete release |

**Tenant API** (`/api/v1/tenants/`) — protected by JWT:

| Method | Endpoint | Purpose |
|--------|----------|---------|
| `GET` | `/api/v1/tenants/catalog` | Apps + latest active releases for tenant |

#### Key Data Models (GM)

```python
# core/app/model.py
class App(BaseModel):
    public_id: UUID        # UUIDv7, exposed as "id"
    name: str              # Deployment namespace name (immutable after creation)
    display_name: str      # User-friendly name
    visibility: Visibility # public/private
    allowed_tenants: List[str]
    is_system_app: bool    # Auto-install/upgrade flag
    app_type: str
    argo_package_names: Optional[str]

# core/version/model.py
class Version(BaseModel):
    public_id: UUID
    app_public_id: UUID
    version: str           # e.g., "1.0.0"
    image: str             # Container image URI
    config: str            # YAML deployment config

# core/release/model.py
class Release(BaseModel):
    public_id: UUID
    app_public_id: UUID
    version_public_id: UUID
    status: ReleaseStatus          # draft / active / inactive / rolled_back
    target_channel: str            # all / beta / staging / specific
    allowed_tenants: List[str]     # For target_channel="specific"
    created_by: Optional[str]      # Email
    approved_by: Optional[str]     # Email
```

#### Release Approval Workflow

```
target_channel = "all"/"beta"/"staging" → status = "draft" (requires approval)
target_channel = "specific"             → status = "active" (auto-approved)

Draft → Approve (POST /releases/{id}/approve) → Active
Active → Visible in tenant catalog
```

#### Tenant Catalog Query Logic

The `GET /api/v1/tenants/catalog` endpoint returns `List[AppWithLatestRelease]`:
- Filters apps by visibility (public OR tenant in `allowed_tenants`)
- Filters releases by: `status = 'active'`, `deleted_at IS NULL`
- Matches `target_channel` to tenant's channel (from `horizon_tenants` lookup)
- Returns up to 5 latest active releases per app
- Each release includes `config` (YAML) and `image` (container image URI)

#### PostgreSQL Tables

| Table | Key Columns |
|-------|-------------|
| `marketplace_apps` | `public_id` (UUID), `name`, `display_name`, `visibility`, `allowed_tenants`, `is_system_app` |
| `versions` | `public_id` (UUID), `app_id` (FK), `version`, `image`, `config` |
| `releases` | `public_id` (UUID), `app_id` (FK), `version_id` (FK), `status`, `target_channel`, `allowed_tenants`, `created_by`, `approved_by` |
| `horizon_tenants` | `tenant_id`, `channel` (beta/staging), synced hourly from Horizon API |
| `audit_log_entries` | `operation`, `table_name`, `record_id`, `old_data`, `new_data`, `user_email` |

---

## 5. New Components (To-Be)

### 5.1 MCP Server (`atlanhq/agent-toolkit-internal` — existing repo, extended)

**We are NOT building a new MCP server or CLI.** The `agent-toolkit-internal` repo is already a production MCP server (Python, FastMCP v2.14+) with 16 tools for data catalog operations. We add `atlan_app_*` tools to it. These are the **sole interface** for AI agents — there is no CLI.

**Repo**: `atlanhq/agent-toolkit-internal`
**Existing infrastructure we inherit:**
- **Auth**: OAuth/JWT mode + API key mode (the JWT/API key identifies the tenant)
- **Tool access control**: LaunchDarkly feature flags per tool per tenant
- **Observability**: OpenTelemetry + Phoenix tracing with PII redaction
- **Pattern**: Tools call Atlan APIs via `pyatlan` SDK or HTTP — our tools use httpx to call LM REST APIs **via Heracles** (auth proxy)

**New tools (added to `modelcontextprotocol/tools/app.py`):**

All tools call LM REST APIs **via Heracles** (auth proxy). Heracles validates the JWT/API key and routes the request to the tenant's LM instance. LM has no auth of its own — Heracles is the auth gateway.

| MCP Tool | LM API Endpoint (via Heracles) | Read/Write |
|----------|-------------------------------|------------|
| `atlan_app_init` | Local only (scaffolds files) | Write |
| `atlan_app_deploy` | `POST /api/v1/marketplace/builds` | Write |
| `atlan_app_publish` | `POST /api/v1/marketplace/publish` | Write |
| `atlan_app_status` | `GET /api/v1/marketplace/builds/{id}` or `GET .../deployments/{id}` | Read-only |
| `atlan_app_build_logs` | `GET /api/v1/marketplace/builds/{id}/logs` | Read-only |
| `atlan_app_logs` | `GET /api/v1/marketplace/apps/{id}/logs` | Read-only |
| `atlan_app_events` | `GET /api/v1/marketplace/apps/{id}/events` | Read-only |
| `atlan_app_workflows` | `GET /api/v1/marketplace/apps/{id}/workflows` | Read-only |
| `atlan_app_failure` | `GET /api/v1/marketplace/apps/deployments/{id}/failure` | Read-only |
| `atlan_app_info` | `GET /api/v1/marketplace/apps/{id}/info` | Read-only |
| `atlan_app_check_installed` | `GET /api/v1/marketplace/apps/{id}/installed` | Read-only |

**No `atlan_app_auth` tool needed** — auth is handled by the MCP server's existing JWT/API key mechanism. The user's token determines which tenant they're on.

**Validation is server-side**: The `atlan_app_deploy` tool sends repo, branch, and commit SHA to LM. LM/GM validate `app-manifest.yaml`, `app-config.yaml`, and `Dockerfile` existence — the MCP tool does not validate locally.

**LaunchDarkly**: Each tool gets a feature flag (e.g., `tool-atlan-app-deploy-enabled`) following the existing naming pattern.

**Tenant scoping rule**: Every tool except `atlan_app_publish` operates on the **authenticated tenant only** (from the MCP session's JWT). No tenant parameter accepted. Only `atlan_app_publish` accepts `tenants` or `channel` for cross-tenant targeting.

### 5.2 Central Build Repo

**Repo**: `atlanhq/application-sdk` (existing, open-source)

The application-sdk already provides the SDK for building Atlan apps. We add a **reusable GitHub Actions workflow** here — making it the single source of truth for "how to build an Atlan app" (SDK + build contract).

```
atlanhq/application-sdk/
├── ...                          # Existing SDK code
├── .github/workflows/
│   └── build-app.yml          # Reusable workflow (NEW)
└── README.md
```

**Why a reusable workflow instead of running builds in a separate repo:**
- Builds run **in the developer's repo**, so developers see build logs in their own GitHub Actions tab
- Central repo controls the build contract — update once, all apps get it
- `atlan_app_init` MCP tool scaffolds a thin wrapper workflow that calls `@main` from the central repo
- GM's GitHub App triggers `workflow_dispatch` on the developer's repo

#### `build-app.yml` — Reusable Workflow

```yaml
# atlanhq/application-sdk/.github/workflows/build-app.yml
name: Build Atlan App

on:
  workflow_call:
    inputs:
      commit_sha:
        required: true
        type: string
        description: "Exact commit SHA to build"
      image_tag:
        required: true
        type: string
        description: "Image tag to use (computed by GM, e.g. 'abc1234abcd')"
      app_name:
        required: true
        type: string
        description: "App name from app-manifest.yaml (used for image naming)"
      enable_sdr:
        required: false
        type: boolean
        default: false
        description: "If true, also push to DockerHub for Self-Deployed Runtime"
    secrets: inherit
    # All secrets (ORG_PAT_GITHUB, DOCKER_HUB_PAT_RW, SNYK_TOKEN_BU_APPS)
    # are atlanhq org-level secrets. The caller repo inherits them
    # automatically — no per-repo secret setup needed.

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          ref: ${{ inputs.commit_sha }}

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Set image names
        id: img
        run: |
          echo "ghcr_image=ghcr.io/atlanhq/${{ inputs.app_name }}-main" >> $GITHUB_OUTPUT
          echo "dockerhub_image=atlanhq/${{ inputs.app_name }}" >> $GITHUB_OUTPUT

      - name: Login to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.ORG_PAT_GITHUB }}

      - name: Build and push to GHCR (multi-arch + Snyk scan)
        uses: atlanhq/.github/.github/actions/secure-build-push-apps@main
        with:
          image_name: ${{ steps.img.outputs.ghcr_image }}
          image_tag: ${{ inputs.image_tag }}
          platforms: linux/amd64,linux/arm64
          push: true
          snyk_token: ${{ secrets.SNYK_TOKEN_BU_APPS }}
          build-args: |
            ACCESS_TOKEN_USR=${{ github.actor }}
            ACCESS_TOKEN_PWD=${{ secrets.ORG_PAT_GITHUB }}

      # --- Conditional DockerHub push (SDR apps only) ---
      - name: Login to DockerHub
        if: ${{ inputs.enable_sdr }}
        uses: docker/login-action@v3
        with:
          username: atlanhq
          password: ${{ secrets.DOCKER_HUB_PAT_RW }}

      - name: Push to DockerHub (SDR)
        if: ${{ inputs.enable_sdr }}
        run: |
          docker buildx imagetools create \
            ${{ steps.img.outputs.ghcr_image }}:${{ inputs.image_tag }} \
            --tag ${{ steps.img.outputs.dockerhub_image }}:main-${{ inputs.image_tag }}
```

**No callback step, no shell script.** The workflow just builds and pushes. GM learns the result via the GitHub App `workflow_run` webhook event (see Section 7.7). The image tag is passed in by GM — the workflow doesn't compute it.

#### How GM Triggers the Build (workflow_dispatch)

GM uses the GitHub App's installation access token to trigger the reusable workflow on the developer's repo. **GM computes the image tag** from the commit SHA before triggering — this makes GM the single source of truth for tag format.

```python
# GM: trigger build on developer's repo
async def trigger_build(repo: str, branch: str, build_id: str, commit_sha: str, app_manifest: dict):
    """
    repo: "atlanhq/my-connector"
    branch: "feat/new-thing"
    """
    token = await get_github_app_installation_token(repo)

    # GM computes the image tag — single source of truth
    image_tag = commit_sha[:7] + "abcd"

    # Read app-manifest.yaml to check enable_sdr flag
    enable_sdr = app_manifest.get("enable_sdr", False)

    # Store image_tag in builds table BEFORE triggering
    await db.builds.insert(build_id=build_id, image_tag=image_tag, status="pending")

    # Trigger workflow_dispatch on the developer's repo
    resp = await httpx.post(
        f"https://api.github.com/repos/{repo}/actions/workflows/marketplace-build.yml/dispatches",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
        },
        json={
            "ref": branch,
            "inputs": {
                "commit_sha": commit_sha,
                "image_tag": image_tag,  # GM decides the tag, workflow just uses it
                "app_name": app_manifest["name"],
                "enable_sdr": str(enable_sdr).lower(),  # "true" or "false"
            },
        },
    )
    # workflow_dispatch returns 204 No Content on success
    if resp.status_code != 204:
        raise BuildTriggerError(f"Failed to trigger build: {resp.status_code} {resp.text}")

    # Poll to get the run_id (workflow_dispatch doesn't return it)
    run_id = await poll_for_run_id(repo, commit_sha, token)
    return run_id
```

**Secrets**: All secrets are `atlanhq` **org-level secrets** — no per-repo setup needed. The caller repo's workflow uses `secrets: inherit`, and the reusable workflow in `application-sdk` automatically receives them.

| Secret | Org-level | Purpose |
|--------|-----------|---------|
| `ORG_PAT_GITHUB` | Already exists | GHCR login, cross-repo access |
| `DOCKER_HUB_PAT_RW` | Already exists | DockerHub push (only used if `enable_sdr: true`) |
| `SNYK_TOKEN_BU_APPS` | Already exists | Container security scanning |

**No new secrets needed.** All three already exist at the `atlanhq` org level. Zero per-repo configuration.

> **Future: Partner repos (outside `atlanhq` org)** will not have access to org secrets. For those, GM will trigger builds on a centralized `atlanhq/marketplace-builder` repo that clones the partner code and builds on their behalf. This keeps secrets within `atlanhq`. Not in scope today.

#### Image Registry Strategy

| Condition | Registry | Image | Tags |
|-----------|----------|-------|------|
| Always | GHCR (`ghcr.io`) | `ghcr.io/atlanhq/{app_name}-main` | `<sha7>abcd` |
| `enable_sdr: true` in app-manifest.yaml | DockerHub (`docker.io`) | `atlanhq/{app_name}` | `main-<sha7>abcd` |

**SDR (Self-Deployed Runtime)**: Apps with `enable_sdr: true` are designed to run on customer infrastructure outside Atlan's managed clusters. DockerHub provides public access so customers can pull images without GHCR credentials.

### 5.3 GitHub App

A GitHub App installed on the `atlanhq` org, owned by GM. It needs:

| Permission | Scope | Purpose |
|-----------|-------|---------|
| Actions: write | Repository | Trigger `workflow_dispatch`, check if a workflow is already running for a commit |
| Packages: read | Repository | Check if a container image already exists for a commit SHA (dedup before building) |
| Deployments: write | Repository | Create GitHub Deployments for tracking |
| Statuses: write | Repository | Create commit status checks (green checkmark on commit after successful deploy) |
| Contents: read | Repository | Read `app-manifest.yaml` and `app-config.yaml` for metadata |

---

## 6. End-to-End Flows

### 6.1 First-Time Setup

```
Prerequisites:
  - MCP server (agent-toolkit-internal) connected to Claude Code / Codex
  - MCP session authenticated to the target tenant (JWT / API key)
    → Auth is handled by the existing MCP server infrastructure
    → No separate auth step needed — the MCP client provides credentials

Agent (or developer):
  > atlan_app_init(app_name="my-connector", app_type="connector")
    → Detects repo from .git/config
    → Creates:
      ├── Dockerfile                         (if not exists)
      ├── app-manifest.yaml                  (app metadata)
      ├── app-config.yaml                    (deployment config: replicas, env, dapr, resources)
      └── .github/workflows/marketplace-build.yml  (thin wrapper → reusable workflow)
```

**app-manifest.yaml** (metadata, read by GM):
```yaml
name: my-connector              # K8s namespace name (immutable)
display_name: My Connector      # Human-readable name
app_type: connector             # connector / miner / orchestrator
description: Syncs data from X
tags: [data-integration, etl]
icon_url: https://example.com/icon.png
enable_sdr: false               # If true, also push image to DockerHub for Self-Deployed Runtime
```

**app-config.yaml** (deployment config, becomes Helm values):
```yaml
replicaCount: 2
containerPort: 8000
env:
  LOG_LEVEL: debug
  MY_VAR: value
dapr:
  objectstore: true
  secretstore: true
  statestore: false
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

**.github/workflows/marketplace-build.yml** (scaffolded by `atlan_app_init`):
```yaml
name: Marketplace Build
on:
  workflow_dispatch:
    inputs:
      commit_sha:
        required: true
      image_tag:
        required: true
      app_name:
        required: true
      enable_sdr:
        required: false
        default: "false"

jobs:
  build:
    uses: atlanhq/application-sdk/.github/workflows/build-app.yml@main
    with:
      commit_sha: ${{ inputs.commit_sha }}
      image_tag: ${{ inputs.image_tag }}
      app_name: ${{ inputs.app_name }}
      enable_sdr: ${{ inputs.enable_sdr == 'true' }}
    secrets: inherit
```

### 6.2 Deploy Flow (Build + Release + Install)

```
Agent: atlan_app_deploy(branch="feat/new-thing")

Step 1: MCP tool reads context
  ├─ Repo name from .git/config (e.g., "atlanhq/my-connector")
  ├─ Commit SHA from `git rev-parse feat/new-thing`
  └─ Tenant from MCP session auth context (JWT — no override)

Step 2: MCP tool → Heracles → LM
  POST {heracles_url}/api/v1/marketplace/builds
  Headers: Authorization: Bearer <jwt>
  {
    "repo": "atlanhq/my-connector",
    "branch": "feat/new-thing",
    "commit_sha": "abc123def"
  }
  → Heracles validates JWT, routes to LM

Step 3: LM validates (server-side, before proxying to GM)
  ├─ Reads app-manifest.yaml from repo via GitHub API (or from request if provided)
  ├─ Reads app-config.yaml from repo via GitHub API (or from request if provided)
  ├─ Validates: app-manifest.yaml exists, valid schema, name is K8s-compatible
  ├─ Validates: app-config.yaml exists, valid YAML, known fields have correct types
  ├─ Validates: Dockerfile exists in repo
  └─ If any validation fails → return 400 with errors, no build triggered

Step 4: LM → GM (proxy)
  POST /internal/api/v1/builds
  {
    "repo": "atlanhq/my-connector",
    "branch": "feat/new-thing",
    "commit_sha": "abc123def",
    "tenant_id": "mycompany",
    "app_manifest": { ... },
    "app_config": "..."
  }

Step 5: GM processes build request
  ├─ Ensure app exists in marketplace_apps (create from app_manifest if needed)
  │
  ├─ Check 1: Does a package (container image) already exist for this commit_sha?
  │   GET /orgs/{org}/packages/container/{app_name}/versions (filter by tag sha-{commit_sha})
  │   YES → Skip build entirely, create version + release from existing image
  │   NO  → Continue to Check 2
  │
  ├─ Check 2: Is a GitHub Action already running for this commit?
  │   GET /repos/{owner}/{repo}/actions/runs?head_sha={commit_sha}&status=in_progress
  │   YES → Attach to existing run (store run_id, wait for webhook event)
  │   NO  → Continue to trigger (this is the most common path)
  │
  ├─ Compute image_tag: commit_sha[:7] + "abcd"  (GM is the single source of truth)
  ├─ Insert row in `builds` table (build_id = UUIDv7, image_tag, status = "pending")
  │
  ├─ Trigger: workflow_dispatch on developer's repo via GitHub App
  │   POST /repos/{owner}/{repo}/actions/workflows/marketplace-build.yml/dispatches
  │   inputs: { commit_sha, image_tag, app_name, enable_sdr }
  ├─ Poll for run_id, store github_run_id, update status = "building"
  ├─ Create GitHub Deployment on the repo (status: "pending")
  └─ Return to LM → MCP tool:
     {
       "build_id": "019abc...",
       "status": "building",
       "github_actions_url": "https://github.com/atlanhq/my-connector/actions/runs/12345"
     }

Step 6: GitHub Action runs (in developer's repo)
  ├─ Calls reusable workflow from atlanhq/application-sdk
  ├─ Checks out commit_sha
  ├─ Builds multi-arch Docker image (amd64 + arm64) with Snyk security scan
  ├─ Pushes to GHCR using the image_tag GM provided (e.g., ghcr.io/atlanhq/my-connector-main:abc1234abcd)
  ├─ If enable_sdr=true, also pushes to DockerHub
  └─ Done. No callback — GitHub sends a `workflow_run` event to GM's App webhook.

Step 7: GM learns build result (two parallel paths)

  Both paths run simultaneously. Whichever detects completion first
  updates the builds row. The other path sees the status change and stops.

  PATH A — GitHub App `workflow_run` webhook:
  ├─ GitHub sends `workflow_run` event (conclusion: "success"/"failure", head_sha, repo)
  ├─ GM looks up builds row by (repo, commit_sha) — already has image_tag from Step 5
  ├─ Update builds row: status = "built"
  ├─ Create version + release, set status = "released"
  └─ Update GitHub Deployment status → "success"

  PATH B — Poller (runs in parallel from the moment build starts):
  ├─ Every 30 seconds, for up to 20 minutes:
  │   1. Check builds row in DB — if status is no longer "building", stop
  │      (webhook already handled it)
  │   2. If still "building", call GitHub Actions API:
  │      GET /repos/{owner}/{repo}/actions/runs/{run_id}
  │      → completed + success: proceed same as Path A (image_tag already in DB)
  │      → completed + failure: set status = "failed", store error_message
  │      → still running: sleep 30s, loop
  └─ After 20 minutes (~40 polls): mark build as "failed"

Step 8: MCP tool polls build status (atlan_app_status)
  GET /api/v1/marketplace/builds/{build_id}
  → { status: "building" }
  → { status: "built" }
  → { status: "released", version_id: "...", release_id: "..." }

Step 9: LM triggers install (automatic after release)
  ├─ Existing flow: TenantAppsManagerService.request_app_deploy()
  ├─ Temporal workflow: trigger_cd → apply HelmRelease → notify_registry
  └─ Returns deployment_id

Step 10: MCP tool polls deployment status (atlan_app_status)
  GET /api/v1/marketplace/apps/deployments/{deployment_id}
  → { status: "PENDING" }
  → { status: "SUCCEEDED" } ← done
     OR
  → { status: "FAILED" } ← agent calls atlan_app_failure() to read details
```

### 6.3 Publish Flow

```
Agent: atlan_app_publish(branch="main", channel="beta")

Similar to deploy, but:
  - target_channel = "beta" instead of "specific"
  - Release created with status = "draft" (requires approval for non-specific channels)
  - No automatic install — tenants pick it up via reconciler after approval

Agent: atlan_app_publish(branch="main", tenants=["tenant-a", "tenant-b"])

  - target_channel = "specific", allowed_tenants = ["tenant-a", "tenant-b"]
  - Release created with status = "active" (auto-approved)
  - Each tenant's reconciler picks it up within 5 minutes
```

### 6.4 The Claude Code Autonomous Loop

This is the core value proposition of the platform:

```
Developer: "Deploy my app to dev-tenant and make sure it works"

Claude Code:
  1. atlan_app_deploy(branch="main")
     → Returns: { build_id: "b-123", github_actions_url: "https://..." }

  2. atlan_app_status(build_id="b-123")           ← poll every 15s
     → { status: "building" }
     → { status: "released", deployment_id: "d-456" }

  3. atlan_app_status(deployment_id="d-456")       ← poll every 10s
     → { status: "PENDING" }
     → { status: "FAILED" }                         ← FAILED

  4. atlan_app_failure(deployment_id="d-456")      ← read stored snapshot
     → {
         failure_reason: "CrashLoopBackOff",
         pod_logs: "ModuleNotFoundError: No module named 'redis'",
         pod_events: "Back-off restarting failed container...",
         captured_at: "2026-02-27T10:30:00Z"
       }

  5. Claude reads logs → "Missing redis dependency"
     → Edits requirements.txt, adds redis
     → git commit + git push

  6. atlan_app_deploy(branch="main")
     → GM sees new commit SHA, triggers new build
     → ... cycle repeats

  7. atlan_app_status(deployment_id="d-789")
     → { status: "SUCCEEDED" }                      ← SUCCESS

  ── Post-deploy health check (automatic) ──────────────────────

  8. atlan_app_workflows(app_id="my-connector", status="failed")
     → {
         failed_workflows: [{
           workflow_type: "ProcessOrderWorkflow",
           failure_message: "connection refused to postgres:5432",
           failed_at: "2026-02-27T11:00:00Z"
         }]
       }

  Claude Code: "The app deployed successfully, but I found 1 failing
                workflow (ProcessOrderWorkflow — connection refused to
                postgres:5432). Want me to debug this?"

  Developer: "Yes"

  9. atlan_app_logs(app_id="my-connector", tail=100)
     → "...psycopg2.OperationalError: could not connect to server..."

  10. Claude reads app-config.yaml → missing postgres dapr component
      → Fixes app-config.yaml, pushes, redeploys
```

---

## 7. Work Stream A: Build & Release Pipeline

**Owner**: Engineer A
**Primary codebase**: Global Marketplace (GM) + `atlanhq/application-sdk` (for reusable build workflow)
**Core question**: "How does code become a deployable artifact?"

### 7.1 Scope

| Component | What to Build |
|-----------|--------------|
| **GM: `builds` table** | New PostgreSQL table tracking build requests (status, commit SHA, image tag, GitHub run ID) |
| **GM: Build API** | `POST /internal/api/v1/builds` — receive build request from LM, check dedup, trigger GitHub Action |
| **GM: GitHub App `workflow_run` handler** | Listen for `workflow_run` completed events from GitHub App webhook. Look up build by `(repo, commit_sha)`, create version + release. |
| **GM: Build status** | `GET /internal/api/v1/builds/{id}` — return current build status for polling |
| **GM: Build logs** | `GET /internal/api/v1/builds/{id}/logs` — fetch GitHub Action logs via GitHub API for failed builds |
| **GM: GitHub App integration** | Trigger `workflow_dispatch`, create GitHub Deployments, create commit status checks, read repo files |
| **GM: Auto version+release** | On successful build, create version (with image + config) and release (targeting tenant/channel) |
| **GM: Commit status checks** | After successful deploy, create commit status (green checkmark) via GitHub App Statuses API |
| **Reusable build workflow** | Add to `atlanhq/application-sdk` — reusable GitHub Actions workflow for building Docker images |
| **LM: Proxy endpoints** | `POST /api/v1/marketplace/builds`, `GET /api/v1/marketplace/builds/{id}`, `GET /api/v1/marketplace/builds/{id}/logs`, `POST /api/v1/marketplace/publish` — proxy to GM with tenant context |
| **LM: Validation API** | Server-side validation of app-manifest.yaml, app-config.yaml, and Dockerfile existence (called before proxying to GM) |

### 7.2 New GM Database Schema

```sql
-- New table: builds
CREATE TABLE builds (
    id              SERIAL PRIMARY KEY,
    public_id       UUID NOT NULL DEFAULT gen_random_uuid(),
    repo            TEXT NOT NULL,
    branch          TEXT NOT NULL,
    commit_sha      TEXT NOT NULL,
    tenant_id       TEXT NOT NULL,           -- requesting tenant
    target_channel  TEXT,                     -- for publish: "beta", "staging", "all"
    allowed_tenants TEXT[],                   -- for publish: specific tenant list
    status          VARCHAR(20) NOT NULL DEFAULT 'pending',
    -- Status lifecycle: pending → building → built → released → failed
    github_run_id   BIGINT,                  -- GitHub Actions run ID
    github_run_url  TEXT,                    -- Full URL to Actions run
    image_tag       TEXT,                    -- Populated on successful build
    version_id      UUID,                    -- FK to versions.public_id (after creation)
    release_id      UUID,                    -- FK to releases.public_id (after creation)
    error_message   TEXT,                    -- Populated on failure
    app_manifest    JSONB,                   -- Snapshot of app-manifest.yaml at build time
    app_config    TEXT,                    -- Snapshot of app-config.yaml at build time
    created_at      TIMESTAMP DEFAULT NOW(),
    updated_at      TIMESTAMP DEFAULT NOW(),

    UNIQUE(commit_sha, tenant_id)            -- Dedup: one build per commit per tenant
);

CREATE INDEX idx_builds_commit_sha ON builds(commit_sha);
CREATE INDEX idx_builds_status ON builds(status);
CREATE INDEX idx_builds_repo ON builds(repo);
```

### 7.3 Build Status Lifecycle

```
pending ──→ building ──→ built ──→ released
   │            │           │
   │            ▼           ▼
   │         failed      failed
   ▼
failed
```

| Status | Meaning |
|--------|---------|
| `pending` | Build request received, about to trigger GitHub Action |
| `building` | GitHub Action running, `github_run_id` populated |
| `built` | Image pushed to registry, `image_tag` populated |
| `released` | Version + release created in GM, `version_id` + `release_id` populated |
| `failed` | Error at any stage, `error_message` populated |

### 7.4 Build Deduplication (Three-Level Check)

Before triggering a new build, GM runs three checks in order. This avoids redundant builds — in most cases, the image won't exist and no action will be running, so GM triggers the action directly.

**Level 1: Check GM's `builds` table**

```sql
SELECT * FROM builds
WHERE commit_sha = $1 AND status = 'released'
LIMIT 1;
```

If a build already exists for this commit SHA with a released version:
- Skip everything — create a new release from the existing `version_id`
- Fastest path, no GitHub API calls needed

**Level 2: Check GitHub Packages (container registry)**

```
GET /orgs/{org}/packages/container/{app_name}/versions
→ Filter by tag: sha-{commit_sha}
```

If a package exists but no GM build record (e.g., image was built outside our pipeline, or build record was lost):
- Skip the build, create version + release from the existing image
- Requires `Packages: read` permission on the GitHub App

**Level 3: Check for running GitHub Action**

```
GET /repos/{owner}/{repo}/actions/runs?head_sha={commit_sha}&status=in_progress
```

If an action is already running for this commit:
- Don't trigger a duplicate — attach to the existing run
- Store the `run_id`, wait for the `workflow_run` webhook event

**If all three checks fail**: Trigger `workflow_dispatch` — this is the normal path for a new commit.

### 7.5 GitHub App Flow

```
GM receives build request
  │
  ├─ Look up GitHub App installation for the repo's org
  ├─ Generate installation access token
  │
  ├─ Read app-manifest.yaml + app-config.yaml from the repo (if not provided in request)
  │   GET /repos/{owner}/{repo}/contents/app-manifest.yaml?ref={commit_sha}
  │   GET /repos/{owner}/{repo}/contents/app-config.yaml?ref={commit_sha}
  │
  ├─ Trigger workflow_dispatch
  │   POST /repos/{owner}/{repo}/actions/workflows/marketplace-build.yml/dispatches
  │   { "ref": "{branch}", "inputs": { "commit_sha": "...", "image_tag": "...", "app_name": "...", "enable_sdr": "..." } }
  │
  ├─ Create GitHub Deployment
  │   POST /repos/{owner}/{repo}/deployments
  │   { "ref": "{commit_sha}", "environment": "{tenant_id}", "auto_merge": false }
  │
  └─ Poll for workflow run (to get run_id)
     GET /repos/{owner}/{repo}/actions/runs?head_sha={commit_sha}
```

**Note**: No callback URL is needed. GM learns the build result via the GitHub App's `workflow_run` webhook event, which is delivered automatically by GitHub when the workflow completes.

### 7.6 Reusable Workflow Contract

The reusable workflow in `atlanhq/application-sdk` receives (see Section 5.2 for full YAML):

| Input | Type | Required | Description |
|-------|------|----------|-------------|
| `commit_sha` | string | Yes | Exact commit to build |
| `image_tag` | string | Yes | Image tag to use (computed by GM, e.g., `abc1234abcd`) |
| `app_name` | string | Yes | App name from app-manifest.yaml (used for image naming) |
| `enable_sdr` | boolean | No (default: false) | If true, also push to DockerHub for Self-Deployed Runtime |

Secrets are **not passed as inputs** — the caller uses `secrets: inherit` and all secrets (`ORG_PAT_GITHUB`, `DOCKER_HUB_PAT_RW`, `SNYK_TOKEN_BU_APPS`) come from `atlanhq` org-level secrets automatically. No new secrets needed.

It performs:
1. `git checkout $commit_sha`
2. Set up Docker Buildx for multi-arch builds (linux/amd64, linux/arm64)
3. Login to GHCR
4. Build + push multi-arch image to GHCR via `atlanhq/.github/actions/secure-build-push-apps` (includes Snyk container scan), tagged with the `image_tag` GM provided
5. If `enable_sdr=true`: Login to DockerHub, re-tag and push with tag `main-{image_tag}`
6. Done — no callback. GM learns the result via the GitHub App `workflow_run` webhook event.

### 7.7 Build Completion: GitHub App Webhook + Poller (Parallel)

The GitHub App `workflow_run` webhook and poller run **in parallel** from the moment a build starts. This is not a fallback — both are always active. The poller uses the database as the coordination point: before hitting the GitHub API, it checks if the builds row has already moved past "building" (meaning the webhook already handled it).

```
                         Build triggered
                              │
                ┌─────────────┴─────────────┐
                ▼                             ▼
         GitHub App webhook            Poller loop (every 30s)
         (workflow_run event)          (active, checks)
                │                             │
                │                      ┌──────┴──────┐
                │                      │ Read builds  │
                │                      │ row from DB  │
                │                      └──────┬──────┘
                │                             │
                │                      status still "building"?
                │                      NO ──→ stop (webhook got it)
                │                      YES ──→ call GitHub Actions API
                │                             │
                │                      action done?
                │                      NO ──→ sleep 30s, loop
                │                      YES ──→ update builds row
                │                             │
          Webhook arrives              ┌──────┴──────┐
          (any time)                   │ success?    │
                │                      │ YES → "built"│
                ▼                      │ NO  → "failed"│
         Update builds row             └─────────────┘
         status = "built"
                │
         Poller sees status
         ≠ "building" → stops
```

**Poller details:**
- **Interval**: 30 seconds
- **Max duration**: 20 minutes (~40 iterations)
- **Check order per iteration**:
  1. `SELECT status FROM builds WHERE public_id = $1` — if not "building", stop
  2. `GET /repos/{owner}/{repo}/actions/runs/{run_id}` — check GitHub
  3. If action completed: update builds row (same logic as webhook handler)
  4. If action still running: sleep 30s, next iteration
- **Timeout**: After 20 minutes with no completion, mark as "failed"
- **Concurrency safety**: Both paths use the same `UPDATE builds SET status = ... WHERE status = 'building'` — the WHERE clause ensures only one path succeeds, the other becomes a no-op

**Why both paths?**
- Webhook is faster (instant notification, no delay)
- Poller is reliable (works even if webhook is lost due to network issues, GM restart, etc.)
- The DB check on each poll iteration means the poller almost never makes a redundant GitHub API call — it stops as soon as it sees the webhook already handled things

### 7.8 Interaction with Existing GM

The build pipeline integrates with existing GM models:

- After build success, create a **Version** using `VersionService.create_with_internal_id()`:
  - `version`: auto-generated (e.g., commit SHA short or timestamp-based)
  - `image`: from builds table (image_tag was computed by GM before triggering)
  - `config`: from `app-config.yaml` (stored in build request)

- Then create a **Release** using `ReleaseService.create_release()`:
  - `target_channel`: "specific" (for `atlan_app_deploy`) or "beta"/"staging"/"all" (for `atlan_app_publish`)
  - `allowed_tenants`: populated for "specific" channel
  - For "specific" channel, release is auto-approved (status="active")
  - For other channels, release starts as "draft" (requires admin approval)

### 7.9 GitHub Commit Status Checks

After a successful deployment, GM creates a **commit status check** on the deployed commit via the GitHub App's Statuses API. This shows a green checkmark on the commit in GitHub's UI.

```
POST /repos/{owner}/{repo}/statuses/{commit_sha}
{
  "state": "success",
  "target_url": "https://{tenant_domain}/marketplace/deployments/{deployment_id}",
  "description": "Deployed to {tenant_id}",
  "context": "marketplace/deploy"
}
```

**When it's created**: After LM confirms deployment is SUCCEEDED, it notifies GM, which creates the commit status.

**What it looks like**: A green checkmark on the commit with the message "Deployed to dev-01" (or whatever the tenant ID is), visible in GitHub's commit history and PR UI.

### 7.10 GitHub Deployment Status Tracking

GM creates **GitHub Deployments** and pushes status updates at every stage of the build/deploy lifecycle. This provides full traceability in GitHub's Deployments UI.

```
Lifecycle of GitHub Deployment statuses:

1. Build requested      → status: "queued"
2. GitHub Action starts → status: "in_progress"
3. Build succeeds       → status: "success" (image built)
4. Deploy starts        → status: "in_progress" (deployment started on tenant)
5. Deploy succeeds      → status: "success" (final)
   OR Deploy fails      → status: "failure"

For publish flow (requires approval):
1. Build requested      → status: "queued"
2. Build succeeds       → status: "pending" (waiting for approval)
3. Admin approves       → status: "in_progress"
4. Tenants pick up      → status: "success"
```

**API calls** (via GitHub App):

```
# Create deployment
POST /repos/{owner}/{repo}/deployments
{ "ref": "{commit_sha}", "environment": "{tenant_id}", "auto_merge": false, "required_contexts": [] }

# Update deployment status
POST /repos/{owner}/{repo}/deployments/{deployment_id}/statuses
{ "state": "success", "description": "Deployed to {tenant_id}" }
```

This means developers can see the full deployment history of any commit directly in GitHub — no need to query our API for that information.

---

## 8. Work Stream B: Deploy, Observe & Recover

**Owner**: Engineer B
**Primary codebase**: Local Marketplace (LM)
**Core question**: "How does a developer know what went wrong and fix it?"

### 8.1 Scope

| Component | What to Build |
|-----------|--------------|
| **LM: Failure snapshot capture** | Capture pod logs + events **inside the HelmRelease polling loop** the instant `Ready=False` is detected — before Flux rollback starts (see Section 8.2 for timing details) |
| **LM: New Atlas attributes** | `atlanAppFailureLogs`, `atlanAppFailureEvents`, `atlanAppFailureReason`, `atlanAppFailureCapturedAt` on AtlanAppDeployment |
| **LM: Live log streaming API** | `GET /api/v1/marketplace/apps/{app_id}/logs` — SSE stream from kubectl |
| **LM: K8s events API** | `GET /api/v1/marketplace/apps/{app_id}/events` — pod events |
| **LM: Workflow query API** | `GET /api/v1/marketplace/apps/{app_id}/workflows` — failed Temporal workflows |
| **LM: Failure details API** | `GET /api/v1/marketplace/apps/deployments/{id}/failure` — stored snapshot |
| **LM: App info API** | `GET /api/v1/marketplace/apps/{app_id}/info` — current app state (installed version, pod status, health) |
| **LM: Check installed API** | `GET /api/v1/marketplace/apps/{app_id}/installed` — check if app is installed and which version |
| **LM: Build logs proxy** | `GET /api/v1/marketplace/builds/{build_id}/logs` — proxy to GM for GitHub Action logs |
| **MCP Server: all `atlan_app_*` tools** | Added to `agent-toolkit-internal` — httpx calls to LM REST APIs. The sole interface for AI agents. |

### 8.2 Failure Snapshot Capture

**The Problem**: Flux detects a crashlooping pod and reverts the HelmRelease to the previous version. By the time anyone checks, the bad pod is gone and there's no evidence of what went wrong.

**The Solution**: The Temporal deployment workflow captures logs and events **inside the polling loop, the moment failure is detected** — before Flux has a chance to rollback.

#### Why Timing Matters: Flux Rollback Sequence

Flux does NOT rollback instantly when it detects failure. The sequence is:

```
Reconciliation cycle 1:
  T+0:    Flux applies new HelmRelease (helm upgrade)
  T+30s:  Pod starts, enters CrashLoopBackOff
  T+60s:  Flux kstatus poller detects terminal failure (CrashLoopBackOff)
  T+60s:  HelmRelease status → Ready=False, reason: "UpgradeFailed"
          ┌─────────────────────────────────────────────────────┐
          │  WINDOW: Failed pods still running.                 │
          │  Rollback has NOT started yet.                      │
          │  This is when we capture the snapshot.              │
          └─────────────────────────────────────────────────────┘
Reconciliation cycle 2 (seconds later):
  T+62s:  Flux starts helm rollback
  T+65s:  Kubernetes terminates failed pods, recreates old ones
  T+70s:  HelmRelease status → Remediated=True, RollbackSucceeded
```

**The window between "status=failed" and "rollback starts" is small (seconds)**, determined by the Flux reconciliation interval. We must capture the snapshot immediately when we detect `Ready=False`, not as a separate step after.

#### Current HelmRelease Remediation Config

Our generated HelmRelease sets `retries: 3`, which means Flux retries before final rollback:

```
Attempt 1: upgrade fails → rollback → retry
Attempt 2: upgrade fails → rollback → retry
Attempt 3: upgrade fails → rollback → retry
Attempt 4: upgrade fails → final rollback (stays at previous version)
```

Each attempt has a window where failed pods exist. Our workflow captures the snapshot on the **first** failure detection.

#### Timeline With Snapshots

```
T+0:    Flux applies new HelmRelease
T+30s:  Pod starts, enters CrashLoopBackOff
T+60s:  Flux sets Ready=False ← our poll loop sees this
T+60s:  IMMEDIATELY capture snapshot (same moment, not a separate step):
          ├─ kubectl logs -n {app}-app --tail=500
          ├─ kubectl get events -n {app}-app --sort-by='.lastTimestamp'
          └─ kubectl describe pod -n {app}-app
T+61s:  Snapshot stored in AtlanAppDeployment entity
T+62s:  Deployment marked as FAILED
T+63s:  Flux starts rollback (next reconciliation cycle)
T+70s:  Failed pods gone — but snapshot is already persisted
```

#### Where the Capture Happens: Inside the Polling Loop

The snapshot must be captured **inside `check_helmrelease_status()`** the moment `Ready=False` is detected, not after the function returns. This eliminates the race with Flux's rollback.

In the `trigger_cd` activity of `AppDeploymentWorkflow` (file: `src/deployment_orchestrator/deployment_orchestrator.py`):

```python
# Pseudocode for enhanced status polling with inline snapshot capture
async def check_helmrelease_status_with_snapshot(
    app_name: str,
    namespace: str,
    timeout_seconds: int = 300,
    poll_interval: int = 5,
) -> Tuple[bool, Optional[str], Optional[FailureSnapshot]]:
    """
    Poll HelmRelease status. On failure detection, IMMEDIATELY capture
    snapshot before returning — the Flux rollback could start any moment.
    """
    start = time.time()
    while time.time() - start < timeout_seconds:
        status = get_helmrelease_conditions()

        if status.ready == "True":
            return True, "HelmRelease is Ready", None

        if status.ready == "False":
            # CRITICAL: Capture snapshot NOW, before Flux rollback starts.
            # The window between Ready=False and rollback is only seconds.
            snapshot = await capture_failure_snapshot(
                app_name=app_name,
                namespace=namespace,
            )
            return False, status.message, snapshot

        await asyncio.sleep(poll_interval)

    # Timeout — still try to capture snapshot (pods may or may not exist)
    snapshot = await capture_failure_snapshot(app_name=app_name, namespace=namespace)
    return False, "Timed out waiting for HelmRelease", snapshot
```

#### Failure Snapshot Structure

```python
class FailureSnapshot:
    pod_logs: str          # Last 500 lines of pod logs
    pod_events: str        # K8s events for the namespace
    pod_describe: str      # kubectl describe output
    failure_reason: str    # CrashLoopBackOff, ImagePullBackOff, OOMKilled, etc.
    captured_at: str       # ISO timestamp
```

### 8.3 New Atlas Attributes

Add to `AtlanAppDeployment` entity type:

| Attribute | Type | Max Size | Purpose |
|-----------|------|----------|---------|
| `atlanAppFailureLogs` | string | ~50KB | Pod logs at time of failure (last 500 lines) |
| `atlanAppFailureEvents` | string | ~10KB | K8s events at time of failure |
| `atlanAppFailureReason` | string | 256 chars | CrashLoopBackOff, ImagePullBackOff, OOMKilled, etc. |
| `atlanAppFailureCapturedAt` | string | 30 chars | ISO timestamp of when snapshot was taken |

**Important**: Follow Atlas typedef rules from CLAUDE.md:
- Attributes are additive and permanent — cannot be removed
- Code must degrade gracefully without the typedef (use `.get("field", "")`)
- Typedef must be added via `atlanhq/models` repo and `typedef-seeder` workflow
- Writes to undefined attributes are silently ignored

### 8.4 Live Log Streaming API

For running apps where the pod is healthy but something is wrong (workflow errors, application bugs, etc.).

#### Endpoint: Stream/Fetch Pod Logs

```
GET /api/v1/marketplace/apps/{app_id}/logs
    ?tail=100                              # Last N lines (default: 100)
    ?since=5m                              # Lines from last 5 minutes
    ?until_time=2026-02-27T10:30:00Z       # For pagination: lines before this timestamp
    ?follow=false                          # SSE stream mode (default: false)
    ?container=main                        # Container name (default: main)
```

**How pagination works** (timestamp-based, not line-number-based):

```
Request 1: GET .../logs?tail=100
  → Returns 100 lines, earliest line has timestamp T1

Request 2: GET .../logs?tail=100&until_time=T1
  → Returns 100 lines before T1

Request 3: GET .../logs?tail=100&until_time=T2
  → Returns 100 lines before T2
  → Continue as needed
```

**Why timestamps instead of line offsets:**
- Pods restart, line numbers reset
- Logs rotate
- Multiple pods may exist during rolling deployments
- Timestamps are stable across all these scenarios

**SSE stream mode** (`?follow=true`):

```
GET .../logs?follow=true&since=1m

Response (text/event-stream):
data: {"line": "2026-02-27T10:30:01Z INFO Starting server", "ts": "..."}
data: {"line": "2026-02-27T10:30:02Z ERROR Connection refused", "ts": "..."}
...
```

LM internally runs: `kubectl logs -n {app}-app {pod} -f --since=1m`

**Tenant isolation**: LM only has kubeconfig for its own tenant's vcluster. No cross-tenant access is possible by design.

#### Endpoint: K8s Events

```
GET /api/v1/marketplace/apps/{app_id}/events
    ?limit=50

Response:
{
  "events": [
    {
      "type": "Warning",
      "reason": "BackOff",
      "message": "Back-off restarting failed container",
      "first_seen": "2026-02-27T10:30:00Z",
      "last_seen": "2026-02-27T10:32:00Z",
      "count": 5,
      "source": "kubelet"
    }
  ]
}
```

LM internally runs: `kubectl get events -n {app}-app --sort-by='.lastTimestamp' -o json`

#### Endpoint: Pod Describe (for debugging startup failures)

```
GET /api/v1/marketplace/apps/{app_id}/describe

Response:
{
  "pod_name": "my-connector-app-xyz-abc",
  "status": "CrashLoopBackOff",
  "conditions": [...],
  "container_statuses": [...],
  "raw": "... full kubectl describe output ..."
}
```

### 8.5 Workflow Query API

For debugging Temporal workflow failures inside the deployed app.

```
GET /api/v1/marketplace/apps/{app_id}/workflows
    ?status=failed
    ?limit=10

Response:
{
  "workflows": [
    {
      "workflow_id": "process-order-123",
      "workflow_type": "ProcessOrderWorkflow",
      "status": "FAILED",
      "failure_message": "activity 'send_email' failed: SMTP connection refused",
      "failed_at": "2026-02-27T10:45:00Z",
      "task_queue": "my-connector-tasks"
    }
  ]
}
```

LM queries Temporal API filtered to the app's task queue. The task queue naming convention must be documented — typically `{app_name}-tasks` or similar.

```
GET /api/v1/marketplace/apps/{app_id}/workflows/{workflow_id}/history
    # Returns Temporal workflow event history for debugging
```

### 8.6 Failure Details API

For reading stored failure snapshots from Atlas (captured before Flux reverted).

```
GET /api/v1/marketplace/apps/deployments/{deployment_id}/failure

Response:
{
  "deployment_id": "d-456",
  "status": "FAILED",
  "failure_reason": "CrashLoopBackOff",
  "pod_logs": "Traceback (most recent call last):\n  File ...\nImportError: No module named 'redis'",
  "pod_events": "Back-off restarting failed container...",
  "captured_at": "2026-02-27T10:30:00Z"
}
```

This reads from Atlas `AtlanAppDeployment` entity's new attributes. It's the **only way** to see why a deployment failed after Flux has reverted the pod.

### 8.7 MCP Server Implementation (Sole Agent Interface)

The MCP tools are added to `atlanhq/agent-toolkit-internal` as a new file `modelcontextprotocol/tools/app.py`, following existing patterns from `tools/search.py` and `tools/assets.py`. There is no CLI — the MCP server is the only interface for AI agents.

**Key difference from existing tools**: The existing tools (search_assets, etc.) use `pyatlan` SDK to talk to Atlas. The new `atlan_app_*` tools use `httpx` to call LM's REST API **via Heracles** (auth proxy). LM has no auth of its own — Heracles validates the JWT/API key and routes requests to LM. All validation (manifest, config, Dockerfile) happens server-side in LM/GM — the MCP tools are thin HTTP clients.

```python
# modelcontextprotocol/tools/app.py
# Follows existing patterns: ToolAnnotations, get_atlan_client(), @redacting_tracer

from fastmcp import ToolAnnotations
from modelcontextprotocol.client import get_atlan_client
import httpx

LM_BASE = "/api/v1/marketplace"


def _get_heracles_client() -> httpx.AsyncClient:
    """Get an authenticated httpx client pointing to Heracles.

    Heracles is a separate auth proxy service that validates JWT/API key
    and routes requests to the tenant's LM instance. LM has no auth of its own.
    """
    client = get_atlan_client()  # Gets JWT from MCP session context
    # heracles_url is the Heracles service URL for this tenant
    # (configured per-tenant, e.g., "https://heracles.mycompany.atlan.com")
    return httpx.AsyncClient(
        base_url=client.heracles_url,
        headers=client.headers,  # Includes Authorization: Bearer <jwt>
    )


@server.tool(
    "atlan_app_deploy",
    annotations=ToolAnnotations(read_only_hint=False),
)
async def atlan_app_deploy(branch: str) -> dict:
    """Build and deploy an app to the authenticated tenant."""
    async with _get_heracles_client() as http:
        resp = await http.post(f"{LM_BASE}/builds", json={"branch": branch, ...})
        return resp.json()


@server.tool(
    "atlan_app_logs",
    annotations=ToolAnnotations(read_only_hint=True),
)
async def atlan_app_logs(
    app_id: str, tail: int = 100, since: str = None, until_time: str = None
) -> dict:
    """Fetch pod logs for a running app on the authenticated tenant."""
    params = {"tail": tail}
    if since:
        params["since"] = since
    if until_time:
        params["until_time"] = until_time
    async with _get_heracles_client() as http:
        resp = await http.get(f"{LM_BASE}/apps/{app_id}/logs", params=params)
        return resp.json()


@server.tool(
    "atlan_app_failure",
    annotations=ToolAnnotations(read_only_hint=True),
)
async def atlan_app_failure(deployment_id: str) -> dict:
    """Get stored failure snapshot (pod logs, events, reason) captured before Flux revert."""
    async with _get_heracles_client() as http:
        resp = await http.get(f"{LM_BASE}/apps/deployments/{deployment_id}/failure")
        return resp.json()

# Same pattern for: atlan_app_status, atlan_app_events, atlan_app_workflows,
#   atlan_app_build_logs, atlan_app_info, atlan_app_check_installed, atlan_app_publish
```

---

## 9. MCP Server Specification

### 9.1 Tool Definitions

These tools are added to the existing `agent-toolkit-internal` FastMCP server. Auth is handled by the MCP server's existing JWT/API key mechanism — **no `atlan_app_auth` tool is needed**. There is no CLI — these MCP tools are the sole interface for AI agents.

```json
{
  "tools": [
    {
      "name": "atlan_app_init",
      "description": "Initialize a new Atlan app in the current repo. Creates Dockerfile, app-manifest.yaml, app-config.yaml, and GitHub workflow (.github/workflows/marketplace-build.yml).",
      "parameters": {
        "app_name": { "type": "string" },
        "app_type": { "type": "string" },
        "description": { "type": "string" }
      }
    },
    {
      "name": "atlan_app_deploy",
      "description": "Build and deploy an app to the authenticated tenant. Validates app-manifest.yaml and app-config.yaml first. Returns build_id for tracking.",
      "parameters": {
        "branch": { "type": "string", "required": true }
      }
    },
    {
      "name": "atlan_app_publish",
      "description": "Publish an app release to multiple tenants or a channel. Only tool that accepts tenant/channel targeting.",
      "parameters": {
        "branch": { "type": "string", "required": true },
        "channel": { "type": "string", "enum": ["beta", "staging", "all"] },
        "tenants": { "type": "array", "items": { "type": "string" } }
      }
    },
    {
      "name": "atlan_app_status",
      "description": "Check build or deployment status on the authenticated tenant.",
      "parameters": {
        "build_id": { "type": "string" },
        "deployment_id": { "type": "string" }
      }
    },
    {
      "name": "atlan_app_build_logs",
      "description": "Fetch GitHub Action build logs for a build. Useful for diagnosing build failures (Dockerfile errors, dependency issues, test failures).",
      "parameters": {
        "build_id": { "type": "string", "required": true }
      }
    },
    {
      "name": "atlan_app_failure",
      "description": "Get stored failure snapshot for a failed deployment (pod logs, events, reason captured before Flux revert).",
      "parameters": {
        "deployment_id": { "type": "string", "required": true }
      }
    },
    {
      "name": "atlan_app_logs",
      "description": "Fetch or stream pod logs for a running app on the authenticated tenant.",
      "parameters": {
        "app_id": { "type": "string", "required": true },
        "tail": { "type": "integer", "default": 100 },
        "follow": { "type": "boolean", "default": false },
        "since": { "type": "string", "description": "e.g., '5m' or ISO timestamp" },
        "until_time": { "type": "string", "description": "ISO timestamp for pagination" }
      }
    },
    {
      "name": "atlan_app_events",
      "description": "Get Kubernetes events for an app's namespace on the authenticated tenant.",
      "parameters": {
        "app_id": { "type": "string", "required": true }
      }
    },
    {
      "name": "atlan_app_workflows",
      "description": "Query Temporal workflows for a running app (e.g., find failed workflows) on the authenticated tenant.",
      "parameters": {
        "app_id": { "type": "string", "required": true },
        "status": { "type": "string", "enum": ["failed", "running", "completed"] }
      }
    },
    {
      "name": "atlan_app_info",
      "description": "Get current state of an app on the authenticated tenant — installed version, pod status, health check.",
      "parameters": {
        "app_id": { "type": "string", "required": true }
      }
    },
    {
      "name": "atlan_app_check_installed",
      "description": "Check if an app is installed on the authenticated tenant and which version.",
      "parameters": {
        "app_id": { "type": "string", "required": true }
      }
    }
  ]
}
```

**Tenant scoping rule for all MCP tools**: Every tool except `atlan_app_publish` operates on the authenticated tenant only. There is no `tenant` parameter. The MCP server's JWT/API key identifies the tenant. All tools make httpx calls to the tenant's **Heracles** service (auth proxy), which routes to LM.

**Auth flow**: MCP tool → httpx → Heracles (validates JWT) → LM (no auth of its own) → GM (internal).

**Validation**: The `atlan_app_deploy` and `atlan_app_publish` tools do NOT validate locally. They send repo + branch + commit SHA to LM, which validates `app-manifest.yaml`, `app-config.yaml`, and `Dockerfile` existence server-side (via GitHub API or from the request payload). Validation errors are returned as structured error responses.

---

## 10. API Contracts

### 10.1 New LM Endpoints (Proxy to GM)

```
POST /api/v1/marketplace/builds
  → Proxies to GM: POST /internal/api/v1/builds
  → Adds tenant context from auth (no tenant in request body)

GET /api/v1/marketplace/builds/{build_id}
  → Proxies to GM: GET /internal/api/v1/builds/{build_id}

GET /api/v1/marketplace/builds/{build_id}/logs
  → Proxies to GM: GET /internal/api/v1/builds/{build_id}/logs
  → Returns GitHub Action build output (for diagnosing build failures)

POST /api/v1/marketplace/publish
  → Proxies to GM: POST /internal/api/v1/builds (with channel/tenants targeting)
```

### 10.2 New LM Endpoints (Observability)

All observability endpoints use the authenticated tenant — no `{tenant}` in the URL path.

```
GET /api/v1/marketplace/apps/{app_id}/logs
  ?tail=100&since=5m&until_time=<ISO>&follow=false&container=main
  → kubectl logs (streaming or paginated)

GET /api/v1/marketplace/apps/{app_id}/events
  ?limit=50
  → kubectl get events

GET /api/v1/marketplace/apps/{app_id}/describe
  → kubectl describe pod

GET /api/v1/marketplace/apps/{app_id}/workflows
  ?status=failed&limit=10
  → Temporal API query

GET /api/v1/marketplace/apps/deployments/{deployment_id}/failure
  → Atlas query for stored failure snapshot

GET /api/v1/marketplace/apps/{app_id}/info
  → Returns: installed version, pod status, pod count, health
  → Combines Atlas query (installed version) + kubectl (pod status)

GET /api/v1/marketplace/apps/{app_id}/installed
  → Returns: { installed: true/false, version_id: "...", version_text: "..." }
  → Lightweight check against Atlas AtlanAppInstalled entity
```

### 10.3 New GM Endpoints (Internal, called by LM only)

```
POST /internal/api/v1/builds
  Request:
  {
    "repo": "atlanhq/my-connector",
    "branch": "main",
    "commit_sha": "abc123",
    "tenant_id": "mycompany",
    "target_channel": "specific",           # or "beta"/"staging"/"all"
    "allowed_tenants": ["mycompany"],        # for "specific" channel
    "app_manifest": { "name": "...", ... },  # from app-manifest.yaml
    "app_config": "replicaCount: 2\n..."   # from app-config.yaml (raw YAML)
  }
  Response:
  {
    "build_id": "019abc...",
    "status": "pending",
    "github_actions_url": null               # populated after trigger
  }

GET /internal/api/v1/builds/{build_id}
  Response:
  {
    "build_id": "019abc...",
    "status": "building",                    # pending/building/built/released/failed
    "github_actions_url": "https://github.com/...",
    "image_tag": null,                       # populated when built
    "version_id": null,                      # populated when released
    "release_id": null,                      # populated when released
    "error_message": null,                   # populated on failure
    "created_at": "2026-02-27T10:00:00Z"
  }

POST /internal/api/v1/builds/{build_id}/logs
  Response:
  {
    "build_id": "019abc...",
    "logs": "Step 1/12: FROM python:3.11...\n..."  # GitHub Action log output
  }
```

### 10.4 GM GitHub App Webhook Handler

GM receives `workflow_run` events from the GitHub App webhook. No custom public endpoint is needed — the webhook URL is configured in the GitHub App settings and is secured by GitHub's built-in `X-Hub-Signature-256` verification.

```
GitHub App webhook event: workflow_run (action: "completed")
  Payload includes:
  {
    "workflow_run": {
      "head_sha": "abc1234...",
      "conclusion": "success",          // or "failure"
      "repository": { "full_name": "atlanhq/my-connector" }
    }
  }

  GM handler:
  1. Verify X-Hub-Signature-256 (GitHub App's webhook secret, configured in App settings)
  2. Filter: workflow name == "Marketplace Build" AND action == "completed"
  3. Look up builds row by (repo, commit_sha) — image_tag is already there
  4. Update status, create version + release
```

---

## 11. Data Models & Storage

### 11.1 Storage Summary

| Data | Where | Why |
|------|-------|-----|
| Build tracking (build_id, status, commit SHA, image) | GM PostgreSQL (`builds` table) | GM owns the build pipeline, needs fast queries |
| App/Version/Release metadata | GM PostgreSQL (existing tables) | Already there, unchanged |
| Deployment tracking (status, operation) | Atlas `AtlanAppDeployment` (existing) | LM already uses this, unchanged |
| Failure snapshots (pod logs, events, reason) | Atlas `AtlanAppDeployment` (new attributes) | Tied to deployment record, survives pod termination |
| Live pod logs | Not stored — streamed from kubectl | Real-time data, no need to persist |
| Live K8s events | Not stored — queried from kubectl | Real-time data, no need to persist |
| App workflow failures | Not stored — queried from Temporal API | Real-time data, no need to persist |
| MCP auth credentials | Managed by `agent-toolkit-internal` (JWT/API key from MCP session) | In-memory, per-session |

### 11.2 What's New vs What's Modified

| Item | Status |
|------|--------|
| GM `builds` table | **New** |
| GM `marketplace_apps` table | Unchanged |
| GM `versions` table | Unchanged (build pipeline creates versions using existing schema) |
| GM `releases` table | Unchanged (build pipeline creates releases using existing schema) |
| Atlas `AtlanAppDeployment` entity | **Modified** — 4 new attributes for failure snapshots |
| Atlas `AtlanAppInstalled` entity | Unchanged |

---

## 12. Failure Handling & Edge Cases

### 12.1 Build Failures

| Failure | How It's Handled |
|---------|-----------------|
| GitHub Action fails (build error) | Callback POSTs `status: "failure"`. GM updates builds row. MCP tool returns error. Claude can use `atlan_app_build_logs` to fetch full GitHub Action output and diagnose the issue. |
| GitHub Action times out | Poller detects the action's final status from GitHub API and marks build as failed. If both webhook and poller miss it, 20-minute poller timeout catches it. |
| Callback never arrives (network issue, GM restart) | Poller picks it up on the next 30s iteration — checks GitHub Actions API directly. No data loss. |
| Duplicate build request (same commit) | GM deduplicates — returns existing build if commit SHA matches. |
| Repo has no marketplace-build.yml | GM's workflow_dispatch will fail. Error returned to MCP tool. `atlan_app_init` prevents this by scaffolding the workflow file. |
| Config validation fails | LM validates `app-manifest.yaml` and `app-config.yaml` server-side before proxying to GM. Structured error returned — no build triggered. |

### 12.2 Deployment Failures

| Failure | How It's Handled |
|---------|-----------------|
| Pod CrashLoopBackOff | Temporal workflow captures snapshot (logs, events, describe). Stores in Atlas. Flux reverts. Snapshot survives. |
| ImagePullBackOff | Same snapshot capture. Likely wrong image tag or registry auth issue. |
| OOMKilled | Same snapshot capture. Developer needs to increase memory in app-config.yaml. |
| HelmRelease stuck in "progressing" | Temporal workflow timeout (configured in `config.KUBECTL_WAIT_TIMEOUT_SECONDS`). |
| Flux reverts before snapshot is captured | Mitigated: snapshot capture happens **inside the polling loop** the instant `Ready=False` is detected (see Section 8.2). The window between Flux setting `Ready=False` and starting rollback is typically seconds (one reconciliation cycle). By capturing inline rather than as a separate step, we beat the rollback. If the rare case occurs where Flux rolls back faster, `kubectl logs` will fail gracefully and we store whatever we captured (events usually survive longer than pods). |

### 12.3 Log Streaming Edge Cases

| Case | How It's Handled |
|------|-----------------|
| Pod doesn't exist (not yet created) | Return 404 with message "Pod not found. Deployment may still be in progress." |
| Multiple pods (rolling update) | Return logs from the latest pod by default. Accept `pod` parameter for specific pod. |
| Pod has multiple containers | Default to `main` container. Accept `container` parameter. |
| Logs too large | `tail` parameter limits output. Timestamp pagination prevents fetching everything at once. |
| Pod restarted (previous logs lost) | kubectl has `--previous` flag for previous container's logs. Expose as `previous` parameter. |

---

## 13. Security & Access Control

### 13.1 Auth Flow

```
MCP Agent ──(JWT / API key)──→ Heracles ──(authenticated, routed)──→ LM ──(trusted internal)──→ GM
```

- **MCP → Heracles**: All `atlan_app_*` tools make httpx calls to **Heracles** (a separate auth proxy service per tenant). Heracles validates the JWT/API key from the MCP session and routes the request to the tenant's LM instance. LM has no auth of its own.
- **Heracles → LM**: Trusted internal communication. Heracles has already validated auth — LM receives the request with tenant context.
- **LM → GM**: Internal trusted communication. LM passes `x-atlan-tenant` header. No separate auth — GM is not externally accessible.
- **GM → GitHub**: GitHub App authentication (installation access tokens). Managed by GM.

### 13.2 GitHub App Webhook Security (GM)

GM does **not** expose a custom public endpoint for build callbacks. Instead, it receives standard GitHub App `workflow_run` webhook events, which are signed by GitHub.

**Security measures:**
- **GitHub's built-in `X-Hub-Signature-256`**: Every webhook delivery is signed by GitHub using the App's webhook secret (configured when creating the GitHub App). No custom HMAC or org-level secret needed.
- **Build row validation**: GM looks up the build by `(repo, commit_sha)`. If no matching build exists, the event is ignored.
- **Workflow name filter**: Only `workflow_run` events where `workflow.name == "Marketplace Build"` are processed. All other events are ignored.
- **Idempotency**: Processing the same event twice is safe — GM checks if the build is already in a terminal state.

```python
# GitHub App webhook verification (pseudocode)
def verify_github_webhook(request):
    signature = request.headers.get("X-Hub-Signature-256")
    expected = "sha256=" + hmac.new(
        github_app_webhook_secret, request.body, hashlib.sha256
    ).hexdigest()
    if not hmac.compare_digest(signature, expected):
        raise HTTPException(403, "Invalid signature")
```

### 13.3 Tenant Scoping Rules

- **No `tenant` parameter on any MCP tool except `atlan_app_publish`**
- `atlan_app_deploy`, `atlan_app_logs`, `atlan_app_status`, `atlan_app_events`, `atlan_app_workflows`, `atlan_app_info`, `atlan_app_check_installed`, `atlan_app_build_logs` — all use the authenticated tenant only
- `atlan_app_publish` accepts `tenants` or `channel` for cross-tenant targeting
- Enforced at the MCP tool level (no tenant param) and at the LM API level (tenant extracted from auth context)

### 13.4 Tenant Isolation

- LM is **per-tenant**: each tenant has its own LM instance with its own kubeconfig.
- LM can only access its own tenant's vcluster — no cross-tenant access is architecturally possible.
- Atlas queries are scoped by `x-atlan-tenant` header.
- Log streaming, events, describe — all scoped to the tenant's namespace automatically.

### 13.5 What We Don't Need to Build

- **CLI**: No CLI needed. The MCP server is the sole interface for AI agents. Developers can call LM APIs directly if needed.
- **Cross-tenant access control**: Not possible by design (LM is per-tenant).
- **Role-based access for logs**: Anyone authenticated to the tenant can read logs. This matches current behavior (anyone with vcluster access can read logs).
- **API key rotation**: Out of scope for V2. Use existing tenant auth infrastructure.

---

## 14. Migrating Existing Apps

All existing Atlan apps that currently build images manually (or via ad-hoc CI) must migrate to the new build pipeline. This is a prerequisite for any app to use `atlan_app_deploy`, be managed by AI agents, or benefit from the observability features.

### 14.1 What Needs to Change Per App

Each app repo needs three files added:

| File | Purpose | Who Creates It |
|------|---------|---------------|
| `app-manifest.yaml` | App metadata (name, type, description, tags) | Developer (one-time, via `atlan_app_init` MCP tool or manually) |
| `app-config.yaml` | Deployment config (replicas, env, dapr, resources) | Developer (migrate from existing Helm values / config) |
| `.github/workflows/marketplace-build.yml` | Thin wrapper calling reusable workflow from `atlanhq/application-sdk` | `atlan_app_init` scaffolds this |

**What does NOT change:**
- The app's source code, Dockerfile, tests — all unchanged
- Existing manual deployment still works during migration (both paths coexist)
- The reconciler continues to work — it just picks up releases created by the new pipeline

### 14.2 Migration Steps Per App

```
1. Run atlan_app_init() via MCP (or manually create the three files)
2. Fill in app-manifest.yaml (name, type, description)
3. Migrate existing deployment config to app-config.yaml
   - If the app already has Helm values, translate them
   - If the app has custom environment variables, add to env: section
   - If the app uses Dapr components, add to dapr: section
4. Commit + push (the GitHub workflow file is now in the repo)
5. Run atlan_app_deploy(branch="main") to verify the pipeline works
6. Done — all future builds go through the pipeline
```

### 14.3 Migration Order

Recommended migration order:

| Phase | Apps | Rationale |
|-------|------|-----------|
| **Phase 1: Pilot** | 1-2 low-risk internal apps | Validate the pipeline end-to-end, catch issues |
| **Phase 2: New apps** | All newly created apps | `atlan_app_init` makes this the default for new development |
| **Phase 3: Active apps** | Apps with frequent releases | Biggest productivity gain |
| **Phase 4: Long-tail** | Stable apps with rare changes | Low urgency, migrate opportunistically |

### 14.4 Coexistence During Migration

During the migration period, both build paths work:

```
OLD PATH (manual):
  Developer builds image → pushes to registry → creates version/release in GM admin UI
  → Reconciler picks up release → installs on tenants

NEW PATH (automated):
  Agent calls atlan_app_deploy() → GM triggers GitHub Action → image built → version/release auto-created
  → LM installs on tenant

Both paths produce the same output: a version + release in GM.
The reconciler and install flow don't care how the version was created.
```

No big-bang migration required — apps can migrate one at a time.

### 14.5 What Happens to Apps That Don't Migrate

- They continue to work as-is (manual builds, manual releases)
- They **cannot** use `atlan_app_deploy`, `atlan_app_build_logs`, or be managed by AI agents
- They still benefit from Stream B features (logs, events, workflows, failure snapshots) because those depend on the app being installed, not how it was built

---

## 15. Open Questions

| # | Question | Impact | Owner | Status |
|---|----------|--------|-------|--------|
| 1 | ~~Where should the CLI package live?~~ | ~~Distribution~~ | ~~Both~~ | **Resolved**: No CLI. MCP server is the sole interface. |
| 2 | ~~Where should the MCP server package live?~~ | ~~Distribution~~ | ~~Stream B~~ | **Resolved**: Extend existing `atlanhq/agent-toolkit-internal` FastMCP server. New tools added alongside existing catalog tools. |
| 3 | How are API keys created and managed? New admin UI feature? | Auth flow | Stream A | Open |
| 4 | ~~What container registry should builds push to? GHCR, ECR, or tenant-specific?~~ | ~~Build pipeline~~ | ~~Stream A~~ | **Resolved**: GHCR always (`ghcr.io/atlanhq/{app}-main`). Also DockerHub (`atlanhq/{app}`) if `enable_sdr: true` in app-manifest.yaml (for Self-Deployed Runtime). Tags: `<sha7>abcd` (no `latest` — every deploy is pinned to a specific commit). |
| 5 | ~~Should deploy auto-install after release?~~ | ~~UX~~ | ~~Both~~ | **Resolved**: Yes, `atlan_app_deploy` auto-installs. No separate install tool. |
| 6 | How do we handle the GitHub App installation across multiple orgs (if repos are not all under `atlanhq`)? For partner repos, plan is a centralized `atlanhq/marketplace-builder` that clones partner code and builds on their behalf (keeps secrets within `atlanhq`). | GitHub integration | Stream A | Future |
| 7 | What's the Temporal task queue naming convention for apps, so we can query workflow failures? | Workflow query | Stream B | Open |
| 8 | Atlas attribute size limits — will 50KB be enough for pod logs? Should we truncate more aggressively? | Snapshot storage | Stream B | Open |
| 9 | Should the failure snapshot include `kubectl describe` output, or is logs + events sufficient? | Snapshot content | Stream B | Open |
| 10 | Should `atlan_app_publish(channel="all")` require a separate approval step, or should it go through the existing GM admin UI approval? | Publish workflow | Stream A | Open |
| 11 | ~~What is the public domain for GM's webhook endpoint?~~ | ~~Webhook routing~~ | ~~Stream A~~ | **Resolved**: No custom public webhook endpoint needed. GM receives `workflow_run` events via the GitHub App's webhook (configured in App settings). |
| 12 | ~~How should the `WEBHOOK_SECRET` be rotated?~~ | ~~Security~~ | ~~Stream A~~ | **Resolved**: No custom webhook secret needed. GM uses the GitHub App's built-in `workflow_run` webhook, signed by GitHub with the App's webhook secret. |
| 13 | Should GM notify LM when a deploy succeeds (for commit status creation), or should LM proactively notify GM? | Commit status flow | Both | Open |

---

## Appendix A: Work Stream Dependencies

```
                Stream A (Build & Release)
                ─────────────────────────
                GM builds table
                GM build logs API (GitHub API integration)
                GitHub App setup (Actions, Deployments, Statuses)
                Build trigger + GitHub App workflow_run webhook
                Auto version+release creation
                Commit status checks (green checkmark on deploy success)
                GitHub Deployment status tracking
                LM proxy endpoints ◄────────────── shared interface
                LM validation API (manifest, config, Dockerfile)
                                │
                                │  Contract: "A release exists in GM
                                │   with version_id, image, config,
                                │   targeting a specific tenant"
                                │
                                ▼
                Stream B (Deploy, Observe & Recover)
                ────────────────────────────────────
                Failure snapshot capture (Temporal)
                New Atlas attributes
                Live logs/events/describe APIs
                Workflow query API
                Failure details API
                App info + check installed APIs
                Build logs proxy (LM → GM)
                MCP server: all atlan_app_* tools (agent-toolkit-internal)
```

**Integration point**: Stream A produces releases. Stream B consumes them through the existing install flow (which is already built). They can develop in parallel — Stream B can test with manually created releases while Stream A builds the automated pipeline.

**Commit status flow**: When LM confirms a deployment is SUCCEEDED, it notifies GM (or GM polls), and GM creates the commit status check on GitHub. This is a cross-stream integration point — Stream A implements the GitHub API call, Stream B triggers it after successful deployment.

## Appendix B: Glossary

| Term | Meaning |
|------|---------|
| **LM** | Local Marketplace — per-tenant service managing app installations |
| **GM** | Global Marketplace — cross-tenant service managing app catalog, versions, releases |
| **Heracles** | Auth proxy service (per-tenant) — validates JWT/API key and routes requests to LM. LM has no auth of its own. |
| **SDR** | Self-Deployed Runtime — apps that customers deploy on their own infrastructure (images pushed to DockerHub for public access) |
| **Build** | The process of creating a Docker image from source code |
| **Version** | A specific build artifact (image + config) in GM |
| **Release** | A version made available to specific tenants/channels in GM |
| **Deployment** | The process of installing a release on a tenant (HelmRelease + Flux) |
| **MCP** | Model Context Protocol — standard for exposing tools to AI models |
| **Failure Snapshot** | Pod logs + events captured before Flux reverts a failing deployment |
| **vcluster** | Virtual Kubernetes cluster, one per tenant |
| **Flux** | GitOps tool that reconciles HelmReleases on the cluster |
| **HelmRelease** | Kubernetes CRD that Flux uses to deploy Helm charts |
| **Temporal** | Workflow orchestration platform used for deployment workflows |
| **Atlas** | Atlan's metadata API (Elasticsearch-backed) used for deployment/app tracking |
