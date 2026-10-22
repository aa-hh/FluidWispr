import SwiftUI

/// The Voice engine page in Settings: the model in use, its language, and the other
/// models as ruled rows with their download, use and delete actions.
struct VoiceEngineSettingsView: View {
    @ObservedObject var viewModel: VoiceEngineSettingsViewModel
    @ObservedObject var settings: SettingsStore
    let theme: AppTheme
    /// Asks before deleting a model. The default deletes at once.
    var confirm: (SettingsConfirmation) -> Void = { $0.action() }

    @State private var isShowingWhisperLanguagePicker = false
    @State private var whisperLanguageSearchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.inUseRow
            if self.activeModel.map(Self.hasLanguageChoice) == true {
                SettingsRow("Language", help: "Automatic suits most people.") {
                    self.languagePicker
                        .disabled(self.viewModel.areSpeechModelActionsBlocked)
                }
            }
            RecordSectionLine(heading: "Other models")
            ForEach(self.otherModels) { model in
                SettingsRow(Self.shortName(model), help: Self.help(for: model)) {
                    SettingsText(model.cardDescription)
                    self.actions(for: model)
                }
            }
        }
        .disabled(self.viewModel.asr.isRunning)
        .onAppear { self.viewModel.onAppear() }
        .onChange(of: self.settings.selectedSpeechModel) { _, newValue in
            self.viewModel.handleSelectedSpeechModelChange(newValue)
        }
    }

    private var activeModel: SpeechModel? {
        let selected = self.settings.selectedSpeechModel
        return self.viewModel.isSpeechModelInstalled(selected) ? selected : nil
    }

    private var otherModels: [SpeechModel] {
        SpeechModel.availableModels.filter { $0 != self.activeModel }
    }

    // MARK: In use

    @ViewBuilder
    private var inUseRow: some View {
        let asr = self.viewModel.asr
        SettingsRow("In use", help: "Runs on this Mac.", target: .voiceEngine) {
            if let model = self.activeModel {
                HStack(spacing: 6) {
                    SettingsText(Self.shortName(model), style: FWType.label, color: FWColor.textPrimary)
                    if asr.isAsrReady {
                        RecordMark(state: .done)
                        SettingsText("Ready", color: FWColor.stateDone)
                    } else if asr.isDownloadingModel || asr.isLoadingModel || asr.isCancellingModelPreparation {
                        RecordMark(state: .working)
                        SettingsText(asr.isCancellingModelPreparation ? "Cancelling…" : asr.modelPreparationStatusText)
                            .monospacedDigit()
                    }
                }
                SettingsText(model.cardDescription)
                if !asr.isAsrReady, asr.isDownloadingModel || asr.isLoadingModel, !asr.isCancellingModelPreparation {
                    Button("Cancel") { self.viewModel.cancelActiveModelPreparation() }
                        .buttonStyle(RecordButtonStyle(kind: .quiet, size: 20))
                }
            } else if self.viewModel.installations.isChecking {
                SettingsText("Checking downloaded models…")
            } else if self.viewModel.installations.state == .failed {
                SettingsStateNote("Couldn’t check downloaded models. Try again.")
                Button("Check again") { self.viewModel.installations.refresh() }
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: 20))
            } else {
                SettingsText("No model in use yet. Download one below, then choose Use this model.")
            }
        }
    }

    // MARK: Other models

    @ViewBuilder
    private func actions(for model: SpeechModel) -> some View {
        let asr = self.viewModel.asr
        let blocked = self.viewModel.areSpeechModelActionsBlocked
        if asr.deletingModelID == model.id {
            SettingsText("Deleting…")
        } else if self.viewModel.downloadingModel == model {
            HStack(spacing: FWMetric.space4) {
                if asr.modelPreparationPhase == .downloading, let progress = asr.downloadProgress {
                    RecordProgressLine(fraction: progress)
                        .frame(width: 240)
                    SettingsText(
                        self.viewModel.isCancellingModelDownload
                            ? "Cancelling…"
                            : "\(Int(progress * 100))% of \(Self.size(self.viewModel.speechModelDownloadSize(model)))"
                    )
                    .monospacedDigit()
                } else {
                    SettingsText(self.viewModel.isCancellingModelDownload ? "Cancelling…" : asr.modelPreparationStatusText)
                }
                if !self.viewModel.isCancellingModelDownload {
                    Button("Cancel") { self.viewModel.cancelSpeechModelDownload() }
                        .buttonStyle(RecordButtonStyle(kind: .quiet, size: 20))
                }
            }
        } else if !self.viewModel.installations.canUseModelActions {
            if self.viewModel.installations.isChecking {
                SettingsText("Checking downloads…")
            } else {
                Button("Check again") { self.viewModel.installations.refresh() }
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: 20))
            }
        } else if self.viewModel.isSpeechModelInstalled(model) {
            HStack(spacing: FWMetric.space3) {
                if model.downloadSize != "Built-in" {
                    RecordMark(state: .done)
                    SettingsText("Downloaded", color: FWColor.stateDone)
                }
                Button("Use this model") { self.viewModel.activateSpeechModel(model) }
                    .buttonStyle(RecordButtonStyle(kind: .primary, size: 20))
                    .disabled(blocked)
                if self.viewModel.isSpeechModelUpdateAvailable(model) {
                    Button("Update") { self.viewModel.downloadSpeechModel(model, updateWeights: true) }
                        .buttonStyle(RecordButtonStyle(kind: .secondary, size: 20))
                        .disabled(blocked)
                }
                if !model.usesAppleLogo {
                    Button("Delete") { self.confirmDelete(model) }
                        .buttonStyle(RecordButtonStyle(kind: .destructive, size: 20))
                        .disabled(blocked)
                }
            }
        } else {
            HStack(spacing: FWMetric.space3) {
                Button("Download") {
                    self.viewModel.previewSpeechModel = model
                    self.viewModel.downloadSpeechModel(model)
                }
                .buttonStyle(RecordButtonStyle(kind: .secondary, size: 20))
                .disabled(blocked)
                if model.requiresExternalArtifacts, model.externalCoreMLSpec?.sourceURL != nil {
                    Button("Model page") { self.viewModel.openExternalModelSource(for: model) }
                        .buttonStyle(RecordButtonStyle(kind: .quiet, size: 20))
                        .disabled(blocked)
                }
            }
        }
    }

    private func confirmDelete(_ model: SpeechModel) {
        let size = Self.size(self.viewModel.speechModelDownloadSize(model))
        self.confirm(SettingsConfirmation(
            title: "Delete \(Self.shortName(model))?",
            message: "This removes \(size) from this Mac. You can download it again.",
            actionLabel: "Delete"
        ) {
            self.viewModel.deleteSpeechModel(model)
        })
    }

    // MARK: Language

    private static func hasLanguageChoice(_ model: SpeechModel) -> Bool {
        model.isWhisperModel || model == .cohereTranscribeSixBit
            || model == .nemotronOffline || model == .nemotronStreaming || model == .nemotronStreaming320
    }

    @ViewBuilder
    private var languagePicker: some View {
        let model = self.settings.selectedSpeechModel
        if model.isWhisperModel {
            Button {
                self.whisperLanguageSearchText = ""
                self.isShowingWhisperLanguagePicker.toggle()
            } label: {
                HStack(spacing: FWMetric.space3) {
                    Text(self.selectedWhisperLanguageName)
                    Image(systemName: "chevron.down")
                        .font(.fluidSystem(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(RecordButtonStyle(kind: .secondary, size: 28))
            .accessibilityLabel("Language")
            .accessibilityValue(self.selectedWhisperLanguageName)
            .popover(isPresented: self.$isShowingWhisperLanguagePicker, arrowEdge: .bottom) {
                self.whisperLanguagePickerPopover
            }
        } else if model == .cohereTranscribeSixBit {
            RecordPopUp(self.settings.selectedCohereLanguage.displayName) {
                ForEach(SettingsStore.CohereLanguage.allCases) { language in
                    Button(language.displayName) { self.settings.selectedCohereLanguage = language }
                }
            }
        } else {
            RecordPopUp(self.settings.selectedNemotronLanguage.compactDisplayName) {
                ForEach(SettingsStore.NemotronLanguage.allCases) { language in
                    Button(language.displayName) { self.settings.selectedNemotronLanguage = language }
                }
            }
        }
    }

    private var selectedWhisperLanguageName: String {
        guard let languageCode = self.settings.selectedWhisperLanguageCode,
              let language = VoiceEngineLanguageCatalog.whisperLanguage(forCode: languageCode)
        else {
            return "Automatic"
        }
        return language.displayName
    }

    private var normalizedWhisperLanguageSearchText: String {
        self.whisperLanguageSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var filteredWhisperLanguages: [VoiceEngineLanguage] {
        let query = self.normalizedWhisperLanguageSearchText
        guard !query.isEmpty else { return VoiceEngineLanguageCatalog.whisperLanguages }
        return VoiceEngineLanguageCatalog.whisperLanguages.filter { language in
            language.displayName.lowercased().contains(query) ||
                language.id.lowercased().contains(query) ||
                language.aliases.contains { $0.lowercased().contains(query) }
        }
    }

    private var whisperLanguagePickerPopover: some View {
        VStack(alignment: .leading, spacing: FWMetric.space3) {
            RecordSearch(placeholder: "Search languages", text: self.$whisperLanguageSearchText)
                .padding([.horizontal, .top], FWMetric.space4)
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if self.normalizedWhisperLanguageSearchText.isEmpty || "automatic".contains(self.normalizedWhisperLanguageSearchText) {
                        self.whisperLanguageRow(title: "Automatic", code: nil)
                    }
                    ForEach(self.filteredWhisperLanguages) { language in
                        self.whisperLanguageRow(
                            title: language.displayName,
                            code: VoiceEngineLanguageCatalog.whisperLanguageCode(for: language.id)
                        )
                    }
                }
                .padding(.vertical, FWMetric.space2)
            }
        }
        .frame(width: 280, height: 420)
        .background(FWColor.surfaceRaised)
    }

    private func whisperLanguageRow(title: String, code: String?) -> some View {
        let isSelected = code == self.settings.selectedWhisperLanguageCode
        return Button {
            self.settings.selectedWhisperLanguageCode = code
            self.isShowingWhisperLanguagePicker = false
        } label: {
            HStack(spacing: FWMetric.space3) {
                Text(title)
                    .recordText(FWType.body)
                    .foregroundStyle(FWColor.textPrimary)
                Spacer(minLength: FWMetric.space4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.fluidSystem(size: 11, weight: .semibold))
                        .foregroundStyle(FWColor.textPrimary)
                }
            }
            .padding(.horizontal, FWMetric.space4)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Names

    /// The display name without its long tail: "Nemotron 3.5 Multilingual" becomes "Nemotron 3.5".
    static func shortName(_ model: SpeechModel) -> String {
        var name = model.displayName
        for suffix in [" Multilingual", " - Ultra Fast Low Latency", " - macOS 26+"] {
            if name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        }
        return name
    }

    /// Languages · size, for the margin help.
    static func help(for model: SpeechModel) -> String {
        let size = model.downloadSize == "Built-in" ? "Built in" : Self.size(model.downloadSize)
        return size.isEmpty ? model.languageSupport : "\(model.languageSupport) · \(size)"
    }

    private static func size(_ text: String) -> String {
        text.replacingOccurrences(of: "~", with: "")
    }
}

extension Notification.Name {
    static let openCustomDictionaryFromVoiceEngine = Notification.Name("OpenCustomDictionaryFromVoiceEngine")
}
