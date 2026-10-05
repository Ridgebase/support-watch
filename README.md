# Support Watch

A one-page status board for clients' Power Automate cloud flows, in the shape of the Koena health panel:
status, today's success rate, last run per client, a 7-day table, then every flow with its last status.

Live page: https://gentle-beach-054c0680f.4.azurestaticapps.net/ (rebuilt every 10 minutes by the GitHub Actions workflow and
published to **Azure Static Web Apps**, free tier, `swa-support-watch` in `rg-support-watch`). It requires a Microsoft
sign-in and the `reader` role, which only invited addresses hold: `az staticwebapp users invite --subscription "Microsoft
Azure Sponsorship #1" -n swa-support-watch --authentication-provider AAD --user-details <email> --role reader --domain
gentle-beach-054c0680f.4.azurestaticapps.net --invitation-expiration-in-hours 168` prints a one-time invitation link to send
to the colleague (free tier: up to 25 users). The deploy token lives in the `AZURE_STATIC_WEB_APPS_API_TOKEN` secret.

## Layout

- `scripts/` — `collect.ps1`, `build-dashboard.ps1`, `dashboard.template.html`, `notify.ps1`, `get-refresh-token.ps1`, and the
  local-only `flow-runs.ps1` (gitignored).
- `state/` — `alerts.json` and `last-run.txt`, committed by the workflow.
- `out/` — everything generated (CSVs, `site/`, `run.log`), gitignored.
- `azure-function/` — the Canada Central collector for SEMO.
- `.github/workflows/watch.yml` — the cloud job.

## How it runs

- `collect.ps1` signs in to each client tenant with a **refresh token**, reads flows and their runs for the
  configured environments through the Flow REST API, and writes `out/flow-runs.csv`.
- `build-dashboard.ps1` aggregates that CSV into `out/site/data.json` (per-flow and per-day totals, failed runs; ~40 KB
  instead of every run) and renders `out/site/index.html` from `dashboard.template.html`.
- The same run also collects, per client, the last refresh of the Power BI models listed under `PowerBI` in `CLIENTS_JSON`
  (`out/powerbi.csv`, Power BI tab) and, for every listed environment, the canvas apps and connections
  (`out/powerapps.csv`, `out/connections.csv`, Power Apps tab; connections only those owned by the signed-in integration
  account, other users' personal connections are not ours to watch): a connection whose status is not Connected and an app whose
  owner account is disabled or deleted in Entra are red and counted in the tab's badge. With a Power Platform admin role the
  whole environment is listed; otherwise only what the signed-in account can see.
- `.github/workflows/watch.yml` runs both every 10 minutes. GitHub throttles its own `schedule` trigger (gaps of ~30 min
  were observed), so the 10-minute cadence comes from a free cron-job.org job that POSTs to the workflow's
  `dispatches` API with a fine-grained token (repo `support-watch`, permission Actions read/write, approved by an
  org owner, **expires after one year**); GitHub's cron stays as a 30-minute fallback. A client whose sign-in is refused keeps its rows from
  the live page (and goes STALE on the page after an hour); the job only fails when no client at all could be collected.

**Known limit:** Seguin Morris (SEMO) has a Conditional Access policy that blocks sign-ins from outside Canada, so
GitHub's US runners are refused (AADSTS53003). SEMO is therefore collected by `azure-function/`, a PowerShell timer
function in **Canada Central** (Ridgebase subscription, resource group `rg-support-watch`, app `func-support-watch-semo`),
every 10 minutes: it fetches `collect.ps1`, `build-dashboard.ps1` and the template from this repo's `main` at each run
(no redeploy for script changes), collects SEMO, and publishes `site/data.json` to an unlisted gist; the cloud job
reads that gist for any client it cannot sign in to. Its settings: `CLIENTS_JSON_B64` (CLIENTS_JSON base64-encoded, SEMO only, with `FlowDays` and
`PowerBI`), `RT_SEMO`, `GIST_ID`, `GIST_TOKEN`; `azure-function/set-secrets.ps1` copies the secret ones from the PC that
holds them. Deploy with `func azure functionapp publish func-support-watch-semo --powershell` from `azure-function/`
(zip deploy through `az` returned Bad Request on this Linux consumption app; the runtime is `PowerShell|7.4`, the
7.6 image would not start). The local Windows task (`flow-runs.ps1`, same role, gitignored) is the fallback.

All client-specific values live in GitHub secrets, nothing in this repo:

| Secret          | Content                                                                                   |
|-----------------|-------------------------------------------------------------------------------------------|
| `CLIENTS_JSON`  | `[{"Name":"X","Tenant":"x.com","Environments":["Env display name", ...]}, ...]`            |
| `RT_<NAME>`     | one per client, the refresh token written by `get-refresh-token.ps1`                       |
| `CARRY_URL`     | raw URL of the gist where the laptop collector publishes its `data.json` (see below)              |
| `SMTP_USER`     | sending account and From address (a Google Workspace user with an app password)            |
| `SMTP_PASSWORD` | its app password                                                                           |
| `MAIL_TO`       | recipient(s), comma-separated                                                              |
| `SMTP_HOST`     | optional, default `smtp.gmail.com`; port 587 with STARTTLS                                 |

## Email alerts

`notify.ps1` runs after each deploy. It emails one message per run listing the flows whose latest run has **newly**
failed (a flow that keeps failing is announced once, until it recovers), and one weekly recap on Monday after 07:00
Eastern with the last 7 days' totals per client and every flow that failed in the week. No recap on Monday morning =
the job itself is broken. `gh workflow run watch.yml -f digest=true` sends a sample recap right away.
`alerts.json` (committed by the workflow) remembers what was already announced.

Mail is sent over SMTP from a team member's Google Workspace account with an app password: Ridgebase's mail is
Google Workspace, so there is no Exchange mailbox for Microsoft Graph to send as, and the Mailgun account the
domain's SPF record authorises is not accessible to the team. If it becomes accessible, point `SMTP_HOST` at
`smtp.mailgun.org` with a Mailgun SMTP credential; nothing else changes.

Test locally without sending: `.
otify.ps1 -DryRun` prints the emails and the state it would save.

## Why refresh tokens

The flow-owner accounts enforce MFA, so no password can sign in unattended. A device-code sign-in done once
by a human yields a refresh token that any machine can use; it renews itself on each use and lives about
90 days of continuous use. When a tenant revokes it the workflow fails: run

    .\get-refresh-token.ps1 -Tenant <tenant domain> -Out "$HOME\rt-<NAME>.txt"
    gh secret set RT_<NAME> --repo Ridgebase/support-watch < "$HOME\rt-<NAME>.txt"

## Local fallback

`flow-runs.ps1` (git-ignored, Windows PowerShell 5.1) is the original on-PC collector with a Task Scheduler
setup. It is kept as a fallback and is not needed while the workflow runs.
