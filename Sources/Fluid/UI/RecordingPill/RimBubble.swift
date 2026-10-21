import Foundation

/// The bubble that splits off the pill when something waits on the user: a
/// transcript whose paste failed, or the fix for a lost microphone. It moves
/// with the Dynamic Island's split ("mitosis") from SpringBoard. Port of
/// `makeFlux`, `updateFlux` and `fluxGeom` in the prototype's rim.js.
nonisolated struct RimBubble {
    enum Kind: Equatable {
        /// A transcript waits; hovering shows a send arrow.
        case send
        /// The microphone stopped; the bubble shows a crossed-out mic.
        case microphone

        /// Which icon the shader draws.
        var icon: Float {
            switch self {
            case .send: return 0
            case .microphone: return 1
            }
        }
    }

    private enum Mode {
        case split
        case dissolve
        case recombine
    }

    private enum Lead {
        case scaleX, scaleY, nudge
    }

    /// One step of the split. Scales are x × y; nudges are sideways, in island
    /// points. `next` is how far through its spring the lead value gets before
    /// the next step starts.
    private struct Phase {
        var scaleX: Float?
        var scaleY: Float?
        var nudge: Float?
        var settlesBlob = false
        var next: Float = 1
        var lead: Lead?
    }

    /// SBSAIndicatorMitosisSettings: the bubble kicks out, then settles.
    private static let bubblePhases = [
        Phase(scaleX: 1.16, scaleY: 1, nudge: 2.33, next: 0.6, lead: .scaleX),
        Phase(scaleX: 1.12, scaleY: 1.08, nudge: 1.67, next: 0.4, lead: .scaleY),
        Phase(nudge: 0.33, settlesBlob: true, next: 0.5, lead: .nudge),
        Phase(scaleX: 1, scaleY: 1, nudge: 0),
    ]

    /// The pill's side of the split: it swells, recoils, then settles.
    private static let pillPhases = [
        Phase(scaleX: 1.08, scaleY: 1.08, next: 0.6, lead: .scaleX),
        Phase(scaleX: 1.11, scaleY: 1.10, nudge: 4, next: 0.6, lead: .nudge),
        Phase(scaleX: 1, scaleY: 1, nudge: 0, next: 0.4, lead: .scaleX),
        Phase(scaleX: 1, scaleY: 1, nudge: 0),
    ]

    private struct Progress {
        var phase = -1
        var lead: Lead?
        var start: Float = 0
    }

    /// Where the pill and the bubble are, in points from the panel's centre.
    struct Geometry {
        var isOn: Bool
        var bubbleX: Float
        var bubbleWidth: Float
        var bubbleHeight: Float
        var bubbleRadius: Float
        var pillWidth: Float
        var pillHeight: Float
        var pillX: Float
        var sigma: Float
    }

    private(set) var isActive = false
    private var mode: Mode = .split
    private var clock: Float = 0
    /// The paste failed straight out of processing, so the line first expands back to the rim.
    private(set) var startsFromLine = false
    private var startsAt: Float = 0
    private(set) var kind: Kind = .send

    private var position = RimSpring(RimSpring.size, at: 0)
    private var grow = RimSpring(RimSpring.size, at: 0)
    private var bubbleScaleX = RimSpring(RimSpring.size, at: 1)
    private var bubbleScaleY = RimSpring(RimSpring.size, at: 1)
    private var bubbleNudge = RimSpring(RimSpring.size, at: 0)
    private var pillScaleX = RimSpring(RimSpring.size, at: 1)
    private var pillScaleY = RimSpring(RimSpring.size, at: 1)
    private var pillNudge = RimSpring(RimSpring.size, at: 0)
    private var blob = RimSpring(RimSpring.size, at: 6.67)
    private var bubbleProgress = Progress()
    private var pillProgress = Progress()
    private var pressBump = RimSpring((0.694, 0.85), at: 0)
    private var shakeOffset = RimSpring(RimSpring.shakeSpring, at: 0)
    private var flash: Float = 0
    /// Reduce Motion fades the bubble in and out in place.
    private(set) var fade: Float = 1
    private(set) var hover: Float = 0
    private var hoverTarget: Float = 0
    private(set) var icon: Float = 0
    /// Time left on a failed retry's soft orange.
    private(set) var failTime: Float = 0

    /// True once the bubble has reached its place and can take a click.
    var isWaiting: Bool { self.isActive && self.mode == .split && self.position.x > 0.8 }

    mutating func setHover(_ on: Bool) {
        self.hoverTarget = on ? 1 : 0
    }

    /// A click on the bubble, or the shortcut (`showsFlash`: the glow and the
    /// arrow show as they would under the pointer).
    mutating func press(params p: RimParameters, showsFlash: Bool, reduced: Bool) {
        guard self.isActive else { return }
        self.pressBump.set((p.pressDamping, p.pressResponse))
        if !reduced { self.pressBump.kick(peak: 1) }
        if showsFlash { self.flash = RimParameters.shortcutFlash }
    }

    /// A retried paste failed again: soft orange, and one shake (not under Reduce Motion).
    mutating func fail(params p: RimParameters, reduced: Bool) {
        self.failTime = p.failFlash
        if !reduced, self.isActive { self.shakeOffset.kick(peak: p.shake) }
    }

    mutating func update(dt: Float, state: RimState, previous: RimState, params p: RimParameters, reduced: Bool) {
        self.failTime = max(0, self.failTime - dt)
        let waitingKind = Self.waitingKind(for: state)
        if let waitingKind, self.isActive, self.mode == .split { self.kind = waitingKind }
        if let waitingKind, !self.isActive || self.mode != .split, previous != state {
            self.start(kind: waitingKind, fromLine: previous == .think, params: p, reduced: reduced)
        }
        guard self.isActive else {
            self.hover = 0
            self.icon = 0
            return
        }
        self.clock += dt

        if waitingKind != nil, self.mode == .split {
            if self.clock >= self.startsAt, self.bubbleProgress.phase < 0 {
                self.position.target = 1
                self.grow.target = 1
                self.enterBubblePhase(0, params: p)
            }
            // The bubble leads by the head start.
            if self.clock >= self.startsAt + p.headStart, self.pillProgress.phase < 0 { self.enterPillPhase(0, params: p) }
            if reduced { self.fade = min(1, self.fade + dt / 0.2) }
        } else if state == .pasted || state == .fixed {
            if self.mode != .dissolve {
                self.mode = .dissolve
                self.settleAll(params: p)
                self.grow.set(RimSpring.collapse)
                self.grow.target = 0
                self.hoverTarget = 0
            }
            if reduced { self.fade = max(0, self.fade - dt / 0.2) }
            if (self.grow.x < 0.02 && abs(self.grow.v) < 0.5) || self.fade <= 0 { self.isActive = false }
        } else if state == .listen {
            // A new dictation supersedes the wait: the bubble slides back into the pill on the recombine spring.
            if self.mode != .recombine {
                self.mode = .recombine
                self.settleAll(params: p)
                self.position.set(RimSpring.recombine)
                self.position.target = 0
                self.grow.target = 0
                self.hoverTarget = 0
            }
            if reduced { self.fade = max(0, self.fade - dt / 0.2) }
            if (self.position.x < 0.03 && self.grow.x < 0.05) || self.fade <= 0 { self.isActive = false }
        } else {
            self.isActive = false
            return
        }

        if !reduced {
            self.pressBump.set((p.pressDamping, p.pressResponse))
            self.position.step(dt)
            self.grow.step(dt)
            self.bubbleScaleX.step(dt)
            self.bubbleScaleY.step(dt)
            self.bubbleNudge.step(dt)
            self.pillScaleX.step(dt)
            self.pillScaleY.step(dt)
            self.pillNudge.step(dt)
            self.blob.step(dt)
            self.pressBump.step(dt)
            self.shakeOffset.step(dt)
            self.advanceBubble(params: p)
            self.advancePill(params: p)
        }

        self.flash = max(0, self.flash - dt)
        let canHover = waitingKind != nil && self.isWaiting
        let hoverNow: Float = canHover ? max(self.hoverTarget, self.flash > 0 ? 1 : 0) : 0
        self.hover += (hoverNow - self.hover) * rimEase(dt, hoverNow > self.hover ? 0.09 : 0.16)
        // The transcript's arrow shows on hover; the mic always shows, brighter on hover.
        let iconTarget: Float
        if self.kind == .send {
            iconTarget = hoverNow
        } else if canHover {
            iconTarget = 0.72 + 0.28 * hoverNow
        } else {
            iconTarget = self.mode == .split ? 0 : self.icon
        }
        self.icon += (iconTarget - self.icon) * rimEase(dt, iconTarget > self.icon ? 0.11 : 0.08)
    }

    private static func waitingKind(for state: RimState) -> Kind? {
        switch state {
        case .flux: return .send
        case .problem: return .microphone
        default: return nil
        }
    }

    private mutating func start(kind: Kind, fromLine: Bool, params p: RimParameters, reduced: Bool) {
        let keptHover = self.hoverTarget
        self = RimBubble()
        self.hoverTarget = keptHover
        self.isActive = true
        self.kind = kind
        self.startsFromLine = fromLine
        self.startsAt = fromLine ? p.snapTime : 0.04
        self.blob.reset(to: p.blobRadius)
        let split = (p.splitDamping, p.splitResponse)
        self.bubbleScaleX.set(split)
        self.bubbleScaleY.set(split)
        self.bubbleNudge.set(split)
        if reduced {
            self.position.reset(to: 1)
            self.grow.reset(to: 1)
            self.fade = 0
            self.blob.reset(to: p.settleBlob)
            self.bubbleProgress.phase = 99
            self.pillProgress.phase = 99
        }
    }

    private mutating func settleAll(params p: RimParameters) {
        self.bubbleScaleX.target = 1
        self.bubbleScaleY.target = 1
        self.bubbleNudge.target = 0
        self.pillScaleX.target = 1
        self.pillScaleY.target = 1
        self.pillNudge.target = 0
        self.blob.target = p.blobRadius
        self.bubbleProgress.phase = 99
        self.pillProgress.phase = 99
    }

    private func bubbleValue(_ lead: Lead) -> RimSpring {
        switch lead {
        case .scaleX: return self.bubbleScaleX
        case .scaleY: return self.bubbleScaleY
        case .nudge: return self.bubbleNudge
        }
    }

    private func pillValue(_ lead: Lead) -> RimSpring {
        switch lead {
        case .scaleX: return self.pillScaleX
        case .scaleY: return self.pillScaleY
        case .nudge: return self.pillNudge
        }
    }

    private mutating func enterBubblePhase(_ index: Int, params p: RimParameters) {
        let phase = Self.bubblePhases[index]
        if let value = phase.scaleX { self.bubbleScaleX.target = value }
        if let value = phase.scaleY { self.bubbleScaleY.target = value }
        if let value = phase.nudge { self.bubbleNudge.target = value }
        if phase.settlesBlob { self.blob.target = p.settleBlob }
        self.bubbleProgress = Progress(phase: index, lead: phase.lead, start: phase.lead.map { self.bubbleValue($0).x } ?? 0)
    }

    private mutating func enterPillPhase(_ index: Int, params _: RimParameters) {
        let phase = Self.pillPhases[index]
        if let value = phase.scaleX { self.pillScaleX.target = value }
        if let value = phase.scaleY { self.pillScaleY.target = value }
        if let value = phase.nudge { self.pillNudge.target = value }
        self.pillProgress = Progress(phase: index, lead: phase.lead, start: phase.lead.map { self.pillValue($0).x } ?? 0)
    }

    private static func reached(_ spring: RimSpring, from start: Float, next: Float) -> Bool {
        let span = spring.target - start
        let progress = abs(span) < 1e-5 ? 1 : (spring.x - start) / span
        return progress >= next
    }

    private mutating func advanceBubble(params p: RimParameters) {
        let progress = self.bubbleProgress
        guard progress.phase >= 0, progress.phase < Self.bubblePhases.count - 1, let lead = progress.lead else { return }
        if Self.reached(self.bubbleValue(lead), from: progress.start, next: Self.bubblePhases[progress.phase].next) {
            self.enterBubblePhase(progress.phase + 1, params: p)
        }
    }

    private mutating func advancePill(params p: RimParameters) {
        let progress = self.pillProgress
        guard progress.phase >= 0, progress.phase < Self.pillPhases.count - 1, let lead = progress.lead else { return }
        if Self.reached(self.pillValue(lead), from: progress.start, next: Self.pillPhases[progress.phase].next) {
            self.enterPillPhase(progress.phase + 1, params: p)
        }
    }

    /// `side` -1 puts the bubble on the left, for a pill against the right edge of the screen.
    func geometry(width w: Float, height h: Float, params p: RimParameters, side: Float = 1) -> Geometry {
        let k = h / RimSpring.islandHeight
        let radius = 0.5 * p.fluxSize * h
        let inside = w * 0.5 - h * 0.5
        let outside = w * 0.5 + p.fluxGap * k + radius
        let size = max(0, self.grow.x)
        let pressed = self.pressBump.x
        return Geometry(
            isOn: self.isActive,
            bubbleX: side * (rimLerp(inside, outside, self.position.x) + (self.bubbleNudge.x + self.shakeOffset.x) * k),
            bubbleWidth: 2 * radius * self.bubbleScaleX.x * size * (1 + (p.pressX - 1) * pressed),
            bubbleHeight: 2 * radius * self.bubbleScaleY.x * size * (1 + (p.pressY - 1) * pressed),
            bubbleRadius: radius,
            pillWidth: w * self.pillScaleX.x,
            pillHeight: h * self.pillScaleY.x,
            // The pill recoils away from the bubble it kicks out.
            pillX: -side * p.recoilDirection * self.pillNudge.x * k,
            sigma: self.blob.x * k
        )
    }
}
