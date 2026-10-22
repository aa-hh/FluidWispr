//
//  fluidApp.swift
//  fluid
//
//  Created by Barathwaj Anandan on 7/30/25.
//

import AppKit
import ApplicationServices
import SwiftUI

@main
struct FluidApp: App {
    @StateObject private var menuBarManager = MenuBarManager()
    @ObservedObject private var settings = SettingsStore.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @FocusedValue(\.settingsIsOpen) private var settingsIsOpen

    var body: some Scene {
        WindowGroup(id: "main") {
            #if DEBUG
            if MeetingExternalReferenceTrialAGate.autorunEnabled(environment: ProcessInfo.processInfo.environment)
                || MeetingSCKPairedDiagnosticGate.autorunEnabled()
                || MeetingStage05EvidenceAutorun.requested()
                || ProcessInfo.processInfo.environment["FLUIDVOICE_MIC_PHASE1"] != nil
                || ProcessInfo.processInfo.environment["FLUIDVOICE_VPIO_ACOUSTIC"] == "1"
            {
                Color.clear
            } else {
                self.applicationContent
            }
            #else
            self.applicationContent
            #endif
        }
        .defaultSize(width: 1000, height: 700)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    self.menuBarManager.openPreferencesFromUI()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("Find") {
                    // Settings searches from its sidebar; every other page has its own search.
                    let name: Notification.Name = self.settingsIsOpen == true ? .sidebarSearchFocusRequested : .pageSearchFocusRequested
                    NotificationCenter.default.post(name: name, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            CommandMenu("History") {
                Button("Clear History…") {
                    NotificationCenter.default.post(name: .clearHistoryRequested, object: nil)
                }
            }
        }
    }

    @ViewBuilder
    private var applicationContent: some View {
        // Test runs must not start ContentView: it reads the real microphone settings and shows overlays.
        if TestHost.isActive {
            Color.clear
        } else {
            AdaptiveAppTheme(accent: self.settings.accentColor) {
                ContentView()
                    .environmentObject(self.menuBarManager)
                    // Resolve the singleton only when the normal application content branch is built.
                    // The DEBUG C2 autorun branch returns Color.clear before this view is evaluated.
                    .environmentObject(AppServices.shared)
            }
        }
    }
}

private struct SettingsIsOpenKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    /// True while the main window shows Settings, so Find knows which search to focus.
    var settingsIsOpen: Bool? {
        get { self[SettingsIsOpenKey.self] }
        set { self[SettingsIsOpenKey.self] = newValue }
    }
}
