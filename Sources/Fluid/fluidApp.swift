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
    @ObservedObject private var menuBarManager = MenuBarManager.shared
    @ObservedObject private var settings = SettingsStore.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            #if DEBUG
            if Self.isDiagnosticAutorun {
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
                    NotificationCenter.default.post(name: .sidebarSearchFocusRequested, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
    }

    #if DEBUG
    /// Diagnostic autoruns own the microphone, so they get no app content and no dictation startup.
    static var isDiagnosticAutorun: Bool {
        MeetingExternalReferenceTrialAGate.autorunEnabled(environment: ProcessInfo.processInfo.environment)
            || MeetingSCKPairedDiagnosticGate.autorunEnabled()
            || MeetingStage05EvidenceAutorun.requested()
            || ProcessInfo.processInfo.environment["FLUIDVOICE_MIC_PHASE1"] != nil
            || ProcessInfo.processInfo.environment["FLUIDVOICE_VPIO_ACOUSTIC"] == "1"
    }
    #endif

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
