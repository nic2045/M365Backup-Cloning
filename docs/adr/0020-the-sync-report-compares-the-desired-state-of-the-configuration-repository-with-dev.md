# 0020. The sync report compares the desired state of the configuration repository with Dev

Status: Accepted (2026-11-08, issue #27 part 3; implements the plan "part 3" of ADR 0018)

## Context

ADR 0018 plans a read-only sync report as the last part of issue #27: what an apply from the repository would change
in Dev, and what Prod changed since the last reviewed export. ADR 0019 builds Dev from `desired/`, but the drift report
(also the one at the end of a rebuild) still compared Prod with Dev. Open were how the report names its source, how a
schedule reads its result, and whether the second comparison (Prod against `desired/`) needs code of its own.

## Decision

1. **The drift report takes the same source choice as the apply.** `Get-DriftReport.ps1 -Source Live|Repository`, the
   web job `drift` with `source`. The default stays `Live` (ADR 0019 point 1); the default of both is switched together
   by a later ADR. With `Repository` the desired side is `desired/` read by `Read-DesiredStateSnapshot` and the Dev side
   is the one of the apply (`ConvertTo-DesiredComparableSnapshot`), so the report shows exactly what a plan from the
   same commit would act on. Only committed state is read; Prod is not read, and the web job signs in to Dev only
   (`tenantsBySource`). Offline: `-TargetSnapshotPath` for a saved Dev snapshot.
2. **The report names its source.** `Compare-TenantSnapshot -SourceInfo` adds `Source = { Kind: Repository, Commit }`
   and a direction "Configuration repository -> Dev (...)"; the Markdown and the web page say "Desired state" instead of
   "Prod" and show the commit, and the report list tags each drift report with its source (`ReportListItem.source`). A
   report from Prod keeps its shape. The audit line names `desired/ <commit>`.
3. **The rebuild ends with the comparison of its own source.** `Invoke-DevRebuildChain -Source Repository` (and
   `Invoke-DevReset.ps1 -RebuildSource Repository`) runs the final drift report with `-Source Repository`, without a
   Prod token; the goal stays an empty report except for what is left out on purpose.
4. **A schedule only reports.** `-ReportExitCode` gives a schedule a result like the suitability check: 0 no difference,
   1 differences, 3 not verified (a tenant, the repository or the config could not be read; the reason is printed, no
   report is written). Without the switch the script behaves as before (0, or it stops with an error), so the web job
   and the rebuild are unchanged. Nothing is applied by a schedule (ADR 0004 point 5); docs/automation.md describes the
   runbook.
5. **Prod against `desired/` needs no code of its own.** Running the export again (ADR 0018) writes the new Prod state
   into `desired/`; its commit diff and the page *History > Desired state* are that comparison, reviewed in the
   repository before it reaches Dev. A second report would repeat it.

## Consequences

- Issue #27 is complete: the source of truth and the flow are fixed (ADR 0004, 0018, 0019, this ADR), and one run
  builds Dev only from the repository.
- Resources the export leaves out on purpose (secrets, excluded types) are "only in Dev" in a sync report, as in a plan
  from the repository; the export report lists them.
- `DriftReport.Source`, `ReportListItem.source` and `JobRequest.source` for `drift` are additions within schema
  version 2.
