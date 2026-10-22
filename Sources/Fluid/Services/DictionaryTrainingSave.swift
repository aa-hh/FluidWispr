import Foundation

/// Saves a trained dictionary word: filters the misheard spellings, writes the voice profile
/// when there are enough voice examples, and returns the dictionary to publish. Profile
/// persistence suspends, so every step checks that this save is still the current one and
/// never returns a list over a newer manual edit, import, or deletion.
@MainActor
struct DictionaryTrainingSave {
    typealias Entry = SettingsStore.CustomDictionaryEntry
    typealias ProfileWrite = @MainActor (
        _ entryID: UUID,
        _ label: String,
        _ modelKey: String,
        _ enrollments: [PronunciationEnrollmentCapture],
        _ canPersist: @escaping @Sendable () -> Bool
    ) async throws -> Void

    enum Outcome: Equatable {
        /// Publish these entries and finish the wizard.
        case saved([Entry])
        /// Show this message and keep the recordings for a retry.
        case failed(String)
        /// A newer save started or this one was cancelled. Touch nothing.
        case superseded
    }

    let replacement: String
    let variants: [String]
    let enrollments: [PronunciationEnrollmentCapture]
    let savePronunciation: Bool
    var filterAliases: @MainActor ([String]) async -> VoiceTrainingAliasFilter.Result = { await VoiceTrainingAliasFilter.filter($0) }
    var currentEntries: @Sendable () -> [Entry] = { SettingsStore.shared.customDictionaryEntries }
    /// The pronunciation generation, or nil while pronunciation matching is off.
    var pronunciationGeneration: @Sendable () -> String? = {
        DictionaryMatcherExperiment.sharedFeaturesEnabled ? DictionaryMatcherExperiment.generation : nil
    }
    var writeProfile: ProfileWrite = { entryID, label, modelKey, enrollments, canPersist in
        try await PronunciationDictionaryStore.shared.upsert(
            dictionaryEntryID: entryID,
            label: label,
            modelKey: modelKey,
            enrollments: enrollments,
            automaticMatchingEnabled: true,
            canPersist: canPersist
        )
    }

    func run(isCurrent: () -> Bool) async -> Outcome {
        let generation = self.pronunciationGeneration()
        let filtered = await self.filterAliases(self.variants)
        guard isCurrent() else { return .superseded }
        DebugLogger.shared.info(
            "VOICE_TRAINING_ALIAS_FILTER accepted=\(filtered.accepted.count) rejected=\(filtered.rejected.count) available=\(filtered.lookupAvailable)",
            source: "CustomDictionary"
        )
        guard self.savePronunciation || !filtered.accepted.isEmpty else {
            return .failed(
                filtered.lookupAvailable
                    ? "These takes contain everyday words, so saving them could change normal sentences. Record again, or add the correction by typing."
                    : "Couldn’t check these words. Try saving again, or add the correction by typing."
            )
        }

        let currentEntries = self.currentEntries
        let pronunciationGeneration = self.pronunciationGeneration
        let originalEntries = currentEntries()
        let updatedEntries = CustomDictionaryTrainingMerge.mergedEntries(
            current: originalEntries,
            replacement: self.replacement,
            triggers: filtered.accepted,
            savePronunciation: self.savePronunciation
        )
        let entry = updatedEntries.first {
            $0.replacement.caseInsensitiveCompare(self.replacement) == .orderedSame
        }
        if self.savePronunciation, let entry, let modelKey = self.enrollments.first?.modelKey {
            do {
                try await self.writeProfile(entry.id, self.replacement, modelKey, self.enrollments) {
                    generation != nil && pronunciationGeneration() == generation && currentEntries() == originalEntries
                }
            } catch {
                guard isCurrent() else { return .superseded }
                DebugLogger.shared.error(
                    "Failed to save pronunciation profile: \(error.localizedDescription)",
                    source: "PronunciationMatching"
                )
                return .failed(
                    currentEntries() == originalEntries
                        ? "Couldn’t save the voice profile. Try again."
                        : "Your dictionary changed while saving. Try again."
                )
            }
        }
        guard isCurrent() else { return .superseded }
        guard currentEntries() == originalEntries else {
            return .failed("Your dictionary changed while saving. Try again.")
        }
        return .saved(updatedEntries)
    }
}
