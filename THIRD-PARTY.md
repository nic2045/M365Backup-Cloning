# Third-party sources

| Source | License | Use |
|---|---|---|
| Microsoft365DSC (Microsoft365DSC/Microsoft365DSC) | MIT | Apply to the Dev tenant (called, not copied) |
| intune-tenant-clone-kit (HoussemMak) | MIT | Template for name-based group remap, fail-closed assignments, preview and reconcile report; code taken over only with attribution here |
| UTCM Graph API (Microsoft) | Microsoft terms | Read, snapshot, drift report |
| htmx 2.0.4 (bigskysoftware/htmx, npm `htmx.org`) | 0BSD | Shipped unchanged as `web/ui/m365ui/static/htmx-2.0.4.min.js` for the filter forms of the web interface |

Not used: jussiroine/UTCM-tooling (no license file in the repository; reference only).

Apply rules (fail-closed assignments, preview before write, reconcile report) follow the ideas of intune-tenant-clone-kit; no code of it is copied.

## Orientation documents (cited, not copied)

| Source | Use |
|---|---|
| Microsoft, "Conditional Access Governance and Principles for Zero Trust", October 2023 (`microsoft/ConditionalAccessforZeroTrustResources`) | Persona model, policy naming `<CAnumber>-<Persona>-<PolicyType>-...`, number ranges, exclusion and ring group ideas (ADR 0003) |
