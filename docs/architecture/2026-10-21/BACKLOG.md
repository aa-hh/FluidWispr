# FluidWispr architecture review backlog, 2026-10-21

Six reviewers read all of `Sources/` (171,000 lines of Swift, 389 files), `Tests/`, `scripts/` and `tools/`. They returned 48 candidates. This file merges them into 24 backlog items plus decisions for Alec. Each item names its source candidates; the full evidence (file:line, grep commands and results, before/after edges) is in the `area-*.md` files beside this one.

Goal from Alec: keep what works, delete the garbage.

The lead reviewer checked these claims against the code: B-1, B-2, B-3, the "theme" part of B-4, D-1 (two provider files), D-1 (design preview), D-3 and D-4 (the `#if DEBUG` headers).

## How to work this backlog

- One Linear issue per item, in the Linear project **FluidWispr** (team Aa-hh, key AA). Title: the item's id and title, for example "B-1 Local API accepts requests from web pages". Put the item's text and its source candidate ids in the description. Labels: `bug`, `delete`, `deepen` or `tests`, plus `upstream-cost:low|medium|high`.
- One pull request per item, each from its own branch, following `CLAUDE.md` (REST-only `gh api`, `scripts/review-branch.sh`, merge only after `scripts/pr-ready.sh` passes and Alec says merge).
- Bugs first. Then deletions with low upstream cost. Deepenings with high upstream cost wait for decision 1 below.
- Do not start a `deepen` item that renames or moves code in `ContentView.swift`, `ASRService.swift`, `SettingsStore.swift`, `MeetingCaptureEngine.swift` or `MeetingProcessingPipeline.swift` until Alec answers decision 1.
- Every deletion PR states the grep that proves nothing references the removed code, and passes the `Build and Test` workflow.

## Decisions Alec needs to make

1. **How much upstream will this fork keep taking?** Nearly every file worth deepening is written and still edited by altic-dev. Moving code out of `ContentView`, `ASRService` or `SettingsStore` turns each later upstream fix there into a hand port. Options: keep merging upstream (do bugs, deletions and small deepenings only), or stop taking upstream for some areas (unlocks C-1, C-7, C-8, C-9).
2. **Are the meeting research investigations finished?** Stage 0.5, Trial A, Trial B / VPIO acoustic, C2 paired SCK, detector feasibility. If yes, D-4 removes about 10,600 lines. If not, name who owns them.
3. **Is the legacy meeting backend's rollback switch still needed?** If not, about 2,000 more lines of `MeetingProcessingPipeline.swift` go (source B4).
4. **Should `Package.swift` build?** Its target has no `path:` and cannot build; it is used only for its dependency list (source F8).

## Bugs (fix first)

### B-1 Local API accepts requests from web pages (security)
Sources: E5. Size S. Upstream cost low.
When the local API is switched on, `LocalAPIServer` only checks that the TCP peer is loopback (`LocalAPIServer.swift:96-110`). No handler checks `Host` or `Origin`, so a web page can read `/v1/history` and `/v1/meetings/transcript` through DNS rebinding, and can send cross-site `text/plain` POSTs, which need no preflight.
Fix: in `LocalAPIRouter.route`, reject a `Host` other than `127.0.0.1:<port>`, `localhost:<port>` or `[::1]:<port>`, reject any request with an `Origin` header, and require `application/json` on POST. Add router tests for each rejection.

### B-2 Custom-provider reasoning settings are ignored in Edit mode and Command Mode
Sources: E2 (drift found there). Size S. Upstream cost medium.
Settings saves reasoning options under the provider key, `custom:<id>` for custom providers (`AIEnhancementSettingsViewModel.swift:902-903`). `getReasoningConfig` looks up `"\(provider):\(model)"` literally (`SettingsStore.swift:3333-3337`). Dictation passes `resolved.providerKey` (`DictationPostProcessingService.swift:285`), but Edit mode (`RewriteModeService.swift:345`) and Command Mode (`CommandModeService.swift:986`) pass the raw `providerID`.
Fix: pass `ModelRepository.providerKey(for:)` in both. Add one test per mode that a custom provider's reasoning setting reaches the request.

### B-3 Backup saves a pronunciation switch that does nothing, and misses the live one
Sources: D1. Size S. Upstream cost medium.
The app obeys `DictionarySharedFeatureMatcherEnabled` (`DictionaryExperimentalMatcher.swift:6,12`). The backup saves `SettingsStore.pronunciationMatchingEnabled` (`BackupService.swift:130`, `SettingsStore.swift:3731`), which nothing at runtime reads.
Fix: make `pronunciationMatchingEnabled` read and write the live key through `DictionaryMatcherExperiment.setEnabled`, then delete the dead `@State` and binding in `CustomDictionaryView.swift:54,101,374`.

### B-4 Backups miss several settings
Sources: D2 (small version). Size S. Upstream cost low.
Theme, overlay edge light, meeting auto-detect, meeting audio retention and the two Fluid Server switches are never backed up (`BackupService.swift` has no `theme` at all). The backup lists each field by hand in three places, so new settings get left out.
Fix: add the missing fields, and add a test that fails when a `SettingsStore.Keys` entry is neither backed up nor on an explicit "not backed up" list. The full one-table rewrite is C-5.

### B-5 Settings "test connection" sends a different request from the real one
Sources: E4. Size S. Upstream cost medium.
For Anthropic the test posts to `/v1/messages` with `x-api-key` (`AIEnhancementSettingsViewModel.swift:859-864, 891-894`). Real dictation, Edit and Command requests go through `LLMClient` to `/v1/chat/completions` with a bearer token. The test can pass while real requests fail, or the other way round.
Fix: build a one-message `LLMClient.Config` with small `maxTokens` and call `LLMClient.call`.

### B-6 `http://[::1]` endpoints are treated as needing an API key
Sources: E3, F4. Size S. Upstream cost medium.
No copy of the local-endpoint check treats the IPv6 loopback address as local. Fix inside D-6, or alone if D-6 waits.

### B-7 The clipboard-preservation test tests code the app never uses
Sources: F5. Size S. Upstream cost low.
The test exercises `PreservedPasteboardSnapshot`; the app uses `PasteboardSnapshot` in `PasteDeliveryCoordinator`. Delete `PreservedPasteboardSnapshot.swift` and `scripts/test_paste_clipboard.sh`; move the round-trip case into `PasteDeliveryCoordinatorTests` against the live type.

## Deletions

### D-1 Delete 11 unreferenced files and a 218-line `#if false` block (about 2,500 lines)
Sources: F1, E1, C3, D7. Size S. Upstream cost low to medium.
Files: `CustomAnimations.swift`, `TalkingAnimations.swift`, `Networking/AIProvider.swift`, `Networking/FunctionCallingProvider.swift`, `Theme/Components/FluidModelUpdateButton.swift`, `Theme/Components/SetupComponents.swift`, `Theme/Components/ThemedGroupBox.swift`, `UI/AISettings/AIProvidersDesignPreview.swift`, `UI/DictionaryMatchDiagnosticsView.swift`, `UI/FluidIcon.swift`, `UI/MenuBarIconGenerator.swift`; the `HoverableGlossyCard` struct in `UI/GlossyEffects.swift` (keep `ButtonHoverModifier`); `MeetingCaptureEngine.swift:5269-5486` (`#if false`); `Resources/FV_end.m4a`. Also from C3: `NotchWaveformView`, `GlassToggleStyle`, `FormRowStyle` and the `AudioVisualizationConfig` protocol (keep `AudioVisualizationData`). Also the private `isLocalEndpoint` at `LLMClient.swift:1094-1134`.
Proof is in area F (one `grep -rlw` per type, all empty). Every `.swift` file under `Sources/Fluid` compiles (synchronized groups), so a clean build proves nothing used them.

### D-2 Delete dead code inside hot files
Sources: C2, A2, D4, E6, B3. Size S each; one PR per source id to keep upstream merges simple. Upstream cost medium.
- C2: the old AI-provider screen state and helpers left in `ContentView`; move the one live side effect (provider-key normalisation in `loadProviderState`, 851-872) into a one-time `SettingsStore` migration.
- A2: small unreachable pieces in the dictation core (list in area A).
- D4: retired settings `TranscriptionProviderOption`, `WhisperModelSize` and four prompt alias properties (`SettingsStore.swift:5789-5850, 6195-6225, 664-674, 1008-1018`); keep the raw key strings the migrations read.
- E6: `UnavailableAIIntegrationShim`, a line-for-line copy of `UnavailablePrivateAIIntegrationProvider`.
- B3: four step-list enums in `MeetingCaptureEngine` that the runtime never reads, and the tests that assert their constants.

### D-3 Delete the legacy AVAudioEngine capture path (about 700 lines)
Sources: A1. Size M. Upstream cost medium.
`experimentalDirectAudioCaptureEnabled` returns a hard-coded `true` (`SettingsStore.swift:2021-2023`) since commit d2df033 (2026-08-04), so the AVAudioEngine branch in `ASRService` never runs. Delete the branch, the property, the engine storage, `AudioEngineRetirementDrain` and its test, and the false-branch helpers in `AudioCaptureIdlePolicy`.

### D-4 Delete the finished meeting research experiments (about 10,600 lines, plus 2,300 lines of tests)
Sources: B1, B2, F6. Size M. Upstream cost medium. **Waits for decision 2.**
Ten DEBUG-only files (5,808 lines, each starting `#if DEBUG`): `MeetingStage05EvidenceAutorun`, `MeetingStage05SCKFrameAdapter`, `MeetingStage05MockAECSeam`, `MeetingSCKPairedAutorun`, `MeetingSCKPairedDiagnostics`, `MeetingExternalReferenceTrialA`, `MeetingVPIOAcousticTrialB`, `MeetingVPIOAcousticMetrics`, `MeetingVPIOAcousticStimulus`, `MeetingDetectorFeasibilityProbe`. Their hooks (about 420 lines in `MeetingMicrophoneCapture.swift`, plus `MeetingCaptureEngine.swift`, `AppDelegate.swift:52-91`, `fluidApp.swift:20-32`), the `FluidVPIOProbe` scheme, five test files and the dated `tools/meeting_*` files. Then six release-compiled modules (about 4,400 lines) whose only callers are those experiments and tests (B2 lists them). Keep `MeetingDirectAEC3Gate` and the `AEC/` folder. Before deleting B2's modules, check upstream `main` for new production callers.

### D-5 Delete stale side files
Sources: F7. Size S. Upstream cost low.
Unreferenced runner scripts, `docs/MACOS_UI_AUTOMATION_BRANCH_PLAN.md`, and in `Prototypes/OverlayOnboarding` the hand-copied production views. Keep the prototype only if the onboarding film will be re-rendered; if kept, compile the real `Theme/FluidTypography.swift` instead of its copy.

### D-6 One implementation each for the local-endpoint check, provider storage key and elapsed-time helper
Sources: E3, F4, D6. Size S. Upstream cost medium.
The local-endpoint check has 5 copies, the provider-id-to-storage-key rule 6 to 7 (the `ModelRepository` copy behaves differently on empty input), and the provider-map cleanup is copied into `ContentView` and the AI settings view model, each rewriting stored settings on load. Keep `ModelRepository.isLocalEndpoint` and `ModelRepository.providerKey(for:)`, add `::1` (B-6), run the map cleanup once as a `SettingsStore` migration, add one `elapsedMs(since:)`.

## Tests

### T-1 Bring the 47 stranded test files into the XCTest target, delete the 37 runner scripts
Sources: F2. Size L, splits by test file. Upstream cost medium.
47 Swift test files are not in `project.pbxproj`; 37 shell runners build them with `swiftc`, CI runs 5 of those runners, and 8 test files are built by nothing. So most of the test suite never runs. Move each into `FluidDictationIntegrationTests` using `@testable import`, as the 104 existing files do. Delete orphans that no longer compile. Delete each runner once its tests move.

### T-2 Let `SettingsStore` take its `UserDefaults`
Sources: D3. Size S. Upstream cost medium.
The private init hard-wires `UserDefaults.standard`, and its extension files call `UserDefaults.standard` directly, so 31 test files write to Alec's real preferences. Add `init(defaults:)` for tests, keep `shared` on `.standard`, route the extensions and settings screens through `self.defaults`, delete the 4 unused key strings.

## Deepenings

### C-1 One module turns a chosen provider and model into an `LLMClient.Config`
Sources: E2, A6, E8. Size M. Upstream cost high (do D-6 first for part of the gain at medium cost).
Five callers (`ContentView.swift:2828-2918`, `RewriteModeService.swift:285-365`, `CommandModeService.swift:829-1020`, `DictationPostProcessingService.swift:3-120, 275-300`, `MeetingSummaryProvider.swift:99-200`) each rebuild base URL, key, provider key, reasoning parameters, temperature and max tokens; B-2 is the drift this caused. Grow `DictationProviderRoute` into "settings plus mode in, route out; route plus messages in, `LLMClient.Config` out", copying `MeetingSummaryRoute.resolve`. Fold in RewriteModeService's private verification copy (A6) and one `LLMError` classification (E8). Add Edit and Command config tests first.

### C-2 Merge the three bottom-overlay hover-menu controllers
Sources: C4. Size S. Upstream cost medium.
`BottomOverlayPromptMenuController`, `…ModeMenuController` and `…ActionsMenuController` are three copies of one NSPanel hover menu. Write one controller generic over its content view.

### C-3 Turn the dictation text formatters into one module with two entry points
Sources: A3. Size M. Upstream cost medium.
About ten static formatters on `ASRService` each read `SettingsStore.shared`. One module: "clean raw text" and "finalise for target app", taking settings and app context as values. Keep the old static names as one-line forwards while callers move.

### C-4 Remove the empty default-input hardware listener in `ASRService`
Sources: A4 (first step only). Size S. Upstream cost high for the full merge, low for this step.
The full merge of `ASRService`'s listeners into `AudioHardwareObserver` waits for decision 1.

### C-5 Backup coverage as one table
Sources: D2 (full). Size M. Upstream cost high. Waits for decision 1; B-4 covers the bug now.

### C-6 Stop mirroring 13 settings into `ContentView` state
Sources: C5. Size M. Upstream cost medium. Do after T-2.
`ContentView` copies shortcut and preference values into `@State`, writes them back through `onChange`, and needs a 55-line reload after backup restore. Bind `SettingsView` to `SettingsStore` and let the hotkey manager observe its shortcut values.

### C-7 Move dictation session orchestration out of `ContentView`
Sources: C1, C6. Size L. Upstream cost high. **Waits for decision 1.**
About 3,100 lines of `ContentView` (2363-5465) are the dictation pipeline, held as `@State` on a view, which is why `AppDelegate` keeps a hidden window alive (`AppDelegate.swift:328-424`). One `@MainActor` module held by `AppServices.shared` would own recording mode, lifecycle ids, target context, the hotkey manager, the notch callbacks and the overlay show/hide state (C6).

### C-8 Give each piece cut out by a `sed` test runner its own module
Sources: F3. Size L, about 10 independent S/M pieces. Upstream cost high. **Waits for decision 1.**
17 runners copy parts of production files with `sed`, a regex or a brace counter, because the behaviour has no interface of its own; 3 assert exact source text.

### C-9 Split speech-model readiness out of `ASRService`, and the model catalog and prompt resolution out of `SettingsStore`
Sources: A7, D8. Size L. Upstream cost high. **Waits for decision 1.**

## Not now (recorded so later reviews don't re-suggest without new reasons)

- A5 typing pass-through in `ASRService`, A8 hotkey per-mode table, B5 splitting `MeetingCaptureEngine.swift`, B6 topology-diagnostics scope helper, B7 `MeetingTranscriptionView` export move, B8 pure transcript corrections, C7 one waveform function, C8 `WelcomeView` fold-in, D5 history storage in SQLite: worth exploring, high or medium upstream cost, low urgency.
- E7 private AI ("Fluid-1") is unreachable in this fork's builds but stays: upstream develops it actively and it is switched off in one place already.

## What works and must survive cleanup

`LLMClient` (deep, with a test seam), the `LocalAPI` route table, `FluidServe` (`fv-serve`), the Analytics outbox, `PasteDeliveryCoordinator`'s pasteboard seam, the C ring buffer plus `DirectCoreAudioLifecycleController`, `AudioCapturePipeline`, the `TranscriptionProvider` seam (7 adapters), the meeting backend registry, chunked crash-safe meeting audio, `MeetingSessionStore`, `MeetingTranscriptExporter`, `SearchIndex`, `TranscriptionHistoryDatabase`, `KeychainService`, `BackupService.restore` ordering, the shared theme tokens and `FluidDropdown`. Area reports list the rest.
