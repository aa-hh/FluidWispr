import Foundation

/// What the rim reads from the voice each frame.
nonisolated struct RimFeatures: Equatable {
    static let bandCount = 8

    var level: Float = 0
    var bands = [Float](repeating: 0, count: RimFeatures.bandCount)
    var low: Float = 0
    var mid: Float = 0
    var high: Float = 0
    var speech: Float = 0
    var speaking = false
    var onset = false
    var onsetAmp: Float = 0
    var centroid: Float = 0.5
}

@inline(__always)
nonisolated func rimEase(_ dt: Float, _ timeConstant: Float) -> Float {
    1 - exp(-dt / timeConstant)
}

@inline(__always)
nonisolated func rimClamp(_ value: Float, _ lower: Float, _ upper: Float) -> Float {
    min(max(value, lower), upper)
}

/// Turns raw band energies into stable features: loudness envelope, a speech
/// gate with hysteresis, syllable onsets and the spectral balance.
/// Line-for-line port of `createExtractor` in the prototype's `audio.js`.
nonisolated struct RimFeatureExtractor {
    var attack: Float
    var release: Float

    /// Onsets are at least this far apart, which keeps blooms under three per
    /// second (WCAG 2.3.1).
    static let onsetRefractory: Float = 0.34

    private(set) var features = RimFeatures()
    private var previous = [Float](repeating: 0, count: RimFeatures.bandCount)
    private var envelope: Float = 0
    private var hold: Float = 0
    private var lastOnset: Float = -9
    private var clock: Float = 0
    private var fluxMean: Float = 0.2

    init(attack: Float, release: Float) {
        self.attack = attack
        self.release = release
    }

    mutating func reset() {
        self = RimFeatureExtractor(attack: self.attack, release: self.release)
    }

    mutating func step(dt: Float, raw: [Float]) -> RimFeatures {
        let count = RimFeatures.bandCount
        self.clock += dt
        var flux: Float = 0
        var sum: Float = 0
        var weighted: Float = 0
        for index in 0..<count {
            let target = index < raw.count ? raw[index] : 0
            let band = self.features.bands[index]
            let next = band + (target - band) * rimEase(dt, target > band ? 0.02 : 0.09)
            self.features.bands[index] = next
            flux += max(0, next - self.previous[index])
            self.previous[index] = next
            sum += next
            weighted += next * Float(index)
        }

        // Loudness: raw mean, then the attack/release envelope, then a short smoother so frames never step.
        let instant = rimClamp(sum / Float(count) * 1.7, 0, 1)
        self.envelope += (instant - self.envelope) * rimEase(dt, instant > self.envelope ? self.attack : self.release)
        self.features.level += (self.envelope - self.features.level) * rimEase(dt, 0.012)

        // Speech gate with hysteresis and a 220 ms hold, so the rim does not flicker between words.
        if self.features.level > 0.09 {
            self.features.speaking = true
            self.hold = 0.22
        } else if self.features.speaking {
            self.hold -= dt
            if self.hold <= 0, self.features.level < 0.045 { self.features.speaking = false }
        }
        let speechTarget: Float = self.features.speaking ? 1 : 0
        self.features.speech += (speechTarget - self.features.speech) * rimEase(dt, self.features.speaking ? 0.06 : 0.3)

        // Onset: half-wave-rectified spectral flux against an adaptive mean.
        let fluxRate = flux / max(dt, 1e-3)
        self.fluxMean += (fluxRate - self.fluxMean) * rimEase(dt, 0.6)
        self.features.onset = false
        if fluxRate > max(9, 1.6 * self.fluxMean), self.clock - self.lastOnset > Self.onsetRefractory, instant > 0.08 {
            self.lastOnset = self.clock
            self.features.onset = true
            self.features.onsetAmp = rimClamp(fluxRate / 40, 0.2, 1)
        }

        // Spectral balance, trusted only while speaking; drifts back to centre otherwise.
        let centroidTarget = sum > 0.05 ? weighted / sum / Float(count - 1) : 0.5
        self.features.centroid += (centroidTarget - self.features.centroid) * rimEase(dt, self.features.speaking ? 0.1 : 0.4)

        let bands = self.features.bands
        let lowTarget = rimClamp((bands[0] + bands[1] + bands[2]) / 2.2, 0, 1)
        let midTarget = rimClamp((bands[3] + bands[4]) / 1.5, 0, 1)
        let highTarget = rimClamp((bands[5] + bands[6] + bands[7]) / 1.8, 0, 1)
        self.features.low += (lowTarget - self.features.low) * rimEase(dt, lowTarget > self.features.low ? 0.025 : 0.16)
        self.features.mid += (midTarget - self.features.mid) * rimEase(dt, midTarget > self.features.mid ? 0.02 : 0.12)
        self.features.high += (highTarget - self.features.high) * rimEase(dt, highTarget > self.features.high ? 0.015 : 0.1)
        return self.features
    }
}
