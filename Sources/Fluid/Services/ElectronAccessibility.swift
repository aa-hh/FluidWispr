import AppKit
import ApplicationServices
import Foundation

/// Electron apps (Claude, Slack, Notion, WhatsApp, VS Code) keep their
/// accessibility tree off until a client asks for it, so the focused field
/// can't be read back and every paste into them ends as "unconfirmed": a paste
/// that didn't land there never shows the failed-paste bubble. Setting
/// `AXManualAccessibility` on the app turns the tree on, once per process.
/// Chromium builds the tree a moment later, so this is called as dictation
/// starts, well before the paste reads the field.
enum ElectronAccessibility {
    private static var enabledPIDs: Set<pid_t> = []

    static func enableForFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        self.enable(for: app)
    }

    static func enable(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier,
              !self.enabledPIDs.contains(pid), AXIsProcessTrusted(),
              let bundleURL = app.bundleURL, self.isElectron(bundleURL: bundleURL)
        else { return }
        self.enabledPIDs.insert(pid)
        let result = AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(pid),
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        DebugLogger.shared.info(
            "ELECTRON_AX app=\(app.bundleIdentifier ?? "pid\(pid)") result=\(result.rawValue)",
            source: "ElectronAccessibility"
        )
    }

    nonisolated static func isElectron(bundleURL: URL) -> Bool {
        let framework = bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }
}
