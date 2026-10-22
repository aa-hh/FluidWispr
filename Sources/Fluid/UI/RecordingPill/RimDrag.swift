import CoreGraphics
import Foundation

/// Where the pill rests: one of six spots along the top and bottom of the screen.
nonisolated enum RecordingPillDock: String, CaseIterable, Codable {
    case topLeft
    case top
    case topRight
    case bottomLeft
    case bottom
    case bottomRight

    var displayName: String {
        switch self {
        case .topLeft: return "Top left"
        case .top: return "Top center"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottom: return "Bottom center"
        case .bottomRight: return "Bottom right"
        }
    }

    /// Docked on the right, the bubble splits off to the left.
    var bubbleSide: Float { self == .topRight || self == .bottomRight ? -1 : 1 }
    /// Docked along the top of the screen, so the live words' bubble goes below the pill.
    var isTop: Bool { self == .topLeft || self == .top || self == .topRight }
}

/// Dragging the pill and docking it. It follows the pointer on the island's
/// finger-drag spring, is rubber-banded past the outer spots, and on release
/// settles on the size spring at the spot nearest to where a flick would carry
/// it. Moving, it stretches along its travel; flung fast, it bounces once.
/// Port of "On your screen" in the prototype's index.html. Points are screen
/// points with y up, and the position is the pill's centre.
nonisolated struct RimDrag {
    /// The island's finger-drag spring (damping ratio, response in seconds).
    static let dragSpring: (Float, Float) = (0.456, 0.35)
    /// Inset of the spots from the screen's left, right and top edges, in points.
    static let margin: CGFloat = 12
    /// Stretch along the travel at full speed, and how much of it thins the pill across.
    static let stretch: Float = 0.08
    static let squash: Float = 0.25
    /// Resistance past the outer spots, and how far it can be pulled, in points.
    static let rubberBand: Float = 0.8
    static let bandReach: Float = 60
    /// The side bounce, at most this many island points.
    static let bounceCap: Float = 12
    static let fullStretchSpeed: Float = 1500
    static let bounceSpeed: Float = 300
    /// A flick is projected this far ahead, in seconds, to pick the spot.
    static let projection: Float = 0.3

    private var x = RimSpring(RimSpring.size, at: 0)
    private var y = RimSpring(RimSpring.size, at: 0)
    private var bounce = RimSpring(RimSpring.size, at: 0)
    private var bouncesAcross = false
    private var grab = SIMD2<Float>(0, 0)
    private var pointerTarget = SIMD2<Float>(0, 0)
    private(set) var isDragging = false
    private(set) var isPlaced = false

    var centre: CGPoint { CGPoint(x: CGFloat(self.x.x), y: CGFloat(self.y.x)) }

    /// Still following the pointer or settling, so the window moves this frame.
    var isMoving: Bool {
        self.isDragging
            || abs(self.x.v) + abs(self.y.v) + abs(self.bounce.v) > 0.5
            || abs(self.x.x - self.x.target) + abs(self.y.x - self.y.target) > 0.2
    }

    /// The pill's centre at each spot. The bottom spots keep the bottom
    /// overlay's offset above the Dock; the centre spots use the screen's middle.
    static func spots(visible: CGRect, screenMidX: CGFloat, pill: CGSize, bottomOffset: CGFloat) -> [RecordingPillDock: CGPoint] {
        let bottom = max(min(visible.minY + bottomOffset, visible.maxY - pill.height - 40), visible.minY + 10) + pill.height / 2
        let top = visible.maxY - Self.margin - pill.height / 2
        let left = visible.minX + Self.margin + pill.width / 2
        let right = visible.maxX - Self.margin - pill.width / 2
        return [
            .topLeft: CGPoint(x: left, y: top), .top: CGPoint(x: screenMidX, y: top), .topRight: CGPoint(x: right, y: top),
            .bottomLeft: CGPoint(x: left, y: bottom), .bottom: CGPoint(x: screenMidX, y: bottom), .bottomRight: CGPoint(x: right, y: bottom),
        ]
    }

    /// Past `lo` or `hi` the pill moves less and less, up to `bandReach`.
    static func banded(_ value: Float, _ lo: Float, _ hi: Float) -> Float {
        func band(_ over: Float) -> Float { (1 - 1 / (over * Self.rubberBand / Self.bandReach + 1)) * Self.bandReach }
        if value < lo { return lo - band(lo - value) }
        if value > hi { return hi + band(value - hi) }
        return value
    }

    static func nearest(to point: CGPoint, in spots: [RecordingPillDock: CGPoint]) -> RecordingPillDock {
        var best = RecordingPillDock.bottom
        var distance = CGFloat.infinity
        for dock in RecordingPillDock.allCases {
            guard let spot = spots[dock] else { continue }
            let d = hypot(spot.x - point.x, spot.y - point.y)
            if d < distance {
                distance = d
                best = dock
            }
        }
        return best
    }

    /// Puts the pill at `point` with no motion.
    mutating func place(at point: CGPoint) {
        self.x.reset(to: Float(point.x))
        self.y.reset(to: Float(point.y))
        self.isPlaced = true
    }

    mutating func begin(pointer: CGPoint) {
        self.isDragging = true
        self.grab = SIMD2(Float(pointer.x) - self.x.x, Float(pointer.y) - self.y.x)
        self.pointerTarget = SIMD2(self.x.x, self.y.x)
        self.x.set(Self.dragSpring)
        self.y.set(Self.dragSpring)
    }

    mutating func move(pointer: CGPoint, spots: [RecordingPillDock: CGPoint]) {
        guard self.isDragging, let lowLeft = spots[.bottomLeft], let topRight = spots[.topRight] else { return }
        self.pointerTarget = SIMD2(
            Self.banded(Float(pointer.x) - self.grab.x, Float(lowLeft.x), Float(topRight.x)),
            Self.banded(Float(pointer.y) - self.grab.y, Float(lowLeft.y), Float(topRight.y))
        )
    }

    /// Ends the drag and returns the spot it settles on.
    mutating func release(velocity: CGVector, spots: [RecordingPillDock: CGPoint], pillHeight: CGFloat, reduced: Bool) -> RecordingPillDock {
        self.isDragging = false
        self.x.set(RimSpring.size)
        self.y.set(RimSpring.size)
        let vx = Float(velocity.dx), vy = Float(velocity.dy)
        let projected = CGPoint(x: CGFloat(self.x.x + vx * Self.projection), y: CGFloat(self.y.x + vy * Self.projection))
        let speed = (vx * vx + vy * vy).squareRoot()
        if speed > Self.bounceSpeed, !reduced {
            self.bouncesAcross = abs(vy) > abs(vx)
            let peak = min(Self.bounceCap, (speed - Self.bounceSpeed) * 0.012) * Float(pillHeight) / RimSpring.islandHeight
            self.bounce.kick(peak: peak)
        }
        return Self.nearest(to: projected, in: spots)
    }

    mutating func step(dt: Float, rest: CGPoint, reduced: Bool) {
        if !self.isPlaced { self.place(at: rest) }
        self.x.target = self.isDragging ? self.pointerTarget.x : Float(rest.x)
        self.y.target = self.isDragging ? self.pointerTarget.y : Float(rest.y)
        if reduced, !self.isDragging {
            self.x.reset(to: self.x.target)
            self.y.reset(to: self.y.target)
        } else {
            self.x.step(dt)
            self.y.step(dt)
        }
        self.bounce.step(dt)
    }

    /// The pill's stretch this frame, width and height factors: along its
    /// travel and thinner across it, plus the bounce. None under Reduce Motion.
    func stretch(pill: CGSize, reduced: Bool) -> SIMD2<Float> {
        guard !reduced else { return SIMD2(1, 1) }
        let speed = (self.x.v * self.x.v + self.y.v * self.y.v).squareRoot()
        let amount = min(1, speed / Self.fullStretchSpeed)
        let ux = speed > 1 ? abs(self.x.v) / speed : 0
        let uy = speed > 1 ? abs(self.y.v) / speed : 0
        let along = Self.stretch * amount, across = along * Self.squash
        var sx = 1 + along * ux - across * uy
        var sy = 1 + along * uy - across * ux
        let out = max(0, self.bounce.x)
        let w = Float(pill.width), h = Float(pill.height)
        if self.bouncesAcross {
            sy += out / h
            sx -= Self.squash * out / h
        } else {
            sx += out / w
            sy -= Self.squash * out / w
        }
        return SIMD2(sx, sy)
    }
}
