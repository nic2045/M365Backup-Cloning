# Third-party sources

| Source | License | Use |
|---|---|---|
| Microsoft365DSC (Microsoft365DSC/Microsoft365DSC) | MIT | Apply to the Dev tenant (called, not copied) |
| intune-tenant-clone-kit (HoussemMak) | MIT | Template for name-based group remap, fail-closed assignments, preview and reconcile report; code taken over only with attribution here |
| UTCM Graph API (Microsoft) | Microsoft terms | Read, snapshot, drift report |
| Az.Accounts (Azure/azure-powershell, PowerShell Gallery) | MIT | Sign-in of web jobs with the certificate and the Graph token (`Connect-AzAccount`, `Get-AzAccessToken`; called, not copied, ADR 0013) |
| htmx 2.0.4 (bigskysoftware/htmx, npm `htmx.org`) | 0BSD | Shipped unchanged as `web/ui/m365ui/static/htmx-2.0.4.min.js` for the filter forms of the web interface |
| Fluent UI System Icons 1.1.345 (microsoft/fluentui-system-icons, npm `@fluentui/svg-icons`) | MIT, Copyright (c) 2020 Microsoft Corporation | The used icons (24 px, regular) copied unchanged to `web/ui/m365ui/static/icons/` (ADR 0011) |
| Fluent 2 design tokens (npm `@fluentui/tokens` 1.0.0-alpha.24) | MIT | Colour, radius, shadow and spacing values taken over as CSS variables in `web/ui/m365ui/static/app.css`; no code copied (ADR 0011) |

Not used: Microsoft product icons (Azure, Entra, Microsoft 365 architecture icons): their terms allow diagrams, training and documentation only, not an app interface (ADR 0011). Test tool only, not shipped: axe-core 4.10.3 (MPL-2.0) for the accessibility check.

Not used: jussiroine/UTCM-tooling (no license file in the repository; reference only).

Apply rules (fail-closed assignments, preview before write, reconcile report) follow the ideas of intune-tenant-clone-kit; no code of it is copied.

## Orientation documents (cited, not copied)

| Source | Use |
|---|---|
| Microsoft, "Conditional Access Governance and Principles for Zero Trust", October 2023 (`microsoft/ConditionalAccessforZeroTrustResources`) | Persona model, policy naming `<CAnumber>-<Persona>-<PolicyType>-...`, number ranges, exclusion and ring group ideas (ADR 0003) |
