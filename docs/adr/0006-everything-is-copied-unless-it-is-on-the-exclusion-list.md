# 0006. Everything is copied unless it is on the exclusion list

Status: Accepted (2026-11-07, decided with the owner in issue #40). Supersedes the per-type allow list implied by ADR 0001 and the resource map built so far.

## Context
Until now every resource type was switched on one by one: a type was copied only after it had its own entry in the resource map and its own handling. Each new type was a piece of own code (for example #35 enrollment, #38 authentication contexts). UTCM and Microsoft365DSC already know several hundred resource types.

## Decision
1. **Default is copy all.** Every resource type that UTCM can snapshot and Microsoft365DSC can apply is part of the plan, in the workloads the installation has switched on.
2. **One generic handling** for all types: tenant-specific IDs and timestamps are removed; known reference fields (groups, assignment filters, named locations, authentication strengths, authentication contexts, scope objects) are mapped by name; properties that carry secrets are detected and the resource is skipped; anything that cannot be resolved is blocked (fail-closed), never widened.
3. **Exclusion list as data.** Types that are dangerous or tenant-specific are listed with a reason in a data file shipped with the toolkit (for example authentication method policies, security defaults, domains, tenant-wide settings without a special path). The operator can extend the list in the local configuration or the configuration repository (ADR 0004). Excluded types appear in the report as `excluded: <reason>`.
4. **Special handling stays** where safety needs it: Conditional Access (Report-only, break-glass), groups (empty static copies), assignments, users, reset, licence check. Special handling is the exception and is named in the resource map.
5. **The report shows per run** what was copied, excluded and blocked, so that types which make no sense are found and added to the exclusion list.
6. Unchanged: Dev only, no write path to Prod, plan hash, confirmation, audit, never `Ensure = Absent` outside the reset.

## Consequences
- A new resource type without a special rule runs without code changes.
- The first runs will show more blocked or excluded entries; the exclusion list grows from real reports.
- The resource map shrinks to the special cases; #35 and #38 become mostly entries in data.
- Implementation follows in its own pull request after the licence check (#32).
