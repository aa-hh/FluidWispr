@testable import FluidVoice_Debug
import XCTest

@MainActor
final class OnboardingPolicyTests: XCTestCase {
    // Turns red if the onboarding practice step gets the cleanup time limit, the short-dictation skip
    // or the meaning check, or if real dictation loses them.
    func testOnlyPracticeDictationSkipsCleanupRules() {
        XCTAssertFalse(DictationSession.OutputRoute.onboardingSandbox.appliesCleanupRules)
        XCTAssertTrue(DictationSession.OutputRoute.normal.appliesCleanupRules)
        XCTAssertTrue(DictationSession.OutputRoute.historyOnly.appliesCleanupRules)
    }

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

    // Turns red if the setup steps are reordered, the step index constants drift from the enum,
    // or the voice model step stops letting the person continue once a download has started.
    func testStepOrderAndVoiceModelContinuesWhileDownloading() {
        XCTAssertEqual(
            OnboardingFlowView.Step.allCases,
            [.landing, .language, .voiceModel, .microphone, .accessibility, .playground, .cleanup, .done]
        )
        XCTAssertEqual(OnboardingFlowView.playgroundStepIndex, 5)
        XCTAssertEqual(OnboardingFlowView.cleanupStepIndex, 6)
        XCTAssertFalse(OnboardingFlowView.voiceModelCanContinue(isReady: false, downloadStarted: false, downloadFailed: false))
        XCTAssertTrue(OnboardingFlowView.voiceModelCanContinue(isReady: false, downloadStarted: true, downloadFailed: false))
        XCTAssertTrue(OnboardingFlowView.voiceModelCanContinue(isReady: false, downloadStarted: false, downloadFailed: true))
        XCTAssertTrue(OnboardingFlowView.voiceModelCanContinue(isReady: true, downloadStarted: false, downloadFailed: false))
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
