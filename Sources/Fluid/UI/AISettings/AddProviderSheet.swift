import SwiftUI

/// Add a provider: a ruled list of providers not added yet, then the connection
/// details for the one picked. Adding one never changes the cleanup in use.
struct AddProviderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: AIEnhancementSettingsViewModel
    @State private var draft = ProviderSetupDraft()
    @State private var isEditing = false
    @State private var saveFailed = false
    @State private var modelFetchTask: Task<Void, Never>?
    @State private var modelFetchID: UUID?
    @State private var modelFetchError: String?
    @State private var modelsLoaded = false
    @State private var showingManualModel = false
    @State private var highlightedIndex = 0
    @FocusState private var listFocused: Bool

    private struct Choice: Identifiable {
        let id: String
        let name: String
        let detail: String
    }

    private var providers: [AIEnhancementSettingsViewModel.ProviderItemData] {
        let added = Set(self.viewModel.cachedAddedProviderItems.map(\.id))
        return self.viewModel.cachedProviderItems.filter {
            $0.isBuiltIn && $0.id != PrivateAIProviderFeature.shared.providerID && !added.contains($0.id)
        }
    }

    /// The built-in providers, then the custom one (empty id).
    private var choices: [Choice] {
        self.providers.map {
            Choice(
                id: $0.id,
                name: $0.name,
                detail: ["ollama", "lmstudio"].contains($0.id) ? "Local connection" : "Connect with an API key"
            )
        } + [Choice(id: "", name: "Custom provider", detail: "Your own service or server")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FWMetric.space5) {
            if self.isEditing {
                self.form
            } else {
                self.chooser
            }
        }
        .padding(FWMetric.space7)
        .frame(width: 480, alignment: .topLeading)
        .background(FWColor.surfaceRaised)
        .onChange(of: self.draft.connectionIdentity) { _, _ in
            self.cancelModelFetch()
            self.modelFetchError = nil
            self.modelsLoaded = false
        }
        .onDisappear { self.cancelModelFetch() }
    }

    // MARK: - Step 1

    private var chooser: some View {
        VStack(alignment: .leading, spacing: FWMetric.space5) {
            VStack(alignment: .leading, spacing: FWMetric.space2) {
                Text("Add a provider")
                    .recordText(FWType.section)
                    .foregroundStyle(FWColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                SettingsText("Adding one won’t change how dictation is cleaned up now.")
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(self.choices.enumerated()), id: \.element.id) { index, choice in
                    Button { self.pick(choice) } label: {
                        HStack(spacing: FWMetric.space4) {
                            VStack(alignment: .leading, spacing: FWMetric.space1) {
                                Text(choice.name)
                                    .recordText(FWType.label)
                                    .foregroundStyle(FWColor.textPrimary)
                                Text(choice.detail)
                                    .recordText(FWType.detail)
                                    .foregroundStyle(FWColor.textSecondary)
                            }
                            Spacer(minLength: FWMetric.space4)
                            Image(systemName: "chevron.right")
                                .font(.fluidSystem(size: 12, weight: .semibold))
                                .foregroundStyle(FWColor.textTertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, FWMetric.space2)
                        .background(self.listFocused && index == self.highlightedIndex ? FWColor.surfaceHover : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .top) {
                        if index > 0 {
                            Rectangle().fill(FWColor.lineRule).frame(height: FWMetric.lineHairline)
                        }
                    }
                }
            }
            .focusable()
            .focused(self.$listFocused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) {
                self.highlightedIndex = max(0, self.highlightedIndex - 1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                self.highlightedIndex = min(self.choices.count - 1, self.highlightedIndex + 1)
                return .handled
            }
            .onKeyPress(.return) {
                guard self.choices.indices.contains(self.highlightedIndex) else { return .ignored }
                self.pick(self.choices[self.highlightedIndex])
                return .handled
            }
            .onAppear { self.listFocused = true }
            HStack {
                Spacer()
                Button("Cancel") { self.dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: 28))
            }
        }
    }

    private func pick(_ choice: Choice) {
        self.draft = choice.id.isEmpty
            ? ProviderSetupDraft(name: "Custom provider")
            : ProviderSetupDraft(providerID: choice.id, name: choice.name, baseURL: ModelRepository.shared.defaultBaseURL(for: choice.id))
        self.isEditing = true
    }

    // MARK: - Step 2

    private var form: some View {
        VStack(alignment: .leading, spacing: FWMetric.space5) {
            VStack(alignment: .leading, spacing: FWMetric.space2) {
                Text(self.draft.trimmedName.isEmpty ? "Custom provider" : self.draft.trimmedName)
                    .recordText(FWType.section)
                    .foregroundStyle(FWColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                SettingsText("Connection details")
            }
            if self.draft.providerID.isEmpty {
                self.field("Name") {
                    RecordField(placeholder: "Custom provider", text: self.$draft.name)
                }
                self.field("Server URL", note: self.draft.needsHTTPS ? ProviderVerification.httpsRequiredMessage : nil, isError: self.draft.needsHTTPS) {
                    RecordField(placeholder: "https://your-server.com/v1", text: self.$draft.baseURL, isError: self.draft.needsHTTPS)
                }
            }
            self.field(self.draft.requiresAPIKey ? "API key" : "API key · Optional", note: "Stored in your Keychain.") {
                SecureRecordField(placeholder: "Paste the API key", text: self.$draft.apiKey)
            }
            if let website = ModelRepository.shared.providerWebsiteURL(for: self.draft.providerID), let url = URL(string: website.url) {
                Link(website.label, destination: url)
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
            }
            self.modelField
            if self.saveFailed {
                SettingsStateNote("Couldn’t save this provider. Check Keychain access and try again.")
            }
            HStack(spacing: FWMetric.space3) {
                Spacer()
                Button("Back") {
                    self.cancelModelFetch()
                    self.isEditing = false
                    self.saveFailed = false
                    self.showingManualModel = false
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(RecordButtonStyle(kind: .secondary, size: 28))
                Button("Add provider") {
                    if self.viewModel.addProvider(self.draft) { self.dismiss() } else { self.saveFailed = true }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(RecordButtonStyle(kind: .primary, size: 28))
                .disabled(
                    self.modelFetchID != nil || !self.draft.isValid || self.draft.trimmedModel.isEmpty
                        || self.viewModel.isTestingConnection || self.viewModel.isFetchingModels
                )
            }
        }
    }

    private var modelField: some View {
        VStack(alignment: .leading, spacing: FWMetric.space2) {
            Text("Model")
                .recordText(FWType.detailStrong)
                .foregroundStyle(FWColor.textSecondary)
            HStack(spacing: FWMetric.space3) {
                RecordPopUp(self.draft.trimmedModel.isEmpty ? "Choose a model" : self.draft.trimmedModel) {
                    ForEach(self.draft.fetchedModels, id: \.self) { model in
                        Button(model) { self.draft.selectFetchedModel(model) }
                    }
                }
                .disabled(self.draft.fetchedModels.isEmpty)
                Button(self.modelFetchID == nil ? "Reload models" : "Loading…", action: self.fetchModels)
                    .buttonStyle(RecordButtonStyle(kind: .quiet, size: 20))
                    .disabled(!self.draft.isValid || self.modelFetchID != nil)
                Button("Enter an ID") { self.showingManualModel.toggle() }
                    .buttonStyle(RecordButtonStyle(kind: .quiet, size: 20))
            }
            if self.showingManualModel {
                RecordField(placeholder: "Model ID", text: self.$draft.model)
                    .accessibilityLabel("Model ID")
            }
            if let error = self.modelFetchError {
                SettingsStateNote(error)
            } else if self.modelsLoaded {
                SettingsText("Models loaded from \(self.draft.trimmedName).")
            } else {
                SettingsText(
                    self.draft.requiresAPIKey && self.draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Paste the API key, then reload models."
                        : "Reload models, or enter a model ID."
                )
            }
        }
    }

    private func field<Control: View>(
        _ title: String,
        note: String? = nil,
        isError: Bool = false,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: FWMetric.space2) {
            Text(title)
                .recordText(FWType.detailStrong)
                .foregroundStyle(FWColor.textSecondary)
            control()
                .accessibilityLabel(title)
            if let note {
                if isError {
                    SettingsStateNote(note)
                } else {
                    SettingsText(note)
                }
            }
        }
    }

    private func cancelModelFetch() {
        self.modelFetchTask?.cancel()
        self.modelFetchTask = nil
        self.modelFetchID = nil
    }

    private func fetchModels() {
        guard self.draft.isValid, self.modelFetchID == nil else { return }
        let snapshot = self.draft
        let requestID = UUID()
        self.modelFetchID = requestID
        self.modelFetchError = nil
        self.modelFetchTask = Task { @MainActor in
            defer {
                if self.modelFetchID == requestID {
                    self.modelFetchID = nil
                    self.modelFetchTask = nil
                }
            }
            do {
                let models = try await ModelRepository.shared.fetchModels(
                    for: snapshot.providerID,
                    baseURL: snapshot.trimmedBaseURL,
                    apiKey: snapshot.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                guard !Task.isCancelled, self.modelFetchID == requestID,
                      self.draft.connectionIdentity == snapshot.connectionIdentity else { return }
                self.draft.applyFetchedModels(models, for: snapshot.connectionIdentity)
                if models.isEmpty {
                    self.modelFetchError = "No models came back. Load a model on your server and reload, or enter its ID."
                } else {
                    self.modelsLoaded = true
                }
            } catch {
                guard !Task.isCancelled, self.modelFetchID == requestID,
                      self.draft.connectionIdentity == snapshot.connectionIdentity else { return }
                self.modelFetchError = error.localizedDescription
            }
        }
    }
}
