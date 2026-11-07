# Running read-only checks on a schedule (Azure Automation)

This page describes how to run the suitability check (`scripts/Invoke-TenantFitCheck.ps1`, issue #39) on a schedule.
The toolkit does not deploy anything to Azure; you set this up yourself in your own subscription.

A schedule is allowed because the check only reads (ADR 0004: "a schedule may only produce reports"). Scheduled
writes to Dev are a separate, later decision (issue #30) and are not covered here.

## What runs

- `Invoke-TenantFitCheck.ps1` reads `GET /subscribedSkus` in Prod and Dev and the newest saved Prod snapshot, then
  writes `History/reports/tenantfit-<timestamp>.json` / `.md` and one line in `History/audit.jsonl`.
- Exit code: 0 green, 1 yellow, 2 red. Use it to mark the job as failed or to send an alert.
- Only Microsoft Graph is used, so a PowerShell 7 runbook is enough (Microsoft365DSC and Windows PowerShell 5.1 are not
  needed for this check).

## Setup (once)

| Step | Where | What |
|---|---|---|
| 1 | Entra admin center, Prod and Dev | The read-only app registration of each tenant has the application permission `LicenseAssignment.Read.All` with admin consent. For `-TakeProdSnapshot` the Prod registration also needs the UTCM read permissions (see the drift report). |
| 2 | Azure Automation account | Upload the certificates of both app registrations (Automation account > Certificates). Never put them into this repository. |
| 3 | Automation account > Runtime environments | A PowerShell 7 runtime with the toolkit files (for example as a packaged module or copied in the runbook's working folder). |
| 4 | Automation account > Variables | Non-secret values: Prod and Dev tenant IDs, client IDs, certificate names, the path or storage of `config.psd1` and `History`. |
| 5 | Runbook | Gets an app-only token per tenant with its certificate (scope `https://graph.microsoft.com/.default`), passes them as `-ProdToken` / `-DevToken` to `Invoke-TenantFitCheck.ps1`, and keeps `History` on persistent storage (for example an Azure file share), because the runbook sandbox is temporary. |
| 6 | Schedule | Link a schedule, for example daily. Prod snapshots count against the UTCM snapshot quota, so prefer the saved Prod snapshot of the drift report over `-TakeProdSnapshot` on every run. |

## What to watch

- A red result with `Verified: False` means a licence list could not be read (permission, certificate, network), not
  that a new tenant is needed. Fix the access first.
- The report contains no secrets and no tenant IDs beyond the shortened ID in the audit line; keep `History` private
  anyway.
