@testable import FluidVoice_Debug
import XCTest

@MainActor
final class PermissionWatcherTests: XCTestCase {
    private var granted: Set<PermissionWatcher.Permission> = []

    private func makeWatcher() -> PermissionWatcher {
        PermissionWatcher(isGranted: { [unowned self] in self.granted.contains($0) })
    }

    // Turns red if a permission that was never granted (first launch, before setup) is reported
    // as revoked, which would show the lock bubble to a new user.
    func testNeverGrantedPermissionIsNotReportedRevoked() {
        let watcher = self.makeWatcher()
        watcher.refresh()
        watcher.refresh()
        XCTAssertEqual(watcher.revoked, [])
    }

    // Turns red if losing a granted permission stops publishing .revoked, if a repeated check
    // publishes it twice, or if getting it back stops publishing .restored.
    func testRevokeThenRestorePublishesOneChangeEach() async {
        self.granted = [.microphone, .accessibility]
        let watcher = self.makeWatcher()
        var changes = watcher.changes().makeAsyncIterator()
        watcher.refresh()

        self.granted = [.microphone]
        watcher.refresh()
        watcher.refresh()
        XCTAssertEqual(watcher.revoked, [.accessibility])

        self.granted = [.microphone, .accessibility]
        watcher.refresh()
        XCTAssertEqual(watcher.revoked, [])

        let first = await changes.next()
        let second = await changes.next()
        XCTAssertEqual(first, .init(permission: .accessibility, kind: .revoked))
        XCTAssertEqual(second, .init(permission: .accessibility, kind: .restored))
    }

    // Turns red if a second changes() call takes events away from the first, or if each
    // permission is not tracked on its own.
    func testEverySubscriberSeesEachPermissionSeparately() async {
        self.granted = [.microphone, .accessibility]
        let watcher = self.makeWatcher()
        var first = watcher.changes().makeAsyncIterator()
        var second = watcher.changes().makeAsyncIterator()
        watcher.refresh()

        self.granted = []
        watcher.refresh()
        XCTAssertEqual(watcher.revoked, [.microphone, .accessibility])

        for _ in 0 ..< 2 {
            let microphone = await first.next()
            let accessibility = await first.next()
            XCTAssertEqual(microphone, .init(permission: .microphone, kind: .revoked))
            XCTAssertEqual(accessibility, .init(permission: .accessibility, kind: .revoked))
            swap(&first, &second)
        }
    }
}
