import SwiftUI

enum AIEnhancementConfigurationSection: String {
    case providers
    case advancedPrompts
    /// Settings › Cleanup › Advanced: providers and cleanup styles as ruled rows.
    case cleanupAdvanced
}

struct AIEnhancementSettingsView: View {
    @ObservedObject var viewModel: AIEnhancementSettingsViewModel
    @ObservedObject var privateAIController: PrivateAISettingsController
    @ObservedObject var settings: SettingsStore
    @ObservedObject var promptTest: DictationPromptTestCoordinator
    let theme: AppTheme
    @Binding var selectedConfigurationSection: AIEnhancementConfigurationSection
    @Binding var activeShortcutRecordingTarget: ShortcutRecordingTarget?
    @Binding var shortcutRecordingMessage: String?
    /// Asks before removing a provider on the Advanced cleanup page.
    var confirm: ((SettingsConfirmation) -> Void)? = nil
    @State var expandedProviderID: String? = nil
    @State var showingAddProviderSheet = false
    @State var showingPromptProviderSetup = false
    @State var managedExternalProviderID: String?
    @State var showingRemoveProviderConfirmation = false
    @State var providerSearchText: String = ""
    @State var hoveredPromptCardKey: String? = nil
    @State var selectedPromptMode: SettingsStore.PromptMode = .dictate
    @State var hoveredPromptModeKey: String? = nil
    @State var hoveredPromptScopeKey: String? = nil
    @State var isPromptProfilesHelpPresented: Bool = false
    @State var showsAppSpecificStyles = false
    @State var promptEditorPrimarySelectionDraft: SettingsStore.DictationPromptSelection? = nil
    @State var promptEditorShortcutDraft: HotkeyShortcut? = nil
    @State var promptEditorProviderIDDraft: String = ""
    @State var promptEditorModelDraft: String = ""
    @State var promptEditorOriginalConfiguration: SettingsStore.DictationPromptConfiguration? = nil

    var body: some View {
        Group {
            if self.selectedConfigurationSection == .cleanupAdvanced {
                self.advancedCleanupPage
            } else {
                self.aiConfigurationCard
            }
        }
            .onAppear {
                self.viewModel.onAppear()
                self.privateAIController.synchronizeSelection()
                self.privateAIController.refreshPrivateAILoadState()
                self.privateAIController.refreshPrivateAIModelUpdateStatus(self.privateAIController.selectedPrivateAIModel)
            }
            .onChange(of: self.viewModel.connectionStatus) { oldValue, newValue in
                if oldValue == .success && newValue != .success {
                    self.expandedProviderID = self.viewModel.selectedProviderID
                }
            }
            .onChange(of: self.viewModel.showKeychainPermissionAlert) { _, isPresented in
                guard isPresented else { return }
                self.viewModel.presentKeychainAccessAlert(message: self.viewModel.keychainPermissionMessage)
                self.viewModel.showKeychainPermissionAlert = false
            }
            .alert("Delete Prompt?", isPresented: self.$viewModel.showingDeletePromptConfirm) {
                Button("Delete", role: .destructive) {
                    self.viewModel.deletePendingPrompt()
                }
                Button("Cancel", role: .cancel) {
                    self.viewModel.clearPendingDeletePrompt()
                }
            } message: {
                if self.viewModel.pendingDeletePromptName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("This cannot be undone.")
                } else {
                    Text("Delete “\(self.viewModel.pendingDeletePromptName)”? This cannot be undone.")
                }
            }
            .alert(
                "Couldn't Add App Override",
                isPresented: Binding(
                    get: { !self.viewModel.appPromptBindingErrorMessage.isEmpty },
                    set: { isPresented in
                        if !isPresented {
                            self.viewModel.appPromptBindingErrorMessage = ""
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {
                    self.viewModel.appPromptBindingErrorMessage = ""
                }
            } message: {
                Text(self.viewModel.appPromptBindingErrorMessage)
            }
    }
}
