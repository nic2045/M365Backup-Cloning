# 0005. The factory reset is the one deleting run: Align by default, Full on purpose

Status: Accepted (2026-11-07, decided with the owner in issue #7: protect the Prod Global Administrators except break-glass, admins as B2B guests, keep the cross-tenant base configuration; two modes, Align as default)

## Context
ADR 0001 keeps every automatic run additive: no delete, no `Ensure = 'Absent'`. The Dev tenant must however reach a state where it equals Prod, and it must be possible to clean it up and rebuild it in a controlled way. Both need deletes. Locking out the administrators of the Dev tenant must not be possible.

## Decision
1. **One documented exception.** The factory reset (`scripts/Invoke-DevReset.ps1`) is the only run that deletes. Everything else stays as ADR 0001 says.
2. **Two modes, same rules.**
   - **Align (default):** deletes only objects of the reset scope that exist in Dev but not in Prod, taken from the drift report (`Compare-TenantSnapshot`, "Removed"). Objects outside the report are kept. The apply then aligns what differs. This reaches "Dev equals Prod" with the least change.
   - **Full (on purpose only):** deletes everything in the reset scope except the protection list and the base state, so that Dev is rebuilt from scratch.
3. **Reset scope.** Conditional Access policies (switched off first, then deleted), Intune configuration profiles and update rings, compliance policies, settings catalog and endpoint security policies, assignment filters, groups, and in Full mode the test users of the positive list (`DevUsers`).
4. **Never deleted.** Devices (listed only), guests, synced users and groups, other member users, Microsoft 365 groups, role-assignable groups, licences, domains, role definitions, app registrations, the cross-tenant access settings and cross-tenant sync. The permanent delete of the deleted items is never called; users, groups and Conditional Access policies stay restorable for 30 days.
5. **Protection list**, built before every plan and shown with its source: `ProtectedAccounts`, `BreakGlass`, `ServiceAccounts` and `BreakGlassGroups` of the config; the Global Administrators of Prod (read only) without the break-glass accounts, and their B2B guests in Dev; all guests; the toolkit's app in Dev; the cross-tenant partners; the groups of the base state. A Prod Global Administrator without a guest in Dev is listed as "Invite"; the invitation runs through the Dev users step (#22), never through the reset.
6. **Refusals before any write.** Prod not readable or without a Global Administrator; no protected account in the config; no protected account present in Dev; Dev tenant ID equal to Prod; `Dev.AllowReset` not `$true`; wrong plan hash (first confirmation); `-ConfirmTenant` not equal to the Dev tenant ID (second confirmation); a planned delete that hits the protection list.
7. **Write path.** Microsoft Graph with its own allow list: DELETE on the reset kinds and one PATCH (`state = 'disabled'` on a Conditional Access policy), Dev only. Not Microsoft365DSC, because a DSC delete is `Ensure = 'Absent'`, which stays out of every other run. Order: Conditional Access, Intune policies, filters, groups, users; a failure stops the later steps. Every delete is written to the audit log (kind and name, no IDs or secrets).
8. **Controlled rebuild.** `-RebuildAfter` runs base state (#8) -> apply Intune and Conditional Access (#19, #23, #25) -> Dev users (#22), each with its own plan and its own confirmation (the plan hash typed by a person), and ends with the drift report. Nothing runs on without confirmation.

## Consequences
- "Dev equals Prod" is reached by Align plus apply; Full is for a clean rebuild.
- The reset needs read permissions in Prod (directory roles) and delete permissions in Dev; the setup wizard (#18) will set them.
- With the configuration repository (ADR 0004) the reset returns Dev to the state described there; until then the base state of the config and the Prod snapshot are the reference.
