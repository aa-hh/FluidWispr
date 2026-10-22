import SwiftUI

struct VoiceEngineSettingsScreen: View {
    let appServices: AppServices
    let theme: AppTheme
    let confirm: (SettingsConfirmation) -> Void

    @StateObject private var viewModel: VoiceEngineSettingsViewModel

    init(appServices: AppServices, theme: AppTheme, confirm: @escaping (SettingsConfirmation) -> Void) {
        self.appServices = appServices
        self.theme = theme
        self.confirm = confirm
        _viewModel = StateObject(wrappedValue: VoiceEngineSettingsViewModel(
            settings: SettingsStore.shared,
            appServices: appServices
        ))
    }

    var body: some View {
        VoiceEngineSettingsView(
            viewModel: self.viewModel,
            settings: self.viewModel.settings,
            theme: self.theme,
            confirm: self.confirm
        )
    }
}

struct AIEnhancementSettingsScreen: View {
    let menuBarManager: MenuBarManager
    let theme: AppTheme
    @Binding var selectedConfigurationSection: AIEnhancementConfigurationSection
    @Binding var activeShortcutRecordingTarget: ShortcutRecordingTarget?
    @Binding var shortcutRecordingMessage: String?
    /// A prompt picked in the sidebar search. Opening its editor is the reveal; the
    /// binding is cleared so the same prompt can be picked again later.
    @Binding var revealTarget: AppSearchHit.Target?
    /// Asks before removing a provider on the Advanced cleanup page.
    let confirm: ((SettingsConfirmation) -> Void)?

    @StateObject private var viewModel: AIEnhancementSettingsViewModel
    @StateObject private var privateAIController: PrivateAISettingsController

    init(
        menuBarManager: MenuBarManager,
        theme: AppTheme,
        selectedConfigurationSection: Binding<AIEnhancementConfigurationSection> = .constant(.providers),
        activeShortcutRecordingTarget: Binding<ShortcutRecordingTarget?> = .constant(nil),
        shortcutRecordingMessage: Binding<String?> = .constant(nil),
        revealTarget: Binding<AppSearchHit.Target?> = .constant(nil),
        confirm: ((SettingsConfirmation) -> Void)? = nil
    ) {
        self.menuBarManager = menuBarManager
        self.theme = theme
        _selectedConfigurationSection = selectedConfigurationSection
        _activeShortcutRecordingTarget = activeShortcutRecordingTarget
        _shortcutRecordingMessage = shortcutRecordingMessage
        _revealTarget = revealTarget
        self.confirm = confirm
        let enhancementModel = AIEnhancementSettingsViewModel(
            settings: SettingsStore.shared,
            menuBarManager: menuBarManager,
            promptTest: DictationPromptTestCoordinator.shared
        )
        _viewModel = StateObject(wrappedValue: enhancementModel)
        _privateAIController = StateObject(wrappedValue: PrivateAISettingsController(viewModel: enhancementModel))
    }

    var body: some View {
        Group {
            if self.selectedConfigurationSection == .cleanupAdvanced {
                // Settings draws this page inside its own scrolling sheet.
                self.settingsView
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: FluidPageLayout.sectionSpacing) {
                        self.settingsView
                    }
                    .fluidPageContent(width: .expanding)
                }
            }
        }
        .task(id: self.revealTarget) {
            guard case let .prompt(id) = self.revealTarget,
                  let profile = self.viewModel.settings.dictationPromptProfiles.first(where: { $0.id == id })
            else { return }
            self.viewModel.openEditor(for: profile)
            self.revealTarget = nil
        }
    }

    private var settingsView: some View {
        AIEnhancementSettingsView(
            viewModel: self.viewModel,
            privateAIController: self.privateAIController,
            settings: self.viewModel.settings,
            promptTest: self.viewModel.promptTest,
            theme: self.theme,
            selectedConfigurationSection: self.$selectedConfigurationSection,
            activeShortcutRecordingTarget: self.$activeShortcutRecordingTarget,
            shortcutRecordingMessage: self.$shortcutRecordingMessage,
            confirm: self.confirm
        )
    }
}
