# 0012 The web interface starts jobs and is organised by goals and areas

Status: Accepted (2026-11-07, issues #14, #66). Supersedes point 4 (workflow navigation) of ADR 0011 and, in point 7,
"the interface stays read only, commands are shown, not run". The rest of ADR 0011 stays.

## Context

Until now the interface only read: reports, plans and the audit log, with the scripts as the only way to change Dev.
The admin had to switch to a console for every step. Issue #14 asks for the actions in the browser (reports, plans,
apply after confirmation, reset with two confirmations) as jobs with steps, progress and cancel, and their state in
files. Issue #66 asks for a menu that follows what the admin wants to reach, not the tools: goals plus a section per
product area in which Dev is configured. The current focus is the Intune QA goal.

## Decision

1. **Menu by goals and areas.**
   - Overview.
   - Goals: *Bring Dev in line* (compare, suitability, plan of all areas, apply), *Start Dev fresh* (reset preview with
     mode and device action, confirmation on the plan, then the rebuild order), *Fill Dev* (base state, Dev users).
   - Areas: *Intune* (differences of the Intune types, a plan of the Intune area, apply). *Entra ID*, *Conditional
     Access* and *Licences* are shown greyed out with "later" (`aria-disabled`, not a link), so the structure is
     visible without dead pages.
   - History: Jobs, Plans, Reports, Audit log. Plans and reports keep their counters; Jobs counts only active jobs.
   - Settings: no item until there is a settings page (unchanged from ADR 0011).
   The reset is reached only through *Start Dev fresh* and a reset plan; no area offers it.
2. **One plan, the area is a scope.** A plan of one area is the same plan format with `Area = 'Intune'`
   (`New-ApplyPlan -Area`, `Invoke-ApplyDev.ps1 -Area`): entries outside the area are `skipped` with a reason starting
   with `area:`; the empty group copies an Intune assignment needs stay in. The area is part of the plan, so its hash
   differs from the plan of all areas, and an apply uses the area of the plan. A plan of all areas keeps its shape and
   hash.
3. **Every action is a job in its own process.** `POST /api/jobs` checks the request, the role and the confirmation,
   writes `History/jobs/<id>.json` (schema `JobFile`) with status `queued` and starts
   `scripts/Invoke-WebJob.ps1` (PowerShell 7) detached. The runner (`Invoke-WebJob`) runs the existing script in the
   same way as on the console and keeps state, steps (check, sign in, run, result), result and log in the job folder.
   The API keeps nothing in memory; it reads the files. One job at a time (`409 job-running`); a job without a sign
   of life (queued 10 minutes, running 6 hours) counts as stopped.
4. **Roles from one table.** `src/M365Cloning/Data/WebJobs.json` names role, tenants and script per action; the API and
   the runner both read it. Reports and the plans of apply, base state and users need `Applier`; the reset preview and
   the reset apply need `Resetter`. The interface hides buttons a person cannot use; the API decides.
5. **Confirmation as on the console, checked three times.** Apply: the person ticks "I checked this plan" on the
   plan page, which sends the plan hash; the API compares it with the plan file (`409 plan-changed`), the runner again,
   and the script builds the plan from the tenants as they are now and applies only if the hash is still the same.
   Reset: in addition the person types the Dev tenant ID; only its SHA-256 is stored and compared with the plan and the
   config (`409 tenant-mismatch`). Mode and device action come from the plan. A refused request writes an audit line
   `refused`.
6. **What stays with the script.** Device wipe and reset plans with different actions per device
   (`-DeviceActionFile`) are not offered in the web interface; the runner refuses such a plan. `-RebuildAfter` is not
   offered; *Start Dev fresh* lists the rebuild steps instead.
7. **Tokens and who.** The runner gets app-only Graph tokens with the certificate of each app registration
   (`Get-AppOnlyGraphToken`, client credentials with a certificate assertion; no extra module), only for the tenants
   the action reads, and keeps them in memory. The person who started the job is written as `Actor` into every audit
   line of the run (environment variable `M365CLONING_ACTOR` for the run).
8. **Cancel between steps.** Cancel creates `History/jobs/<id>.cancel`; the runner stops before its next step. A
   running script is not interrupted: an apply stopped half way is worse than one finished.
9. **Progress as steps.** The job page shows the step list with a state per step and a progress bar and refreshes
   itself every 3 seconds while the job is active (HTMX, no own script).

## Consequences

- The API has its first write routes: `POST /api/jobs` and `POST /api/jobs/{id}/cancel` (OpenAPI, contract tests,
  mock examples). Both answer 202 with the job.
- The web host needs PowerShell 7 (`pwsh`, or `M365CLONING_PWSH`), the module and, for an apply, Windows with
  Microsoft365DSC; the certificate of each app registration must be in the personal store of the account that runs
  the API. `M365CLONING_CONFIG` points to the config if it is not next to the scripts.
- In mock mode without sign-in the example person has every role, so all buttons can be tried; they only show the
  example answers and start nothing.
- The jobs counter in the menu costs one more read call (`/api/jobs`) per page.
- A settings page (read only) is still open; so are the areas Entra ID, Conditional Access and Licences.
