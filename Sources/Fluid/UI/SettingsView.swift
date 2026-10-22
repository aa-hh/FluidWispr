//
//  SettingsView.swift
//  fluid
//
//  The Settings sheet: one ruled page per section, built from the Record components.
//

import AppKit
import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// A confirmation shown as a Record alert over the Settings sheet.
struct SettingsConfirmation {
    let title: String
    let message: String
    let actionLabel: String
    let action: () -> Void
}

struct SettingsView: View {
    @EnvironmentObject var appServices: AppServices
    private var asr: ASRService {
        self.appServices.asr
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var updater = SimpleUpdater.shared
    @ObservedObject private var practiceField = DictationPracticeField.shared
    @ObservedObject private var audioCheck = DictionaryAudioCheckPresenter.shared
    @AppStorage("DictionarySharedFeatureMatcherEnabled") private var dictionaryMatcherEnabled = false
    let selectedSection: SettingsSection
    let searchResults: [SettingsSearchResult]
    let searchScrollRequest: Int
    @ObservedObject var microphonePreferenceCoordinator: MicrophonePreferenceCoordinator
    @Binding var appear: Bool
    @Binding var visualizerNoiseThreshold: Double
    @Binding var selectedInputUID: String
    @Binding var selectedOutputUID: String
    @Binding var inputDevices: [AudioDevice.Device]
    @Binding var outputDevices: [AudioDevice.Device]
    @Binding var accessibilityEnabled: Bool
    @Binding var primaryDictationShortcuts: [HotkeyShortcut]
    @Binding var activeShortcutRecordingTarget: ShortcutRecordingTarget?
    @Binding var shortcutRecordingMessage: String?
    @Binding var commandModeShortcut: HotkeyShortcut?
    @Binding var rewriteShortcut: HotkeyShortcut
    @Binding var cancelRecordingShortcut: HotkeyShortcut?
    @Binding var pasteLastTranscriptionShortcut: HotkeyShortcut?
    @Binding var commandModeShortcutEnabled: Bool
    @Binding var rewriteShortcutEnabled: Bool
    @Binding var pasteLastTranscriptionShortcutEnabled: Bool
    @Binding var hotkeyManagerInitialized: Bool
    @Binding var enableStreamingPreview: Bool
    @Binding var copyToClipboard: Bool
    /// The Settings search text, for the "N matches for “q” here." subtitle.
    var searchQuery: String = ""

    // CRITICAL FIX: Cache default device names to avoid CoreAudio calls during view body evaluation.
    // Querying AudioDevice.getDefaultInputDevice() in the view body triggers HALSystem::InitializeShell()
    // which races with SwiftUI's AttributeGraph metadata processing and causes EXC_BAD_ACCESS crashes.
    @State private var cachedDefaultInputUID: String = ""
    @State private var cachedDefaultOutputName: String = ""

    // Detailed analytics consent UI state (default ON; daily activity remains enabled)
    @State private var shareDetailedAnalytics: Bool = SettingsStore.shared.shareDetailedAnalytics
    @State private var showAnalyticsPrivacy: Bool = false
    @State private var rollbackVersion: String = ""
    @State private var isRollingBack: Bool = false
    @State private var audioHistoryBudgetText: String = Self.audioBudgetText(for: SettingsStore.shared.audioHistoryBudgetGB)
    @State private var audioHistoryUsageBytes: Int64 = 0
    @State private var draggedMicrophoneUID: String?
    @State private var hoveredMicrophoneUID: String?
    @State private var searchScrollCoordinator = SettingsSearchScrollCoordinator()
    @State private var confirmation: SettingsConfirmation?
    @State private var showsAdvancedShortcuts = false
    @State private var showsAdvancedCleanup = false
    @State private var showsFillerWordsEditor = false
    @State private var bottomOffsetText = ""
    @State private var volumePreviewTask: Task<Void, Never>?
    @State private var isTestingMicrophone = false
    @State private var lastHeardAt = Date()
    @State private var microphoneTestTask: Task<Void, Never>?

    let hotkeyManager: GlobalHotkeyManager?
    let menuBarManager: MenuBarManager
    let startRecording: () -> Void
    let refreshDevices: () -> Void
    let openAccessibilitySettings: () -> Void
    let restartApp: () -> Void
    let revealAppInFinder: () -> Void
    let openApplicationsFolder: () -> Void

    private func isRecording(_ target: ShortcutRecordingTarget) -> Bool {
        self.activeShortcutRecordingTarget == target
    }

    private var detailedAnalyticsToggleBinding: Binding<Bool> {
        Binding(
            get: { self.shareDetailedAnalytics },
            set: { newValue in
                // Turning it off asks first.
                if self.shareDetailedAnalytics, !newValue {
                    self.confirmation = SettingsConfirmation(
                        title: "Stop sharing detailed analytics?",
                        message: "We never collect audio, dictation text, prompts or other personal information.",
                        actionLabel: "Stop sharing"
                    ) {
                        self.shareDetailedAnalytics = false
                        self.applyAnalyticsConsentChange(false)
                    }
                    return
                }
                self.shareDetailedAnalytics = newValue
                self.applyAnalyticsConsentChange(newValue)
            }
        )
    }

    private var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var launchAtStartupBinding: Binding<Bool> {
        Binding(
            get: { self.settings.launchAtStartupEnabled },
            set: { self.settings.setLaunchAtStartup($0) }
        )
    }

    var body: some View {
        SettingsPersistentScrollView(
            theme: self.theme,
            colorScheme: self.colorScheme,
            searchScrollCoordinator: self.searchScrollCoordinator,
            searchScrollTarget: self.selectedSectionSearchResults.first?.target,
            searchScrollRequest: self.searchScrollRequest
        ) {
            VStack(alignment: .leading, spacing: 0) {
                self.header
                    .padding(.top, FWMetric.space8)
                self.page
            }
            .padding(.bottom, FWMetric.space8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .environment(\.settingsSearchPresentation, self.settingsSearchPresentation)
            .environmentObject(self.appServices)
        }
        .id(self.selectedSection)
        .background(FWColor.surfaceWindow)
        .overlay(alignment: .top) {
            if let confirmation = self.confirmation {
                RecordAlert(
                    title: confirmation.title,
                    message: confirmation.message,
                    layout: .sideBySide,
                    width: 340,
                    cancel: .init(label: "Cancel", kind: .primary) { self.confirmation = nil },
                    action: .init(label: confirmation.actionLabel, kind: .destructive) {
                        self.confirmation = nil
                        confirmation.action()
                    }
                )
                .padding(.top, 180)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: FWMotion.durationReduceCrossfade), value: self.confirmation != nil)
        .sheet(isPresented: self.$showAnalyticsPrivacy) {
            AnalyticsPrivacyView()
                .frame(minWidth: 520, minHeight: 520)
                .appTheme(self.theme)
        }
        .task(id: self.selectedSection) {
            await self.prepareSelectedSection()
        }
        .onChange(of: self.selectedSection) { oldSection, _ in
            self.leave(oldSection)
        }
        .onDisappear {
            self.leave(self.selectedSection)
        }
    }

    /// Stops what a page started when it is left.
    private func leave(_ section: SettingsSection) {
        self.confirmation = nil
        self.showsAdvancedCleanup = false
        if section == .dictation { self.stopMicrophoneTest() }
        if section == .overlay {
            self.practiceField.isActive = false
            self.practiceField.text = ""
        }
    }

    // MARK: - Header

    private var header: some View {
        RecordHeader(self.headerTitle, subtitle: self.headerSubtitle) {
            if self.selectedSection == .cleanup, self.showsAdvancedCleanup {
                RecordBackButton(label: "Cleanup") { self.showsAdvancedCleanup = false }
            }
        }
        .settingsSearchTarget(self.selectedSection.searchTarget)
    }

    private var headerTitle: String {
        self.selectedSection == .cleanup && self.showsAdvancedCleanup ? "Advanced cleanup" : self.selectedSection.title
    }

    private var headerSubtitle: String? {
        if let searchSubtitle = self.searchSubtitle { return searchSubtitle }
        switch self.selectedSection {
        case .general:
            return "Every change takes effect at once."
        case .dictationFormatting:
            return "Rules that run on every dictation, before and without AI cleanup."
        case .shortcuts:
            return self.isRecordingAnyShortcut ? "Press the keys you want to use." : nil
        case .overlay:
            let subtitle = "The pill is the only part of FluidWispr you see while you work."
            return self.asr.isRunning ? subtitle + "\nSettings are locked while you dictate." : subtitle
        case .notifications:
            return "FluidWispr only interrupts you for these."
        case .voiceEngine:
            return "Speech becomes text on this Mac. Nothing you say leaves it."
        case .cleanup:
            return self.showsAdvancedCleanup
                ? "Other providers and your own styles. The default on Cleanup stays until you change it."
                : "Speech stays on this Mac. Only the text is sent for cleanup."
        case .experimental:
            return "These may change or go away."
        case .dictation, .audio, .dataAndDiagnostics:
            return nil
        }
    }

    /// "N matches for “q” here. Also in A and B." while a search has matches on this page.
    private var searchSubtitle: String? {
        guard let presentation = self.settingsSearchPresentation else { return nil }
        let count = presentation.matchedTargets.count
        let query = self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let noun = count == 1 ? "match" : "matches"
        var subtitle = query.isEmpty ? "\(count) \(noun) here." : "\(count) \(noun) for “\(query)” here."
        let others = SettingsSection.allCases.filter { section in
            section != self.selectedSection && self.searchResults.contains { $0.section == section }
        }
        if !others.isEmpty {
            subtitle += " Also in \(Self.joinedList(others.map(\.title)))."
        }
        return subtitle
    }

    private static func joinedList(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: - Pages

    @ViewBuilder
    private var page: some View {
        switch self.selectedSection {
        case .general: self.generalPage
        case .dictation: self.dictationPage
        case .dictationFormatting: self.formattingPage
        case .shortcuts: self.shortcutsPage
        case .overlay: self.overlayPage
        case .audio: self.audioPage
        case .notifications: self.notificationsPage
        case .voiceEngine:
            VoiceEngineSettingsScreen(appServices: self.appServices, theme: self.theme, confirm: { self.confirmation = $0 })
        case .cleanup:
            CleanupSettingsView(
                menuBarManager: self.menuBarManager,
                theme: self.theme,
                showsAdvanced: self.$showsAdvancedCleanup,
                activeShortcutRecordingTarget: self.$activeShortcutRecordingTarget,
                shortcutRecordingMessage: self.$shortcutRecordingMessage,
                confirm: { self.confirmation = $0 }
            )
        case .dataAndDiagnostics: self.dataPage
        case .experimental: self.experimentalPage
        }
    }

    // MARK: General

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow("Launch at login", help: "Start when you log in.", target: .launchAtStartup) {
                RecordSwitch("Launch at login", isOn: self.launchAtStartupBinding)
                if !self.settings.launchAtStartupStatusMessage.isEmpty {
                    SettingsText(self.settings.launchAtStartupStatusMessage)
                }
                if let error = self.settings.launchAtStartupErrorMessage {
                    SettingsStateNote(error)
                }
            }
            SettingsRow("Window at login", help: "When off, it opens quietly in the menu bar.", target: .showWindowAtLogin) {
                RecordSwitch("Window at login", isOn: self.$settings.showMainWindowAtLoginLaunch)
            }
            SettingsRow("Hide from Dock", help: "Menu bar only. Needs a restart.", target: .dockVisibility) {
                RecordSwitch("Hide from Dock", isOn: self.$settings.hideFromDockAndAppSwitcher)
            }
            SettingsRow("Sound cues", help: "When recording starts and stops.", target: .transcriptionSounds) {
                HStack(spacing: FWMetric.space4) {
                    RecordPopUp(self.settings.transcriptionStartSound.displayName) {
                        ForEach(SettingsStore.TranscriptionStartSound.allCases) { option in
                            Button(option.displayName) {
                                self.settings.transcriptionStartSound = option
                                TranscriptionSoundPlayer.shared.playPreview(sound: option)
                            }
                        }
                    }
                    if self.settings.transcriptionStartSound != .none {
                        SettingsText("Volume")
                        RecordSlider(label: "Volume", value: self.soundVolumeBinding)
                    }
                }
            }
            RecordSectionLine(heading: "Updates")
            SettingsRow("Check for updates", help: "Once an hour, in the background.", target: .automaticUpdates) {
                RecordSwitch("Check for updates", isOn: self.$settings.autoUpdateCheckEnabled)
                self.updateStatus
            }
            SettingsRow("Update pop-ups", help: "When off, updates wait here.") {
                RecordSwitch("Update pop-ups", isOn: self.$settings.showUpdatePopups)
            }
            SettingsRow("Beta releases", help: "Preview builds. Can be less stable.") {
                RecordSwitch("Beta releases", isOn: self.$settings.betaReleasesEnabled)
            }
        }
    }

    private var soundVolumeBinding: Binding<Double> {
        Binding(
            get: { Double(self.settings.transcriptionSoundVolume) },
            set: { newValue in
                self.settings.transcriptionSoundVolume = Float(newValue)
                // Play the cue once the slider settles, as the old slider did when editing ended.
                self.volumePreviewTask?.cancel()
                self.volumePreviewTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled else { return }
                    TranscriptionSoundPlayer.shared.playPreviewAtVolume(self.settings.transcriptionSoundVolume)
                }
            }
        )
    }

    @ViewBuilder
    private var updateStatus: some View {
        let busy = self.updater.isCheckingForUpdates || self.updater.isUpdateInProgress
        if let version = self.updater.availableUpdateVersion {
            VStack(alignment: .leading, spacing: FWMetric.space1) {
                SettingsText("Version \(version) is ready to install.", style: FWType.label, color: FWColor.textPrimary)
                SettingsText("You have \(self.currentAppVersion). Installing takes a few seconds and reopens FluidWispr.")
            }
            HStack(spacing: FWMetric.space3) {
                Button("Install and reopen") { self.updater.showAvailableUpdate() }
                    .buttonStyle(RecordButtonStyle(kind: .primary, size: 28))
                    .disabled(busy)
                self.releaseNotesButton
                self.previousVersionsButton
            }
        } else {
            SettingsText(self.versionLine)
            HStack(spacing: FWMetric.space3) {
                Button(self.updater.isCheckingForUpdates ? "Checking…" : "Check now") {
                    self.updater.checkForUpdatesManually()
                }
                .buttonStyle(RecordButtonStyle(kind: .secondary, size: 28))
                .disabled(busy)
                self.releaseNotesButton
                self.previousVersionsButton
            }
        }
    }

    private var releaseNotesButton: some View {
        Button("Release notes") {
            if let url = SimpleUpdater.releasesPageURL { NSWorkspace.shared.open(url) }
        }
        .buttonStyle(RecordButtonStyle(kind: .quiet, size: 20))
        .disabled(SimpleUpdater.releasesPageURL == nil)
    }

    private var previousVersionsButton: some View {
        Button("Previous versions") { self.openPreviousVersions() }
            .buttonStyle(RecordButtonStyle(kind: .quiet, size: 20))
            .disabled(self.isRollingBack || (self.rollbackVersion.isEmpty && SimpleUpdater.releasesPageURL == nil))
    }

    private var versionLine: String {
        guard let lastCheck = self.settings.lastUpdateCheckDate else {
            return "Version \(self.currentAppVersion)."
        }
        let time = lastCheck.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        let when = if calendar.isDateInToday(lastCheck) {
            "today at \(time)"
        } else if calendar.isDateInYesterday(lastCheck) {
            "yesterday at \(time)"
        } else {
            "on \(lastCheck.formatted(date: .abbreviated, time: .omitted)) at \(time)"
        }
        return "Version \(self.currentAppVersion). Checked \(when)."
    }

    // MARK: Dictation

    private var dictationPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            if self.asr.micStatus == .denied || self.asr.micStatus == .notDetermined {
                self.microphonePermissionRow
            }
            SettingsRow("Press to talk", help: "Press once to start, again to stop.", target: .pressToTalk) {
                HStack(spacing: FWMetric.space3) {
                    RecordSwitch("Press to talk", isOn: self.$settings.pressToTalkEnabled)
                    ForEach(Array(self.primaryDictationShortcuts.enumerated()), id: \.offset) { _, shortcut in
                        RecordKeycap(key: shortcut.displayString)
                    }
                    Button("Change in Shortcuts") { AppNavigationRouter.shared.request(.dictationShortcuts) }
                        .buttonStyle(RecordButtonStyle(kind: .quiet, size: 20))
                }
            }
            SettingsRow("Hold to talk", help: "Hold the key, let go to paste.", target: .holdToTalk) {
                HStack(spacing: FWMetric.space3) {
                    RecordSwitch("Hold to talk", isOn: self.holdToTalkBinding)
                    ForEach(Array(self.settings.holdToTalkShortcuts.enumerated()), id: \.offset) { _, shortcut in
                        RecordKeycap(key: shortcut.displayString)
                    }
                    if self.settings.holdToTalkShortcuts.isEmpty {
                        Button("Set shortcut") { self.recordHoldToTalkShortcut() }
                            .buttonStyle(RecordButtonStyle(kind: .quiet, size: 20))
                    } else {
                        Button("Change in Shortcuts") { AppNavigationRouter.shared.request(.dictationShortcuts) }
                            .buttonStyle(RecordButtonStyle(kind: .quiet, size: 20))
                    }
                }
            }
            self.microphoneRow
            SettingsRow("Paste method", help: "How text reaches the app.", target: .textInsertionMode) {
                RecordPopUp(Self.pasteMethodName(self.settings.textInsertionMode)) {
                    ForEach(SettingsStore.TextInsertionMode.allCases) { mode in
                        Button(Self.pasteMethodName(mode)) { self.settings.textInsertionMode = mode }
                    }
                }
                SettingsText(Self.pasteMethodHelp(self.settings.textInsertionMode))
            }
            SettingsRow("Keep a copy", help: "Also copy each dictation.", target: .copyToClipboard) {
                RecordSwitch("Keep a copy", isOn: self.$copyToClipboard)
                    .onChange(of: self.copyToClipboard) { _, newValue in
                        SettingsStore.shared.copyTranscriptionToClipboard = newValue
                    }
            }
            SettingsRow("Pause media", help: "Pause music and video while you talk.", target: .pauseMedia) {
                RecordSwitch("Pause media", isOn: self.$settings.pauseMediaDuringTranscription)
            }
            SettingsRow("Skip silence", help: "Ignore short silent recordings.", target: .skipSilentRecordings) {
                RecordSwitch("Skip silence", isOn: self.$settings.skipSilentRecordingsEnabled)
            }
            RecordSectionLine(heading: "History")
            SettingsRow("Save history", help: "Needed for stats. Off for privacy.", target: .transcriptionHistory) {
                RecordSwitch("Save history", isOn: Binding(
                    get: { self.settings.saveTranscriptionHistory },
                    set: {
                        self.settings.saveTranscriptionHistory = $0
                        self.refreshAudioHistoryUsage()
                    }
                ))
            }
            SettingsRow("Save audio", help: "Keep the recording with each one.", target: .audioHistory) {
                RecordSwitch("Save audio", isOn: Binding(
                    get: { self.settings.saveAudioWithTranscriptionHistory },
                    set: {
                        self.settings.saveAudioWithTranscriptionHistory = $0
                        self.refreshAudioHistoryUsage()
                    }
                ))
                .disabled(!self.settings.saveTranscriptionHistory)
            }
            SettingsRow("Learn from fixes", help: "Asks to add words you retype.", target: .dictionarySuggestions) {
                HStack(spacing: FWMetric.space4) {
                    RecordSwitch("Learn from fixes", isOn: Binding(
                        get: { self.settings.automaticDictionaryLearningEnabled },
                        set: { enabled in
                            self.settings.automaticDictionaryLearningEnabled = enabled
                            if !enabled { AutomaticDictionaryCorrectionTracker.shared.cancel() }
                        }
                    ))
                    if self.settings.automaticDictionaryLearningEnabled {
                        SettingsText("Ask after")
                        RecordPopUp(self.settings.automaticDictionarySuggestionFrequency.displayName) {
                            ForEach(SettingsStore.AutomaticDictionarySuggestionFrequency.allCases) { frequency in
                                Button(frequency.displayName) {
                                    self.settings.automaticDictionarySuggestionFrequency = frequency
                                }
                            }
                        }
                    }
                }
            }
            SettingsRow("Weekend streaks", help: "Weekends don't break a streak.", target: .usageStreak) {
                RecordSwitch("Weekend streaks", isOn: self.$settings.weekendsDontBreakStreak)
            }
        }
    }

    private var holdToTalkBinding: Binding<Bool> {
        Binding(
            get: { self.settings.holdToTalkEnabled },
            set: { enabled in
                self.settings.holdToTalkEnabled = enabled
                if enabled, self.settings.holdToTalkShortcuts.isEmpty {
                    self.recordHoldToTalkShortcut()
                }
            }
        )
    }

    /// Opens Shortcuts with the Hold to talk row already recording. Opening Settings
    /// clears any recording first, so the target is set once the page has changed.
    private func recordHoldToTalkShortcut() {
        AppNavigationRouter.shared.request(.dictationShortcuts)
        DispatchQueue.main.async {
            self.shortcutRecordingMessage = nil
            self.activeShortcutRecordingTarget = .holdToTalk(.add)
        }
    }

    private static func pasteMethodName(_ mode: SettingsStore.TextInsertionMode) -> String {
        switch mode {
        case .reliablePaste: "Clipboard paste"
        case .standard: "Direct paste"
        }
    }

    private static func pasteMethodHelp(_ mode: SettingsStore.TextInsertionMode) -> String {
        switch mode {
        case .reliablePaste:
            "Uses the clipboard for a moment, then puts back what was there. Works in the most apps."
        case .standard:
            "Posts text without touching the clipboard. Some editors reject or cut it short."
        }
    }

    private var microphonePermissionRow: some View {
        SettingsRow("Permission", help: "Needed to hear you.", mark: .needsYou, target: .microphonePermission) {
            SettingsText(
                "FluidWispr can’t use the microphone. Turn it on in System Settings, under Privacy & Security, then Microphone.",
                style: FWType.body,
                color: FWColor.textPrimary
            )
            HStack(spacing: FWMetric.space3) {
                if self.asr.micStatus == .notDetermined {
                    Button("Allow microphone") { self.asr.requestMicAccess() }
                        .buttonStyle(RecordButtonStyle(kind: .primary, size: 28))
                } else {
                    Button("Open System Settings") { self.asr.openSystemSettingsForMic() }
                        .buttonStyle(RecordButtonStyle(kind: .primary, size: 28))
                    Button("Check again") {
                        self.asr.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                    }
                    .buttonStyle(RecordButtonStyle(kind: .quiet, size: 20))
                }
            }
        }
    }

    // MARK: Microphone row and test

    @ViewBuilder
    private var microphoneRow: some View {
        if self.inputDevices.isEmpty {
            SettingsRow("Microphone", mark: .needsYou, target: .microphoneTest) {
                RecordPopUp("No microphone") { EmptyView() }
                SettingsStateNote(
                    "No microphone found. Plug one in, or open the lid to use the built-in one. FluidWispr switches as soon as one appears."
                )
            }
        } else {
            SettingsRow("Microphone", help: "Shown live while you test.", target: .microphoneTest) {
                RecordPopUp(self.microphoneName) {
                    ForEach(self.inputDevices, id: \.uid) { device in
                        Button(device.name) { self.chooseMicrophone(device) }
                    }
                }
                .disabled(self.isMicrophonePriorityEditingDisabled)
                self.microphoneTestLine
            }
        }
    }

    @ViewBuilder
    private var microphoneTestLine: some View {
        if self.asr.micStatus != .authorized {
            SettingsText("Testing needs microphone access.", color: FWColor.textTertiary)
        } else {
            HStack(spacing: FWMetric.space4) {
                RecordingPillPreview(state: self.isTestingMicrophone ? .listen : .idle, size: .medium)
                    // The pill's glow reaches past its frame; the row must not clip it.
                    .padding(-RecordingPillController.margin)
                SettingsText(self.isTestingMicrophone ? "Speak. The rim follows your voice." : "Test it before you rely on it.")
                Button(self.isTestingMicrophone ? "Stop" : "Test microphone") {
                    if self.isTestingMicrophone { self.stopMicrophoneTest() } else { self.startMicrophoneTest() }
                }
                .buttonStyle(RecordButtonStyle(kind: .secondary, size: 20))
                .disabled(!self.isTestingMicrophone && self.asr.isRunningOrStarting)
            }
            .onReceive(self.asr.audioLevelPublisher) { level in
                if level > 0 { self.lastHeardAt = Date() }
            }
        }
    }

    private var microphoneName: String {
        if let device = self.selectedInputDevice { return device.name }
        if let first = self.settings.microphonePriority.first(where: { entry in
            self.inputDevices.contains { $0.uid == entry.uid }
        }) {
            return first.name
        }
        return self.inputDevices.first?.name ?? "No microphone"
    }

    /// Picking a microphone puts it first in the priority list on the Audio page.
    private func chooseMicrophone(_ device: AudioDevice.Device) {
        if let firstUID = self.settings.microphonePriority.first?.uid, firstUID != device.uid {
            self.settings.moveMicrophonePriority(uid: device.uid, before: firstUID)
        }
        self.refreshActiveInputSelection()
    }

    /// A level-only capture: nothing is transcribed or saved. Stops on Stop, after
    /// 10 seconds of silence, or when the page is left.
    private func startMicrophoneTest() {
        guard !self.isTestingMicrophone else { return }
        self.isTestingMicrophone = true
        self.lastHeardAt = Date()
        self.microphoneTestTask = Task { @MainActor in
            await self.asr.startMicrophonePreview()
            while !Task.isCancelled, self.isTestingMicrophone {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Date().timeIntervalSince(self.lastHeardAt) >= 10 {
                    self.stopMicrophoneTest()
                }
            }
        }
    }

    private func stopMicrophoneTest() {
        guard self.isTestingMicrophone else { return }
        self.isTestingMicrophone = false
        self.microphoneTestTask?.cancel()
        self.microphoneTestTask = nil
        Task { await self.asr.stopMicrophonePreview() }
    }

    // MARK: Formatting

    private var formattingPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow("Filler words", help: "Remove these words.", target: .fillerWords) {
                RecordSwitch("Filler words", isOn: self.$settings.removeFillerWordsEnabled)
                HStack(spacing: FWMetric.space4) {
                    SettingsText(self.settings.fillerWords.joined(separator: ", "), style: FWType.body, color: FWColor.textPrimary)
                    Button(self.showsFillerWordsEditor ? "Done" : "Edit list") { self.showsFillerWordsEditor.toggle() }
                        .buttonStyle(RecordButtonStyle(kind: .secondary, size: 20))
                }
                if self.showsFillerWordsEditor {
                    FillerWordsEditor()
                }
            }
            SettingsRow("Smart capitals", help: "Match the text before the cursor.") {
                RecordSwitch("Smart capitals", isOn: self.$settings.contextAwareCapitalizationEnabled)
            }
            SettingsRow("Lowercase start", help: "Begin each dictation in lowercase.") {
                RecordSwitch("Lowercase start", isOn: self.$settings.gaavLowercaseFirstLetterEnabled)
            }
            SettingsRow("Final full stop", help: "Drop the last full stop.") {
                RecordSwitch("Final full stop", isOn: self.$settings.gaavRemoveTrailingPeriodEnabled)
            }
            SettingsRow("Space between", help: "When dictations join up.") {
                RecordSwitch("Space between", isOn: self.$settings.continuousDictationSpacingEnabled)
            }
            SettingsRow("Slash and @", help: "Say “slash help” to type /help.") {
                RecordSwitch("Slash and @", isOn: self.$settings.literalDictationFormattingEnabled)
            }
            RecordSectionLine(heading: "Spoken send")
            SettingsRow("Spoken send", help: "Say a phrase to press Return.", target: .spokenSend) {
                RecordSwitch("Spoken send", isOn: self.$settings.spokenSendEnabled)
            }
            if self.settings.spokenSendEnabled {
                SettingsRow("Send phrase", help: "Say it at the very end.") {
                    RecordField(placeholder: "send it", text: self.$settings.spokenSendPhrase)
                        .frame(width: 240)
                        .accessibilityLabel("Send phrase")
                    SettingsText("Say “literal \(self.settings.spokenSendPhrase)” to type the words instead.")
                }
                SettingsRow("Send key", help: "What the app expects.") {
                    RecordPopUp(self.settings.spokenSendKey.displayName) {
                        ForEach(SettingsStore.SpokenSendKey.allCases) { key in
                            Button(key.displayName) { self.settings.spokenSendKey = key }
                        }
                    }
                }
                SettingsRow("Send at once", help: "Stop listening as soon as the phrase is heard.") {
                    RecordSwitch("Send at once", isOn: self.$settings.spokenSendImmediatelyEnabled)
                }
            }
            RecordSectionLine(heading: "Spoken formatting")
            SettingsRow(target: .spokenFormatting, showsRule: false) {
                CustomDictionaryView(formattingOnly: true, revealTarget: .constant(nil))
            }
        }
    }

    // MARK: Shortcuts

    private var shortcutsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !self.accessibilityEnabled {
                SettingsRow("Permission", help: "Needed for shortcuts.", mark: .needsYou, target: .accessibilityPermission) {
                    SettingsText(
                        "Shortcuts need Accessibility access to hear your keys while another app is in front.",
                        style: FWType.body,
                        color: FWColor.textPrimary
                    )
                    SettingsText("Open the setting, then turn on FluidWispr. If it isn’t listed, press + and choose it from Applications.")
                    HStack(spacing: FWMetric.space3) {
                        Button("Open Accessibility settings") { self.openAccessibilitySettings() }
                            .buttonStyle(RecordButtonStyle(kind: .primary, size: 28))
                        Button("Check again") { self.accessibilityEnabled = AXIsProcessTrusted() }
                            .buttonStyle(RecordButtonStyle(kind: .quiet, size: 20))
                    }
                }
            }
            SettingsRow("Press to talk", help: "Up to three keys or mouse buttons.", target: .primaryDictationShortcuts) {
                self.shortcutList(
                    name: "Press to talk",
                    shortcuts: self.primaryDictationShortcuts,
                    target: { .primaryDictation($0) },
                    remove: { index in
                        guard self.primaryDictationShortcuts.indices.contains(index) else { return }
                        self.primaryDictationShortcuts.remove(at: index)
                    }
                )
            }
            SettingsRow("Hold to talk", help: "Hold the key, let go to paste.") {
                self.shortcutList(
                    name: "Hold to talk",
                    shortcuts: self.settings.holdToTalkShortcuts,
                    target: { .holdToTalk($0) },
                    remove: { index in
                        var shortcuts = self.settings.holdToTalkShortcuts
                        guard shortcuts.indices.contains(index) else { return }
                        shortcuts.remove(at: index)
                        self.settings.holdToTalkShortcuts = shortcuts
                    }
                )
            }
            SettingsRow("Cancel", help: "Stop without pasting.", target: .cancelRecordingShortcut) {
                self.singleShortcut(name: "Cancel", shortcut: self.cancelRecordingShortcut, target: .cancel) {
                    self.cancelRecordingShortcut = nil
                }
            }
            SettingsRow("Paste last", help: "Paste your last dictation again.", target: .pasteLastTranscriptionShortcut) {
                self.singleShortcut(
                    name: "Paste last",
                    shortcut: self.pasteLastTranscriptionShortcutEnabled ? self.pasteLastTranscriptionShortcut : nil,
                    target: .pasteLast
                ) {
                    self.pasteLastTranscriptionShortcut = nil
                    self.pasteLastTranscriptionShortcutEnabled = false
                }
            }
            SettingsRow("Space to mute", help: "Hold Space to pause. A tap types a space.", target: .holdSpaceToMute) {
                RecordSwitch("Space to mute", isOn: self.$settings.holdSpaceToMute)
            }
            SettingsRow("Advanced", help: "Command mode, Edit mode, Smart dictation.") {
                Button(self.advancedShortcutsShown ? "Hide advanced shortcuts" : "Show advanced shortcuts") {
                    self.showsAdvancedShortcuts = !self.advancedShortcutsShown
                }
                .buttonStyle(RecordButtonStyle(kind: .secondary, size: 20))
            }
            if self.advancedShortcutsShown {
                self.advancedShortcutRows
            }
        }
    }

    /// Advanced shortcuts also open while one of them is recording or matches the search.
    private var advancedShortcutsShown: Bool {
        if self.showsAdvancedShortcuts { return true }
        switch self.activeShortcutRecordingTarget {
        case .command, .edit, .dictationPrompt: return true
        default: break
        }
        let matched = self.settingsSearchPresentation?.matchedTargets ?? []
        return matched.contains(.commandModeShortcut) || matched.contains(.editModeShortcut)
    }

    @ViewBuilder
    private var advancedShortcutRows: some View {
        if FluidWisprBuild.includesCommandMode {
            SettingsRow("Command mode", help: "Run voice commands.", target: .commandModeShortcut) {
                self.singleShortcut(
                    name: "Command mode",
                    shortcut: self.commandModeShortcutEnabled ? self.commandModeShortcut : nil,
                    target: .command
                ) {
                    self.commandModeShortcut = nil
                    self.commandModeShortcutEnabled = false
                }
            }
        }
        SettingsRow("Edit mode", help: "Say how to change the selected text.", target: .editModeShortcut) {
            self.singleShortcut(
                name: "Edit mode",
                shortcut: self.rewriteShortcutEnabled ? self.rewriteShortcut : nil,
                target: .edit
            ) {
                self.rewriteShortcutEnabled = false
            }
        }
        if PrivateFeatures.privateAIProvider,
           let key = self.settings.dictationPromptConfigurationKey(for: .privateAI)
        {
            SettingsRow("Smart dictation", help: "Dictate with the on-device model.") {
                self.singleShortcut(
                    name: "Smart dictation",
                    shortcut: self.settings.dictationPromptConfiguration(for: .privateAI).shortcut,
                    target: .dictationPrompt(key)
                ) {
                    var updated = self.settings.dictationPromptConfiguration(for: .privateAI)
                    updated.shortcut = nil
                    self.settings.setDictationPromptConfiguration(updated, for: .privateAI)
                }
            }
        }
    }

    /// A list of up to three shortcuts: keycaps, then Add shortcut or Set shortcut.
    @ViewBuilder
    private func shortcutList(
        name: String,
        shortcuts: [HotkeyShortcut],
        target: @escaping (PrimaryDictationShortcutEdit) -> ShortcutRecordingTarget,
        remove: @escaping (Int) -> Void
    ) -> some View {
        let recordingIndex = shortcuts.indices.first { self.isRecording(target(.replace($0))) }
        let isAdding = self.isRecording(target(.add))
        HStack(spacing: FWMetric.space3) {
            ForEach(Array(shortcuts.enumerated()), id: \.offset) { index, shortcut in
                if recordingIndex == index {
                    self.recordingKeycap
                } else {
                    SettingsShortcutKeycap(
                        key: shortcut.displayString,
                        name: name,
                        isDisabled: self.isRecordingAnyShortcut,
                        edit: { self.beginRecordingShortcut(target(.replace(index))) },
                        remove: { remove(index) }
                    )
                }
            }
            if isAdding {
                self.recordingKeycap
            }
            if recordingIndex != nil || isAdding {
                self.cancelRecordingButton
            } else if shortcuts.isEmpty {
                SettingsText("Off", style: FWType.body, color: FWColor.textTertiary)
                Button("Set shortcut") { self.beginRecordingShortcut(target(.add)) }
                    .buttonStyle(RecordButtonStyle(kind: .quiet, size: 20))
                    .disabled(self.isRecordingAnyShortcut)
            } else if shortcuts.count < 3 {
                Button("Add shortcut") { self.beginRecordingShortcut(target(.add)) }
                    .buttonStyle(RecordButtonStyle(kind: .quiet, size: 20))
                    .disabled(self.isRecordingAnyShortcut)
            }
        }
        if recordingIndex != nil || isAdding {
            self.recordingNote
        }
    }

    /// One optional shortcut: a keycap, Off with Set shortcut, or the recording field.
    @ViewBuilder
    private func singleShortcut(
        name: String,
        shortcut: HotkeyShortcut?,
        target: ShortcutRecordingTarget,
        remove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: FWMetric.space3) {
            if self.isRecording(target) {
                self.recordingKeycap
                self.cancelRecordingButton
            } else if let shortcut {
                SettingsShortcutKeycap(
                    key: shortcut.displayString,
                    name: name,
                    isDisabled: self.isRecordingAnyShortcut,
                    edit: { self.beginRecordingShortcut(target) },
                    remove: remove
                )
            } else {
                SettingsText("Off", style: FWType.body, color: FWColor.textTertiary)
                Button("Set shortcut") { self.beginRecordingShortcut(target) }
                    .buttonStyle(RecordButtonStyle(kind: .quiet, size: 20))
                    .disabled(self.isRecordingAnyShortcut)
            }
        }
        if self.isRecording(target) {
            self.recordingNote
        }
    }

    private var recordingKeycap: some View {
        RecordKeycap(
            key: "Press the new shortcut…",
            state: self.shortcutRecordingMessage == nil ? .recording : .conflict
        )
        .accessibilityLabel("Recording a new shortcut")
    }

    private var cancelRecordingButton: some View {
        Button("Cancel") {
            self.shortcutRecordingMessage = nil
            self.activeShortcutRecordingTarget = nil
        }
        .buttonStyle(RecordButtonStyle(kind: .secondary, size: 20))
    }

    @ViewBuilder
    private var recordingNote: some View {
        if let message = self.shortcutRecordingMessage, !message.isEmpty {
            SettingsStateNote(message)
        } else {
            SettingsText("Esc also cancels. Include a modifier key such as ⌃, ⌥ or ⌘.")
        }
    }

    private func beginRecordingShortcut(_ target: ShortcutRecordingTarget) {
        self.shortcutRecordingMessage = nil
        self.activeShortcutRecordingTarget = target
    }

    // MARK: Overlay

    private var overlayPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow("Pill shows", help: "Always, or only while you talk.") {
                RecordSegmentedChoice(
                    options: [(value: RecordingPillVisibility.whileDictating, label: "While dictating"), (value: .always, label: "Always")],
                    selection: self.$settings.recordingPillVisibility
                )
            }
            SettingsRow("Pill size", help: "Shown at real size.") {
                HStack(alignment: .bottom, spacing: FWMetric.space7) {
                    ForEach(RecordingPillSize.allCases, id: \.self) { size in
                        self.pillSizeOption(size)
                    }
                }
            }
            SettingsRow("Position", help: "Where it sits on screen.", target: .overlayPosition) {
                RecordSegmentedChoice(
                    options: [(value: SettingsStore.OverlayPosition.top, label: "Top"), (value: .bottom, label: "Bottom")],
                    selection: self.$settings.overlayPosition
                )
            }
            if self.settings.overlayPosition == .bottom {
                SettingsRow("From bottom", help: "Distance from the screen edge.", target: .bottomOffset) {
                    HStack(spacing: FWMetric.space4) {
                        RecordField(placeholder: "48", text: self.bottomOffsetBinding)
                            .frame(width: 88)
                            .accessibilityLabel("Distance from bottom in pixels")
                        SettingsText("Pixels. Shown when the pill sits at the bottom.")
                    }
                }
            }
            SettingsRow(showsRule: false) {
                Button("Try a dictation") {
                    self.practiceField.text = ""
                    self.practiceField.isActive = true
                    self.startRecording()
                }
                .buttonStyle(RecordButtonStyle(kind: .primary, size: 28))
                if self.practiceField.isActive {
                    RecordField(placeholder: "Your words land here.", text: self.$practiceField.text, size: .multi)
                        .frame(maxWidth: 480, minHeight: 96)
                }
            }
        }
        .disabled(self.asr.isRunning && !self.practiceField.isActive)
        .onAppear { self.bottomOffsetText = String(Int(self.settings.overlayBottomOffset)) }
    }

    private func pillSizeOption(_ size: RecordingPillSize) -> some View {
        let isSelected = self.settings.recordingPillSize == size
        return Button {
            self.settings.recordingPillSize = size
        } label: {
            VStack(spacing: FWMetric.space3) {
                RecordingPillPreview(state: .idle, size: size)
                    .padding(-RecordingPillController.margin)
                    .padding(FWMetric.space2)
                    .overlay {
                        if isSelected {
                            Capsule().strokeBorder(FWColor.textPrimary, lineWidth: 1.5)
                        }
                    }
                Text(size.displayName)
                    .recordText(isSelected ? FWType.smallStrong : FWType.small)
                    .foregroundStyle(isSelected ? FWColor.textPrimary : FWColor.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pill size \(size.displayName)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var bottomOffsetBinding: Binding<String> {
        Binding(
            get: { self.bottomOffsetText },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                self.bottomOffsetText = digits
                if let value = Double(digits), (20...500).contains(value) {
                    self.settings.overlayBottomOffset = value
                }
            }
        )
    }

    // MARK: Audio

    private var audioPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow("Microphones", help: "Tried from the top. Drag to reorder.", target: .inputDevicePriority) {
                self.microphonePriorityList
                HStack(spacing: FWMetric.space3) {
                    if !self.settings.suppressedMicrophoneUIDs.isEmpty {
                        Button("Restore removed") {
                            self.settings.restoreRemovedMicrophones(with: self.inputDevices)
                            self.refreshActiveInputSelection()
                        }
                        .buttonStyle(RecordButtonStyle(kind: .secondary, size: 20))
                        .disabled(self.isMicrophonePriorityEditingDisabled)
                    }
                    Button("Refresh") {
                        self.refreshDevices()
                        self.cachedDefaultInputUID = AudioDevice.getDefaultInputDevice()?.uid ?? ""
                        self.cachedDefaultOutputName = AudioDevice.getDefaultOutputDevice()?.name ?? ""
                    }
                    .buttonStyle(RecordButtonStyle(kind: .quiet, size: 20))
                }
                SettingsText("This order is for FluidWispr only. Your Mac’s input stays as it is.")
            }
            .onChange(of: self.inputDevices) { _, newDevices in
                self.cachedDefaultInputUID = AudioDevice.getDefaultInputDevice()?.uid ?? ""
                guard newDevices.isEmpty == false else { return }
                if let selectedInput = self.appServices.microphonePreferenceCoordinator
                    .reconcileMicrophoneSelection(availableInputs: newDevices, defaultInputUID: self.cachedDefaultInputUID)
                {
                    self.selectedInputUID = selectedInput.uid
                }
            }
            SettingsRow("Bluetooth", help: "AirPods and headsets.") {
                SettingsText(
                    "Using AirPods as a microphone lowers their playback quality. A wired, USB or display microphone avoids that.",
                    style: FWType.body
                )
            }
            SettingsRow("Output", help: "Where sound cues play.", target: .outputDevice) {
                RecordPopUp(self.outputDeviceName) {
                    ForEach(self.outputDevices, id: \.uid) { device in
                        Button(self.outputDeviceLabel(device)) { self.selectedOutputUID = device.uid }
                    }
                }
                .disabled(self.asr.isRunning)
                .onChange(of: self.selectedOutputUID) { oldUID, newUID in
                    guard !newUID.isEmpty else { return }
                    if self.asr.isRunning {
                        DebugLogger.shared.warning("Cannot change output device during recording", source: "SettingsView")
                        self.selectedOutputUID = oldUID
                        return
                    }
                    SettingsStore.shared.preferredOutputDeviceUID = newUID
                    _ = AudioDevice.setDefaultOutputDevice(uid: newUID)
                }
                .onChange(of: self.outputDevices) { _, newDevices in
                    self.cachedDefaultOutputName = AudioDevice.getDefaultOutputDevice()?.name ?? ""
                    guard !newDevices.isEmpty, !newDevices.contains(where: { $0.uid == self.selectedOutputUID }) else { return }
                    if let prefUID = SettingsStore.shared.preferredOutputDeviceUID, newDevices.contains(where: { $0.uid == prefUID }) {
                        self.selectedOutputUID = prefUID
                    } else if let defaultUID = AudioDevice.getDefaultOutputDevice()?.uid, newDevices.contains(where: { $0.uid == defaultUID }) {
                        self.selectedOutputUID = defaultUID
                    } else {
                        self.selectedOutputUID = newDevices.first?.uid ?? ""
                    }
                }
            }
        }
    }

    private var outputDeviceName: String {
        guard let device = self.outputDevices.first(where: { $0.uid == self.selectedOutputUID }) else {
            return self.outputDevices.isEmpty ? "Loading…" : "Choose an output"
        }
        return self.outputDeviceLabel(device)
    }

    private func outputDeviceLabel(_ device: AudioDevice.Device) -> String {
        !self.cachedDefaultOutputName.isEmpty && device.name == self.cachedDefaultOutputName
            ? "\(device.name) (System default)" : device.name
    }

    @ViewBuilder
    private var microphonePriorityList: some View {
        if self.settings.microphonePriority.isEmpty {
            SettingsText(self.inputDevices.isEmpty ? "No microphones available." : "No microphones in the list.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(self.settings.microphonePriority.enumerated()), id: \.element.uid) { index, entry in
                    self.microphonePriorityRow(entry, rank: index + 1)
                        .overlay(alignment: .top) {
                            if index > 0 {
                                Rectangle().fill(FWColor.lineRule).frame(height: FWMetric.lineHairline)
                            }
                        }
                }
            }
            .frame(maxWidth: 480, alignment: .leading)
        }
    }

    private func microphonePriorityRow(_ entry: SettingsStore.MicrophonePriorityEntry, rank: Int) -> some View {
        let connectedDevice = self.inputDevices.first { $0.uid == entry.uid }
        let isAvailable = connectedDevice.map {
            self.appServices.microphonePreferenceCoordinator.isInputDeviceAvailable($0)
        } ?? false
        let isActive = entry.uid == self.microphonePreferenceCoordinator.confirmedActiveInputUID && isAvailable
        let status = isActive ? "In use" : (isAvailable ? "Available" : "Not connected")
        return MicrophonePriorityRowView(
            rank: rank,
            name: entry.name,
            status: status,
            isAvailable: isAvailable,
            isActive: isActive,
            isEditingDisabled: self.isMicrophonePriorityEditingDisabled,
            isLast: rank == self.settings.microphonePriority.count,
            move: { offset in
                self.settings.moveMicrophonePriority(uid: entry.uid, by: offset)
                self.refreshActiveInputSelection()
            },
            remove: { self.removeMicrophonePriorityEntry(entry) }
        )
        .onDrag {
            self.draggedMicrophoneUID = entry.uid
            return NSItemProvider(object: entry.uid as NSString)
        }
        .onDrop(
            of: [UTType.plainText.identifier],
            delegate: MicrophonePriorityDropDelegate(
                targetUID: entry.uid,
                settings: self.settings,
                draggedUID: self.$draggedMicrophoneUID,
                reorderAnimation: self.accessibilityReduceMotion ? nil : .easeInOut(duration: 0.16),
                onDropCompleted: self.refreshActiveInputSelection
            )
        )
    }

    // MARK: Notifications

    private var notificationsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow("Cleanup failed", help: "The raw words were pasted.", target: .aiEnhancementFailures) {
                RecordSwitch("Cleanup failed", isOn: self.$settings.notifyAIProcessingFailures)
            }
            SettingsRow("Microphone changes", help: "It switched or lost a microphone.", target: .microphoneChanges) {
                RecordSwitch("Microphone changes", isOn: Binding(
                    get: { self.settings.showMicrophoneChangeAlerts },
                    set: { enabled in
                        self.settings.showMicrophoneChangeAlerts = enabled
                        if !enabled { MicrophoneChangeOverlayController.shared.hide() }
                    }
                ))
            }
            SettingsRow("Paste check", help: "It couldn’t confirm the text landed.", target: .pasteCheck) {
                RecordSwitch("Paste check", isOn: self.$settings.showPasteCheckAlerts)
            }
        }
    }

    // MARK: Data and diagnostics

    private var dataPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow("Backup", help: "Settings, styles, history and stats.", target: .backupAndRestore) {
                HStack(spacing: FWMetric.space3) {
                    Button("Export backup", action: self.exportBackup)
                        .buttonStyle(RecordButtonStyle(kind: .secondary, size: 28))
                    Button("Import backup", action: self.importBackup)
                        .buttonStyle(RecordButtonStyle(kind: .secondary, size: 28))
                }
                SettingsText("API keys are never included. Import one on a new Mac to pick up where you left off.")
            }
            SettingsRow("Saved audio", help: "Recordings kept with history.", target: .audioStorage) {
                SettingsText(
                    "\(DictationAudioHistoryStore.formattedGigabytes(self.audioHistoryUsageBytes)) of \(Self.audioBudgetText(for: self.settings.audioHistoryBudgetGB)) GB used",
                    style: FWType.body,
                    color: FWColor.textPrimary
                )
                HStack(spacing: FWMetric.space3) {
                    SettingsText("Keep up to")
                    RecordField(placeholder: "5", text: self.$audioHistoryBudgetText)
                        .frame(width: 72)
                        .accessibilityLabel("Gigabytes of audio to keep")
                    SettingsText("GB")
                    Button("Apply") { self.applyAudioHistoryBudget() }
                        .buttonStyle(RecordButtonStyle(kind: .secondary, size: 20))
                }
                HStack(spacing: FWMetric.space3) {
                    Button("Export audio") { self.exportAudioZip() }
                        .buttonStyle(RecordButtonStyle(kind: .secondary, size: 20))
                    Button("Delete saved audio") { self.deleteSavedAudio() }
                        .buttonStyle(RecordButtonStyle(kind: .destructive, size: 20))
                        .disabled(self.audioHistoryUsageBytes <= 0)
                }
            }
            SettingsRow("Logs", help: "For when something breaks.", target: .debugLogs) {
                HStack(spacing: FWMetric.space4) {
                    RecordSwitch("Show debug logs in the app", isOn: self.$settings.enableDebugLogs)
                    SettingsText("Show debug logs in the app", style: FWType.body, color: FWColor.textPrimary)
                }
                Button("Show log file in Finder") {
                    let url = FileLogger.shared.currentLogFileURL()
                    if FileManager.default.fileExists(atPath: url.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        DebugLogger.shared.info("Log file not found at \(url.path)", source: "SettingsView")
                    }
                }
                .buttonStyle(RecordButtonStyle(kind: .secondary, size: 20))
                SettingsText("Crash details always go to Library/Logs/Fluid/Fluid.log.")
            }
            SettingsRow("Analytics", help: "Anonymous. Never your words or audio.", target: .analyticsPrivacy) {
                RecordSwitch("Analytics", isOn: self.detailedAnalyticsToggleBinding)
                SettingsText("One anonymous signal a day is always sent. Daily totals of features and timings only when this is on.")
                Button("What we collect") { self.showAnalyticsPrivacy = true }
                    .buttonStyle(RecordButtonStyle(kind: .quiet, size: 20))
            }
            SettingsRow("Reset", help: "Back to how it shipped.", target: .resetAllSettings) {
                Button("Reset all settings") {
                    self.confirmation = SettingsConfirmation(
                        title: "Reset all settings?",
                        message: "Every setting goes back to how FluidWispr shipped. History, dictionary and API keys stay.",
                        actionLabel: "Reset settings"
                    ) {
                        self.settings.resetAllSettings()
                        self.syncLocalSettingsAfterBackupRestore()
                    }
                }
                .buttonStyle(RecordButtonStyle(kind: .destructive, size: 28))
            }
        }
    }

    // MARK: Experimental

    private var experimentalPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow("Return to field", help: "Paste where you started, even after switching apps.", target: .returnToStartingField) {
                RecordSwitch("Return to field", isOn: self.$settings.returnDictationToStartingField)
            }
            SettingsRow("Faster long dictation", help: "Parakeet only. Reuses parts already done.", target: .fasterLongDictation) {
                RecordSwitch("Faster long dictation", isOn: self.$settings.experimentalParakeetUnifiedFinalEnabled)
            }
            SettingsRow("Learn how you say words", help: "Matches dictionary words to your voice.", target: .dictionaryMatcherExperiments) {
                DictionaryMatcherExperimentSettings()
                    .disabled(self.asr.isRunningOrStarting)
            }
            if self.dictionaryMatcherEnabled {
                SettingsRow("Audio check", help: "How dictionary words were heard.", target: .audioCheck) {
                    Button("Open audio check") {
                        self.audioCheck.isRequested = true
                        AppNavigationRouter.shared.request(.customDictionary)
                    }
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: 20))
                    .disabled(self.audioCheck.lastReport == nil)
                    SettingsText(
                        self.audioCheck.lastReport == nil
                            ? "Test a word in Dictionary first."
                            : "Shown while Learn how you say words is on."
                    )
                }
            }
            SettingsRow("Timings in History", help: "Show transcription and cleanup time.", target: .historyPerformance) {
                RecordSwitch("Timings in History", isOn: self.$settings.showHistoryPerformanceMetrics)
            }
        }
    }

    // MARK: - Actions

    private func refreshRollbackState() {
        self.rollbackVersion = SimpleUpdater.shared.latestRollbackVersion() ?? ""
    }

    /// Rolls back to the local backup when there is one, otherwise offers recent release builds.
    private func openPreviousVersions() {
        guard !self.rollbackVersion.isEmpty else {
            self.openPreviousBuildPicker()
            return
        }
        guard !self.isRollingBack else { return }

        let targetVersion = self.rollbackVersion
        let confirm = NSAlert()
        confirm.messageText = "Go back to \(targetVersion)?"
        confirm.informativeText = "This restores the previous version and reopens FluidWispr."
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Go back")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        self.isRollingBack = true
        Task {
            defer {
                Task { @MainActor in self.isRollingBack = false }
            }
            do {
                try await SimpleUpdater.shared.rollbackToLatestBackup()
                await MainActor.run {
                    self.presentInfoAlert(title: "Went back to \(targetVersion)", message: "FluidWispr reopens in a moment.")
                }
            } catch {
                await MainActor.run {
                    self.presentErrorAlert(title: "Couldn’t go back", message: error.localizedDescription)
                    self.refreshRollbackState()
                }
            }
        }
    }

    private func exportBackup() {
        Task { await self.performBackupExport() }
    }

    private func performBackupExport() async {
        do {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = BackupService.shared.suggestedFilename()

            guard panel.runModal() == .OK, let url = panel.url else { return }

            let document = try await BackupService.shared.makeBackupDocument()
            let data = try BackupService.shared.encode(document)
            try data.write(to: url, options: .atomic)

            self.presentInfoAlert(title: "Backup exported", message: "Saved your FluidWispr backup to:\n\(url.path)")
        } catch {
            self.presentErrorAlert(title: "Backup export failed", message: error.localizedDescription)
        }
    }

    private func importBackup() {
        Task { await self.performBackupImport() }
    }

    private func performBackupImport() async {
        do {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.json]

            guard panel.runModal() == .OK, let url = panel.url else { return }

            let data = try Data(contentsOf: url)
            let document = try BackupService.shared.decode(data)

            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short

            let confirm = NSAlert()
            confirm.messageText = "Import this backup?"
            confirm.informativeText = """
            This replaces your current settings, styles and stats history.

            Exported: \(formatter.string(from: document.exportedAt))
            API keys are not included and stay as they are.
            """
            confirm.alertStyle = .warning
            confirm.addButton(withTitle: "Import")
            confirm.addButton(withTitle: "Cancel")

            guard confirm.runModal() == .alertFirstButtonReturn else { return }

            try await BackupService.shared.restore(document)
            self.syncLocalSettingsAfterBackupRestore()

            self.presentInfoAlert(title: "Backup imported", message: "Your settings, styles and stats are back.")
        } catch {
            self.presentErrorAlert(title: "Backup import failed", message: error.localizedDescription)
        }
    }

    private func syncLocalSettingsAfterBackupRestore() {
        self.shareDetailedAnalytics = SettingsStore.shared.shareDetailedAnalytics
        self.refreshAudioHistoryUsage()
    }

    private func refreshAudioHistoryUsage() {
        self.audioHistoryUsageBytes = DictationAudioHistoryStore.shared.audioUsageBytes()
        self.audioHistoryBudgetText = Self.audioBudgetText(for: SettingsStore.shared.audioHistoryBudgetGB)
    }

    private func applyAudioHistoryBudget() {
        let normalized = self.audioHistoryBudgetText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value > 0 else {
            self.presentErrorAlert(title: "Enter a size in GB", message: "Use a number above 0, such as 5.")
            self.refreshAudioHistoryUsage()
            return
        }

        let newBudget = max(0.1, value)
        let apply = {
            SettingsStore.shared.audioHistoryBudgetGB = newBudget
            let pruned = TranscriptionHistoryStore.shared.pruneAudioToBudget()
            self.refreshAudioHistoryUsage()
            if pruned > 0 {
                self.presentInfoAlert(title: "Audio pruned", message: "Deleted the oldest saved audio from \(pruned) dictations.")
            }
        }
        if self.audioHistoryUsageBytes > DictationAudioHistoryStore.bytes(forGigabytes: newBudget) {
            self.confirmation = SettingsConfirmation(
                title: "Prune saved audio?",
                message: "This limit is below what is saved now. FluidWispr deletes the oldest audio first and keeps every transcript.",
                actionLabel: "Apply and prune",
                action: apply
            )
        } else {
            apply()
        }
    }

    private func deleteSavedAudio() {
        let size = DictationAudioHistoryStore.formattedGigabytes(self.audioHistoryUsageBytes)
        self.confirmation = SettingsConfirmation(
            title: "Delete saved audio?",
            message: "This removes the \(size) GB of recordings kept with your history. The text of every dictation stays.",
            actionLabel: "Delete audio"
        ) {
            let removed = TranscriptionHistoryStore.shared.deleteAllSavedAudio()
            self.refreshAudioHistoryUsage()
            self.presentInfoAlert(title: "Audio deleted", message: "Removed audio from \(removed) dictations.")
        }
    }

    private func exportAudioZip() {
        do {
            guard TranscriptionHistoryStore.shared.entries.contains(where: {
                DictationAudioHistoryStore.shared.audioFileExists(for: $0)
            }) else {
                throw DictationAudioHistoryError.noAudioEntries
            }

            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.zip]
            panel.nameFieldStringValue = DictationAudioHistoryStore.shared.suggestedAudioExportFilename()

            guard panel.runModal() == .OK, let url = panel.url else { return }
            try DictationAudioHistoryStore.shared.exportAudioArchive(
                entries: TranscriptionHistoryStore.shared.entries,
                to: url
            )
            self.presentInfoAlert(title: "Audio exported", message: "Saved your dictation audio to:\n\(url.path)")
        } catch {
            self.presentErrorAlert(title: "Audio export failed", message: error.localizedDescription)
        }
    }

    private func presentInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func openPreviousBuildPicker() {
        Task { @MainActor in
            do {
                let options = try await SimpleUpdater.shared.fetchRecentReleaseBuildOptions(
                    limit: 3,
                    includePrerelease: SettingsStore.shared.betaReleasesEnabled
                )
                self.presentPreviousBuildPicker(options)
            } catch {
                self.openAllReleasesPage()
            }
        }
    }

    private func presentPreviousBuildPicker(_ options: [SimpleUpdater.ReleaseBuildOption]) {
        guard !options.isEmpty else {
            self.openAllReleasesPage()
            return
        }

        let picker = NSAlert()
        picker.messageText = "Download a previous version"
        picker.informativeText = "There is no earlier version saved on this Mac. Choose a recent release:"
        picker.alertStyle = .informational

        for option in options {
            picker.addButton(withTitle: option.version)
        }
        picker.addButton(withTitle: "All releases")
        picker.addButton(withTitle: "Cancel")

        let response = picker.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let index = response.rawValue - first

        if index >= 0, index < options.count {
            NSWorkspace.shared.open(options[index].url)
            return
        }
        if index == options.count {
            self.openAllReleasesPage()
        }
    }

    private func openAllReleasesPage() {
        guard let url = SimpleUpdater.releasesPageURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func applyAnalyticsConsentChange(_ enabled: Bool) {
        SettingsStore.shared.shareDetailedAnalytics = enabled
        AnalyticsService.shared.setDetailedAnalyticsEnabled(enabled)
    }

    private static func audioBudgetText(for value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }
}

private extension SettingsView {
    var isRecordingAnyShortcut: Bool {
        self.activeShortcutRecordingTarget != nil
    }

    var selectedSectionSearchResults: [SettingsSearchResult] {
        self.searchResults.filter { $0.section == self.selectedSection }
    }

    var settingsSearchPresentation: SettingsSearchPresentation? {
        guard let primaryTarget = self.selectedSectionSearchResults.first?.target else { return nil }
        return SettingsSearchPresentation(
            matchedTargets: Set(self.selectedSectionSearchResults.map(\.target)),
            primaryTarget: primaryTarget,
            scrollCoordinator: self.searchScrollCoordinator
        )
    }

    var isMicrophonePriorityEditingDisabled: Bool {
        self.asr.isRunning || self.asr.isStarting
    }

    func refreshActiveInputSelection() {
        // Reuse the existing off-main hardware refresh so the active
        // indicator and next capture resolve from live Core Audio.
        self.refreshDevices()
    }

    func removeMicrophonePriorityEntry(_ entry: SettingsStore.MicrophonePriorityEntry) {
        self.hoveredMicrophoneUID = nil
        self.settings.removeMicrophoneFromPriority(
            uid: entry.uid,
            isConnected: self.inputDevices.contains { $0.uid == entry.uid }
        )
        self.refreshActiveInputSelection()
    }

    var selectedInputDevice: AudioDevice.Device? {
        guard let confirmedUID = self.microphonePreferenceCoordinator.confirmedActiveInputUID else {
            return nil
        }
        return self.inputDevices.first { $0.uid == confirmedUID }
    }
}

private extension SettingsView {
    func prepareSelectedSection() async {
        do {
            try await Task.sleep(nanoseconds: self.accessibilityReduceMotion ? 120_000_000 : 240_000_000)
        } catch {
            return
        }

        guard !Task.isCancelled else { return }
        switch self.selectedSection {
        case .general:
            self.refreshRollbackState()
            self.settings.refreshLaunchAtStartupStatus(clearError: true, logMismatch: false)
        case .audio, .dictation:
            await self.prepareAudioSettings()
        case .dataAndDiagnostics:
            await self.refreshAudioHistoryUsageInBackground()
        case .dictationFormatting, .shortcuts, .notifications, .overlay, .voiceEngine, .cleanup, .experimental:
            break
        }
    }

    func prepareAudioSettings() async {
        // Keep Core Audio initialization out of the navigation transaction.
        await AudioStartupGate.shared.scheduleOpenAfterInitialUISettled()
        await AudioStartupGate.shared.waitUntilOpen()
        guard !Task.isCancelled else { return }

        self.refreshDevices()

        if !self.inputDevices.isEmpty {
            let defaultInput = AudioDevice.getDefaultInputDevice()
            self.cachedDefaultInputUID = defaultInput?.uid ?? ""
            if let selectedInput = self.appServices.microphonePreferenceCoordinator
                .reconcileMicrophoneSelection(
                    availableInputs: self.inputDevices,
                    defaultInputUID: self.cachedDefaultInputUID
                )
            {
                self.selectedInputUID = selectedInput.uid
            }
        }

        if !self.outputDevices.isEmpty {
            let outputValid = self.outputDevices.contains { $0.uid == self.selectedOutputUID }
            if !outputValid || self.selectedOutputUID.isEmpty {
                if let prefUID = SettingsStore.shared.preferredOutputDeviceUID,
                   self.outputDevices.contains(where: { $0.uid == prefUID })
                {
                    self.selectedOutputUID = prefUID
                } else if let defaultUID = AudioDevice.getDefaultOutputDevice()?.uid,
                          self.outputDevices.contains(where: { $0.uid == defaultUID })
                {
                    self.selectedOutputUID = defaultUID
                } else {
                    self.selectedOutputUID = self.outputDevices.first?.uid ?? ""
                }
            }
        }

        // Cache hardware names outside body evaluation to avoid the Core Audio/AttributeGraph race.
        let defaultInput = AudioDevice.getDefaultInputDevice()
        self.cachedDefaultInputUID = defaultInput?.uid ?? ""
        self.cachedDefaultOutputName = AudioDevice.getDefaultOutputDevice()?.name ?? ""
    }

    func refreshAudioHistoryUsageInBackground() async {
        let usageBytes = await Task.detached(priority: .utility) {
            DictationAudioHistoryStore.shared.audioUsageBytes()
        }.value
        guard !Task.isCancelled else { return }

        self.audioHistoryUsageBytes = usageBytes
        self.audioHistoryBudgetText = Self.audioBudgetText(for: SettingsStore.shared.audioHistoryBudgetGB)
    }
}

// MARK: - Shared row pieces

/// One ruled Settings row: the setting's name, optional mark and help in the margin,
/// its controls in the content column. A search match fills the whole row.
struct SettingsRow<Content: View>: View {
    let name: String?
    var help: String?
    var mark: RecordMark.State?
    var target: SettingsSearchTarget?
    var showsRule = true
    let content: Content

    init(
        _ name: String? = nil,
        help: String? = nil,
        mark: RecordMark.State? = nil,
        target: SettingsSearchTarget? = nil,
        showsRule: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.name = name
        self.help = help
        self.mark = mark
        self.target = target
        self.showsRule = showsRule
        self.content = content()
    }

    var body: some View {
        let line = RecordLine(showsRule: self.showsRule) {
            if let name = self.name {
                HStack(alignment: .center, spacing: 6) {
                    Text(name)
                        .recordText(FWType.label)
                        .foregroundStyle(FWColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let mark = self.mark {
                        RecordMark(state: mark)
                    }
                }
            }
            if let help = self.help {
                Text(help)
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } content: {
            self.content
        }
        if let target = self.target {
            line.settingsSearchTarget(target)
        } else {
            line
        }
    }
}

/// A line of Settings copy in one Record text style, wrapping rather than truncating.
struct SettingsText: View {
    let text: String
    var style: RecordTextStyle = FWType.detail
    var color: Color = FWColor.textSecondary

    init(_ text: String, style: RecordTextStyle = FWType.detail, color: Color = FWColor.textSecondary) {
        self.text = text
        self.style = style
        self.color = color
    }

    var body: some View {
        Text(self.text)
            .recordText(self.style)
            .foregroundStyle(self.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The inline state note: a Needs you mark, then the message in the attention colour.
struct SettingsStateNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            RecordMark(state: .needsYou)
            Text(self.text)
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.stateAttention)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A shortcut keycap that records a new shortcut when clicked (or Return), and shows
/// a small remove button while hovered. Delete or Backspace removes it when focused.
private struct SettingsShortcutKeycap: View {
    let key: String
    let name: String
    let isDisabled: Bool
    let edit: () -> Void
    let remove: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: self.edit) {
            RecordKeycap(key: self.key)
        }
        .buttonStyle(SettingsKeycapButtonStyle())
        .disabled(self.isDisabled)
        .onDeleteCommand { if !self.isDisabled { self.remove() } }
        .overlay(alignment: .topTrailing) {
            if self.isHovered, !self.isDisabled {
                Button(action: self.remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.fluidSystem(size: 12))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(FWColor.surfaceRaised, FWColor.textSecondary)
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .accessibilityLabel("Remove \(self.name) shortcut")
            }
        }
        .onHover { self.isHovered = $0 }
        .accessibilityLabel("\(self.name) shortcut \(self.key)")
        .accessibilityHint("Press to record a new shortcut")
        .accessibilityAction(named: "Remove \(self.name) shortcut") { self.remove() }
    }
}

private struct SettingsKeycapButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsKeycapButtonBody(label: configuration.label)
    }
}

private struct SettingsKeycapButtonBody<Label: View>: View {
    let label: Label
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        self.label
            .contentShape(Capsule())
            .recordFocusRing(self.isFocused, in: Capsule())
            .focusEffectDisabled()
    }
}

/// One microphone in the ordered list: rank, name, status and a drag handle.
/// With keyboard focus, ⌥⌘↑ and ⌥⌘↓ move it and Delete removes it.
private struct MicrophonePriorityRowView: View {
    let rank: Int
    let name: String
    let status: String
    let isAvailable: Bool
    let isActive: Bool
    let isEditingDisabled: Bool
    let isLast: Bool
    let move: (Int) -> Void
    let remove: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: FWMetric.space4) {
            Text("\(self.rank)")
                .recordText(FWType.small)
                .foregroundStyle(FWColor.textTertiary)
            Text(self.name)
                .recordText(FWType.body)
                .foregroundStyle(self.isAvailable ? FWColor.textPrimary : FWColor.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(self.status)
                .recordText(self.isActive ? FWType.detailStrong : FWType.detail)
                .foregroundStyle(self.isActive ? FWColor.textPrimary : (self.isAvailable ? FWColor.textSecondary : FWColor.textTertiary))
            VStack(spacing: 2.5) {
                ForEach(0..<3, id: \.self) { _ in
                    Rectangle().fill(FWColor.textTertiary).frame(width: 12, height: 1.2)
                }
            }
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .focusable(!self.isEditingDisabled)
        .focused(self.$isFocused)
        .focusEffectDisabled()
        .recordFocusRing(self.isFocused, in: RoundedRectangle(cornerRadius: FWMetric.radiusInner, style: .continuous))
        .onKeyPress(keys: [.upArrow, .downArrow], phases: .down) { press in
            guard press.modifiers.contains(.command), press.modifiers.contains(.option) else { return .ignored }
            if press.key == .upArrow, self.rank > 1 { self.move(-1) }
            if press.key == .downArrow, !self.isLast { self.move(1) }
            return .handled
        }
        .onDeleteCommand { if !self.isEditingDisabled { self.remove() } }
        .contextMenu {
            Button("Move Up") { self.move(-1) }
                .disabled(self.isEditingDisabled || self.rank == 1)
            Button("Move Down") { self.move(1) }
                .disabled(self.isEditingDisabled || self.isLast)
            Divider()
            Button("Remove from Priority", role: .destructive) { self.remove() }
                .disabled(self.isEditingDisabled)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Priority \(self.rank), \(self.name)")
        .accessibilityValue(self.status)
        .accessibilityAction(named: "Move up") {
            guard !self.isEditingDisabled, self.rank > 1 else { return }
            self.move(-1)
        }
        .accessibilityAction(named: "Move down") {
            guard !self.isEditingDisabled, !self.isLast else { return }
            self.move(1)
        }
        .accessibilityAction(named: "Remove from priority") {
            guard !self.isEditingDisabled else { return }
            self.remove()
        }
    }
}

private struct MicrophonePriorityDropDelegate: DropDelegate {
    let targetUID: String
    let settings: SettingsStore
    @Binding var draggedUID: String?
    let reorderAnimation: Animation?
    let onDropCompleted: () -> Void

    func validateDrop(info _: DropInfo) -> Bool {
        self.draggedUID != nil
    }

    func dropEntered(info _: DropInfo) {
        guard let draggedUID = self.draggedUID,
              draggedUID != self.targetUID
        else { return }

        let entries = self.settings.microphonePriority
        guard let sourceIndex = entries.firstIndex(where: { $0.uid == draggedUID }),
              let targetIndex = entries.firstIndex(where: { $0.uid == self.targetUID })
        else { return }

        withAnimation(self.reorderAnimation) {
            self.settings.reorderMicrophonePriority(
                fromOffsets: IndexSet(integer: sourceIndex),
                toOffset: targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
            )
        }
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        self.draggedUID = nil
        self.onDropCompleted()
        return true
    }
}

// MARK: - Filler Words Editor

struct FillerWordsEditor: View {
    @State private var fillerWords: [String] = SettingsStore.shared.fillerWords
    @State private var newWord: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: FWMetric.space4) {
            FlowLayout(spacing: 6) {
                ForEach(self.fillerWords, id: \.self) { word in
                    HStack(spacing: FWMetric.space1) {
                        RecordKeycap(key: word)
                        Button { self.removeWord(word) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.fluidSystem(size: 12))
                                .foregroundStyle(FWColor.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(word)")
                    }
                }
            }
            HStack(spacing: FWMetric.space3) {
                RecordField(placeholder: "Add a word", text: self.$newWord)
                    .frame(width: 140)
                    .onSubmit { self.addWord() }
                Button("Add") { self.addWord() }
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: 20))
                    .disabled(self.newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Reset") {
                    self.fillerWords = SettingsStore.defaultFillerWords
                    SettingsStore.shared.fillerWords = self.fillerWords
                }
                .buttonStyle(RecordButtonStyle(kind: .quiet, size: 20))
            }
        }
    }

    private func addWord() {
        let word = self.newWord.trimmingCharacters(in: .whitespaces).lowercased()
        guard !word.isEmpty, !self.fillerWords.contains(word) else { return }
        self.fillerWords.append(word)
        SettingsStore.shared.fillerWords = self.fillerWords
        self.newWord = ""
    }

    private func removeWord(_ word: String) {
        self.fillerWords.removeAll { $0 == word }
        SettingsStore.shared.fillerWords = self.fillerWords
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    struct Cache {
        var sizes: [CGSize] = []
        var positions: [CGPoint] = []
        var containerSize: CGSize = .zero
        var lastWidth: CGFloat = 0
    }

    var spacing: CGFloat = 8

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: Array(repeating: .zero, count: subviews.count))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        self.arrangeSubviews(proposal: proposal, subviews: subviews, cache: &cache)
        return cache.containerSize
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        self.arrangeSubviews(proposal: proposal, subviews: subviews, cache: &cache)
        for (index, position) in cache.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrangeSubviews(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let proposedWidth = proposal.width ?? 0
        let maxWidth = proposedWidth > 0 ? proposedWidth : 260
        let needsLayout = cache.positions.count != subviews.count || cache.lastWidth != maxWidth

        if needsLayout {
            cache.positions = []
            cache.positions.reserveCapacity(subviews.count)
            cache.sizes = Array(repeating: .zero, count: subviews.count)
        }

        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for index in subviews.indices {
            let size: CGSize
            if needsLayout {
                size = subviews[index].sizeThatFits(.unspecified)
                cache.sizes[index] = size
            } else {
                size = cache.sizes[index]
            }

            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + self.spacing
                rowHeight = 0
            }
            if needsLayout {
                cache.positions.append(CGPoint(x: x, y: y))
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + self.spacing
        }

        cache.containerSize = CGSize(width: maxWidth, height: y + rowHeight)
        cache.lastWidth = maxWidth
    }
}
