# 0017. The web interface uses a warm orange brand ramp

Status: Accepted (2026-11-08, issue #81, decided with the owner). Supersedes the brand colour of ADR 0011 point 1
(the blue `brandWeb` ramp of the Fluent web themes); everything else in ADR 0011 stays.

## Context

ADR 0011 took all colours from the Fluent 2 web themes, including the blue brand ramp. Every Fluent app looks the
same in that blue; the owner wants this toolkit to be recognisable at a glance. Fluent 2 is built for this: a theme
is generated from 16 brand variants (`BrandVariants`, steps 10 to 160) and the alias tokens of `webLightTheme` and
`webDarkTheme` are derived from them. Changing the brand therefore means changing one ramp, not the pages.

## Decision

1. **Key colour `#c4500e` (warm burnt orange) at step 80.** Step 80 is the background of the primary button in the
   light theme, so it must carry white text at WCAG AA: 4.67:1. A lighter, brighter orange (for example `#e8590c`,
   3.58:1) fails that. The hue (OKLCH about 44 degrees) is warm but stays clear of red (danger).
2. **Ramp built like the Fluent Theme Designer.** The lightness curve of the 16 steps follows the default Fluent
   brand ramp, shifted so that step 80 is the key colour; hue fixed; chroma highest in the middle and lower towards
   both ends, clipped to sRGB. The values are tokens `--brand-10` to `--brand-160` in `web/ui/m365ui/static/app.css`;
   no other file holds a brand hex value (the static `logo.svg` for the browser tab repeats step 80).
3. **Alias mapping as in `@fluentui/tokens` 1.0.0-alpha.24** (`lightColor.js`, `darkColor.js`):

   | Our token | Fluent alias | Light | Dark |
   |---|---|---|---|
   | `--brand` | colorBrandBackground | 80 | 70 |
   | `--brand-hover` | colorBrandBackgroundHover | 70 | 80 |
   | `--brand-pressed` | colorBrandBackgroundPressed | 40 | 40 |
   | `--brand-soft` | colorBrandBackground2 | 160 | 20 |
   | `--link` | colorBrandForegroundLink | 70 | 100 |
   | `--link-hover` | colorBrandForegroundLinkHover | 60 | 110 |
   | `--brand-fg` | colorBrandForeground1 / colorCompoundBrandStroke | **70** (Fluent: 80) | 100 |

   One deviation: in light, brand text uses step 70, not 80. Step 80 on the page background `#fafafa` reaches only
   4.47:1, below AA for small text (eyebrow, icons with text).
4. **Contrast (WCAG 2.2 AA, computed from relative luminance):** white on `--brand` light 4.67:1, dark 5.90:1; white
   on hover light 5.90:1, dark 4.67:1; `--brand-fg` light on white 5.90:1, on `#fafafa` 5.65:1; dark `--brand-fg` on
   `#292929` 5.63:1, on `#1f1f1f` 6.38:1. axe-core 4.10.3 finds no violation on any page, light and dark, 1280 and
   390 px.
5. **Status colours stay Fluent** (`statusColorMapping`: success green, warning orange, danger cranberry; info blue).
   Warning and brand are both orange; they stay apart because status is never colour alone (ADR 0011: badge = icon +
   text + colour) and the brand appears on actions, links and accents, not on status badges.
6. **Minimal polish, only where Fluent has the state:** the primary button gets the Fluent pressed state
   (`--brand-pressed`); link hover follows `colorBrandForegroundLinkHover`; the logo takes the brand colour.
   Nothing else changes (radius, spacing, type, components).

## Consequences

- A new brand colour is one ramp of 16 values plus step 80 in `logo.svg`; pages and templates stay as they are.
- The warning orange sits close to the brand. If that proves confusing in use, the next step is to move warning to
  the Fluent `marigold` palette in a new ADR, not to change the brand.
- The contrast numbers above must be checked again when the ramp changes; axe runs with the UI screenshots.
