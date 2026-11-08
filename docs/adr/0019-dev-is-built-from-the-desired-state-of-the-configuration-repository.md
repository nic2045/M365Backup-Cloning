# 0019. Dev is built from the desired state of the configuration repository

Status: Accepted (2026-11-08, issue #27 part 2; implements the plan "part 2" of ADR 0018 and point 4 of ADR 0004 for the apply). The drift report at the end of the rebuild follows the source since ADR 0020.

## Context

ADR 0018 writes the Prod desired state into `desired/` of the configuration repository and plans that the apply reads
it back instead of a Prod snapshot. Issue #27 accepts when one run builds Dev only from the repository. Open were the
default source, how a plan proves which state it was built from, what happens with uncommitted edits, and which tenants
a web job signs in to.

## Decision

1. **Source is a choice, default Live.** `Invoke-ApplyDev.ps1 -Source Live|Repository`, the web job `plan-apply` with
   `source` (`Live` or `Repository`), `Invoke-DevReset.ps1 -RebuildSource` and `Invoke-DevRebuildChain -Source`. The
   default stays `Live` (a Prod snapshot, as before): an existing instance does not change behaviour without a decision
   of its operator, and an instance without `ConfigRepository` keeps working. The default can be switched by a later ADR
   once the repository source has run on a real system.
2. **Read back without a new plan path.** `Read-DesiredStateSnapshot` reads every `desired/<type>/<name>.json` into a
   snapshot (`ConvertFrom-DesiredStateResource`): a filter gets its name as a synthetic `Id`, an assignment's
   `deviceAndAppManagementAssignmentFilterDisplayName` becomes its `deviceAndAppManagementAssignmentFilterId`. So
   `New-ApplyPlan`, the filter and group mapping by name, the licence check, the plan hash, the gate and the confirmation
   are the ones of the live source; the apply drops `Id` before it writes, so the synthetic value never reaches Dev.
   A file that is not a desired-state file or lies in the wrong type folder stops the run with its path.
3. **Same properties on both sides.** Dev is still read live (actual state). Before the comparison the Dev snapshot loses
   what the export never writes (`ConvertTo-DesiredComparableSnapshot`: connection properties and assignment
   `collectionId`), so a property left out on purpose is not a difference. IDs stay; the comparison ignores them and the
   mapping needs the Dev IDs.
4. **The plan names its source.** A plan from the repository carries `Source = { Kind: Repository, Commit: <full commit
   ID> }` and a note. The commit is part of the plan hash: when the desired state changed between preview and apply,
   the plan built again for `-Apply` has another hash and is refused, as for a changed tenant. A plan from Prod has no
   `Source` and keeps its shape and hash.
5. **Only committed state.** `desired/` must have no change that is not committed, also no new file. Otherwise the run
   stops and names the files: the commit in the plan must hold exactly what the plan read.
6. **Prod is not read.** With the repository source no Prod snapshot is taken; the web job signs in to Dev only
   (`tenantsBySource` in `WebJobs.json`), its apply takes the source from the plan. All other rules of the apply stay:
   Prod lock, `ApplyAllowed`, Conditional Access Report-only with the break-glass exclusion, no `Ensure = Absent`,
   exclusion list, fail-closed name mapping.
7. **Web.** *Bring Dev in line* and *Areas > Intune* offer "Desired state: Prod (live) / Configuration repository" (Live
   preselected); the plan page shows the source and the short commit. `JobRequest.source`, `JobOptions.source` and
   `Plan.Source` are additions within schema version 2.

## Consequences

- One run builds Dev only from the repository (acceptance of #27); the operator reviews a change of `desired/` in the
  repository before it reaches Dev.
- The reset's own preview (protection list, Align against Prod) still reads Prod; only the rebuild's apply step uses the
  chosen source. The drift report at the end of the rebuild still compares Prod and Dev; the comparison against the
  repository is part 3 (sync report, ADR 0018).
- Base state and Dev users are not part of `desired/` yet (ADR 0004 point 4 follows later).
