@testable import FluidVoice_Debug
import XCTest

final class DeliveryTargetAssessmentTests: XCTestCase {
    func testTextRolesAreEditable() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField"] {
            XCTAssertEqual(DeliveryTargetAssessment.classify(role: role, valueSettable: false), .editable(role: role))
        }
    }

    func testSettableValueWinsOverRole() {
        XCTAssertEqual(DeliveryTargetAssessment.classify(role: "AXStaticText", valueSettable: true), .editable(role: "AXStaticText"))
    }

    func testControlsAndStaticContentAreRefused() {
        for role in ["AXButton", "AXStaticText", "AXImage", "AXMenuItem", "AXSlider"] {
            XCTAssertTrue(DeliveryTargetAssessment.classify(role: role, valueSettable: false).isCertainlyNotEditable, role)
        }
    }

    func testContainersStayUnknownSoPasteProceeds() {
        // Apps that draw their own UI report the window or application as the
        // focused element and still accept Cmd+V.
        for role in ["AXWindow", "AXSheet", "AXDrawer", "AXApplication", "AXGroup", "AXWebArea", "AXCell", "AXUnknown"] {
            XCTAssertEqual(DeliveryTargetAssessment.classify(role: role, valueSettable: false), .unknown(reason: "role_\(role)"), role)
        }
    }

    /// Turns red if the Electron check stops looking for Electron's framework, so Claude, Slack and
    /// Notion never get their fields made readable and failed pastes there show no bubble again.
    func testElectronAppsAreFoundByTheirFramework() throws {
        // isolation-ok: a private folder under the temp directory, removed at the end.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ElectronCheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let electron = root.appendingPathComponent("Claude.app")
        let native = root.appendingPathComponent("Notes.app")
        try FileManager.default.createDirectory(
            at: electron.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: native.appendingPathComponent("Contents/Frameworks"), withIntermediateDirectories: true)
        XCTAssertTrue(ElectronAccessibility.isElectron(bundleURL: electron))
        XCTAssertFalse(ElectronAccessibility.isElectron(bundleURL: native))
    }

    /// Turns red if test runs log to ~/Library/Logs/Fluid again, where they push out the log of
    /// real dictation that a failed paste is diagnosed from.
    func testTestRunsLogOutsideTheUsersLibrary() {
        let path = FileLogger.shared.currentLogFileURL().path
        XCTAssertTrue(path.contains("FluidTests-"), path)
        XCTAssertFalse(path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path), path)
    }
}
