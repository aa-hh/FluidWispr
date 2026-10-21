@testable import FluidVoice_Debug
import XCTest

@MainActor
final class OnboardingPolicyTests: XCTestCase {
    // Turns red if onboarding practice output goes to the sandbox when it should paste into
    // another app, or the other way round.
    func testPracticeDictationUsesSandboxOnlyWhileActiveAndNotTargetingAnotherApp() {
        for active in [false, true] {
            for dictation in [false, true] {
                for target: Int32? in [nil, 100, 200] {
                    let actual = OnboardingDictationOutputPolicy.usesSandbox(
                        onboardingPracticeActive: active,
                        isDictation: dictation,
                        targetProcessID: target,
                        fluidVoiceProcessID: 100
                    )
                    XCTAssertEqual(actual, active && dictation && target != 200, "active=\(active) dictation=\(dictation) target=\(String(describing: target))")
                }
            }
        }
    }

    // Turns red if practice accepts stale or empty results, advances while busy, or runs
    // past its last step.
    func testPolishPracticeProgression() {
        var practice = OnboardingPolishPractice()
        practice.receive("Stale result from earlier onboarding")
        XCTAssertNil(practice.result)
        XCTAssertFalse(practice.advance(isBusy: false))
        practice.beginAttempt()
        practice.receive(" \n ")
        XCTAssertNil(practice.result)
        XCTAssertFalse(practice.advance(isBusy: false))
        practice.receive("Hey John,\nHow are you doing today?")
        XCTAssertNotNil(practice.result)
        XCTAssertFalse(practice.advance(isBusy: true))
        XCTAssertEqual(practice.index, 0)
        XCTAssertTrue(practice.advance(isBusy: false))
        XCTAssertFalse(practice.advance(isBusy: false))
        practice.receive("Late duplicate")
        XCTAssertNil(practice.result)
        XCTAssertEqual(practice.results.count, 1)
        practice.beginAttempt()
        practice.receive("Correction result")
        practice.beginAttempt()
        XCTAssertNil(practice.result)
        XCTAssertNotNil(practice.results[0])
        practice.receive("")
        XCTAssertFalse(practice.advance(isBusy: false))
        practice.receive("Retried correction")
        XCTAssertTrue(practice.advance(isBusy: false))
        practice.beginAttempt()
        practice.receive("Grocery list:\n- banana\n- apple\n- orange")
        XCTAssertTrue(practice.isLast)
        XCTAssertEqual(practice.results.count, 3)
        XCTAssertFalse(practice.advance(isBusy: false))
        XCTAssertEqual(practice.index, 2)
    }
}
