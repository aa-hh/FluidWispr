import Foundation

/// Features FluidWispr leaves out of its build: meetings (with live captions and coding-agent
/// integrations), file transcription, Command Mode and the local API.
///
/// The `FLUIDWISPR_LEAN` compilation condition, set for the app target, turns them off. Their code
/// still compiles, so upstream merges and the existing tests keep working, but nothing starts
/// them at launch and no sidebar, menu bar, search or Settings entry leads to them.
///
/// Debug builds keep the local API, still off until `LocalAPIEnabled` is set, because
/// tools/cleanup_comparison transcribes recordings through it.
nonisolated enum FluidWisprBuild {
    #if FLUIDWISPR_LEAN
    static let isLean = true
    #else
    static let isLean = false
    #endif

    #if DEBUG
    static let isDebug = true
    #else
    static let isDebug = false
    #endif

    static var includesMeetings: Bool { !self.isLean }
    static var includesFileTranscription: Bool { !self.isLean }
    static var includesCommandMode: Bool { !self.isLean }
    static var includesLocalAPI: Bool { !self.isLean || self.isDebug }
}

extension SidebarItem {
    var isInThisBuild: Bool {
        switch self {
        case .meetingTranscription: FluidWisprBuild.includesMeetings
        case .fileTranscription: FluidWisprBuild.includesFileTranscription
        case .commandMode: FluidWisprBuild.includesCommandMode
        default: true
        }
    }

    /// A page left out of this build opens the Dashboard instead, so a saved selection,
    /// a menu item or a search result can never land on it.
    var shownInThisBuild: SidebarItem {
        self.isInThisBuild ? self : .welcome
    }
}

nonisolated extension AppSearchKind {
    var isInThisBuild: Bool {
        switch self {
        case .transcripts: FluidWisprBuild.includesFileTranscription
        case .chats: FluidWisprBuild.includesCommandMode
        default: true
        }
    }
}
