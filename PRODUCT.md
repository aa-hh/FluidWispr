# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

Native macOS app in Swift and SwiftUI, macOS 15 and later, Apple Silicon only. The design skill's platform list has no macOS entry, so design work follows Apple's Human Interface Guidelines for Mac.

## Users

Ali first, who dictates instead of typing, all day, into whatever app is in front. A public release is planned later, so first-run, permission and settings design should work for a stranger, not only for Ali.

## Product Purpose

FluidWispr turns speech into clean text pasted where the cursor is. Press the dictation key, talk, press it again, and the text appears in the app in front. Hold-to-talk is also available; each way of dictating has its own shortcut. It started from the open-source FluidVoice (GPL-3.0) and is now its own app.

Success means dictation is faster and less tiring than typing, every time: text lands within a moment of letting go of the key, it reads as if written, and no dictation is ever lost.

## Positioning

A Wispr Flow alternative for the community rather than for enterprise or profit: built to give individual users the best dictation experience possible. Reliable, efficient, low on CPU use, and configurable. Speech recognition runs on the Mac; only the optional cleanup step uses the cloud, with offline fallbacks.

## Operating Context

- Dictation happens anywhere text can be typed: Slack, Google Docs, Notion, Claude, WhatsApp, Telegram, Messages, Mail, and more.
- Length ranges from one or two words to several paragraphs.
- The recording pill is the part of the app seen most. The main window (history, dictionary, settings) is opened occasionally.
- It runs all day in the background on laptops, often with external microphones and keyboards coming and going.

## Capabilities and Constraints

- Speech recognition is local (Parakeet, through the FluidAudio package).
- Cleanup runs on Cerebras gpt-oss-120b within a 400 ms budget, then falls back to Ollama qwen3:4b-instruct offline, then to rule-based cleanup. Dictations of three words or fewer skip AI cleanup.
- One measured default experience; other cleanup providers live under Advanced.
- App and cursor context stays on the Mac by default.
- Cloud keys are the user's own, stored in the Keychain. Who pays for cleanup in a public release is undecided.
- Reliability and low resource use are core goals; FluidVoice crashed often on Ali's Mac.
- Undecided: how a public release is distributed and priced.

## Brand Commitments

- The recording pill is approved and final: a near-black capsule whose thin ivory rim reacts to the voice. Spec: `/mnt/project-files/design/pill-rim/README.md` in the project files, and the Figma page "Recording pill: Rim (approved)".
- Clean, minimal, intuitive UI with the personality of today's AI voice modes, kept subtle: generative motion and colour live in the pill, not across the app.
- Not FluidVoice's generic look. Rejected directions are recorded in the project notes and are not to be revived.
- Figma (file "FluidWispr") is the design source of truth.

## Evidence on Hand

- The approved pill prototype, Figma components and spec.
- Real timing figures: FluidVoice takes about 918 ms typical and 5,009 ms at the slowest tenth from key release to text; Wispr Flow about 450 ms.
- No users, reviews or download figures yet. Do not invent any.

## Product Principles

1. Never lose what someone said. A failed paste or cleanup keeps the words and offers them back.
2. Speed is the feature. Every step serves the time from letting go of the key to text on screen.
3. Quiet by default. The app stays out of the way; only the pill shows life, and only while it is working.
4. Local first. Speech stays on the Mac; the cloud is optional and has offline fallbacks.
5. Configurable without being complicated. One good default, with real control for those who want it.

## Accessibility & Inclusion

- Respect Reduce Motion: travel stops, but colour and brightness still carry meaning.
- No flashing: light pulses at least 340 ms apart (WCAG 2.3.1).
- Text contrast of at least 4.5:1.
- Dictation itself is an accessibility tool, so the app must work fully from the keyboard.
