import AppKit
import QuartzCore

/// Draws the live words over the rim: one text layer per word, inside a clip
/// that is the inside of the pill or of the bubble above it, with the oldest
/// words fading at the left (or the top) once the text scrolls. RimWords decides
/// where each word is and how it looks; this only puts the layers there.
@MainActor
final class RecordingPillWordsView: NSView {
    /// The approved text colour, #F4EFE6, and the warm glow behind a lit word.
    private static let textColour = NSColor(srgbRed: 244 / 255, green: 239 / 255, blue: 230 / 255, alpha: 1)
    private static let glowColour = NSColor(srgbRed: 1, green: 238 / 255, blue: 214 / 255, alpha: 1).cgColor

    private let content = CALayer()
    /// Fades the top line once the bubble above scrolls; `clip` inside it fades the left.
    private let viewport = CALayer()
    private let fadeUp = CAGradientLayer()
    private let clip = CALayer()
    private let fade = CAGradientLayer()
    private var layers: [Int: CATextLayer] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        self.wantsLayer = true
        self.layer?.addSublayer(self.content)
        self.content.addSublayer(self.viewport)
        self.viewport.addSublayer(self.clip)
        self.fadeUp.startPoint = CGPoint(x: 0.5, y: 1)
        self.fadeUp.endPoint = CGPoint(x: 0.5, y: 0)
        self.fadeUp.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        self.viewport.mask = self.fadeUp
        self.clip.masksToBounds = true
        self.fade.startPoint = CGPoint(x: 0, y: 0.5)
        self.fade.endPoint = CGPoint(x: 1, y: 0.5)
        self.clip.mask = self.fade
        self.setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    /// A word's width at a text size, in points, for RimWords' layout.
    nonisolated static func width(of text: String, size: CGFloat) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width)
    }

    /// Puts each word in place for this frame. `box` is the pill's or the bubble's size now, in points,
    /// centred `offset` from the view's centre (y up), and the words take `look`'s scale and opacity.
    func show(
        _ looks: [RimWords.Look],
        words: RimWords,
        box: CGSize,
        offset: CGPoint,
        look: (scale: SIMD2<Float>, opacity: Float),
        scale: CGFloat
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard !looks.isEmpty, look.opacity > 0.003 else {
            self.content.isHidden = true
            return
        }
        self.content.isHidden = false
        let bounds = self.bounds
        self.content.bounds = bounds
        self.content.position = CGPoint(x: bounds.midX + offset.x, y: bounds.midY + offset.y)
        self.content.transform = CATransform3DMakeScale(CGFloat(look.scale.x), CGFloat(look.scale.y), 1)
        self.content.opacity = look.opacity

        let pad = words.padding
        let lineHeight = words.lineHeight
        // In the bubble the clip stops just above the top line, so a line scrolled away doesn't peek in.
        let inset = words.isAbove ? max(1, words.paddingY - 2) : 1
        let clipFrame = CGRect(
            x: bounds.midX - box.width / 2 + pad - 2,
            y: bounds.midY - box.height / 2 + inset,
            width: max(0, box.width - 2 * pad + 4),
            height: max(0, box.height - 2 * inset)
        )
        self.viewport.frame = clipFrame
        self.fadeUp.frame = self.viewport.bounds
        let top = (words.scrollUpOffset > 0.5 ? 4 * words.scale : 0) / max(1, clipFrame.height)
        self.fadeUp.locations = [0, NSNumber(value: Double(min(0.5, top))), 1]
        self.clip.frame = self.viewport.bounds
        self.fade.frame = self.clip.bounds
        let width = max(1, clipFrame.width)
        let left = (words.scrollOffset > 0.5 ? 14 * words.scale : 2) / width
        let right = 4 * words.scale / width
        self.fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        self.fade.locations = [0, NSNumber(value: Double(min(0.5, left))), NSNumber(value: Double(max(0.5, 1 - right))), 1]

        let size = words.fontSize
        var seen = Set<Int>()
        for word in looks {
            seen.insert(word.id)
            let text = self.layers[word.id] ?? self.makeLayer(id: word.id, scale: scale)
            if (text.string as? NSAttributedString)?.string != word.text || text.fontSize != size {
                text.fontSize = size
                text.string = NSAttributedString(string: word.text, attributes: [
                    .font: NSFont.systemFont(ofSize: size), .foregroundColor: Self.textColour,
                ])
            }
            guard word.opacity > 0.003 else {
                text.opacity = 0
                continue
            }
            let wordWidth = Self.width(of: word.text, size: size) + 2
            // y is up in the layer. In the pill the word sits on the clip's middle; in the bubble its line
            // counts down from the top. Either way it rises into place as it fades in.
            let y = words.isAbove
                ? clipFrame.height - (words.paddingY - inset) - CGFloat(word.y - words.scrollUpOffset) - lineHeight
                : clipFrame.height / 2 - lineHeight / 2
            text.frame = CGRect(
                x: CGFloat(word.x - words.scrollOffset) + 2,
                y: y - CGFloat(word.dy),
                width: wordWidth,
                height: lineHeight
            )
            text.transform = CATransform3DMakeScale(CGFloat(word.scale), CGFloat(word.scale), 1)
            text.opacity = word.opacity
            text.shadowOpacity = word.glow > 0.02 ? 0.75 * word.glow : 0
        }
        for (id, text) in self.layers where !seen.contains(id) {
            text.removeFromSuperlayer()
            self.layers[id] = nil
        }
    }

    private func makeLayer(id: Int, scale: CGFloat) -> CATextLayer {
        let text = CATextLayer()
        text.contentsScale = scale
        text.alignmentMode = .left
        text.truncationMode = .none
        text.isWrapped = false
        text.shadowColor = Self.glowColour
        text.shadowRadius = 5
        text.shadowOffset = .zero
        text.shadowOpacity = 0
        self.clip.addSublayer(text)
        self.layers[id] = text
        return text
    }
}
