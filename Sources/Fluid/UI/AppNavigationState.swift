//
//  AppNavigationState.swift
//  fluid
//
//  Navigation state shared by the main app and settings sidebars.
//

import Foundation

enum SidebarItem: Hashable {
    case today
    case yesterday
    case earlier
    case stats
    case commandMode
    case rewriteMode
    case fileTranscription
    case meetingTranscription
    case customDictionary

    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .earlier: "Earlier"
        case .stats: "Stats"
        case .commandMode: "Command Mode"
        case .rewriteMode: "Edit Mode"
        case .fileTranscription: "File Transcription"
        case .meetingTranscription: "FluidMeet"
        case .customDictionary: "Dictionary"
        }
    }
}

/// Read-only projection; changing chrome cannot navigate or alter a page's state.
struct AppPagePresentation: Equatable {
    let title: String
    let showsPageActions: Bool

    init(destination: SidebarItem?, settings: SettingsNavigationState) {
        self.title = settings.selectedSection?.title ?? (destination ?? .today).title
        self.showsPageActions = !settings.isPresented
    }
}

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general
    case dictation
    case dictationFormatting
    case shortcuts
    case overlay
    case audio
    case notifications
    case voiceEngine
    case cleanup
    case dataAndDiagnostics
    case experimental

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .dictationFormatting: return "Formatting"
        case .shortcuts: return "Shortcuts"
        case .overlay: return "Overlay"
        case .audio: return "Audio"
        case .notifications: return "Notifications"
        case .voiceEngine: return "Voice engine"
        case .cleanup: return "Cleanup"
        case .dataAndDiagnostics: return "Data and diagnostics"
        case .experimental: return "Experimental"
        }
    }
}

struct SettingsNavigationState: Equatable {
    var selectedSection: SettingsSection?
    private(set) var returnDestination: SidebarItem = .today

    var isPresented: Bool {
        self.selectedSection != nil
    }

    func isLeaving(_ section: SettingsSection, for destination: SettingsSection?) -> Bool {
        self.selectedSection == section && destination != section
    }

    mutating func present(_ section: SettingsSection, returningTo currentDestination: SidebarItem?) {
        if !self.isPresented {
            self.returnDestination = currentDestination ?? .today
        }
        self.selectedSection = section
    }

    mutating func dismiss() -> SidebarItem {
        self.selectedSection = nil
        return self.returnDestination
    }

    mutating func leaveForApp() {
        self.selectedSection = nil
    }
}
