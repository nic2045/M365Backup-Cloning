# 0018. The desired state is exported from Prod into the configuration repository

Status: Accepted (2026-11-08, issue #27 part 1; implements points 2 and 3 of ADR 0004, plans points 4 and 5)

Part 2 (build Dev from the repository) is implemented by ADR 0019.

## Context

ADR 0004 decided that the desired state lives as files in the private configuration repository of the operator and
that Dev is built only from it. So far the apply reads a live Prod snapshot at run time, and the repository holds only
the Intune backup of IntuneCD (ADR 0014), whose files are IntuneCD's format and hold both tenants. Issue #27 asks for
the export of Prod into normalised files, then for building Dev from them, then for a sync report. This ADR fixes the
export (part 1) and the plan for parts 2 and 3.

## Decision

1. **Export, read only.** `scripts/Export-DesiredState.ps1` and the web job `export-desired` (role Applier, like the
   other reading jobs that use the certificates) read one UTCM snapshot of Prod with the resource types of the apply
   (`Resources` or `Get-M365CloningDefaultResources`). Dev is not read. Nothing is written to a tenant.
2. **Folder and format.** `<ConfigRepository>/desired/<resource type>/<display name>.json`, one file per resource. The
   content is `{ resourceType, displayName, properties }`, the shape of a resource in a UTCM snapshot, so part 2 can
   read the folder back into a snapshot and use the existing comparison and plan unchanged. JSON with sorted keys
   (ordinal), lists in their original order, two spaces, LF line ends, a final newline, UTF-8 without BOM: the same
   content gives the same bytes, so Git diffs show only real changes. File names: characters Windows does not allow
   become `_`, device names get a prefix, at most 120 characters; names that end up equal (also only in case) get
   ` (2)`, ` (3)`.
3. **What is written.** Exactly what an apply may take from Prod (ADR 0001, 0006): types the catalog does not know,
   excluded types and workloads that are off, secret types, profiles with an encrypted OMA-URI value and resources with
   a secret property are not written and are listed in the run's report with the reason. Report-only types, tenant
   defaults and built-in objects are written; the apply decides what it does with them. The Prod values stay as they
   are: Conditional Access keeps its Prod state; Report-only and the break-glass exclusion stay rules of the apply.
4. **No IDs, no tenant.** `Id`/`Identity` are removed unless they are the key of the type. Assignments keep
   `groupDisplayName` and lose `groupId` and `collectionId`; the filter ID becomes
   `deviceAndAppManagementAssignmentFilterDisplayName`, looked up in the same snapshot. A filter that is not in the
   snapshot leaves the resource out (`needs-filter`): without it the assignment would be wider than in Prod. Connection
   properties (`TenantId`, `ApplicationId`, `CertificateThumbprint`, `ApplicationSecret`, `Credential`,
   `ManagedIdentity`, `AccessTokens`) are removed. A resource that still contains the Prod tenant ID anywhere is left out
   (`tenant id`). Other values that look like an object ID stay and are counted (`WithObjectIds`); the apply blocks them
   as before.
5. **Repository and history.** The same rules as the Intune backup (ADR 0014 point 4): the repository must be a Git work
   tree and not this toolkit; the files are written to a new folder below `History/tmp` first and replace `desired/`
   only when every file was written. One commit per run with only `desired/` (author `M365Cloning export`, "Started by"
   from the job), no push; no change, no commit. `History/reports/desired-export-<time>.json` (schema `DesiredExport`)
   holds counts, changed paths and the skipped resources (at most 1000 each), no content; one audit line, mode
   `export`, counts only.
6. **Web.** Routes `GET /api/desired-exports` and `/api/desired-exports/{id}`; page *History > Desired state* with the
   changes since the export before and the resources not written. It is a page of its own, not a generalised
   *Intune changes*: the Intune backup shows both tenants in IntuneCD's format and is history and documentation, the
   export shows Prod in the toolkit's format and is the input of the apply. One page per source keeps the existing route
   and contract unchanged.
7. **One truth.** `desired/` is the desired state and the only input the apply will take from the repository (part 2).
   `intune/` (IntuneCD) stays the documentation and change history of Intune in both tenants; it is never read by the
   apply. The operator reviews a change of `desired/` in the repository (commit or pull request) before it reaches Dev.

## Plan for the next parts (not built yet)

- **Part 2: build Dev from the repository.** `Invoke-ApplyDev.ps1 -Source Repository` (and `plan-apply` with
  `source: Repository`) reads `desired/` into a snapshot instead of reading Prod: every file becomes a resource; a
  filter gets a synthetic `Id` equal to its name and an assignment's `deviceAndAppManagementAssignmentFilterDisplayName`
  becomes that `Id`, so `New-ApplyPlan`, the filter mapping, the licence check, the plan hash and the confirmation stay
  as they are. The plan records the commit it was built from (part of the hash). Acceptance of #27: one run builds Dev
  only from the repository. Baseline and users move to the repository afterwards (ADR 0004 point 4).
- **Part 3: sync report.** Two read-only comparisons as reports: `desired/` against Dev (what an apply would change) and
  the latest Prod snapshot against `desired/` (what Prod changed since the last reviewed export). A schedule may run
  them (report only, ADR 0004 point 5); applying stays a confirmed action.

## Consequences

- The configuration repository gains the folder `desired/`; it must stay private (names of policies and groups).
- The host of the job runner needs Git; Python is not needed for the export.
- Resources left out by the export are visible per run and do not reach Dev through the repository; they are created in
  Dev by hand as before.
