import Combine
@testable import FluidVoice_Debug
import Foundation
import Metal
import XCTest

final class RecordingPillTests: XCTestCase {
    private let medium = RecordingPillSize.medium.points

    private func simulation(collapses: Bool) -> RimSimulation {
        RimSimulation(collapsesWhenDone: collapses, random: { 0.5 })
    }

    private func run(_ sim: inout RimSimulation, _ state: RimState, for duration: Float, features: RimFeatures = RimFeatures()) {
        let dt: Float = 1 / 120
        var elapsed: Float = 0
        while elapsed < duration - dt / 2 {
            sim.update(dt: dt, state: state, features: features, reduced: false, pill: self.medium)
            elapsed += dt
        }
    }

    // Red if the Metal source in RecordingPillShader stops compiling; the app would then fall back to the old overlay.
    func testShaderSourceCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device on this machine") }
        let library = try device.makeLibrary(source: RecordingPillShader.source, options: nil)
        XCTAssertNotNil(library.makeFunction(name: RecordingPillShader.vertexFunction))
        XCTAssertNotNil(library.makeFunction(name: RecordingPillShader.fragmentFunction))
    }

    // Red if an offset in RimUniform drifts from the matching #define in the shader source.
    func testUniformOffsetsMatchShaderDefines() {
        let expected: [String: Int] = [
            "U_PILL_W": RimUniform.pillW, "U_PILL_H": RimUniform.pillH, "U_FULL_W": RimUniform.fullW,
            "U_FADE": RimUniform.fade, "U_SCALE": RimUniform.scale, "U_PHASE": RimUniform.phase,
            "U_WOBBLE": RimUniform.wobble, "U_CONTRAST": RimUniform.contrast, "U_EXPOSURE": RimUniform.exposure,
            "U_HUE": RimUniform.hue, "U_HUE_SHIFT": RimUniform.hueShift, "U_HUE_CYCLES": RimUniform.hueCycles,
            "U_TILT": RimUniform.tilt, "U_LOW_S": RimUniform.lowS, "U_HIGH_S": RimUniform.highS,
            "U_TILT_S": RimUniform.tiltS, "U_BAND_LIFT": RimUniform.bandLift, "U_BANDS": RimUniform.bands,
            "U_BLOOM_COUNT": RimUniform.bloomCount, "U_BLOOMS": RimUniform.blooms, "U_WIDTH": RimUniform.width,
            "U_WIDTH_GAIN": RimUniform.widthGain, "U_GLOW": RimUniform.glow, "U_REACH": RimUniform.reach,
            "U_DIM_RIM": RimUniform.dimRim, "U_STRENGTH": RimUniform.strength, "U_REST_EASE": RimUniform.restEase,
            "U_CORE_ON": RimUniform.coreOn, "U_DONE_T": RimUniform.doneT, "U_THINK_T": RimUniform.thinkT,
            "U_REDUCED": RimUniform.reduced, "U_DOWNLOAD_TIME": RimUniform.downloadTime, "U_SNAP_TIME": RimUniform.snapTime,
            "U_LINE_WIDTH": RimUniform.lineWidth, "U_INNER_GLOW": RimUniform.innerGlow, "U_BREATH": RimUniform.breath,
            "U_PULSE_DEPTH": RimUniform.pulseDepth, "U_LINE_PHASE": RimUniform.linePhase, "U_LINE_BLOOMS": RimUniform.lineBlooms,
            "U_SNAP_T": RimUniform.snapT, "U_LINE_LENGTH": RimUniform.lineLength, "U_LINE_FADE": RimUniform.lineFade,
            "U_PILL_X": RimUniform.pillX, "U_SIGMA": RimUniform.sigma, "U_HOVER": RimUniform.hover, "U_ICON": RimUniform.icon,
            "U_HOVER_GLOW": RimUniform.hoverGlow, "U_ICON_KIND": RimUniform.iconKind, "U_MELT": RimUniform.melt,
            "U_MELT_SIGMA": RimUniform.meltSigma, "U_BUBBLE": RimUniform.bubble,
            "U_PALETTE": RimUniform.palette, "U_COUNT": RimUniform.count,
        ]
        var defined: [String: Int] = [:]
        for line in RecordingPillShader.source.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 3, parts[0] == "#define", let value = Int(parts[2]) else { continue }
            defined[String(parts[1])] = value
        }
        XCTAssertEqual(defined, expected)
        XCTAssertEqual(RimUniform.blooms + RimUniform.maxBlooms * 4, RimUniform.width)
        XCTAssertEqual(RimUniform.lineBlooms + RimUniform.maxLineBlooms * 4, RimUniform.snapT)
        XCTAssertEqual(RimUniform.bubble + 4, RimUniform.palette)
        XCTAssertEqual(RimUniform.palette + 12, RimUniform.count)
    }

    // Red if a default drifts from Ali's approved 17:36 UTC tuning.
    func testDefaultsAreTheApprovedTuning() {
        let p = RimParameters.approved
        XCTAssertEqual(p.width, 1.2)
        XCTAssertEqual(p.widthGain, 0.95)
        XCTAssertEqual(p.reach, 2.6)
        XCTAssertEqual(p.intensity, 1.4)
        XCTAssertEqual(p.attack, 0.015)
        XCTAssertEqual(p.release, 0.24)
        XCTAssertEqual(p.downloadTime, 0.15)
        XCTAssertEqual(p.lineLength, 0.5)
        XCTAssertEqual(p.greenHold, 0.26)
        XCTAssertEqual(p.snapTime, 0.13)
        XCTAssertEqual(p.collapseTime, 0.34)
        XCTAssertEqual(p.idleFps, 31)
        XCTAssertEqual(RecordingPillSize.small.points, CGSize(width: 86, height: 20))
        XCTAssertEqual(RecordingPillSize.medium.points, CGSize(width: 120, height: 28))
        XCTAssertEqual(RecordingPillSize.large.points, CGSize(width: 156, height: 36))
    }

    private func uniforms(_ sim: RimSimulation, _ state: RimState, reduced: Bool = false) -> [Float] {
        sim.uniforms(state: state, stateTime: 0, displayScale: 2, reduced: reduced, dimAtRest: true)
    }

    // Red if the pill stops growing from a point over about 180 ms on key down.
    func testPillGrowsFromAPointOnKeyDown() {
        var sim = self.simulation(collapses: true)
        XCTAssertEqual(sim.visibility, 0)
        self.run(&sim, .listen, for: 0.09)
        XCTAssertGreaterThan(sim.visibility, 0.3)
        XCTAssertLessThan(sim.visibility, 0.8)
        self.run(&sim, .listen, for: 0.09)
        XCTAssertGreaterThan(sim.visibility, 0.9)
        self.run(&sim, .listen, for: 0.2)
        XCTAssertEqual(sim.visibility, 1, accuracy: 0.01)
    }

    // Red if the appear and collapse stop running on springs: a key press mid-collapse would restart from a point instead of growing back from where the pill is.
    func testKeyPressMidCollapseGrowsBackFromWhereThePillIs() {
        var sim = self.simulation(collapses: true)
        self.run(&sim, .listen, for: 0.4)
        self.run(&sim, .done, for: 0.4)
        let midway = sim.visibility
        XCTAssertGreaterThan(midway, 0.1)
        XCTAssertLessThan(midway, 0.9)
        sim.update(dt: 1 / 120, state: .listen, features: RimFeatures(), reduced: false, pill: self.medium)
        XCTAssertGreaterThan(sim.visibility, midway - 0.05)
        self.run(&sim, .listen, for: 0.4)
        XCTAssertEqual(sim.visibility, 1, accuracy: 0.01)
    }

    // Red if "Only while dictating" stops holding the green line for 260 ms before collapsing within 340 ms.
    func testWhileDictatingPillHoldsGreenThenCollapses() {
        var sim = self.simulation(collapses: true)
        self.run(&sim, .listen, for: 0.3)
        self.run(&sim, .think, for: 0.4)
        self.run(&sim, .done, for: 0.25)
        XCTAssertEqual(sim.visibility, 1, accuracy: 0.01)
        self.run(&sim, .done, for: 0.2)
        XCTAssertGreaterThan(sim.visibility, 0)
        XCTAssertLessThan(sim.visibility, 1)
        self.run(&sim, .done, for: 0.17)
        XCTAssertLessThan(sim.visibility, 0.15)
        self.run(&sim, .idle, for: 0.3)
        XCTAssertTrue(sim.isGone)
    }

    // Red if the collapse's last point stops melting through the blob, or the melt shows while the pill is still whole.
    func testCollapseMeltsOnlyItsLastPoint() {
        var sim = self.simulation(collapses: true)
        self.run(&sim, .listen, for: 0.3)
        XCTAssertEqual(self.uniforms(sim, .listen)[RimUniform.melt], 0)
        self.run(&sim, .done, for: 0.3)
        XCTAssertEqual(self.uniforms(sim, .done)[RimUniform.melt], 0)
        self.run(&sim, .done, for: 0.3)
        let late = self.uniforms(sim, .done)
        XCTAssertGreaterThan(late[RimUniform.melt], 0)
        XCTAssertGreaterThan(late[RimUniform.meltSigma], 0)
    }

    // Red if an always-shown pill disappears at any point of a dictation.
    func testAlwaysShownPillNeverLeaves() {
        var sim = self.simulation(collapses: false)
        for state in [RimState.idle, .listen, .think, .done, .idle] {
            self.run(&sim, state, for: 0.5)
            XCTAssertEqual(sim.visibility, 1, "\(state)")
        }
    }

    // Red if the paste stops switching the palette to mint in a single frame (a glide passes through grey).
    func testPasteTurnsPaletteMintAtOnce() {
        var sim = self.simulation(collapses: true)
        self.run(&sim, .think, for: 0.3)
        sim.update(dt: 1 / 60, state: .done, features: RimFeatures(), reduced: false, pill: self.medium)
        let u = self.uniforms(sim, .done)
        let mint = RimSimulation.labs(RimParameters.done)[0]
        XCTAssertEqual(u[RimUniform.palette], mint.x, accuracy: 1e-5)
        XCTAssertEqual(u[RimUniform.palette + 1], mint.y, accuracy: 1e-5)
        XCTAssertEqual(u[RimUniform.palette + 2], mint.z, accuracy: 1e-5)
        XCTAssertGreaterThanOrEqual(u[RimUniform.doneT], 0)
        XCTAssertEqual(u[RimUniform.thinkT], -1)
    }

    // Red if the collapse stops passing through a thin line on its way to a point.
    func testCollapseShapePassesThroughALine() {
        let full = RimSimulation.shape(size: self.medium, visibility: 1)
        XCTAssertEqual(full.width, 120)
        XCTAssertEqual(full.height, 28)
        let line = RimSimulation.shape(size: self.medium, visibility: 0.4)
        XCTAssertEqual(line.height, 1.2, accuracy: 1e-4)
        XCTAssertEqual(line.width, 1.2 + 92, accuracy: 1e-4)
        let gone = RimSimulation.shape(size: self.medium, visibility: 0)
        XCTAssertEqual(gone.fade, 0)
    }

    // Red if syllable onsets can come closer than 340 ms, which would break the WCAG 2.3.1 flash limit.
    func testOnsetsAreAtLeast340MillisecondsApart() {
        var extractor = RimFeatureExtractor(attack: 0.015, release: 0.24)
        let loud = [Float](repeating: 0.9, count: 8)
        let quiet = [Float](repeating: 0, count: 8)
        let dt: Float = 1 / 60
        var onsets: [Float] = []
        for frame in 0..<600 {
            // A new syllable every 100 ms, far faster than the refractory window.
            let raw = (frame / 3) % 2 == 0 ? loud : quiet
            if extractor.step(dt: dt, raw: raw).onset { onsets.append(Float(frame) * dt) }
        }
        XCTAssertGreaterThan(onsets.count, 5)
        for (earlier, later) in zip(onsets, onsets.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later - earlier, RimFeatureExtractor.onsetRefractory - dt)
        }
    }

    // Red if the speech gate drops during a short pause between words, which would make the rim flicker.
    func testSpeechGateHoldsThroughAShortPause() {
        var extractor = RimFeatureExtractor(attack: 0.015, release: 0.24)
        let dt: Float = 1 / 60
        for _ in 0..<30 { _ = extractor.step(dt: dt, raw: [Float](repeating: 0.7, count: 8)) }
        XCTAssertTrue(extractor.features.speaking)
        for _ in 0..<9 { _ = extractor.step(dt: dt, raw: [Float](repeating: 0, count: 8)) }
        XCTAssertTrue(extractor.features.speaking)
    }

    // Red if the band filters stop separating low and high sounds, so lows would no longer light the bottom of the rim.
    func testAnalyzerSeparatesLowAndHighSounds() {
        func bands(forTone frequency: Float) -> [Float] {
            let analyzer = RimAudioAnalyzer()
            analyzer.setActive(true)
            // One second of broadband noise first, so every band learns a loud reference as it would from speech.
            var seed: UInt32 = 1
            let noise = (0..<16000).map { _ -> Float in
                seed = seed &* 1_664_525 &+ 1_013_904_223
                return 0.3 * (Float(seed >> 8) / Float(1 << 24) * 2 - 1)
            }
            analyzer.ingest(noise)
            let tone = (0..<4800).map { 0.3 * sin(2 * Float.pi * frequency * Float($0) / RimAudioAnalyzer.sampleRate) }
            analyzer.ingest(tone)
            return analyzer.latestBands()
        }
        let low = bands(forTone: 120)
        XCTAssertGreaterThan(low[0], 0.6)
        XCTAssertLessThan(low[7], 0.2)
        let high = bands(forTone: 4500)
        XCTAssertGreaterThan(high[7], 0.6)
        XCTAssertLessThan(high[0], 0.2)
    }

    // Red if an inactive analyzer keeps publishing bands, which would cost capture-thread work while the pill is hidden.
    func testInactiveAnalyzerIgnoresAudio() {
        let analyzer = RimAudioAnalyzer()
        analyzer.ingest([Float](repeating: 0.5, count: 1600))
        XCTAssertEqual(analyzer.latestBands(), [Float](repeating: 0, count: 8))
    }

    // Red if a dictation stops walking the pill through listen, processing and the green paste, or a late finish restarts it.
    @MainActor
    func testControllerFollowsADictation() throws {
        let pill = RecordingPillController.shared
        guard pill.prepare() else { throw XCTSkip("No Metal device on this machine") }
        XCTAssertTrue(pill.beginListening())
        XCTAssertEqual(pill.stateForTests, .listen)
        pill.beginProcessing()
        XCTAssertEqual(pill.stateForTests, .think)
        pill.finish(pasted: true)
        XCTAssertEqual(pill.stateForTests, .done)
        pill.finish(pasted: false)
        XCTAssertEqual(pill.stateForTests, .done)
        pill.showMicrophoneLost()
        XCTAssertEqual(pill.stateForTests, .problem)
    }

    // Red if a failed paste stops waiting in the bubble through a failed retry, a retry stops turning it green, or a new dictation no longer clears it.
    @MainActor
    func testControllerHoldsAFailedPasteUntilARetryLands() throws {
        let pill = RecordingPillController.shared
        guard pill.prepare() else { throw XCTSkip("No Metal device on this machine") }
        XCTAssertTrue(pill.beginListening())
        pill.beginProcessing()
        pill.holdFailedPaste()
        XCTAssertEqual(pill.stateForTests, .flux)
        XCTAssertTrue(pill.isHoldingFailedPaste)
        pill.finish(pasted: false)
        XCTAssertEqual(pill.stateForTests, .flux)
        pill.retryPasteStarted()
        pill.retryPasteFailed()
        XCTAssertEqual(pill.stateForTests, .flux)
        XCTAssertTrue(pill.isHoldingFailedPaste)
        pill.retryPasteSucceeded()
        XCTAssertEqual(pill.stateForTests, .pasted)
        XCTAssertFalse(pill.isHoldingFailedPaste)

        pill.holdFailedPaste()
        XCTAssertTrue(pill.beginListening())
        XCTAssertFalse(pill.isHoldingFailedPaste)
        XCTAssertEqual(pill.stateForTests, .listen)
        pill.finish(pasted: false)
    }

    // Red if the overlay manager stops sending dictation to the pill, or a paste marked before the hide no longer turns it green.
    @MainActor
    func testOverlayManagerHandsDictationToThePill() throws {
        let pill = RecordingPillController.shared
        guard pill.prepare() else { throw XCTSkip("No Metal device on this machine") }
        let manager = NotchOverlayManager.shared
        defer { manager.hideImmediately() }

        manager.show(audioLevelPublisher: Empty<CGFloat, Never>().eraseToAnyPublisher(), mode: .dictation)
        XCTAssertTrue(manager.isRecordingPillPresented)
        XCTAssertEqual(pill.stateForTests, .listen)
        manager.freezeForStop()
        XCTAssertEqual(pill.stateForTests, .think)
        manager.markRecordingPasted()
        manager.hideImmediately()
        XCTAssertFalse(manager.isRecordingPillPresented)
        XCTAssertEqual(pill.stateForTests, .done)

        manager.show(audioLevelPublisher: Empty<CGFloat, Never>().eraseToAnyPublisher(), mode: .dictation)
        manager.hideImmediately()
        XCTAssertEqual(pill.stateForTests, .idle)
    }

    // Red if paste outcome events stop putting a failed dictation paste in the bubble, a retry's verdict stops reaching it, or a late verdict interrupts the next dictation.
    @MainActor
    func testPasteOutcomeEventsDriveTheBubble() throws {
        let pill = RecordingPillController.shared
        guard pill.prepare() else { throw XCTSkip("No Metal device on this machine") }
        let settings = SettingsStore.shared
        let savedHistory = settings.saveTranscriptionHistory
        defer { settings.saveTranscriptionHistory = savedHistory }
        settings.saveTranscriptionHistory = true
        func event(_ phase: PasteOutcomeEvent.Phase, _ outcome: PasteOutcome, retry: Bool = false) -> PasteOutcomeEvent {
            PasteOutcomeEvent(id: UUID(), transcript: "hello", isRetry: retry, phase: phase, outcome: outcome)
        }

        XCTAssertTrue(pill.beginListening())
        pill.handle(event(.final, .failed(.pasteNotLanded)))
        XCTAssertEqual(pill.stateForTests, .listen, "a late verdict leaves the next dictation alone")
        pill.beginProcessing()
        pill.finish(pasted: false)

        pill.handle(event(.final, .noFocusedTextField))
        XCTAssertEqual(pill.stateForTests, .flux)
        pill.handle(event(.dispatched, .unconfirmed, retry: true))
        pill.handle(event(.final, .failed(.pasteNotLanded), retry: true))
        XCTAssertEqual(pill.stateForTests, .flux)
        pill.handle(event(.final, .unconfirmed, retry: true))
        XCTAssertEqual(pill.stateForTests, .pasted)

        settings.saveTranscriptionHistory = false
        XCTAssertFalse(pill.takesFailedPastes, "without history the retry would paste the wrong text")
        pill.handle(event(.final, .noFocusedTextField))
        XCTAssertEqual(pill.stateForTests, .pasted)
    }

    // MARK: - Paste failed and island motion

    private func bubbleWidth(_ sim: RimSimulation) -> Float {
        self.uniforms(sim, .flux)[RimUniform.bubble + 1]
    }

    // Red if a paste that fails out of processing stops sending the line back to the rim before the bubble splits off the pill's right end.
    func testFailedPasteSendsTheLineBackThenSplitsOffABubble() {
        var sim = self.simulation(collapses: true)
        self.run(&sim, .listen, for: 0.3)
        self.run(&sim, .think, for: 0.4)
        self.run(&sim, .flux, for: 0.05)
        XCTAssertGreaterThan(self.uniforms(sim, .flux)[RimUniform.snapT], -100)
        XCTAssertEqual(self.bubbleWidth(sim), 0)
        self.run(&sim, .flux, for: 1.2)
        let u = self.uniforms(sim, .flux)
        XCTAssertTrue(sim.bubble.isWaiting)
        XCTAssertEqual(u[RimUniform.bubble + 1], 28, accuracy: 1)
        XCTAssertGreaterThan(u[RimUniform.bubble], 60 + 14)
        XCTAssertEqual(u[RimUniform.iconKind], 0)
        XCTAssertEqual(sim.visibility, 1, accuracy: 0.01, "the pill stays while a transcript waits")
    }

    // Red if the pill stops recoiling from the bubble it kicks out, or the recoil direction setting is ignored.
    func testPillRecoilFollowsTheRecoilDirection() {
        func largestRecoil(direction: Float) -> Float {
            var params = RimParameters.approved
            params.recoilDirection = direction
            var sim = RimSimulation(params: params, collapsesWhenDone: true, random: { 0.5 })
            self.run(&sim, .listen, for: 0.3)
            self.run(&sim, .idle, for: 0.3)
            var largest: Float = 0
            for _ in 0..<60 {
                self.run(&sim, .flux, for: 1 / 60)
                let x = self.uniforms(sim, .flux)[RimUniform.pillX]
                if abs(x) > abs(largest) { largest = x }
            }
            return largest
        }
        XCTAssertLessThan(largestRecoil(direction: 1), -0.5)
        XCTAssertGreaterThan(largestRecoil(direction: -1), 0.5)
        XCTAssertEqual(largestRecoil(direction: 0), 0)
    }

    // Red if a failed retry stops turning the pill soft orange or stops shaking the bubble once.
    func testFailedRetryFlashesOrangeAndShakes() {
        var sim = self.simulation(collapses: true)
        self.run(&sim, .idle, for: 0.1)
        self.run(&sim, .flux, for: 1.2)
        let restX = self.uniforms(sim, .flux)[RimUniform.bubble]
        sim.failRetry(reduced: false)
        var moved: Float = 0
        for _ in 0..<12 {
            self.run(&sim, .flux, for: 1 / 60)
            moved = max(moved, abs(self.uniforms(sim, .flux)[RimUniform.bubble] - restX))
        }
        XCTAssertGreaterThan(moved, 3)
        let orange = RimSimulation.labs(RimParameters.retryFailed)[0]
        XCTAssertEqual(self.uniforms(sim, .flux)[RimUniform.palette], orange.x, accuracy: 0.02)
        self.run(&sim, .flux, for: 2)
        let ivory = RimSimulation.labs(RimParameters.ivory)[0]
        XCTAssertEqual(self.uniforms(sim, .flux)[RimUniform.palette], ivory.x, accuracy: 0.02)
    }

    // Red if Reduce Motion stops dropping the shake while keeping the orange.
    func testReduceMotionKeepsTheOrangeButDropsTheShake() {
        var sim = self.simulation(collapses: true)
        self.run(&sim, .idle, for: 0.1)
        for _ in 0..<120 { sim.update(dt: 1 / 60, state: .flux, features: RimFeatures(), reduced: true, pill: self.medium) }
        let before = self.uniforms(sim, .flux, reduced: true)
        XCTAssertEqual(before[RimUniform.bubble + 3], 1, accuracy: 0.01, "the bubble fades in in place")
        sim.failRetry(reduced: true)
        for _ in 0..<6 { sim.update(dt: 1 / 60, state: .flux, features: RimFeatures(), reduced: true, pill: self.medium) }
        let after = self.uniforms(sim, .flux, reduced: true)
        XCTAssertEqual(after[RimUniform.bubble], before[RimUniform.bubble])
        let orange = RimSimulation.labs(RimParameters.retryFailed)[0]
        XCTAssertLessThan(abs(after[RimUniform.palette] - orange.x), abs(before[RimUniform.palette] - orange.x))
    }

    // Red if a retry that lands stops turning everything green at once and dissolving the bubble, or the pill no longer leaves afterwards.
    func testRetryThatLandsTurnsGreenAndDissolvesTheBubble() {
        var sim = self.simulation(collapses: true)
        self.run(&sim, .idle, for: 0.1)
        self.run(&sim, .flux, for: 1.2)
        sim.update(dt: 1 / 60, state: .pasted, features: RimFeatures(), reduced: false, pill: self.medium)
        let mint = RimSimulation.labs(RimParameters.done)[0]
        XCTAssertEqual(self.uniforms(sim, .pasted)[RimUniform.palette], mint.x, accuracy: 1e-5)
        self.run(&sim, .pasted, for: 1)
        XCTAssertFalse(sim.bubble.isActive)
        self.run(&sim, .idle, for: 0.3)
        XCTAssertTrue(sim.isGone)
    }

    // Red if a new dictation stops merging the waiting bubble back into the pill.
    func testNewDictationMergesTheBubbleBack() {
        var sim = self.simulation(collapses: true)
        self.run(&sim, .idle, for: 0.1)
        self.run(&sim, .flux, for: 1.2)
        XCTAssertGreaterThan(self.bubbleWidth(sim), 20)
        self.run(&sim, .listen, for: 0.6)
        XCTAssertFalse(sim.bubble.isActive)
        XCTAssertEqual(self.uniforms(sim, .listen)[RimUniform.bubble + 1], 0)
    }

    // Red if a lost mic stops splitting off a bubble that shows the crossed-out mic.
    func testLostMicShowsItsFixInABubble() {
        var sim = self.simulation(collapses: true)
        self.run(&sim, .listen, for: 0.3)
        self.run(&sim, .problem, for: 1.2)
        let u = self.uniforms(sim, .problem)
        XCTAssertTrue(sim.bubble.isWaiting)
        XCTAssertEqual(u[RimUniform.iconKind], 1)
        XCTAssertGreaterThan(u[RimUniform.icon], 0.6)
        self.run(&sim, .fixed, for: 1)
        XCTAssertFalse(sim.bubble.isActive)
    }

    // Red if hover or the shortcut's flash stop lighting the bubble and showing the send arrow.
    func testHoverAndShortcutShowTheSendArrow() {
        var sim = self.simulation(collapses: true)
        self.run(&sim, .idle, for: 0.1)
        self.run(&sim, .flux, for: 1.2)
        XCTAssertLessThan(self.uniforms(sim, .flux)[RimUniform.icon], 0.01)
        sim.setBubbleHover(true)
        self.run(&sim, .flux, for: 0.5)
        XCTAssertGreaterThan(self.uniforms(sim, .flux)[RimUniform.hover], 0.9)
        XCTAssertGreaterThan(self.uniforms(sim, .flux)[RimUniform.icon], 0.9)
        sim.setBubbleHover(false)
        self.run(&sim, .flux, for: 1)
        sim.pressBubble(showsFlash: true, reduced: false)
        self.run(&sim, .flux, for: 0.2)
        XCTAssertGreaterThan(self.uniforms(sim, .flux)[RimUniform.icon], 0.5)
        self.run(&sim, .flux, for: 1)
        XCTAssertLessThan(self.uniforms(sim, .flux)[RimUniform.icon], 0.05)
    }

    // Red if a press stops bumping the bubble by about the island's 1.015 by 1.03.
    func testPressBumpsTheBubble() {
        var sim = self.simulation(collapses: true)
        self.run(&sim, .idle, for: 0.1)
        self.run(&sim, .flux, for: 1.5)
        let rest = self.uniforms(sim, .flux)[RimUniform.bubble + 2]
        sim.pressBubble(showsFlash: false, reduced: false)
        var peak: Float = 0
        for _ in 0..<60 {
            self.run(&sim, .flux, for: 1 / 60)
            peak = max(peak, self.uniforms(sim, .flux)[RimUniform.bubble + 2])
        }
        XCTAssertEqual(peak / rest, 1.03, accuracy: 0.008)
    }

    // Red if the "can't hear you" nudge stops pulsing the light after two seconds of silence, or starts while the user is speaking.
    func testSilenceNudgesTheLightAfterTwoSeconds() {
        func exposureRise(speech: Float) -> Float {
            var sim = self.simulation(collapses: true)
            var features = RimFeatures()
            features.speech = speech
            self.run(&sim, .idle, for: 0.1)
            self.run(&sim, .listen, for: 1.95, features: features)
            let before = self.uniforms(sim, .listen)[RimUniform.exposure]
            self.run(&sim, .listen, for: 0.15, features: features)
            return self.uniforms(sim, .listen)[RimUniform.exposure] - before
        }
        XCTAssertGreaterThan(exposureRise(speech: 0), 0.15)
        XCTAssertLessThan(abs(exposureRise(speech: 1)), 0.05)
    }

    // Red if a new size setting jumps instead of gliding on the island's size spring.
    func testSizeSettingGlides() {
        var sim = self.simulation(collapses: false)
        self.run(&sim, .idle, for: 0.1)
        let large = RecordingPillSize.large.points
        sim.update(dt: 1 / 60, state: .idle, features: RimFeatures(), reduced: false, pill: large)
        XCTAssertLessThan(sim.size.width, 125)
        for _ in 0..<60 { sim.update(dt: 1 / 60, state: .idle, features: RimFeatures(), reduced: false, pill: large) }
        XCTAssertEqual(sim.size.width, large.width, accuracy: 1)
    }

    // Red if a spring timed to a duration stops settling close to that duration.
    func testTimedSpringSettlesInItsDuration() {
        var spring = RimSpring(RimSpring.size, at: 0)
        spring.time(to: 0.34, damping: 0.816)
        spring.target = 1
        for _ in 0..<Int(0.34 * 480) { spring.step(1 / 480) }
        XCTAssertGreaterThan(spring.x, 0.85)
        for _ in 0..<480 { spring.step(1 / 480) }
        XCTAssertEqual(spring.x, 1, accuracy: 0.005)
    }
}
