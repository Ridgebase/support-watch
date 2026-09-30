# Support Watch

A one-page status board for clients' Power Automate cloud flows, in the shape of the Koena health panel:
status, today's success rate, last run per client, a 7-day table, then every flow with its last status.

Live page: https://ridgebase.github.io/support-watch/ (rebuilt every 10 minutes by the GitHub Actions workflow and
published to GitHub Pages: free and without a deploy quota, unlike Netlify's free plan at 15 credits per deploy).

## How it runs

- `collect.ps1` signs in to each client tenant with a **refresh token**, reads flows and their runs for the
  configured environments through the Flow REST API, and writes `flow-runs.csv`.
- `build-dashboard.ps1` aggregates that CSV into `site/data.json` (per-flow and per-day totals, failed runs; ~40 KB
  instead of every run) and renders `site/index.html` from `dashboard.template.html`.
- `.github/workflows/watch.yml` runs both every 10 minutes. GitHub throttles its own `schedule` trigger (gaps of ~30 min
  were observed), so the 10-minute cadence comes from a free cron-job.org job that POSTs to the workflow's
  `dispatches` API with a fine-grained token (repo `support-watch`, permission Actions read/write, approved by an
  org owner, **expires after one year**); GitHub's cron stays as a 30-minute fallback. A client whose sign-in is refused keeps its rows from
  the live page (and goes STALE on the page after an hour); the job only fails when no client at all could be collected.

**Known limit:** Seguin Morris (SEMO) has a Conditional Access policy that blocks sign-ins from GitHub's servers
(AADSTS53003), while the same token works from a PC in Canada. Until their IT excludes the `integrateur-erp` account
from that policy, SEMO data on the public page comes from the local Windows task (`flow-runs.ps1`) whenever that PC
is on: it publishes its `site/data.json` to an unlisted gist (`rry-gist.txt` holds the id) and the cloud job
reads that gist for any client it cannot sign in to.

All client-specific values live in GitHub secrets, nothing in this repo:

| Secret          | Content                                                                                   |
|-----------------|-------------------------------------------------------------------------------------------|
| `CLIENTS_JSON`  | `[{"Name":"X","Tenant":"x.com","Environments":["Env display name", ...]}, ...]`            |
| `RT_<NAME>`     | one per client, the refresh token written by `get-refresh-token.ps1`                       |
| `CARRY_URL`     | raw URL of the gist where the laptop collector publishes its `data.json` (see below)              |

## Why refresh tokens

The flow-owner accounts enforce MFA, so no password can sign in unattended. A device-code sign-in done once
by a human yields a refresh token that any machine can use; it renews itself on each use and lives about
90 days of continuous use. When a tenant revokes it the workflow fails: run

    .\get-refresh-token.ps1 -Tenant <tenant domain> -Out "$HOME\rt-<NAME>.txt"
    gh secret set RT_<NAME> --repo Ridgebase/support-watch < "$HOME\rt-<NAME>.txt"

## Local fallback

`flow-runs.ps1` (git-ignored, Windows PowerShell 5.1) is the original on-PC collector with a Task Scheduler
setup. It is kept as a fallback and is not needed while the workflow runs.
