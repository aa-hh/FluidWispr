import AppKit
@testable import FluidVoice_Debug
import XCTest

/// Drives the real update prompt panels. Each test has its own presenter and closes what it opened.
@MainActor
final class UpdatePromptPresenterTests: XCTestCase {
    private lazy var presenter = UpdatePromptPresenter()
    private var answered: [String] = []

    override func tearDown() async throws {
        self.presenter.dismissAll()
        try await super.tearDown()
    }

    private func action(_ title: String, records label: String) -> FloatingPromptAction {
        FloatingPromptAction(title: title) { self.answered.append(label) }
    }

    private func offer(_ message: String, label: String, automatic: Bool = false) {
        self.presenter.presentFloatingPrompt(
            title: "Update Available",
            message: message,
            actions: [self.action("Later", records: "\(label) later"), self.action("Install Now", records: "\(label) install")],
            isAutomaticUpdateOffer: automatic
        )
    }

    private func notice(_ title: String, label: String) {
        self.presenter.presentFloatingPrompt(title: title, message: title, actions: [self.action("OK", records: label)])
    }

    private func visiblePanels(_ title: String) -> [NSWindow] {
        NSApp.windows.filter { $0.title == title && $0.isVisible }
    }

    private func panel(_ title: String) throws -> NSWindow {
        try XCTUnwrap(self.visiblePanels(title).first, "No visible prompt titled \(title)")
    }

    private func button(_ title: String, in panel: NSWindow) throws -> NSButton {
        let buttons = panel.contentView?.subviews.compactMap { $0 as? NSButton } ?? []
        return try XCTUnwrap(buttons.first { $0.title == title }, "No \(title) button")
    }

    private func message(in panel: NSWindow) -> [String] {
        panel.contentView?.subviews.compactMap { ($0 as? NSTextField)?.stringValue } ?? []
    }

    private func returnKey(for panel: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
    }

    // Turns red if an update offer takes keyboard focus, opens as a modal, stops floating, clips its text
    // or buttons, or answers before the user clicks.
    func testOfferNeitherTakesFocusNorBlocks() throws {
        let keyWindow = NSApp.keyWindow
        let firstResponder = keyWindow?.firstResponder
        self.offer("FluidVoice v1.6.10 is now available. The app will restart automatically after installation.", label: "offer")

        let panel = try self.panel("Update Available")
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        XCTAssertTrue(keyWindow?.firstResponder === firstResponder)
        XCTAssertNil(NSApp.modalWindow)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(try self.button("Install Now", in: panel).acceptsFirstMouse(for: nil))
        XCTAssertTrue(self.answered.isEmpty)

        let content = try XCTUnwrap(panel.contentView)
        for view in content.subviews {
            XCTAssertTrue(content.bounds.contains(view.frame), "\(view) sits outside the panel")
            if let label = view as? NSTextField { XCTAssertGreaterThanOrEqual(label.frame.height, ceil(label.fittingSize.height)) }
            if let button = view as? NSButton { XCTAssertGreaterThanOrEqual(button.frame.width, ceil(button.fittingSize.width)) }
        }
    }

    // Turns red if the same offer opens twice, a queued notice jumps ahead of it, or a button from a closed
    // prompt still runs its action.
    func testRepeatedOfferShowsOnceAndOldButtonsDoNothing() throws {
        self.offer("Version 1", label: "offer")
        let panel = try self.panel("Update Available")
        let install = try self.button("Install Now", in: panel)
        self.offer("Version 1", label: "repeat")
        self.notice("Update Check Failed", label: "failure")
        XCTAssertEqual(self.visiblePanels("Update Available").count, 1)
        XCTAssertTrue(try self.panel("Update Available") === panel)
        XCTAssertTrue(self.visiblePanels("Update Check Failed").isEmpty)

        try self.button("Later", in: panel).performClick(nil)
        XCTAssertEqual(self.answered, ["offer later"])
        XCTAssertFalse(panel.isVisible)
        install.performClick(nil)
        XCTAssertEqual(self.answered, ["offer later"])

        try self.panel("Update Check Failed").cancelOperation(nil)
        XCTAssertEqual(self.answered, ["offer later", "failure"])
        XCTAssertTrue(self.visiblePanels("Update Check Failed").isEmpty)
    }

    // Turns red if the prompt queue grows past four, answers out of order, accepts a prompt with no buttons,
    // or stops showing prompts after it drains.
    func testQueueIsBoundedAndAnsweredInOrder() throws {
        for index in 0..<8 {
            self.notice("Queue \(index)", label: "\(index)")
        }
        for index in 0..<4 {
            try self.panel("Queue \(index)").cancelOperation(nil)
        }
        XCTAssertEqual(self.answered, ["0", "1", "2", "3"])
        XCTAssertFalse(NSApp.windows.contains { $0.isVisible && $0.title.hasPrefix("Queue ") })

        self.presenter.presentFloatingPrompt(title: "Empty", message: "No actions", actions: [])
        XCTAssertTrue(self.visiblePanels("Empty").isEmpty)
        self.notice("Recovered", label: "recovered")
        try self.panel("Recovered").cancelOperation(nil)
        XCTAssertEqual(self.answered.last, "recovered")
    }

    // Turns red if dismissing everything leaves a queued notice behind, or a button from a dismissed offer
    // can install from a later one.
    func testDismissAllClearsTheQueueAndOldButtons() throws {
        self.offer("Dismissed offer", label: "dismissed")
        let staleInstall = try self.button("Install Now", in: self.panel("Update Available"))
        self.notice("Queued failure", label: "queued failure")
        self.presenter.dismissAll()
        self.presenter.dismissAll()
        XCTAssertTrue(self.visiblePanels("Update Available").isEmpty)
        XCTAssertTrue(self.visiblePanels("Queued failure").isEmpty)

        staleInstall.performClick(nil)
        self.offer("Fresh offer", label: "fresh")
        staleInstall.performClick(nil)
        XCTAssertTrue(self.answered.isEmpty)
        XCTAssertFalse(self.visiblePanels("Update Available").isEmpty)
    }

    // Turns red if a newer version's offer leaves the old one on screen, loses its place in the queue,
    // takes focus, or lets the old offer's buttons answer it.
    func testNewerOfferReplacesTheOldOneInPlace() throws {
        let keyWindow = NSApp.keyWindow
        self.offer("Version 1", label: "old")
        let oldPanel = try self.panel("Update Available")
        let oldInstall = try self.button("Install Now", in: oldPanel)
        let oldLater = try self.button("Later", in: oldPanel)
        self.notice("First notice", label: "first notice")
        self.offer("Version 2", label: "new")

        let newerPanel = try self.panel("Update Available")
        XCTAssertFalse(newerPanel === oldPanel)
        XCTAssertFalse(oldPanel.isVisible)
        XCTAssertTrue(self.message(in: newerPanel).contains("Version 2"))
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        oldInstall.performClick(nil)
        oldLater.performClick(nil)
        XCTAssertTrue(self.answered.isEmpty)
        try self.button("Later", in: newerPanel).performClick(nil)
        XCTAssertEqual(self.answered, ["new later"])

        // A queued offer is replaced where it waits; the notices around it keep their places.
        self.offer("Queued version 1", label: "old queued")
        self.notice("Last notice", label: "last notice")
        self.offer("Queued version 2", label: "new queued")
        try self.panel("First notice").cancelOperation(nil)
        let queuedPanel = try self.panel("Update Available")
        XCTAssertTrue(self.message(in: queuedPanel).contains("Queued version 2"))
        XCTAssertTrue(self.visiblePanels("Last notice").isEmpty)
        try self.button("Install Now", in: queuedPanel).performClick(nil)
        try self.panel("Last notice").cancelOperation(nil)
        XCTAssertEqual(self.answered, ["new later", "first notice", "new queued install", "last notice"])
    }

    // Turns red if refreshing an offer the user clicked into drops its keyboard focus, or Return stops
    // pressing the new offer's Install button.
    func testRefreshingAFocusedOfferKeepsFocus() throws {
        self.offer("Focused version 1", label: "old")
        let oldPanel = try self.panel("Update Available")
        let oldInstall = try self.button("Install Now", in: oldPanel)
        oldPanel.makeKey()
        try XCTSkipUnless(oldPanel.isKeyWindow, "This runner cannot give the test app keyboard focus")

        self.offer("Focused version 2", label: "fresh")
        let refreshed = try self.panel("Update Available")
        XCTAssertFalse(refreshed === oldPanel)
        XCTAssertTrue(refreshed.isKeyWindow)
        oldInstall.performClick(nil)
        XCTAssertTrue(self.answered.isEmpty)
        XCTAssertTrue(try refreshed.performKeyEquivalent(with: self.returnKey(for: refreshed)))
        XCTAssertEqual(self.answered, ["fresh install"])
        XCTAssertFalse(refreshed.isVisible)
    }

    // Turns red if turning off update pop-ups leaves an automatic offer up, removes an error the user asked for,
    // lets a removed offer's button install, or removes a manual offer that replaced an automatic one.
    func testAutomaticOffersAreRemovedButManualOnesStay() throws {
        self.offer("Automatic version", label: "automatic", automatic: true)
        let automatic = try self.panel("Update Available")
        let automaticInstall = try self.button("Install Now", in: automatic)
        self.notice("Update Check Failed", label: "error")
        self.presenter.dismissAutomaticUpdateOffers()
        XCTAssertFalse(automatic.isVisible)
        XCTAssertFalse(self.visiblePanels("Update Check Failed").isEmpty)
        automaticInstall.performClick(nil)
        XCTAssertTrue(self.answered.isEmpty)

        self.offer("Queued automatic", label: "queued automatic", automatic: true)
        self.presenter.dismissAutomaticUpdateOffers()
        try self.panel("Update Check Failed").cancelOperation(nil)
        XCTAssertEqual(self.answered, ["error"])
        XCTAssertTrue(self.visiblePanels("Update Available").isEmpty)

        // Asking for updates turns the same automatic offer into a manual one.
        self.offer("Same version", label: "old automatic", automatic: true)
        let promotedFrom = try self.panel("Update Available")
        let staleInstall = try self.button("Install Now", in: promotedFrom)
        self.offer("Same version", label: "manual")
        let manual = try self.panel("Update Available")
        XCTAssertFalse(manual === promotedFrom)
        XCTAssertFalse(promotedFrom.isVisible)
        self.offer("Same version", label: "downgraded automatic", automatic: true)
        self.presenter.dismissAutomaticUpdateOffers()
        XCTAssertTrue(try self.panel("Update Available") === manual)
        staleInstall.performClick(nil)
        XCTAssertEqual(self.answered, ["error"])
        try self.button("Install Now", in: manual).performClick(nil)
        XCTAssertEqual(self.answered, ["error", "manual install"])
    }
}
