import Foundation

// The backup table. Each SettingsBackupPayload field has one entry here, and the
// entries run in this order on restore. Adding a setting to backups means adding
// a payload field and one entry; Tests/run_backup_coverage_tests.py checks both
// against SettingsStore.Keys.

extension SettingsStore {
    struct BackupRestoreSource {
        let payload: SettingsBackupPayload
        let promptProfiles: [DictationPromptProfile]
        let appPromptBindings: [AppPromptBinding]
    }

    struct BackupFieldValue: Encodable {
        private let write: (Encoder) throws -> Void

        init<Value: Encodable>(_ value: Value) {
            self.write = { encoder in
                var container = encoder.singleValueContainer()
                try container.encode(value)
            }
        }

        func encode(to encoder: Encoder) throws {
            try self.write(encoder)
        }
    }

    struct BackupEntry {
        /// The SettingsBackupPayload field name, or nil for a restore step that owns no field.
        let name: String?
        let export: (SettingsStore) -> BackupFieldValue?
        let restore: (SettingsStore, BackupRestoreSource) -> Void

        /// Exported as is; restore copies the backup value.
        static func value<Value: Encodable>(
            _ name: String,
            _ field: KeyPath<SettingsBackupPayload, Value>,
            _ setting: ReferenceWritableKeyPath<SettingsStore, Value>
        ) -> Self {
            Self(
                name: name,
                export: { BackupFieldValue($0[keyPath: setting]) },
                restore: { store, source in store[keyPath: setting] = source.payload[keyPath: field] }
            )
        }

        /// The field is optional for older backups; when it is absent, restore keeps the current value.
        static func keepIfAbsent<Value: Encodable>(
            _ name: String,
            _ field: KeyPath<SettingsBackupPayload, Value?>,
            _ setting: ReferenceWritableKeyPath<SettingsStore, Value>
        ) -> Self {
            Self(
                name: name,
                export: { BackupFieldValue($0[keyPath: setting]) },
                restore: { store, source in
                    if let value = source.payload[keyPath: field] {
                        store[keyPath: setting] = value
                    }
                }
            )
        }

        /// The field is optional for older backups; when it is absent, restore sets `fallback`.
        static func orDefault<Value: Encodable>(
            _ name: String,
            _ field: KeyPath<SettingsBackupPayload, Value?>,
            _ setting: ReferenceWritableKeyPath<SettingsStore, Value>,
            _ fallback: Value
        ) -> Self {
            Self(
                name: name,
                export: { BackupFieldValue($0[keyPath: setting]) },
                restore: { store, source in store[keyPath: setting] = source.payload[keyPath: field] ?? fallback }
            )
        }

        static func custom(
            _ name: String,
            export: @escaping (SettingsStore) -> BackupFieldValue?,
            restore: @escaping (SettingsStore, BackupRestoreSource) -> Void = { _, _ in }
        ) -> Self {
            Self(name: name, export: export, restore: restore)
        }

        static func step(_ restore: @escaping (SettingsStore, BackupRestoreSource) -> Void) -> Self {
            Self(name: nil, export: { _ in nil }, restore: restore)
        }
    }

    static let backupEntries: [BackupEntry] = providerBackupEntries
        + speechBackupEntries
        + shortcutBackupEntries
        + generalBackupEntries
        + microphoneBackupEntries
        + overlayAndHistoryBackupEntries
        + formattingBackupEntries
        + promptBackupEntries
        + laterBackupEntries

    func makeBackupPayload() throws -> SettingsBackupPayload {
        var fields: [String: BackupFieldValue] = [:]
        for entry in Self.backupEntries {
            if let name = entry.name, let value = entry.export(self) {
                fields[name] = value
            }
        }
        // Decoding checks the table: a required payload field with no entry fails here.
        return try JSONDecoder().decode(SettingsBackupPayload.self, from: JSONEncoder().encode(fields))
    }

    func restore(from payload: SettingsBackupPayload) {
        self.restore(from: payload, promptProfiles: self.dictationPromptProfiles, appPromptBindings: self.appPromptBindings)
    }

    func restore(
        from payload: SettingsBackupPayload,
        promptProfiles: [DictationPromptProfile],
        appPromptBindings: [AppPromptBinding]
    ) {
        let source = BackupRestoreSource(payload: payload, promptProfiles: promptProfiles, appPromptBindings: appPromptBindings)
        for entry in Self.backupEntries {
            entry.restore(self, source)
        }
    }

    private static let providerBackupEntries: [BackupEntry] = [
        .value("savedProviders", \.savedProviders, \.savedProviders),
        .value("selectedProviderID", \.selectedProviderID, \.selectedProviderID),
        .value("selectedModelByProvider", \.selectedModelByProvider, \.selectedModelByProvider),
        .value("modelReasoningConfigs", \.modelReasoningConfigs, \.modelReasoningConfigs),
        .keepIfAbsent("privateAIPrefixKVCacheEnabled", \.privateAIPrefixKVCacheEnabled, \.privateAIPrefixKVCacheEnabled),
        .keepIfAbsent("privateAIBoostEnabled", \.privateAIBoostEnabled, \.privateAIBoostEnabled),
        .keepIfAbsent("privateAIBackendPreference", \.privateAIBackendPreference, \.privateAIBackendPreference),
        .keepIfAbsent("privateAIContextTokenLimit", \.privateAIContextTokenLimit, \.privateAIContextTokenLimit),
        .keepIfAbsent("privateAIIdleUnload", \.privateAIIdleUnload, \.privateAIIdleUnload),
    ]

    private static let speechBackupEntries: [BackupEntry] = [
        .value("selectedSpeechModel", \.selectedSpeechModel, \.selectedSpeechModel),
        .custom(
            "selectedWhisperLanguageCode",
            export: { BackupFieldValue(SettingsStore.whisperLanguageBackupValue(for: $0.selectedWhisperLanguageCode)) },
            restore: { store, source in
                if let value = source.payload.selectedWhisperLanguageCode {
                    store.selectedWhisperLanguageCode = SettingsStore.whisperLanguageCode(fromBackupValue: value)
                }
            }
        ),
        .value("selectedCohereLanguage", \.selectedCohereLanguage, \.selectedCohereLanguage),
        .keepIfAbsent("selectedNemotronLanguage", \.selectedNemotronLanguage, \.selectedNemotronLanguage),
        .keepIfAbsent("selectedAppleSpeechLocaleIdentifier", \.selectedAppleSpeechLocaleIdentifier, \.selectedAppleSpeechLocaleIdentifier),
        // A backup predating this setting represents an absent selection, which resolves to the
        // current phase's local default. Unknown stored IDs remain intact and visibly unavailable.
        .custom(
            "meetingTranscriptionBackendID",
            export: { BackupFieldValue($0.meetingTranscriptionBackendID.rawValue) },
            restore: { store, source in
                store.meetingTranscriptionBackendID = source.payload.meetingTranscriptionBackendID.map {
                    MeetingBackendID(rawValue: $0)
                } ?? .productionDefault
            }
        ),
        .keepIfAbsent("meetingRecordingDefaults", \.meetingRecordingDefaults, \.meetingRecordingDefaults),
    ]

    private static let shortcutBackupEntries: [BackupEntry] = [
        // Written for older builds; restore reads it only when primaryDictationShortcuts is absent.
        .custom("hotkeyShortcut", export: { BackupFieldValue($0.hotkeyShortcut) }),
        .custom(
            "primaryDictationShortcuts",
            export: { BackupFieldValue($0.primaryDictationShortcuts) },
            restore: { store, source in
                store.primaryDictationShortcuts = source.payload.primaryDictationShortcuts ?? [source.payload.hotkeyShortcut]
            }
        ),
        .value("promptModeHotkeyShortcut", \.promptModeHotkeyShortcut, \.promptModeHotkeyShortcut),
        .value("promptModeShortcutEnabled", \.promptModeShortcutEnabled, \.promptModeShortcutEnabled),
        .value("commandModeHotkeyShortcut", \.commandModeHotkeyShortcut, \.commandModeHotkeyShortcut),
        .value("commandModeShortcutEnabled", \.commandModeShortcutEnabled, \.commandModeShortcutEnabled),
        .value("commandModeSelectedModel", \.commandModeSelectedModel, \.commandModeSelectedModel),
        .value("commandModeSelectedProviderID", \.commandModeSelectedProviderID, \.commandModeSelectedProviderID),
        .value("commandModeConfirmBeforeExecute", \.commandModeConfirmBeforeExecute, \.commandModeConfirmBeforeExecute),
        .value("commandModeLinkedToGlobal", \.commandModeLinkedToGlobal, \.commandModeLinkedToGlobal),
        .value("rewriteModeHotkeyShortcut", \.rewriteModeHotkeyShortcut, \.rewriteModeHotkeyShortcut),
        .value("rewriteModeShortcutEnabled", \.rewriteModeShortcutEnabled, \.rewriteModeShortcutEnabled),
        .value("rewriteModeSelectedModel", \.rewriteModeSelectedModel, \.rewriteModeSelectedModel),
        .value("rewriteModeSelectedProviderID", \.rewriteModeSelectedProviderID, \.rewriteModeSelectedProviderID),
        .value("rewriteModeLinkedToGlobal", \.rewriteModeLinkedToGlobal, \.rewriteModeLinkedToGlobal),
        .value("cancelRecordingHotkeyShortcut", \.cancelRecordingHotkeyShortcut, \.cancelRecordingHotkeyShortcut),
        // Guarded so restoring an older backup (which predates this field) doesn't wipe a
        // currently-configured shortcut.
        .custom(
            "pasteLastTranscriptionHotkeyShortcut",
            export: { BackupFieldValue($0.pasteLastTranscriptionHotkeyShortcut) },
            restore: { store, source in
                if let shortcut = source.payload.pasteLastTranscriptionHotkeyShortcut {
                    store.pasteLastTranscriptionHotkeyShortcut = shortcut
                }
            }
        ),
        .keepIfAbsent("pasteLastTranscriptionShortcutEnabled", \.pasteLastTranscriptionShortcutEnabled, \.pasteLastTranscriptionShortcutEnabled),
    ]

    private static let generalBackupEntries: [BackupEntry] = [
        .value("showThinkingTokens", \.showThinkingTokens, \.showThinkingTokens),
        .value("hideFromDockAndAppSwitcher", \.hideFromDockAndAppSwitcher, \.hideFromDockAndAppSwitcher),
        .orDefault("showMainWindowAtLoginLaunch", \.showMainWindowAtLoginLaunch, \.showMainWindowAtLoginLaunch, true),
        .value("accentColorOption", \.accentColorOption, \.accentColorOption),
        .value("transcriptionStartSound", \.transcriptionStartSound, \.transcriptionStartSound),
        .value("transcriptionSoundVolume", \.transcriptionSoundVolume, \.transcriptionSoundVolume),
        // Independent Volume was removed, but the key is still written (always false) so backups
        // from this build decode on app versions that require it. Ignored on restore.
        .custom("transcriptionSoundIndependentVolume", export: { _ in BackupFieldValue(false) }),
        .value("autoUpdateCheckEnabled", \.autoUpdateCheckEnabled, \.autoUpdateCheckEnabled),
        .keepIfAbsent("showUpdatePopups", \.showUpdatePopups, \.showUpdatePopups),
        .value("betaReleasesEnabled", \.betaReleasesEnabled, \.betaReleasesEnabled),
        .value("enableDebugLogs", \.enableDebugLogs, \.enableDebugLogs),
        .value("shareAnonymousAnalytics", \.shareAnonymousAnalytics, \.shareDetailedAnalytics),
        .keepIfAbsent("pressToTalkEnabled", \.pressToTalkEnabled, \.pressToTalkEnabled),
        .keepIfAbsent("holdToTalkEnabled", \.holdToTalkEnabled, \.holdToTalkEnabled),
        .keepIfAbsent("holdToTalkShortcuts", \.holdToTalkShortcuts, \.holdToTalkShortcuts),
        // A backup from an older build in Hold mode moves its shortcuts to Hold to talk, and Press to
        // talk is turned off and gets the default Right Option. "automatic" counts as Press to talk.
        // Any other older mode turns Press to talk on, so the restored shortcut works on an install
        // that the migration put in Hold mode.
        .custom("pressAndHoldMode", export: { _ in nil }),
        .custom(
            "hotkeyMode",
            export: { _ in nil },
            restore: { store, source in
                let payload = source.payload
                let oldModeIsHold = payload.hotkeyMode.map { $0 == HotkeyActivationMode.hold.rawValue } ?? payload.pressAndHoldMode
                guard payload.holdToTalkShortcuts == nil, let oldModeIsHold else { return }
                guard oldModeIsHold else {
                    store.pressToTalkEnabled = true
                    store.holdToTalkEnabled = false
                    return
                }
                store.holdToTalkShortcuts = payload.primaryDictationShortcuts ?? [payload.hotkeyShortcut]
                store.holdToTalkEnabled = true
                store.pressToTalkEnabled = false
                store.primaryDictationShortcuts = [HotkeyShortcut(keyCode: 61, modifierFlags: [])]
            }
        ),
        .orDefault("holdSpaceToMute", \.holdSpaceToMute, \.holdSpaceToMute, false),
        .value("enableStreamingPreview", \.enableStreamingPreview, \.enableStreamingPreview),
        .keepIfAbsent("experimentalParakeetUnifiedFinalEnabled", \.experimentalParakeetUnifiedFinalEnabled, \.experimentalParakeetUnifiedFinalEnabled),
        .keepIfAbsent("returnDictationToStartingField", \.returnDictationToStartingField, \.returnDictationToStartingField),
        .keepIfAbsent("showHistoryPerformanceMetrics", \.showHistoryPerformanceMetrics, \.showHistoryPerformanceMetrics),
        .keepIfAbsent("skipSilentRecordingsEnabled", \.skipSilentRecordingsEnabled, \.skipSilentRecordingsEnabled),
        .value("enableAIStreaming", \.enableAIStreaming, \.enableAIStreaming),
        .value("copyTranscriptionToClipboard", \.copyTranscriptionToClipboard, \.copyTranscriptionToClipboard),
        .value("textInsertionMode", \.textInsertionMode, \.textInsertionMode),
        .keepIfAbsent("spokenSendEnabled", \.spokenSendEnabled, \.spokenSendEnabled),
        .keepIfAbsent("spokenSendImmediatelyEnabled", \.spokenSendImmediatelyEnabled, \.spokenSendImmediatelyEnabled),
        .keepIfAbsent("spokenSendPhrase", \.spokenSendPhrase, \.spokenSendPhrase),
        .keepIfAbsent("spokenSendKey", \.spokenSendKey, \.spokenSendKey),
    ]

    private static let microphoneBackupEntries: [BackupEntry] = [
        .value("preferredInputDeviceUID", \.preferredInputDeviceUID, \.preferredInputDeviceUID),
        .custom(
            "suppressedMicrophoneUIDs",
            export: { BackupFieldValue($0.suppressedMicrophoneUIDs.sorted()) },
            restore: { store, source in store.suppressedMicrophoneUIDs = Set(source.payload.suppressedMicrophoneUIDs ?? []) }
        ),
        .orDefault("microphonePriority", \.microphonePriority, \.microphonePriority, []),
        .value("preferredOutputDeviceUID", \.preferredOutputDeviceUID, \.preferredOutputDeviceUID),
        // Kept in the backup schema for compatibility with older builds.
        // Current builds always resolve microphones from the priority list.
        .custom(
            "microphoneSelectionMode",
            export: { _ in BackupFieldValue(MicrophoneSelectionMode.manual) },
            restore: { store, source in
                if source.payload.microphonePriority != nil {
                    store.microphoneSelectionMode = .manual
                    store.microphoneSelectionMigrationVersion = SettingsStore.microphonePriorityMigrationVersion
                } else if source.payload.microphoneSelectionMode == .system {
                    store.microphoneSelectionMode = .system
                    store.microphoneSelectionMigrationVersion = 0
                } else {
                    store.microphoneSelectionMode = .manual
                }
            }
        ),
    ]

    private static let overlayAndHistoryBackupEntries: [BackupEntry] = [
        .value("visualizerNoiseThreshold", \.visualizerNoiseThreshold, \.visualizerNoiseThreshold),
        .value("overlayPosition", \.overlayPosition, \.overlayPosition),
        .value("overlayBottomOffset", \.overlayBottomOffset, \.overlayBottomOffset),
        .value("overlaySize", \.overlaySize, \.overlaySize),
        .keepIfAbsent("overlayMaterial", \.overlayMaterial, \.overlayMaterial),
        .keepIfAbsent("overlayGlassOpacity", \.overlayGlassOpacity, \.overlayGlassOpacity),
        .keepIfAbsent("overlayTint", \.overlayTint, \.overlayTint),
        .keepIfAbsent("overlayHighlight", \.overlayHighlight, \.overlayHighlight),
        .keepIfAbsent("overlayClosingAnimationEnabled", \.overlayClosingAnimationEnabled, \.overlayClosingAnimationEnabled),
        .keepIfAbsent("recordingPillVisibility", \.recordingPillVisibility, \.recordingPillVisibility),
        .keepIfAbsent("recordingPillSize", \.recordingPillSize, \.recordingPillSize),
        .keepIfAbsent("recordingPillDock", \.recordingPillDock, \.recordingPillDock),
        .keepIfAbsent("recordingPillLiveWords", \.recordingPillLiveWords, \.recordingPillLiveWords),
        .keepIfAbsent("meetingOverlayPreference", \.meetingOverlayPreference, \.meetingOverlayPreference),
        .value("transcriptionPreviewCharLimit", \.transcriptionPreviewCharLimit, \.transcriptionPreviewCharLimit),
        .value("userTypingWPM", \.userTypingWPM, \.userTypingWPM),
        .custom(
            "statsResetDate",
            export: { BackupFieldValue($0.statsResetDate) },
            restore: { store, source in
                if let date = source.payload.statsResetDate {
                    store.statsResetDate = date
                }
            }
        ),
        .value("saveTranscriptionHistory", \.saveTranscriptionHistory, \.saveTranscriptionHistory),
        .keepIfAbsent("saveAudioWithTranscriptionHistory", \.saveAudioWithTranscriptionHistory, \.saveAudioWithTranscriptionHistory),
        .keepIfAbsent("audioHistoryBudgetGB", \.audioHistoryBudgetGB, \.audioHistoryBudgetGB),
        .keepIfAbsent("notifyAIProcessingFailures", \.notifyAIProcessingFailures, \.notifyAIProcessingFailures),
        .keepIfAbsent("showMicrophoneChangeAlerts", \.showMicrophoneChangeAlerts, \.showMicrophoneChangeAlerts),
        .keepIfAbsent("showPasteCheckAlerts", \.showPasteCheckAlerts, \.showPasteCheckAlerts),
        .value("weekendsDontBreakStreak", \.weekendsDontBreakStreak, \.weekendsDontBreakStreak),
    ]

    private static let formattingBackupEntries: [BackupEntry] = [
        .value("fillerWords", \.fillerWords, \.fillerWords),
        .value("removeFillerWordsEnabled", \.removeFillerWordsEnabled, \.removeFillerWordsEnabled),
        .keepIfAbsent("autoConvertPunctuationEnabled", \.autoConvertPunctuationEnabled, \.autoConvertPunctuationEnabled),
        .keepIfAbsent("literalDictationFormattingEnabled", \.literalDictationFormattingEnabled, \.literalDictationFormattingEnabled),
        .keepIfAbsent("punctuationDictionaryPrefix", \.punctuationDictionaryPrefix, \.punctuationDictionaryPrefix),
        .keepIfAbsent("punctuationDictionaryRules", \.punctuationDictionaryRules, \.punctuationDictionaryRules),
        .keepIfAbsent("spokenFormattingActionRules", \.spokenFormattingActionRules, \.spokenFormattingActionRules),
        // The detail switches default to their master switch when an older backup lacks them.
        .value("gaavModeEnabled", \.gaavModeEnabled, \.gaavModeEnabled),
        .custom(
            "gaavLowercaseFirstLetterEnabled",
            export: { BackupFieldValue($0.gaavLowercaseFirstLetterEnabled) },
            restore: { store, source in
                store.gaavLowercaseFirstLetterEnabled = source.payload.gaavLowercaseFirstLetterEnabled ?? source.payload.gaavModeEnabled
            }
        ),
        .custom(
            "gaavRemoveTrailingPeriodEnabled",
            export: { BackupFieldValue($0.gaavRemoveTrailingPeriodEnabled) },
            restore: { store, source in
                store.gaavRemoveTrailingPeriodEnabled = source.payload.gaavRemoveTrailingPeriodEnabled ?? source.payload.gaavModeEnabled
            }
        ),
        .orDefault("continuousDictationModeEnabled", \.continuousDictationModeEnabled, \.continuousDictationModeEnabled, false),
        .custom(
            "continuousDictationSpacingEnabled",
            export: { BackupFieldValue($0.continuousDictationSpacingEnabled) },
            restore: { store, source in
                store.continuousDictationSpacingEnabled = source.payload.continuousDictationSpacingEnabled
                    ?? (source.payload.continuousDictationModeEnabled ?? false)
            }
        ),
        .custom(
            "contextAwareCapitalizationEnabled",
            export: { BackupFieldValue($0.contextAwareCapitalizationEnabled) },
            restore: { store, source in
                store.contextAwareCapitalizationEnabled = source.payload.contextAwareCapitalizationEnabled
                    ?? (source.payload.continuousDictationModeEnabled ?? false)
            }
        ),
        .value("pauseMediaDuringTranscription", \.pauseMediaDuringTranscription, \.pauseMediaDuringTranscription),
        .keepIfAbsent("automaticDictionaryLearningEnabled", \.automaticDictionaryLearningEnabled, \.automaticDictionaryLearningEnabled),
        .keepIfAbsent("automaticDictionarySuggestionFrequency", \.automaticDictionarySuggestionFrequency, \.automaticDictionarySuggestionFrequency),
        // Older builds saved a switch nothing read. Never written now and ignored on restore;
        // see pronunciationLearningEnabled.
        .custom("pronunciationMatchingEnabled", export: { _ in nil }),
        .value("vocabularyBoostingEnabled", \.vocabularyBoostingEnabled, \.vocabularyBoostingEnabled),
        .value("customDictionaryEntries", \.customDictionaryEntries, \.customDictionaryEntries),
    ]

    private static let promptBackupEntries: [BackupEntry] = [
        .step { store, source in store.dictationPromptProfiles = source.promptProfiles },
        // A present empty map clears prompt overrides; an absent map preserves them.
        .keepIfAbsent("dictationPromptConfigurations", \.dictationPromptConfigurations, \.dictationPromptConfigurations),
        .step { store, source in store.appPromptBindings = source.appPromptBindings },
        .value("selectedDictationPromptID", \.selectedDictationPromptID, \.selectedDictationPromptID),
        .custom(
            "dictationPromptOff",
            export: { BackupFieldValue($0.isDictationPromptOff) },
            restore: { store, source in store.isDictationPromptOff = source.payload.dictationPromptOff ?? store.isDictationPromptOff }
        ),
        .orDefault("dictationPromptRoutingScope", \.dictationPromptRoutingScope, \.dictationPromptRoutingScope, .allApps),
        .custom(
            "editPromptOff",
            export: { BackupFieldValue($0.isEditPromptOff) },
            restore: { store, source in store.isEditPromptOff = source.payload.editPromptOff ?? store.isEditPromptOff }
        ),
        .orDefault("editPromptRoutingScope", \.editPromptRoutingScope, \.editPromptRoutingScope, .allApps),
        .value("selectedEditPromptID", \.selectedEditPromptID, \.selectedEditPromptID),
        .value("defaultDictationPromptOverride", \.defaultDictationPromptOverride, \.defaultDictationPromptOverride),
        .value("defaultEditPromptOverride", \.defaultEditPromptOverride, \.defaultEditPromptOverride),
        .keepIfAbsent("fileTranscriptionSpeakerLabelsEnabled", \.fileTranscriptionSpeakerLabelsEnabled, \.fileTranscriptionSpeakerLabelsEnabled),
        .keepIfAbsent("fileTranscriptionExpectedSpeakerCount", \.fileTranscriptionExpectedSpeakerCount, \.fileTranscriptionExpectedSpeakerCount),
        .value("promptModeSelectedPromptID", \.promptModeSelectedPromptID, \.promptModeSelectedPromptID),
        .orDefault("secondaryDictationPromptOff", \.secondaryDictationPromptOff, \.isSecondaryDictationPromptOff, false),
        .step { store, source in
            store.normalizePromptSelectionsIfNeeded()
            // Validate imported mappings only after profile migration/normalization.
            // Legacy backups do not own the newer map, so leave it intact when absent.
            if source.payload.dictationPromptConfigurations != nil {
                store.normalizeDictationPromptConfigurationsIfNeeded()
            }
        },
    ]

    // Fields added after 1.0 backups: absent means keep the current value.
    private static let laterBackupEntries: [BackupEntry] = [
        .keepIfAbsent("themePreference", \.themePreference, \.themePreference),
        .keepIfAbsent("overlayEdgeLightEnabled", \.overlayEdgeLightEnabled, \.overlayEdgeLightEnabled),
        .keepIfAbsent("meetingAutoDetectEnabled", \.meetingAutoDetectEnabled, \.meetingAutoDetectEnabled),
        .keepIfAbsent("meetingAutoDetectBrowserEnabled", \.meetingAutoDetectBrowserEnabled, \.meetingAutoDetectBrowserEnabled),
        .keepIfAbsent("meetingAudioRetentionPolicy", \.meetingAudioRetentionPolicy, \.meetingAudioRetentionPolicy),
        .keepIfAbsent("dictationCleanupBudgetMilliseconds", \.dictationCleanupBudgetMilliseconds, \.dictationCleanupBudgetMilliseconds),
        .keepIfAbsent("dictationCloudCleanupBudgetMilliseconds", \.dictationCloudCleanupBudgetMilliseconds, \.dictationCloudCleanupBudgetMilliseconds),
        .keepIfAbsent("dictationCleanupContextEnabled", \.dictationCleanupContextEnabled, \.dictationCleanupContextEnabled),
        .keepIfAbsent("dictationCloudCleanupContextEnabled", \.dictationCloudCleanupContextEnabled, \.dictationCloudCleanupContextEnabled),
        .keepIfAbsent("pronunciationLearningEnabled", \.pronunciationLearningEnabled, \.pronunciationMatchingEnabled),
        .step { store, _ in store.purgeRetiredAppleIntelligenceState() },
    ]
}
