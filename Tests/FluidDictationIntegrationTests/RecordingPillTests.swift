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
            "U_PALETTE": RimUniform.palette, "U_MELT_FADE": RimUniform.meltFade, "U_WAVE_AMOUNT": RimUniform.waveAmount,
            "U_WAVE_OPACITY": RimUniform.waveOpacity, "U_WAVE_HEIGHT": RimUniform.waveHeight, "U_WAVE": RimUniform.wave,
            "U_COUNT": RimUniform.count,
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
        XCTAssertEqual(RimUniform.palette + 12, RimUniform.meltFade)
        XCTAssertEqual(RimUniform.meltFade + 1, RimUniform.waveAmount)
        XCTAssertEqual(RimUniform.wave + RimWaveform.sampleCount, RimUniform.count)
        XCTAssertTrue(RecordingPillShader.source.contains("constant int WAVE_SAMPLES = \(RimWaveform.sampleCount);"))
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
        XCTAssertTrue(p.fluidCollapse)
        XCTAssertEqual(p.fluidSwell, 1.08)
        XCTAssertEqual(p.swellTime, 0.09)
        XCTAssertEqual(p.fluidLead, 0.08)
        XCTAssertEqual(p.fluidFadeDelay, 0.12)
        XCTAssertEqual(p.waveGain, 1.3)
        XCTAssertEqual(p.waveHeight, 0.85)
        XCTAssertEqual(p.waveSpan, 1.5)
        XCTAssertEqual(p.waveOpacity, 0.95)
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

    /// Uniforms for each 120 Hz frame of a collapse after a paste.
    private func collapseFrames(_ sim: inout RimSimulation, for duration: Float, reduced: Bool = false) -> [[Float]] {
        var frames: [[Float]] = []
        for _ in 0..<Int((duration * 120).rounded()) {
            sim.update(dt: 1 / 120, state: .done, features: RimFeatures(), reduced: reduced, pill: self.medium)
            frames.append(sim.uniforms(state: .done, stateTime: 0, displayScale: 2, reduced: reduced, dimAtRest: true))
        }
        return frames
    }

    // Red if the fluid collapse loses its 1.08 swell, stops closing the height ahead of the width, stops on a thin line, or outlasts the approved 340 ms.
    func testFluidCollapseSwellsThenClosesHeightFirst() {
        var sim = self.simulation(collapses: true)
        self.run(&sim, .listen, for: 0.4)
        let frames = self.collapseFrames(&sim, for: 0.8)
        let widths = frames.map { $0[RimUniform.pillW] }
        let peak = widths.max() ?? 0
        XCTAssertGreaterThan(peak, 128, "the swell reaches about 1.08 of 120 pt")
        XCTAssertLessThan(peak, 132)
        let halfHeight = frames.first { $0[RimUniform.pillH] < 14 }
        XCTAssertGreaterThan(halfHeight?[RimUniform.pillW] ?? 0, 110, "the width is still whole when the height is half closed")
        for frame in frames where frame[RimUniform.pillW] > 60 {
            XCTAssertGreaterThan(frame[RimUniform.pillH], 4, "the pill never stops on a line")
        }
        XCTAssertTrue(frames.contains { $0[RimUniform.meltFade] == RimFluidCollapse.meltFade && $0[RimUniform.melt] > 0.5 })
        XCTAssertEqual(frames.last?[RimUniform.fade] ?? 1, 0, accuracy: 0.01)
        self.run(&sim, .idle, for: 0.3)
        XCTAssertTrue(sim.isGone)
    }

    // Red if a key press mid fluid collapse stops growing both axes back from where they are, or the pill does not come back whole.
    func testKeyPressMidFluidCollapseGrowsBothAxesBack() {
        var sim = self.simulation(collapses: true)
        self.run(&sim, .listen, for: 0.4)
        let midway = self.collapseFrames(&sim, for: 0.41).last ?? []
        XCTAssertLessThan(midway[RimUniform.pillH], 20)
        XCTAssertGreaterThan(midway[RimUniform.pillW], 100)
        self.run(&sim, .listen, for: 0.1)
        let growing = self.uniforms(sim, .listen)
        XCTAssertGreaterThan(growing[RimUniform.pillH], midway[RimUniform.pillH] + 3)
        XCTAssertGreaterThan(growing[RimUniform.pillW], 100)
        self.run(&sim, .listen, for: 0.4)
        let whole = self.uniforms(sim, .listen)
        XCTAssertEqual(whole[RimUniform.pillW], 120, accuracy: 0.5)
        XCTAssertEqual(whole[RimUniform.pillH], 28, accuracy: 0.5)
        XCTAssertEqual(whole[RimUniform.fade], 1)
        XCTAssertEqual(whole[RimUniform.meltFade], 1)
    }

    // Red if turning the fluid collapse off, or Reduce Motion, stops giving the line-then-point collapse.
    func testLineThenPointCollapseStaysAsTheAlternative() {
        var params = RimParameters.approved
        params.fluidCollapse = false
        var sim = RimSimulation(params: params, collapsesWhenDone: true, random: { 0.5 })
        self.run(&sim, .listen, for: 0.4)
        for frame in self.collapseFrames(&sim, for: 0.6) {
            XCTAssertLessThanOrEqual(frame[RimUniform.pillW], 120.01, "no swell")
            XCTAssertEqual(frame[RimUniform.meltFade], 1)
        }
        var reduced = self.simulation(collapses: true)
        self.run(&reduced, .listen, for: 0.4)
        for frame in self.collapseFrames(&reduced, for: 0.6, reduced: true) {
            XCTAssertLessThanOrEqual(frame[RimUniform.pillW], 120.01, "no swell")
            XCTAssertEqual(frame[RimUniform.meltFade], 1)
        }
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

    // Red if the rim's layer keeps a contentsScale of 0 from being made at zero size, which drew the pill at zero size on Ali's Mac.
    @MainActor
    func testControllerDrawsAtTheWindowScale() throws {
        let pill = RecordingPillController.shared
        guard pill.prepare() else { throw XCTSkip("No Metal device on this machine") }
        let scale = try XCTUnwrap(pill.layerScaleForTests)
        XCTAssertGreaterThan(scale.layer, 0)
        XCTAssertEqual(scale.layer, scale.window)
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

    // Red if a revoked permission stops splitting off a bubble with the lock, or the bubble keeps the lock once the problem is the lost mic.
    func testRevokedPermissionShowsALockInTheBubble() {
        var sim = self.simulation(collapses: true)
        sim.problem = .lock
        self.run(&sim, .listen, for: 0.3)
        self.run(&sim, .problem, for: 1.2)
        let u = self.uniforms(sim, .problem)
        XCTAssertTrue(sim.bubble.isWaiting)
        XCTAssertEqual(u[RimUniform.iconKind], 2)
        XCTAssertGreaterThan(u[RimUniform.icon], 0.6)
        sim.problem = .microphone
        self.run(&sim, .problem, for: 0.1)
        XCTAssertEqual(self.uniforms(sim, .problem)[RimUniform.iconKind], 1)
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

    /// A 1440 by 900 screen with an 80 pt Dock and the menu bar.
    private let visible = CGRect(x: 0, y: 80, width: 1440, height: 795)

    private func dockSpots() -> [RecordingPillDock: CGPoint] {
        RimDrag.spots(visible: self.visible, screenMidX: 720, pill: self.medium, bottomOffset: 50)
    }

    // Red if a dock spot moves off its edge inset, the bottom spots stop keeping the overlay's offset above the Dock, or the bubble stops splitting left on the right.
    func testDockSpotsSitAlongTheEdges() {
        let spots = self.dockSpots()
        XCTAssertEqual(spots[.topLeft], CGPoint(x: 72, y: 849))
        XCTAssertEqual(spots[.top], CGPoint(x: 720, y: 849))
        XCTAssertEqual(spots[.topRight], CGPoint(x: 1368, y: 849))
        XCTAssertEqual(spots[.bottomLeft], CGPoint(x: 72, y: 144))
        XCTAssertEqual(spots[.bottom], CGPoint(x: 720, y: 144))
        XCTAssertEqual(spots[.bottomRight], CGPoint(x: 1368, y: 144))
        XCTAssertEqual(RecordingPillDock.topRight.bubbleSide, -1)
        XCTAssertEqual(RecordingPillDock.bottomRight.bubbleSide, -1)
        XCTAssertEqual(RecordingPillDock.bottom.bubbleSide, 1)
    }

    // Red if a release stops projecting the flick 0.3 s ahead to pick its spot, or the pill stops settling on it.
    func testReleasePicksTheSpotAFlickWouldReach() {
        let spots = self.dockSpots()
        func released(velocity: CGVector) -> (RecordingPillDock, RimDrag) {
            var drag = RimDrag()
            drag.place(at: spots[.bottom] ?? .zero)
            drag.begin(pointer: CGPoint(x: 720, y: 144))
            let dock = drag.release(velocity: velocity, spots: spots, pillHeight: 28, reduced: false)
            return (dock, drag)
        }
        XCTAssertEqual(released(velocity: .zero).0, .bottom)
        XCTAssertEqual(released(velocity: CGVector(dx: 2000, dy: 0)).0, .bottomRight)
        XCTAssertEqual(released(velocity: CGVector(dx: 0, dy: 2000)).0, .top)
        let flick = released(velocity: CGVector(dx: -2000, dy: 2000))
        let dock = flick.0
        var drag = flick.1
        XCTAssertEqual(dock, .topLeft)
        for _ in 0..<120 { drag.step(dt: 1 / 60, rest: spots[dock] ?? .zero, reduced: false) }
        XCTAssertEqual(drag.centre.x, 72, accuracy: 0.5)
        XCTAssertEqual(drag.centre.y, 849, accuracy: 0.5)
        XCTAssertFalse(drag.isMoving)
    }

    // Red if dragging past the outer spots stops resisting, or the pill can be pulled further than the band.
    func testDragIsRubberBandedPastTheOuterSpots() {
        XCTAssertEqual(RimDrag.banded(700, 72, 1368), 700)
        let pulled: Float = 100 * RimDrag.rubberBand / RimDrag.bandReach
        let expected: Float = 1368 + RimDrag.bandReach * (1 - 1 / (pulled + 1))
        XCTAssertEqual(RimDrag.banded(1468, 72, 1368), expected, accuracy: 1e-3)
        XCTAssertLessThan(RimDrag.banded(5000, 72, 1368), 1368 + 60)
        XCTAssertGreaterThan(RimDrag.banded(-5000, 72, 1368), 72 - 60)
        var drag = RimDrag()
        let spots = self.dockSpots()
        drag.place(at: spots[.bottom] ?? .zero)
        drag.begin(pointer: CGPoint(x: 720, y: 144))
        drag.move(pointer: CGPoint(x: 2400, y: 144), spots: spots)
        for _ in 0..<120 { drag.step(dt: 1 / 60, rest: spots[.bottom] ?? .zero, reduced: false) }
        XCTAssertGreaterThan(drag.centre.x, 1368)
        XCTAssertLessThan(drag.centre.x, 1368 + 60)
    }

    // Red if a fling stops stretching the pill along its travel, the side bounce passes its cap, or Reduce Motion keeps any stretch or glide.
    func testFlingStretchesWithinTheCapAndReduceMotionJumps() {
        let spots = self.dockSpots()
        var drag = RimDrag()
        drag.place(at: spots[.bottom] ?? .zero)
        drag.begin(pointer: CGPoint(x: 720, y: 144))
        let dock = drag.release(velocity: CGVector(dx: 3000, dy: 0), spots: spots, pillHeight: 28, reduced: false)
        var widest: Float = 1
        for _ in 0..<90 {
            drag.step(dt: 1 / 60, rest: spots[dock] ?? .zero, reduced: false)
            widest = max(widest, drag.stretch(pill: self.medium, reduced: false).x)
        }
        let bounce = RimDrag.bounceCap * 28 / RimSpring.islandHeight / 120
        XCTAssertGreaterThan(widest, 1.03)
        XCTAssertLessThanOrEqual(widest, 1 + RimDrag.stretch + bounce + 0.001)

        var still = RimDrag()
        still.place(at: spots[.bottom] ?? .zero)
        still.begin(pointer: CGPoint(x: 720, y: 144))
        let reducedDock = still.release(velocity: CGVector(dx: 3000, dy: 0), spots: spots, pillHeight: 28, reduced: true)
        still.step(dt: 1 / 60, rest: spots[reducedDock] ?? .zero, reduced: true)
        XCTAssertEqual(still.centre, spots[reducedDock])
        XCTAssertEqual(still.stretch(pill: self.medium, reduced: true), SIMD2(1, 1))
        XCTAssertFalse(still.isMoving)
    }

    private func stepWave(_ wave: inout RimWaveform, level: Float, shows: Bool = true, reduced: Bool = false, for duration: Float) {
        var features = RimFeatures()
        features.level = level
        for _ in 0..<Int(duration * 120) {
            wave.update(dt: 1 / 120, shows: shows, features: features, reduced: reduced, params: .approved)
        }
    }

    // Red if the waveform stops putting the newest sound at the centre and carrying older sound out towards the ends.
    func testWaveformCarriesSoundOutFromTheCentre() {
        var wave = RimWaveform()
        self.stepWave(&wave, level: 1, for: 0.1)
        self.stepWave(&wave, level: 0, for: 0.5)
        let loudest = wave.history.indices.max { wave.history[$0] < wave.history[$1] } ?? 0
        let travelled = Int(0.5 / RimParameters.approved.waveSpan * Float(RimWaveform.sampleCount))
        XCTAssertLessThan(wave.history[0], 0.05)
        XCTAssertGreaterThan(wave.history[loudest], 0.5)
        XCTAssertGreaterThan(loudest, travelled - 6)
        XCTAssertLessThan(loudest, travelled + 6)
    }

    // Red if Reduce Motion lets the waveform travel instead of the whole shape following the level.
    func testReduceMotionWaveformFollowsTheLevelEverywhere() {
        var wave = RimWaveform()
        self.stepWave(&wave, level: 1, reduced: true, for: 0.3)
        let level = wave.history[0]
        XCTAssertGreaterThan(level, 0.5)
        XCTAssertTrue(wave.history.allSatisfy { $0 == level })
    }

    // Red if the waveform stops showing while listening, or stops flattening and fading once the key is released.
    func testWaveformShowsWhileListeningAndFlattensOnRelease() {
        var sim = self.simulation(collapses: true)
        var loud = RimFeatures()
        loud.level = 0.8
        self.run(&sim, .listen, for: 0.5, features: loud)
        let listening = self.uniforms(sim, .listen)
        XCTAssertGreaterThan(listening[RimUniform.waveOpacity], 0.9)
        XCTAssertGreaterThan(listening[RimUniform.waveAmount], 0.9)
        XCTAssertGreaterThan(listening[RimUniform.wave], 0.5)
        self.run(&sim, .think, for: 0.3)
        let thinking = self.uniforms(sim, .think)
        XCTAssertLessThan(thinking[RimUniform.waveAmount], 0.01)
        XCTAssertLessThan(thinking[RimUniform.waveOpacity], 0.05)
    }

    private func liveWords() -> RimWords {
        RimWords(measure: { text, size in CGFloat(text.count) * size * 0.5 })
    }

    private func stepWords(_ words: inout RimWords, for duration: Float, reduced: Bool = false) {
        for _ in 0..<Int(duration * 120) {
            words.step(dt: 1 / 120, reduced: reduced)
        }
    }

    // Red if new words stop arriving light, the next preview stops confirming them, or a revision stops replacing the word in place.
    func testLiveWordsArriveLightThenFirmUp() {
        var words = self.liveWords()
        words.hear("send the", reduced: false)
        self.stepWords(&words, for: 1)
        let light = words.looks(thinking: false, inner: 300, reduced: false)
        XCTAssertEqual(light.map(\.text), ["send", "the"])
        XCTAssertEqual(light[0].opacity, RimWords.tentative, accuracy: 0.05)

        words.hear("send the report", reduced: false)
        self.stepWords(&words, for: 1)
        let firm = words.looks(thinking: false, inner: 300, reduced: false)
        XCTAssertEqual(firm[0].opacity, RimWords.settled, accuracy: 0.05)
        XCTAssertEqual(firm[2].opacity, RimWords.tentative, accuracy: 0.05)

        words.hear("sent the report", reduced: false)
        XCTAssertEqual(words.text, "sent the report")
        XCTAssertEqual(words.looks(thinking: false, inner: 300, reduced: false).first?.id, firm.first?.id)
    }

    // Red if the pill stops keeping its own width for a few words, stops growing to fit more, or grows past the maximum instead of scrolling.
    func testLiveWordsGrowThePillThenScroll() {
        var words = self.liveWords()
        let base = CGSize(width: 64, height: 28)
        words.setPill(height: base.height)
        XCTAssertEqual(words.pillSize(base: base), base)
        words.hear("hi", reduced: true)
        XCTAssertEqual(words.pillSize(base: base).width, base.width)
        words.hear("hi there this is a longer line", reduced: true)
        let grown = words.pillSize(base: base).width
        XCTAssertGreaterThan(grown, base.width)
        XCTAssertLessThan(grown, RimWords.maxWidth)
        words.hear(String(repeating: "and more words ", count: 12), reduced: true)
        self.stepWords(&words, for: 0.1, reduced: true)
        XCTAssertEqual(words.pillSize(base: base).width, RimWords.maxWidth, accuracy: 0.5)
        XCTAssertGreaterThan(words.scrollOffset, 0)
    }

    // Red if the word diff stops dropping a corrected run as one block or stops keeping the words both texts share.
    func testWordDiffDropsTheCorrectedRun() {
        let heard = "four and five no actually five and six".split(separator: " ").map(String.init)
        let ops = RimWords.diff(heard, ["Five", "and", "six."])
        XCTAssertEqual(ops, [.drop(0), .drop(1), .drop(2), .drop(3), .drop(4), .keep(5, 0), .keep(6, 1), .keep(7, 2)])
        XCTAssertEqual(RimWords.diff(["hello"], ["hello", "there"]), [.keep(0, 0), .insert(1)])
    }

    // Red if cleaned text stops replacing the words, or dropped words never fade out and leave.
    func testCleanUpSettlesTheCleanedText() {
        var words = self.liveWords()
        words.hear("um so lets meet at four", reduced: false)
        self.stepWords(&words, for: 0.5)
        words.release()
        words.cleanUp("Let's meet at four.", reduced: false)
        XCTAssertEqual(words.text, "Let's meet at four.")
        self.stepWords(&words, for: 2)
        XCTAssertEqual(words.looks(thinking: false, inner: 300, reduced: false).map(\.text), ["Let's", "meet", "at", "four."])
        words.dropAll()
        XCTAssertFalse(words.hasWords)
        self.stepWords(&words, for: 2)
        XCTAssertTrue(words.isEmpty)
    }

    // Red if words in the pill stop dimming while the AI works, or the light stops reading through them.
    func testThinkingDimsTheWordsAndReadsThrough() {
        var words = self.liveWords()
        let heard = String(repeating: "word ", count: 10)
        words.hear(heard, reduced: false)
        words.hear(heard, reduced: false)
        self.stepWords(&words, for: 1)
        words.release()
        var lowest: Float = 1, highest: Float = 0
        for _ in 0..<240 {
            words.step(dt: 1 / 120, reduced: false)
            let opacity = words.looks(thinking: true, inner: 300, reduced: false)[4].opacity
            lowest = min(lowest, opacity)
            highest = max(highest, opacity)
        }
        XCTAssertLessThan(lowest, RimWords.settled * RimWords.thinkWords + 0.05)
        XCTAssertGreaterThan(highest, RimWords.settled * 0.9)
    }

    // Red if live words in the pill stop hiding the waveform, the centre line stops giving way to them, or the rim dims as far as it does without words.
    func testWordsInThePillReplaceTheWaveformAndLine() {
        var sim = self.simulation(collapses: true)
        sim.liveWordsInPill = true
        sim.wordsShown = true
        var loud = RimFeatures()
        loud.level = 0.8
        self.run(&sim, .listen, for: 0.5, features: loud)
        XCTAssertLessThan(self.uniforms(sim, .listen)[RimUniform.waveOpacity], 0.01)
        self.run(&sim, .think, for: 1)
        let thinking = self.uniforms(sim, .think)
        XCTAssertEqual(thinking[RimUniform.coreOn], 0)
        XCTAssertEqual(thinking[RimUniform.dimRim], RimSimulation.wordsRimDim, accuracy: 0.03)
    }
}
