@testable import FluidVoice_Debug
import Combine
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
            "U_MODE": RimUniform.mode, "U_HOLD": RimUniform.hold, "U_LINE_LENGTH": RimUniform.lineLength,
            "U_LINE_FADE": RimUniform.lineFade, "U_PALETTE": RimUniform.palette, "U_COUNT": RimUniform.count,
        ]
        var defined: [String: Int] = [:]
        for line in RecordingPillShader.source.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 3, parts[0] == "#define", let value = Int(parts[2]) else { continue }
            defined[String(parts[1])] = value
        }
        XCTAssertEqual(defined, expected)
        XCTAssertEqual(RimUniform.blooms + RimUniform.maxBlooms * 4, RimUniform.width)
        XCTAssertEqual(RimUniform.lineBlooms + RimUniform.maxLineBlooms * 4, RimUniform.mode)
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

    // Red if the pill stops growing from a point over 180 ms on key down.
    func testPillGrowsFromAPointOnKeyDown() {
        var sim = self.simulation(collapses: true)
        XCTAssertEqual(sim.visibility, 0)
        self.run(&sim, .listen, for: 0.09)
        XCTAssertGreaterThan(sim.visibility, 0.3)
        XCTAssertLessThan(sim.visibility, 0.7)
        self.run(&sim, .listen, for: 0.1)
        XCTAssertEqual(sim.visibility, 1)
    }

    // Red if "Only while dictating" stops holding the green line for 260 ms before collapsing within 340 ms.
    func testWhileDictatingPillHoldsGreenThenCollapses() {
        var sim = self.simulation(collapses: true)
        self.run(&sim, .listen, for: 0.3)
        self.run(&sim, .think, for: 0.4)
        self.run(&sim, .done, for: 0.25)
        XCTAssertEqual(sim.visibility, 1)
        self.run(&sim, .done, for: 0.2)
        XCTAssertGreaterThan(sim.visibility, 0)
        XCTAssertLessThan(sim.visibility, 1)
        self.run(&sim, .done, for: 0.17)
        XCTAssertEqual(sim.visibility, 0)
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
        let u = sim.uniforms(state: .done, stateTime: 0, pill: self.medium, displayScale: 2, reduced: false, dimAtRest: true)
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
}
