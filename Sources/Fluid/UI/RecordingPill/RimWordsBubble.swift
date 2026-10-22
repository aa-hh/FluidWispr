import CoreGraphics
import Foundation

/// The live words' bubble above the pill (AA-242, "Bubble above"). As the
/// first word arrives it splits off the top of the pill on the island's size
/// spring, staying joined to it through the blob until it settles 6 pt above;
/// it grows to fit the words, and once you stop talking it is sucked back into
/// the pill on the island's collapse spring, height a little ahead. Port of
/// `panelStep` in the live words prototype's index.html. Docked at the top of
/// the screen, it splits off below the pill instead.
nonisolated struct RimWordsBubble {
    /// The gap between the pill and the settled bubble, in medium-pill points.
    static let gap: Float = 6
    /// Its ring is the pill's light, a little quieter.
    static let light: Float = 0.6
    static let cornerCap: Float = 14
    /// The size it splits off at and drains to, in medium-pill points.
    private static let seed: Float = 18
    /// The blob radius, in island points: wide while it splits, narrower once it has settled.
    private static let blobSplitting: Float = 6.67
    private static let blobSettled: Float = 3.33
    private static let mediumHeight: Float = 28

    private(set) var isActive = false
    private(set) var isMerging = false
    private var position = RimSpring(RimSpring.size, at: 0)
    private var width = RimSpring(RimSpring.size, at: RimWordsBubble.seed)
    private var height = RimSpring(RimSpring.size, at: RimWordsBubble.seed)
    private var blob = RimSpring((0.816, 0.3), at: RimWordsBubble.blobSplitting)
    /// The bubble's centre below the pill's centre, in points; negative is above.
    private(set) var y: Float = 0
    private var islandScale: Float = 1

    var size: CGSize { CGSize(width: CGFloat(self.width.x), height: CGFloat(self.height.x)) }
    var sigma: Float { self.blob.x * self.islandScale }
    var cornerRadius: Float { min(self.height.x / 2, Self.cornerCap) }

    /// How visible the ring is: it fades in fast as it splits and out as it drains.
    func fade(reduced: Bool) -> Float {
        guard self.isActive else { return 0 }
        if self.isMerging { return rimSmooth(self.position.x / 0.3) }
        return reduced ? 1 : rimSmooth(self.position.x / 0.15)
    }

    /// The words show once the bubble is most of the way out, and go before it has drained.
    var textOpacity: Float {
        guard self.isActive else { return 0 }
        return self.isMerging ? rimSmooth((self.position.x - 0.6) / 0.3) : rimSmooth((self.position.x - 0.55) / 0.35)
    }

    /// `target` is the size the words need, or nil once the bubble should go back into the pill.
    /// It only splits off while listening.
    mutating func update(dt: Float, target: CGSize?, listening: Bool, pillHeight: Float, gap: Float, below: Bool, reduced: Bool) {
        self.islandScale = pillHeight / RimSpring.islandHeight
        let seed = Self.seed * pillHeight / RimWordsBubble.mediumHeight
        if !self.isActive, target != nil, listening { self.split(seed: seed) }
        guard self.isActive else { return }
        if target == nil { self.merge() }
        self.position.target = self.isMerging ? 0 : 1
        self.width.target = self.isMerging ? seed * 0.5 : Float(target?.width ?? 0)
        self.height.target = self.isMerging ? seed * 0.5 : Float(target?.height ?? 0)
        self.blob.target = !self.isMerging && self.position.x > 0.85 ? Self.blobSettled : Self.blobSplitting
        if reduced {
            self.position.reset(to: self.position.target)
            self.width.reset(to: self.width.target)
            self.height.reset(to: self.height.target)
            self.blob.reset(to: self.blob.target)
        } else {
            self.position.step(dt)
            self.width.step(dt)
            self.height.step(dt)
            self.blob.step(dt)
        }
        let edge = pillHeight / 2
        let settled = edge + gap + self.height.x / 2
        let distance = rimLerp(edge - 2, settled, rimClamp(self.position.x, -0.2, 1.2))
        self.y = below ? distance : -distance
        if self.isMerging, self.position.x < 0.03 || reduced { self.isActive = false }
    }

    private mutating func split(seed: Float) {
        self.isActive = true
        self.isMerging = false
        self.position = RimSpring(RimSpring.size, at: 0)
        self.width = RimSpring(RimSpring.size, at: seed)
        self.height = RimSpring(RimSpring.size, at: seed)
        self.blob.reset(to: Self.blobSplitting)
    }

    private mutating func merge() {
        guard !self.isMerging else { return }
        self.isMerging = true
        self.position.set(RimSpring.collapse)
        self.width.set(RimSpring.collapse)
        self.height.set((RimSpring.collapse.0, RimSpring.collapse.1 * 0.8))
    }
}
