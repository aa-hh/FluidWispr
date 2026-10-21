---
name: FluidWispr
description: The record. A quiet Mac window that keeps every dictation as a ruled, numbered record, built from the recording pill.
colors:
  surface-window: "#FCFCFB"
  surface-window-dark: "#0E0F13"
  surface-sidebar: "#F2F2F3"
  surface-sidebar-dark: "#0A0B0E"
  surface-selected: "#E4E4E8"
  surface-selected-dark: "#1C1D23"
  surface-hover: "#F6F6F7"
  surface-hover-dark: "#14151A"
  surface-sunken: "#F0F0F2"
  surface-sunken-dark: "#17181D"
  surface-raised: "#FFFFFF"
  surface-raised-dark: "#26272E"
  line-rule: "#E6E6EA"
  line-rule-dark: "#22232A"
  line-margin: "#D3D3D9"
  line-margin-dark: "#34353E"
  line-strong: "#C2C3CA"
  line-strong-dark: "#34353D"
  line-spoken: "#0E0F1359"
  line-spoken-dark: "#ECECEF59"
  text-primary: "#0E0F13"
  text-primary-dark: "#ECECEF"
  text-secondary: "#5E5F68"
  text-secondary-dark: "#9A9BA4"
  text-tertiary: "#6C6D76"
  text-tertiary-dark: "#80818A"
  action-primary: "#0E0F13"
  action-primary-dark: "#ECECEF"
  action-on-primary: "#F4F4F5"
  action-on-primary-dark: "#0E0F13"
  state-done: "#11804A"
  state-done-dark: "#5BE39B"
  state-attention: "#975A00"
  state-attention-dark: "#FFC24D"
  state-retry: "#B4531B"
  state-retry-dark: "#FF9A5C"
  state-destructive: "#C8322F"
  state-destructive-dark: "#FF6B66"
  live-ivory: "#FFE4B8"
  pill-body: "#0E0F13"
typography:
  title:
    fontFamily: "SF Pro"
    fontSize: "22pt"
    fontWeight: 600
    lineHeight: "28pt"
  section:
    fontFamily: "SF Pro"
    fontSize: "15pt"
    fontWeight: 600
    lineHeight: "20pt"
  transcript:
    fontFamily: "SF Pro"
    fontSize: "15pt"
    fontWeight: 400
    lineHeight: "24pt"
  body:
    fontFamily: "SF Pro"
    fontSize: "13pt"
    fontWeight: 400
    lineHeight: "18pt"
  label:
    fontFamily: "SF Pro"
    fontSize: "13pt"
    fontWeight: 500
    lineHeight: "18pt"
  detail:
    fontFamily: "SF Pro"
    fontSize: "12pt"
    fontWeight: 400
    lineHeight: "16pt"
  detail-strong:
    fontFamily: "SF Pro"
    fontSize: "12pt"
    fontWeight: 500
    lineHeight: "16pt"
  small:
    fontFamily: "SF Pro"
    fontSize: "11pt"
    fontWeight: 400
    lineHeight: "14pt"
  small-strong:
    fontFamily: "SF Pro"
    fontSize: "11pt"
    fontWeight: 500
    lineHeight: "14pt"
rounded:
  inner: "8pt"
  container: "14pt"
  window: "16pt"
  capsule: "999pt"
spacing:
  "1": "2pt"
  "2": "4pt"
  "3": "8pt"
  "4": "12pt"
  "5": "16pt"
  "6": "20pt"
  "7": "24pt"
  "8": "32pt"
  "9": "40pt"
  "10": "56pt"
components:
  button-primary:
    backgroundColor: "{colors.action-primary}"
    textColor: "{colors.action-on-primary}"
    typography: "{typography.label}"
    rounded: "{rounded.capsule}"
    height: "28pt"
    padding: "0 12pt"
  button-primary-dark:
    backgroundColor: "{colors.action-primary-dark}"
    textColor: "{colors.action-on-primary-dark}"
    typography: "{typography.label}"
    rounded: "{rounded.capsule}"
    height: "28pt"
    padding: "0 12pt"
  button-secondary:
    backgroundColor: "{colors.surface-sunken}"
    textColor: "{colors.text-primary}"
    typography: "{typography.label}"
    rounded: "{rounded.capsule}"
    height: "28pt"
    padding: "0 12pt"
  button-small:
    typography: "{typography.detail-strong}"
    rounded: "{rounded.capsule}"
    height: "20pt"
    padding: "0 8pt"
  button-large:
    typography: "{typography.label}"
    rounded: "{rounded.capsule}"
    height: "36pt"
    padding: "0 16pt"
  record-row:
    backgroundColor: "{colors.surface-window}"
    textColor: "{colors.text-primary}"
    typography: "{typography.transcript}"
    height: "44pt"
  sidebar:
    backgroundColor: "{colors.surface-sidebar}"
    textColor: "{colors.text-primary}"
    typography: "{typography.body}"
    width: "184pt"
  sidebar-item-selected:
    backgroundColor: "{colors.surface-selected}"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.inner}"
  text-field:
    backgroundColor: "{colors.surface-raised}"
    textColor: "{colors.text-primary}"
    typography: "{typography.body}"
    rounded: "{rounded.inner}"
    height: "28pt"
---

# Design System: FluidWispr

Figma is the source of truth: file "FluidWispr", page "Foundations: The record" (board 44:2 holds the locked foundations, board 40:2 the Settings and History examples). The variable collections Color, Dimension, Motion and Type there carry the Swift names used in code (`FWColor.*`, `FWMetric.*`, `FWMotion.*`, `FWType.*`). This file follows them; if the two differ, Figma wins and this file gets fixed.

Colours come in pairs. A key ending in `-dark` is the Dark appearance value of the key without it. The app follows the system appearance.

## Overview

**Creative North Star: "The record"**

The main window reads like a transcript sheet. A fixed left margin, set off by a double hairline, holds the details: time, state, app, number. Everything to the right of the margin is the person's own words or the controls that act on them. History is a numbered record for each day, so dictation number 142 is always number 142. Settings are shown at real size, so the pill size picker shows the real pill and the microphone row shows the live rim.

The window is still. Nothing moves or glows unless the microphone is live, because ivory light already means "listening" in the pill and must keep meaning only that. Colour is for state, and state is rare: mint when text landed, amber when something needs the person, soft orange when a retry failed, red only for deleting. Density is a Mac preferences window, not a dashboard: rows and rules, no cards.

The one honest risk is that legal-record grammar tips into bureaucratic. The margin must stay quiet: small grey details, tabular figures, no labels shouting their own names.

**Key Characteristics:**
- Ruled sheet with one fixed margin (168 pt) behind a double hairline.
- The person's words are the loudest thing on screen (Transcript, 15 on 24).
- Ivory appears only where the microphone is live.
- Capsules for anything pressed, at the pill's own heights (20, 28, 36).
- Motion reuses the pill's timings and springs; nothing new is invented for the window.

## Colors

Graphite neutrals with the pill body's slightly cool cast, a single ink for actions, and four state colours taken from the pill.

### Primary
- **Ink** (#0E0F13 Light, #ECECEF Dark): primary text and the one primary action per view. In Light the primary capsule is the pill body colour with a near-white label; in Dark it flips to bone with a near-black label.

### Neutral
- **Window paper** (#FCFCFB / #0E0F13): the window and the record sheet. Dark mode uses the pill body itself.
- **Sidebar** (#F2F2F3 / #0A0B0E): the source list.
- **Selected row** (#E4E4E8 / #1C1D23) and **Hover** (#F6F6F7 / #14151A).
- **Sunken** (#F0F0F2 / #17181D): secondary capsules, inset wells such as the waiting note.
- **Raised** (#FFFFFF / #26272E): text fields and floating panels only.
- **Rule** (#E6E6EA / #22232A): the hairline between records.
- **Margin rule** (#D3D3D9 / #34353E): the double hairline at the margin.
- **Strong line** (#C2C3CA / #34353D): field outlines and control borders.
- **Spoken line** (ink at 35%): the hairline that shows how long someone spoke.
- **Secondary text** (#5E5F68 / #9A9BA4) and **Tertiary text** (#6C6D76 / #80818A): margin details, captions, running times. Both pass 4.5:1 on their window colour.

### State
- **Pasted mint** (#11804A / #5BE39B): text landed. A tick in the margin, the pill's paste flash.
- **Needs you amber** (#975A00 / #FFC24D): a waiting dictation or a mic or permission problem.
- **Retry failed orange** (#B4531B / #FF9A5C): a retry that did not land.
- **Delete red** (#C8322F / #FF6B66): destructive actions only.
- **Live ivory** (#FFE4B8, both appearances): the moving rim of the pill and the live microphone level. Nothing else.

### Named Rules
**The Ivory Means Live Rule.** Ivory is shown only while the microphone is live: the pill rim, the microphone test in Settings, a permission try-it field. Never as an accent, a highlight, a selection or a brand colour.

**The Colour Is For State Rule.** Mint, amber, orange and red mark state, never decoration or category. A screen at rest is graphite and ink.

## Typography

**Font:** SF Pro, the system font, at Apple's Mac sizes. No second family, no rounded or serif variant.

**Character:** plain system type, set slightly roomier for transcripts so that someone's own words read like writing, not like a list.

### Hierarchy
- **Title** (Semibold 22 on 28): the view name, once per view.
- **Section** (Semibold 15 on 20): a group heading in Settings or a day heading in History.
- **Transcript** (Regular 15 on 24): the person's dictated words. Keep lines to about 70 characters.
- **Body** (Regular 13 on 18): setting descriptions, notes, sidebar items.
- **Label** (Medium 13 on 18): button labels and setting names.
- **Detail** (Regular 12 on 16) and **Detail strong** (Medium 12 on 16): margin details such as time and app.
- **Small** (Regular 11 on 14) and **Small strong** (Medium 11 on 14): record numbers, running times, footnotes.

### Named Rules
**The Your Words Are Loudest Rule.** Transcript text is the largest regular text on a record screen. Details in the margin are smaller and grey.

**The Honest Numbers Rule.** Times, counts and durations use tabular figures. Running times sit beside each record and day totals sit on each day heading.

## Layout

A standard Mac window: a 184 pt sidebar, then the content. The sidebar has two groups, "Record" (Today, Yesterday, Earlier, each with a count) and "App" (Dictionary, Settings).

The content is a ruled sheet. A 168 pt margin sits on the left behind a double hairline (two 1 pt lines, 2 pt apart, in the margin rule colour). Details go in the margin; words and controls go to the right of it. The margin width does not change with the window. Records and setting rows are separated by single hairlines in the rule colour and are at least 44 pt tall.

Each record shows a spoken-length hairline under the transcript: 5 pt per second spoken, in the spoken line colour, with the running time beside it ("0:07").

Spacing steps are 2, 4, 8, 12, 16, 20, 24, 32, 40 and 56 pt. Row padding is 12 pt vertical; the gap between margin and content is 24 pt.

## Elevation & Depth

Flat. Depth comes from rules and the sidebar tone, not shadows. The only shadow is **Float** (y 8, blur 24, black at 16%), used on things that float above the window: the pill, popovers, the paste-failed bubble.

### Named Rules
**The Ruled, Not Boxed Rule.** No cards and no boxed sections. Group with hairlines and section headings.

## Shapes

Capsules for anything pressed; rounded rectangles for anything that holds. Inner elements (fields, selected rows, wells) use 8 pt corners, containers 14 pt, the window 16 pt. Control heights match the pill sizes: 20 pt small, 28 pt regular, 36 pt large.

## Components

### Buttons
- **Shape:** capsule, at 20, 28 or 36 pt high.
- **Primary:** ink fill with the on-primary label (Label style), 12 pt side padding at 28 pt high. One primary per view.
- **Secondary:** sunken fill with ink label.
- **Hover / Focus:** hover darkens the fill one step over 130 ms; focus is the system focus ring at 2 pt.
- **Destructive:** text in delete red, never a red fill.

### Record row
- **Margin:** time (Detail strong), state mark (mint tick pasted, grey ring waiting, amber ring raw text), app name (Detail), "No. 142" (Small).
- **Content:** transcript, then the spoken-length hairline and running time.
- **Waiting record:** a sunken note under the transcript, "Not pasted yet", with Paste (primary, small) and Copy (secondary, small).
- **Raw text record:** an amber note saying cleanup was skipped and the raw words were kept.

### Inputs / Fields
- **Style:** raised fill, 1 pt strong-line outline, 8 pt corners, 28 pt high, Body text.
- **Focus:** system focus ring.
- **Error:** amber outline and an amber note below; never red unless something will be deleted.

### Navigation
- **Sidebar:** sidebar fill, Body text, counts in Small tertiary with tabular figures. Selected item uses the selected fill with 8 pt corners.

### Settings rows
Margin holds the setting name (Label) and one line of help (Detail). The control sits to the right, shown at real size: the pill size choice shows real S, M and L pills; the microphone row shows the live rim while the test runs.

### Recording pill (signature)
Approved and fixed. Spec in `/mnt/project-files/design/pill-rim/README.md` and Figma page "Recording pill: Rim (approved)". The window borrows its colours, heights and timings and never restyles it.

## Motion

Timings come from the pill: snap 130 ms, exit 150 ms, enter 180 ms, hold 260 ms, collapse 340 ms. Springs: size (response 0.512, damping 0.816) and collapse (response 0.45, damping 0.816). A new record arrives on the size spring. With Reduce Motion on, every move becomes a 130 ms crossfade; colour and brightness still carry meaning. Light pulses stay at least 340 ms apart.

## Do's and Don'ts

### Do:
- **Do** keep the 168 pt margin fixed and quiet: details only, grey, small.
- **Do** use one primary capsule per view.
- **Do** show settings at real size where it helps (pill sizes, microphone level).
- **Do** use tabular figures for times, counts and durations.
- **Do** check every text colour against 4.5:1 in both appearances.

### Don't:
- **Don't** use ivory anywhere the microphone is not live.
- **Don't** use cards, boxed sections or drop shadows on things that sit in the window.
- **Don't** add waveforms, bars, dots or particles; the pill rim is the only living element.
- **Don't** use colour for category or decoration.
- **Don't** add a second typeface or SF Pro Rounded.
- **Don't** invent new timings; reuse the pill's.
