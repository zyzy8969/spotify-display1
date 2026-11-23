---
name: Spotify Display
description: The companion app for a keychain that wears your Spotify cover.
colors:
  paper: "#FFFFFF"
  art-surface: "#FBFBF9"
  ink: "#1A1A1A"
  ink-soft: "#5A5A5A"
  ink-faint: "#6B6B6B"
  spotify-green: "#2E7D32"
  display-blue: "#1565C0"
  fresh-orange: "#E65100"
  convert-violet: "#6A1B9A"
  destructive-red: "#C62828"
  ring-off: "#767676"
  rule: "#E4E4E0"
  frame-yellow: "#FFD400"
typography:
  display:
    fontFamily: "Chalkboard SE"
    fontSize: "72px"
    fontWeight: 700
  headline:
    fontFamily: "Chalkboard SE"
    fontSize: "34px"
    fontWeight: 700
  title:
    fontFamily: "Chalkboard SE"
    fontSize: "28px"
    fontWeight: 700
  title-sheet:
    fontFamily: "Chalkboard SE"
    fontSize: "26px"
    fontWeight: 700
  subtitle:
    fontFamily: "Chalkboard SE"
    fontSize: "19px"
    fontWeight: 700
  row:
    fontFamily: "Chalkboard SE"
    fontSize: "20px"
    fontWeight: 700
  button:
    fontFamily: "Chalkboard SE"
    fontSize: "19px"
    fontWeight: 700
  body:
    fontFamily: "Chalkboard SE"
    fontSize: "16px"
    fontWeight: 400
  footnote:
    fontFamily: "Chalkboard SE"
    fontSize: "14px"
    fontWeight: 400
  label:
    fontFamily: "Chalkboard SE"
    fontSize: "13px"
    fontWeight: 400
  mono:
    fontFamily: "SF Mono, ui-monospace, monospace"
    fontSize: "11px"
    fontWeight: 400
rounded:
  art: "6px"
  art-frame: "10px"
  toggle: "15px"
  button: "27px"
spacing:
  hairline-gap: "4px"
  tight: "8px"
  row-gap: "12px"
  margin: "22px"
  section-gap: "26px"
  hit-target: "44px"
components:
  button-primary:
    backgroundColor: "{colors.spotify-green}"
    textColor: "{colors.paper}"
    typography: "{typography.button}"
    rounded: "{rounded.button}"
    padding: "12px 32px"
  art-stage:
    backgroundColor: "{colors.art-surface}"
    rounded: "{rounded.art}"
  toggle-on:
    backgroundColor: "{colors.spotify-green}"
    rounded: "{rounded.toggle}"
    width: "52px"
    height: "30px"
  toggle-off:
    backgroundColor: "{colors.ring-off}"
    rounded: "{rounded.toggle}"
    width: "52px"
    height: "30px"
  tab-selected:
    textColor: "{colors.ink}"
    typography: "{typography.label}"
    height: "{spacing.hit-target}"
  tab-unselected:
    textColor: "{colors.ink-faint}"
    typography: "{typography.label}"
    height: "{spacing.hit-target}"
  status-label:
    textColor: "{colors.ink-soft}"
    typography: "{typography.label}"
---

# Design System: Spotify Display

The source of truth is code: `Theme.swift` (colour and metric tokens), `ThemeTypography.swift` (text roles), `CrayonShapes.swift` (shapes, icons, state marker), `ThemeCopy.swift` (wording). The token block above is **Crayon**, the default theme. Quiet and Keyring are written out in full below; they use the same token names with different values.

## Overview

This is the app for a digital keychain. The Spotify cover is the hero, the one big thing on the screen, drawn as the keychain shows it and replaced whole, never half-loaded. Your own photos (and GIFs, planned) are secondary actions. Everything else is small: two status dots, a thin live strip under the art, the track name, three playback marks and a one-line footer. A person opening the app for three seconds should see the cover, see that both dots are filled, and put the phone away.

There are three themes, picked in Settings. They share one layout, one set of text roles and one token vocabulary. **Crayon** (default) is a white page with hand-drawn, slightly wobbly marks in Chalkboard SE; colour lives only in the marks, never in the words. **Quiet** is near-black with system type, crisp geometry, and colour only in the two status dots and the cached strip. **Keyring** is warm paper with the keychain itself drawn around the cover, so the screen shows what is on your keys right now; it uses SF Pro, tag-style SF Mono labels, and one signal orange. A theme changes values, never structure: adding one means adding a `ThemeID` case and its tokens, not new screens.

Each theme has its own control style. **Crayon: drawn, not built.** Wobbly outlines with slight tilts, so buttons look like someone drew them. **Quiet: few and quiet.** There are no filled buttons, just small icons with tiny labels, and the picture does the talking. **Keyring: the keychain is the picture.** Controls are plain ink marks on paper with 12pt corners; the drawn device carries the character. Icons are a small in-house set drawn on a 20×20 grid in the theme's hand, not SF Symbols chrome. Every control has a target of at least 44pt.

**Key Characteristics:**
- One hero: the square cover, centred, at the largest width the screen allows (inside the drawn keychain on Keyring).
- Status through filled dots vs hollow rings, never through colour alone.
- Three themes, one structure; all values come from `@Environment(\.theme)`.
- Hand-drawn wobble and the keychain housing are tokens (`wobble`, `housing`), not separate component sets.
- Text scales with Dynamic Type and honours Bold Text in every theme.

## Colors

Near-black words on white paper, with a handful of crayon colours that only appear in marks that carry meaning.

### Primary
- **Crayon Spotify Green** (spotify-green): the Spotify status dot, the "on" toggle fill and the primary button (Connect Spotify), with white text at 5.1:1. Darkened from the mockup's #2BB24C, which fails contrast at 2.8:1.
- **Keychain Blue** (display-blue): anything about the keychain itself: the Display status dot, a cached cover's strip and marker, the selected-tab marker, the slider tint and the back chevron.

### Secondary
- **Fresh Orange** (fresh-orange): a cover sent fresh over Bluetooth, i.e. the strip filling during a send and the hollow "fresh" marker. Marks only (3.8:1), never text.
- **Convert Violet** (convert-violet): the "colours" (convert) phase bar on Stats. Its only job is telling phases apart.

### Tertiary
- **Pencil-box Yellow** (frame-yellow): Crayon's coloured-in outline offset behind the cover. Purely decorative.
- **Crossing-out Red** (destructive-red): destructive actions such as emptying the cache.

### Neutral
- **Paper** (paper): the page.
- **Art Paper** (art-surface): the warm off-white square behind the cover before it loads.
- **Pencil Ink** (ink): titles and body, 17.4:1.
- **Soft Graphite** (ink-soft): artist, secondary rows, connected-dot labels, 6.9:1.
- **Faint Graphite** (ink-faint): unselected tabs, the live mono line, 5.3:1.
- **Eraser Grey** (ring-off): hollow "off" rings, the off toggle, the dashed "preparing" strip. The lightest grey that still clears 3:1 for a state mark.
- **Ruled Line** (rule): dividers and the empty strip track. Decorative only.

### Quiet and Keyring values

| Token | Quiet | Keyring |
|---|---|---|
| background / art-surface | #0C0C0C / #141414 | #F4F1EA warm paper / #2A2925 dark screen |
| ink / ink-soft / ink-faint | #FFFFFF / #9B9B9B / #8A8A8A | #1C1B19 / #57554F / #67645D |
| spotify | #34C759 | #2E7D32 |
| display (the keychain) | #4FC3F7 | #C2410C signal orange |
| fresh / accent | #FFFFFF / #4FC3F7 | #1C1B19 / #C2410C |
| destructive | #FFFFFF (an alert guards it) | #B3261E |
| ring-off / toggle-off | #8A8A8A / #6E6E6E | #7D7A72 / #7D7A72 |
| primary fill / on primary | #FFFFFF / #0C0C0C | #1C1B19 / #F4F1EA |
| rule | #1E1E1E | #DDD8CC |
| housing body / edge / ring | none | #1C1B19 / #3A3833 / #9A968C |

Quiet's and Keyring's phase bars are a single colour (white / ink). Keyring's contrast against #F4F1EA: ink 15.3:1, ink-soft 6.6:1, ink-faint 5.2:1, spotify 4.55:1, signal orange 4.6:1, destructive 5.8:1, ring-off 3.8:1. The housing ring (2.6:1) is decorative and carries no state.

### Named Rules
**The Colour-Means-Something Rule.** Only state marks (dots, strip, toggles, phase bars) and the primary button are coloured. Words are ink, soft or faint. A colour that only decorates is listed in `artPalette`/`doodle`/`rule`/`housing` and carries no meaning.

**The Contrast Floor Rule.** Every text token clears 4.5:1 against its theme's background, and every state-carrying mark clears 3:1. Where a mockup colour failed, the token was darkened and the mockup value noted in a `Theme.swift` comment. Keep doing that.

**The One Signal Rule (Keyring).** Keyring has exactly one non-ink colour besides Spotify green: #C2410C, meaning "the keychain" (the Display dot, a cached cover, the slider). A cover sent fresh is plain ink with a hollow marker. Nothing else is tinted.

## Typography

**Display Font:** Chalkboard SE (Crayon), SF Pro system (Quiet, Keyring)
**Body Font:** same family as display in each theme
**Label/Mono Font:** SF Mono: live/debug detail in every theme, and Keyring's tag-style status and number labels

**Character:** Crayon is bold, round and handwritten, like labels on a lunchbox. Quiet is plain system type with light-weight big numbers. Keyring reads like the device's printed tag: SF Pro for words, short uppercase SF Mono labels for status, counts and timings ("KEYCHAIN LINKED", "47 ON YOUR KEYS").

### Hierarchy
Sizes come from 390×844 artboards in points and scale with Dynamic Type through each role's anchor style. The minimum on-screen size is 11pt.

- **Display / statBig** (Crayon 72 bold · Quiet 64 light · Keyring 60 semibold mono): the big transfer time on Stats.
- **Headline / heading** (34 bold · 28 semibold · 30 bold): signed-out headline "what's playing, on your keys".
- **Title / trackTitle** (28 bold · 22 semibold · 22 semibold): the song name under the cover, centred, max 2 lines.
- **Title-sheet** (26 bold · 20 semibold · 20 semibold): sheet titles (Settings, Transitions).
- **Subtitle / trackArtist** (19 bold · 15 · 15): the artist, in ink-soft.
- **Row / rowValue** (20/18 bold · 15/13 · 17/15): Settings rows and their values.
- **Button** (19 bold · 17 semibold · 17 semibold): primary button label.
- **Body / lead** (16 · 15 · 15): supporting sentences.
- **Footnote / footer** (14 / 17 bold · 13 / 12 · 13 / 12 mono caps): Now Playing footer status line and its secondary line.
- **Label / statusLabel, eyebrow** (13 · 12 · 11 mono caps +0.8 tracking): status-dot names, tabs, section labels.
- **Mono** (11, `.caption2` monospaced): the live pipeline line and debug values only.

### Named Rules
**The Role-Not-Size Rule.** Views ask for a `TextRole` via `.themeText(_:)` and never set a font, size, weight or case directly. A new kind of text gets a new role mapped in all three themes.

**The Crayon Lowercase Rule.** Crayon copy is lowercase and playful ("empty it", "keychain ready"); Quiet and Keyring use sentence case. Case comes from `ThemeCopy.swift`, not from text transforms, except Keyring's tag labels, which uppercase via the role.

**The Mono-Is-Data Rule (Keyring).** SF Mono is for status, counts and timings only. Song titles, artists, rows and sentences stay in SF Pro.

## Layout

A single centred column on a full-bleed background, with horizontal margins from the `margin` token (22pt in all three themes). From top to bottom, Now Playing holds: the status header (two dots on the left, photo and gear icons on the right), the cover as a square sized to the available width, the live strip (10–20pt below, same width as the art slot), track info, playback controls (34pt apart), and the footer. Spacers spread these out to fill the screen.

On Keyring the art slot holds the drawn keychain: a case 92% of the slot's width, the square cover inside it with an 8.5% bezel and a deeper bottom bezel, and a key ring above. The cover is therefore about 77% of the slot's width, and the slot is a little taller than it is wide.

`FitOrScroll` lays content out to fill the screen and falls back to scrolling only when it cannot fit, at accessibility text sizes or in short landscape. Settings is a scrolling sheet with a 44pt close chevron, 26pt between sections and 12pt inside them. Every tappable thing has a frame of at least 44×44pt; the play button gets 56pt. At accessibility text sizes the status-dot names hide, and the dots keep their spoken labels.

### Named Rules
**The Cover-Width Rule.** The live strip, track info and footer all align to the art slot's width. Nothing on Now Playing is wider than the slot except the header.

## Elevation & Depth

Mostly flat. The only lifted object is the cover (or, on Keyring, the keychain holding it). Crayon gives the cover a soft ink shadow (14% ink, 13pt blur, 10pt down) plus a yellow hand-drawn outline offset 6×7pt behind it, "like a shadow someone coloured in". Quiet uses a deep black shadow (80%, 22pt blur, 18pt down) so the art floats on near-black. Keyring puts the shadow on the keychain case (22% case colour, 14pt blur, 10pt down) and none on the cover, which sits flush in its screen. Sheets use the system sheet presentation.

### Named Rules
**The Only-the-Cover-Floats Rule.** No cards, no shadowed buttons, no layered panels. If something besides the cover (or Keyring's keychain) needs separation, use a `ThemedDivider` or spacing.

## Shapes

Corners are soft everywhere: 6pt cover and 27pt capsule button in Crayon and Quiet; Keyring uses a 4pt screen corner, a case with corners 11% of its width, and 12pt buttons. Crayon's shapes come from the seeded `Wobble` family (`WobbleLine`, `WobbleEllipse`, `WobbleRoundedRect`, `ScribbleShape`). Their wobble is deterministic per seed, so a mark never shimmers between renders. `ThemedStroke` adds the waxy look: a dotted paper-coloured line over any stroke of 2pt or more. With `wobble` 0, the same shapes draw crisp. Line weights scale with the theme: icon stroke 2.4 / 1.4 / 1.6, strip 6 / 2 / 3.

## Components

### Buttons
- **Shape:** Crayon a wobbly rounded rect with a 27pt radius and a faint dotted highlight; Quiet a clean capsule; Keyring a 12pt rounded rectangle.
- **Primary:** `primaryFill` with `onPrimary` text, padded 12pt × 32pt. It only appears for Connect Spotify / Sign in again.
- **Icon buttons:** `GlyphIcon` in `control`/`controlStrong` inside a ≥44pt plain button. They have no background, no pressed chrome and no tint.
- **Destructive:** text in `destructive`, always behind a confirmation alert.

### State Marker and Status Dot
- **The app's one non-colour state cue:** a filled dot means yes (connected, cached), and a hollow ring means no, or "the other kind" (not connected, sent fresh).
- **Status dot:** an 11pt marker plus a name in `statusLabel`, spoken as "Spotify connected" / "Display not connected".

### Live Strip (signature)
A horizontal line under the art, as wide as the art slot, that shows the send pipeline. It is a decorative empty track at idle; dashed in ring-off while preparing; a fresh-coloured fill that trims from 0 to 100% while sending; solid display colour with a filled marker when cached; solid fresh colour with a hollow marker when sent fresh. Crayon draws it 6pt thick with a gentle bow, Quiet 2pt and Keyring 3pt, both ruler-straight.

### Art Stage (signature)
The cover in its theme frame: art surface, corner radius, border or shadow, and Crayon's offset doodle frame. A new cover replaces the old one in one piece. When the keychain announced its transition, the app replays an approximation of it; otherwise it crossfades over 0.4s. With Reduce Motion it simply cuts. Before any cover arrives it shows a placeholder: scribbles (Crayon) or filled rings (Quiet, Keyring).

### Keychain Housing (Keyring signature)
`KeychainHousing` draws the keychain around the art stage: a dark rounded case with a thin lighter edge, a square screen like the board's 240×240 panel, a deeper bottom bezel, a metal key ring and its link above. The screen shows what the board shows, because the app only swaps in a new cover once the board confirms it drew it. The housing is decorative; the art's accessibility label describes the picture. Sizes live in `KeychainMetrics`.

### Toggles and Sliders
- **Toggle:** a custom 52×30pt track, filled `toggleOnFill` with a `toggleOnKnob` knob when on, and a `toggleOff` outline when off. Wobbly in Crayon. Each row is at least 44pt tall.
- **Slider:** the system slider tinted `sliderTint`.

### Navigation
- **Tabs (Stats on):** a row of text tabs, each a state marker plus a `statusLabel`; the selected tab is ink with a filled display-colour marker, and unselected tabs are ink-faint with a ring.
- **Sheets:** Settings and Transitions open as sheets with a `SheetHeader` (chevron-down close and title). Swipe down also dismisses.

### Stats Breakdown
Per-phase timing as bars: thick hand-drawn bars, one colour per phase (Crayon); thin flat bars on a dim track (Quiet, Keyring). A dot-leader style (`StatsStyle.dotLeaders`) also exists in code, but no current theme uses it.

## Do's and Don'ts

### Do:
- **Do** read every colour and metric from `@Environment(\.theme)`, and add a token to all three themes when a screen needs a new one.
- **Do** pair every coloured state with a filled-vs-hollow `StateMarker` or a dash pattern, so it reads without colour.
- **Do** keep text tokens at 4.5:1 or better and state marks at 3:1 or better, noting any mockup value you darken in a comment.
- **Do** give every control a hit area of at least 44×44pt while keeping its visible mark small.
- **Do** route all wording through `ThemeCopy.swift`: lowercase for Crayon, sentence case for Quiet and Keyring.

### Don't:
- **Don't** branch on the theme name for colour or layout; a theme changes token values, not view structure.
- **Don't** set fonts directly; use `.themeText(_:)` roles.
- **Don't** draw a cover partially, or show progress on top of the art. Progress lives in the live strip.
- **Don't** show a cached or drawn state before the keychain confirms it.
- **Don't** add cards, shadows or tinted panels: only the cover (or Keyring's keychain) floats.
- **Don't** use colour on words in Crayon; colour belongs to the marks.
- **Don't** add a second accent to Keyring beyond the one signal orange.
