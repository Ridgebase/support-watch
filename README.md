# Support Watch

A one-page status board for clients' Power Automate cloud flows, in the shape of the Koena health panel:
status, today's success rate, last run per client, a 7-day table, then every flow with its last status.

Live page: https://support-watch.netlify.app (rebuilt every 10 minutes by the GitHub Actions workflow).

## How it runs

- `collect.ps1` signs in to each client tenant with a **refresh token**, reads flows and their runs for the
  configured environments through the Flow REST API, and writes `flow-runs.csv`.
- `build-dashboard.ps1` embeds that CSV into `dashboard.template.html` and pushes the result to Netlify.
- `.github/workflows/watch.yml` runs both every 10 minutes. If a client cannot be collected the job fails
  and GitHub emails the repo owner; the page is still deployed with the clients that worked.

All client-specific values live in GitHub secrets, nothing in this repo:

| Secret          | Content                                                                                   |
|-----------------|-------------------------------------------------------------------------------------------|
| `CLIENTS_JSON`  | `[{"Name":"X","Tenant":"x.com","Environments":["Env display name", ...]}, ...]`            |
| `RT_<NAME>`     | one per client, the refresh token written by `get-refresh-token.ps1`                       |
| `NETLIFY_TOKEN` | a Netlify personal access token                                                            |

## Why refresh tokens

The flow-owner accounts enforce MFA, so no password can sign in unattended. A device-code sign-in done once
by a human yields a refresh token that any machine can use; it renews itself on each use and lives about
90 days of continuous use. When a tenant revokes it the workflow fails: run

    .\get-refresh-token.ps1 -Tenant <tenant domain> -Out "$HOME\rt-<NAME>.txt"
    gh secret set RT_<NAME> --repo Ridgebase/support-watch < "$HOME\rt-<NAME>.txt"

## Local fallback

`flow-runs.ps1` (git-ignored, Windows PowerShell 5.1) is the original on-PC collector with a Task Scheduler
setup. It is kept as a fallback and is not needed while the workflow runs.
