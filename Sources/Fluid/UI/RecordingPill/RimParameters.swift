import CoreGraphics
import Foundation

/// The approved rim tuning (Ali, 2026-10-21 17:36 UTC). Every value matches
/// `DEFAULTS` in the prototype's `rim.js` and the Figma "Rim" variables.
/// Times are in seconds here; the prototype stores milliseconds.
nonisolated struct RimParameters: Equatable {
    // Geometry of the light, in points.
    var width: Float = 1.2
    var widthGain: Float = 0.95
    var glow: Float = 1
    var reach: Float = 2.6
    var intensity: Float = 1.4
    // Band slide in loops per second: at idle, and the extra while speaking.
    var drift: Float = 0.1
    var speechDrift: Float = 0.5
    // Band contrast quiet to speaking, and light quiet to loud.
    var visIdle: Float = 0.16
    var visMax: Float = 1
    var expMin: Float = 0.26
    var expMax: Float = 0.53
    var bandLift: Float = 1.2
    var bloom: Float = 1.1
    var bloomDecay: Float = 0.25
    var bloomWidth: Float = 0.03
    var bloomSpread: Float = 1.3
    var tilt: Float = 0
    var hueShift: Float = 0.3
    var hueCycles: Float = 3
    var attack: Float = 0.015
    var release: Float = 0.24
    var idleActivity: Float = 0.3
    var downloadTime: Float = 0.15
    var lineLength: Float = 0.5
    var greenHold: Float = 0.26
    var snapTime: Float = 0.13
    var collapseTime: Float = 0.34
    var lineWidth: Float = 1
    var innerGlow: Float = 0.1
    var pulsePeriod: Float = 1.5
    var pulseDepth: Float = 0
    var lineBloom: Float = 0
    var lineBloomRate: Float = 0
    var lineSlide: Float = 0
    var idleFps: Double = 31

    /// The pill grows from a point on key down in this long.
    static let appearTime: Float = 0.18
    /// Ivory, the approved palette, as sRGB hex.
    static let ivory: [UInt32] = [0xffe4b8, 0xfff6ea, 0xffcfa0, 0xffebd2]
    static let done: [UInt32] = [0x3edc8a, 0x9cefb2, 0x79efcf, 0xb4ee62]
    static let problem: [UInt32] = [0xffb020, 0xffcf6a, 0xff8a00, 0xffc24d]

    static let approved = RimParameters()
}

/// The "Pill size" setting. Everything scales together; rim width, glow reach
/// and timing stay the same.
nonisolated enum RecordingPillSize: String, CaseIterable, Codable {
    case small
    case medium
    case large

    var displayName: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    var points: CGSize {
        switch self {
        case .small: return CGSize(width: 86, height: 20)
        case .medium: return CGSize(width: 120, height: 28)
        case .large: return CGSize(width: 156, height: 36)
        }
    }
}

/// The "Pill shows" setting.
nonisolated enum RecordingPillVisibility: String, CaseIterable, Codable {
    case always
    case whileDictating

    var displayName: String {
        switch self {
        case .always: return "Always"
        case .whileDictating: return "Only while dictating"
        }
    }
}
