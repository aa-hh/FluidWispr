import Foundation

/// Keeps the app's one live `GlobalHotkeyManager`, outside any SwiftUI view.
///
/// SwiftUI can build `ContentView` more than once (for example when the main window is closed
/// and reopened from the menu bar), and each build makes its own manager whose callbacks point
/// at that build's state. Installing the new manager shuts the previous one down first, so only
/// one set of event taps exists and no tap is torn down by a deinit that runs at a random time.
@MainActor
final class HotkeyManagerOwner {
    static let shared = HotkeyManagerOwner()

    private(set) var current: GlobalHotkeyManager?

    func install(_ manager: GlobalHotkeyManager) {
        guard manager !== self.current else { return }
        self.current?.shutDown()
        self.current = manager
    }
}
