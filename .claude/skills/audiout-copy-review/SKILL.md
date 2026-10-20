---
name: audiout-copy-review
description: Review user-visible copy on Audiout screens — the Mac app, the iPhone companion, and the marketing website. Use when asked to review, audit, or fix on-screen text, microcopy, error messages, empty states, or marketing copy in any Audiout repo. Covers terminology consistency, AI-slop prose patterns, and UI-copy structure.
---

# Audiout copy review

Rules for reviewing every user-visible string on Audiout's surfaces: the Mac
app, the iPhone companion (audiout-remote), and the marketing website. Apply
all three rule sets to every finding: terminology, prose, and UI structure.

## What counts as user-visible

Labels, buttons, section headers, empty states, toasts, banners, alerts,
permission prompts (including Info.plist usage descriptions), settings rows,
onboarding text, accessibility labels, error text that renders in UI, and
every sentence on the website. Not: log messages, identifiers, SF Symbol
names, wire-protocol constants.

## Output format

Every finding, from every reviewer, in this shape — findings from different
agents must merge into one list without reformatting:

```
[severity] surface — file:line (or page/section for the website)
  now:  "the exact current string"
  rule: which rule below it breaks
  fix:  "the suggested replacement"
```

Severity: **error** (wrong term, blames the user, dead-end error message,
factually wrong), **warn** (slop pattern, inconsistent verb, vague), **nit**
(style polish). Rank errors first. One finding per string; if a string breaks
several rules, cite the worst and fix them all in the replacement.

## 1. Terminology

One concept, one word, everywhere — app copy, website, and App Store text use
the same term. Flag any synonym for a canonical term below, and flag any new
concept the copy names without adding it here.

| Concept | Use | Never |
| --- | --- | --- |
| Audio endpoint | speaker | device (code-only) |
| Saved speaker set | scene (Scene/Scenes as a label) | group, Groups |
| The controlled Mac | your Mac / the Mac | server, host, companion |
| The Mac app | Audiout on your Mac | "the Audiout app running on a Mac" and variants |
| The phone | this iPhone | phone, device |
| Per-app routing | route, routing | redirect |
| Master output | Main Audio | Main Out, output, master |
| Main Audio's no-scene value | Selected Speakers | Selected Devices |
| Speaker states | Playing / Ready / Unavailable | armed, selected |
| Live scene badge | Playing | "Playing now", Live, Active group |
| Phone↔Mac states | Not connected / Connecting… / Waiting for approval… / Connected / Disconnected | Live, "No Mac connected" as a status |
| Loudness | volume | level |
| Retry action | Try again | Retry (as button label) |
| Add action | Add \<thing\> (e.g. "Add scene") | New \<thing\>, Create |
| Pinned speakers | Favourites (add to / remove from) | pin |
| The demo | Demo / demo mode | Demo system, simulated Mac (as a name) |
| Bluetooth timing feature | align (verb), Sync (the control), sync offset (the value) | calibrate, sync calibration, probe, alignment (all code-only) |
| The shared-clock helper | Speaker Sync | Sync, PTP, the helper |
| The network | Wi-Fi network | your network, this network, local network (except quoting iOS's "Local Network" permission) |

Closed 2026-09-05 (decision D4): the iPhone app is named **Audiout Remote**.
Its subtitle is "The remote that tunes your speakers." Flag any surviving
"Audiout" (bare) reference to the phone app as drift against this name.

All three surfaces were harvested and reconciled on 2026-09-05, and the
Master output, Per-app routing and Saved speaker set rows are Alec's explicit
decisions from that date — do not re-litigate them in a review; flag drift
against them instead. The Mac app owns some strings the iPhone renders
verbatim (refusal reasons, takeover status), so a wrong term there must be
fixed in the Mac repo.

Alec settled the remaining conflicts on 2026-09-05: the live-scene badge
becomes "Playing" (the apps move, not the table); the add action is
"Add scene" (the apps move); the Bluetooth timing feature keeps
align / Sync / sync offset, with "Speaker Sync" reserved for the shared-clock
helper. Sentence case applies to every label except the standard macOS menu
items Apple itself title-cases (About…, Check for Updates…, Preferences…).

## 2. Prose rules

Full force on the website and any multi-sentence in-app copy (onboarding,
empty states, permission explanations). Button labels and one-word strings are
mostly exempt — check them against sections 1 and 3 instead.

**Concreteness.** Names, numbers, mechanisms. "Plays to every speaker within
20 ms of each other," not "perfectly in sync." If a sentence could sit
unchanged on any audio product's website, cut it or make it about Audiout.

**Banned words:** delve, foster, leverage, utilize, facilitate, empower,
streamline, robust, cutting-edge, game changer, seamless, effortless,
tapestry, realm, multifaceted, meticulous, intricate, paramount,
transformative, elevate, embark, harness, ever-evolving, supercharge.

**Patterns to flag:**

- Binary contrasts: "It's not X, it's Y." Say Y.
- Throat-clearing: "Here's the thing," "Let's dive in," "The best part:".
- Colon reveals: a noun phrase, a colon, a dramatic finish. Plain sentence.
- Importance puffery: "plays a vital role," "marks a pivotal moment."
- Trailing -ing analysis: "…, ensuring a premium experience." State the
  actual consequence or cut.
- Weasel attribution: "audiophiles agree," "studies show." Name it or cut it.
- Fake-profound kickers and recap endings. End on the last concrete point.
- Rhetorical setups: "What if I told you…", self-answered questions.
- Em dashes: none in UI strings; at most one or two per website page.
- Formatting slop: emoji in headings, bold mid-sentence, a header over a
  two-sentence section.

## 3. UI-copy rules

**Errors say three things:** what happened, (optionally) why, and what to do
next. An error with no next action is a dead end — flag it as **error**
severity. Offer a real verb: Try again, Open Settings, Diagnose. Error codes
go behind "details", never in the headline. Never blame the user — "That
didn't connect," not "You entered an invalid address."

**Empty states point forward.** Every empty state says what will appear here
and the one action that makes it appear. "No speakers yet — open Audiout on
your Mac" beats "No data."

**Consistent action verbs.** Pick one verb per action and reuse it: Connect,
Disconnect, Add, Remove, Try again. Flag drift (Add/Create/New for the same
action, Try again/Retry across visible and VoiceOver text). No generic
OK/Cancel when a specific verb fits: "Delete group" / "Cancel" is fine;
"OK" alone is not.

**Warmth is capped.** Copy is roughly 80% information, 20% warmth; first-run,
empty states, failures, and long waits may go 70/30. At most half a sentence
of warmth, always followed by the next step. No pep talks, no
over-personifying the app.

**Long waits give an out.** Anything over a few seconds says roughly how long
and what the user can do meanwhile or to speed it up.

**Sentence case** for labels, buttons, and headers ("Add speaker", not "Add
Speaker"). Title case only where Apple's own UI forces it.

## Running a full review

Fan out one reviewer per surface — iPhone app UI, Mac app UI, website pages —
each loading this skill and reporting in the output format above. The
coordinating session merges the lists, deduplicates shared strings (the same
error text may exist on two surfaces — fix it once, consistently), and ranks
by severity.
