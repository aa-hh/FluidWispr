import Foundation

/// The live waveform inside the pill while listening (AA-242, approved by Ali
/// 2026-10-21 22:39 UTC): a mirrored ribbon of light on a flat centre line, the
/// newest sound at the centre and the last `waveSpan` seconds travelling out to
/// both ends. On release it flattens into the processing line. Under Reduce
/// Motion nothing travels; the whole shape follows the level. Port of
/// `waveStep` in the live words prototype's index.html; the shader draws it.
nonisolated struct RimWaveform {
    /// Samples across half the pill, newest first.
    static let sampleCount = 64

    private(set) var history = [Float](repeating: 0, count: RimWaveform.sampleCount)
    /// How tall the shape is allowed to be, 0 flat to 1 full; it flattens on release.
    private(set) var amount: Float = 0
    private(set) var opacity: Float = 0
    private var level: Float = 0
    private var shiftClock: Float = 0

    /// True once it has faded out, so it costs nothing.
    var isHidden: Bool { self.opacity < 0.01 }

    mutating func update(dt: Float, shows: Bool, features f: RimFeatures, reduced: Bool, params p: RimParameters) {
        let on: Float = shows ? 1 : 0
        self.amount += (on - self.amount) * rimEase(dt, shows ? 0.08 : 0.045)
        self.opacity += (on - self.opacity) * rimEase(dt, shows ? 0.08 : 0.09)
        let target = shows ? rimClamp(pow(f.level, 0.75) * p.waveGain * (0.85 + 0.3 * f.high), 0, 1) : 0
        self.level += (target - self.level) * rimEase(dt, 0.03)
        if reduced {
            for index in self.history.indices { self.history[index] = self.level }
            return
        }
        self.shiftClock += dt
        let every = max(1e-3, p.waveSpan / Float(Self.sampleCount))
        while self.shiftClock >= every {
            self.shiftClock -= every
            self.history.removeLast()
            self.history.insert(0, at: 0)
        }
        self.history[0] = self.level
    }
}
