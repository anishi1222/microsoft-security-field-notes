# Copilot instructions for this repository

## Repository scope
- This repository is a Microsoft Security "field notes" collection. The only runnable solution currently stored here is `vuln-notification/`.
- Keep documentation layered as intended:
  - Root `README.md`: repository-level scope and catalog.
  - `vuln-notification/README.md`: architecture, setup, deployment, and test flow.
  - `vuln-notification/function-app/RUNBOOK.md` and `SENDER_GUIDE.md`: operational runbook and API caller details.

## Build, test, and lint commands
Run from repository root unless noted.

| Task | Command | Notes |
|---|---|---|
| Install function dependencies | `cd vuln-notification/function-app && python -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt` | On PowerShell, activate with `.\.venv\Scripts\Activate.ps1`. |
| Deploy infrastructure (Bicep) | `cd vuln-notification && az deployment group create --name vuln-notify-infra --resource-group vuln-notify-rg --template-file azuredeploy.bicep --parameters @azuredeploy.parameters.json` | Provisions Function App, Key Vault, App Insights, Log Analytics, and RBAC wiring. |
| Publish function code (remote build) | `cd vuln-notification/function-app && func azure functionapp publish <FUNCTION_APP_NAME> --python --build remote` | This is the project’s build/deploy path for the Python function code. |
| Run one notify E2E scenario (single test run) | `pwsh ./vuln-notification/function-app/Test-VulnNotify.ps1 -FunctionAppName "<FUNCTION_APP_NAME>" -ApiKey "<API_KEY>" -UserAccessToken "<TOKEN>" -Upns "analyst01@contoso.com","owner01@contoso.com"` | Exercises `/api/notify` without Planner task creation. |
| Run one Planner E2E scenario | `pwsh ./vuln-notification/function-app/Test-VulnNotify.ps1 -FunctionAppName "<FUNCTION_APP_NAME>" -ApiKey "<API_KEY>" -UserAccessToken "<TOKEN>" -Upns "analyst01@contoso.com","owner01@contoso.com","manager01@contoso.com" -CreatePlannerTask -PlannerPlanId "<PLAN_ID>" -PlannerBucketId "<BUCKET_ID>"` | Exercises optional Planner integration. |

No repository-level lint command or unit-test framework configuration is currently checked in.

## High-level architecture
1. `vuln-notification/azuredeploy.bicep` provisions Azure resources: Storage, Log Analytics, Application Insights, Linux Consumption plan, Python 3.11 Function App, Key Vault, and a Key Vault Secrets User role assignment for the Function’s system-assigned managed identity.
2. The Function is implemented in `vuln-notification/function-app/function_app.py` as `POST /api/notify`, with `http_auth_level=ANONYMOUS` and explicit app-level auth checks.
3. Call flow:
   - Caller sends `Authorization: Bearer <token>` and `x-api-key`.
   - Function validates API key, parses `upn/upns`, resolves users via Microsoft Graph `/users`.
   - If `chat_id` is absent, Function creates a group chat via `/chats`.
   - Function posts an Adaptive Card message to `/chats/{id}/messages`.
   - If Planner is enabled, Function creates `/planner/tasks` and patches task details.
4. Authentication flow supports two token paths:
   - Graph-audience token can be used directly.
   - `access_as_user` API token is exchanged via OBO (`msal.ConfidentialClientApplication.acquire_token_on_behalf_of`) to get a Graph delegated token.

## Key codebase conventions
- Key Vault secret names use hyphens (`TENANT-ID`, `CLIENT-ID`, `CLIENT-SECRET`, `API-KEY`), while runtime environment variable names use underscores (`TENANT_ID`, `CLIENT_ID`, `CLIENT_SECRET`, `API_KEY`). Keep this mapping unchanged.
- `x-api-key` is mandatory even when a valid Bearer token is provided.
- `upn`, `upns` (array), and comma-separated `upns` are all accepted; values are normalized to lowercase, trimmed, and deduplicated before Graph calls.
- If `chat_id` is not provided, at least 2 UPNs are required; otherwise the API returns HTTP 400.
- Planner enablement is treated as true when either `planner.enabled=true` or `planner_plan_id` is present.
- Planner assignee precedence is fixed: `planner.assignee_upn` > `planner.assignee_upns` > all resolved target users.
- Planner failure is intentionally non-fatal to chat delivery: API returns HTTP 207 with `planner_error` while keeping message send status as `"sent"`.
- User-facing docs and many runtime/error messages are Japanese; preserve existing terminology and language tone when updating docs/messages.
