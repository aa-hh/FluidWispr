import AppKit
import Carbon.HIToolbox
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class PasteTests: XCTestCase {
    // Turns red if restoring the clipboard after a paste loses item representations, leaves
    // dictated text in an originally empty clipboard, or overwrites something the user copied.
    func testClipboardIsRestoredOnlyWhileStillOurs() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("fluidvoice.paste-tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let original = NSPasteboardItem()
        original.setString("original", forType: .string)
        original.setData(Data([0, 1, 2, 255]), forType: .rtf)
        let second = NSPasteboardItem()
        second.setData(Data([3, 4, 5]), forType: .png)
        board.clearContents()
        XCTAssertTrue(board.writeObjects([original, second]))
        let preserved = PreservedPasteboardSnapshot(board)
        board.clearContents()
        board.setString("dictated", forType: .string)
        let owned = board.changeCount
        XCTAssertTrue(preserved.restore(to: board, ifUnchangedSince: owned))
        XCTAssertEqual(PreservedPasteboardSnapshot(board).items, preserved.items, "All item representations must round-trip")

        board.clearContents()
        board.setString("dictated", forType: .string)
        let oldGeneration = board.changeCount
        board.clearContents()
        board.setString("dictated", forType: .string)
        let userCopy = board.changeCount
        XCTAssertFalse(preserved.restore(to: board, ifUnchangedSince: oldGeneration), "Same text copied again belongs to the user")
        XCTAssertEqual(board.changeCount, userCopy)
        XCTAssertEqual(board.string(forType: .string), "dictated")
        board.clearContents()
        board.setString("new user copy", forType: .string)
        XCTAssertFalse(preserved.restore(to: board, ifUnchangedSince: oldGeneration))
        XCTAssertEqual(board.string(forType: .string), "new user copy")

        board.clearContents()
        let empty = PreservedPasteboardSnapshot(board)
        board.setString("temporary", forType: .string)
        XCTAssertTrue(empty.restore(to: board, ifUnchangedSince: board.changeCount))
        XCTAssertNil(board.string(forType: .string), "An originally empty clipboard must end empty")
    }

    // Turns red if Cmd+V is sent with the wrong key code on a non-QWERTY layout, or a missing
    // layout stops falling back to the QWERTY V key. Reads installed layouts without
    // enabling or switching any input source.
    func testPasteKeyCodeForInstalledLayouts() throws {
        let sources = try XCTUnwrap(
            TISCreateInputSourceList(nil, true).takeRetainedValue() as? [TISInputSource],
            "Unable to read installed keyboard layouts"
        )
        for (identifier, expected): (String, CGKeyCode) in [
            ("com.apple.keylayout.US", 9),
            ("com.apple.keylayout.Dvorak", 47),
            ("com.apple.keylayout.DVORAK-QWERTYCMD", 9),
            ("com.apple.keylayout.French", 9),
            ("com.apple.keylayout.Russian", 9),
        ] {
            let source = try XCTUnwrap(sources.first { source in
                guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return false }
                return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String == identifier
            }, "Missing test layout: \(identifier)")
            let pointer = try XCTUnwrap(TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData), "No layout data: \(identifier)")
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
            XCTAssertEqual(PasteKeyCodeResolver.resolve(layoutData: data, keyboardType: UInt32(LMGetKbdType())), expected, identifier)
        }
        XCTAssertEqual(PasteKeyCodeResolver.resolve(layoutData: nil, keyboardType: 0), 9)
        XCTAssertEqual(PasteKeyCodeResolver.resolve(layoutData: Data(), keyboardType: 0), 9)
    }

    // Turns red if a paste queries the keyboard layout instead of the cached key, a layout
    // change notification stops refreshing the cache, an unrelated notification refreshes
    // it, or the notification observer keeps the cache alive.
    func testPasteKeyCacheRefreshesOnlyOnLayoutChange() {
        let name = Notification.Name("FluidVoice.PasteKeyCacheTest.\(UUID().uuidString)")
        var selectedKey: CGKeyCode = 9
        var lookups = 0
        let cache = PasteKeyCodeCache(notificationName: name) {
            lookups += 1
            return selectedKey
        }
        cache.start()
        cache.start()
        XCTAssertEqual(lookups, 1, "Startup must resolve exactly once")
        XCTAssertTrue((0..<10_000).allSatisfy { _ in cache.snapshot() == 9 })
        XCTAssertEqual(lookups, 1, "Pastes must not query the layout")
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("FluidVoice.UnrelatedTest.\(UUID().uuidString)"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.02)) // real-time-ok: distributed notifications arrive through the run loop
        XCTAssertEqual(lookups, 1, "Unrelated notifications must not refresh the cache")

        func notifyAndWait(for key: CGKeyCode) {
            selectedKey = key
            DistributedNotificationCenter.default().postNotificationName(
                name,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            let limit = Date().addingTimeInterval(2) // real-time-ok: 2s ceiling for a distributed notification
            while cache.snapshot() != key, Date() < limit {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005)) // real-time-ok: pumps the run loop until the notification lands
            }
            XCTAssertEqual(cache.snapshot(), key, "Layout-change notification must update the snapshot")
        }
        notifyAndWait(for: 47) // Alternate layout, not hard-coded QWERTY.
        notifyAndWait(for: 9) // Resolver's unavailable-layout fallback replaces stale key.
        for key: CGKeyCode in [47, 12, 9, 47, 9] {
            notifyAndWait(for: key)
        }

        var released: PasteKeyCodeCache? = PasteKeyCodeCache(notificationName: name) { 9 }
        released?.start()
        weak var weakCache = released
        released = nil
        XCTAssertNil(weakCache, "Observer must not retain cache")
    }
}
