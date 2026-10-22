import AppKit
import SwiftUI

/// Settings › Cleanup: the cleanup chain as PRODUCT.md orders it. Cerebras with your
/// key, then Ollama on this Mac, then the built-in rules. "Show advanced" swaps in
/// the Advanced cleanup page (other providers and styles).
struct CleanupSettingsView: View {
    let menuBarManager: MenuBarManager
    let theme: AppTheme
    @Binding var showsAdvanced: Bool
    @Binding var activeShortcutRecordingTarget: ShortcutRecordingTarget?
    @Binding var shortcutRecordingMessage: String?
    let confirm: (SettingsConfirmation) -> Void
    /// A prompt picked in the app search. Styles live on the Advanced page, so it opens first.
    var revealTarget: Binding<AppSearchHit.Target?> = .constant(nil)

    var body: some View {
        Group {
            if self.showsAdvanced {
                AIEnhancementSettingsScreen(
                    menuBarManager: self.menuBarManager,
                    theme: self.theme,
                    selectedConfigurationSection: .constant(.cleanupAdvanced),
                    activeShortcutRecordingTarget: self.$activeShortcutRecordingTarget,
                    shortcutRecordingMessage: self.$shortcutRecordingMessage,
                    revealTarget: self.revealTarget,
                    confirm: self.confirm
                )
            } else {
                CleanupChainRows(showsAdvanced: self.$showsAdvanced, confirm: self.confirm)
            }
        }
        .task(id: self.revealTarget.wrappedValue) {
            if case .prompt = self.revealTarget.wrappedValue { self.showsAdvanced = true }
        }
    }
}

private struct CleanupChainRows: View {
    @Binding var showsAdvanced: Bool
    let confirm: (SettingsConfirmation) -> Void

    @ObservedObject private var settings = SettingsStore.shared
    @State private var keyText = ""
    @State private var isChecking = false
    @State private var failure: CerebrasKeyCheck.Result?
    @State private var hasKey = CerebrasKeyCheck.hasKey
    @State private var maskedKey = ""
    @State private var isReplacing = false
    @State private var ollamaStatus: OllamaService.Status?
    @State private var pullProgress: Double?
    @State private var pullError: String?

    private static let ollamaDownloadURL = URL(string: "https://ollama.com/download")
    private static let ollamaModelLabel = "Ollama \(OllamaService.modelName)"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow("Clean up with", help: "The measured default.", target: .cleanupProvider) {
                HStack(spacing: 6) {
                    SettingsText(self.providerLabel, style: FWType.label, color: FWColor.textPrimary)
                    self.providerStatus
                }
                SettingsText("If it hasn’t answered within \(SettingsStore.shared.dictationCloudCleanupBudgetMilliseconds) ms, FluidWispr moves on to the next step.")
            }
            SettingsRow("API key", help: "Kept in your Keychain.", target: .cleanupKey) {
                self.keyContent
            }
            SettingsRow("Offline", help: "Used when Cerebras can’t answer.", target: .cleanupOffline) {
                self.offlineContent
            }
            SettingsRow("Last resort", help: "Always available.") {
                SettingsText("Built-in rules: filler words, capitals and full stops.", style: FWType.body, color: FWColor.textPrimary)
                SettingsText("Nothing you say is lost if every step above fails.")
            }
            SettingsRow("Short dictations", help: "Three words or fewer skip cleanup.") {
                SettingsText("Always on.", style: FWType.body)
            }
            SettingsRow("Advanced", help: "Other providers and styles.") {
                Button("Show advanced") { self.showsAdvanced = true }
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: 20))
            }
        }
        .task {
            self.loadMaskedKey()
            await self.refreshOllama()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await self.refreshOllama() }
        }
    }

    // MARK: - Clean up with

    private var usesCerebras: Bool {
        let id = self.settings.selectedProviderID
        return id.isEmpty || id == CerebrasKeyCheck.providerID
    }

    private var providerLabel: String {
        guard !self.usesCerebras else { return "Cerebras \(CerebrasKeyCheck.model)" }
        let id = self.settings.selectedProviderID
        let model = self.settings.selectedModelByProvider[ModelRepository.shared.providerKey(for: id)]
            ?? self.settings.selectedModelByProvider[id] ?? ""
        let name = ModelRepository.shared.displayName(for: id)
        return model.isEmpty ? name : "\(name) \(model)"
    }

    @ViewBuilder
    private var providerStatus: some View {
        if !self.usesCerebras {
            SettingsText("Chosen in Advanced cleanup.")
        } else if self.isChecking {
            SettingsText("Checking the key…")
        } else if let failure = self.failure {
            RecordMark(state: .needsYou)
            SettingsText(Self.statusText(for: failure), color: FWColor.stateAttention)
        } else if self.hasKey {
            RecordMark(state: .done)
            SettingsText("Connected", color: FWColor.stateDone)
        } else {
            SettingsText("Needs your key", color: FWColor.textTertiary)
        }
    }

    private static func statusText(for failure: CerebrasKeyCheck.Result) -> String {
        switch failure {
        case .rejected: "Key not accepted"
        case .unreachable: "Couldn’t reach Cerebras"
        case .keychainFailed: "Key not saved"
        case .accepted: "Connected"
        }
    }

    // MARK: - API key

    @ViewBuilder
    private var keyContent: some View {
        if self.isChecking {
            HStack(spacing: FWMetric.space3) {
                SecureRecordField(placeholder: "Paste your Cerebras API key", text: self.$keyText)
                    .frame(width: 300)
                    .disabled(true)
                Button("Checking…") {}
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: 28))
                    .disabled(true)
            }
            SettingsText("This takes a moment. You can leave the page.")
        } else if self.hasKey, !self.isReplacing, self.failure == nil {
            HStack(spacing: FWMetric.space3) {
                SettingsText(self.maskedKey.isEmpty ? "Saved key" : self.maskedKey, style: FWType.body, color: FWColor.textPrimary)
                Button("Replace") {
                    self.keyText = ""
                    self.isReplacing = true
                }
                .buttonStyle(RecordButtonStyle(kind: .secondary, size: 20))
                Button("Remove key") { self.confirmRemoveKey() }
                    .buttonStyle(RecordButtonStyle(kind: .destructive, size: 20))
            }
            SettingsText("Stored in your Keychain. FluidWispr never shows it again.")
        } else if let failure = self.failure {
            HStack(spacing: FWMetric.space3) {
                SecureRecordField(placeholder: "Paste your Cerebras API key", text: self.$keyText, isError: true)
                    .frame(width: 300)
                    .onSubmit { self.checkKey() }
                Button("Check again") { self.checkKey() }
                    .buttonStyle(RecordButtonStyle(kind: .primary, size: 28))
                    .disabled(self.trimmedKey.isEmpty)
            }
            SettingsStateNote(Self.failureNote(for: failure))
            SettingsText("Until then, cleanup uses the offline model or built-in rules. Your words still land.")
        } else {
            HStack(spacing: FWMetric.space3) {
                SecureRecordField(placeholder: "Paste your Cerebras API key", text: self.$keyText, focusesOnAppear: self.isReplacing)
                    .frame(width: 300)
                    .onSubmit { self.checkKey() }
                Button("Check key") { self.checkKey() }
                    .buttonStyle(RecordButtonStyle(kind: .primary, size: 28))
                    .disabled(self.trimmedKey.isEmpty)
            }
            SettingsText("Make one at cloud.cerebras.ai. You pay Cerebras directly.")
        }
    }

    private static func failureNote(for failure: CerebrasKeyCheck.Result) -> String {
        switch failure {
        case .rejected: "Cerebras turned this key down. Copy it again from cloud.cerebras.ai, all of it."
        case .unreachable: "Couldn’t reach Cerebras. Check your connection and try again."
        case .keychainFailed: "Couldn’t save the key. Check Keychain access and try again."
        case .accepted: ""
        }
    }

    private var trimmedKey: String {
        self.keyText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The key reaches the Keychain only after Cerebras accepts it.
    private func checkKey() {
        let key = self.trimmedKey
        guard !key.isEmpty, !self.isChecking else { return }
        self.isChecking = true
        self.failure = nil
        Task { @MainActor in
            let result = await CerebrasKeyCheck.verify(key: key)
            self.isChecking = false
            if result == .accepted {
                self.hasKey = true
                self.isReplacing = false
                self.maskedKey = Self.mask(key)
                self.keyText = ""
            } else {
                self.failure = result
            }
        }
    }

    private func confirmRemoveKey() {
        self.confirm(SettingsConfirmation(
            title: "Remove the Cerebras key?",
            message: "Cleanup will use the offline model or built-in rules until you add a key.",
            actionLabel: "Remove key"
        ) {
            CerebrasKeyCheck.removeKey()
            self.hasKey = false
            self.maskedKey = ""
            self.keyText = ""
        })
    }

    private func loadMaskedKey() {
        self.hasKey = CerebrasKeyCheck.hasKey
        guard self.hasKey, self.maskedKey.isEmpty,
              let key = try? KeychainService.shared.fetchKey(for: CerebrasKeyCheck.providerID)
        else { return }
        self.maskedKey = Self.mask(key)
    }

    /// "csk-••••3f9a": the first four and last four characters, dots between.
    private static func mask(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        return "\(key.prefix(4))\(String(repeating: "•", count: 16))\(key.suffix(4))"
    }

    // MARK: - Offline

    @ViewBuilder
    private var offlineContent: some View {
        switch self.ollamaStatus {
        case nil:
            HStack(spacing: 6) {
                SettingsText(Self.ollamaModelLabel, style: FWType.label, color: FWColor.textPrimary)
                SettingsText("Checking…")
            }
        case .some(.notInstalled):
            HStack(spacing: 6) {
                SettingsText(Self.ollamaModelLabel, style: FWType.label, color: FWColor.textPrimary)
                SettingsText("Not installed", color: FWColor.textTertiary)
            }
            SettingsText("Install Ollama and FluidWispr fetches the model for you.")
            HStack(spacing: FWMetric.space3) {
                Button("Get Ollama") { Self.ollamaDownloadURL.map { _ = NSWorkspace.shared.open($0) } }
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: 20))
                Button("Check again") { Task { await self.refreshOllama() } }
                    .buttonStyle(RecordButtonStyle(kind: .quiet, size: 20))
            }
        case .some(.modelMissing):
            HStack(spacing: 6) {
                SettingsText(Self.ollamaModelLabel, style: FWType.label, color: FWColor.textPrimary)
                SettingsText("Model not downloaded", color: FWColor.textTertiary)
            }
            if let progress = self.pullProgress {
                HStack(spacing: FWMetric.space4) {
                    RecordProgressLine(fraction: progress)
                        .frame(width: 240)
                    SettingsText("\(Int(progress * 100))%")
                }
            } else {
                SettingsText("Ollama is installed. FluidWispr fetches the model into it.")
                Button("Get the model") { self.pullModel() }
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: 20))
            }
            if let pullError = self.pullError {
                SettingsStateNote(pullError)
            }
        case .some(.ready):
            HStack(spacing: 6) {
                SettingsText(Self.ollamaModelLabel, style: FWType.label, color: FWColor.textPrimary)
                RecordMark(state: .done)
                SettingsText("Ready", color: FWColor.stateDone)
            }
            SettingsText("Runs on this Mac when Cerebras is slow or you are offline.")
        }
    }

    private func refreshOllama() async {
        guard self.pullProgress == nil else { return }
        self.ollamaStatus = await OllamaService.shared.status()
    }

    private func pullModel() {
        guard self.pullProgress == nil else { return }
        self.pullProgress = 0
        self.pullError = nil
        Task { @MainActor in
            do {
                try await OllamaService.shared.pullModel { fraction in
                    Task { @MainActor in self.pullProgress = fraction }
                }
                self.pullProgress = nil
            } catch {
                self.pullProgress = nil
                self.pullError = "Couldn’t get the model: \(error.localizedDescription)"
            }
            self.ollamaStatus = await OllamaService.shared.status()
        }
    }
}

/// Record/Field for secrets: the Single field's chrome around a `SecureField`.
struct SecureRecordField: View {
    let placeholder: String
    @Binding var text: String
    var isError = false
    var focusesOnAppear = false

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FWMetric.radiusInner, style: .continuous)
        SecureField("", text: self.$text, prompt: Text(self.placeholder).foregroundStyle(FWColor.textTertiary))
            .textFieldStyle(.plain)
            .recordText(FWType.body)
            .foregroundStyle(FWColor.textPrimary)
            .focused(self.$isFocused)
            .focusEffectDisabled()
            .frame(height: FWMetric.sizeControlM)
            .padding(.leading, FWMetric.space3)
            .padding(.trailing, FWMetric.space4)
            .background(shape.fill(FWColor.surfaceRaised))
            .overlay { shape.strokeBorder(self.isError ? FWColor.stateAttention : FWColor.lineStrong, lineWidth: FWMetric.lineHairline) }
            .recordFocusRing(self.isFocused && self.isEnabled, in: shape)
            .opacity(self.isEnabled ? 1 : 0.4)
            .accessibilityLabel(self.placeholder)
            .onAppear { if self.focusesOnAppear { self.isFocused = true } }
    }
}
