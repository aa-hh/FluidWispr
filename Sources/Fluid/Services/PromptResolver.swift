//
//  PromptResolver.swift
//  fluid
//
//  Decides which prompt a dictation or edit request uses: a shortcut's chosen profile,
//  an app binding, the user's default override or the built-in default. It reads the
//  stored choices through PromptResolverSettings, so tests can resolve prompts without
//  SettingsStore.shared.
//

import Foundation

/// The stored prompt choices the resolver reads. SettingsStore provides them.
protocol PromptResolverSettings {
    var dictationPromptProfiles: [SettingsStore.DictationPromptProfile] { get }
    var isEditPromptOff: Bool { get }
    func dictationPromptSelection(for slot: SettingsStore.DictationShortcutSlot) -> SettingsStore.DictationPromptSelection
    func selectedPromptID(for mode: SettingsStore.PromptMode) -> String?
    func promptRoutingScope(for mode: SettingsStore.PromptMode) -> SettingsStore.PromptRoutingScope
    func appPromptBinding(for mode: SettingsStore.PromptMode, appBundleID: String?) -> SettingsStore.AppPromptBinding?
    func defaultPromptOverride(for mode: SettingsStore.PromptMode) -> String?
}

extension SettingsStore: PromptResolverSettings {}

struct PromptResolver {
    typealias PromptMode = SettingsStore.PromptMode
    typealias PromptResolution = SettingsStore.PromptResolution
    typealias PromptResolutionSource = SettingsStore.PromptResolutionSource
    typealias DictationPromptProfile = SettingsStore.DictationPromptProfile
    typealias DictationPromptSelection = SettingsStore.DictationPromptSelection
    typealias DictationShortcutSlot = SettingsStore.DictationShortcutSlot
    typealias AppPromptBinding = SettingsStore.AppPromptBinding

    let settings: any PromptResolverSettings
    /// A prompt picked from the overlay for an app, which wins over stored choices.
    let manualChoice: (DictationShortcutSlot, String?) -> DictationPromptSelection?

    init(
        settings: any PromptResolverSettings,
        manualChoice: @escaping (DictationShortcutSlot, String?) -> DictationPromptSelection? = { slot, appID in
            DictationAppSession.shared.choice(for: slot, appID: appID)
        }
    ) {
        self.settings = settings
        self.manualChoice = manualChoice
    }

    static func dictationSelectionSupportsAppOverride(_ selection: DictationPromptSelection) -> Bool {
        selection == .default || selection == .privateAI
    }

    // MARK: - Dictation selection

    func resolvedDictationPromptSelection(for slot: DictationShortcutSlot, appBundleID: String?) -> DictationPromptSelection {
        if let manual = self.manualChoice(slot, appBundleID) { return manual }
        let selection = self.settings.dictationPromptSelection(for: slot)
        guard selection != .off else { return .off }
        let appOnly = self.settings.promptRoutingScope(for: .dictate) == .selectedAppsOnly
        guard appOnly || Self.dictationSelectionSupportsAppOverride(selection) else { return selection }
        guard let binding = self.settings.appPromptBinding(for: .dictate, appBundleID: appBundleID) else {
            return appOnly ? .off : selection
        }
        guard let id = binding.promptID,
              self.dictationProfile(id: id) != nil
        else { return .default }
        return .profile(id)
    }

    func resolvedDictationPromptProfile(for slot: DictationShortcutSlot, appBundleID: String?) -> DictationPromptProfile? {
        switch self.resolvedDictationPromptSelection(for: slot, appBundleID: appBundleID) {
        case .off:
            return nil
        case let .profile(promptID):
            return self.dictationProfile(id: promptID)
        case .default, .privateAI:
            guard self.manualChoice(slot, appBundleID) == nil else { return nil }
            guard let binding = self.settings.appPromptBinding(for: .dictate, appBundleID: appBundleID) else { return nil }
            let promptID = binding.promptID
            return self.settings.dictationPromptProfiles.first {
                $0.id == promptID && $0.mode.normalized == .dictate
            }
        }
    }

    func isAppDictationPromptBindingActive(for slot: DictationShortcutSlot, appBundleID: String?) -> Bool {
        guard self.manualChoice(slot, appBundleID) == nil else { return false }
        let selection = self.settings.dictationPromptSelection(for: slot)
        guard Self.dictationSelectionSupportsAppOverride(selection) else { return false }
        return self.settings.appPromptBinding(for: .dictate, appBundleID: appBundleID) != nil
    }

    func dictationPromptDisplayName(for slot: DictationShortcutSlot, appBundleID: String?) -> String {
        switch self.resolvedDictationPromptSelection(for: slot, appBundleID: appBundleID) {
        case .off:
            return "Basic"
        case .default:
            if let profile = self.resolvedDictationPromptProfile(for: slot, appBundleID: appBundleID) {
                return Self.displayName(of: profile)
            }
            return "Default"
        case .privateAI:
            if self.isAppDictationPromptBindingActive(for: slot, appBundleID: appBundleID) {
                if let profile = self.resolvedDictationPromptProfile(for: slot, appBundleID: appBundleID) {
                    return Self.displayName(of: profile)
                }
                return "Default"
            }
            return SettingsStore.DictationModeLabels.smart
        case let .profile(promptID):
            guard let profile = self.dictationProfile(id: promptID) else { return "Default" }
            return Self.displayName(of: profile)
        }
    }

    // MARK: - Prompt text

    func promptResolution(for mode: PromptMode, appBundleID: String? = nil) -> PromptResolution {
        let normalizedMode = mode.normalized

        if normalizedMode == .edit, self.settings.isEditPromptOff {
            return self.defaultPromptResolution(
                for: normalizedMode,
                source: .builtInDefault,
                appBinding: nil,
                allowDefaultOverride: false
            )
        }

        if let binding = self.settings.appPromptBinding(for: normalizedMode, appBundleID: appBundleID) {
            if let promptID = binding.promptID,
               let profile = self.settings.dictationPromptProfiles.first(where: {
                   $0.id == promptID &&
                       $0.mode.normalized == normalizedMode
               })
            {
                let body = SettingsStore.customPromptBody(profile.prompt, mode: normalizedMode)
                if !body.isEmpty || (profile.mode.normalized == .dictate && !profile.usesLegacyEmptyPromptFallback) {
                    return PromptResolution(
                        source: .appBindingProfile,
                        profile: profile,
                        appBinding: binding,
                        promptBody: body,
                        systemPrompt: Self.systemPrompt(forCustomProfileBody: body, mode: normalizedMode)
                    )
                }
            }

            return self.defaultPromptResolution(
                for: normalizedMode,
                source: .appBindingDefault,
                appBinding: binding
            )
        }

        if self.settings.promptRoutingScope(for: normalizedMode) == .selectedAppsOnly {
            return self.defaultPromptResolution(
                for: normalizedMode,
                source: .builtInDefault,
                appBinding: nil,
                allowDefaultOverride: false
            )
        }

        if let profile = self.selectedPromptProfile(for: normalizedMode) {
            let body = SettingsStore.customPromptBody(profile.prompt, mode: normalizedMode)
            if !body.isEmpty || (profile.mode.normalized == .dictate && !profile.usesLegacyEmptyPromptFallback) {
                return PromptResolution(
                    source: .selectedProfile,
                    profile: profile,
                    appBinding: nil,
                    promptBody: body,
                    systemPrompt: Self.systemPrompt(forCustomProfileBody: body, mode: normalizedMode)
                )
            }
        }

        return self.defaultPromptResolution(for: normalizedMode, source: .defaultOverride, appBinding: nil)
    }

    func effectiveDictationPromptBody(for slot: DictationShortcutSlot, appBundleID: String? = nil) -> String {
        self.effectiveDictationPrompt(for: slot, appBundleID: appBundleID, system: false)
    }

    func effectiveDictationSystemPrompt(for slot: DictationShortcutSlot, appBundleID: String? = nil) -> String {
        self.effectiveDictationPrompt(for: slot, appBundleID: appBundleID, system: true)
    }

    /// Use the same explicit custom prompt for shortcut and app-based selection.
    static func shortcutOverrideSystemPrompt(for profile: DictationPromptProfile, mode: PromptMode = .dictate) -> String? {
        if mode.normalized == .dictate, profile.usesLegacyEmptyPromptFallback {
            return profile.legacyEmptyShortcutUsesBasePrompt ? SettingsStore.baseDictationPromptText() : nil
        }
        return self.systemPrompt(
            forCustomProfileBody: SettingsStore.customPromptBody(profile.prompt, mode: mode),
            mode: mode
        )
    }

    // MARK: - Helpers

    /// With Off selected the body is empty but the system prompt still resolves.
    private func effectiveDictationPrompt(for slot: DictationShortcutSlot, appBundleID: String?, system: Bool) -> String {
        if let manual = self.manualChoice(slot, appBundleID) {
            return self.manualDictationPrompt(manual, system: system)
        }
        let selection = self.settings.dictationPromptSelection(for: slot)
        if self.settings.promptRoutingScope(for: .dictate) == .selectedAppsOnly {
            guard selection != .off else { return "" }
            return self.globalDictationPrompt(appBundleID: appBundleID, system: system)
        }

        switch selection {
        case .off:
            return system ? self.globalDictationPrompt(appBundleID: appBundleID, system: true) : ""
        case .default, .privateAI:
            return self.globalDictationPrompt(appBundleID: appBundleID, system: system)
        case let .profile(promptID):
            guard let profile = self.dictationProfile(id: promptID) else {
                return self.globalDictationPrompt(appBundleID: appBundleID, system: system)
            }
            let body = SettingsStore.customPromptBody(profile.prompt, mode: .dictate)
            if !body.isEmpty || !profile.usesLegacyEmptyPromptFallback {
                return system ? Self.systemPrompt(forCustomProfileBody: body, mode: .dictate) : body
            }
            return self.globalDictationPrompt(appBundleID: appBundleID, system: system)
        }
    }

    private func globalDictationPrompt(appBundleID: String?, system: Bool) -> String {
        let resolution = self.promptResolution(for: .dictate, appBundleID: appBundleID)
        return system ? resolution.systemPrompt : resolution.promptBody
    }

    private func manualDictationPrompt(_ selection: DictationPromptSelection, system: Bool) -> String {
        if selection == .off { return "" }
        if case let .profile(id) = selection, let profile = self.dictationProfile(id: id) {
            let body = SettingsStore.customPromptBody(profile.prompt, mode: .dictate)
            if !body.isEmpty || !profile.usesLegacyEmptyPromptFallback {
                return system ? Self.systemPrompt(forCustomProfileBody: body, mode: .dictate) : body
            }
        }
        let fallback = self.defaultPromptResolution(for: .dictate, source: .defaultOverride, appBinding: nil)
        return system ? fallback.systemPrompt : fallback.promptBody
    }

    private func dictationProfile(id: String) -> DictationPromptProfile? {
        self.settings.dictationPromptProfiles.first { $0.id == id && $0.mode.normalized == .dictate }
    }

    private func selectedPromptProfile(for mode: PromptMode) -> DictationPromptProfile? {
        guard let id = self.settings.selectedPromptID(for: mode) else { return nil }
        let target = mode.normalized
        return self.settings.dictationPromptProfiles.first { $0.id == id && $0.mode.normalized == target }
    }

    private static func displayName(of profile: DictationPromptProfile) -> String {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Untitled" : name
    }

    private func defaultPromptResolution(
        for mode: PromptMode,
        source: PromptResolutionSource,
        appBinding: AppPromptBinding?,
        allowDefaultOverride: Bool = true
    ) -> PromptResolution {
        if allowDefaultOverride, let override = self.settings.defaultPromptOverride(for: mode) {
            let trimmedOverride = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedOverride.isEmpty {
                return PromptResolution(
                    source: source,
                    profile: nil,
                    appBinding: appBinding,
                    promptBody: "",
                    systemPrompt: override
                )
            }

            let body = SettingsStore.stripBasePrompt(for: mode, from: trimmedOverride)
            return PromptResolution(
                source: source,
                profile: nil,
                appBinding: appBinding,
                promptBody: body,
                systemPrompt: SettingsStore.combineBasePrompt(for: mode, with: body)
            )
        }

        let defaultBody = SettingsStore.defaultPromptBodyText(for: mode)
        let fallbackSource: PromptResolutionSource = source == .defaultOverride ? .builtInDefault : source
        return PromptResolution(
            source: fallbackSource,
            profile: nil,
            appBinding: appBinding,
            promptBody: defaultBody,
            systemPrompt: SettingsStore.combineBasePrompt(for: mode, with: defaultBody)
        )
    }

    private static func systemPrompt(forCustomProfileBody body: String, mode: PromptMode) -> String {
        let normalizedMode = mode.normalized
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedMode == .dictate {
            return body
        }
        return SettingsStore.combineBasePrompt(for: normalizedMode, with: trimmedBody)
    }
}
