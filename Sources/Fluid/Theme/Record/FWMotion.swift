import SwiftUI

/// The motion tokens of "The record", taken from the recording pill.
enum FWMotion {
    static let durationSnap: Double = 0.13
    static let durationExit: Double = 0.15
    static let durationEnter: Double = 0.18
    static let durationHold: Double = 0.26
    static let durationCollapse: Double = 0.34
    static let durationReduceCrossfade: Double = 0.13

    static let size = Animation.spring(response: 0.512, dampingFraction: 0.816)
    static let collapse = Animation.spring(response: 0.45, dampingFraction: 0.816)

    /// The size spring, or a 130 ms crossfade with Reduce Motion on.
    static func motion(reduced: Bool) -> Animation {
        reduced ? .easeInOut(duration: Self.durationReduceCrossfade) : Self.size
    }
}
