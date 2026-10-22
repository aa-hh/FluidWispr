import CoreGraphics
import Foundation

/// What the pill is doing. `idle` is the resting ring when the pill is always
/// shown, and nothing at all when it only shows while dictating.
nonisolated enum RimState: Equatable {
    case idle
    case listen
    case think
    case done
    /// The microphone stopped; its fix waits in a bubble.
    case problem
    /// A paste failed; the transcript waits in a bubble for a retry.
    case flux
    /// A retried paste landed: everything turns green and the bubble dissolves.
    case pasted
    /// The microphone's fix was taken: the bubble dissolves and the pill goes back to ivory.
    case fixed
}

/// Offsets into the float array the Metal shader reads. Keep in step with the
/// `#define`s at the top of the source in `RecordingPillShader.swift`.
nonisolated enum RimUniform {
    static let pillW = 0, pillH = 1, fullW = 2, fade = 3, scale = 4
    static let phase = 5, wobble = 8, contrast = 9, exposure = 10, hue = 11
    static let hueShift = 12, hueCycles = 13, tilt = 14, lowS = 15, highS = 16, tiltS = 17, bandLift = 18
    static let bands = 19, bloomCount = 27, blooms = 28
    static let width = 52, widthGain = 53, glow = 54, reach = 55, dimRim = 56, strength = 57, restEase = 58
    static let coreOn = 59, doneT = 60, thinkT = 61, reduced = 62, downloadTime = 63, snapTime = 64
    static let lineWidth = 65, innerGlow = 66, breath = 67, pulseDepth = 68
    static let linePhase = 69, lineBlooms = 72
    static let snapT = 88, lineLength = 89, lineFade = 90
    static let pillX = 91, sigma = 92, hover = 93, icon = 94, hoverGlow = 95, iconKind = 96, melt = 97, meltSigma = 98
    static let bubble = 99, palette = 103, meltFade = 115
    static let waveAmount = 116, waveOpacity = 117, waveHeight = 118, wave = 119
    /// The bubble's centre below the pill's (negative is above), its corner cap and how bright its ring is.
    static let bubbleY = RimUniform.wave + RimWaveform.sampleCount, bubbleRadius = RimUniform.bubbleY + 1, bubbleLight = RimUniform.bubbleY + 2
    static let count = RimUniform.bubbleLight + 1

    static let maxBlooms = 6
    static let maxLineBlooms = 4
}

/// The rim's CPU state, about forty floats, stepped once per frame. Port of
/// `create()` in the prototype's `rim.js`; the shader does the drawing.
nonisolated struct RimSimulation {
    private struct Bloom {
        var s: Float
        var age: Float
        var amp: Float
    }

    private struct LineBloom {
        var x: Float
        var age: Float
        var amp: Float
    }

    private static let layerSpeeds: [Float] = [1.0, -0.63, 0.37]
    private static let listenLab = RimSimulation.labs(RimParameters.ivory)
    private static let thinkLab = RimSimulation.listenLab.map { SIMD3<Float>($0.x + 0.06, $0.y * 0.9, $0.z * 0.9) }
    private static let doneLab = RimSimulation.labs(RimParameters.done)
    private static let problemLab = RimSimulation.labs(RimParameters.problem)
    private static let retryFailedLab = RimSimulation.labs(RimParameters.retryFailed)

    var params: RimParameters
    /// True when the pill only shows while dictating.
    var collapsesWhenDone: Bool

    private var random: () -> Float
    private var phases: [Float] = [0.13, 0.71, 0.42]
    private var wobble: Float = 0
    private var hue: Float = 0
    private var exposure: Float = 0.3
    private var contrast: Float = 0.2
    private var tiltS: Float = 0
    private var lowS: Float = 0
    private var highS: Float = 0
    private var ringPhase: Float = 0
    private var coreOn: Float = 0
    private var restEase: Float = 0
    private var dimRim: Float = 1
    private var bandEnvelope = [Float](repeating: 0, count: RimFeatures.bandCount)
    private var blooms: [Bloom] = []
    private var lineBlooms: [LineBloom] = []
    private var lineBloomUniforms = [Float](repeating: 0, count: RimUniform.maxLineBlooms * 4)
    private var bloomUniforms = [Float](repeating: 0, count: RimUniform.maxBlooms * 4)
    private var linePhases: [Float] = [0.2, 0.6, 0.9]
    private var breath: Float = 0
    private var nextLineBloom: Float = 0
    private var lastLineBloomX: Float = 0
    private var thinkClock: Float = 0
    private(set) var doneClock: Float = 0
    /// 1 is the full pill, 0.4 a thin line, 0 a point and gone.
    var visibility: Float { rimClamp(self.visibilitySpring.x, 0, 1) }
    private var visibilitySpring: RimSpring
    private var isCollapsing = false
    private var meltAmount: Float = 0
    private var fluid = RimFluidCollapse()
    private var snapSpring = RimSpring((1, 0.12), at: 0)
    private var isSnapping = false
    private var width = RimSpring(RimSpring.size, at: 0)
    private var height = RimSpring(RimSpring.size, at: 0)
    private var isSized = false
    private var quietTime: Float = 0
    private var nextNudge: Float = 0
    private var nudgeTime: Float = 9
    /// Time since the bubble state began, for the line's way back to the rim.
    private var bubbleClock: Float = 0
    private var palette: [SIMD3<Float>] = RimSimulation.listenLab
    private var previousState: RimState = .idle
    private(set) var bubble = RimBubble()
    private(set) var waveform = RimWaveform()
    private(set) var wordsBubble = RimWordsBubble()
    /// A failed paste waits for the words' bubble to go back into the pill before its own bubble splits off.
    private var fluxWaits = false

    init(params: RimParameters = .approved, collapsesWhenDone: Bool, random: @escaping () -> Float = { Float.random(in: 0..<1) }) {
        self.params = params
        self.collapsesWhenDone = collapsesWhenDone
        self.random = random
        self.visibilitySpring = RimSpring((1, RimParameters.appearTime), at: collapsesWhenDone ? 0 : 1)
        self.nextNudge = params.noSpeechAfter
    }

    /// The pill's size this frame; a new size setting glides on the island's size spring.
    var size: CGSize { CGSize(width: CGFloat(self.width.x), height: CGFloat(self.height.x)) }

    /// True once a pill shown only while dictating has fully collapsed.
    var isGone: Bool {
        self.collapsesWhenDone && self.visibilitySpring.x < 0.005 && abs(self.visibilitySpring.v) < 0.05 && !self.bubble.isActive
            && !self.wordsBubble.isActive
            && (!self.fluid.isOn || self.fluid.hasFaded)
    }

    mutating func setBubbleHover(_ on: Bool) { self.bubble.setHover(on) }

    /// What the amber pill's bubble holds: the lost mic's fix, or a lock for a revoked permission.
    var problem: RimBubble.Kind = .microphone

    /// Live words go in the pill, so it shows no waveform while listening.
    var liveWordsInPill = false
    /// Words are in the pill: they take the processing light, so there is no centre line,
    /// and the rim only dims to `wordsRimDim` while the AI works and stays lit while green.
    var wordsShown = false
    static let wordsRimDim: Float = 0.6
    /// The size the live words need in their bubble above the pill, or nil when it should go back into the pill.
    var wordsAbove: CGSize?
    /// Docked at the top of the screen, the words' bubble splits off below the pill.
    var wordsBelow = false
    /// The gap between the pill and the words' bubble, in points.
    var wordsGap: Float = RimWordsBubble.gap

    /// The state the rim shows: a failed paste looks like processing until the words' bubble is back in the pill.
    func shownState(_ state: RimState) -> RimState {
        self.fluxWaits && state == .flux ? .think : state
    }

    mutating func pressBubble(showsFlash: Bool, reduced: Bool) {
        self.bubble.press(params: self.params, showsFlash: showsFlash, reduced: reduced)
    }

    mutating func failRetry(reduced: Bool) {
        self.bubble.fail(params: self.params, reduced: reduced)
    }

    mutating func update(dt: Float, state given: RimState, features f: RimFeatures, reduced: Bool, pill: CGSize) {
        let p = self.params
        let previous = self.previousState
        self.updateSize(dt: dt, pill: pill, reduced: reduced)
        self.wordsBubble.update(
            dt: dt,
            target: self.wordsAbove,
            listening: given == .listen,
            pillHeight: self.height.x,
            gap: self.wordsGap,
            below: self.wordsBelow,
            reduced: reduced
        )
        // Only a failure straight out of processing waits; after a green paste the waiting bubble starts at once.
        if given == .flux, previous == .think, self.wordsBubble.isActive { self.fluxWaits = true }
        if !self.wordsBubble.isActive { self.fluxWaits = false }
        let state = self.shownState(given)
        let sized = self.size
        let listening = state == .listen
        let talking: Float = listening ? f.speech : 0
        let level: Float = listening ? f.level : 0
        let idleActivity = rimClamp(p.idleActivity, 0, 1)

        self.bubble.update(dt: dt, state: state, previous: previous, params: p, reduced: reduced, problem: self.problem)
        self.bubbleClock = state == previous ? self.bubbleClock + dt : 0
        self.updateNudge(dt: dt, state: state, speech: f.speech)

        // Palette: ease each OKLab value toward the state's set. On paste it turns
        // mint at once, because an OKLab glide from warm to green passes through grey.
        // A failed retry glides to soft orange quickly and back slowly (both warm, so the glide stays clean).
        let failing = self.bubble.failTime > 0
        let want: [SIMD3<Float>]
        switch state {
        case .done, .pasted: want = Self.doneLab
        case .problem: want = Self.problemLab
        case .think: want = Self.thinkLab
        case .flux: want = failing ? Self.retryFailedLab : Self.listenLab
        case .idle, .listen, .fixed: want = Self.listenLab
        }
        let colourStep: Float
        if (state == .done || state == .pasted) && previous != state {
            colourStep = 1
        } else if state == .flux {
            colourStep = rimEase(dt, failing ? 0.06 : 0.22)
        } else {
            colourStep = rimEase(dt, 0.28)
        }
        self.previousState = state
        for index in 0..<4 {
            self.palette[index] += (want[index] - self.palette[index]) * colourStep
        }

        // Light and band contrast. Fast up, slow down, never dark.
        let expMax = p.expMax * p.intensity
        let exposureTarget: Float
        let contrastTarget: Float
        switch state {
        case .idle:
            exposureTarget = p.expMin * rimLerp(0.75, 1, idleActivity)
            contrastTarget = p.visIdle * 0.7 * rimLerp(0.5, 1, idleActivity)
        case .listen:
            exposureTarget = rimLerp(rimLerp(p.expMin, expMax, 0.25), expMax, pow(level, 0.75))
            contrastTarget = rimLerp(p.visIdle, p.visMax, talking) + 0.1 * level
        case .think:
            exposureTarget = rimLerp(p.expMin, expMax, 0.3)
            contrastTarget = p.visIdle
        case .done, .pasted:
            exposureTarget = rimLerp(p.expMin, expMax, 0.85)
            contrastTarget = p.visIdle * 0.5
        case .flux, .fixed:
            exposureTarget = rimLerp(p.expMin, expMax, failing ? 0.6 : 0.35)
            contrastTarget = p.visIdle * 0.8
        case .problem:
            exposureTarget = rimLerp(p.expMin, expMax, 0.4) + 0.04 * sin(self.ringPhase * 2 * .pi / 2.6)
            contrastTarget = p.visIdle
        }
        self.exposure += (exposureTarget - self.exposure) * rimEase(dt, exposureTarget > self.exposure ? 0.018 : 0.16)
        self.contrast += (contrastTarget - self.contrast) * rimEase(dt, 0.12)

        // Where the voice lands: eight band followers plus low/high regional lift and tilt.
        let attack = max(0.005, p.attack)
        let release = max(0.06, p.release)
        for band in 0..<RimFeatures.bandCount {
            let target = listening ? rimClamp(f.bands[band], 0, 1) : 0
            let current = self.bandEnvelope[band]
            self.bandEnvelope[band] += (target - current) * rimEase(dt, target > current ? attack : release * 0.45)
        }
        let tiltTarget = listening ? (f.centroid - 0.5) * 2 * talking : 0
        self.tiltS += (tiltTarget - self.tiltS) * rimEase(dt, 0.14)
        self.lowS += ((listening ? f.low : 0) - self.lowS) * rimEase(dt, f.low > self.lowS ? 0.03 : 0.18)
        self.highS += ((listening ? f.high : 0) - self.highS) * rimEase(dt, f.high > self.highS ? 0.02 : 0.12)

        // Band slide. Frozen under Reduce Motion; the wobble keeps the composition from repeating.
        let speed: Float
        if reduced {
            speed = 0
        } else {
            switch state {
            case .think: speed = p.drift * 2
            case .problem: speed = p.drift * 0.5
            case .idle, .flux, .fixed: speed = p.drift * idleActivity
            case .listen, .done, .pasted: speed = p.drift + p.speechDrift * talking * (0.5 + 0.5 * level)
            }
        }
        for index in 0..<3 {
            self.phases[index] = rimWrap(self.phases[index] + Self.layerSpeeds[index] * speed * dt)
        }
        self.hue = rimWrap(self.hue + speed * 0.25 * dt)
        if !reduced { self.wobble += dt * (0.25 + 6 * speed) }
        self.ringPhase += dt * (state == .problem ? 1 : 0)

        self.updateBlooms(dt: dt, listening: listening, features: f, reduced: reduced, pill: sized)
        self.waveform.update(dt: dt, shows: listening && !self.liveWordsInPill, features: f, reduced: reduced, params: p)
        self.updateLine(dt: dt, state: state, reduced: reduced)

        // A paste that fails straight out of processing first sends the line back out to the rim, in ivory.
        let lineReturns = state == .flux && self.bubble.startsFromLine
        // Words in the pill take the line's place, so the line stays out and eases in from nothing once they go.
        let lineShows = !self.wordsShown && (state == .think || state == .done || (lineReturns && self.bubbleClock < p.snapTime))
        self.coreOn += ((lineShows ? 1 : 0) - self.coreOn) * rimEase(dt, 0.14)

        // Completion: the line turns green and holds; then one front expands back out
        // to the rim (always shown) or the whole pill collapses and vanishes.
        self.doneClock = state == .done || state == .pasted ? self.doneClock + dt : 0
        let hold = p.greenHold
        let dimTarget: Float
        switch state {
        case .think:
            dimTarget = self.wordsShown ? Self.wordsRimDim : 0.38
        case .done where self.wordsShown:
            dimTarget = 1
        case .done:
            let restoresAt = self.collapsesWhenDone ? hold : hold + 0.75 * p.snapTime
            dimTarget = self.doneClock > restoresAt ? 1 : 0.38
        case .flux:
            dimTarget = lineReturns && self.bubbleClock < 0.75 * p.snapTime ? 0.38 : 1
        case .idle, .listen, .problem, .pasted, .fixed:
            dimTarget = 1
        }
        let dimTime: Float = state == .think ? 0.3 : (dimTarget > self.dimRim ? 0.05 : 0.07)
        self.dimRim += (dimTarget - self.dimRim) * rimEase(dt, dimTime)

        self.updateVisibility(dt: dt, state: state, previous: previous, reduced: reduced)

        // Expand back to the rim, after the green hold (always shown) or in ivory when a paste fails.
        self.isSnapping = (state == .done && !self.collapsesWhenDone && self.doneClock >= hold) || lineReturns
        if self.isSnapping {
            self.snapSpring.time(to: p.snapTime, damping: p.transitionDamping)
            self.snapSpring.target = 1
            if reduced { self.snapSpring.x = 1 } else { self.snapSpring.step(dt) }
        } else {
            self.snapSpring.reset(to: 0)
        }
        self.restEase += ((state == .idle ? 1 : 0) - self.restEase) * rimEase(dt, state == .idle ? 0.5 : 0.05)
    }

    private mutating func updateSize(dt: Float, pill: CGSize, reduced: Bool) {
        let w = Float(pill.width), h = Float(pill.height)
        if !self.isSized || reduced {
            self.width.reset(to: w)
            self.height.reset(to: h)
            self.isSized = true
        }
        self.width.target = w
        self.height.target = h
        self.width.step(dt)
        self.height.step(dt)
    }

    /// "Can't hear you": after a stretch of silence while listening, a short pulse of light, never of shape.
    private mutating func updateNudge(dt: Float, state: RimState, speech: Float) {
        let p = self.params
        if state == .listen {
            self.quietTime = speech < 0.15 ? self.quietTime + dt : 0
            if self.quietTime == 0 { self.nextNudge = p.noSpeechAfter }
            if self.quietTime >= self.nextNudge {
                self.nudgeTime = 0
                self.nextNudge = self.quietTime + max(0.6, p.nudgeEvery)
            }
        } else {
            self.quietTime = 0
            self.nextNudge = p.noSpeechAfter
        }
        self.nudgeTime += dt
    }

    /// The pill shown only while dictating grows from a point, collapses after a
    /// paste and hides otherwise. Each runs on a spring timed to its approved
    /// duration, so a key press mid-collapse grows back from where the pill is.
    private mutating func updateVisibility(dt: Float, state: RimState, previous: RimState, reduced: Bool) {
        let p = self.params
        guard self.collapsesWhenDone else {
            self.visibilitySpring.reset(to: 1)
            self.isCollapsing = false
            self.meltAmount = 0
            self.fluid = RimFluidCollapse()
            return
        }
        let collapseNow = (state == .done || state == .pasted) && self.doneClock >= p.greenHold
        let shows = state != .idle && !collapseNow
        if shows {
            self.isCollapsing = false
        } else if collapseNow || previous == .fixed {
            // Idle after a paste keeps collapsing; idle otherwise hides quickly.
            self.isCollapsing = true
        }
        let duration = shows ? RimParameters.appearTime : self.isCollapsing ? p.collapseTime : RimParameters.hideTime
        self.visibilitySpring.time(to: duration, damping: p.transitionDamping)
        self.visibilitySpring.target = shows ? 1 : 0
        self.visibilitySpring.step(dt)
        self.fluid.update(dt: dt, collapsing: p.fluidCollapse && self.isCollapsing && !reduced, shows: shows, params: p)
        // The collapse's last point melts through the island's blob, the way the bubble dissolves.
        // In the fluid collapse the softening grows through the whole collapse, following the width.
        if !self.isCollapsing || reduced {
            self.meltAmount = 0
        } else if self.fluid.isOn {
            self.meltAmount = p.melt * pow(self.fluid.closed, 1.6)
        } else {
            self.meltAmount = p.melt * (1 - rimSmooth(self.visibility / 0.2))
        }
    }

    /// One bloom per syllable: underside for deep syllables, top edge for bright ones, mirrored, with a little jitter.
    private mutating func updateBlooms(dt: Float, listening: Bool, features f: RimFeatures, reduced: Bool, pill: CGSize) {
        let p = self.params
        if f.onset, listening {
            let w = Float(pill.width), h = Float(pill.height)
            let straight = max(0, w - h)
            let loop = 2 * straight + .pi * h
            let a = straight / loop
            let base = f.centroid > 0.5 ? a / 2 : a + (.pi * h / 2) / loop + a / 2
            let jitter = (self.random() * 2 - 1) * a * 0.38
            if self.blooms.count >= RimUniform.maxBlooms { self.blooms.removeFirst() }
            self.blooms.append(Bloom(s: rimWrap(base + jitter), age: 0, amp: p.bloom * (0.55 + 0.45 * f.onsetAmp) * (reduced ? 0.7 : 1)))
        }
        let tau = p.bloomDecay
        for index in self.blooms.indices { self.blooms[index].age += dt }
        self.blooms.removeAll { $0.age > tau * 4 || !listening }
        for index in 0..<RimUniform.maxBlooms {
            guard index < self.blooms.count else {
                for k in 0..<4 { self.bloomUniforms[index * 4 + k] = 0 }
                continue
            }
            let bloom = self.blooms[index]
            let sigma2 = p.bloomWidth * p.bloomWidth * (1 + (reduced ? 0 : p.bloomSpread) * 3 * bloom.age / tau)
            self.bloomUniforms[index * 4] = bloom.s
            self.bloomUniforms[index * 4 + 1] = bloom.amp * exp(-bloom.age / tau)
            self.bloomUniforms[index * 4 + 2] = sigma2
            self.bloomUniforms[index * 4 + 3] = (p.bloomWidth * p.bloomWidth / sigma2).squareRoot()
        }
    }

    /// The processing line's own colour slide, breath and blooms. All three are
    /// off in the approved tuning but stay wired so they can be turned back on.
    private mutating func updateLine(dt: Float, state: RimState, reduced: Bool) {
        let p = self.params
        let breathStep = dt / max(0.4, p.pulsePeriod)
        if state == .think {
            self.thinkClock += dt
            let slide = reduced ? 0 : p.lineSlide
            self.linePhases[0] = rimWrap(self.linePhases[0] + slide * dt)
            self.linePhases[1] = rimWrap(self.linePhases[1] - slide * 0.63 * dt)
            self.linePhases[2] = rimWrap(self.linePhases[2] + slide * 0.37 * dt)
            self.breath = rimWrap(self.breath + breathStep)
            let ready = self.thinkClock > p.downloadTime * 0.9
            if ready, self.thinkClock >= self.nextLineBloom, p.lineBloomRate > 0 {
                var x = (self.random() * 2 - 1) * 0.8
                if abs(x - self.lastLineBloomX) < 0.25 { x = -x * 0.9 }
                self.lastLineBloomX = x
                if self.lineBlooms.count >= RimUniform.maxLineBlooms { self.lineBlooms.removeFirst() }
                self.lineBlooms.append(LineBloom(x: x, age: 0, amp: p.lineBloom * (0.6 + 0.4 * self.random())))
                // Never faster than one per 340 ms.
                self.nextLineBloom = self.thinkClock + max(0.34, (0.6 + 0.8 * self.random()) / p.lineBloomRate)
            }
        } else {
            self.thinkClock = 0
            self.nextLineBloom = 0
            self.breath = state == .done ? rimWrap(self.breath + breathStep) : 0
        }
        for index in self.lineBlooms.indices { self.lineBlooms[index].age += dt }
        self.lineBlooms.removeAll { $0.age > 1.6 || (state != .think && state != .done) }
        for index in 0..<RimUniform.maxLineBlooms {
            guard index < self.lineBlooms.count else {
                for k in 0..<4 { self.lineBloomUniforms[index * 4 + k] = 0 }
                continue
            }
            let bloom = self.lineBlooms[index]
            let width: Float = 0.09
            let sigma2 = width * width * (1 + (reduced ? 0 : 1.2) * 3 * bloom.age / 0.42)
            self.lineBloomUniforms[index * 4] = bloom.x
            self.lineBloomUniforms[index * 4 + 1] = bloom.amp * rimSmooth(bloom.age / 0.09) * exp(-bloom.age / 0.42)
            self.lineBloomUniforms[index * 4 + 2] = sigma2
            self.lineBloomUniforms[index * 4 + 3] = (width * width / sigma2).squareRoot()
        }
    }

    /// Pill outline while it appears or collapses: full pill, then a thin line, then a point.
    static func shape(size: CGSize, visibility a: Float) -> (width: Float, height: Float, fade: Float) {
        let w = Float(size.width), h = Float(size.height)
        if a >= 1 { return (w, h, 1) }
        let thin: Float = 1.2
        let straight = max(0, w - h)
        if a <= 0 { return (thin, thin, 0) }
        if a < 0.4 {
            let k = rimSmooth(a / 0.4)
            return (thin + straight * k, thin, min(1, k * 1.6))
        }
        let k = rimSmooth((a - 0.4) / 0.6)
        let height = thin + (h - thin) * k
        return (height + straight, height, 1)
    }

    /// Everything the shader needs for one frame.
    /// `stretch` scales the pill's width and height while it is dragged.
    func uniforms(
        state given: RimState, stateTime givenTime: Float, displayScale: Float, reduced: Bool, dimAtRest: Bool,
        side: Float = 1, stretch: SIMD2<Float> = SIMD2(1, 1)
    ) -> [Float] {
        let p = self.params
        // While a failed paste waits on the words' bubble, the processing line holds where it is.
        let state = self.shownState(given)
        let stateTime = state != given ? givenTime + p.downloadTime + 1 : givenTime
        let w = self.width.x, h = self.height.x
        let geometry = self.bubble.geometry(width: w, height: h, params: p, side: side)
        var shape = if geometry.isOn {
            Self.shape(size: CGSize(width: CGFloat(geometry.pillWidth), height: CGFloat(geometry.pillHeight)), visibility: self.visibility)
        } else if self.fluid.isOn {
            self.fluid.shape(size: self.size)
        } else {
            Self.shape(size: self.size, visibility: self.visibility)
        }
        // The melt takes over the final fade.
        if self.meltAmount > 0 { shape.fade = max(shape.fade, min(1, 1.6 * (1 - self.meltAmount))) }
        var u = [Float](repeating: 0, count: RimUniform.count)
        u[RimUniform.pillW] = shape.width * stretch.x
        u[RimUniform.pillH] = shape.height * stretch.y
        u[RimUniform.fullW] = w
        u[RimUniform.fade] = shape.fade
        u[RimUniform.scale] = displayScale
        for index in 0..<3 {
            u[RimUniform.phase + index] = self.phases[index]
            u[RimUniform.linePhase + index] = self.linePhases[index]
        }
        u[RimUniform.wobble] = self.wobble
        u[RimUniform.contrast] = self.contrast
        // "Can't hear you": the island's 0.2 s pulse, in light.
        let nudge = self.nudgeTime < 0.2 ? sin(.pi * self.nudgeTime / 0.2) : 0
        u[RimUniform.exposure] = self.exposure + p.nudge * nudge
        u[RimUniform.hue] = self.hue
        u[RimUniform.hueShift] = p.hueShift
        u[RimUniform.hueCycles] = p.hueCycles
        u[RimUniform.tilt] = p.tilt
        u[RimUniform.lowS] = self.lowS
        u[RimUniform.highS] = self.highS
        u[RimUniform.tiltS] = self.tiltS
        u[RimUniform.bandLift] = p.bandLift
        for band in 0..<RimFeatures.bandCount { u[RimUniform.bands + band] = self.bandEnvelope[band] }
        u[RimUniform.bloomCount] = Float(self.blooms.count)
        for index in 0..<self.bloomUniforms.count { u[RimUniform.blooms + index] = self.bloomUniforms[index] }
        u[RimUniform.width] = p.width
        u[RimUniform.widthGain] = p.widthGain
        u[RimUniform.glow] = p.glow
        u[RimUniform.reach] = p.reach
        u[RimUniform.dimRim] = self.dimRim
        u[RimUniform.strength] = 1
        u[RimUniform.restEase] = dimAtRest ? self.restEase : 0
        u[RimUniform.coreOn] = self.coreOn
        u[RimUniform.doneT] = state == .done || state == .pasted ? self.doneClock : -1
        u[RimUniform.thinkT] = state == .think ? stateTime : -1
        u[RimUniform.reduced] = reduced ? 1 : 0
        u[RimUniform.downloadTime] = p.downloadTime
        u[RimUniform.snapTime] = p.snapTime
        u[RimUniform.lineWidth] = p.lineWidth
        u[RimUniform.innerGlow] = p.innerGlow
        u[RimUniform.breath] = self.breath
        u[RimUniform.pulseDepth] = p.pulseDepth
        for index in 0..<self.lineBloomUniforms.count { u[RimUniform.lineBlooms + index] = self.lineBloomUniforms[index] }
        u[RimUniform.snapT] = self.isSnapping ? self.snapSpring.x * p.snapTime : -1000
        u[RimUniform.lineLength] = p.lineLength
        u[RimUniform.lineFade] = rimSmooth((self.visibility - 0.55) / 0.45)
        u[RimUniform.pillX] = geometry.isOn ? geometry.pillX : 0
        u[RimUniform.sigma] = geometry.sigma
        u[RimUniform.hover] = self.bubble.hover
        u[RimUniform.icon] = self.bubble.icon
        u[RimUniform.hoverGlow] = p.hoverGlow
        u[RimUniform.iconKind] = self.bubble.kind.icon
        u[RimUniform.melt] = self.meltAmount
        u[RimUniform.meltSigma] = p.blobRadius * h / RimSpring.islandHeight
        u[RimUniform.meltFade] = self.fluid.isOn ? RimFluidCollapse.meltFade : 1
        u[RimUniform.waveAmount] = self.waveform.amount
        u[RimUniform.waveOpacity] = self.waveform.isHidden ? 0 : self.waveform.opacity * p.waveOpacity
        u[RimUniform.waveHeight] = p.waveHeight
        for index in 0..<RimWaveform.sampleCount { u[RimUniform.wave + index] = self.waveform.history[index] }
        if geometry.isOn, geometry.bubbleWidth > 0.05 {
            u[RimUniform.bubble] = geometry.bubbleX
            u[RimUniform.bubble + 1] = geometry.bubbleWidth
            u[RimUniform.bubble + 2] = geometry.bubbleHeight
            u[RimUniform.bubble + 3] = self.bubble.fade
        } else {
            u[RimUniform.bubble + 3] = 1
        }
        u[RimUniform.bubbleRadius] = 1e4
        u[RimUniform.bubbleLight] = 1
        // A waiting bubble beside the pill shares these slots, so it wins over words still draining back in.
        let words = self.wordsBubble
        if words.isActive, words.size.width > 0.05, !geometry.isOn {
            u[RimUniform.bubble] = 0
            u[RimUniform.bubble + 1] = Float(words.size.width)
            u[RimUniform.bubble + 2] = Float(words.size.height)
            u[RimUniform.bubble + 3] = words.fade(reduced: reduced)
            u[RimUniform.bubbleY] = words.y
            u[RimUniform.bubbleRadius] = words.cornerRadius
            u[RimUniform.bubbleLight] = RimWordsBubble.light
            u[RimUniform.sigma] = words.sigma
            u[RimUniform.hover] = 0
            u[RimUniform.icon] = 0
        }
        for index in 0..<4 {
            u[RimUniform.palette + index * 3] = self.palette[index].x
            u[RimUniform.palette + index * 3 + 1] = self.palette[index].y
            u[RimUniform.palette + index * 3 + 2] = self.palette[index].z
        }
        return u
    }

    /// How the words in the pill sit this frame: their offset when a bubble splits off, their
    /// scale with the pill's outline, and their opacity as it appears, collapses or fades.
    func wordsLook(side: Float = 1) -> (offsetX: Float, scale: SIMD2<Float>, opacity: Float) {
        let p = self.params
        let w = max(1, self.width.x), h = max(1, self.height.x)
        let appear = rimSmooth((self.visibility - 0.5) / 0.5)
        let geometry = self.bubble.geometry(width: w, height: h, params: p, side: side)
        if geometry.isOn {
            return (geometry.pillX, SIMD2(geometry.pillWidth / w, geometry.pillHeight / h), appear)
        }
        guard self.fluid.isOn else { return (0, SIMD2(1, 1), appear) }
        // The collapse: the words swell with the pill (1.05 for its 1.08), then fade as its height closes.
        let shape = self.fluid.shape(size: self.size)
        let across = shape.width / w, down = shape.height / h
        let swell = rimClamp((across - 1) / max(1e-3, p.fluidSwell - 1), 0, 1)
        let scale: Float = across >= 1 ? 1 + 0.05 * swell : 1 + (across - 1) * 0.25
        return (0, SIMD2(scale, scale), rimSmooth((down - 0.45) / 0.5) * shape.fade)
    }

    /// sRGB hex to OKLab.
    static func labs(_ colours: [UInt32]) -> [SIMD3<Float>] {
        colours.map { hex in
            func linear(_ shift: UInt32) -> Float {
                let c = Float((hex >> shift) & 0xff) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            let r = linear(16), g = linear(8), b = linear(0)
            let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
            let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
            let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
            return SIMD3(
                0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s
            )
        }
    }
}

@inline(__always)
nonisolated func rimLerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
    a + (b - a) * t
}

@inline(__always)
nonisolated func rimWrap(_ value: Float) -> Float {
    value - floor(value)
}

@inline(__always)
nonisolated func rimSmooth(_ t: Float) -> Float {
    let x = rimClamp(t, 0, 1)
    return x * x * (3 - 2 * x)
}
