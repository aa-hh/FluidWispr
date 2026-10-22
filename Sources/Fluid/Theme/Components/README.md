# Shared controls

The `Record` components in `Theme/Record/` are the only shared controls. They
follow `DESIGN.md` and the Figma board "3. Components: The record (shared)".

## Tokens

- `FWColor`: every colour, each with its Light and Dark value. `.recordNearBlack()`
  puts a floating surface beside the pill on the pill's near-black in both appearances.
- `FWMetric`: spacing, control heights, the 168 pt margin, radii, line widths, and
  `.recordFloat()` for the one shadow.
- `FWMotion`: the pill's durations and its size and collapse springs;
  `FWMotion.motion(reduced:)` gives the 130 ms crossfade under Reduce Motion.
- `FWType`: the nine `Record/` text styles; apply one with `.recordText(_:)`, which
  also turns on tabular figures.

Use these values and nothing else for colour, spacing, type and timing in new code.

## Buttons

The app theme installs `RecordButtonStyle(kind: .secondary, size: 28)` as the
default, so unstyled buttons, sheets included, become Secondary 28 capsules. Set
`.buttonStyle(RecordButtonStyle(kind:size:))` for Primary, Destructive or Quiet,
or for sizes 20 and 36. One Primary per view.

Native `ToolbarItemGroup` buttons must explicitly use `.buttonStyle(.automatic)`
to keep macOS toolbar grouping.

## Screens

Screens compose `RecordLine`, `RecordSectionLine`, `RecordHeader` and
`RecordSidebar` with the controls (`RecordSwitch`, `RecordPopUp`, `RecordField`,
`RecordSearch`, `RecordKeycap`, `RecordMark` and the rest). A screen never draws
its own capsules, outlines, hover fills, hairlines or focus rings; change the shared
component to change the design everywhere.

`RecordingPillPreview` shows the real pill at real size; never draw a stand-in.

## Legacy

`FluidDropdown`, `ThemedCard`, `FluidOutlinedButtonStyle`, the glass controls
(`FluidGlassControls`, `GlassButtonStyle`, `GlassToggleStyle`) and the styles in
`NativeButtonStyles.swift` remain only for screens not yet rebuilt. Do not use
them in new code.
