@testable import FluidVoice_Debug
import XCTest

// The unloader waits on a real quiet period, so these tests use short real delays
// (60 to 150 ms) and wait a few times longer before checking.
final class PrivateAIIdleUnloaderTests: XCTestCase {
    private actor Recorder {
        private(set) var unloads = 0
        var delayMs: Int? = 60
        var busy = false
        func noteUnload() { self.unloads += 1 }
        func set(delayMs: Int?) { self.delayMs = delayMs }
        func set(busy: Bool) { self.busy = busy }
    }

    private func makeUnloader(_ recorder: Recorder) -> PrivateAIIdleUnloader {
        PrivateAIIdleUnloader(
            delay: { await recorder.delayMs.map { .milliseconds($0) } },
            isBusy: { await recorder.busy },
            unload: { await recorder.noteUnload() }
        )
    }

    private func pause(_ ms: Int) async {
        try? await Task.sleep(for: .milliseconds(ms)) // real-time-ok: the unloader counts down on the real clock
    }

    // Turns red if the model is not released once after the quiet period, or every new
    // request fails to restart the countdown.
    func testUnloadsOnceAfterQuietPeriodAndActivityRestartsIt() async {
        let quick = Recorder()
        await self.makeUnloader(quick).tracking {}
        await self.pause(250)
        let quickUnloads = await quick.unloads
        XCTAssertEqual(quickUnloads, 1, "Unloads once after the quiet period")

        let busy = Recorder()
        await busy.set(delayMs: 150)
        let unloader = self.makeUnloader(busy)
        for _ in 0..<4 {
            await unloader.tracking {}
            await self.pause(60)
        }
        var unloads = await busy.unloads
        XCTAssertEqual(unloads, 0, "Activity keeps restarting the countdown")
        await self.pause(400)
        unloads = await busy.unloads
        XCTAssertEqual(unloads, 1, "Unloads after activity stops")
    }

    // Turns red if the model is unloaded while a request is still running, including when
    // requests overlap.
    func testNeverUnloadsDuringARequest() async {
        let single = Recorder()
        let unloader = self.makeUnloader(single)
        await unloader.begin()
        await self.pause(250)
        var unloads = await single.unloads
        XCTAssertEqual(unloads, 0, "Never unloads while a request is in flight")
        await unloader.end()
        await self.pause(250)
        unloads = await single.unloads
        XCTAssertEqual(unloads, 1, "Unloads once the request finishes")

        let overlapping = Recorder()
        let shared = self.makeUnloader(overlapping)
        await shared.begin()
        await shared.tracking {}
        await self.pause(250)
        let overlapUnloads = await overlapping.unloads
        XCTAssertEqual(overlapUnloads, 0, "Overlapping requests hold the model until the last one ends")
        await shared.end()
    }

    // Turns red if "never" still unloads, or picking a period afterwards needs new activity
    // to start counting.
    func testSettingsChangeStartsCountdown() async {
        let recorder = Recorder()
        await recorder.set(delayMs: nil)
        let unloader = self.makeUnloader(recorder)
        await unloader.tracking {}
        await self.pause(250)
        var unloads = await recorder.unloads
        XCTAssertEqual(unloads, 0, "Does nothing when set to never")
        await recorder.set(delayMs: 60)
        await unloader.settingsChanged()
        await self.pause(250)
        unloads = await recorder.unloads
        XCTAssertEqual(unloads, 1, "Picking a period starts the countdown without new activity")
    }

    // Turns red if the model is unloaded during a recording, stays loaded after it ends, or a
    // failed request keeps its hold.
    func testWaitsForRecordingAndReleasesFailedRequests() async {
        let recorder = Recorder()
        await recorder.set(busy: true)
        let unloader = self.makeUnloader(recorder)
        await unloader.tracking {}
        await self.pause(250)
        var unloads = await recorder.unloads
        XCTAssertEqual(unloads, 0, "Waits while a recording is in progress")
        await recorder.set(busy: false)
        await self.pause(250)
        unloads = await recorder.unloads
        XCTAssertEqual(unloads, 1, "Unloads after the recording ends")

        struct Boom: Error {}
        let failing = Recorder()
        let failingUnloader = self.makeUnloader(failing)
        do { try await failingUnloader.tracking { throw Boom() } } catch {}
        await self.pause(250)
        let failedUnloads = await failing.unloads
        XCTAssertEqual(failedUnloads, 1, "A failed request still releases its hold")
    }
}
