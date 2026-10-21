import Foundation

/// A damped spring with SpringBoard's parameters: mass 1, stiffness
/// (2π / response)², damping ratio × 4π / response. Port of the spring
/// helpers in the prototype's rim.js.
nonisolated struct RimSpring: Equatable {
    /// The resting Dynamic Island's height. Island distances scale by pill height / this.
    static let islandHeight: Float = 36.67

    /// The island's springs: (damping ratio, response in seconds).
    static let size: (Float, Float) = (0.816, 0.512)
    static let collapse: (Float, Float) = (0.816, 0.45)
    static let recombine: (Float, Float) = (0.6, 0.222)
    static let shakeSpring: (Float, Float) = (0.35, 0.18)

    var x: Float
    var v: Float = 0
    var target: Float
    var damping: Float
    var response: Float

    init(_ spring: (Float, Float), at x: Float) {
        self.x = x
        self.target = x
        self.damping = spring.0
        self.response = spring.1
    }

    mutating func set(_ spring: (Float, Float)) {
        self.damping = spring.0
        self.response = spring.1
    }

    /// Jumps to `value` and stops.
    mutating func reset(to value: Float) {
        self.x = value
        self.target = value
        self.v = 0
    }

    mutating func step(_ dt: Float) {
        let omega = 2 * Float.pi / self.response
        let stiffness = omega * omega
        let friction = self.damping * 2 * omega
        let count = max(1, Int((dt * 480).rounded(.up)))
        let h = dt / Float(count)
        for _ in 0..<count {
            self.v += (-stiffness * (self.x - self.target) - friction * self.v) * h
            self.x += self.v * h
        }
    }

    /// Times the spring to an approved duration. The response is fitted by
    /// least squares to the smoothstep it replaces (ω·T ≈ 3.3 at 0.816), so
    /// the curve barely changes while any transition can be interrupted and
    /// carry on from where it is.
    mutating func time(to duration: Float, damping: Float) {
        let zeta = rimClamp(damping, 0.5, 1.2)
        self.damping = zeta
        self.response = 2 * .pi * max(0.02, duration) / (3.0 + (zeta - 0.7) * 2.5)
    }

    /// Adds velocity so the spring's swing peaks at `peak` from rest.
    mutating func kick(peak: Float) {
        self.v += peak / max(1e-6, Self.impulsePeak(damping: self.damping, response: self.response))
    }

    /// How far a unit impulse swings this spring, so a kick can be sized to a peak.
    static func impulsePeak(damping: Float, response: Float) -> Float {
        var probe = RimSpring((damping, response), at: 0)
        probe.v = 1
        var peak: Float = 0
        for _ in 0..<2400 {
            probe.step(1 / 480)
            peak = max(peak, abs(probe.x))
        }
        return peak
    }
}
