# Lanebay design system

Lanebay uses a quiet, practical visual language for arranging active terminal work. Its palette pairs deep ink-blue and slate neutrals with a restrained teal-mint accent. Light and dark appearances are resolved through AppKit dynamic colors, so the same tokens adapt to the user's macOS appearance.

## Color

`Palette` provides canvas, surface, raised surface, border, primary/secondary/muted ink, and accent tokens. Semantic state colors are explicit and exhaustive:

| Status | Meaning | Color family |
|---|---|---|
| Running | Active work | Blue |
| Waiting for input | Input or permission required | Amber |
| Idle | Idle at a prompt | Green |
| Stopped | Intentionally stopped | Gray |
| Finished | Finished successfully | Violet |
| Error | Failed or blocked | Red |

Use status color alongside a visible non-color identifier (a distinct symbol and visible text label); accessible naming is also required. Color alone is never a status description.

### Text contrast

Color tokens are defined in sRGB. Keep text to these tested pairings: primary, secondary, or muted ink on `surface` or `raisedSurface`; selected rail text uses `accent` on `accentSoft`. Every pairing must maintain at least 4.5:1 WCAG contrast in both light and dark appearances. Do not use muted ink for decorative or essential text unless the pairing remains above that threshold. `canvas` is a layout background, not a text surface.

Essential focus and selection cues use a visible outline or system focus/selection color; borders remain decorative and cannot be the only cue. Increased-contrast appearances strengthen essential boundaries. Selection is independent from agent status: selected consoles use an accent outline, keyboard focus uses the system focus indicator, and status uses its own symbol, label, and semantic color.

## Type and spacing

UI text uses the system San Francisco family, with caption (11 pt), body (13 pt), title (16 pt), and display (24 pt) sizes. Terminal content uses the system monospaced face (SF Mono on macOS) at an adjustable 12 pt default. Spacing values sit on a 4 pt grid: 4, 8, 12, 16, 24, 32, and 48 pt. Corner radii are 6, 10, and 14 pt. Soft and raised shadows distinguish adjacent surfaces without a glow effect.

## Layout

The main board places a narrow **left icon rail** beside the canvas. Agent console cards sit on the canvas and can be arranged as the workspace grows. A **bottom command bar** spans the working area for issuing commands. Utility panels use the same surface and border tokens and can sit alongside the canvas when opened.

The rail keeps navigation available without consuming the canvas; use caption labels and allow longer labels to fit or scale modestly. The canvas gives consoles room to remain visible together; cards have a minimum width of 280 pt. Headers keep titles on one truncated line and preserve room for status and menu controls. Selected consoles have an accent outline distinct from focus and status. The bottom command bar displays its caller-supplied destination (for example, “Claude Code” or “3 selected consoles”) and disables submission when unavailable or blank. The visual treatment favors legibility and clear grouping over decorative effects.

## Components and symbols

`StatusLight` renders semantic state, `ConsoleCardChrome` supplies a terminal header and menu, `RailButton` handles compact navigation, `CommandBar` provides command entry, and `PanelContainer` frames auxiliary content. `Icon` maps Lanebay concepts to SF Symbols so symbols remain native and consistent with macOS.
