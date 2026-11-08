# 0017. The web interface uses a copper brand ramp

Status: Accepted (2026-11-08, issue #81, decided with the owner). Supersedes the brand colour of ADR 0011 point 1
(the blue `brandWeb` ramp of the Fluent web themes); everything else in ADR 0011 stays.

## Context

ADR 0011 took all colours from the Fluent 2 web themes, including the blue brand ramp. Every Fluent app looks the
same in that blue; the owner wants this toolkit to be recognisable at a glance, in a warm colour. Fluent 2 is built
for this: a theme is generated from 16 brand variants (`BrandVariants`, steps 10 to 160) and the alias tokens of
`webLightTheme` and `webDarkTheme` are derived from them. Changing the brand therefore means changing one ramp, not
the pages.

A first draft used a saturated warm orange (`#c4500e`). It sat right on top of the Fluent warning colour (status
`orange`: `#bc4b09` / `#8a3707`, HSL hue 22 degrees, saturation about 91 %), so a warning badge and a brand accent
looked alike.

## Decision

1. **Key colour copper `#a65a3a` at step 80** (HSL 18 degrees, 48 %, 44 %). It is deliberately set apart from the
   Fluent warning orange: a similar warm hue, but about half the saturation, so it reads as a muted copper next to
   the vivid warning orange. Step 80 is the background of the primary button in the light theme; white text on it
   reaches 5.07:1 (WCAG AA).
2. **Ramp built like the Fluent Theme Designer.** The lightness curve of the 16 steps follows the default Fluent
   brand ramp, shifted so that step 80 is the key colour; hue fixed (OKLCH about 43 degrees); chroma highest in the
   middle and lower towards both ends, clipped to sRGB. The values are tokens `--brand-10` to `--brand-160` in
   `web/ui/m365ui/static/app.css`; no other file holds a brand hex value (the static `logo.svg` for the browser tab
   repeats step 80).
3. **Alias mapping exactly as in `@fluentui/tokens` 1.0.0-alpha.24** (`lightColor.js`, `darkColor.js`), no deviation:

   | Our token | Fluent alias | Light | Dark |
   |---|---|---|---|
   | `--brand` | colorBrandBackground | 80 | 70 |
   | `--brand-hover` | colorBrandBackgroundHover | 70 | 80 |
   | `--brand-pressed` | colorBrandBackgroundPressed | 40 | 40 |
   | `--brand-soft` | colorBrandBackground2 | 160 | 20 |
   | `--link` | colorBrandForegroundLink | 70 | 100 |
   | `--link-hover` | colorBrandForegroundLinkHover | 60 | 110 |
   | `--brand-fg` | colorBrandForeground1 / colorCompoundBrandStroke | 80 | 100 |

4. **Contrast (WCAG 2.2 AA, computed from relative luminance):**

   | Pair | Light | Dark |
   |---|---|---|
   | White on `--brand` (primary button) | 5.07:1 | 6.36:1 |
   | White on `--brand-hover` | 6.36:1 | 5.07:1 |
   | `--brand-fg` on card `#ffffff` / `#292929` | 5.07:1 | 5.35:1 |
   | `--brand-fg` on page `#fafafa` / `#1f1f1f` | 4.85:1 | 6.06:1 |
   | `--link` on card / page | 6.36:1 / 6.10:1 | 5.35:1 / 6.06:1 |

   axe-core 4.10.3 finds no violation on any page, light and dark, 1280 and 390 px.
5. **Status colours stay Fluent** (`statusColorMapping`: success green, warning orange, danger cranberry; info blue).
   Status is never colour alone (ADR 0011: badge = icon + text + colour), and the brand appears on actions, links and
   accents, not on status badges.
6. **Minimal polish, only where Fluent has the state:** the primary button gets the Fluent pressed state
   (`--brand-pressed`); link hover follows `colorBrandForegroundLinkHover`; the logo takes the brand colour.
   Nothing else changes (radius, spacing, type, components).

## Consequences

- A new brand colour is one ramp of 16 values plus step 80 in `logo.svg`; pages and templates stay as they are.
- The contrast numbers above must be checked again when the ramp changes; axe runs with the UI screenshots.
