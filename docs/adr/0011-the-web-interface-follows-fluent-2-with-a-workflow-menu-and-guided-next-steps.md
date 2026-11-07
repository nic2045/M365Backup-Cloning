# 0011 The web interface follows Fluent 2 with a workflow menu and guided next steps

Status: Accepted (issues #63, #61). Point 4 (workflow navigation) and "the interface stays read only" in point 7 are superseded by ADR 0012.

## Context

The read-only interface (ADR 0002, issue #12) had a top bar with four links and raw ISO times. Admins open it
rarely and need to know at a glance where the Dev tenant stands and what to do next. The people who use it work
in the Microsoft admin centers every day, so the interface should feel familiar to them. Product logos of
Microsoft would help recognition, but their use is restricted.

## Decision

1. **Design template: Fluent 2.** Colours, radius, shadow, type ramp and spacing follow the Fluent 2 web themes.
   The values are taken from the npm package `@fluentui/tokens` 1.0.0-alpha.24 (`webLightTheme`, `webDarkTheme`,
   read as text from the published package) and kept as CSS variables in `web/ui/m365ui/static/app.css`, light
   and dark (`prefers-color-scheme`). Own CSS, no component framework, no build step. The existing spacing tokens
   stay (`--gap-row` 8 px = Fluent spacing S, `--gap-block` 16 px = L, `--gap-section` 32 px = XXXL). One
   deviation: the warning text uses the darker orange shade (`#8a3707`) for contrast on the light warning
   background.
2. **Icons: Fluent UI System Icons** (MIT, npm `@fluentui/svg-icons` 1.1.345). Only the icons in use are copied
   to `web/ui/m365ui/static/icons/`; one table (`view.ICON_FILES`) maps names to files and one macro (`icon`)
   inlines them. Only plain single-path SVGs are accepted when they are loaded.
3. **No Microsoft product logos.** The terms of the Azure and the Microsoft Entra architecture icons permit use
   "in architectural diagrams, training materials, or documentation" and say not to use them to represent your
   own product or service (checked on Microsoft Learn: *Azure architecture icons* and *Microsoft Entra
   architecture icons*, November 2026). An app interface is none of these, so product families (Intune,
   Entra ID, Conditional Access) are shown as neutral tags with a Fluent icon and the name as text. The toolkit
   has its own simple logo (`static/logo.svg`, two squares and an arrow, no Microsoft mark).
4. **Workflow navigation.** A menu on the left in the order of the work: Overview; Workflow: 1 Compare and check
   (drift and suitability reports), 2 Plans; Trace: Audit log. The active item is marked by background, bar and
   bold text plus `aria-current`; reports and plans carry counters from the list routes. Applying and resetting
   are done with the scripts and get no menu item (no dead or "coming soon" links). The signed-in person and
   roles (ADR 0010) sit at the bottom of the menu. Settings get an item only once there is a settings page.
   Detail pages have breadcrumbs. On narrow screens the menu folds behind a button with icon and text
   (`aria-expanded`, `aria-controls`); without JavaScript it stays open.
5. **Guidance from data only.** The overview shows a "Next step" card. It is derived only from what the read
   routes already return (`/api/status`, `/api/fitcheck/latest`, `/api/plans`); the rules are a small table in
   `m365ui/view.py` (`RULES`), first match wins, the others follow under "After that":

   | Rule | When | Next step | Script |
   |---|---|---|---|
   | no-report | no drift report | Run the drift report | `scripts/Get-DriftReport.ps1` |
   | fit-check | suitability red, grey, not verified or missing | Check the suitability report | `scripts/Invoke-TenantFitCheck.ps1` |
   | stale-report | last comparison older than 7 days | Compare again | `scripts/Get-DriftReport.ps1` |
   | differences | differences > 0 | Create a plan | `scripts/Invoke-ApplyDev.ps1` |
   | done | none of the above | Nothing to do | – |

   Tiles show the 3 newest plans and the 5 newest audit entries (existing routes, `pageSize=5`).
6. **Readable times (#61).** Every time is shown as date and time plus relative time ("2 hours ago"); the exact
   value stays in `<time datetime>` and `title`. The server writes UTC; a small script (`static/app.js`) rewrites
   the text to the local time of the browser. Lists are newest first, entries in an older format (`outdated`)
   always last.
7. **Principles** for every view: visible state; a next step on the overview; progressive disclosure (details,
   "After that", excluded types folded); error prevention (the interface stays read only, commands are shown,
   not run); explained empty states (picture, meaning, script to run); status never by colour or icon alone
   (badge = icon + text + colour); WCAG 2.2 AA, targets at least 44 px, visible focus, skip link, logical order.
   Checked with axe-core 4.10.3 (local file, rules WCAG 2.0/2.1/2.2 A and AA plus best practice) on all main
   pages, light and dark, 1280 and 390 px.

## Consequences

- The UI calls no new API route; the counters and tiles cost three extra read calls on the overview and two on
  other pages.
- Changing a colour means changing a token, not a page. New icons are added to `ICON_FILES` and copied from the
  same package version.
- The Fluent 2 design site (fluent2.microsoft.design) and the WCAG 2.2 text at w3.org could not be reached from
  the build environment; the token values come from the published package and the accessibility check from
  axe-core.
