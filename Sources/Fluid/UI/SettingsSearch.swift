//
//  SettingsSearch.swift
//  fluid
//
//  Search metadata and fuzzy matching for the Settings sidebar.
//

import AppKit
import AVFoundation
import Foundation
import SwiftUI

enum SettingsSearchTarget: Hashable {
    case general
    case launchAtStartup
    case showWindowAtLogin
    case dockVisibility
    case transcriptionSounds
    case automaticUpdates

    case dictation
    case microphonePermission
    case pressToTalk
    case holdToTalk
    case microphoneTest
    case copyToClipboard
    case textInsertionMode
    case transcriptionHistory
    case audioHistory
    case usageStreak
    case skipSilentRecordings
    case pauseMedia
    case dictionarySuggestions

    case textFormatting
    case spokenFormatting
    case fillerWords
    case spokenSend

    case shortcuts
    case accessibilityPermission
    case globalHotkey
    case primaryDictationShortcuts
    case commandModeShortcut
    case editModeShortcut
    case cancelRecordingShortcut
    case pasteLastTranscriptionShortcut
    case pasteRawInsteadShortcut
    case holdSpaceToMute

    case notifications
    case aiEnhancementFailures
    case microphoneChanges
    case pasteCheck

    case audio
    case inputDevicePriority
    case outputDevice

    case overlay
    case overlayPosition
    case bottomOffset

    case voiceEngine
    case cleanup
    case cleanupProvider
    case cleanupKey
    case cleanupOffline

    case dataAndDiagnostics
    case backupAndRestore
    case audioStorage
    case debugLogs
    case analyticsPrivacy
    case resetAllSettings

    case experimental
    case returnToStartingField
    case fasterLongDictation
    case dictionaryMatcherExperiments
    case audioCheck
    case historyPerformance

    var section: SettingsSection {
        switch self {
        case .general,
             .launchAtStartup,
             .showWindowAtLogin,
             .dockVisibility,
             .transcriptionSounds,
             .automaticUpdates:
            return .general

        case .dictation,
             .microphonePermission,
             .pressToTalk,
             .holdToTalk,
             .microphoneTest,
             .copyToClipboard,
             .textInsertionMode,
             .transcriptionHistory,
             .audioHistory,
             .usageStreak,
             .skipSilentRecordings,
             .pauseMedia,
             .dictionarySuggestions:
            return .dictation

        case .textFormatting, .spokenFormatting, .fillerWords, .spokenSend:
            return .dictationFormatting

        case .shortcuts, .accessibilityPermission, .globalHotkey, .primaryDictationShortcuts,
             .commandModeShortcut, .editModeShortcut, .cancelRecordingShortcut,
             .pasteLastTranscriptionShortcut, .pasteRawInsteadShortcut, .holdSpaceToMute:
            return .shortcuts

        case .notifications, .aiEnhancementFailures, .microphoneChanges, .pasteCheck:
            return .notifications

        case .audio, .inputDevicePriority, .outputDevice:
            return .audio

        case .overlay, .overlayPosition, .bottomOffset:
            return .overlay

        case .voiceEngine:
            return .voiceEngine

        case .cleanup, .cleanupProvider, .cleanupKey, .cleanupOffline:
            return .cleanup

        case .dataAndDiagnostics, .backupAndRestore, .audioStorage, .debugLogs, .analyticsPrivacy, .resetAllSettings:
            return .dataAndDiagnostics

        case .experimental, .returnToStartingField, .fasterLongDictation, .dictionaryMatcherExperiments,
             .audioCheck, .historyPerformance:
            return .experimental
        }
    }
}

extension SettingsSection {
    var searchTarget: SettingsSearchTarget {
        switch self {
        case .general: return .general
        case .dictation: return .dictation
        case .dictationFormatting: return .textFormatting
        case .shortcuts: return .shortcuts
        case .notifications: return .notifications
        case .audio: return .audio
        case .overlay: return .overlay
        case .voiceEngine: return .voiceEngine
        case .cleanup: return .cleanup
        case .dataAndDiagnostics: return .dataAndDiagnostics
        case .experimental: return .experimental
        }
    }
}

struct SettingsSearchResult: Identifiable, Equatable {
    let target: SettingsSearchTarget
    let score: Int

    var id: SettingsSearchTarget {
        self.target
    }

    var section: SettingsSection {
        self.target.section
    }
}

struct SettingsSearchAvailability {
    let microphoneAuthorized: Bool
    let accessibilityEnabled: Bool
    let savesTranscriptionHistory: Bool
    let savesAudioWithTranscriptionHistory: Bool
    let overlayAtBottom: Bool
    var dictionaryMatcherEnabled: Bool = DictionaryMatcherExperiment.sharedFeaturesEnabled

    static var current: Self {
        let settings = SettingsStore.shared
        return Self(
            microphoneAuthorized: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibilityEnabled: AXIsProcessTrusted(),
            savesTranscriptionHistory: settings.saveTranscriptionHistory,
            savesAudioWithTranscriptionHistory: settings.saveAudioWithTranscriptionHistory,
            overlayAtBottom: settings.overlayPosition == .bottom
        )
    }

    func includes(_ target: SettingsSearchTarget) -> Bool {
        switch target {
        case .microphonePermission:
            return !self.microphoneAuthorized
        case .accessibilityPermission:
            return !self.accessibilityEnabled
        case .bottomOffset:
            return self.overlayAtBottom
        case .audioCheck:
            return self.dictionaryMatcherEnabled
        default:
            return true
        }
    }
}

enum SettingsSearchIndex {
    private static let queryStopWords: Set<String> = ["and", "for", "from", "in", "of", "or", "the", "to", "with"]

    private struct Entry {
        let target: SettingsSearchTarget
        let title: String
        let terms: [String]
    }

    private struct WeightedField {
        let text: String
        let weight: Int
    }

    private static let entries: [Entry] = [
        .init(target: .general, title: "General", terms: ["app settings preferences"]),
        .init(
            target: .launchAtStartup,
            title: "Launch at login",
            terms: ["Start FluidWispr when you log in", "login startup boot open"]
        ),
        .init(
            target: .showWindowAtLogin,
            title: "Window at login",
            terms: ["opens quietly in the menu bar", "login window visibility"]
        ),
        .init(
            target: .dockVisibility,
            title: "Hide from Dock",
            terms: ["menu bar only", "dock icon command tab cmd tab app switcher"]
        ),
        .init(
            target: .transcriptionSounds,
            title: "Sound cues",
            terms: ["recording sound cue volume start stop audio"]
        ),
        .init(
            target: .automaticUpdates,
            title: "Check for updates",
            terms: ["beta releases release notes previous versions rollback version update pop-ups install"]
        ),

        .init(target: .dictation, title: "Dictation", terms: ["typing transcription keyboard preferences"]),
        .init(
            target: .microphonePermission,
            title: "Microphone permission",
            terms: ["mic access authorization privacy allow denied system settings"]
        ),
        .init(
            target: .pressToTalk,
            title: "Press to talk",
            terms: ["dictation mode press once start again stop toggle key"]
        ),
        .init(
            target: .holdToTalk,
            title: "Hold to talk",
            terms: ["dictation mode hold key let go paste push"]
        ),
        .init(
            target: .microphoneTest,
            title: "Microphone",
            terms: ["test microphone mic input device level pill"]
        ),
        .init(
            target: .copyToClipboard,
            title: "Keep a copy",
            terms: ["copy to clipboard pasteboard backup each dictation"]
        ),
        .init(
            target: .textInsertionMode,
            title: "Paste method",
            terms: ["clipboard paste direct paste text insertion delivery type"]
        ),
        .init(
            target: .transcriptionHistory,
            title: "Save history",
            terms: ["stats privacy remember transcript"]
        ),
        .init(
            target: .audioHistory,
            title: "Save audio",
            terms: ["keep recording with history microphone audio"]
        ),
        .init(
            target: .usageStreak,
            title: "Weekend streaks",
            terms: ["Saturday Sunday stats usage streak weekday"]
        ),
        .init(
            target: .skipSilentRecordings,
            title: "Skip silence",
            terms: ["silent recordings quiet ignore"]
        ),
        .init(
            target: .pauseMedia,
            title: "Pause media",
            terms: ["music video playback resume"]
        ),
        .init(
            target: .dictionarySuggestions,
            title: "Learn from fixes",
            terms: ["corrections ask after learn words dictionary retype"]
        ),

        .init(
            target: .textFormatting,
            title: "Formatting",
            terms: [
                "Smart capitals Lowercase start Final full stop Space between Slash and @",
                "punctuation uppercase capitalization period symbols mentions rules",
            ]
        ),
        .init(target: .spokenFormatting, title: "Spoken formatting", terms: ["punctuation start word symbols new line paragraph"]),
        .init(target: .fillerWords, title: "Filler words", terms: ["um uh er remove filler sounds edit list"]),
        .init(
            target: .spokenSend,
            title: "Spoken send",
            terms: ["send phrase send key send at once enter return submit voice"]
        ),

        .init(target: .shortcuts, title: "Shortcuts", terms: ["keyboard hotkeys keys"]),
        .init(
            target: .accessibilityPermission,
            title: "Accessibility permission",
            terms: ["shortcuts access macOS system settings allow"]
        ),
        .init(target: .globalHotkey, title: "Global hotkey", terms: ["keyboard shortcut dictation key accessibility"]),
        .init(
            target: .primaryDictationShortcuts,
            title: "Press to talk shortcut",
            terms: ["primary dictation keyboard shortcut mouse button record hotkey add"]
        ),
        .init(target: .commandModeShortcut, title: "Command mode", terms: ["voice commands advanced hotkey shortcut"]),
        .init(target: .editModeShortcut, title: "Edit mode", terms: ["rewrite selected text advanced hotkey shortcut"]),
        .init(
            target: .cancelRecordingShortcut,
            title: "Cancel",
            terms: ["cancel recording stop without pasting hotkey shortcut escape"]
        ),
        .init(
            target: .pasteLastTranscriptionShortcut,
            title: "Paste last",
            terms: ["paste last dictation again reinsert hotkey shortcut"]
        ),
        .init(
            target: .pasteRawInsteadShortcut,
            title: "Paste raw instead",
            terms: ["undo ai cleanup original transcript swap last paste hotkey shortcut"]
        ),
        .init(target: .holdSpaceToMute, title: "Space to mute", terms: ["hold space pause mute spacebar"]),

        .init(target: .notifications, title: "Notifications", terms: ["alerts warnings"]),
        .init(
            target: .aiEnhancementFailures,
            title: "Cleanup failed",
            terms: ["notify cleanup error raw words pasted alert"]
        ),
        .init(
            target: .microphoneChanges,
            title: "Microphone changes",
            terms: ["mic device lost switched alert notification"]
        ),
        .init(
            target: .pasteCheck,
            title: "Paste check",
            terms: ["text not pasted landed confirm delivery failure alert"]
        ),

        .init(target: .audio, title: "Audio", terms: ["sound devices microphone speaker"]),
        .init(
            target: .inputDevicePriority,
            title: "Microphones",
            terms: ["microphone mic order drag reorder restore removed not connected in use bluetooth"]
        ),
        .init(
            target: .outputDevice,
            title: "Output",
            terms: ["output device speaker headphones sound cues"]
        ),

        .init(target: .overlay, title: "Overlay", terms: ["pill shows pill size recording indicator try a dictation"]),
        .init(
            target: .overlayPosition,
            title: "Position",
            terms: ["overlay position pill top bottom screen location"]
        ),
        .init(target: .bottomOffset, title: "From bottom", terms: ["bottom offset distance screen edge pixels"]),

        .init(target: .voiceEngine, title: "Voice engine", terms: ["speech model transcription download language parakeet whisper nemotron"]),
        .init(target: .cleanup, title: "Cleanup", terms: ["AI cleanup providers styles advanced"]),
        .init(target: .cleanupProvider, title: "Clean up with", terms: ["cleanup provider Cerebras model default reasoning effort time limit budget"]),
        .init(target: .cleanupKey, title: "API key", terms: ["Cerebras key Keychain check key"]),
        .init(target: .cleanupOffline, title: "Offline", terms: ["Ollama local model qwen offline"]),

        .init(
            target: .dataAndDiagnostics,
            title: "Data and diagnostics",
            terms: ["backup restore logs saved audio analytics reset troubleshooting"]
        ),
        .init(
            target: .backupAndRestore,
            title: "Backup",
            terms: ["export import backup settings styles history stats"]
        ),
        .init(
            target: .audioStorage,
            title: "Saved audio",
            terms: ["audio storage keep up to GB export delete prune recordings"]
        ),
        .init(
            target: .debugLogs,
            title: "Logs",
            terms: ["debug logs log file Finder crash details troubleshooting"]
        ),
        .init(
            target: .analyticsPrivacy,
            title: "Analytics",
            terms: ["detailed anonymous analytics what we collect privacy telemetry"]
        ),
        .init(target: .resetAllSettings, title: "Reset all settings", terms: ["reset defaults back to how it shipped"]),

        .init(
            target: .experimental,
            title: "Experimental",
            terms: ["preview early access optional features"]
        ),
        .init(
            target: .returnToStartingField,
            title: "Return to field",
            terms: ["return to starting field paste where you started switch apps cursor"]
        ),
        .init(
            target: .fasterLongDictation,
            title: "Faster long dictation",
            terms: ["Parakeet reuse parts already done"]
        ),
        .init(
            target: .dictionaryMatcherExperiments,
            title: "Learn how you say words",
            terms: ["pronunciation voice matching dictionary"]
        ),
        .init(target: .audioCheck, title: "Audio check", terms: ["dictionary words heard pronunciation inspection"]),
        .init(
            target: .historyPerformance,
            title: "Timings in History",
            terms: ["show performance transcription cleanup time speed"]
        ),
    ]

    static func results(for query: String) -> [SettingsSearchResult] {
        let normalizedQuery = self.normalize(query)
        guard !normalizedQuery.isEmpty else { return [] }

        let rankedResults: [(index: Int, result: SettingsSearchResult)] = self.entries.enumerated().compactMap { index, entry in
            guard entry.target != .commandModeShortcut || FluidWisprBuild.includesCommandMode,
                  let score = self.score(entry, for: normalizedQuery)
            else { return nil }
            return (index, SettingsSearchResult(target: entry.target, score: score))
        }

        return rankedResults.sorted { lhs, rhs in
            if lhs.result.score == rhs.result.score {
                return lhs.index < rhs.index
            }
            return lhs.result.score > rhs.result.score
        }
        .map(\.result)
    }

    static func results(
        for query: String,
        availability: SettingsSearchAvailability
    ) -> [SettingsSearchResult] {
        self.results(for: query).filter { availability.includes($0.target) }
    }

    static func title(for target: SettingsSearchTarget) -> String {
        self.entries.first { $0.target == target }?.title ?? target.section.title
    }

    static func matchingSections(for query: String) -> [SettingsSection] {
        let matchingSections = Set(self.results(for: query).map(\.section))
        return SettingsSection.allCases.filter(matchingSections.contains)
    }

    static func preferredSection(
        current: SettingsSection?,
        results: [SettingsSearchResult]
    ) -> SettingsSection? {
        guard !results.isEmpty else { return current }
        if let current, results.contains(where: { $0.section == current }) {
            return current
        }
        return results.first?.section
    }

    private static func score(_ entry: Entry, for query: String) -> Int? {
        let fields = [
            WeightedField(text: entry.title, weight: 100),
            WeightedField(text: entry.target.section.title, weight: 45),
        ] + entry.terms.map { WeightedField(text: $0, weight: 55) }

        let allQueryTokens = self.tokens(in: query)
        let meaningfulQueryTokens = allQueryTokens.filter { !self.queryStopWords.contains($0) }
        let queryTokens = meaningfulQueryTokens.isEmpty ? allQueryTokens : meaningfulQueryTokens
        let compactQuery = self.compact(query)
        let compactCandidates = fields.flatMap { field in
            var candidates = [self.compact(self.normalize(field.text))]
            for token in self.tokens(in: field.text) {
                candidates.append(self.compact(token))
            }
            return candidates
        }
        let hasCompactFuzzyMatch = compactQuery.count >= 4 &&
            compactCandidates.contains(where: { self.isFuzzyMatch(query: compactQuery, candidate: $0) })
        var score = 0

        for queryToken in queryTokens {
            let bestTokenScore = fields.compactMap { field -> Int? in
                self.tokens(in: field.text)
                    .compactMap { self.tokenScore(query: queryToken, candidate: $0) }
                    .max()
                    .map { $0 + field.weight }
            }.max()

            if let bestTokenScore {
                score += bestTokenScore
            } else if !hasCompactFuzzyMatch {
                return nil
            }
        }

        let normalizedTitle = self.normalize(entry.title)
        let normalizedSection = self.normalize(entry.target.section.title)
        score += self.phraseBonus(query: query, candidate: normalizedTitle, exactBonus: 1000)
        score += self.phraseBonus(query: query, candidate: normalizedSection, exactBonus: 400)

        for term in entry.terms {
            score += self.phraseBonus(query: query, candidate: self.normalize(term), exactBonus: 220)
        }

        if hasCompactFuzzyMatch {
            score += 180
        }

        return score
    }

    private static func phraseBonus(query: String, candidate: String, exactBonus: Int) -> Int {
        if candidate == query {
            return exactBonus
        }
        if candidate.hasPrefix(query) {
            return exactBonus * 3 / 5
        }
        if query.count >= 3, candidate.contains(query) {
            return exactBonus * 2 / 5
        }
        return 0
    }

    private static func tokenScore(query: String, candidate: String) -> Int? {
        if candidate == query {
            return 120
        }
        if candidate.hasPrefix(query) {
            return 105
        }
        if query.count >= 3, candidate.contains(query) {
            return 90
        }
        if self.isFuzzyMatch(query: query, candidate: candidate) {
            return 70 - (self.editDistance(query, candidate) * 8)
        }
        return nil
    }

    private static func isFuzzyMatch(query: String, candidate: String) -> Bool {
        let tolerance: Int
        switch query.count {
        case 0...3:
            return false
        case 4...6:
            tolerance = 1
        default:
            tolerance = 2
        }

        guard abs(query.count - candidate.count) <= tolerance else { return false }
        return self.editDistance(query, candidate) <= tolerance
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty else { return right.count }
        guard !right.isEmpty else { return left.count }

        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            current.reserveCapacity(right.count + 1)

            for (rightIndex, rightCharacter) in right.enumerated() {
                current.append(min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous[right.count]
    }

    private static func normalize(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        let separated = folded.map { character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(separated)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func tokens(in value: String) -> [String] {
        self.normalize(value).split(separator: " ").map(String.init)
    }

    private static func compact(_ value: String) -> String {
        value.filter { !$0.isWhitespace }
    }
}

/// An `NSSearchField` for a sidebar, drawn as Record/Search: a 28 pt capsule with no
/// magnifier, sunken at rest and raised with the ink ring while focused. Esc clears it.
/// Up, Down and Return are handed to `onCommand` so a results list can be driven from
/// the keyboard, and Cmd+F (`Notification.Name.sidebarSearchFocusRequested`) focuses
/// whichever instance is active.
struct SidebarSearchField: View {
    @Binding var text: String
    let placeholder: String
    let isActive: Bool
    var onCommand: (Selector) -> Bool = { _ in false }
    @State private var isFocused = false

    var body: some View {
        HStack(spacing: FWMetric.space2) {
            SidebarSearchInput(
                text: self.$text,
                placeholder: self.placeholder,
                isActive: self.isActive,
                onCommand: self.onCommand,
                isFocused: self.$isFocused
            )
            if !self.text.isEmpty {
                Button {
                    self.text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.fluidSystem(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(FWColor.textPrimary, FWColor.lineStrong)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, FWMetric.space4)
        .padding(.trailing, self.text.isEmpty ? FWMetric.space4 : FWMetric.space2)
        .frame(height: FWMetric.sizeControlM)
        .background(Capsule().fill(self.isFocused ? FWColor.surfaceRaised : FWColor.surfaceSunken))
        .overlay {
            if self.isFocused {
                Capsule().strokeBorder(FWColor.lineStrong, lineWidth: FWMetric.lineHairline)
            }
        }
        .recordFocusRing(self.isFocused, in: Capsule())
    }

    static func owns(_ editor: NSTextView, in window: NSWindow) -> Bool {
        SidebarSearchInput.owns(editor, in: window)
    }

    static func resignFocusIfNeeded(from searchField: NSSearchField, isActive: Bool) {
        SidebarSearchInput.resignFocusIfNeeded(from: searchField, isActive: isActive)
    }
}

private final class SidebarSearchNativeField: NSSearchField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { self.onFocus?() }
        return accepted
    }
}

private struct SidebarSearchInput: NSViewRepresentable {
    private static let identifier = NSUserInterfaceItemIdentifier("FluidVoice.SidebarSearchField")

    @Binding var text: String
    let placeholder: String
    let isActive: Bool
    var onCommand: (Selector) -> Bool = { _ in false }

    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = SidebarSearchNativeField()
        searchField.onFocus = { [weak coordinator = context.coordinator] in
            coordinator?.parent.isFocused = true
        }
        searchField.delegate = context.coordinator
        searchField.placeholderString = self.placeholder
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.controlSize = .regular
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        (searchField.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        (searchField.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        searchField.font = .fluidSystemFont(ofSize: FWType.detail.size, weight: .regular)
        searchField.identifier = Self.identifier
        searchField.setAccessibilityLabel(self.placeholder)
        context.coordinator.observeFocusRequests(for: searchField)
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if searchField.stringValue != self.text {
            searchField.stringValue = self.text
        }
        Self.resignFocusIfNeeded(from: searchField, isActive: self.isActive)
    }

    static func resignFocusIfNeeded(from searchField: NSSearchField, isActive: Bool) {
        guard !isActive,
              searchField.currentEditor() != nil,
              let window = searchField.window
        else { return }

        window.makeFirstResponder(nil)
    }

    static func owns(_ editor: NSTextView, in window: NSWindow) -> Bool {
        guard editor.isFieldEditor, let contentView = window.contentView else { return false }
        var views = [contentView]
        while let view = views.popLast() {
            if let searchField = view as? NSSearchField,
               searchField.identifier == Self.identifier,
               searchField.currentEditor() === editor
            {
                return true
            }
            views.append(contentsOf: view.subviews)
        }
        return false
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SidebarSearchInput
        private var focusObserver: NSObjectProtocol?

        init(_ parent: SidebarSearchInput) {
            self.parent = parent
        }

        deinit {
            self.focusObserver.map(NotificationCenter.default.removeObserver)
        }

        func observeFocusRequests(for searchField: NSSearchField) {
            self.focusObserver = NotificationCenter.default.addObserver(
                forName: .sidebarSearchFocusRequested, object: nil, queue: .main
            ) { [weak self, weak searchField] _ in
                guard let self, self.parent.isActive, let searchField else { return }
                searchField.window?.makeFirstResponder(searchField)
            }
        }

        func controlTextDidBeginEditing(_: Notification) {
            self.parent.isFocused = true
        }

        func controlTextDidEndEditing(_: Notification) {
            self.parent.isFocused = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            self.parent.text = searchField.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else {
                return self.parent.onCommand(commandSelector)
            }
            textView.string = ""
            control.stringValue = ""
            self.parent.text = ""
            return true
        }
    }
}

extension Notification.Name {
    static let sidebarSearchFocusRequested = Notification.Name("FluidVoice.sidebarSearchFocusRequested")
}
