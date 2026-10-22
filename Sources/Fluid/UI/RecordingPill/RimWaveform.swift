import Foundation

/// The live waveform inside the pill while listening, with live words Off or
/// Bubble above (AA-242; look approved by Ali 2026-10-22 03:39 UTC). Your voice
/// is laid across the pill from low to high, left to right, like the Dynamic
/// Island's call waveform: 14 points read from the 8 speech bands, each against
/// the bands' average so the shape shows where the voice sits, on Apple's 2/3
/// power curve. The points make one smooth ribbon mirrored about the centre
/// line, never separate bars, and each settles on a spring that doesn't bounce.
/// On release it flattens into the processing line. Under Reduce Motion the
/// points ease instead. Port of `waveStep` and `across` in the voice waveform
/// prototype's index.html (style "Low to high, across"); the shader draws it.
nonisolated struct RimWaveform {
    /// Samples of the ribbon's height across the pill, left to right, for the shader.
    static let sampleCount = 64
    /// Points across the pill, like Apple's 14 bands.
    static let pointCount = 14
    /// The points' critically damped spring, in seconds to settle.
    static let response: Float = 0.22
    /// A point this quiet drops to nothing.
    static let quiet: Float = 0.04

    private(set) var samples = [Float](repeating: 0, count: RimWaveform.sampleCount)
    private(set) var points = [Float](repeating: 0, count: RimWaveform.pointCount)
    private var velocities = [Float](repeating: 0, count: RimWaveform.pointCount)
    /// How tall the shape is allowed to be, 0 flat to 1 full; it flattens on release.
    private(set) var amount: Float = 0
    private(set) var opacity: Float = 0

    /// True once it has faded out, so it costs nothing.
    var isHidden: Bool { self.opacity < 0.01 }

    mutating func update(dt: Float, shows: Bool, features f: RimFeatures, reduced: Bool, params p: RimParameters) {
        let on: Float = shows ? 1 : 0
        self.amount += (on - self.amount) * rimEase(dt, shows ? 0.08 : 0.045)
        self.opacity += (on - self.opacity) * rimEase(dt, shows ? 0.08 : 0.09)
        let bands = f.bands
        let mean = bands.reduce(0, +) / Float(max(1, bands.count))
        for index in 0..<Self.pointCount {
            let target = shows ? Self.target(index, bands: bands, mean: mean, gain: p.waveGain) : 0
            if reduced {
                self.points[index] += (target - self.points[index]) * rimEase(dt, 0.2)
            } else {
                Self.spring(&self.points[index], &self.velocities[index], to: target, dt: dt)
            }
        }
        for index in 0..<Self.sampleCount {
            let u = Float(index) / Float(Self.sampleCount - 1)
            self.samples[index] = self.across(u) * Self.taper(u)
        }
    }

    /// One point's height: its share of the bands against their average, on Apple's curve.
    /// Apple's per-band weights are left out: they shrink the top bands, and those are the s and t sounds.
    private static func target(_ index: Int, bands: [Float], mean: Float, gain: Float) -> Float {
        guard bands.count > 1 else { return 0 }
        let at = Float(index) / Float(Self.pointCount - 1) * Float(bands.count - 1)
        let low = Int(at), high = min(bands.count - 1, low + 1)
        let band = rimLerp(bands[low], bands[high], at - Float(low))
        let energy = max(0, band * 1.6 - mean * 0.75)
        let height = min(1, pow(energy * gain * 1.5, 2 / 3))
        return height <= Self.quiet ? 0 : height
    }

    /// A smooth curve through the points, cosine between neighbours.
    private func across(_ u: Float) -> Float {
        let at = rimClamp(u, 0, 1) * Float(Self.pointCount - 1)
        let low = Int(at), high = min(Self.pointCount - 1, low + 1)
        let blend = (1 - cos((at - Float(low)) * .pi)) / 2
        return max(0, rimLerp(self.points[low], self.points[high], blend))
    }

    /// The ends ease to a point, so the ribbon sits inside the pill's curve.
    private static func taper(_ u: Float) -> Float {
        pow(sin(.pi * rimClamp(u * 1.04 - 0.02, 0, 1)), 0.35)
    }

    /// A critically damped spring, stepped in 4 ms slices.
    private static func spring(_ x: inout Float, _ v: inout Float, to target: Float, dt: Float) {
        let omega = 2 * Float.pi / Self.response
        let steps = max(1, Int((dt / 0.004).rounded(.up)))
        let h = dt / Float(steps)
        for _ in 0..<steps {
            v += (omega * omega * (target - x) - 2 * omega * v) * h
            x += v * h
        }
    }
}
