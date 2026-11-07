# 0001. The Dev tenant stack reads with UTCM and applies with Microsoft365DSC to Dev only

Status: Accepted (2026-11-07, decided with the owner in nic2045/SW-Depoyment#1585)

## Context
A package should be tested (QA) in a Dev tenant before it reaches Prod. The Dev tenant must stay equal to Prod for Intune configuration, compliance, groups, roles and Conditional Access, and it must be possible to reset and rebuild it. Per customer there is one pair of a Dev and a Prod tenant.

## Decision
1. **Direction.** Configuration, compliance, groups, roles and Conditional Access are mirrored Prod -> Dev. Apply is implemented for the Dev tenant only. There is no write path to a Prod tenant. Apps go Dev -> Prod after QA, but that upload is done by IntuneWin32App in nic2045/SW-Depoyment (neither UTCM nor Microsoft365DSC upload `.intunewin` content).
2. **Read and report: UTCM** (Microsoft Graph Tenant Configuration Management, generally available). Snapshot jobs export the source tenant; the toolkit copies the snapshot to local history (Graph keeps it only 7 days) and compares it with the target. Plain Graph calls, PowerShell 7. The module `jussiroine/UTCM-tooling` has no license file and is not used.
3. **Apply: Microsoft365DSC**, in its own Windows PowerShell 5.1 process, one job with a step list. Order: export, difference report, confirmation by a person, apply. Never automatic.
4. **Template: intune-tenant-clone-kit** (MIT) for name-based group remap, fail-closed assignments, preview and reconcile report. Code is taken over only with attribution in `THIRD-PARTY.md`.
5. **Safety rules.**
   - No `Ensure = Absent` in an automatic run; assignments that cannot be resolved are blocked, never widened.
   - Conditional Access is created Report-only (or disabled); break-glass accounts are always excluded; no apply may lock out an admin.
   - Role assignments go through groups only. Groups are matched by name, not ID.
   - Reset runs only on tenant IDs in the local config, after a preview and a double confirmation; 1-2 administrators, service accounts and break-glass accounts are never touched.
   - The write permission (app registration with certificate) exists only in the Dev tenant. In Prod only a read-only registration exists.
6. **Where it runs.** First as a job on a Windows machine (no Azure). Azure Automation (PowerShell 5.1) or an Azure Function is added only if a schedule without a running machine is needed.
7. **Repository.** Separate from nic2045/SW-Depoyment, independent of it. Private first, built public-ready (no real data, secret scan, MIT); made public after a review of the checklist in `CLAUDE.md`.
8. **Out of scope now.** Exchange Online, Entra ID, SharePoint and Teams scenarios (idea only).

## Consequences
- Reading needs no module installation; applying needs Windows PowerShell 5.1 and Microsoft365DSC.
- UTCM limits apply: snapshot 20,000 resources per month, 7 days retention; monitors every 6 hours and 800 resources per day.
- Everything that needs a real tenant is checked by the owner under `validation/`.
- The decision in nic2045/SW-Depoyment#1327 / ADR 0080 (test in the Prod tenant) is superseded for the QA step by a Dev-tenant option; SW-Depoyment records that in its own ADR.
