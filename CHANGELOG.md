# Changelog

## 1.2 — 2026-09-12

### Menu bar
- Meters are 8.05×18 pt rounded rectangles (soft corners, not pills). Used fill sits 1.2 pt inside the outline.
- Percents are whole numbers (`55%`, not `55.2%`).
- Menu-bar fill is one color by used %: light blue under 50%, yellow under 75%, orange under 90%, red at 90%+.
- The popover still uses the light-blue → yellow → orange → red gradient.

## 1.1 — 2026-09-11

### Menu bar
- Meters are iStat-style vertical capsules (5×18 pt, 1 pt outline). Fill is used % of the inner track, from the bottom.
- Icons are 16.4 pt. Grok and GPT marks are vectors; the Grok slash is the full even-odd logo, not a cropped PNG.
- Percents stay whole numbers when that is accurate, otherwise one decimal (for example `13.6%`).
- Glyphs, percents, and bars share a 20 pt row so marks are not clipped.

### Performance
- Unchanged usage no longer rewrites the extra or the snapshot cache.
- Opening the popover refreshes only if the last attempt is older than 45 seconds.
- Menu-bar drawing skips implicit animations.

### Fixes
- Grok Build glyph was missing half of the mark.
- Popover stays open on the first click and closes on a click outside.
- Settings opens a real window.

## 1.0 — 2026-09-09

First public source drop: menu-bar extra for Grok Build, Grok Bot, Claude, OpenAI, and Cursor. Sign in through the official CLIs or Cursor. MIT license. No Headroom server; credentials stay where those tools put them.
