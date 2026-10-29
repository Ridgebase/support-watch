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
- `build-dashboard.ps1` aggregates that CSV into `out/site/data.json` (per-flow and per-day totals, failed runs with their run id and
  error text: the failed action's name, code and connector message for a flow's 30 newest failed runs, read with two extra calls
  each, the run's generic banner for older ones; ~40 KB instead of every run) and renders `out/site/index.html` from `dashboard.template.html`. It also flags
  **silent** flows: an enabled recurrence flow whose last run is older than 1.5x the longest gap between two of its runs this week
  (3 runs needed), i.e. a schedule that stopped without failing. A flow with no weekend run is measured in weekday time (Saturdays,
  Sundays and the statutory holidays listed in `build-dashboard.ps1` do not count), so a weekday schedule is not silent over the weekend.
  Yellow on the page, counted in "needing attention", emailed once. Same for **stuck** runs: a run still Running after 2 hours.
- Credentials with a fixed expiry are listed, dates only, in `EXPIRIES` (plain env in `watch.yml`): shown under the page title, red and
  emailed when under 14 days, emailed again once expired. After renewing one, store the new secret and put the new date there.
- The same run also collects, per client, the refresh history of the Power BI models listed under `PowerBI` in `CLIENTS_JSON`
  (`out/powerbi.csv` = last refresh per model, `out/powerbi-runs.csv` = every refresh of the window, aggregated per day into
  `pbidays` for the Power BI tab's recap and the weekly mail) and, for every listed environment, the canvas apps and connections
  (`out/powerapps.csv`, `out/connections.csv`, Power Apps tab; connections only those owned by the signed-in integration
  account, other users' personal connections are not ours to watch): a connection whose status is not Connected and an app whose
  owner account is disabled or deleted in Entra are red and counted in the tab's badge. With a Power Platform admin role the
  whole environment is listed; otherwise only what the signed-in account can see.
- The cloud job also reads, once (one Odoo database for all clients), the **Odoo Helpdesk** tickets whose stage is `In Progress`
  (`out/tickets.csv`, Helpdesk tab: a ticket past its SLA deadline is red and counted in the tab's badge). A ticket belongs to the client
  whose optional `"Odoo"` field in `CLIENTS_JSON` equals the ticket customer's company, or whose tenant's first label is contained in that
  company name (`seguinmorris.com` ~ `Séguin Morris Inc`); the others show under All clients only.
- The **Odoo** tab watches the Odoo.sh database (`ODOOSH_*`, separate from the Helpdesk tab's Odoo Online): `/web/health`, the neutralization
  flag, the `ridgebase_support` module's version, failing or overdue scheduled actions and mails in error (red, in the tab's badge), then the
  changes of the last 7 days (Odoo 20's tracking messages, "old → new (Field)", which also cover users, groups, access rules and crons; plus
  the untracked config models such as helpdesk teams, stages and SLAs, edited by whom and when) and the sign-ins per user (`out/odoo.csv`). `ODOOSH_USER` should be a dedicated user: its own sign-ins
  (one per run) are left out.
- The **Licences** tab: per client, from Graph with the same refresh token (`licences.csv`, `tenants.csv`, `licusers.csv`, SEMO's carried over),
  one row per plan with the seats bought, assigned, in grace or suspended and the next renewal date, the enabled user count, and the disabled
  accounts that still hold a paid licence. Red (and the tab's badge): more seats assigned than bought, seats in grace, a plan not enabled, a renewal
  within 30 days; yellow: suspended seats, or a fifth of a paid plan's seats unassigned. Free, trial and expired plans are hidden by a switch.
  Plan names are a hand-kept map in the template (`SKU`); an unknown code shows as is. Below the plans, every environment of the tenant
  (`out/envcap.csv`, admin API) with its Dataverse database, file and log storage used and the add-ons allocated to it: per-app passes are
  assigned to environments, never to users, so that allocation is what the per-app plan row shows as assigned, and the number of distinct users
  who opened an app in the environment in the last 30 days sits next to it: the audit log's `LaunchPowerApp` events, read through Graph with the
  `MC_<NAME>` token (one asynchronous audit query a day per client, its id kept in `state/audit-queries.json`, the result in
  `state/launches.csv`; the Power Apps tab shows the same per app). Above it, the tenant's Dataverse
  capacity as the admin center's Capacity page shows it (`tenants.csv`, Power Platform API `licensing/tenantCapacity`): used against entitled
  per storage type, red at 100% or when Microsoft reports the capacity exceeded, yellow from 80%.
- The **Tech watch** tab has two sections. Top, **service changes**: each client's Microsoft 365 Message Center (Graph, the place Microsoft
  announces retirements, licensing and policy changes with the services affected and an action date), messages of the last 60 days that are
  more than "Stay informed" and that match `WATCH_SERVICES` (plain env in `watch.yml`, a regex on the services and title: Power Platform,
  Dataverse, Dynamics, Entra, licensing and pricing by default; Teams, Exchange and Office housekeeping is left to the tenant's admin), one row
  per message with the clients it was seen in; red with the tab's badge when an action is due within 14 days or overdue by less than a month,
  yellow for a major change or a retirement. It needs a second token per client, `MC_<NAME>`, made by
  `get-refresh-token.ps1 -Tenant <tenant> -Out <file> -MessageCenter` (the Flow token's app is not pre-authorized for that permission; the
  account needs a role that reads the Message Center, e.g. Global Reader or Message Center Reader) and stored like `RT_<NAME>` (GitHub secret;
  for SEMO the function's app setting, `flow-runs.ps1 -Login SEMO -MessageCenter` then `azure-function/set-secrets.ps1`). Bottom, **blog posts
  and roadmap**: the public feeds listed in `WATCH_FEEDS` (plain env in `watch.yml`, one per line `Label | URL | optional regex` matched against
  each item's title and categories, used to keep only our products from the Microsoft 365 roadmap), general (not per client), newest 25 items
  per feed from the last 45 days, read once a day, each morning, into `state/news.csv` (committed with the rest of `state/`), with links to the Microsoft pages.
- `.github/workflows/watch.yml` runs both every 10 minutes. GitHub throttles its own `schedule` trigger (gaps of ~30 min
  were observed), so the 10-minute cadence comes from a free cron-job.org job that POSTs to the workflow's
  `dispatches` API with a fine-grained token (repo `support-watch`, permission Actions read/write, approved by an
  org owner, **expires after one year**); GitHub's cron stays as a 30-minute fallback. A client whose sign-in is refused keeps its rows from
  the live page (and goes STALE on the page after an hour); the job only fails when no client at all could be collected.

**Known limit:** Seguin Morris (SEMO) has a Conditional Access policy that blocks sign-ins from outside Canada, so
GitHub's US runners are refused (AADSTS53003). SEMO is therefore collected by `azure-function/`, a PowerShell timer
function in **Canada Central** (Ridgebase subscription, resource group `rg-support-watch`, app `func-support-watch-semo`),
every 15 minutes (10 overloaded the Flow API): it fetches `collect.ps1`, `build-dashboard.ps1` and the template from this repo's `main` at each run
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
| `ODOO_URL`, `ODOO_USER`, `ODOO_KEY` | the Odoo database (`https://<db>.odoo.com`), the user and their API key (Preferences > Account Security) for the Helpdesk tab |
| `ODOOSH_URL`, `ODOOSH_DB`, `ODOOSH_USER`, `ODOOSH_KEY` | the Odoo.sh database (URL and full database name, from the branch's build), an admin user and their API key, for the Odoo tab |

`CARRY_CLIENTS` (plain env in `watch.yml`, currently `SEMO`) names the clients the job never collects itself: they come
from `CARRY_URL` only, i.e. from the Azure function, even on the days SEMO's Conditional Access lets GitHub's runners in.
| `SMTP_USER`     | sending account and From address (a Google Workspace user with an app password)            |
| `SMTP_PASSWORD` | its app password                                                                           |
| `MAIL_TO`       | recipient(s), comma-separated                                                              |
| `SMTP_HOST`     | optional, default `smtp.gmail.com`; port 587 with STARTTLS                                 |
| `HEALTHCHECK_URL` | optional, a healthchecks.io ping URL (check period 10 min, grace 1 h): the job pings it after every successful run, so the service emails when the job stops running at all. The Azure function has its own check through its `HEALTHCHECK_URL` app setting (period 15 min). |

## Email alerts

`notify.ps1` runs after each deploy. It emails one message per run listing the flows whose latest run has **newly**
failed (a flow that keeps failing is announced once, until it recovers), with the run's error text and a link to the failed run,
one message for flows that went **silent** (announced once per silence), one for **stuck** runs (once per run), one when a client has
had **no data for over an hour** (once per episode: token revoked, sign-in refused or collector down), and one weekly recap on Monday after 07:00
Eastern with the last 7 days' totals per client, every flow that failed in the week and the Helpdesk tickets in progress (those past
SLA named), plus one recap per client the same morning (its flows with failures, its failed Power BI refreshes and its tickets in
progress, listed in full). No recap on Monday morning =
the job itself is broken. `gh workflow run watch.yml -f digest=true` sends a sample recap right away; `-f sample_ops=true` a sample stuck-run alert and a sample
stale-client alert; `-f sample=true` a sample failure alert. Add `-f to=<address>` to send a sample to someone else than `MAIL_TO`.
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
