import CoreGraphics
import Foundation

/// The approved collapse (Ali, 2026-10-21 20:03 UTC): the island's pre-collapse
/// swell, then height and width close on their own collapsing springs with the
/// height leading, while the fade runs on a third spring. It starts and ends when
/// the line-then-point collapse did, and never stops on a line. Port of the
/// `fluidCollapse` branch in the prototype's rim.js.
nonisolated struct RimFluidCollapse {
    /// How much the softening dims the pill in this collapse; the fade spring sets the end.
    static let meltFade: Float = 0.3
    /// The swell hands over to the collapse this far of the way up, the island's "next" point.
    private static let handOver: Float = 0.6
    /// The thinnest the pill gets before it is gone, in points.
    private static let thin: Float = 1.2

    private(set) var isOn = false
    private var height = RimSpring(RimSpring.collapse, at: 1)
    private var width = RimSpring(RimSpring.collapse, at: 1)
    private var fade = RimSpring(RimSpring.collapse, at: 1)
    private var clock: Float = 0
    /// When the swell handed over, in seconds from the start; negative while it rises.
    private var swellEnd: Float = -1

    /// How far the width has closed, 0 whole to 1 gone. The softening follows it.
    var closed: Float { self.isOn ? rimClamp(1 - self.width.x, 0, 1) : 0 }

    /// True once the fade has run out.
    var hasFaded: Bool { self.isOn && self.fade.x < 0.01 }

    /// `collapsing` is the collapse after a paste; `shows` is a key press asking for the pill.
    mutating func update(dt: Float, collapsing: Bool, shows: Bool, params p: RimParameters) {
        let damping = RimSpring.collapse.0
        if collapsing {
            if !self.isOn {
                self.isOn = true
                self.clock = 0
                self.swellEnd = p.fluidSwell <= 1.0001 ? 0 : -1
                self.height.reset(to: 1)
                self.width.reset(to: 1)
                self.fade.reset(to: 1)
            }
            self.clock += dt
            if self.swellEnd < 0 {
                self.height.time(to: p.swellTime, damping: damping)
                self.width.time(to: p.swellTime, damping: damping)
                self.height.target = p.fluidSwell
                self.width.target = p.fluidSwell
                if (self.width.x - 1) / (p.fluidSwell - 1) >= Self.handOver { self.swellEnd = self.clock }
            }
            if self.swellEnd >= 0 {
                let rest = max(0.08, p.collapseTime - self.swellEnd - p.fluidLead)
                self.height.time(to: rest, damping: damping)
                self.width.time(to: rest, damping: damping)
                self.fade.time(to: max(0.06, p.collapseTime - p.fluidFadeDelay), damping: damping)
                self.height.target = 0
                if self.clock - self.swellEnd >= p.fluidLead { self.width.target = 0 }
            }
            if self.clock >= p.fluidFadeDelay { self.fade.target = 0 }
        } else if self.isOn {
            // A key press mid-collapse grows both axes back from where they are. Once the
            // pill has gone, or is whole again, the approved appear takes over.
            let whole = abs(self.height.x - 1) < 0.005 && abs(self.width.x - 1) < 0.005 && self.height.target == 1
            if !shows || self.fade.x < 0.03 || whole {
                self.isOn = false
                return
            }
            Self.growBack(&self.height, damping: damping)
            Self.growBack(&self.width, damping: damping)
            Self.growBack(&self.fade, damping: damping)
        }
        guard self.isOn else { return }
        self.height.step(dt)
        self.width.step(dt)
        self.fade.step(dt)
    }

    private static func growBack(_ spring: inout RimSpring, damping: Float) {
        spring.time(to: RimParameters.appearTime, damping: damping)
        spring.target = 1
    }

    /// The pill's outline this frame, each axis from its own spring: a capsule
    /// never narrower than it is tall.
    func shape(size: CGSize) -> (width: Float, height: Float, fade: Float) {
        let w = Self.thin + (Float(size.width) - Self.thin) * rimClamp(self.width.x, 0, 1.2)
        let h = Self.thin + (Float(size.height) - Self.thin) * rimClamp(self.height.x, 0, 1.2)
        return (w, min(w, h), rimClamp(self.fade.x, 0, 1))
    }
}
