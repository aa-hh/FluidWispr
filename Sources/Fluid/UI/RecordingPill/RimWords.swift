import CoreGraphics
import Foundation

/// Where the live words show while dictating (AA-242, Ali 2026-10-21 22:39 UTC;
/// In the pill is the default, 23:08 UTC). Off and Bubble above leave the pill
/// to the waveform.
nonisolated enum RecordingPillLiveWords: String, CaseIterable, Codable {
    case off
    case inPill
    case above

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .inPill: return "In the pill"
        case .above: return "Bubble above"
        }
    }
}

/// The live words in the pill: what Parakeet hears appears as you speak, the
/// pill grows to fit on the island's size spring and then scrolls, the oldest
/// words fading at the left. On release the rim's light reaches the words from
/// the ends inward; while the AI works they dim and a light reads through them;
/// the cleaned text then settles in place. Port of the words half of the live
/// words prototype's index.html (layout "ticker"). Sizes are for the medium
/// pill and scale with the pill's height.
nonisolated struct RimWords {
    /// The approved values, in medium-pill points and seconds.
    static let maxWidth: CGFloat = 360
    static let fontSize: CGFloat = 13
    static let padX: CGFloat = 13
    static let tentative: Float = 0.5
    static let settled: Float = 0.94
    static let appear: Float = 0.28
    static let scrollSpring: (Float, Float) = (0.78, 0.4)
    static let stagger: Float = 0.035
    static let thinkWords: Float = 0.6
    static let sweepPeriod: Float = 0.9
    static let sweepWidth: Float = 34
    static let inward: Float = 0.15
    static let popSpring: (Float, Float) = (0.78, 0.4)
    static let leaveResponse: Float = 0.45
    static let changeGlow: Float = 0.6
    /// How far a word may slide on cleanup; farther, it fades out where it was and in where it goes.
    static let farMove: Float = 48
    private static let mediumHeight: CGFloat = 28

    /// The widest the pill gets with words, for a pill of this height.
    static func widest(pillHeight: CGFloat) -> CGFloat { Self.maxWidth * max(0.5, pillHeight / Self.mediumHeight) }

    /// One word as drawn this frame, in points from the left of the text (before scroll) and with its look.
    struct Look: Equatable {
        let id: Int
        let text: String
        let x: Float
        let opacity: Float
        let glow: Float
        /// Rises into place as it fades in, in points.
        let dy: Float
        let scale: Float
    }

    private struct Word {
        let id: Int
        var text: String
        var tentative: Bool
        var gone = false
        var x: Float = 0
        var width: Float = 0
        var place: RimSpring
        var appear: RimSpring
        var opacity: Float
        var glow: Float = 0
        var pulseAt: Float = -1
        var delay: Float = 0
        /// False until the word has its first place, so it fades in there instead of sliding.
        var placed = false
    }

    private var words: [Word] = []
    private var nextID = 1
    private var scroll = RimSpring(RimWords.scrollSpring, at: 0)
    private var clock: Float = 0
    private var thinkStart: Float = -1
    private var textWidth: Float = 0
    private(set) var scale: CGFloat = 1
    /// Measures a word at a font size, in points.
    private let measure: @Sendable (String, CGFloat) -> CGFloat

    init(measure: @escaping @Sendable (String, CGFloat) -> CGFloat) {
        self.measure = measure
    }

    /// Words that are showing or still on their way in.
    var hasWords: Bool { self.words.contains { !$0.gone } }
    /// Anything left to draw, leaving words included.
    var isEmpty: Bool { self.words.isEmpty }
    var text: String { self.words.filter { !$0.gone }.map(\.text).joined(separator: " ") }
    var fontSize: CGFloat { Self.fontSize * self.scale }
    var lineHeight: CGFloat { (Self.fontSize * 1.32).rounded() * self.scale }
    var padding: CGFloat { Self.padX * self.scale }
    var scrollOffset: Float { self.scroll.x }

    /// The pill's size for these words: its own size until they need more, then wider up to the maximum.
    func pillSize(base: CGSize) -> CGSize {
        guard self.hasWords else { return base }
        let width = min(max(CGFloat(self.textWidth) + 2 * self.padding, base.width), Self.maxWidth * self.scale)
        return CGSize(width: width, height: base.height)
    }

    /// Sets the text size from the pill's height.
    mutating func setPill(height: CGFloat) {
        let scale = Self.widest(pillHeight: height) / Self.maxWidth
        guard abs(scale - self.scale) > 0.001 else { return }
        self.scale = scale
        self.layout()
    }

    /// A new preview of everything heard so far. Earlier words firm up and take
    /// any revision; new words arrive one after another and stay light until the
    /// next preview confirms them.
    mutating func hear(_ text: String, reduced: Bool) {
        let heard = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var live = self.words.indices.filter { !self.words[$0].gone }
        for (position, index) in live.enumerated() where position < heard.count {
            self.words[index].tentative = false
            if self.words[index].text != heard[position] {
                self.words[index].text = heard[position]
                self.words[index].glow = max(self.words[index].glow, 0.3)
            }
        }
        if live.count > heard.count {
            for index in live[heard.count...] { self.leave(index) }
            live.removeLast(live.count - heard.count)
        }
        if heard.count > live.count {
            for (order, word) in heard[live.count...].enumerated() {
                var new = self.makeWord(word, tentative: true)
                new.delay = reduced ? 0 : Float(order) * Self.stagger
                if new.delay == 0 { new.appear.target = 1 }
                self.words.append(new)
            }
        }
        self.layout()
        self.placeNewWords()
    }

    /// Key up: everything heard is final, and the rim's light reaches the words from the ends inward.
    mutating func release() {
        let inner = max(1, min(self.textWidth, Float(Self.maxWidth * self.scale - 2 * self.padding)))
        for index in self.words.indices where !self.words[index].gone {
            self.words[index].tentative = false
            let middle = (self.words[index].x - self.scroll.target + self.words[index].width / 2) / inner * 2 - 1
            self.words[index].pulseAt = self.clock + (1 - min(1, abs(middle))) * Self.inward
        }
        self.thinkStart = self.clock
    }

    /// The cleaned text came back: dropped words shrink away, changed ones glow
    /// as they change, new ones fade in where they go, and the rest slide there.
    mutating func cleanUp(_ cleaned: String, reduced: Bool) {
        let next = cleaned.split(whereSeparator: \.isWhitespace).map(String.init)
        let live = self.words.filter { !$0.gone }
        guard !live.isEmpty else { return }
        var leaving = self.words.filter(\.gone)
        var kept: [Word] = []
        for op in Self.diff(live.map(\.text), next) {
            switch op {
            case let .keep(old, new):
                var word = live[old]
                if word.text != next[new] {
                    word.text = next[new]
                    word.glow = max(word.glow, 0.35 * Self.changeGlow)
                }
                word.tentative = false
                kept.append(word)
            case let .drop(old):
                var word = live[old]
                Self.fadeOut(&word)
                leaving.append(word)
            case let .insert(new):
                var word = self.makeWord(next[new], tentative: false)
                word.glow = Self.changeGlow
                word.appear.target = 1
                kept.append(word)
            }
        }
        self.words = kept
        self.layout()
        self.placeNewWords()
        for index in self.words.indices {
            let from = self.words[index].place.x
            if !reduced, abs(self.words[index].x - from) > Self.farMove {
                var ghost = self.words[index]
                ghost.place.reset(to: from)
                ghost.glow = 0
                ghost = self.renumbered(ghost)
                Self.fadeOut(&ghost)
                leaving.append(ghost)
                self.words[index].place.reset(to: self.words[index].x)
                self.words[index].appear.reset(to: 0)
                self.words[index].appear.target = 1
            } else {
                self.words[index].place.set(Self.popSpring)
                self.words[index].place.target = self.words[index].x
                if reduced { self.words[index].place.reset(to: self.words[index].x) }
            }
        }
        self.words += leaving
        self.thinkStart = -1
    }

    /// Every word fades out, as when the pill rests again after a paste.
    mutating func dropAll() {
        for index in self.words.indices where !self.words[index].gone { self.leave(index) }
        self.thinkStart = -1
    }

    mutating func clear() {
        self.words = []
        self.textWidth = 0
        self.scroll.reset(to: 0)
        self.thinkStart = -1
    }

    mutating func step(dt: Float, reduced: Bool) {
        self.clock += dt
        self.scroll.target = max(0, self.textWidth - Float(Self.maxWidth * self.scale - 2 * self.padding))
        if reduced { self.scroll.reset(to: self.scroll.target) } else { self.scroll.step(dt) }
        for index in self.words.indices {
            if self.words[index].delay > 0 {
                self.words[index].delay -= dt
                if self.words[index].delay <= 0 { self.words[index].appear.target = 1 }
            }
            if !self.words[index].gone { self.words[index].place.target = self.words[index].x }
            if reduced {
                self.words[index].place.reset(to: self.words[index].place.target)
            } else {
                self.words[index].place.step(dt)
            }
            self.words[index].appear.step(reduced ? dt * 1.6 : dt)
            self.words[index].appear.x = rimClamp(self.words[index].appear.x, 0, 1.05)
            let opacity = self.words[index].tentative ? Self.tentative : Self.settled
            self.words[index].opacity += (opacity - self.words[index].opacity) * rimEase(dt, 0.12)
            if self.words[index].pulseAt >= 0, self.clock >= self.words[index].pulseAt {
                self.words[index].glow = max(self.words[index].glow, 0.85)
                self.words[index].pulseAt = -1
            }
            self.words[index].glow *= exp(-dt / 0.32)
        }
        self.words.removeAll { $0.gone && $0.appear.x < 0.01 && abs($0.appear.v) < 0.05 }
    }

    /// Each word's look this frame. `thinking` dims them while the AI works and runs the read-through
    /// along `inner`, the width inside the pill's padding.
    func looks(thinking: Bool, inner: Float, reduced: Bool) -> [Look] {
        let since = self.thinkStart >= 0 ? self.clock - self.thinkStart : 0
        let thinkFactor = thinking && self.thinkStart >= 0 ? rimSmooth((since - Self.inward * 0.6) / 0.12) : 0
        let sweepOn = thinking && !reduced && since > Self.inward + 0.05
        let span = inner + 2 * Self.sweepWidth
        let sweepX: Float = sweepOn
            ? -Self.sweepWidth + span * ((since - Self.inward - 0.05) / Self.sweepPeriod).truncatingRemainder(dividingBy: 1)
            : -1e4
        return self.words.map { word in
            let shown = rimClamp(word.appear.x, 0, 1)
            var opacity = word.appear.x * word.opacity
            var glow = word.glow
            if thinkFactor > 0 {
                let d = (word.place.x - self.scroll.x + word.width / 2 - sweepX) / Self.sweepWidth
                let lift: Float = sweepOn ? exp(-d * d * 1.4) : 0
                opacity *= rimLerp(1, Self.thinkWords + (1 - Self.thinkWords) * lift, thinkFactor)
                glow = max(glow, 0.55 * lift * thinkFactor)
            }
            return Look(
                id: word.id,
                text: word.text,
                x: word.place.x,
                opacity: max(0, opacity),
                glow: glow,
                dy: reduced || word.gone ? 0 : (1 - shown) * 2.2 * Float(self.scale),
                scale: word.gone && !reduced ? 0.82 + 0.18 * shown : 1
            )
        }
    }

    // MARK: - Layout and the word diff

    enum DiffOp: Equatable {
        case keep(Int, Int)
        case drop(Int)
        case insert(Int)
    }

    /// Keep, drop and insert between what was heard and what came back. Ties drop the earlier
    /// occurrence, so "four and five, no actually five and six" loses "four and five no actually" as one run.
    static func diff(_ a: [String], _ b: [String]) -> [DiffOp] {
        func norm(_ word: String) -> String {
            String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "'" })
        }
        let na = a.map(norm), nb = b.map(norm)
        let n = na.count, m = nb.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = na[i] == nb[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var ops: [DiffOp] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, na[i] == nb[j], table[i + 1][j] < table[i][j] {
                ops.append(.keep(i, j))
                i += 1
                j += 1
            } else if i < n, j >= m || table[i + 1][j] >= table[i][j + 1] {
                ops.append(.drop(i))
                i += 1
            } else {
                ops.append(.insert(j))
                j += 1
            }
        }
        return ops
    }

    private mutating func layout() {
        let size = self.fontSize
        let space = Float(self.measure(" ", size))
        var x: Float = 0
        for index in self.words.indices where !self.words[index].gone {
            self.words[index].width = Float(self.measure(self.words[index].text, size))
            self.words[index].x = x
            x += self.words[index].width + space
        }
        self.textWidth = max(0, x - space)
    }

    private mutating func placeNewWords() {
        for index in self.words.indices where !self.words[index].placed {
            self.words[index].place.reset(to: self.words[index].x)
            self.words[index].placed = true
        }
    }

    private mutating func makeWord(_ text: String, tentative: Bool) -> Word {
        defer { self.nextID += 1 }
        return Word(
            id: self.nextID,
            text: text,
            tentative: tentative,
            place: RimSpring(Self.popSpring, at: 0),
            appear: RimSpring((0.816, Self.appear), at: 0),
            opacity: tentative ? Self.tentative : Self.settled
        )
    }

    private mutating func renumbered(_ word: Word) -> Word {
        defer { self.nextID += 1 }
        var copy = Word(id: self.nextID, text: word.text, tentative: false, place: word.place, appear: word.appear, opacity: word.opacity)
        copy.width = word.width
        copy.x = word.x
        copy.placed = true
        return copy
    }

    private mutating func leave(_ index: Int) {
        Self.fadeOut(&self.words[index])
    }

    private static func fadeOut(_ word: inout Word) {
        word.gone = true
        word.appear.set((0.816, Self.leaveResponse))
        word.appear.target = 0
        word.pulseAt = -1
    }
}
