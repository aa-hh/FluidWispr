import Foundation
import os

/// Splits captured audio into the rim's eight voice bands on the capture
/// thread. Runs eight band-pass filters (`CENTRES` in the prototype's audio.js) and a
/// 10 ms loudness reading per band, then publishes the latest reading under a
/// lock for the render loop. Read-only tap: it never alters the samples.
nonisolated final class RimAudioAnalyzer: @unchecked Sendable {
    static let shared = RimAudioAnalyzer()

    static let centres: [Float] = [120, 200, 340, 560, 950, 1600, 2700, 4500]
    static let sampleRate: Float = 16_000
    static let hopSamples = 160

    private struct Biquad {
        var b0: Float, b2: Float, a1: Float, a2: Float
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

        init(sampleRate: Float, centre: Float, q: Float) {
            let w0 = 2 * Float.pi * min(centre, sampleRate * 0.45) / sampleRate
            let alpha = sin(w0) / (2 * q)
            let a0 = 1 + alpha
            self.b0 = alpha / a0
            self.b2 = -alpha / a0
            self.a1 = -2 * cos(w0) / a0
            self.a2 = (1 - alpha) / a0
        }

        mutating func process(_ x: Float) -> Float {
            let y = self.b0 * x + self.b2 * self.x2 - self.a1 * self.y1 - self.a2 * self.y2
            self.x2 = self.x1
            self.x1 = x
            self.y2 = self.y1
            self.y1 = y
            return y
        }
    }

    private struct Published {
        var bands = [Float](repeating: 0, count: RimFeatures.bandCount)
        var isActive = false
    }

    // Capture-thread state. Only `ingest` touches it, and the capture pipeline
    // calls `ingest` from one thread at a time.
    private var filters: [Biquad]
    private var energy = [Float](repeating: 0, count: RimFeatures.bandCount)
    private var hopFill = 0
    private var reference = [Float](repeating: RimAudioAnalyzer.referenceFloor, count: RimFeatures.bandCount)
    private var noiseFloor = [Float](repeating: 0, count: RimFeatures.bandCount)
    private let published = OSAllocatedUnfairLock(initialState: Published())

    /// Band loudness that counts as fully lit is never below this, so room
    /// noise alone cannot fill the rim.
    static let referenceFloor: Float = 0.006
    /// The loud reference falls back over about four seconds after a loud word.
    private static let referenceDecayPerHop: Float = exp(-0.01 / 4)

    init() {
        self.filters = Self.centres.map { Biquad(sampleRate: Self.sampleRate, centre: $0, q: 1.2) }
    }

    /// The render loop turns analysis on only while the pill reacts to the voice.
    func setActive(_ active: Bool) {
        self.published.withLock { state in
            state.isActive = active
            if !active { state.bands = [Float](repeating: 0, count: RimFeatures.bandCount) }
        }
    }

    /// Latest band energies, 0...1, low first.
    func latestBands() -> [Float] {
        self.published.withLock { $0.bands }
    }

    /// Feed 16 kHz mono samples. Called from the capture pipeline.
    func ingest(_ samples: [Float]) {
        guard self.published.withLock({ $0.isActive }) else { return }
        var latest: [Float]?
        for sample in samples {
            for band in 0..<self.filters.count {
                let y = self.filters[band].process(sample)
                self.energy[band] += y * y
            }
            self.hopFill += 1
            if self.hopFill == Self.hopSamples {
                latest = self.finishHop()
            }
        }
        if let latest {
            self.published.withLock { state in
                if state.isActive { state.bands = latest }
            }
        }
    }

    /// One 10 ms reading per band: RMS, minus a slowly tracked noise floor,
    /// against an adaptive loud reference, then a square root so quiet speech
    /// still shows. Mirrors `analyseBuffer` in the prototype, which normalised
    /// against a whole recording's 97th percentile instead.
    private func finishHop() -> [Float] {
        var signals = [Float](repeating: 0, count: RimFeatures.bandCount)
        for band in 0..<RimFeatures.bandCount {
            let rms = (self.energy[band] / Float(Self.hopSamples)).squareRoot()
            self.energy[band] = 0
            let noise = self.noiseFloor[band]
            self.noiseFloor[band] = rms < noise ? rms : noise + (rms - noise) * 0.005
            signals[band] = max(0, rms - 1.5 * self.noiseFloor[band])
            self.reference[band] = max(signals[band], self.reference[band] * Self.referenceDecayPerHop)
        }
        // A band is never measured against less than a tenth (-20 dB) of the
        // loudest band's reference, so leakage from a loud band stays dim.
        let minimumReference = max(Self.referenceFloor, 0.1 * (self.reference.max() ?? 0))
        var out = [Float](repeating: 0, count: RimFeatures.bandCount)
        for band in 0..<RimFeatures.bandCount {
            out[band] = rimClamp(signals[band] / max(minimumReference, self.reference[band]), 0, 1.3).squareRoot()
        }
        self.hopFill = 0
        return out
    }
}
