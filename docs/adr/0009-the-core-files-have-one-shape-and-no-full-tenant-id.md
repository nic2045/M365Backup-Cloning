# 0009. The core files have one shape and no full tenant ID

Status: Accepted (2026-11-07, issue #51). Raises the schema version of ADR 0008 from `"1"` to `"2"`; ADR 0008 point 3 is superseded in this value only.

## Context
ADR 0008 described the core files as they were: the kind and the time of a plan were only in the file name, the summary had other counters per plan kind, the reset plan had no licence section, `Properties` was sometimes `null`, the plan carried the full Dev tenant ID, and `Operation`, `Status` and the audit counters were open sets. A web server and interface built on that would need a special case for every plan kind.

## Decision
1. **Header in every file.** Plan files, the drift report and the suitability check carry `SchemaVersion` (`"2"`), `Kind` and `CreatedUtc`. A plan also carries `SchemaVersion` and `Kind` inside the plan object.
2. **The time is not part of the plan.** `CreatedUtc` is in the plan file, not in the plan: the plan hash must be the same when a script builds the plan again for `-Apply` (ADR 0001).
3. **One plan shape.** Every plan has the same fields. The summary has the same counters for every kind; a counter a kind does not use is 0. `Licences`, `Protected`, `TypeSummary` and `ExcludedTypes` are always present (empty where a kind has none; the reset's licence section says `Checked = false`). `Properties` is always an object.
4. **One licence core.** The plan check and the suitability check share `Checked`, `Readable`, `Error`, `Available` (`LicenceStatus`). The plan adds `Missing` and `Warnings`; the suitability check adds the SKU list. The plan has no SKU list, because seat counts change and must not change the plan hash.
5. **No full tenant ID in a plan.** A plan carries `TargetTenant` (8 characters plus `...`, as in the audit log) and `TargetTenantHash` (SHA-256 of the lower-case ID). The gate compares the hash with the Dev tenant of the local config; the full ID for writing always comes from the config. The Prod lock (Dev must not equal Prod) is unchanged.
6. **Closed lists.** `Operation`, `Status` and the audit counters are closed lists in the schema. A new value is added to the schema in the same pull request that introduces it.
7. **Older plans are refused, not guessed.** The gate and `Read-ApplyPlanFile` refuse a plan without `Kind` or with another `SchemaVersion` with "make a new plan".

## Consequences
- The server and the interface (#11) need no special case per plan kind.
- Plan hashes made before this change do not match any more; a preview has to be made again (the scripts always rebuild the plan for `-Apply` anyway).
- Resource data that needs a tenant ID to be applied (the cross-tenant partner of the baseline, the protected partner entry of the reset) keeps it; the server must not show these values to people without the right role.
