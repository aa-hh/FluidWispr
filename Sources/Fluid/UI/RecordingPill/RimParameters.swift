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

    // Paste failed: the transcript waits in a bubble that splits off the pill
    // with the Dynamic Island's split. Distances are island points, scaled by
    // pill height / `RimSpring.islandHeight`.
    /// Bubble diameter as a share of the pill's height.
    var fluxSize: Float = 1
    /// Clear space between the pill and the bubble, island points. Ali has not settled it yet.
    var fluxGap: Float = 8
    /// Which way the pill recoils when it kicks the bubble out: 1 away from
    /// the bubble, -1 towards it, 0 not at all. Ali has not settled it yet.
    var recoilDirection: Float = 1
    /// The island's blur radius for merging the two shapes, and the bubble's as it settles, island points.
    var blobRadius: Float = 6.67
    var settleBlob: Float = 3.33
    /// The bubble's own spring (damping ratio, response in seconds) and how far it leads the pill.
    var splitDamping: Float = 0.141
    var splitResponse: Float = 0.222
    var headStart: Float = 0.13
    /// Soft glow on the bubble's ring under the pointer.
    var hoverGlow: Float = 1
    /// How long a failed retry shows soft orange.
    var failFlash: Float = 0.6

    // Island motion (Ali, 2026-10-21 18:50 UTC).
    /// Appear, collapse and expand back run on springs with this damping that settle in the times above.
    var transitionDamping: Float = 0.816
    /// The collapse's last point melts through the blob; 0 turns it off.
    var melt: Float = 1
    /// The press bump on the waiting bubble and its spring (damping ratio, response in seconds).
    var pressX: Float = 1.015
    var pressY: Float = 1.03
    var pressDamping: Float = 0.694
    var pressResponse: Float = 0.85
    /// A failed retry shakes the bubble once this far, island points.
    var shake: Float = 8
    /// "Can't hear you": a 0.2 s pulse of light after this much silence, then again every `nudgeEvery`.
    var nudge: Float = 0.22
    var noSpeechAfter: Float = 2
    var nudgeEvery: Float = 3

    /// The pill grows from a point on key down in this long.
    static let appearTime: Float = 0.18
    /// A pill that is hidden without a paste leaves in this long.
    static let hideTime: Float = 0.12
    /// A click on the bubble fires its action this long after the press bump starts.
    static let pressDelay: Float = 0.12
    /// The Paste last transcript shortcut shows the hover glow and arrow for this long.
    static let shortcutFlash: Float = 0.32
    /// Ivory, the approved palette, as sRGB hex.
    static let ivory: [UInt32] = [0xffe4b8, 0xfff6ea, 0xffcfa0, 0xffebd2]
    static let done: [UInt32] = [0x3edc8a, 0x9cefb2, 0x79efcf, 0xb4ee62]
    static let problem: [UInt32] = [0xffb020, 0xffcf6a, 0xff8a00, 0xffc24d]
    /// Soft orange: a retried paste that failed again.
    static let retryFailed: [UInt32] = [0xff9a5c, 0xffb27e, 0xff8b57, 0xffc196]

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
