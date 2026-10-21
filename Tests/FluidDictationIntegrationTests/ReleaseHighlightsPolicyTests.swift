@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class ReleaseHighlightsPolicyTests: XCTestCase {
    // Turns red if the "what's new" sheet repeats an acknowledged version, loses an unseen
    // one, lets a stale callback dismiss a newer sheet, or forgets the bounded history.
    func testVersionLedgerAcrossOwnersDismissalsAndInterruptions() throws {
        let owner = UUID()
        let other = UUID()
        var policy = ReleaseHighlightsPolicy()
        for version in [""] {
            XCTAssertNil(policy.request(owner: owner, version: version, eligible: true))
        }
        XCTAssertNil(policy.request(owner: owner, version: "1.6.10-beta.7", eligible: false))
        let first = try XCTUnwrap(policy.request(owner: owner, version: "1.6.10-beta.7", eligible: true))
        XCTAssertTrue(policy.seenVersions.isEmpty, "Opening alone must not acknowledge an interrupted popup")
        XCTAssertNil(policy.request(owner: other, version: first.version, eligible: true), "One presentation across windows")
        XCTAssertTrue(policy.beginDismiss(id: first.id, acknowledge: true))
        XCTAssertTrue(!policy.beginDismiss(id: first.id, acknowledge: true), "A double click cannot replace the first destination")
        XCTAssertNil(policy.request(owner: owner, version: first.version, eligible: true, manual: true), "Dismissal keeps ownership until completion")
        XCTAssertNil(policy.finishDismiss(id: UUID(), eligible: true))
        XCTAssertTrue(policy.session?.id == first.id, "Stale callbacks cannot release another sheet")
        XCTAssertTrue(policy.finishDismiss(id: first.id, eligible: true) == true)
        XCTAssertTrue(policy.seenVersions == [first.version])
        XCTAssertNil(policy.request(owner: owner, version: first.version, eligible: true))

        // A Help click during refinement survives ineligibility and replays an acknowledged version.
        policy.requestManual(owner: owner)
        XCTAssertNil(policy.request(owner: owner, version: first.version, eligible: false))
        let deferred = try XCTUnwrap(policy.request(owner: owner, version: first.version, eligible: true))
        policy.requestManual(owner: owner)
        XCTAssertTrue(policy.finishDismiss(id: deferred.id, eligible: true) == true)
        XCTAssertNil(policy.request(owner: owner, version: first.version, eligible: true), "An open-sheet request must not reopen after dismissal")
        policy.requestManual(owner: owner)
        policy.abandon(owner: owner)
        XCTAssertNil(policy.request(owner: owner, version: first.version, eligible: true), "Closing the host cancels deferred manual intent")

        // Manual replay, interruption during dismissal, and safe deferred retry.
        let replay = try XCTUnwrap(policy.request(owner: owner, version: first.version, eligible: true, manual: true))
        XCTAssertTrue(policy.beginDismiss(id: replay.id, acknowledge: true))
        policy.interrupt(id: replay.id)
        XCTAssertTrue(policy.finishDismiss(id: replay.id, eligible: false) == false)
        XCTAssertTrue(policy.seenVersions == [first.version])
        let resumedReplay = try XCTUnwrap(policy.request(owner: owner, version: first.version, eligible: true))
        XCTAssertTrue(policy.finishDismiss(id: resumedReplay.id, eligible: true) == true)
        let next = try XCTUnwrap(policy.request(owner: other, version: "1.6.10-beta.8", eligible: true))
        policy.interrupt(id: next.id)
        XCTAssertTrue(policy.finishDismiss(id: next.id, eligible: true) == false, "Recovery before onDismiss must not acknowledge an interruption")
        let retry = try XCTUnwrap(policy.request(owner: other, version: next.version, eligible: true))
        policy.abandon(owner: owner)
        XCTAssertTrue(policy.session?.id == retry.id, "Another window cannot cancel this owner")
        policy.abandon(owner: other)
        XCTAssertNil(policy.session)
        XCTAssertNil(policy.finishDismiss(id: retry.id, eligible: true))
        XCTAssertTrue(!policy.seenVersions.contains(next.version), "Closing the host must not lose unseen updates")

        // Every shipped version is independent; rebuilds of the same version do not repeat.
        for version in ["1.6.10-beta.8", "1.6.10", "1.6.11"] {
            let session = try XCTUnwrap(policy.request(owner: owner, version: version, eligible: true))
            XCTAssertTrue(policy.finishDismiss(id: session.id, eligible: true) == true)
            XCTAssertNil(policy.request(owner: owner, version: version, eligible: true))
        }
        XCTAssertNil(policy.request(owner: owner, version: first.version, eligible: true), "Downgrades do not repeat an acknowledged update")
        var bounded = ReleaseHighlightsPolicy(seenVersions: [""] + (0..<80).map { "1.0.\($0)" } + ["1.0.79"])
        XCTAssertTrue(bounded.seenVersions.count == ReleaseHighlightsPolicy.historyLimit)
        let boundedSession = try XCTUnwrap(bounded.request(owner: owner, version: "2.0.0", eligible: true))
        XCTAssertTrue(bounded.finishDismiss(id: boundedSession.id, eligible: true) == true)
        XCTAssertTrue(bounded.seenVersions.count == ReleaseHighlightsPolicy.historyLimit)
        XCTAssertTrue(bounded.seenVersions.last == "2.0.0")

        // A newer build of the same version must show once, independently of content.
        var updates = ReleaseHighlightsPolicy(seenVersions: ["1.6.12-beta.1"])
        let installedVersion = "1.6.12-beta.1"
        let initialBuild = try XCTUnwrap(updates.request(owner: owner, version: installedVersion, build: "29", eligible: true))
        XCTAssertTrue(updates.finishDismiss(id: initialBuild.id, eligible: true) == true)
        updates = ReleaseHighlightsPolicy(seenVersions: updates.seenVersions)
        XCTAssertNil(updates.request(owner: owner, version: installedVersion, build: "29", eligible: true), "Relaunching the same build must not repeat")
        XCTAssertNil(updates.request(owner: owner, version: installedVersion, build: "30", eligible: false), "An update must not interrupt recording or onboarding")
        let newBuild = try XCTUnwrap(updates.request(owner: owner, version: installedVersion, build: "30", eligible: true))
        updates.interrupt(id: newBuild.id)
        XCTAssertTrue(updates.finishDismiss(id: newBuild.id, eligible: false) == false)
        let recovered = try XCTUnwrap(updates.request(owner: owner, version: installedVersion, build: "30", eligible: true))
        XCTAssertNil(updates.finishDismiss(id: newBuild.id, eligible: true), "A stale dismissal must not mark the new presentation seen")
        XCTAssertTrue(updates.finishDismiss(id: recovered.id, eligible: true) == true)
        XCTAssertNil(updates.request(owner: owner, version: installedVersion, build: "30", eligible: true))
        let futureVersion = try XCTUnwrap(updates.request(owner: owner, version: "1.7.0", build: "31", eligible: true))
        XCTAssertTrue(updates.finishDismiss(id: futureVersion.id, eligible: true) == true, "A future update must show even when the content release is unchanged")
    }

    // Turns red if seen versions stop round-tripping through UserDefaults as a string array.
    func testSeenVersionsRoundTripThroughDefaults() throws {
        let seen = ["1.6.10-beta.7", "1.6.10", "1.6.11"]
        let suite = "ReleaseHighlightsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(seen, forKey: ReleaseHighlightsPolicy.seenKey)
        let restored = ReleaseHighlightsPolicy(seenVersions: defaults.stringArray(forKey: ReleaseHighlightsPolicy.seenKey) ?? [])
        XCTAssertEqual(restored.seenVersions, seen)
    }

    // Turns red if the shipped highlights lose their release label, belong to another
    // version family than the app, exceed three features, repeat a feature, or advertise
    // Fluid models to a Mac without Private AI.
    func testShippedContentIsComplete() throws {
        let version = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        XCTAssertFalse(version.isEmpty)
        for privateAI in [false, true] {
            let content = ReleaseHighlightsContent.current(hasPrivateAI: privateAI)
            XCTAssertTrue(!content.release.isEmpty, "The displayed release label must be present")
            XCTAssertTrue(version.hasPrefix(content.release), "Highlights for \(content.release) shipped in \(version)")
            XCTAssertTrue((1...3).contains(content.features.count))
            XCTAssertTrue(Set(content.features.map(\.id)).count == content.features.count)
            for feature in content.features {
                XCTAssertTrue(!feature.title.isEmpty && !feature.detail.isEmpty && !feature.action.isEmpty)
            }
            if !privateAI {
                let last = try XCTUnwrap(content.features.last)
                XCTAssertTrue(!last.title.contains("Fluid models"))
            }
        }
    }
}
