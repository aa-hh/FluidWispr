import AppKit
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class SettingsNavigationStateTests: XCTestCase {
    func testPresentAndDismissRestoresPreviousAppDestination() {
        var state = SettingsNavigationState()

        state.present(.general, returningTo: .yesterday)

        XCTAssertTrue(state.isPresented)
        XCTAssertEqual(state.selectedSection, .general)
        XCTAssertEqual(state.returnDestination, .yesterday)
        XCTAssertEqual(state.dismiss(), .yesterday)
        XCTAssertFalse(state.isPresented)
    }

    func testSpecificDeepLinkChangesSectionWithoutReplacingReturnDestination() {
        var state = SettingsNavigationState()
        state.present(.general, returningTo: .stats)

        state.present(.audio, returningTo: .customDictionary)

        XCTAssertEqual(state.selectedSection, .audio)
        XCTAssertEqual(state.returnDestination, .stats)
    }

    func testMissingReturnDestinationFallsBackToGettingStarted() {
        var state = SettingsNavigationState()

        state.present(.general, returningTo: nil)

        XCTAssertEqual(state.dismiss(), .today)
    }

    func testLeavingForAppDismissesSettings() {
        var state = SettingsNavigationState()
        state.present(.overlay, returningTo: .earlier)

        state.leaveForApp()

        XCTAssertFalse(state.isPresented)
        XCTAssertNil(state.selectedSection)
    }

    func testDetectsWhenNavigationLeavesDictationSettings() {
        var state = SettingsNavigationState()
        state.present(.dictation, returningTo: .today)

        XCTAssertTrue(state.isLeaving(.dictation, for: .audio))
        XCTAssertTrue(state.isLeaving(.dictation, for: nil))
        XCTAssertFalse(state.isLeaving(.dictation, for: .dictation))
    }

    func testInactiveSettingsSearchResignsFirstResponder() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let searchField = NSSearchField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        window.contentView?.addSubview(searchField)

        XCTAssertTrue(window.makeFirstResponder(searchField))
        XCTAssertNotNil(searchField.currentEditor())

        SidebarSearchField.resignFocusIfNeeded(from: searchField, isActive: false)

        XCTAssertNil(searchField.currentEditor())
    }

    func testCommandModeOnlyOwnsRecordingItStarted() {
        XCTAssertTrue(CommandModeRecordingOwnershipPolicy.ownsRecording(after: .started, isRunning: true))
        XCTAssertFalse(CommandModeRecordingOwnershipPolicy.ownsRecording(after: .started, isRunning: false))
        XCTAssertFalse(CommandModeRecordingOwnershipPolicy.ownsRecording(after: .alreadyActive, isRunning: true))
        XCTAssertFalse(CommandModeRecordingOwnershipPolicy.ownsRecording(after: .failed, isRunning: true))
    }

    func testCommandModeDeactivationNeverStopsUnownedRecording() {
        XCTAssertTrue(CommandModeRecordingOwnershipPolicy.shouldStopOnDeactivate(
            ownsRecording: true,
            isRunning: true
        ))
        XCTAssertFalse(CommandModeRecordingOwnershipPolicy.shouldStopOnDeactivate(
            ownsRecording: false,
            isRunning: true
        ))
        XCTAssertFalse(CommandModeRecordingOwnershipPolicy.shouldStopOnDeactivate(
            ownsRecording: true,
            isRunning: false
        ))
        XCTAssertTrue(CommandModeRecordingOwnershipPolicy.shouldStopAfterStart(
            ownsRecording: true,
            isPresentationActive: false
        ))
        XCTAssertFalse(CommandModeRecordingOwnershipPolicy.shouldStopAfterStart(
            ownsRecording: false,
            isPresentationActive: false
        ))
    }

    func testSettingsSectionsHaveStableTitlesAndIcons() {
        XCTAssertEqual(
            SettingsSection.allCases.map(\.title),
            [
                "General", "Dictation", "Formatting", "Shortcuts", "Overlay", "Audio", "Notifications",
                "Voice engine", "Cleanup", "Data and diagnostics", "Experimental",
            ]
        )
        XCTAssertTrue(SettingsSection.allCases.allSatisfy { !$0.systemImage.isEmpty })
        XCTAssertEqual(SettingsSection.overlay.systemImage, "rectangle.on.rectangle")
        XCTAssertEqual(SettingsSection.voiceEngine.systemImage, "waveform")
        XCTAssertEqual(SettingsSection.cleanup.systemImage, "sparkles")
    }

    func testShortcutSearchRoutesToDedicatedPageWithoutMovingDictationOptions() {
        XCTAssertEqual(SettingsSearchIndex.results(for: "Press to talk shortcut").first?.section, .shortcuts)
        XCTAssertEqual(SettingsSearchIndex.results(for: "Keep a copy").first?.section, .dictation)
        XCTAssertEqual(SettingsSearchTarget.commandModeShortcut.section, .shortcuts)
        var state = SettingsNavigationState()
        state.present(.shortcuts, returningTo: .stats)
        XCTAssertTrue(state.isLeaving(.shortcuts, for: .dictation))
        XCTAssertEqual(state.dismiss(), .stats)
    }

    // Goes red if a Debug build drops the local API, which the cleanup comparison tool
    // needs to transcribe recordings.
    func testDebugLeanBuildKeepsTheLocalAPI() {
        XCTAssertTrue(FluidWisprBuild.isDebug)
        XCTAssertTrue(FluidWisprBuild.includesLocalAPI)
    }

    // Goes red if the lean build lets the meetings page open, or hides Command Mode,
    // File Transcription or their Settings search and app search entries again.
    func testLeanBuildSendsLeftOutPagesToToday() {
        XCTAssertTrue(FluidWisprBuild.isLean)
        XCTAssertFalse(SidebarItem.meetingTranscription.isInThisBuild)
        XCTAssertEqual(SidebarItem.meetingTranscription.shownInThisBuild, .today)
        for item: SidebarItem in [
            .today, .yesterday, .earlier, .stats, .commandMode, .rewriteMode, .fileTranscription, .customDictionary,
        ] {
            XCTAssertEqual(item.shownInThisBuild, item, "\(item)")
        }
        XCTAssertTrue(SettingsSearchIndex.results(for: "Command Mode").contains { $0.target == .commandModeShortcut })
        XCTAssertTrue(AppSearchKind.chats.isInThisBuild)
        XCTAssertTrue(AppSearchKind.transcripts.isInThisBuild)
        XCTAssertTrue(AppSearchKind.history.isInThisBuild)
    }

    func testFormattingSearchRoutesToDedicatedSection() {
        XCTAssertEqual(SettingsSearchIndex.results(for: "Formatting").first?.section, .dictationFormatting)
        XCTAssertEqual(SettingsSearchIndex.results(for: "Smart capitals").first?.section, .dictationFormatting)
        XCTAssertEqual(SettingsSearchIndex.results(for: "Spoken formatting").first?.section, .dictationFormatting)
        XCTAssertEqual(SettingsSearchIndex.results(for: "Filler words").first?.section, .dictationFormatting)
        XCTAssertEqual(SettingsSearchIndex.results(for: "Spoken send").first?.section, .dictationFormatting)
        XCTAssertEqual(SettingsSearchTarget.copyToClipboard.section, .dictation)
        XCTAssertEqual(SettingsSearchTarget.inputDevicePriority.section, .audio)
    }

    func testSettingsSearchRanksExactTitleAheadOfRelatedTerms() {
        XCTAssertEqual(SettingsSearchIndex.results(for: "Paste method").first?.target, .textInsertionMode)
        let results = SettingsSearchIndex.results(for: "clipboard")
        XCTAssertTrue(results.contains { $0.target == .copyToClipboard })
        XCTAssertTrue(results.contains { $0.target == .textInsertionMode })
    }

    // Goes red if the Press to talk row drops out of the Settings search index or is renamed.
    func testSettingsSearchFindsPressToTalkForPress() {
        let results = SettingsSearchIndex.results(for: "press")

        XCTAssertTrue(results.contains { $0.target == .pressToTalk })
        XCTAssertEqual(SettingsSearchIndex.title(for: .pressToTalk), "Press to talk")
        XCTAssertEqual(SettingsSearchTarget.pressToTalk.section, .dictation)
    }

    func testSettingsSearchNormalizesCaseAndDiacritics() {
        let results = SettingsSearchIndex.results(for: "SÁVE HÍSTORY")

        XCTAssertEqual(results.first?.target, .transcriptionHistory)
    }

    func testSettingsSearchMatchesPrefixesAliasesAndMultipleWords() {
        XCTAssertEqual(SettingsSearchIndex.results(for: "start").first?.target, .launchAtStartup)
        XCTAssertTrue(SettingsSearchIndex.results(for: "mic").contains { $0.target == .inputDevicePriority })
        XCTAssertEqual(SettingsSearchIndex.results(for: "audio device").first?.section, .audio)
    }

    func testSettingsSearchToleratesRepresentativeTypos() {
        XCTAssertTrue(SettingsSearchIndex.results(for: "microfone").contains { $0.target == .microphonePermission })
        XCTAssertEqual(SettingsSearchIndex.results(for: "clipbord").first?.target, .copyToClipboard)
        XCTAssertEqual(SettingsSearchIndex.results(for: "hot ky").first?.target, .globalHotkey)
    }

    func testSettingsSearchRejectsUnrelatedShortQuery() {
        XCTAssertTrue(SettingsSearchIndex.results(for: "zz").isEmpty)
    }

    func testSettingsSearchKeepsSectionsInNavigationOrder() {
        XCTAssertEqual(
            SettingsSearchIndex.matchingSections(for: "mic"),
            [.dictation, .audio, .notifications]
        )
    }

    func testSettingsSearchPreservesMatchingSectionAndFallsBackToBestResult() {
        let results = SettingsSearchIndex.results(for: "mic")

        XCTAssertEqual(
            SettingsSearchIndex.preferredSection(current: .audio, results: results),
            .audio
        )
        XCTAssertEqual(
            SettingsSearchIndex.preferredSection(current: .general, results: results),
            results.first?.section
        )
        XCTAssertEqual(SettingsSearchIndex.preferredSection(current: .audio, results: []), .audio)
    }

    func testSettingsSearchOmitsTargetsUnavailableInTheCurrentState() {
        let availability = SettingsSearchAvailability(
            microphoneAuthorized: true,
            accessibilityEnabled: true,
            savesTranscriptionHistory: false,
            savesAudioWithTranscriptionHistory: false,
            overlayAtBottom: false,
            dictionaryMatcherEnabled: false
        )

        let permissionTargets = SettingsSearchIndex.results(
            for: "permission",
            availability: availability
        ).map(\.target)

        XCTAssertFalse(permissionTargets.contains(.microphonePermission))
        XCTAssertFalse(permissionTargets.contains(.accessibilityPermission))
        XCTAssertFalse(SettingsSearchIndex.results(
            for: "audio check",
            availability: availability
        ).contains { $0.target == .audioCheck })
        XCTAssertFalse(SettingsSearchIndex.results(
            for: "bottom offset",
            availability: availability
        ).contains { $0.target == .bottomOffset })
    }

    // Goes red if search hides Settings rows that now show without Accessibility permission.
    func testSettingsSearchKeepsRowsShownWithoutAccessibility() {
        let availability = SettingsSearchAvailability(
            microphoneAuthorized: true,
            accessibilityEnabled: false,
            savesTranscriptionHistory: false,
            savesAudioWithTranscriptionHistory: false,
            overlayAtBottom: true
        )
        let shownTargets: [(SettingsSearchTarget, String)] = [
            (.primaryDictationShortcuts, "press to talk shortcut"),
            (.commandModeShortcut, "command mode"),
            (.editModeShortcut, "edit mode"),
            (.cancelRecordingShortcut, "cancel recording shortcut"),
            (.pasteLastTranscriptionShortcut, "paste last"),
            (.copyToClipboard, "keep a copy"),
            (.textInsertionMode, "paste method"),
            (.spokenSend, "spoken send"),
            (.transcriptionHistory, "save history"),
            (.audioHistory, "save audio"),
            (.audioStorage, "saved audio"),
            (.usageStreak, "weekend streaks"),
            (.skipSilentRecordings, "skip silence"),
            (.pauseMedia, "pause media"),
            (.dictionarySuggestions, "learn from fixes"),
            (.analyticsPrivacy, "analytics"),
        ]

        for (target, query) in shownTargets {
            XCTAssertTrue(
                SettingsSearchIndex.results(for: query, availability: availability)
                    .contains { $0.target == target },
                "\(target) is shown without Accessibility permission"
            )
        }
    }
}
