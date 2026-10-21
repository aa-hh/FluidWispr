import Foundation

extension AIEnhancementSettingsViewModel {
    static let addedProviderIDsKey = "AISettingsAddedProviderIDs"

    /// Preserve prompt text and hotkeys; only disconnect routes using the removed provider.
    func clearProviderAssignments(for providerID: String) {
        var configurations = self.settings.dictationPromptConfigurations
        for (id, var configuration) in configurations where configuration.providerID == providerID {
            configuration.providerID = ""
            configuration.modelName = ""
            configurations[id] = configuration
        }
        if configurations != self.settings.dictationPromptConfigurations {
            self.settings.dictationPromptConfigurations = configurations
        }
        if self.settings.rewriteModeSelectedProviderID == providerID {
            self.settings.rewriteModeSelectedProviderID = ""
            self.settings.rewriteModeSelectedModel = nil
        }
        if self.settings.commandModeSelectedProviderID == providerID {
            self.settings.commandModeSelectedProviderID = ""
            self.settings.commandModeSelectedModel = nil
        }
    }

    /// Keep legacy connections discoverable even when their verification or credentials expire.
    func addedProviderItems(from items: [ProviderItemData]) -> [ProviderItemData] {
        let explicit = Set(UserDefaults.standard.stringArray(forKey: Self.addedProviderIDsKey) ?? [])
        let referenced = Set(self.settings.dictationPromptConfigurations.values.map(\.providerID))
        return items.filter { item in
            guard item.id != PrivateAIProviderFeature.shared.providerID else { return false }
            let key = self.providerKey(for: item.id)
            return !item.isBuiltIn || explicit.contains(item.id) || referenced.contains(item.id)
                || self.settings.selectedProviderID == item.id
                || !self.providerAPIKey(for: item.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || self.settings.verifiedProviderFingerprints[key] != nil
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Saves credentials first. Failure keeps the form open and creates no provider/model record.
    /// Does not select a provider, change shortcuts, fetch models, or start a network request.
    func addProvider(_ draft: ProviderSetupDraft) -> Bool {
        guard draft.isValid, !self.isTestingConnection, !self.isFetchingModels else { return false }
        let builtIn = !draft.providerID.isEmpty && ModelRepository.shared.isBuiltIn(draft.providerID)
        guard draft.providerID.isEmpty || builtIn else { return false }
        guard !builtIn || !self.cachedAddedProviderItems.contains(where: { $0.id == draft.providerID }) else { return false }
        let models = draft.modelsToSave(defaults: builtIn ? ModelRepository.shared.defaultModels(for: draft.providerID) : [])
        let provider = SettingsStore.SavedProvider(name: draft.trimmedName, baseURL: draft.trimmedBaseURL, models: models)
        let id = builtIn ? draft.providerID : provider.id
        let key = self.providerKey(for: id)
        let previousKeys = self.providerAPIKeys
        let apiKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            self.updateProviderAPIKey(apiKey, for: id)
            guard self.saveProviderAPIKeys(invalidating: id) else {
                self.providerAPIKeys = previousKeys
                self.refreshProviderItems()
                return false
            }
        }
        if !builtIn { self.savedProviders.append(provider) }
        self.availableModelsByProvider[key] = models
        self.selectedModelByProvider[key] = models.first ?? ""
        var added = Set(UserDefaults.standard.stringArray(forKey: Self.addedProviderIDsKey) ?? [])
        added.insert(id)
        UserDefaults.standard.set(added.sorted(), forKey: Self.addedProviderIDsKey)
        self.saveSavedProviders()
        return true
    }

    @discardableResult
    func deleteCurrentProvider() -> Bool {
        guard !self.isFetchingModels, !self.isTestingConnection,
              !self.selectedProviderID.isEmpty,
              self.selectedProviderID != PrivateAIProviderFeature.shared.providerID
        else { return false }
        let deletedProviderID = self.selectedProviderID
        let deletedDefaultProvider = self.settings.selectedProviderID == deletedProviderID
        let key = self.providerKey(for: deletedProviderID)
        let previousKeys = self.providerAPIKeys
        let persistedKey = self.managedOriginalKey ?? self.providerAPIKey(for: deletedProviderID)
        let hadPersistedKey = !persistedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.providerAPIKeys.removeValue(forKey: key)
        if key != deletedProviderID {
            self.providerAPIKeys.removeValue(forKey: deletedProviderID)
        }
        if hadPersistedKey, !self.saveProviderAPIKeys(invalidating: deletedProviderID) {
            self.providerAPIKeys = previousKeys
            return false
        }
        self.clearProviderAssignments(for: deletedProviderID)
        let remainingAddedIDs = (UserDefaults.standard.stringArray(forKey: Self.addedProviderIDsKey) ?? []).filter { $0 != deletedProviderID }
        UserDefaults.standard.set(remainingAddedIDs, forKey: Self.addedProviderIDsKey)
        self.savedProviders.removeAll { $0.id == deletedProviderID }
        self.saveSavedProviders()
        self.availableModelsByProvider.removeValue(forKey: key)
        self.selectedModelByProvider.removeValue(forKey: key)
        self.settings.verifiedProviderFingerprints.removeValue(forKey: key)
        self.settings.availableModelsByProvider = self.availableModelsByProvider
        self.settings.selectedModelByProvider = self.selectedModelByProvider
        if deletedDefaultProvider {
            self.settings.selectedProviderID = ""
            self.settings.selectedModel = nil
        }
        self.fetchedModelsProviders.remove(key)
        self.clearEditProviderDraft()
        self.finishConfiguringProvider()
        self.refreshVerifiedProviders()
        self.refreshProviderItems()
        self.selectSoleVerifiedProviderIfNeeded()
        return true
    }

    /// Commit a managed provider's key before dismissing, but never save a removed provider
    /// or the default selected by the removal cleanup in its place.
    func saveManagedProviderBeforeClosing(_ providerID: String) -> Bool {
        guard !self.isFetchingModels, !self.isTestingConnection else { return false }
        return self.saveManagedProviderAPIKeyIfNeeded(providerID)
    }

    /// Persist only an API-key edit made in the active provider manager. Selecting an
    /// already-configured or keyless provider must not depend on Keychain write access.
    func saveManagedProviderAPIKeyIfNeeded(_ providerID: String) -> Bool {
        guard self.selectedProviderID == providerID,
              let original = self.managedOriginalKey
        else { return true }
        let current = self.providerAPIKey(for: providerID)
        guard original.trimmingCharacters(in: .whitespacesAndNewlines)
            != current.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return true }
        guard self.hasProviderAPIKeyDraft(for: providerID) else { return true }
        guard self.saveProviderAPIKeys(invalidating: providerID) else { return false }
        self.managedOriginalKey = current
        return true
    }
}
