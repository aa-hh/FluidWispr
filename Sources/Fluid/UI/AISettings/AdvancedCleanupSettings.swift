import SwiftUI

/// Settings › Cleanup › Advanced: other providers and cleanup styles as ruled rows.
/// Edit opens the existing provider and style editors unchanged.
extension AIEnhancementSettingsView {
    var advancedCleanupPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecordSectionLine(heading: "Providers")
            ForEach(self.viewModel.cachedAddedProviderItems) { provider in
                self.advancedProviderRow(provider)
            }
            SettingsRow {
                Button("Add provider") { self.showingAddProviderSheet = true }
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: 28))
                    .disabled(self.viewModel.isFetchingModels || self.viewModel.isTestingConnection)
            }
            RecordSectionLine(heading: "Cleanup styles")
            SettingsRow("Default", help: "Every other app.") {
                SettingsText(
                    "The built-in style. Fixes punctuation, capitals and filler words and keeps your wording.",
                    style: FWType.body,
                    color: FWColor.textPrimary
                )
            }
            ForEach(self.cleanupStyleProfiles) { profile in
                self.cleanupStyleRow(profile)
            }
            SettingsRow(showsRule: false) {
                HStack(spacing: FWMetric.space4) {
                    Button("Add style") { self.viewModel.openNewPromptEditor(prefillMode: .dictate) }
                        .buttonStyle(RecordButtonStyle(kind: .secondary, size: 20))
                    SettingsText("Styles need a provider from the list above.")
                }
            }
        }
        .sheet(isPresented: self.$showingAddProviderSheet) {
            AddProviderSheet(viewModel: self.viewModel)
                .appTheme(self.theme)
        }
        .sheet(isPresented: Binding(
            get: { self.managedExternalProviderID != nil },
            set: { if !$0 { self.closeExternalProviderManager() } }
        )) {
            self.externalProviderManager.appTheme(self.theme)
        }
        .sheet(item: self.$viewModel.promptEditorMode) { mode in
            self.promptEditorSheet(mode: mode)
        }
    }

    // MARK: Providers

    private func advancedProviderRow(_ provider: AIEnhancementSettingsViewModel.ProviderItemData) -> some View {
        let item = ProviderItem(id: provider.id, name: provider.name, isBuiltIn: provider.isBuiltIn)
        let isLocal = self.viewModel.isLocalEndpoint(self.providerBaseURL(for: item))
        let model = self.viewModel.selectedModel(for: provider.id).trimmingCharacters(in: .whitespacesAndNewlines)
        let status = self.viewModel.connectionStatus(for: provider.id)
        let setupIssue = DictationDefaultProvider.setupIssue(
            requiresAPIKey: !isLocal,
            hasAPIKey: !self.viewModel.providerAPIKey(for: provider.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            hasModel: !model.isEmpty,
            isVerified: status == .success,
            verificationFailed: status == .failed
        )
        let busy = self.viewModel.isFetchingModels || self.viewModel.isTestingConnection
        let help = model.isEmpty ? (isLocal ? "Local connection" : "No model chosen") : ModelDisplayName.forID(model)

        return SettingsRow(provider.name, help: help) {
            HStack(spacing: 6) {
                if status == .testing {
                    RecordMark(state: .working)
                    SettingsText("Checking…")
                } else if let setupIssue {
                    RecordMark(state: .needsYou)
                    SettingsText(Self.providerIssueText(setupIssue), color: FWColor.stateAttention)
                } else if status == .success {
                    RecordMark(state: .done)
                    SettingsText("Connected", color: FWColor.stateDone)
                } else {
                    RecordMark(state: .waiting)
                    SettingsText("Not checked yet")
                }
            }
            HStack(spacing: FWMetric.space3) {
                if setupIssue == "Choose a model" {
                    Button("Choose model") { self.editProvider(provider.id) }
                        .buttonStyle(RecordButtonStyle(kind: .secondary, size: 20))
                } else if setupIssue != nil || status != .success {
                    Button("Check connection") { self.checkConnection(provider.id) }
                        .buttonStyle(RecordButtonStyle(kind: .secondary, size: 20))
                    Button("Edit") { self.editProvider(provider.id) }
                        .buttonStyle(RecordButtonStyle(kind: .quiet, size: 20))
                } else {
                    if self.primaryDefaultProviderID == provider.id {
                        SettingsText("Used for cleanup")
                    } else {
                        Button("Use as default") { self.makePrimaryDefaultProvider(provider.id, isPrivateAI: false) }
                            .buttonStyle(RecordButtonStyle(kind: .secondary, size: 20))
                            .disabled(!self.viewModel.canUseProviderWithoutVerification(provider.id))
                    }
                    Button("Edit") { self.editProvider(provider.id) }
                        .buttonStyle(RecordButtonStyle(kind: .quiet, size: 20))
                }
                Button("Remove") { self.confirmRemoveProvider(provider) }
                    .buttonStyle(RecordButtonStyle(kind: .destructive, size: 20))
            }
            .disabled(busy)
        }
    }

    private static func providerIssueText(_ issue: String) -> String {
        switch issue {
        case "Choose a model": "Choose a model before it can be used."
        case "API key missing": "Add an API key before it can be used."
        case "Verification failed": "The last check failed. Edit it, then check again."
        default: issue
        }
    }

    private func editProvider(_ providerID: String) {
        self.viewModel.configureProvider(providerID)
        self.managedExternalProviderID = providerID
    }

    private func checkConnection(_ providerID: String) {
        self.viewModel.configureProvider(providerID)
        Task { @MainActor in
            await self.viewModel.testAPIConnection()
            self.viewModel.finishConfiguringProvider()
        }
    }

    private func confirmRemoveProvider(_ provider: AIEnhancementSettingsViewModel.ProviderItemData) {
        let styles = self.styleNames(usingProvider: provider.id)
        let fallback = switch styles.count {
        case 0: ""
        case 1: " The \(styles[0]) style that uses it falls back to the default until you pick another provider."
        default:
            " The \(styles.dropLast().joined(separator: ", ")) and \(styles[styles.count - 1]) styles that use it fall back to the default until you pick another provider."
        }
        let confirmation = SettingsConfirmation(
            title: "Remove \(provider.name)?",
            message: "This removes its saved API key and model setup.\(fallback) You can add it again later.",
            actionLabel: "Remove"
        ) {
            self.viewModel.configureProvider(provider.id)
            if !self.viewModel.deleteCurrentProvider() {
                self.viewModel.finishConfiguringProvider()
            }
        }
        if let confirm = self.confirm {
            confirm(confirmation)
        } else {
            confirmation.action()
        }
    }

    /// The names of the cleanup styles whose saved setup runs on this provider.
    private func styleNames(usingProvider providerID: String) -> [String] {
        self.settings.dictationPromptConfigurations
            .filter { $0.value.providerID == providerID }
            .compactMap { key, _ -> String? in
                switch self.settings.dictationPromptSelection(forConfigurationKey: key) {
                case .default: return "Default"
                case let .profile(id):
                    return self.viewModel.dictationPromptProfiles.first { $0.id == id }.map { $0.name.isEmpty ? "Untitled" : $0.name }
                case .off, .privateAI, nil: return nil
                }
            }
            .sorted()
    }

    // MARK: Cleanup styles

    private var cleanupStyleProfiles: [SettingsStore.DictationPromptProfile] {
        self.viewModel.dictationPromptProfiles.filter { $0.mode.normalized == .dictate }
    }

    private func cleanupStyleRow(_ profile: SettingsStore.DictationPromptProfile) -> some View {
        let apps = self.viewModel.appBindings(for: .dictate)
            .filter { $0.promptID == profile.id }
            .map(\.appName)
        let providerID = self.settings.dictationPromptConfiguration(for: .profile(profile.id)).providerID
        let body = SettingsStore.stripBasePrompt(for: .dictate, from: profile.prompt)
        return SettingsRow(profile.name.isEmpty ? "Untitled" : profile.name, help: apps.isEmpty ? "Any app" : apps.joined(separator: ", ")) {
            SettingsText("“\(self.viewModel.promptPreview(body))”", style: FWType.body, color: FWColor.textPrimary)
            HStack(spacing: FWMetric.space3) {
                SettingsText(providerID.isEmpty ? "Default provider" : self.viewModel.providerDisplayName(for: providerID))
                Button("Edit") { self.viewModel.openEditor(for: profile) }
                    .buttonStyle(RecordButtonStyle(kind: .quiet, size: 20))
            }
        }
    }
}
